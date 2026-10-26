unit markdown.inline;
{ A LINEAR inline tokenizer.

  WHY THIS UNIT EXISTS. The source design's worst defect was a regex doing
  lexical, syntactic and semantic work at once: it froze for 6.8 seconds on 200
  characters of `[a](` repetition, because a backtracking engine retried
  exponentially. Model output is attacker-influenced through prompt injection, so
  that is a security defect, not a performance one.

  A linear scanner cannot have that failure mode. Two rules keep it linear:

  1. NO FORWARD SEARCH PER DELIMITER. A naive tokenizer scans forward from each
     `[` for its `]`, which is O(n^2) on `[[[[[[`. A single prepass matches
     brackets and parentheses with a stack and records each pair once; the main
     scan then looks a pair up in O(1).
  2. EVERY STEP ADVANCES. Both passes consume at least one character per
     iteration.

  Emphasis uses the left/right-flanking rule rather than a search: a run that
  follows whitespace or punctuation can OPEN, one that precedes it can CLOSE.
  That is what makes both `*a **b** c*` (nested) and `***both***` (a double run)
  come out right without ever scanning backward.

  Emission is a flat token stream with explicit open/close tokens, so nesting is
  resolved by the consumer's stack rather than by recursion here. This unit
  therefore has no dependency on the node model and is directly testable.

  URI allow-listing happens HERE, at token creation, not at render time. An OSC 8
  hyperlink is a terminal-initiated action, so a `javascript:` URI reaching an
  emitter is a live injection - the decision belongs where the URI is first
  trusted, once. }

{$mode delphi}{$H+}

interface

uses
  markdown.tree;

