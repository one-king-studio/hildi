unit markdown.parse;
{ A small markdown subset parsed into typed blocks of styled spans, plus a theme
  mapping. Pure: no UI, no I/O, and never raises on malformed input.

  Streaming friendly. A closed block is final and never re-parsed. The open
  (trailing) block is retained as raw text and is not parsed at all until its
  terminator is seen or the stream ends, so an incomplete block renders as plain
  text while it streams. This is what keeps appending amortised O(n): the tail
  is inert, not re-scanned.

  Deviations from CommonMark, accepted for v1: lazy continuation is not
  supported (an unindented line after a list item closes the list), any ordered
  number may interrupt a paragraph, and underscore emphasis is only recognised
  at word boundaries.

  This is the pure module's parser: it depends on markdown.types and the RTL
  only (SysUtils), never on tui.* or hildegard.helper.*. `make markdown-standalone`
  compiles it with nothing else on the search path, and that is the feature's
  central claim. The theme that used to live here moved to
  tui.widgets.mdtheme; width measurement and wrapping are the renderer's job,
  so nothing here measures a terminal cell.

  Split pending: the block scanner, the inline scanner and the segmenter share
  this unit today because they share helpers (CollapseWhitespace, SplitCells).
  They are meant to become markdown.blocks / markdown.inline / markdown.stream,
  in separate commits, as the units are touched. }

{$mode delphi}{$H+}

interface

uses
  markdown.types;

