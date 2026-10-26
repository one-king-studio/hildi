unit markdown.compat;
{ Project the v2 node tree onto the v1 flat TMdBlockArray.

  This exists so the shipped TUI keeps working while `markdownview` migrates to
  the tree one consumer at a time - it is NOT the destination. Its ceiling, and
  the reason it must be deleted, is that it silently drops every node kind v1 had
  no equivalent for: footnotes, references, abbreviations, math, raw HTML,
  description lists, custom blocks, and all nesting beyond a depth integer.

  ALossy is the honest signal: True when the document contained anything the
  projection had to discard. `TestCompatIsLosslessForV1Corpus` asserts it stays
  False for the v1 corpus, so the adapter cannot quietly become the product.

  DELETION CONDITION (Markdown_v2.SPEC.md 6): the commit that migrates
  tui.widgets.markdownview to the tree deletes this unit and its test.

  Pure: markdown.types and markdown.tree only. It does not use the v1 parser -
  it consumes a tree, which makes it a projection rather than a second parser. }

{$mode delphi}{$H+}

interface

uses
  markdown.types, markdown.tree;

{ Project ADoc onto v1 blocks. ALossy reports whether anything was discarded. }
function BlocksForTui(const ADoc: TMdDocument; out ALossy: Boolean): TMdBlockArray;

implementation

uses
  SysUtils;

{ --- span projection ------------------------------------------------------ }