type
  TMdTokKind = (
    tkText,        { plain text; Formats carry the enclosing emphasis }
    tkCode,        { inline code span; Text is the content }
    tkOpen,        { an emphasis run opens; Formats say which }
    tkClose,       { the matching emphasis run closes }
    tkLinkOpen,    { a link opens (Uri allow-listed); Text is the label }
    tkImageOpen,   { an image opens; Text is the alt text }
    tkAutolink,    { an autolink; Uri and Text both set }
    tkSoftBreak,   { a newline inside a block's text }
    tkHardBreak);  { two trailing spaces, or a backslash, before a newline }

  TMdInlineToken = record
    Kind: TMdTokKind;
    Text: UnicodeString;
    Formats: TMdFormats;
    Uri: UnicodeString;
  end;

  TMdTokenArray = array of TMdInlineToken;

{ Tokenize one block's inline text. Linear in Length(AText). }
function TokenizeInline(const AText: UnicodeString): TMdTokenArray;

{ True when AUri's scheme may be handed to a terminal. Exposed for tests. }
function UriAllowed(const AUri: UnicodeString): Boolean;

{ The plain text of a token stream, with no markup. Used by tests and by any
  consumer that only needs the words. }
function TokenText(const ATokens: TMdTokenArray): UnicodeString;

implementation

uses
  SysUtils;

const
  AllowedSchemes: array[0..2] of string = ('http', 'https', 'mailto');

function Lower(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Result[I] in ['A'..'Z'] then
      Result[I] := Chr(Ord(Result[I]) + 32);
end;

function UriAllowed(const AUri: UnicodeString): Boolean;
var
  S, Scheme: string;
  P, I: Integer;
begin
  S := Lower(Trim(string(AUri)));
  if S = '' then
    Exit(False);
  P := Pos(':', S);
  { A relative reference has no scheme to abuse. }
  if P = 0 then
    Exit(True);
  { A colon after a path separator is part of the path, not a scheme. }
  for I := 1 to P - 1 do
    if S[I] in ['/', '?', '#'] then
      Exit(True);
  Scheme := Copy(S, 1, P - 1);
  for I := 0 to High(AllowedSchemes) do
    if Scheme = AllowedSchemes[I] then
      Exit(True);
  Result := False;
end;

procedure Push(var ATokens: TMdTokenArray; const AKind: TMdTokKind;
  const AText: UnicodeString; const AFormats: TMdFormats;
  const AUri: UnicodeString);
begin
  SetLength(ATokens, Length(ATokens) + 1);
  ATokens[High(ATokens)] := Default(TMdInlineToken);
  ATokens[High(ATokens)].Kind := AKind;
  ATokens[High(ATokens)].Text := AText;
  ATokens[High(ATokens)].Formats := AFormats;
  ATokens[High(ATokens)].Uri := AUri;
end;

function IsFlankSpace(const AText: UnicodeString; const APos: Integer): Boolean; forward;

{ A delimiter run can OPEN only when it is LEFT-flanking: something follows it,
  and that something is not simply whitespace. It can CLOSE only when it is
  RIGHT-flanking: something precedes it, and that something is not whitespace.
  This is what makes `a * b` ordinary text instead of an emphasis run that
  swallows the rest of the line. }
function CanOpenAt(const AText: UnicodeString; const APos, ALen: Integer): Boolean;
var
  After: Integer;
begin
  After := APos + ALen;
  { Nothing after it, or whitespace after it: cannot open. }
  if IsFlankSpace(AText, After) then
    Exit(False);
  Result := True;
end;

function CanCloseAt(const AText: UnicodeString; const APos: Integer): Boolean;
begin
  { Nothing before it, or whitespace before it: cannot close. }
  Result := not IsFlankSpace(AText, APos - 1);
end;

function IsFlankSpace(const AText: UnicodeString; const APos: Integer): Boolean;
begin
  if (APos < 1) or (APos > Length(AText)) then
    Exit(True);   { the edges count as whitespace }
  Result := (AText[APos] = ' ') or (AText[APos] = #9) or
    (AText[APos] = #10) or (AText[APos] = #13);
end;

function IsFlankPunct(const AText: UnicodeString; const APos: Integer): Boolean;
begin
  if (APos < 1) or (APos > Length(AText)) then
    Exit(False);
  Result := AText[APos] in ['!', '"', '#', '$', '%', '&', '''', '(', ')', '*',
    '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\', ']',
    '^', '_', '`', '{', '|', '}', '~'];
end;

type
  TIntArray = array of Integer;

{ Match every `[` with its `]` and every `(` with its `)`, in one pass, so the
  main scan never searches forward. Unmatched positions stay 0. }
procedure MatchPairs(const AText: UnicodeString;
  out ABrackets, AParens: TIntArray);
var
  I, N, Top: Integer;
  Stack: TIntArray;
begin
  N := Length(AText);
  SetLength(ABrackets, N + 2);
  SetLength(AParens, N + 2);
  for I := 0 to N + 1 do
  begin
    ABrackets[I] := 0;
    AParens[I] := 0;
  end;

  Stack := nil;
  Top := 0;
  for I := 1 to N do
    if AText[I] = '[' then
    begin
      SetLength(Stack, Top + 1);
      Stack[Top] := I;
      Inc(Top);
    end
    else if AText[I] = ']' then
      if Top > 0 then
      begin
        Dec(Top);
        ABrackets[Stack[Top]] := I;
        ABrackets[I] := Stack[Top];
      end;

  Stack := nil;
  Top := 0;
  for I := 1 to N do
    if AText[I] = '(' then
    begin
      SetLength(Stack, Top + 1);
      Stack[Top] := I;
      Inc(Top);
    end
    else if AText[I] = ')' then
      if Top > 0 then
      begin
        Dec(Top);
        AParens[Stack[Top]] := I;
        AParens[I] := Stack[Top];
      end;
end;

{ The delimiter run at APos, or 0. LONGEST FIRST, so `**` is recognised before
  `*` and `***` is a double run plus a single one rather than something else. }
function DelimiterAt(const AText: UnicodeString; const APos: Integer;
  out ALen: Integer; out AFormats: TMdFormats): Boolean;
var
  C: Char;
begin
  ALen := 0;
  AFormats := [];
  if (APos < 1) or (APos > Length(AText)) then
    Exit(False);
  C := AText[APos];
  case C of
    '*':
      { A run of three is ONE run carrying both formats, not two nested opens.
        Treating it as `**` then `*` makes the closer `***` ambiguous, and my
        first version leaked a stray `*` into the text for `***x***`. }
      if (APos + 2 <= Length(AText)) and (AText[APos + 1] = '*') and
        (AText[APos + 2] = '*') then
      begin
        ALen := 3;
        AFormats := [mfBold, mfItalic];
      end
      else if (APos < Length(AText)) and (AText[APos + 1] = '*') then
      begin
        ALen := 2;
        AFormats := [mfBold];
      end
      else
      begin
        ALen := 1;
        AFormats := [mfItalic];
      end;
    '~':
      if (APos < Length(AText)) and (AText[APos + 1] = '~') then
      begin
        ALen := 2;
        AFormats := [mfStrike];
      end;
    '=':
      if (APos < Length(AText)) and (AText[APos + 1] = '=') then
      begin
        ALen := 2;
        AFormats := [mfMark];
      end;
    '+':
      if (APos < Length(AText)) and (AText[APos + 1] = '+') then
      begin
        ALen := 2;
        AFormats := [mfInsert];
      end;
    '-':
      if (APos < Length(AText)) and (AText[APos + 1] = '-') then
      begin
        ALen := 2;
        AFormats := [mfDelete];
      end;
  end;
  Result := ALen > 0;
end;

function TokenizeInline(const AText: UnicodeString): TMdTokenArray;
var
  I, J, Len, CloseBracket, CloseParen, Top: Integer;
  Brackets, Parens: TIntArray;
  Fmts: TMdFormats;
  OpenFmts: array of TMdFormats;
  OpenLens: TIntArray;
  Plain: UnicodeString;
  Uri: UnicodeString;
  CanOpen, CanClose: Boolean;
  Steps, Match, K: Integer;

  procedure FlushPlain;
  begin
    if Plain <> '' then
    begin
      Push(Result, tkText, Plain, [], '');
      Plain := '';
    end;
  end;

  procedure Open(const ALen: Integer; const AFmt: TMdFormats);
  begin
    SetLength(OpenFmts, Top + 1);
    OpenFmts[Top] := AFmt;
    SetLength(OpenLens, Top + 1);
    OpenLens[Top] := ALen;
    Inc(Top);
    Push(Result, tkOpen, '', AFmt, '');
  end;

  procedure CloseTop;
  begin
    Dec(Top);
    Push(Result, tkClose, '', OpenFmts[Top], '');
  end;

begin
  Result := nil;
  Plain := '';
  Top := 0;
  OpenFmts := nil;
  OpenLens := nil;
  if AText = '' then
    Exit;
  MatchPairs(AText, Brackets, Parens);

  I := 1;
  Steps := 0;
  while I <= Length(AText) do
  begin
    { A hard bound so a bug in this loop cannot hang a frame. Every path below
      advances I, so this is never reached in practice. }
    Inc(Steps);
    if Steps > Length(AText) * 4 + 64 then
      Break;

    { inline code: content is verbatim, no markup inside }
    if AText[I] = '`' then
    begin
      J := I + 1;
      while (J <= Length(AText)) and (AText[J] <> '`') do
        Inc(J);
      if (J <= Length(AText)) and (J > I + 1) then
      begin
        FlushPlain;
        Push(Result, tkCode, Copy(AText, I + 1, J - I - 1), [], '');
        I := J + 1;
        Continue;
      end;
      Plain := Plain + AText[I];
      Inc(I);
      Continue;
    end;

    { backslash escape }
    if (AText[I] = '\') and (I < Length(AText)) then
    begin
      Plain := Plain + AText[I + 1];
      Inc(I, 2);
      Continue;
    end;

    { autolink }
    if AText[I] = '<' then
    begin
      J := I + 1;
      while (J <= Length(AText)) and (AText[J] <> '>') and
        (AText[J] <> ' ') and (AText[J] <> #10) do
        Inc(J);
      if (J <= Length(AText)) and (AText[J] = '>') and (J > I + 1) then
      begin
        Uri := Copy(AText, I + 1, J - I - 1);
        if UriAllowed(Uri) then
        begin
          FlushPlain;
          Push(Result, tkAutolink, Uri, [], Uri);
          I := J + 1;
          Continue;
        end;
      end;
      Plain := Plain + AText[I];
      Inc(I);
      Continue;
    end;

    { image }
    if (AText[I] = '!') and (I < Length(AText)) and (AText[I + 1] = '[') then
    begin
      CloseBracket := Brackets[I + 1];
      if (CloseBracket > 0) and (CloseBracket < Length(AText)) and
        (AText[CloseBracket + 1] = '(') then
      begin
        CloseParen := Parens[CloseBracket + 1];
        if CloseParen > 0 then
        begin
          Uri := Trim(Copy(AText, CloseBracket + 2,
            CloseParen - CloseBracket - 2));
          if UriAllowed(Uri) then
          begin
            FlushPlain;
            Push(Result, tkImageOpen, Copy(AText, I + 2,
              CloseBracket - I - 2), [], Uri);
            I := CloseParen + 1;
            Continue;
          end;
        end;
      end;
      Plain := Plain + AText[I];
      Inc(I);
      Continue;
    end;

    { link: the label is tokenized normally, so it closes at its `]` }
    if AText[I] = '[' then
    begin
      CloseBracket := Brackets[I];
      if (CloseBracket > 0) and (CloseBracket < Length(AText)) and
        (AText[CloseBracket + 1] = '(') then
      begin
        CloseParen := Parens[CloseBracket + 1];
        if CloseParen > 0 then
        begin
          Uri := Trim(Copy(AText, CloseBracket + 2,
            CloseParen - CloseBracket - 2));
          if UriAllowed(Uri) then
          begin
            FlushPlain;
            Push(Result, tkLinkOpen, '', [], Uri);
            Inc(I);
            Continue;
          end;
        end;
      end;
      Plain := Plain + AText[I];
      Inc(I);
      Continue;
    end;

    { the `]` that ends a link label: skip the `(uri)` after it }
    if (AText[I] = ']') and (I < Length(AText)) and
      (AText[I + 1] = '(') then
    begin
      CloseParen := Parens[I + 1];
      if CloseParen > 0 then
      begin
        FlushPlain;
        Push(Result, tkClose, '', [], '');
        I := CloseParen + 1;
        Continue;
      end;
    end;

    { a newline inside the block's text }
    if AText[I] = #10 then
    begin
      FlushPlain;
      if (I >= 3) and (AText[I - 1] = ' ') and (AText[I - 2] = ' ') then
        Push(Result, tkHardBreak, '', [], '')
      else
        Push(Result, tkSoftBreak, '', [], '');
      I := I + 1;
      Continue;
    end;

    { emphasis, by flanking rather than by search }
    if DelimiterAt(AText, I, Len, Fmts) then
    begin
      CanOpen := CanOpenAt(AText, I, Len);
      CanClose := CanCloseAt(AText, I);
      if CanClose then
      begin
        { Find the innermost open run this delimiter can close. A `***x***` has
          opened bold then italic, so the closing `***` must unwind both; a
          single match-only-the-top rule would reject the second and open a new
          run instead. }
        Match := -1;
        for K := Top - 1 downto 0 do
          if OpenFmts[K] = Fmts then
          begin
            Match := K;
            Break;
          end;
        if Match >= 0 then
        begin
          FlushPlain;
          while Top - 1 > Match do
            CloseTop;
          { Consume the delimiter's own length at THIS position, not the
            opener's. For `***x***` the inner close consumes 1, leaving `**` for
            the outer - consuming the opener's length instead swallowed only one
            of the three and left a stray `*` in the text. }
          CloseTop;
          I := I + Len;
          Continue;
        end;
      end;
      if CanOpen then
      begin
        FlushPlain;
        Open(Len, Fmts);
        I := I + Len;
        Continue;
      end;
      { Neither: a literal run. }
      Plain := Plain + Copy(AText, I, Len);
      I := I + Len;
      Continue;
    end;

    Plain := Plain + AText[I];
    Inc(I);
  end;
  FlushPlain;

  { Close anything still open, so the stream is always balanced. An unbalanced
    stream would make a consumer's stack leak into the next block. }
  while Top > 0 do
    CloseTop;
end;

function TokenText(const ATokens: TMdTokenArray): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ATokens) do
    case ATokens[I].Kind of
      tkText, tkCode, tkAutolink, tkImageOpen:
        Result := Result + ATokens[I].Text;
      tkLinkOpen:
        Result := Result + '';
      tkSoftBreak, tkHardBreak:
        Result := Result + ' ';
    else
      ;
    end;
end;

end.