type
  { The parser. Create once; Reset before a new document. }
  TMarkdownParser = class
  private
    FFinalized: TMdBlockArray;
    FTail: UnicodeString;      { raw text of the open block, never parsed }
    FPartial: UnicodeString;   { received text with no newline yet }
    FOpen: Boolean;
    FKind: TMdBlockKind;
    FFenceChar: Char;
    FLanguage: UnicodeString;
    procedure AddBlock(const ABlock: TMdBlock);
    procedure AppendTailLine(const ALine: UnicodeString);
    procedure ResetOpen;
    procedure FinalizeTail;
    procedure ProcessLine(const ALine: UnicodeString);
    procedure Feed(const AText: string; AAtEof: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    { Full parse of a complete document. }
    function Parse(const AText: string): TMdBlockArray;
    { Incremental: append a chunk of streamed text. }
    procedure Append(const AChunk: string);
    { End of stream: finalise the open tail as the last block. }
    procedure Finish;
    { All blocks known so far, plus the open tail as one plain text block. }
    function Blocks: TMdBlockArray;
    { The number of finalised blocks so far; these never change. }
    function FinalizedCount: Integer;
    { The finalised block at AIndex (0..FinalizedCount-1), else an empty block. }
    function FinalizedBlock(AIndex: Integer): TMdBlock;
    { The open tail as raw text (including the pending partial line), or ''. }
    function TailText: UnicodeString;
  end;

{ The batch form: one call, same tree. Equivalence with the streamed form is
  asserted over a corpus (tests/test_markdown_equivalence.pas), not assumed. }
function ParseMarkdown(const AText: string): TMdBlockArray;

implementation

uses
  SysUtils;

type
  TUnicodeStringArray = array of UnicodeString;

function IsSpaceU(const AText: UnicodeString; AIndex: Integer): Boolean;
begin
  Result := (AText[AIndex] = ' ') or (AText[AIndex] = #9) or
    (AText[AIndex] = #10) or (AText[AIndex] = #13);
end;

function TrimU(const S: UnicodeString): UnicodeString;
var
  A, B: Integer;
begin
  A := 1;
  B := Length(S);
  while (A <= B) and IsSpaceU(S, A) do
    Inc(A);
  while (B >= A) and IsSpaceU(S, B) do
    Dec(B);
  Result := Copy(S, A, B - A + 1);
end;

{ Collapse every run of whitespace to a single space and trim the edges. }
function CollapseWhitespace(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  Pending: Boolean;
begin
  Result := '';
  Pending := False;
  for I := 1 to Length(S) do
    if IsSpaceU(S, I) then
      Pending := True
    else
    begin
      if Pending and (Result <> '') then
        Result := Result + ' ';
      Pending := False;
      Result := Result + S[I];
    end;
end;

function SplitLines(const S: UnicodeString): TUnicodeStringArray;
var
  P: Integer;
  Rest: UnicodeString;
begin
  Result := nil;
  Rest := S;
  while True do
  begin
    P := Pos(#10, Rest);
    if P = 0 then
      Break;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Copy(Rest, 1, P - 1);
    Rest := Copy(Rest, P + 1, Length(Rest));
  end;
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)] := Rest;
end;

{ Drop the first line of a multi-line string (a code fence's opening line). }
function DropFirstLine(const S: UnicodeString): UnicodeString;
var
  P: Integer;
begin
  P := Pos(#10, S);
  if P = 0 then
    Result := ''
  else
    Result := Copy(S, P + 1, Length(S));
end;

{ --- line classifiers ---------------------------------------------------- }

function HeadingLevel(const ALine: UnicodeString; out ALevel: Integer): Boolean;
var
  I, N: Integer;
begin
  I := 1;
  while (I <= Length(ALine)) and (ALine[I] = ' ') do
    Inc(I);
  N := 0;
  while (I <= Length(ALine)) and (ALine[I] = '#') do
  begin
    Inc(N);
    Inc(I);
  end;
  ALevel := N;
  Result := (N >= 1) and (N <= 6) and
    ((I > Length(ALine)) or (ALine[I] = ' '));
end;

function IsRule(const ALine: UnicodeString): Boolean;
var
  I, Count: Integer;
  Ch: Char;
  S: UnicodeString;
begin
  S := TrimU(ALine);
  Count := 0;
  Ch := #0;
  for I := 1 to Length(S) do
    if S[I] = ' ' then
      Continue
    else if not (S[I] in ['-', '*', '_']) then
      Exit(False)
    else
    begin
      if Ch = #0 then
        Ch := S[I]
      else if S[I] <> Ch then
        Exit(False);
      Inc(Count);
    end;
  Result := Count >= 3;
end;

function FenceOpen(const ALine: UnicodeString; out AChar: Char;
  out ALanguage: UnicodeString): Boolean;
var
  I, Count, Start: Integer;
begin
  AChar := #0;
  ALanguage := '';
  Start := 1;
  while (Start <= Length(ALine)) and (ALine[Start] = ' ') and (Start <= 3) do
    Inc(Start);
  if Start > Length(ALine) then
    Exit(False);
  if not (ALine[Start] in ['`', '~']) then
    Exit(False);
  AChar := ALine[Start];
  I := Start;
  Count := 0;
  while (I <= Length(ALine)) and (ALine[I] = AChar) do
  begin
    Inc(Count);
    Inc(I);
  end;
  if Count < 3 then
    Exit(False);
  ALanguage := TrimU(Copy(ALine, I, Length(ALine)));
  Result := True;
end;

function FenceClose(const ALine: UnicodeString; AChar: Char): Boolean;
var
  I, Count: Integer;
  S: UnicodeString;
begin
  S := TrimU(ALine);
  Count := 0;
  for I := 1 to Length(S) do
    if S[I] = AChar then
      Inc(Count)
    else
      Exit(False);
  Result := Count >= 3;
end;

function ListMarker(const ALine: UnicodeString; out AOrdered: Boolean;
  out AOrdinal, ADepth: Integer): Boolean;
var
  I, Indent, Start, Num, Digits: Integer;
begin
  AOrdered := False;
  AOrdinal := 0;
  ADepth := 1;
  Indent := 0;
  I := 1;
  while (I <= Length(ALine)) and (ALine[I] = ' ') do
  begin
    Inc(Indent);
    Inc(I);
  end;
  Start := I;
  if Start > Length(ALine) then
    Exit(False);
  if ALine[Start] in ['-', '*', '+'] then
  begin
    if (Start = Length(ALine)) or (ALine[Start + 1] = ' ') then
    begin
      ADepth := (Indent div 2) + 1;
      Exit(True);
    end;
    Exit(False);
  end;
  Num := 0;
  Digits := 0;
  while (I <= Length(ALine)) and (ALine[I] in ['0'..'9']) do
  begin
    if Digits < 6 then
      Num := Num * 10 + (Ord(ALine[I]) - Ord('0'));
    Inc(Digits);
    Inc(I);
  end;
  if (Digits = 0) or (I > Length(ALine)) or not (ALine[I] in ['.', ')']) then
    Exit(False);
  if (I < Length(ALine)) and (ALine[I + 1] <> ' ') then
    Exit(False);
  AOrdered := True;
  if Num < 1 then
    Num := 1;
  AOrdinal := Num;
  ADepth := (Indent div 2) + 1;
  Result := True;
end;

function QuoteDepth(const ALine: UnicodeString; out ADepth: Integer): Boolean;
var
  I, D: Integer;
begin
  ADepth := 0;
  I := 1;
  while (I <= Length(ALine)) and (ALine[I] = ' ') do
    Inc(I);
  D := 0;
  while (I <= Length(ALine)) and (ALine[I] = '>') do
  begin
    Inc(D);
    Inc(I);
    if (I <= Length(ALine)) and (ALine[I] = ' ') then
      Inc(I);
  end;
  ADepth := D;
  Result := D > 0;
end;

function StripQuote(const ALine: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(ALine)) and (ALine[I] = ' ') do
    Inc(I);
  while (I <= Length(ALine)) and (ALine[I] = '>') do
  begin
    Inc(I);
    if (I <= Length(ALine)) and (ALine[I] = ' ') then
      Inc(I);
  end;
  Result := Copy(ALine, I, Length(ALine));
end;

function StripListMarker(const ALine: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(ALine)) and (ALine[I] = ' ') do
    Inc(I);
  if (I <= Length(ALine)) and (ALine[I] in ['-', '*', '+']) then
    Inc(I)
  else
  begin
    while (I <= Length(ALine)) and (ALine[I] in ['0'..'9']) do
      Inc(I);
    if (I <= Length(ALine)) and (ALine[I] in ['.', ')']) then
      Inc(I);
  end;
  if (I <= Length(ALine)) and (ALine[I] = ' ') then
    Inc(I);
  Result := Copy(ALine, I, Length(ALine));
end;

{ --- table helpers ------------------------------------------------------- }

{ True when the line contains a `|` that is not escaped with a backslash. }
function HasUnescapedPipe(const ALine: UnicodeString): Boolean;
var
  I: Integer;
begin
  I := 1;
  while I <= Length(ALine) do
    if ALine[I] = '\' then
      Inc(I, 2)
    else if ALine[I] = '|' then
      Exit(True)
    else
      Inc(I);
  Result := False;
end;

{ Split a table row into trimmed cells: drop an optional leading and trailing
  pipe and unescape `\|`. An all-pipe row still yields one (empty) cell. }
function SplitCells(const ALine: UnicodeString): TUnicodeStringArray;
var
  I, N: Integer;
  Cell, Line: UnicodeString;

  procedure Flush;
  begin
    SetLength(Result, N + 1);
    Result[N] := TrimU(Cell);
    Inc(N);
    Cell := '';
  end;

begin
  Result := nil;
  N := 0;
  Line := TrimU(ALine);
  I := 1;
  if (I <= Length(Line)) and (Line[I] = '|') then
    Inc(I);
  while I <= Length(Line) do
    if (Line[I] = '\') and (I < Length(Line)) and (Line[I + 1] = '|') then
    begin
      Cell := Cell + '|';
      Inc(I, 2);
    end
    else if Line[I] = '|' then
    begin
      Flush;
      Inc(I);
    end
    else
    begin
      Cell := Cell + Line[I];
      Inc(I);
    end;
  if (Cell <> '') or (N = 0) then
    Flush;
end;

{ Parse a delimiter row into per-column alignments. Requires a `|`, so a bare
  `---` stays a thematic break rather than a one-column table. }
function ParseDelimiter(const ALine: UnicodeString;
  out AAligns: TMdAlignArray): Boolean;
var
  Cells: TUnicodeStringArray;
  I, J: Integer;
  S: UnicodeString;
  Left, Right: Boolean;
begin
  Result := False;
  AAligns := nil;
  if not HasUnescapedPipe(ALine) then
    Exit;
  Cells := SplitCells(ALine);
  if Length(Cells) = 0 then
    Exit;
  SetLength(AAligns, Length(Cells));
  for I := 0 to High(Cells) do
  begin
    S := Cells[I];
    if S = '' then
      Exit;
    Left := S[1] = ':';
    if Left then
      S := Copy(S, 2, Length(S));
    Right := (S <> '') and (S[Length(S)] = ':');
    if Right then
      SetLength(S, Length(S) - 1);
    if S = '' then
      Exit;
    for J := 1 to Length(S) do
      if S[J] <> '-' then
        Exit;
    if Left and Right then
      AAligns[I] := maCenter
    else if Right then
      AAligns[I] := maRight
    else if Left then
      AAligns[I] := maLeft
    else
      AAligns[I] := maNone;
  end;
  Result := True;
end;

{ --- inline scanner ------------------------------------------------------ }

const
  { Recursion cap for nested emphasis, so untrusted input cannot blow the stack;
    beyond it, markup is emitted literally. }
  MaxInlineDepth = 16;

function IsWordChar(const Ch: UnicodeString): Boolean;
begin
  if Ch = '' then
    Exit(False);
  Result := ((Ch[1] >= '0') and (Ch[1] <= '9')) or
    ((Ch[1] >= 'A') and (Ch[1] <= 'Z')) or
    ((Ch[1] >= 'a') and (Ch[1] <= 'z')) or (Ch[1] = '_');
end;

function FindChar(const S: UnicodeString; ACh: Char; AFrom: Integer): Integer;
var
  I: Integer;
begin
  for I := AFrom to Length(S) do
    if S[I] = ACh then
      Exit(I);
  Result := 0;
end;

function FindStr(const S: UnicodeString; const ANeedle: UnicodeString;
  AFrom: Integer): Integer;
var
  I: Integer;
begin
  for I := AFrom to Length(S) - Length(ANeedle) + 1 do
    if Copy(S, I, Length(ANeedle)) = ANeedle then
      Exit(I);
  Result := 0;
end;

{ Scan inline markup into styled spans. Unmatched delimiters are literal. A
  paired run is re-scanned so emphasis nests; the outer style is ORed into each
  inner span. }
function ScanInline(const AText: UnicodeString; ADepth: Integer): TMdSpanArray;
var
  I, ClosePos, UrlStart, UrlEnd, N: Integer;
  Plain: UnicodeString;
  Span: TMdSpan;

  procedure FlushPlain;
  begin
    if Plain = '' then
      Exit;
    Span := Default(TMdSpan);
    Span.Text := Plain;
    SetLength(Result, N + 1);
    Result[N] := Span;
    Inc(N);
    Plain := '';
  end;

  procedure Emit(const AText: UnicodeString; AStyles: TMdInlineStyles;
    const ALink: UnicodeString);
  begin
    FlushPlain;
    Span := Default(TMdSpan);
    Span.Text := AText;
    Span.Styles := AStyles;
    Span.Link := ALink;
    SetLength(Result, N + 1);
    Result[N] := Span;
    Inc(N);
  end;

  { Append already-scanned spans, adding AExtra to each one's styles. }
  procedure AppendStyled(const AInner: TMdSpanArray;
    AExtra: TMdInlineStyles);
  var
    K: Integer;
  begin
    for K := 0 to High(AInner) do
    begin
      Span := AInner[K];
      Span.Styles := Span.Styles + AExtra;
      SetLength(Result, N + 1);
      Result[N] := Span;
      Inc(N);
    end;
  end;

  { Match a paired delimiter at I; on success emit the enclosed run, re-scanned
    so nested emphasis works and the outer style is added to each inner span. }
  function Paired(const ADelim: UnicodeString;
    AStyles: TMdInlineStyles): Boolean;
  var
    Closing: Integer;
    Inner: TMdSpanArray;
  begin
    Result := False;
    if Copy(AText, I, Length(ADelim)) <> ADelim then
      Exit;
    { Underscore emphasis sits at a word boundary, so snake_case is safe. }
    if (ADelim[1] = '_') and (I > 1) and IsWordChar(AText[I - 1]) then
      Exit;
    Closing := FindStr(AText, ADelim, I + Length(ADelim));
    if Closing = 0 then
      Exit;
    FlushPlain;
    if ADepth >= MaxInlineDepth then
      Emit(Copy(AText, I + Length(ADelim), Closing - I - Length(ADelim)),
        AStyles, '')
    else
    begin
      Inner := ScanInline(Copy(AText, I + Length(ADelim),
        Closing - I - Length(ADelim)), ADepth + 1);
      AppendStyled(Inner, AStyles);
    end;
    I := Closing + Length(ADelim);
    Result := True;
  end;

begin
  Result := nil;
  N := 0;
  Plain := '';
  I := 1;
  while I <= Length(AText) do
  begin
    { backslash escape of a markup character }
    if (AText[I] = '\') and (I < Length(AText)) and
      (AText[I + 1] in ['\', '`', '*', '_', '~', '[', ']', '(', ')']) then
    begin
      Plain := Plain + AText[I + 1];
      Inc(I, 2);
      Continue;
    end;

    { inline code: verbatim, no nesting }
    if AText[I] = '`' then
    begin
      ClosePos := FindChar(AText, '`', I + 1);
      if ClosePos > 0 then
      begin
        Emit(Copy(AText, I + 1, ClosePos - I - 1), [misCode], '');
        I := ClosePos + 1;
        Continue;
      end;
      Plain := Plain + AText[I];
      Inc(I);
      Continue;
    end;

    { ***bold italic*** / ___bold italic___: tried before ** and * }
    if Copy(AText, I, 3) = '***' then
    begin
      if Paired('***', [misBold, misItalic]) then
        Continue;
      Plain := Plain + '*';
      Inc(I);
      Continue;
    end;
    if Copy(AText, I, 3) = '___' then
    begin
      if Paired('___', [misBold, misItalic]) then
        Continue;
      Plain := Plain + '_';
      Inc(I);
      Continue;
    end;

    { **bold**, __bold__, ~~strike~~; a lone delimiter is literal }
    if Copy(AText, I, 2) = '**' then
    begin
      if Paired('**', [misBold]) then
        Continue;
      Plain := Plain + '*';
      Inc(I);
      Continue;
    end;
    if Copy(AText, I, 2) = '__' then
    begin
      if Paired('__', [misBold]) then
        Continue;
      Plain := Plain + '_';
      Inc(I);
      Continue;
    end;
    if Copy(AText, I, 2) = '~~' then
    begin
      if Paired('~~', [misStrike]) then
        Continue;
      Plain := Plain + '~';
      Inc(I);
      Continue;
    end;

    { *italic* / _italic_ }
    if (AText[I] = '*') or (AText[I] = '_') then
    begin
      if Paired(AText[I], [misItalic]) then
        Continue;
      Plain := Plain + AText[I];
      Inc(I);
      Continue;
    end;

    { [text](url) }
    if AText[I] = '[' then
    begin
      ClosePos := FindChar(AText, ']', I + 1);
      if (ClosePos > 0) and (ClosePos < Length(AText)) and
        (AText[ClosePos + 1] = '(') then
      begin
        UrlStart := ClosePos + 2;
        UrlEnd := FindChar(AText, ')', UrlStart);
        if UrlEnd > 0 then
        begin
          Emit(Copy(AText, I + 1, ClosePos - I - 1), [misLink],
            Copy(AText, UrlStart, UrlEnd - UrlStart));
          I := UrlEnd + 1;
          Continue;
        end;
      end;
    end;

    Plain := Plain + AText[I];
    Inc(I);
  end;
  FlushPlain;
end;

function InlineSpans(const AText: UnicodeString): TMdSpanArray;
begin
  Result := ScanInline(AText, 0);
end;

{ Turn one row line into exactly ACount inline-parsed cells, padding short rows
  with empty cells and dropping any beyond ACount. }
function TableRowCells(const ALine: UnicodeString; ACount: Integer): TMdTableRow;
var
  Cells: TUnicodeStringArray;
  I: Integer;
begin
  Result := nil;
  Cells := SplitCells(ALine);
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    if I <= High(Cells) then
      Result[I] := InlineSpans(CollapseWhitespace(Cells[I]))
    else
      Result[I] := nil;
end;

{ --- TMarkdownParser ----------------------------------------------------- }

constructor TMarkdownParser.Create;
begin
  inherited Create;
  Reset;
end;

destructor TMarkdownParser.Destroy;
begin
  inherited Destroy;
end;

procedure TMarkdownParser.Reset;
begin
  FFinalized := nil;
  FPartial := '';
  ResetOpen;
end;

procedure TMarkdownParser.ResetOpen;
begin
  FOpen := False;
  FKind := mbBlank;
  FTail := '';
  FFenceChar := #0;
  FLanguage := '';
end;

procedure TMarkdownParser.AddBlock(const ABlock: TMdBlock);
begin
  SetLength(FFinalized, Length(FFinalized) + 1);
  FFinalized[High(FFinalized)] := ABlock;
end;

procedure TMarkdownParser.AppendTailLine(const ALine: UnicodeString);
begin
  if FTail <> '' then
    FTail := FTail + #10;
  FTail := FTail + ALine;
end;

procedure TMarkdownParser.FinalizeTail;
var
  Lines: TUnicodeStringArray;
  I, Depth, Ordinal, N: Integer;
  Ordered: Boolean;
  B: TMdBlock;
  Text: UnicodeString;
begin
  if not FOpen then
    Exit;
  case FKind of
    mbCodeFence:
      begin
        B := Default(TMdBlock);
        B.Kind := mbCodeFence;
        B.Language := FLanguage;
        SetLength(B.Spans, 1);
        B.Spans[0] := Default(TMdSpan);
        B.Spans[0].Text := DropFirstLine(FTail);
        AddBlock(B);
      end;
    mbTable:
      begin
        { Line 0 is the header, line 1 the delimiter, the rest body rows. }
        Lines := SplitLines(FTail);
        B := Default(TMdBlock);
        B.Kind := mbTable;
        if (Length(Lines) >= 2) and ParseDelimiter(Lines[1], B.Align) then
        begin
          N := Length(B.Align);
          B.Head := TableRowCells(Lines[0], N);
          for I := 2 to High(Lines) do
          begin
            SetLength(B.Rows, Length(B.Rows) + 1);
            B.Rows[High(B.Rows)] := TableRowCells(Lines[I], N);
          end;
        end;
        AddBlock(B);
      end;
    mbQuote:
      begin
        Lines := SplitLines(FTail);
        Depth := 0;
        if Length(Lines) > 0 then
          QuoteDepth(Lines[0], Depth);
        Text := '';
        for I := 0 to High(Lines) do
          Text := Text + ' ' + StripQuote(Lines[I]);
        B := Default(TMdBlock);
        B.Kind := mbQuote;
        B.Level := Depth;
        B.Spans := InlineSpans(CollapseWhitespace(Text));
        AddBlock(B);
      end;
    mbListItem:
      begin
        Lines := SplitLines(FTail);
        for I := 0 to High(Lines) do
          if TrimU(Lines[I]) <> '' then
            if ListMarker(Lines[I], Ordered, Ordinal, Depth) then
            begin
              B := Default(TMdBlock);
              B.Kind := mbListItem;
              B.Level := Depth;
              B.Ordered := Ordered;
              B.Ordinal := Ordinal;
              B.Spans := InlineSpans(
                CollapseWhitespace(StripListMarker(Lines[I])));
              AddBlock(B);
            end;
      end;
  else
    { paragraph (and any unexpected kind) }
    B := Default(TMdBlock);
    B.Kind := mbParagraph;
    B.Spans := InlineSpans(CollapseWhitespace(FTail));
    AddBlock(B);
  end;
  ResetOpen;
end;

procedure TMarkdownParser.ProcessLine(const ALine: UnicodeString);
var
  Level, Depth, Ordinal: Integer;
  Ordered: Boolean;
  FChar: Char;
  Lang: UnicodeString;
  B: TMdBlock;
  Txt: UnicodeString;
  I, J: Integer;
  Aligns: TMdAlignArray;
  Lines: TUnicodeStringArray;
  HeaderLine, Prefix: UnicodeString;
begin
  { Inside a fence, only the closing fence ends it. }
  if FOpen and (FKind = mbCodeFence) then
  begin
    if FenceClose(ALine, FFenceChar) then
      FinalizeTail
    else
      AppendTailLine(ALine);
    Exit;
  end;

  { A row with a pipe continues an open table; anything else ends it. }
  if FOpen and (FKind = mbTable) then
  begin
    if (TrimU(ALine) <> '') and HasUnescapedPipe(ALine) then
    begin
      AppendTailLine(ALine);
      Exit;
    end;
    FinalizeTail;
  end;

  if TrimU(ALine) = '' then
  begin
    if FOpen and (FKind = mbListItem) then
      AppendTailLine(ALine)   { a blank inside a list keeps it open (loose) }
    else
      FinalizeTail;
    Exit;
  end;

  if HeadingLevel(ALine, Level) then
  begin
    FinalizeTail;
    I := 1;
    while (I <= Length(ALine)) and (ALine[I] = ' ') do
      Inc(I);
    while (I <= Length(ALine)) and (ALine[I] = '#') do
      Inc(I);
    Txt := TrimU(Copy(ALine, I, Length(ALine)));
    J := Length(Txt);
    while (J > 0) and (Txt[J] = '#') do
      Dec(J);
    if (J < Length(Txt)) and ((J = 0) or (Txt[J] = ' ')) then
      Txt := TrimU(Copy(Txt, 1, J));
    B := Default(TMdBlock);
    B.Kind := mbHeading;
    B.Level := Level;
    B.Spans := InlineSpans(CollapseWhitespace(Txt));
    AddBlock(B);
    Exit;
  end;

  if IsRule(ALine) then
  begin
    FinalizeTail;
    B := Default(TMdBlock);
    B.Kind := mbRule;
    AddBlock(B);
    Exit;
  end;

  if FenceOpen(ALine, FChar, Lang) then
  begin
    FinalizeTail;
    FOpen := True;
    FKind := mbCodeFence;
    FFenceChar := FChar;
    FLanguage := Lang;
    AppendTailLine(ALine);
    Exit;
  end;

  if ListMarker(ALine, Ordered, Ordinal, Depth) then
  begin
    if not (FOpen and (FKind = mbListItem)) then
    begin
      FinalizeTail;
      FOpen := True;
      FKind := mbListItem;
    end;
    AppendTailLine(ALine);
    Exit;
  end;

  if QuoteDepth(ALine, Depth) then
  begin
    if not (FOpen and (FKind = mbQuote)) then
    begin
      FinalizeTail;
      FOpen := True;
      FKind := mbQuote;
    end;
    AppendTailLine(ALine);
    Exit;
  end;

  { A delimiter row after a paragraph's last line opens a table. The last line
    becomes the header; earlier lines of the paragraph finalise on their own. }
  if FOpen and (FKind = mbParagraph) and ParseDelimiter(ALine, Aligns) then
  begin
    Lines := SplitLines(FTail);
    HeaderLine := Lines[High(Lines)];
    if HasUnescapedPipe(HeaderLine) and
      (Length(SplitCells(HeaderLine)) = Length(Aligns)) then
    begin
      if Length(Lines) > 1 then
      begin
        Prefix := '';
        for I := 0 to High(Lines) - 1 do
        begin
          if Prefix <> '' then
            Prefix := Prefix + #10;
          Prefix := Prefix + Lines[I];
        end;
        B := Default(TMdBlock);
        B.Kind := mbParagraph;
        B.Spans := InlineSpans(CollapseWhitespace(Prefix));
        AddBlock(B);
      end;
      FKind := mbTable;
      FTail := HeaderLine;
      AppendTailLine(ALine);
      Exit;
    end;
  end;

  if not (FOpen and (FKind = mbParagraph)) then
  begin
    FinalizeTail;
    FOpen := True;
    FKind := mbParagraph;
  end;
  AppendTailLine(ALine);
end;

procedure TMarkdownParser.Feed(const AText: string; AAtEof: Boolean);
var
  S, Line: UnicodeString;
  P: Integer;
begin
  S := FPartial + UnicodeString(AText);
  FPartial := '';
  P := Pos(#10, S);
  while P > 0 do
  begin
    Line := Copy(S, 1, P - 1);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    ProcessLine(Line);
    S := Copy(S, P + 1, Length(S));
    P := Pos(#10, S);
  end;
  if AAtEof then
  begin
    if S <> '' then
    begin
      if S[Length(S)] = #13 then
        SetLength(S, Length(S) - 1);
      ProcessLine(S);
    end;
    FinalizeTail;
  end
  else
    FPartial := S;
end;

function TMarkdownParser.Parse(const AText: string): TMdBlockArray;
begin
  Reset;
  Feed(AText, True);
  Result := Blocks;
end;

procedure TMarkdownParser.Append(const AChunk: string);
begin
  Feed(AChunk, False);
end;

procedure TMarkdownParser.Finish;
begin
  if FPartial <> '' then
  begin
    ProcessLine(FPartial);
    FPartial := '';
  end;
  FinalizeTail;
end;

function TMarkdownParser.Blocks: TMdBlockArray;
var
  B: TMdBlock;
  Raw: UnicodeString;
begin
  Result := FFinalized;
  { The open block is not parsed: it is shown as plain text until it closes. The
    pending partial line is included, so a streamed line shows before its
    newline arrives. }
  Raw := TailText;
  if Raw <> '' then
  begin
    B := Default(TMdBlock);
    B.Kind := mbParagraph;
    SetLength(B.Spans, 1);
    B.Spans[0] := Default(TMdSpan);
    B.Spans[0].Text := Raw;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := B;
  end;
end;

function TMarkdownParser.FinalizedCount: Integer;
begin
  Result := Length(FFinalized);
end;

function TMarkdownParser.FinalizedBlock(AIndex: Integer): TMdBlock;
begin
  if (AIndex >= 0) and (AIndex < Length(FFinalized)) then
    Result := FFinalized[AIndex]
  else
    Result := Default(TMdBlock);
end;

function TMarkdownParser.TailText: UnicodeString;
begin
  Result := FTail;
  if FPartial <> '' then
    if Result <> '' then
      Result := Result + #10 + FPartial
    else
      Result := FPartial;
end;

function ParseMarkdown(const AText: string): TMdBlockArray;
var
  Parser: TMarkdownParser;
begin
  Parser := TMarkdownParser.Create;
  try
    Result := Parser.Parse(AText);
  finally
    Parser.Free;
  end;
end;

end.