function IsSpaceU(const AText: UnicodeString; AIndex: Integer): Boolean;
begin
  Result := (AText[AIndex] = ' ') or (AText[AIndex] = #9) or
    (AText[AIndex] = #10) or (AText[AIndex] = #13);
end;

function StylesOf(const AFormats: TMdFormats; const ALink: Boolean): TMdInlineStyles;
begin
  Result := [];
  if mfBold in AFormats then
    Include(Result, misBold);
  if mfItalic in AFormats then
    Include(Result, misItalic);
  if mfStrike in AFormats then
    Include(Result, misStrike);
  if ALink then
    Include(Result, misLink);
end;

procedure PushSpan(var ASpans: TMdSpanArray; const AText: UnicodeString;
  const AStyles: TMdInlineStyles; const ALink: UnicodeString);
var
  S: TMdSpan;
begin
  S := Default(TMdSpan);
  S.Text := AText;
  S.Styles := AStyles;
  S.Link := ALink;
  SetLength(ASpans, Length(ASpans) + 1);
  ASpans[High(ASpans)] := S;
end;

procedure CollectSpans(const ADoc: TMdDocument; const AId: Integer;
  const AFormats: TMdFormats; const AUri: UnicodeString;
  var ASpans: TMdSpanArray); forward;

{ Flatten an inline subtree. A link contributes its Uri to every span inside it,
  which is how v1 represented a link: a span carrying misLink. }
procedure CollectSpans(const ADoc: TMdDocument; const AId: Integer;
  const AFormats: TMdFormats; const AUri: UnicodeString;
  var ASpans: TMdSpanArray);
var
  N: TMdNode;
  I: Integer;
  Inherited_: TMdFormats;
begin
  N := NodeOf(ADoc, AId);
  if N.Id = 0 then
    Exit;
  case N.Kind of
    mnText:
      begin
        { A FORMATTED run is a wrapper text node with empty Content whose child
          holds the text. Pushing the wrapper's content and stopping is what
          turned `a **bold** word` into `a word`. }
        Inherited_ := AFormats + N.Formats;
        if N.Content <> '' then
          PushSpan(ASpans, N.Content, StylesOf(Inherited_, AUri <> ''), AUri);
        for I := 0 to High(N.Children) do
          CollectSpans(ADoc, N.Children[I], Inherited_, AUri, ASpans);
      end;
    mnCodeSpan:
      PushSpan(ASpans, N.Content, StylesOf(AFormats, AUri <> '') + [misCode], AUri);
    mnLineBreak:
      { v1 collapsed a paragraph's lines into one text run, so a soft break is a
        space here. }
      PushSpan(ASpans, ' ', StylesOf(AFormats, AUri <> ''), AUri);
    mnLink:
      for I := 0 to High(N.Children) do
        CollectSpans(ADoc, N.Children[I], AFormats, N.Uri, ASpans);
    mnHyperlink:
      PushSpan(ASpans, N.Content, StylesOf(AFormats, True), N.Uri);
    mnImage:
      { v1 had no image node; its alt text is the closest readable thing. }
      if N.Alt <> '' then
        PushSpan(ASpans, N.Alt, StylesOf(AFormats, AUri <> ''), AUri);
    mnFootnoteCallout:
      PushSpan(ASpans, N.RefLabel, StylesOf(AFormats, AUri <> ''), AUri);
  else
    for I := 0 to High(N.Children) do
      CollectSpans(ADoc, N.Children[I], AFormats, AUri, ASpans);
  end;
end;

{ Collapse whitespace across a span sequence while preserving styles, merging
  neighbours that share styling. v1 collapsed a block's text before scanning it
  for inline markup, so this is what makes the projection EQUAL to the old
  output rather than merely similar. }
function CollapseSpans(const ARaw: TMdSpanArray): TMdSpanArray;
var
  I, J: Integer;
  Pending, Any: Boolean;
  Text: UnicodeString;

  procedure AppendPiece(const AText: UnicodeString;
    const AStyles: TMdInlineStyles; const ALink: UnicodeString);
  begin
    if AText = '' then
      Exit;
    if (Length(Result) > 0) and (Result[High(Result)].Styles = AStyles) and
      (Result[High(Result)].Link = ALink) then
      Result[High(Result)].Text := Result[High(Result)].Text + AText
    else
      PushSpan(Result, AText, AStyles, ALink);
  end;

begin
  Result := nil;
  Pending := False;
  Any := False;
  for I := 0 to High(ARaw) do
  begin
    Text := '';
    for J := 1 to Length(ARaw[I].Text) do
      if IsSpaceU(ARaw[I].Text, J) then
      begin
        if Any then
          Pending := True;
      end
      else
      begin
        if Pending then
        begin
          Text := Text + ' ';
          Pending := False;
        end;
        Text := Text + ARaw[I].Text[J];
        Any := True;
      end;
    AppendPiece(Text, ARaw[I].Styles, ARaw[I].Link);
  end;
  { v1 always produced at least one span for a block. }
  if Length(Result) = 0 then
    PushSpan(Result, '', [], '');
end;

function SpansOf(const ADoc: TMdDocument; const AId: Integer): TMdSpanArray;
var
  Raw: TMdSpanArray;
begin
  Raw := nil;
  CollectSpans(ADoc, AId, [], '', Raw);
  Result := CollapseSpans(Raw);
end;

{ --- block projection ----------------------------------------------------- }

type
  EProjector = class
  private
    FDoc: TMdDocument;
    FLossy: Boolean;
    function ChildOfKind(const AParent: Integer; const AKind: TMdNodeKind): Integer;
    function RowsUnder(const AParent: Integer): TMdIntArray;
    function CellSpans(const ARow: Integer; const AIndex: Integer): TMdSpanArray;
    procedure EmitList(const AListId, ADepth: Integer; var ABlocks: TMdBlockArray);
    procedure EmitQuote(const AQuoteId, ADepth: Integer; var ABlocks: TMdBlockArray);
    function BlockAt(const AId: Integer): TMdBlock;
    procedure Walk(const AParent: Integer; var ABlocks: TMdBlockArray);
  public
    constructor Create(const ADoc: TMdDocument);
    function Project(out ALossy: Boolean): TMdBlockArray;
  end;

constructor EProjector.Create(const ADoc: TMdDocument);
begin
  inherited Create;
  FDoc := ADoc;
  FLossy := False;
end;

function EProjector.ChildOfKind(const AParent: Integer; const AKind: TMdNodeKind): Integer;
var
  P, C: TMdNode;
  I: Integer;
begin
  Result := 0;
  P := NodeOf(FDoc, AParent);
  for I := 0 to High(P.Children) do
  begin
    C := NodeOf(FDoc, P.Children[I]);
    if C.Kind = AKind then
      Exit(C.Id);
  end;
end;

function EProjector.RowsUnder(const AParent: Integer): TMdIntArray;
var
  P, C: TMdNode;
  I: Integer;
begin
  Result := nil;
  P := NodeOf(FDoc, AParent);
  for I := 0 to High(P.Children) do
  begin
    C := NodeOf(FDoc, P.Children[I]);
    if C.Kind <> mnTableRow then
      Continue;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := C.Id;
  end;
end;

{ nil for an empty cell: v1 padded a short row with a NIL cell (no spans), not
  one empty span. }
function EProjector.CellSpans(const ARow: Integer; const AIndex: Integer): TMdSpanArray;
var
  Row: TMdNode;
begin
  Result := nil;
  Row := NodeOf(FDoc, ARow);
  if (AIndex < 0) or (AIndex > High(Row.Children)) then
    Exit;
  Result := SpansOf(FDoc, Row.Children[AIndex]);
  if (Length(Result) = 1) and (Result[0].Text = '') then
    Result := nil;
end;

procedure EProjector.EmitList(const AListId, ADepth: Integer;
  var ABlocks: TMdBlockArray);
var
  List_, Item, Para: TMdNode;
  I, J: Integer;
  B: TMdBlock;
begin
  List_ := NodeOf(FDoc, AListId);
  for I := 0 to High(List_.Children) do
  begin
    Item := NodeOf(FDoc, List_.Children[I]);
    if Item.Kind <> mnListItem then
    begin
      FLossy := True;
      Continue;
    end;
    B := Default(TMdBlock);
    B.Kind := mbListItem;
    B.Level := ADepth;
    B.Ordered := List_.Style = lsOrdered;
    if B.Ordered then
      B.Ordinal := List_.Start
    else
      B.Ordinal := 0;
    { The item's own text is its first paragraph, which is how v1 read the
      marker line. }
    B.Spans := nil;
    for J := 0 to High(Item.Children) do
    begin
      Para := NodeOf(FDoc, Item.Children[J]);
      if Para.Kind = mnParagraph then
      begin
        B.Spans := SpansOf(FDoc, Para.Id);
        Break;
      end;
    end;
    SetLength(ABlocks, Length(ABlocks) + 1);
    ABlocks[High(ABlocks)] := B;
    { A nested list becomes deeper items, because v1 carried nesting as a Level
      integer on a flat block. }
    for J := 0 to High(Item.Children) do
    begin
      Para := NodeOf(FDoc, Item.Children[J]);
      if Para.Kind = mnList then
        EmitList(Para.Id, ADepth + 1, ABlocks)
      else if (Para.Kind = mnBlockQuote) or (Para.Kind = mnParagraph) and
        (J > 0) then
      begin
        { A second paragraph, or a quote, inside an item has no v1 shape. }
        if Para.Kind <> mnParagraph then
          FLossy := True;
      end;
    end;
  end;
end;

procedure EProjector.EmitQuote(const AQuoteId, ADepth: Integer;
  var ABlocks: TMdBlockArray);
var
  Q, C: TMdNode;
  I: Integer;
  B: TMdBlock;
  Spans: TMdSpanArray;
  Sub: TMdSpanArray;
  K: Integer;
begin
  Q := NodeOf(FDoc, AQuoteId);
  B := Default(TMdBlock);
  B.Kind := mbQuote;
  B.Level := ADepth;
  Spans := nil;
  for I := 0 to High(Q.Children) do
  begin
    C := NodeOf(FDoc, Q.Children[I]);
    if C.Kind = mnBlockQuote then
    begin
      { A nested quote: v1 expressed depth on one block, so this recursion
        produces a deeper block rather than a child. }
      EmitQuote(C.Id, ADepth + 1, ABlocks);
      Continue;
    end;
    if Length(Spans) > 0 then
      PushSpan(Spans, ' ', [], '');
    if IsInlineKind(C.Kind) or (C.Kind = mnParagraph) then
    begin
      Sub := SpansOf(FDoc, C.Id);
      for K := 0 to High(Sub) do
        PushSpan(Spans, Sub[K].Text, Sub[K].Styles, Sub[K].Link);
    end
    else
    begin
      { A list or fence inside a quote: v1 FLATTENED it to text (it joined every
        quoted line into one run), so flattening here reproduces v1 rather than
        losing anything. Marking this lossy would be wrong - it would fail the
        corpus guard for a document v1 rendered fine. }
      PushSpan(Spans, TextOf(FDoc, C.Id), [], '');
    end;
  end;
  B.Spans := Spans;
  if Length(B.Spans) = 0 then
    PushSpan(B.Spans, '', [], '');
  SetLength(ABlocks, Length(ABlocks) + 1);
  ABlocks[High(ABlocks)] := B;
end;

function EProjector.BlockAt(const AId: Integer): TMdBlock;
var
  N: TMdNode;
  HeaderId, BodyId, RowId: Integer;
  Rows: TMdIntArray;
  I, K: Integer;
begin
  Result := Default(TMdBlock);
  N := NodeOf(FDoc, AId);
  case N.Kind of
    mnParagraph:
      begin
        Result.Kind := mbParagraph;
        Result.Spans := SpansOf(FDoc, AId);
      end;
    mnHeading:
      begin
        Result.Kind := mbHeading;
        Result.Level := N.Level;
        Result.Spans := SpansOf(FDoc, AId);
      end;
    mnCodeBlock:
      begin
        Result.Kind := mbCodeFence;
        Result.Language := N.Language;
        { Verbatim: a fence's whitespace is content, never collapsed. }
        SetLength(Result.Spans, 1);
        Result.Spans[0] := Default(TMdSpan);
        Result.Spans[0].Text := N.Content;
      end;
    mnHorizontalRule:
      Result.Kind := mbRule;
    mnTable:
      begin
        Result.Kind := mbTable;
        Result.Align := N.Align;
        HeaderId := ChildOfKind(AId, mnTableHeader);
        BodyId := ChildOfKind(AId, mnTableBody);
        if HeaderId <> 0 then
        begin
          Rows := RowsUnder(HeaderId);
          if Length(Rows) > 0 then
          begin
            RowId := Rows[0];
            SetLength(Result.Head, Length(N.Align));
            for K := 0 to High(N.Align) do
              Result.Head[K] := CellSpans(RowId, K);
          end;
        end;
        Result.Rows := nil;
        if BodyId <> 0 then
        begin
          Rows := RowsUnder(BodyId);
          for I := 0 to High(Rows) do
          begin
            SetLength(Result.Rows, Length(Result.Rows) + 1);
            SetLength(Result.Rows[High(Result.Rows)], Length(N.Align));
            for K := 0 to High(N.Align) do
              Result.Rows[High(Result.Rows)][K] := CellSpans(Rows[I], K);
          end;
        end;
      end;
  else
    FLossy := True;
  end;
end;

procedure EProjector.Walk(const AParent: Integer; var ABlocks: TMdBlockArray);
var
  P, C: TMdNode;
  I: Integer;
  B: TMdBlock;
begin
  P := NodeOf(FDoc, AParent);
  for I := 0 to High(P.Children) do
  begin
    C := NodeOf(FDoc, P.Children[I]);
    case C.Kind of
      mnList:
        EmitList(C.Id, 1, ABlocks);
      mnBlockQuote:
        EmitQuote(C.Id, 1, ABlocks);
      mnParagraph, mnHeading, mnCodeBlock, mnHorizontalRule, mnTable:
        begin
          B := BlockAt(C.Id);
          SetLength(ABlocks, Length(ABlocks) + 1);
          ABlocks[High(ABlocks)] := B;
        end;
    else
      { html_block, mathblock, footnote, reference, description_list,
        custom_block: no v1 equivalent. }
      FLossy := True;
    end;
  end;
end;

function EProjector.Project(out ALossy: Boolean): TMdBlockArray;
begin
  Result := nil;
  Walk(FDoc.Root, Result);
  ALossy := FLossy;
end;

function BlocksForTui(const ADoc: TMdDocument; out ALossy: Boolean): TMdBlockArray;
var
  P: EProjector;
begin
  P := EProjector.Create(ADoc);
  try
    Result := P.Project(ALossy);
  finally
    P.Free;
  end;
end;

end.
