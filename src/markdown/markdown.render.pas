unit markdown.render;
{ AST -> plain text. No styling characters, no colour, no theme, no terminal.

  It exists for two reasons (SPEC 4.5): it is the cheapest proof that the AST is
  consumable without a terminal, and it gives tests a diffable failure message.
  It is not the TUI's renderer - tui.widgets.markdownview draws blocks with
  colour, glyphs and a code backdrop, and wraps using real display width.

  Two deliberate approximations, both because this unit may not depend on tui.*
  (SPEC 4.4: width is a terminal concern, and the module compiles against the
  RTL alone):

  1. WIDTH IS CODEPOINTS, NOT CELLS. A CJK glyph or a combining mark is one
     unit here and two-or-zero cells in a terminal, so wrapping here is
     approximate on purpose. Anything that must line up on screen wraps in the
     viewer with tui.grapheme.
  2. NO SYMBOL SUBSTITUTION. A bullet is '- ', an ordered item keeps the marker
     it was written with, a rule is '---'. No box drawing.

  Fenced code is emitted verbatim and never re-wrapped: a fence's line breaks
  are content, not layout. }

{$mode delphi}{$H+}

interface

uses
  markdown.types, markdown.tree;

type
  TMdLineArray = array of string;

{ Render every block to width-wrapped plain lines. AWidth <= 0 means "do not
  wrap" (one output line per logical line). This is the v1 flat-block form; it
  stays until the TUI's compat adapter is deleted (v2 TODO, Phase 7). }
function RenderPlain(const ABlocks: TMdBlockArray; AWidth: Integer): TMdLineArray;

{ The same, over the v2 node tree. The document's frontmatter is NOT rendered:
  it is metadata, not body (v2 SPEC 10.3), and painting it into the output is the
  mistake that decision exists to prevent. }
function RenderTree(const ADoc: TMdDocument; AWidth: Integer): TMdLineArray;

implementation

uses
  SysUtils;

type
  { FPC does not accept an anonymous `array of Integer` as a function result, so
    the column widths need a name. }
  TMdWidthArray = array of Integer;

{ StringOfChar returns an AnsiString in this build, and the implicit conversion
  to UnicodeString is a warning-as-error under -Sew. The input is ASCII, so an
  explicit conversion is safe. }
function Rep(const ACh: Char; ACount: Integer): UnicodeString;
begin
  if ACount <= 0 then
    Exit('');
  Result := UnicodeString(StringOfChar(ACh, ACount));
end;

function U8(const S: UnicodeString): string;
begin
  { Explicit: the implicit conversion writes '?' for non-ASCII on this build. }
  Result := UTF8Encode(S);
end;

function IsSpaceU(const AText: UnicodeString; AIndex: Integer): Boolean;
begin
  Result := (AText[AIndex] = ' ') or (AText[AIndex] = #9) or
    (AText[AIndex] = #10) or (AText[AIndex] = #13);
end;

{ Collapse whitespace runs to one space and trim the edges. }
function Collapse(const S: UnicodeString): UnicodeString;
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

procedure AddLine(var ALines: TMdLineArray; const AText: UnicodeString);
begin
  SetLength(ALines, Length(ALines) + 1);
  ALines[High(ALines)] := U8(AText);
end;

{ A blank line between blocks, collapsed: never two in a row, never leading. }
procedure AddBlank(var ALines: TMdLineArray);
begin
  if (Length(ALines) > 0) and (ALines[High(ALines)] <> '') then
    AddLine(ALines, '');
end;

{ Greedy word wrap. AWidth <= 0 emits the collapsed text as one line. A word
  longer than the width is hard-broken rather than allowed to overflow. }
procedure WrapInto(const AText: UnicodeString; AWidth: Integer;
  var ALines: TMdLineArray);
var
  S, Word, Line: UnicodeString;
  I: Integer;

  procedure Flush;
  begin
    if Line <> '' then
      AddLine(ALines, Line);
    Line := '';
  end;

  procedure Take(const AWord: UnicodeString);
  var
    W: UnicodeString;
  begin
    W := AWord;
    while (AWidth > 0) and (Length(W) > AWidth) do
    begin
      Flush;
      AddLine(ALines, Copy(W, 1, AWidth));
      W := Copy(W, AWidth + 1, Length(W));
    end;
    if W = '' then
      Exit;
    if Line = '' then
      Line := W
    else if (AWidth > 0) and (Length(Line) + 1 + Length(W) > AWidth) then
    begin
      Flush;
      Line := W;
    end
    else
      Line := Line + ' ' + W;
  end;

begin
  S := Collapse(AText);
  Line := '';
  if S = '' then
  begin
    AddLine(ALines, '');
    Exit;
  end;
  I := 1;
  while I <= Length(S) do
  begin
    while (I <= Length(S)) and (S[I] = ' ') do
      Inc(I);
    Word := '';
    while (I <= Length(S)) and (S[I] <> ' ') do
    begin
      Word := Word + S[I];
      Inc(I);
    end;
    if Word <> '' then
      Take(Word);
  end;
  Flush;
end;

function SpanText(const ASpans: TMdSpanArray): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ASpans) do
    Result := Result + ASpans[I].Text;
end;

{ One table row's cells joined with no padding: only used when a block claims to
  be a table but carries no delimiter row, so there is no layout to honour. }
function RowText(const ARow: TMdTableRow): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ARow) do
  begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + SpanText(ARow[I]);
  end;
end;

function CellAt(const ARow: TMdTableRow; AIndex: Integer): UnicodeString;
begin
  if (AIndex >= 0) and (AIndex <= High(ARow)) then
    Result := SpanText(ARow[AIndex])
  else
    Result := '';
end;

function PadTo(const S: UnicodeString; AWidth: Integer; AAlign: TMdAlign): UnicodeString;
var
  Pad, Left: Integer;
begin
  Pad := AWidth - Length(S);
  if Pad <= 0 then
    Exit(S);
  case AAlign of
    maRight: Left := Pad;
    maCenter: Left := Pad div 2;
  else
    Left := 0;
  end;
  Result := Rep(' ', Left) + S + Rep(' ', Pad - Left);
end;

{ The widest cell in each column, over the head and every body row. A column
  with no content still gets width 1 so the delimiter row stays legible. }
function ColumnWidths(const ABlock: TMdBlock): TMdWidthArray;
var
  I, J, N: Integer;
begin
  N := Length(ABlock.Align);
  Result := nil;
  SetLength(Result, N);
  for I := 0 to N - 1 do
    Result[I] := 1;
  for J := 0 to High(ABlock.Head) do
    if (J < N) and (Length(SpanText(ABlock.Head[J])) > Result[J]) then
      Result[J] := Length(SpanText(ABlock.Head[J]));
  for I := 0 to High(ABlock.Rows) do
    for J := 0 to High(ABlock.Rows[I]) do
      if (J < N) and (Length(SpanText(ABlock.Rows[I][J])) > Result[J]) then
        Result[J] := Length(SpanText(ABlock.Rows[I][J]));
end;

procedure EmitRow(const ARow: TMdTableRow; const AAlign: TMdAlignArray;
  const AWidths: TMdWidthArray; var ALines: TMdLineArray);
var
  J: Integer;
  Line, Cell: UnicodeString;
  Align: TMdAlign;
begin
  Line := '';
  for J := 0 to High(AWidths) do
  begin
    if J <= High(AAlign) then
      Align := AAlign[J]
    else
      Align := maNone;
    Cell := PadTo(CellAt(ARow, J), AWidths[J], Align);
    if Line <> '' then
      Line := Line + ' | ';
    Line := Line + Cell;
  end;
  AddLine(ALines, Line);
end;

procedure EmitRule(const AWidths: TMdWidthArray; var ALines: TMdLineArray);
var
  J: Integer;
  Line: UnicodeString;
begin
  Line := '';
  for J := 0 to High(AWidths) do
  begin
    if Line <> '' then
      Line := Line + '-+-';
    Line := Line + Rep('-', AWidths[J]);
  end;
  AddLine(ALines, Line);
end;

procedure RenderTable(const ABlock: TMdBlock; var ALines: TMdLineArray);
var
  Widths: TMdWidthArray;
  I: Integer;
begin
  if Length(ABlock.Align) = 0 then
  begin
    WrapInto(RowText(ABlock.Head), 0, ALines);
    Exit;
  end;
  Widths := ColumnWidths(ABlock);
  EmitRow(ABlock.Head, ABlock.Align, Widths, ALines);
  EmitRule(Widths, ALines);
  for I := 0 to High(ABlock.Rows) do
    EmitRow(ABlock.Rows[I], ABlock.Align, Widths, ALines);
end;

procedure RenderFence(const ABlock: TMdBlock; var ALines: TMdLineArray);
var
  Text: UnicodeString;
  P: Integer;
begin
  Text := SpanText(ABlock.Spans);
  while Text <> '' do
  begin
    P := Pos(#10, Text);
    if P = 0 then
    begin
      AddLine(ALines, Text);
      Break;
    end;
    AddLine(ALines, Copy(Text, 1, P - 1));
    Text := Copy(Text, P + 1, Length(Text));
  end;
end;

procedure RenderListItem(const ABlock: TMdBlock; AWidth: Integer;
  var ALines: TMdLineArray);
var
  Prefix: UnicodeString;
  J: Integer;
  Wrapped: TMdLineArray;
  ContentWidth: Integer;
begin
  Prefix := '';
  for J := 2 to ABlock.Level do
    Prefix := Prefix + '  ';
  if ABlock.Ordered then
    Prefix := Prefix + UnicodeString(IntToStr(ABlock.Ordinal)) + '. '
  else
    Prefix := Prefix + '- ';
  ContentWidth := 0;
  if AWidth > 0 then
  begin
    ContentWidth := AWidth - Length(Prefix);
    if ContentWidth < 1 then
      ContentWidth := 1;
  end;
  Wrapped := nil;
  WrapInto(SpanText(ABlock.Spans), ContentWidth, Wrapped);
  if Length(Wrapped) = 0 then
  begin
    AddLine(ALines, Prefix);
    Exit;
  end;
  for J := 0 to High(Wrapped) do
    if J = 0 then
      AddLine(ALines, Prefix + UnicodeString(Wrapped[J]))
    else
      AddLine(ALines, Rep(' ', Length(Prefix)) + UnicodeString(Wrapped[J]));
end;

procedure RenderQuote(const ABlock: TMdBlock; AWidth: Integer;
  var ALines: TMdLineArray);
var
  Prefix: UnicodeString;
  J: Integer;
  Wrapped: TMdLineArray;
  ContentWidth: Integer;
begin
  Prefix := '';
  for J := 1 to ABlock.Level do
    Prefix := Prefix + '> ';
  ContentWidth := 0;
  if AWidth > 0 then
  begin
    ContentWidth := AWidth - Length(Prefix);
    if ContentWidth < 1 then
      ContentWidth := 1;
  end;
  Wrapped := nil;
  WrapInto(SpanText(ABlock.Spans), ContentWidth, Wrapped);
  for J := 0 to High(Wrapped) do
    AddLine(ALines, Prefix + UnicodeString(Wrapped[J]));
end;

function RenderPlain(const ABlocks: TMdBlockArray; AWidth: Integer): TMdLineArray;
var
  I: Integer;
  B: TMdBlock;
  ConsecutiveList: Boolean;
begin
  Result := nil;
  for I := 0 to High(ABlocks) do
  begin
    B := ABlocks[I];
    { Consecutive list items are one run, so they do not get a blank between
      them; every other block boundary does. }
    ConsecutiveList := (I > 0) and (B.Kind = mbListItem) and
      (ABlocks[I - 1].Kind = mbListItem);
    if (I > 0) and not ConsecutiveList then
      AddBlank(Result);
    case B.Kind of
      mbHeading:
        WrapInto(SpanText(B.Spans), AWidth, Result);
      mbRule:
        AddLine(Result, '---');
      mbCodeFence:
        RenderFence(B, Result);
      mbQuote:
        RenderQuote(B, AWidth, Result);
      mbListItem:
        RenderListItem(B, AWidth, Result);
      mbTable:
        RenderTable(B, Result);
    else
      WrapInto(SpanText(B.Spans), AWidth, Result);
    end;
  end;
end;


{ ==== v2: render the node tree ============================================ }

type
  TTreeRenderer = class
  private
    FDoc: TMdDocument;
    FWidth: Integer;
    FLines: TMdLineArray;
    procedure Emit(const AText: UnicodeString);
    procedure Blank;
    procedure Wrap(const AText: UnicodeString; AAvail: Integer);
    procedure TextRun(const AId: Integer; var ABuf: UnicodeString);
    procedure RenderInline(const AId: Integer);
    procedure RenderBlock(const AId, ADepth: Integer);
    procedure RenderList(const AId, ADepth: Integer);
    procedure RenderQuote(const AId, ADepth: Integer);
    procedure RenderTable(const AId: Integer);
    procedure RenderChildren(const AId, ADepth: Integer);
  public
    constructor Create(const ADoc: TMdDocument; AWidth: Integer);
    function Run: TMdLineArray;
  end;

constructor TTreeRenderer.Create(const ADoc: TMdDocument; AWidth: Integer);
begin
  inherited Create;
  FDoc := ADoc;
  FWidth := AWidth;
  FLines := nil;
end;

procedure TTreeRenderer.Emit(const AText: UnicodeString);
begin
  SetLength(FLines, Length(FLines) + 1);
  FLines[High(FLines)] := U8(AText);
end;

procedure TTreeRenderer.Blank;
begin
  if (Length(FLines) > 0) and (FLines[High(FLines)] <> '') then
    Emit('');
end;

procedure TTreeRenderer.Wrap(const AText: UnicodeString; AAvail: Integer);
var
  Wrapped: TMdLineArray;
  I: Integer;
begin
  Wrapped := nil;
  WrapInto(AText, AAvail, Wrapped);
  for I := 0 to High(Wrapped) do
    Emit(UnicodeString(Wrapped[I]));
end;

{ The plain text of an inline subtree, ignoring formatting. }
{ The plain text of an inline subtree.

  This delegates to markdown.tree's InlineSpansOf rather than walking the tree
  itself. It used to be a SECOND copy of that projection, and the copies drifted:
  InlineSpansOf was fixed to descend into a formatted run's wrapper and this one
  was not, so every bold and italic word silently vanished from rendered output
  until a test caught it. One projection, one fix. }
procedure TTreeRenderer.TextRun(const AId: Integer; var ABuf: UnicodeString);
var
  Spans: TMdSpanArray;
  I: Integer;
begin
  Spans := InlineSpansOf(FDoc, AId);
  for I := 0 to High(Spans) do
    ABuf := ABuf + Spans[I].Text;
end;

procedure TTreeRenderer.RenderInline(const AId: Integer);
var
  Buf: UnicodeString;
begin
  Buf := '';
  TextRun(AId, Buf);
  if Buf <> '' then
    Wrap(Buf, FWidth);
end;

procedure TTreeRenderer.RenderList(const AId, ADepth: Integer);
var
  N, Item, Block: TMdNode;
  I, J: Integer;
  Pad, Marker, Buf: UnicodeString;
  Markered: Boolean;
begin
  N := NodeOf(FDoc, AId);
  for I := 0 to High(N.Children) do
  begin
    Item := NodeOf(FDoc, N.Children[I]);
    if Item.Kind <> mnListItem then
      Continue;
    Pad := '';
    for J := 1 to ADepth do
      Pad := Pad + '  ';
    if N.Style = lsOrdered then
      Marker := Pad + UnicodeString(IntToStr(N.Start)) + '. '
    else
      Marker := Pad + '- ';
    { The item's first paragraph shares the marker's line; further blocks indent
      under it, which is what makes nesting readable. }
    Markered := False;
    for J := 0 to High(Item.Children) do
    begin
      Block := NodeOf(FDoc, Item.Children[J]);
      if (Block.Kind = mnParagraph) and not Markered then
      begin
        Buf := '';
        TextRun(Block.Id, Buf);
        Wrap(Marker + Buf, FWidth);
        Markered := True;
      end
      else
        RenderBlock(Block.Id, ADepth + 1);
    end;
    if not Markered then
      Emit(Marker);
  end;
end;

procedure TTreeRenderer.RenderQuote(const AId, ADepth: Integer);
var
  J: Integer;
  Prefix: UnicodeString;
  Start: Integer;
begin
  Prefix := '';
  for J := 1 to ADepth do
    Prefix := Prefix + '> ';
  Start := Length(FLines);
  RenderChildren(AId, ADepth);
  { Prefix the lines this quote produced. }
  for J := Start to High(FLines) do
    FLines[J] := U8(UnicodeString(Prefix + UnicodeString(FLines[J])));
end;

procedure TTreeRenderer.RenderTable(const AId: Integer);
var
  N, Header, Row: TMdNode;
  I, J: Integer;
  Rows: array of Integer;
  RowCount, ColCount: Integer;
  Widths: TMdWidthArray;
  Line: UnicodeString;

  procedure ConsiderRow(const ARowId: Integer);
  var
    R: TMdNode;
    C: Integer;
    Txt: UnicodeString;
  begin
    R := NodeOf(FDoc, ARowId);
    for C := 0 to High(R.Children) do
      if C < Length(Widths) then
      begin
        Txt := '';
        TextRun(R.Children[C], Txt);
        if Length(Txt) > Widths[C] then
          Widths[C] := Length(Txt);
      end;
  end;

  procedure EmitRow(const ARowId: Integer);
  var
    R: TMdNode;
    C: Integer;
    Txt, Padded: UnicodeString;
  begin
    R := NodeOf(FDoc, ARowId);
    Line := '';
    for C := 0 to ColCount - 1 do
    begin
      Txt := '';
      if C <= High(R.Children) then
        TextRun(R.Children[C], Txt);
      Padded := Txt;
      while Length(Padded) < Widths[C] do
        Padded := Padded + ' ';
      if Line <> '' then
        Line := Line + ' | ';
      Line := Line + Padded;
    end;
    Emit(Line);
  end;

begin
  N := NodeOf(FDoc, AId);
  ColCount := Length(N.Align);
  if ColCount = 0 then
    Exit;
  SetLength(Widths, ColCount);
  for I := 0 to ColCount - 1 do
    Widths[I] := 1;

  { Collect the row ids: one under the header, the rest under the body. }
  SetLength(Rows, 0);
  for I := 0 to High(N.Children) do
  begin
    Header := NodeOf(FDoc, N.Children[I]);
    if Header.Kind in [mnTableHeader, mnTableBody] then
      for J := 0 to High(Header.Children) do
      begin
        Row := NodeOf(FDoc, Header.Children[J]);
        if Row.Kind = mnTableRow then
        begin
          SetLength(Rows, Length(Rows) + 1);
          Rows[High(Rows)] := Row.Id;
        end;
      end;
  end;
  RowCount := Length(Rows);
  if RowCount = 0 then
    Exit;
  for I := 0 to RowCount - 1 do
    ConsiderRow(Rows[I]);

  EmitRow(Rows[0]);
  Line := '';
  for I := 0 to ColCount - 1 do
  begin
    if Line <> '' then
      Line := Line + '-+-';
    Line := Line + Rep('-', Widths[I]);
  end;
  Emit(Line);
  for I := 1 to RowCount - 1 do
    EmitRow(Rows[I]);
end;

procedure TTreeRenderer.RenderBlock(const AId, ADepth: Integer);
var
  N: TMdNode;
  I: Integer;
  Buf: UnicodeString;
  Pad: UnicodeString;
begin
  N := NodeOf(FDoc, AId);
  case N.Kind of
    mnParagraph:
      RenderInline(AId);
    mnHeading:
      RenderInline(AId);
    mnCodeBlock:
      begin
        { Verbatim: a fence's own line breaks are content. }
        Buf := N.Content;
        I := 1;
        while I <= Length(Buf) do
        begin
          if Pos(#10, Copy(Buf, I, Length(Buf))) > 0 then
          begin
            Emit(Copy(Buf, I, Pos(#10, Copy(Buf, I, Length(Buf))) - 1));
            I := I + Pos(#10, Copy(Buf, I, Length(Buf)));
          end
          else
          begin
            Emit(Copy(Buf, I, Length(Buf)));
            Break;
          end;
        end;
        if Buf = '' then
          Emit('');
      end;
    mnHorizontalRule:
      Emit('---');
    mnList:
      RenderList(AId, ADepth);
    mnBlockQuote:
      RenderQuote(AId, ADepth);
    mnTable:
      RenderTable(AId);
    mnHtmlBlock, mnMathBlock:
      { Raw content, emitted as-is and never interpreted. }
      Emit(N.Content);
    mnFootnote:
      begin
        Pad := '';
        for I := 1 to ADepth do
          Pad := Pad + '  ';
        Emit(Pad + '[^' + N.RefLabel + ']:');
        RenderChildren(AId, ADepth + 1);
      end;
    mnCustomBlock:
      RenderChildren(AId, ADepth);
    mnReference:
      { A definition has no visible body. }
      ;
    mnDescriptionList:
      RenderChildren(AId, ADepth);
    mnDescriptionTerm:
      RenderInline(AId);
    mnDescription:
      begin
        Buf := '';
        TextRun(AId, Buf);
        Emit('  ' + Buf);
      end;
  else
    RenderChildren(AId, ADepth);
  end;
end;

procedure TTreeRenderer.RenderChildren(const AId, ADepth: Integer);
var
  N: TMdNode;
  I: Integer;
begin
  N := NodeOf(FDoc, AId);
  for I := 0 to High(N.Children) do
    RenderBlock(N.Children[I], ADepth);
end;

function TTreeRenderer.Run: TMdLineArray;
var
  Root: TMdNode;
  I: Integer;
  Prev, Cur: TMdNodeKind;
begin
  Root := NodeOf(FDoc, FDoc.Root);
  Prev := mnDocument;
  for I := 0 to High(Root.Children) do
  begin
    Cur := NodeOf(FDoc, Root.Children[I]).Kind;
    { A blank between blocks, except between consecutive list items. }
    if (I > 0) and not ((Cur = mnListItem) and (Prev = mnListItem)) and
      (Cur <> mnReference) and (Prev <> mnReference) then
      Blank;
    RenderBlock(Root.Children[I], 1);
    Prev := Cur;
  end;
  Result := FLines;
end;

function RenderTree(const ADoc: TMdDocument; AWidth: Integer): TMdLineArray;
var
  R: TTreeRenderer;
begin
  R := TTreeRenderer.Create(ADoc, AWidth);
  try
    Result := R.Run;
  finally
    R.Free;
  end;
end;

end.
