unit markdown.tree;
{ The full document tree: nodes with identity, nesting and source offsets.

  This is v2 (docs/features/Markdown_Viewer/Markdown_v2.SPEC.md). It replaces the
  flat TMdBlockArray model, which could not express nesting (Level was a depth
  counter), relations (a footnote and its callout) or addressing (there was no
  node identity to point a renderer or an interaction at).

  THE SHAPE, and why: the document is ONE FLAT ARRAY of nodes. `Children` holds
  child ids, not nested records. Nesting a record inside a record copies the whole
  subtree when a consumer asks for one node - the cost that makes a per-frame
  renderer slow. With ids, `NodeOf(Id)` copies one small record. `Parent` is
  stored rather than derived, because "which container is this in" is a constant
  query during render and a linear scan otherwise.

  Ids are document order, from 1, assigned per parse. They are NOT stable across an
  edit - that is what SrcStart/SrcEnd are for. Never persist an id.

  Pure: the RTL only. `make markdown-standalone` proves it.

  Phase 1 scope: the constructs the v1 parser handled, expressed as a tree, plus
  the nesting v1 could not express (list in a list item, blocks in a quote). The
  inline parser here is deliberately minimal and is replaced in Phase 3 by a
  dedicated linear tokenizer. }

{$mode delphi}{$H+}

interface

uses
  markdown.types;

type
  TMdNodeKind = (
    { block }
    mnDocument, mnParagraph, mnHeading, mnCodeBlock, mnBlockQuote,
    mnList, mnListItem, mnTable, mnTableRow, mnTableHeader, mnTableBody,
    mnTableCell, mnHorizontalRule, mnHtmlBlock, mnMathBlock,
    mnDescriptionList, mnDescriptionTerm, mnDescription, mnFootnote,
    mnCustomBlock, mnReference,
    { an EXTENSION, not CommonMark or GFM: a leading `---` fenced block. It is a
      node so a consumer can address it like any other block. }
    mnFrontmatter,
    { inline }
    mnText, mnCodeSpan, mnLineBreak, mnHyperlink, mnLink, mnImage,
    mnHtml, mnMathSpan, mnFootnoteCallout, mnAbbreviation);

  TMdListStyle = (lsOrdered, lsUnordered, lsCheckbox);
  TMdMarker = (lmInteger, lmAlphaLower, lmAlphaUpper, lmRomanLower,
    lmRomanUpper);

  TMdIntArray = array of Integer;

  { One node. Every attribute any kind needs lives in one record so the node stays
    a value type; a zero value means "not applicable". }
  TMdNode = record
    Id: Integer;
    Kind: TMdNodeKind;
    Parent: Integer;            { parent id; 0 for none }
    Children: TMdIntArray;      { child ids, in document order }
    Content: UnicodeString;     { text-ish content; '' for containers }
    Level: Integer;             { heading 1..6 }
    Language: UnicodeString;    { codeblock, mathblock }
    Fenced: Boolean;            { codeblock }
    Style: TMdListStyle;        { list }
    Marker: TMdMarker;          { list }
    Start: Integer;             { list: first ordinal as written }
    Checked: Boolean;           { listitem }
    Uri: UnicodeString;         { link, image, hyperlink, reference }
    Title: UnicodeString;
    Ref: UnicodeString;         { link, image: reference label used }
    RefLabel: UnicodeString;    { footnote, callout, abbreviation, reference }
    Expansion: UnicodeString;   { abbreviation }
    Alt: UnicodeString;         { image }
    Align: TMdAlignArray;       { table }
    CellAlign: TMdAlign;        { table_cell }
    Formats: TMdFormats;        { text }
    Soft: Boolean;              { linebreak: a soft wrap, not a hard break }
    SrcStart, SrcEnd: Integer;  { byte offsets into the source, half open }
  end;

  TMdNodeArray = array of TMdNode;

  { A CLASS, not a record, and that distinction is the whole point of the
    streaming shape.

    TMdNodeArray is a managed (refcounted) dynamic array, so a RECORD document
    handed to a consumer as a copy shares that array. The stream's next SetLength
    would then trigger a full COPY-ON-WRITE of every node - the opposite of "no
    object per update", and invisible because it looks like a cheap assignment.

    As a class there is exactly ONE document object. A stream mutates its Nodes in
    place, and every consumer holding the reference sees the growth. `snapshot` is
    the explicit way to take a stable copy when a consumer needs a consistent read
    rather than a live one. }
  TMdDocument = class
  public
    Nodes: TMdNodeArray;        { index 0 is unused; real ids start at 1 }
    Root: Integer;              { always 1 for a parsed document }
    constructor Create;
    { A deep copy: a separate document a caller may re-parse or mutate without
      touching this one. O(total nodes); use it for a consistent read, not per
      frame. }
    function Snapshot: TMdDocument;
    { Frontmatter is NOT a field: it is a NODE (mnFrontmatter), so it is
      addressable like every other block. Ask FrontmatterOf / FrontmatterText,
      or QueryNodes with a predicate. }
  end;

{ Parse a complete document into a tree. }
function ParseTree(const AText: string): TMdDocument;

{ Parse AText and append its blocks to ADoc under AParent, numbering ids from
  where ADoc left off. This is the STREAMING entry point: a stream closes one
  segment at a time into the SAME document, so there is no temporary tree and no
  merge pass per block. Returns the number of top-level blocks appended. }
function AppendParsed(const ADoc: TMdDocument; const AText: string;
  const AParent: Integer): Integer;

{ A copy of one node, or a zeroed node when AId is out of range. }
function NodeOf(const ADoc: TMdDocument; AId: Integer): TMdNode;

type
  { A predicate over one node. The filter form is what makes a query general
    instead of a growing list of hardcoded selectors: "all footnotes", "all
    headings at level 2", "every code block in a language" are all one call. }
  TMdNodeFilter = function(const ANode: TMdNode): Boolean;
  { A visitor, for callers that want the nodes rather than their ids. A PLAIN
    procedural type, deliberately: `of object` would force every caller to own a
    class just to look at a node. }
  TMdNodeVisitor = procedure(const ANode: TMdNode);

{ Every node matching AFilter, in document order (depth-first from the root).
  Pass ADoc.Root as ASubtree to search a whole document; pass any other id to
  search only that subtree. A nil filter matches every node.

  This is THE way to ask a document for nodes. The named accessors below are
  written in terms of it, so adding a new kind of query costs a predicate rather
  than a new traversal. }
function QueryNodes(const ADoc: TMdDocument; ASubtree: Integer;
  AFilter: TMdNodeFilter): TMdIntArray;

{ Visit every node in a subtree, depth first, in document order. }
procedure WalkNodes(const ADoc: TMdDocument; ASubtree: Integer;
  AVisit: TMdNodeVisitor);

{ The document's frontmatter node id, or 0 when it has none. A NAMED QUERY so a
  consumer asks the root for it rather than walking the tree hoping to find it.
  Frontmatter is an extension (not CommonMark or GFM) and may appear anywhere; this
  returns the first in document order, which is the one a harness treats as the
  document's metadata. }
function FrontmatterOf(const ADoc: TMdDocument): Integer;

{ The frontmatter block's text verbatim, or '' when there is none. The parser does
  NOT parse it as YAML - interpreting it is the consumer's job. }
function FrontmatterText(const ADoc: TMdDocument): UnicodeString;

{ Every node id of one kind, in document order. }
function NodesOfKind(const ADoc: TMdDocument; AKind: TMdNodeKind): TMdIntArray;

{ Footnote DEFINITIONS in document order - the aggregate a consumer needs to
  build a footnote table. Aggregation, not parsing: the nodes are already there. }
function FootnotesOf(const ADoc: TMdDocument): TMdIntArray;

{ Footnote CALLOUTS in document order, i.e. the references in the body. Pairing
  a callout with its definition is by RefLabel and is the consumer's job, exactly
  as interpreting frontmatter YAML is. }
function FootnoteCalloutsOf(const ADoc: TMdDocument): TMdIntArray;

{ The node matching ALabel among footnotes, or 0. }
function FootnoteFor(const ADoc: TMdDocument; const ALabel: UnicodeString): Integer;

{ The number of real nodes (the unused index 0 is not counted). }
function NodeCount(const ADoc: TMdDocument): Integer;

{ The concatenated text of a subtree, depth first. Line breaks become a space. }
function TextOf(const ADoc: TMdDocument; AId: Integer): UnicodeString;

{ Non-whitespace text of a subtree, for comparing renders to parses. }
function SquashedTextOf(const ADoc: TMdDocument; AId: Integer): UnicodeString;

{ The inline content of AId flattened into styled spans - the operation every
  renderer needs ("give me the styled text of this node"). Formatting becomes a
  TMdInlineStyles set, a link carries its Uri on each span inside it, and a soft
  line break becomes a space, all matching what a v1 span consumer expects.

  Kept here rather than in a consumer because it is a pure projection of the
  tree, and a second renderer must not have to reinvent it. }
function InlineSpansOf(const ADoc: TMdDocument; const AId: Integer): TMdSpanArray;

{ A node kind's name, for a test failure message that names the kind. }
function KindName(AKind: TMdNodeKind): string;

function IsInlineKind(AKind: TMdNodeKind): Boolean;

implementation

uses
  SysUtils, markdown.inline;

type
  TStrArray = array of UnicodeString;

  { The builder owns id assignment, so no caller can invent an id.

    Capacity exists so growth is DOUBLING rather than one element at a time.
    `SetLength(Nodes, Length(Nodes) + 1)` reallocs and copies the whole array on
    every node, which is exactly the per-chunk churn a streaming parser must not
    have. With Capacity, appending a block is amortised O(1). }
  TBuilder = record
    Nodes: TMdNodeArray;   { length == capacity, not the node count }
    Count: Integer;        { the number of real nodes; ids are 1..Count-1 }
    procedure Init;
    procedure Add(var ANode: TMdNode; out AId: Integer);
    procedure Append(const AParent, AChild: Integer);
    procedure Reserve(ACount: Integer);
    procedure Adopt(var ADoc: TMdDocument);
  end;

procedure TBuilder.Init;
begin
  Nodes := nil;
  Count := 0;
  Reserve(8);
  { Reserve index 0 so id 0 can mean "none". }
  Nodes[0] := Default(TMdNode);
  Count := 1;
end;

{ Grow geometrically. The array's LENGTH is its capacity and is never used as the
  node count - that is what Count is for. Reusing the buffer between appends is
  the whole point: one realloc per doubling, not one per node. }
procedure TBuilder.Reserve(ACount: Integer);
var
  NewCap: Integer;
begin
  if ACount <= Length(Nodes) then
    Exit;
  NewCap := Length(Nodes);
  if NewCap < 8 then
    NewCap := 8;
  while NewCap < ACount do
    NewCap := NewCap * 2;
  SetLength(Nodes, NewCap);
end;

procedure TBuilder.Add(var ANode: TMdNode; out AId: Integer);
begin
  Reserve(Count + 1);
  AId := Count;
  ANode.Id := AId;
  Nodes[AId] := ANode;
  Inc(Count);
end;

{ Hand the built array back, trimmed so a consumer never sees spare capacity. }
procedure TBuilder.Adopt(var ADoc: TMdDocument);
begin
  SetLength(Nodes, Count);
  ADoc.Nodes := Nodes;
end;

procedure TBuilder.Append(const AParent, AChild: Integer);
var
  N: Integer;
begin
  if (AParent < 1) or (AParent > High(Nodes)) then
    Exit;
  N := Length(Nodes[AParent].Children);
  SetLength(Nodes[AParent].Children, N + 1);
  Nodes[AParent].Children[N] := AChild;
  if (AChild >= 1) and (AChild <= High(Nodes)) then
    Nodes[AChild].Parent := AParent;
end;

function IsInlineKind(AKind: TMdNodeKind): Boolean;
begin
  Result := AKind in [mnText, mnCodeSpan, mnLineBreak, mnHyperlink, mnLink,
    mnImage, mnHtml, mnMathSpan, mnFootnoteCallout, mnAbbreviation];
end;

function KindName(AKind: TMdNodeKind): string;
const
  Names: array[TMdNodeKind] of string = (
    'document', 'paragraph', 'heading', 'codeblock', 'blockquote', 'list',
    'listitem', 'table', 'table_row', 'table_header', 'table_body',
    'table_cell', 'horizontal_rule', 'html_block', 'mathblock',
    'description_list', 'description_term', 'description', 'footnote',
    'custom_block', 'reference', 'frontmatter',
    'text', 'codespan', 'linebreak', 'hyperlink',
    'link', 'image', 'html', 'mathspan', 'footnote_callout', 'abbreviation');
begin
  Result := Names[AKind];
end;

{ --- text helpers --------------------------------------------------------- }

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

type
  { One source line with its byte span in the original UTF-8 text, half open and
    EXCLUDING the line ending. This is what makes SrcStart/SrcEnd real: a node's
    span is its first line's start to its last line's end. }
  TLineSpan = record
    StartByte: Integer;
    EndByte: Integer;
  end;
  TLineSpanArray = array of TLineSpan;

{ Split into lines AND record each line's byte span. Byte offsets are what the
  parser receives, so a consumer can slice the original text. }
procedure SplitLinesEx(const S: UnicodeString; out ALines: TStrArray;
  out ASpans: TLineSpanArray);
var
  P, I, BytePos, LineBytes: Integer;
  Rest, Line: UnicodeString;
  Enc: UTF8String;
begin
  ALines := nil;
  ASpans := nil;
  Rest := S;
  BytePos := 0;
  while True do
  begin
    P := Pos(#10, Rest);
    if P = 0 then
      Line := Rest
    else
      Line := Copy(Rest, 1, P - 1);
    { Tolerate CRLF: the CR is line-ending, not content. }
    if (Length(Line) > 0) and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    SetLength(ALines, Length(ALines) + 1);
    ALines[High(ALines)] := Line;
    { Encoded ONCE per line and summed, so this stays O(total bytes) rather than
      re-encoding the remaining text per line. }
    Enc := UTF8Encode(Line);
    LineBytes := Length(Enc);
    SetLength(ASpans, Length(ASpans) + 1);
    ASpans[High(ASpans)].StartByte := BytePos;
    ASpans[High(ASpans)].EndByte := BytePos + LineBytes;
    { Advance past the line and its #10 (and the #13 that rode along with it). }
    BytePos := BytePos + LineBytes;
    if P = 0 then
      Break;
    if P <= Length(Rest) then
      Inc(BytePos);   { the #10 }
    Rest := Copy(Rest, P + 1, Length(Rest));
  end;
  I := 0;
  I := I;
end;

function SplitLines(const S: UnicodeString): TStrArray;
var
  P, I: Integer;
  Rest, Line: UnicodeString;
begin
  Result := nil;
  Rest := S;
  while True do
  begin
    P := Pos(#10, Rest);
    if P = 0 then
      Line := Rest
    else
      Line := Copy(Rest, 1, P - 1);
    { Tolerate CRLF: the CR is line-ending, not content. }
    if (Length(Line) > 0) and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Line;
    if P = 0 then
      Break;
    Rest := Copy(Rest, P + 1, Length(Rest));
  end;
  I := 0;
  I := I;
end;

{ --- line classifiers ----------------------------------------------------- }

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

{ A setext underline is a CONTINUOUS run of '=' or '-'. No internal spaces: that is
  exactly what keeps `- - -` a thematic break and `= =` ordinary text. }
function SetextLevel(const ALine: UnicodeString; out ALevel: Integer): Boolean;
var
  I, Count: Integer;
  Ch: Char;
  S: UnicodeString;
begin
  ALevel := 0;
  S := TrimU(ALine);
  if S = '' then
    Exit(False);
  Ch := #0;
  Count := 0;
  for I := 1 to Length(S) do
    if S[I] in ['=', '-'] then
    begin
      if Ch = #0 then
        Ch := S[I]
      else if S[I] <> Ch then
        Exit(False);
      Inc(Count);
    end
    else
      Exit(False);
  if Count < 2 then
    Exit(False);
  if Ch = '=' then
    ALevel := 1
  else
    ALevel := 2;
  Result := True;
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
  S, Info: UnicodeString;
  I, Run: Integer;
begin
  AChar := #0;
  ALanguage := '';
  S := TrimU(ALine);
  if S = '' then
    Exit(False);
  if not (S[1] in ['`', '~']) then
    Exit(False);
  AChar := S[1];
  Run := 0;
  I := 1;
  while (I <= Length(S)) and (S[I] = AChar) do
  begin
    Inc(Run);
    Inc(I);
  end;
  if Run < 3 then
    Exit(False);
  Info := Copy(S, I, Length(S));
  { A backtick fence's info string may not contain a backtick, or an inline
    code span would be mistaken for a fence. }
  if (AChar = '`') and (Pos('`', Info) > 0) then
    Exit(False);
  ALanguage := TrimU(Info);
  Result := True;
end;

function FenceClose(const ALine: UnicodeString; AChar: Char): Boolean;
var
  S: UnicodeString;
  I, Run: Integer;
begin
  S := TrimU(ALine);
  Run := 0;
  I := 1;
  while (I <= Length(S)) and (S[I] = AChar) do
  begin
    Inc(Run);
    Inc(I);
  end;
  Result := (Run >= 3) and (TrimU(Copy(S, I, Length(S))) = '');
end;

{ A list marker. AIndent is the leading spaces, ADepth the v1 depth convention
  (1 + indent div 2) kept so the compat adapter can reproduce v1 exactly. }
function ListMarker(const ALine: UnicodeString; out AOrdered: Boolean;
  out AOrdinal, ADepth, AIndent: Integer): Boolean;
var
  I, Num, Digits: Integer;
begin
  AOrdered := False;
  AOrdinal := 0;
  ADepth := 1;
  AIndent := 0;
  I := 1;
  while (I <= Length(ALine)) and (ALine[I] = ' ') do
  begin
    Inc(AIndent);
    Inc(I);
  end;
  if I > Length(ALine) then
    Exit(False);
  if ALine[I] in ['-', '*', '+'] then
  begin
    if (I = Length(ALine)) or (ALine[I + 1] = ' ') then
    begin
      ADepth := (AIndent div 2) + 1;
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
  ADepth := (AIndent div 2) + 1;
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
  { `>` alone is a valid empty quote line - requiring a trailing space made a
    blank quote line terminate the run. }
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

{ `[^label]: ...` - a footnote DEFINITION. The callout is `[^label]`. }
function FootnoteDef(const ALine: UnicodeString; out ALabel,
  AContent: UnicodeString): Boolean;
var
  S: UnicodeString;
  P, Q: Integer;
begin
  ALabel := '';
  AContent := '';
  S := TrimU(ALine);
  if (Length(S) < 5) or (S[1] <> '[') or (S[2] <> '^') then
    Exit(False);
  P := Pos(']:', S);
  if P < 4 then
    Exit(False);
  ALabel := Copy(S, 3, P - 3);
  Q := P + 2;
  AContent := TrimU(Copy(S, Q, Length(S)));
  Result := ALabel <> '';
end;

{ `[label]: uri "title"` - a link reference DEFINITION. }
function ReferenceDef(const ALine: UnicodeString; out ALabel, AUri,
  ATitle: UnicodeString): Boolean;
var
  S, Rest: UnicodeString;
  P, Q: Integer;
begin
  ALabel := '';
  AUri := '';
  ATitle := '';
  S := TrimU(ALine);
  if (Length(S) < 4) or (S[1] <> '[') then
    Exit(False);
  P := Pos(']:', S);
  if P < 3 then
    Exit(False);
  ALabel := Copy(S, 2, P - 2);
  { A `[^...]` label is a footnote, not a reference. }
  if (ALabel <> '') and (ALabel[1] = '^') then
    Exit(False);
  Rest := TrimU(Copy(S, P + 2, Length(S)));
  if Rest = '' then
    Exit(False);
  { A trailing quoted title. }
  Q := Pos(' "', Rest);
  if Q > 0 then
  begin
    ATitle := TrimU(Copy(Rest, Q + 1, Length(Rest)));
    if (Length(ATitle) >= 2) and (ATitle[1] = '"') and
      (ATitle[Length(ATitle)] = '"') then
      ATitle := Copy(ATitle, 2, Length(ATitle) - 2)
    else
      ATitle := '';
    Rest := TrimU(Copy(Rest, 1, Q - 1));
  end;
  AUri := Rest;
  Result := (ALabel <> '') and (AUri <> '');
end;

function IsMathFence(const ALine: UnicodeString): Boolean;
begin
  Result := TrimU(ALine) = '$$';
end;

{ `:::name` opens a custom block; `:::` closes it. }
function CustomFenceOpen(const ALine: UnicodeString; out AName: UnicodeString): Boolean;
var
  S: UnicodeString;
begin
  AName := '';
  S := TrimU(ALine);
  if (Length(S) < 4) or (Copy(S, 1, 3) <> ':::') then
    Exit(False);
  AName := TrimU(Copy(S, 4, Length(S)));
  Result := AName <> '';
end;

function IsCustomFenceClose(const ALine: UnicodeString): Boolean;
begin
  Result := TrimU(ALine) = ':::';
end;

{ <tag ...> or a closing </tag> - a raw HTML block line. }
function IsHtmlLine(const ALine: UnicodeString): Boolean;
var
  S: UnicodeString;
  I: Integer;
begin
  S := TrimU(ALine);
  if (S = '') or (S[1] <> '<') then
    Exit(False);
  I := 2;
  if (I <= Length(S)) and (S[I] = '/') then
    Inc(I);
  Result := (I <= Length(S)) and (S[I] in ['a'..'z', 'A'..'Z']);
end;

{ `term` on one line, `: definition` on the next - a description list entry. }
function IsDescriptionMarker(const ALine: UnicodeString): Boolean;
var
  S: UnicodeString;
begin
  S := TrimU(ALine);
  Result := (Length(S) >= 2) and (S[1] = ':') and
    ((S[2] = ' ') or (Length(S) = 1));
end;

{ Is AFrom the opening of a frontmatter fence? True when the line is a thematic
  break AND a later line in the same block is also a thematic break, which is its
  closing partner. A `---` with no partner is a plain rule. }
function FrontCloses(const ALines: TStrArray; AFrom, ATo: Integer;
  out AClose: Integer): Boolean;
var
  I: Integer;
begin
  AClose := 0;
  if not IsRule(ALines[AFrom]) then
    Exit(False);
  { Only a bare fence line can open or close: `---` with other content is a rule
    like any other and must not pair. }
  if TrimU(ALines[AFrom]) <> '---' then
    Exit(False);
  for I := AFrom + 1 to ATo do
    if (TrimU(ALines[I]) = '---') then
    begin
      AClose := I;
      Exit(True);
    end;
  Result := False;
end;

{ An indented-code line: four spaces, or a tab, of indent. }
function IsCodeIndent(const ALine: UnicodeString): Boolean;
begin
  if (Length(ALine) >= 1) and (ALine[1] = #9) then
    Exit(True);
  Result := (Length(ALine) >= 4) and (ALine[1] = ' ') and (ALine[2] = ' ') and
    (ALine[3] = ' ') and (ALine[4] = ' ');
end;

function StripCodeIndent(const ALine: UnicodeString): UnicodeString;
begin
  if (Length(ALine) >= 1) and (ALine[1] = #9) then
    Result := Copy(ALine, 2, Length(ALine))
  else if (Length(ALine) >= 4) and (ALine[1] = ' ') and (ALine[2] = ' ') and
    (ALine[3] = ' ') and (ALine[4] = ' ') then
    Result := Copy(ALine, 5, Length(ALine))
  else
    Result := ALine;
end;

{ How many leading spaces a line has. }
function IndentOf(const ALine: UnicodeString): Integer;
begin
  Result := 0;
  while (Result < Length(ALine)) and (ALine[Result + 1] = ' ') do
    Inc(Result);
end;

function StripIndent(const ALine: UnicodeString; ACount: Integer): UnicodeString;
begin
  Result := Copy(ALine, ACount + 1, Length(ALine));
end;

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

procedure PushCell(var ACells: TStrArray; const AText: UnicodeString);
begin
  SetLength(ACells, Length(ACells) + 1);
  ACells[High(ACells)] := AText;
end;

function SplitCells(const ALine: UnicodeString): TStrArray;
var
  I: Integer;
  S, Cell: UnicodeString;
begin
  Result := nil;
  S := TrimU(ALine);
  { An outer pipe is decoration, not an empty cell. }
  if (S <> '') and (S[1] = '|') then
    S := Copy(S, 2, Length(S));
  if (S <> '') and (S[Length(S)] = '|') and
    ((Length(S) < 2) or (S[Length(S) - 1] <> '\')) then
    SetLength(S, Length(S) - 1);
  Cell := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '\') and (I < Length(S)) and (S[I + 1] = '|') then
    begin
      Cell := Cell + '|';
      Inc(I, 2);
    end
    else if S[I] = '|' then
    begin
      PushCell(Result, TrimU(Cell));
      Cell := '';
      Inc(I);
    end
    else
    begin
      Cell := Cell + S[I];
      Inc(I);
    end;
  end;
  PushCell(Result, TrimU(Cell));
end;

function ParseDelimiter(const ALine: UnicodeString;
  out AAlign: TMdAlignArray): Boolean;
var
  Cells: TStrArray;
  I, K, Dashes: Integer;
  S: UnicodeString;
  Left, Right: Boolean;
begin
  AAlign := nil;
  if not HasUnescapedPipe(ALine) then
    Exit(False);
  Cells := SplitCells(ALine);
  if Length(Cells) = 0 then
    Exit(False);
  SetLength(AAlign, Length(Cells));
  for I := 0 to High(Cells) do
  begin
    S := TrimU(Cells[I]);
    if S = '' then
      Exit(False);
    Left := S[1] = ':';
    Right := S[Length(S)] = ':';
    if Left then
      S := Copy(S, 2, Length(S));
    if (Right) and (S <> '') then
      SetLength(S, Length(S) - 1);
    S := TrimU(S);
    if S = '' then
      Exit(False);
    Dashes := 0;
    for K := 1 to Length(S) do
      if S[K] = '-' then
        Inc(Dashes)
      else
        Exit(False);
    if Dashes < 1 then
      Exit(False);
    if Left and Right then
      AAlign[I] := maCenter
    else if Left then
      AAlign[I] := maLeft
    else if Right then
      AAlign[I] := maRight
    else
      AAlign[I] := maNone;
  end;
  Result := True;
end;

{ --- node emission helpers ------------------------------------------------ }

procedure EmitLeaf(var B: TBuilder; const AParent: Integer;
  const AKind: TMdNodeKind; const AContent: UnicodeString);
var
  N: TMdNode;
  Id: Integer;
begin
  N := Default(TMdNode);
  N.Kind := AKind;
  N.Content := AContent;
  B.Add(N, Id);
  B.Append(AParent, Id);
end;

{ Text with formats, splitting on soft line breaks so a paragraph's lines are
  linebreak nodes rather than one collapsed run. }
procedure EmitText(var B: TBuilder; const AParent: Integer;
  const AText: UnicodeString; const AFormats: TMdFormats);
var
  N: TMdNode;
  Id, P, From: Integer;
  Piece: UnicodeString;
begin
  From := 1;
  repeat
    P := Pos(#10, AText, From);
    if P = 0 then
      Piece := Copy(AText, From, Length(AText))
    else
      Piece := Copy(AText, From, P - From);
    if Piece <> '' then
    begin
      N := Default(TMdNode);
      N.Kind := mnText;
      N.Content := Piece;
      N.Formats := AFormats;
      B.Add(N, Id);
      B.Append(AParent, Id);
    end;
    if P = 0 then
      Break;
    N := Default(TMdNode);
    N.Kind := mnLineBreak;
    N.Soft := True;
    B.Add(N, Id);
    B.Append(AParent, Id);
    From := P + 1;
  until False;
end;

{ --- inline (Phase 1: deliberately minimal, replaced in Phase 3) ---------- }

{ --- inline, driven by the linear tokenizer ------------------------------- }

{ Build nodes from markdown.inline's token stream. The tokens are a flat stream
  with explicit open/close markers, so nesting is resolved by a STACK here rather
  than by recursion in the tokenizer - that is what keeps the tokenizer free of
  any dependency on the node model.

  A formatted run becomes a wrapper `text` node carrying the format set, with the
  actual text as its child. }
procedure ParseInlines(var B: TBuilder; const AParent: Integer;
  const AText: UnicodeString); forward;

procedure ParseInlines(var B: TBuilder; const AParent: Integer;
  const AText: UnicodeString);
var
  Toks: TMdTokenArray;
  I, Id, LinkId: Integer;
  Parents: array of Integer;
  Fmts: array of TMdFormats;
  Top: Integer;
  Active: TMdFormats;
  N: TMdNode;
  Depth: Integer;

  function CurrentParent: Integer;
  begin
    if Top = 0 then
      Result := AParent
    else
      Result := Parents[Top - 1];
  end;

  procedure OpenRun(const AFmt: TMdFormats);
  begin
    N := Default(TMdNode);
    N.Kind := mnText;
    N.Formats := AFmt;
    B.Add(N, Id);
    B.Append(CurrentParent, Id);
    SetLength(Parents, Top + 1);
    Parents[Top] := Id;
    SetLength(Fmts, Top + 1);
    Fmts[Top] := AFmt;
    Inc(Top);
  end;

  procedure CloseRun;
  begin
    if Top > 0 then
      Dec(Top);
  end;

begin
  Toks := TokenizeInline(AText);
  Top := 0;
  LinkId := 0;
  Parents := nil;
  Fmts := nil;
  for I := 0 to High(Toks) do
  begin
    { The formats in force are the union of every open run. }
    Active := [];
    for Depth := 0 to Top - 1 do
      Active := Active + Fmts[Depth];
    case Toks[I].Kind of
      tkOpen:
        OpenRun(Toks[I].Formats);
      tkClose:
        CloseRun;
      tkText:
        EmitText(B, CurrentParent, Toks[I].Text, Active);
      tkCode:
        begin
          N := Default(TMdNode);
          N.Kind := mnCodeSpan;
          N.Content := Toks[I].Text;
          B.Add(N, Id);
          B.Append(CurrentParent, Id);
        end;
      tkSoftBreak:
        begin
          N := Default(TMdNode);
          N.Kind := mnLineBreak;
          N.Soft := True;
          B.Add(N, Id);
          B.Append(CurrentParent, Id);
        end;
      tkHardBreak:
        begin
          N := Default(TMdNode);
          N.Kind := mnLineBreak;
          N.Soft := False;
          B.Add(N, Id);
          B.Append(CurrentParent, Id);
        end;
      tkLinkOpen:
        begin
          N := Default(TMdNode);
          N.Kind := mnLink;
          N.Uri := Toks[I].Uri;
          B.Add(N, LinkId);
          B.Append(CurrentParent, LinkId);
          SetLength(Parents, Top + 1);
          Parents[Top] := LinkId;
          SetLength(Fmts, Top + 1);
          Fmts[Top] := [];
          Inc(Top);
        end;
      tkImageOpen:
        begin
          N := Default(TMdNode);
          N.Kind := mnImage;
          N.Uri := Toks[I].Uri;
          N.Alt := Toks[I].Text;
          B.Add(N, Id);
          B.Append(CurrentParent, Id);
        end;
      tkAutolink:
        begin
          N := Default(TMdNode);
          N.Kind := mnHyperlink;
          N.Content := Toks[I].Text;
          N.Uri := Toks[I].Uri;
          B.Add(N, Id);
          B.Append(CurrentParent, Id);
        end;
      tkFootnoteCallout:
        begin
          N := Default(TMdNode);
          N.Kind := mnFootnoteCallout;
          N.RefLabel := Toks[I].Text;
          B.Add(N, Id);
          B.Append(CurrentParent, Id);
        end;
      tkMathSpan:
        begin
          N := Default(TMdNode);
          N.Kind := mnMathSpan;
          N.Content := Toks[I].Text;
          B.Add(N, Id);
          B.Append(CurrentParent, Id);
        end;
    end;
  end;
end;

{ --- block parser --------------------------------------------------------- }

{ Stamp a node's byte span from the source lines it came from. Declared here
  because ParseBlocks stamps as it emits. }
procedure StampAt(var B: TBuilder; const AId: Integer;
  const ASpans: TLineSpanArray; const AFrom, ATo: Integer); forward;

procedure ParseBlocks(var B: TBuilder; const AParent: Integer;
  const ALines: TStrArray; const ASpans: TLineSpanArray;
  AFrom, ATo: Integer); forward;

{ A paragraph or heading's inline content from its raw lines. }
procedure EmitJoined(var B: TBuilder; const AParent: Integer;
  const ALines: TStrArray; AFrom, ATo: Integer);
var
  I: Integer;
  Joined: UnicodeString;
begin
  Joined := '';
  for I := AFrom to ATo do
  begin
    if I > AFrom then
      Joined := Joined + #10;
    Joined := Joined + TrimU(ALines[I]);
  end;
  ParseInlines(B, AParent, Joined);
end;

procedure EmitTable(var B: TBuilder; const AParent: Integer;
  const ALines: TStrArray; AFrom, ATo: Integer;
  const AAlign: TMdAlignArray);
var
  TableId, HeaderId, BodyId, RowId, CellId: Integer;
  Cells: TStrArray;
  I, J: Integer;
  N: TMdNode;

  procedure EmitRow(const ALine: UnicodeString);
  var
    K: Integer;
  begin
    N := Default(TMdNode);
    N.Kind := mnTableRow;
    B.Add(N, RowId);
    B.Append(BodyId, RowId);
    Cells := SplitCells(ALine);
    for K := 0 to High(AAlign) do
    begin
      N := Default(TMdNode);
      N.Kind := mnTableCell;
      N.CellAlign := AAlign[K];
      B.Add(N, CellId);
      B.Append(RowId, CellId);
      if (K <= High(Cells)) and (TrimU(Cells[K]) <> '') then
        ParseInlines(B, CellId, TrimU(Cells[K]));
    end;
  end;

begin
  N := Default(TMdNode);
  N.Kind := mnTable;
  N.Align := AAlign;
  B.Add(N, TableId);
  B.Append(AParent, TableId);

  N := Default(TMdNode);
  N.Kind := mnTableHeader;
  B.Add(N, HeaderId);
  B.Append(TableId, HeaderId);
  N := Default(TMdNode);
  N.Kind := mnTableRow;
  B.Add(N, RowId);
  B.Append(HeaderId, RowId);
  Cells := SplitCells(ALines[AFrom]);
  for I := 0 to High(AAlign) do
  begin
    N := Default(TMdNode);
    N.Kind := mnTableCell;
    N.CellAlign := AAlign[I];
    B.Add(N, CellId);
    B.Append(RowId, CellId);
    if (I <= High(Cells)) and (TrimU(Cells[I]) <> '') then
      ParseInlines(B, CellId, TrimU(Cells[I]));
  end;

  N := Default(TMdNode);
  N.Kind := mnTableBody;
  B.Add(N, BodyId);
  B.Append(TableId, BodyId);
  for J := AFrom + 2 to ATo do
    EmitRow(ALines[J]);
end;

{ A run of list items at the same indent. Deeper markers become a nested list
  attached to the item that precedes them - the nesting v1 could not express. }
procedure ParseListRun(var B: TBuilder; const AParent: Integer;
  const ALines: TStrArray; const ASpans: TLineSpanArray;
  AFrom, ATo, AIndent: Integer;
  const AOrdered: Boolean; const AOrdinal: Integer; out ANext: Integer);
var
  I, J, Id, ItemId, ParaId, SubId: Integer;
  Depth, Ordinal, Indent: Integer;
  Ordered: Boolean;
  Cont: TStrArray;
  ContFrom, ContTo: Integer;
  CountSpans: TLineSpanArray;
  ListId, LastItemLine: Integer;
  N: TMdNode;
  Styled: TMdListStyle;
  Nested: TStrArray;
  NestedFrom, NestedTo, NestedNext: Integer;
begin
  Indent := AIndent;
  { A nested run is given its own lines, so infer its indent from its first
    marker. Passing the OUTER indent here silently drops every nested item. }
  if (AIndent < 0) and (AFrom <= ATo) then
  begin
    ListMarker(ALines[AFrom], Ordered, Ordinal, Depth, Indent);
    AIndent := Indent;
  end;

  ListId := 0;
  N := Default(TMdNode);
  N.Kind := mnList;
  if AOrdered then
    Styled := lsOrdered
  else
    Styled := lsUnordered;
  N.Style := Styled;
  N.Marker := lmInteger;
  N.Start := AOrdinal;
  B.Add(N, Id);
  B.Append(AParent, Id);
  { Stamped AFTER the loop, from its first line to its last ITEM's line. Stamping
    it here with ATo swallowed the blank line that separates the list from what
    follows, so a slice of the span included a separator that is not part of the
    node. }
  ListId := Id;

  I := AFrom;
  while I <= ATo do
  begin
    if TrimU(ALines[I]) = '' then
    begin
      { A blank does not close a list when another marker follows. }
      if (I + 1 <= ATo) and
        ListMarker(ALines[I + 1], Ordered, Ordinal, Depth, Indent) and
        (Indent = AIndent) then
      begin
        Inc(I);
        Continue;
      end;
      Break;
    end;
    if not ListMarker(ALines[I], Ordered, Ordinal, Depth, Indent) then
      Break;
    if Indent <> AIndent then
      Break;

    N := Default(TMdNode);
    N.Kind := mnListItem;
    B.Add(N, ItemId);
    B.Append(Id, ItemId);
    StampAt(B, ItemId, ASpans, I, I);
    N := Default(TMdNode);
    N.Kind := mnParagraph;
    B.Add(N, ParaId);
    B.Append(ItemId, ParaId);
    ParseInlines(B, ParaId, TrimU(StripListMarker(ALines[I])));
    Inc(I);

    { A blank line that is followed by an INDENTED, non-marker line belongs to
      this item, not to the document: that is what makes an item "loose". The
      check has to happen BEFORE the outer loop's blank handling, or the blank
      closes the list and the continuation becomes a sibling paragraph. }
    if (I <= ATo) and (TrimU(ALines[I]) = '') and (I + 1 <= ATo) and
      (TrimU(ALines[I + 1]) <> '') and
      not ListMarker(ALines[I + 1], Ordered, Ordinal, Depth, Indent) and
      (IndentOf(ALines[I + 1]) > AIndent) then
      Inc(I);

    { Indented continuation lines that are not markers: the item's further blocks. }
    while (I <= ATo) and (TrimU(ALines[I]) <> '') and
      not ListMarker(ALines[I], Ordered, Ordinal, Depth, Indent) and
      (IndentOf(ALines[I]) > AIndent) do
    begin
      ContFrom := I;
      J := I;
      while (J <= ATo) and (TrimU(ALines[J]) <> '') and
        not ListMarker(ALines[J], Ordered, Ordinal, Depth, Indent) and
        (IndentOf(ALines[J]) > AIndent) do
        Inc(J);
      SetLength(Cont, J - ContFrom);
      for ContTo := ContFrom to J - 1 do
        Cont[ContTo - ContFrom] := StripIndent(ALines[ContTo], AIndent + 2);
      CountSpans := nil;
      for ContTo := ContFrom to J - 1 do
      begin
        SetLength(CountSpans, Length(CountSpans) + 1);
        if ContTo <= High(ASpans) then
          CountSpans[High(CountSpans)] := ASpans[ContTo];
      end;
      ParseBlocks(B, ItemId, Cont, CountSpans, 0, High(Cont));
      I := J;
      { A blank between the continuation and the next marker does not end the
        item, but a blank followed by a non-indented line does end the list. }
      if (I <= ATo) and (TrimU(ALines[I]) = '') and (I + 1 <= ATo) and
        (IndentOf(ALines[I + 1]) <= AIndent) and
        not ListMarker(ALines[I + 1], Ordered, Ordinal, Depth, Indent) then
        Break;
      if (I <= ATo) and (TrimU(ALines[I]) = '') then
        Inc(I);
    end;

    { Deeper markers belong to this item as a sublist. }
    if (I <= ATo) and ListMarker(ALines[I], Ordered, Ordinal, Depth, Indent) and
      (Indent > AIndent) then
    begin
      NestedFrom := I;
      J := I;
      while (J <= ATo) and ListMarker(ALines[J], Ordered, Ordinal, Depth, Indent) and
        (Indent > AIndent) do
        Inc(J);
      Nested := nil;
      for NestedTo := NestedFrom to J - 1 do
      begin
        SetLength(Nested, Length(Nested) + 1);
        Nested[High(Nested)] := ALines[NestedTo];
      end;
      ParseListRun(B, ItemId, Nested, nil, 0, High(Nested), -1, Ordered,
        Ordinal, NestedNext);
      Inc(I, J - NestedFrom);
    end;
    LastItemLine := I - 1;
  end;
  if (ListId > 0) and (LastItemLine >= AFrom) then
    StampAt(B, ListId, ASpans, AFrom, LastItemLine);
  ANext := I;
end;

procedure ParseBlocks(var B: TBuilder; const AParent: Integer;
  const ALines: TStrArray; const ASpans: TLineSpanArray;
  AFrom, ATo: Integer);
var
  I, J, K, Level, Depth, Ordinal, Indent, Id, Next: Integer;
  ParaId2, TermId, DescId, FrontAt: Integer;
  Label1, Text1, Text2: UnicodeString;
  CountSpans, QuoteSpans: TLineSpanArray;
  Ordered: Boolean;
  AChar: Char;
  Lang: UnicodeString;
  N: TMdNode;
  Align: TMdAlignArray;
  QuoteId: Integer;
  Stripped: TStrArray;
  ParaFrom: Integer;

  function StartsBlock(const ALine: UnicodeString): Boolean;
  var
    L, D, O, N2: Integer;
    C: Char;
    G: UnicodeString;
  begin
    Result := HeadingLevel(ALine, L) or IsRule(ALine) or
      FenceOpen(ALine, C, G) or ListMarker(ALine, Ordered, O, D, N2) or
      QuoteDepth(ALine, D);
  end;

begin
  I := AFrom;
  while I <= ATo do
  begin
    if TrimU(ALines[I]) = '' then
    begin
      Inc(I);
      Continue;
    end;

    { fenced code }
    if FenceOpen(ALines[I], AChar, Lang) then
    begin
      J := I + 1;
      while (J <= ATo) and not FenceClose(ALines[J], AChar) do
        Inc(J);
      N := Default(TMdNode);
      N.Kind := mnCodeBlock;
      N.Language := Lang;
      N.Fenced := True;
      N.Content := '';
      for Level := I + 1 to J - 1 do
      begin
        if N.Content <> '' then
          N.Content := N.Content + #10;
        N.Content := N.Content + ALines[Level];
      end;
      B.Add(N, Id);
      B.Append(AParent, Id);
      { A fence spans its opener through its closer. }
      StampAt(B, Id, ASpans, I, J);
      I := J + 1;
      Continue;
    end;

    { ATX heading }
    if HeadingLevel(ALines[I], Level) then
    begin
      N := Default(TMdNode);
      N.Kind := mnHeading;
      N.Level := Level;
      B.Add(N, Id);
      B.Append(AParent, Id);
    StampAt(B, Id, ASpans, I, I);
      J := 1;
      while (J <= Length(ALines[I])) and ((ALines[I][J] = ' ') or
        (ALines[I][J] = '#')) do
        Inc(J);
      ParseInlines(B, Id, TrimU(Copy(ALines[I], J, Length(ALines[I]))));
      Inc(I);
      Continue;
    end;

    { table: a header line with a delimiter row directly beneath it }
    if (I < ATo) and HasUnescapedPipe(ALines[I]) and
      ParseDelimiter(ALines[I + 1], Align) then
    begin
      J := I + 2;
      while (J <= ATo) and (TrimU(ALines[J]) <> '') and
        HasUnescapedPipe(ALines[J]) do
        Inc(J);
      EmitTable(B, AParent, ALines, I, J - 1, Align);
      { The table node spans header through last body row. }
      StampAt(B, Id, ASpans, I, J - 1);
      I := J;
      Continue;
    end;

    { setext heading: the very next line is the underline. This MUST precede the
      thematic break, or `---` is claimed as a rule and the heading vanishes. }
    if (I < ATo) and SetextLevel(ALines[I + 1], Level) then
    begin
      N := Default(TMdNode);
      N.Kind := mnHeading;
      N.Level := Level;
      B.Add(N, Id);
      B.Append(AParent, Id);
    StampAt(B, Id, ASpans, I, I);
      ParseInlines(B, Id, TrimU(ALines[I]));
      Inc(I, 2);
      Continue;
    end;

    { indented code: four spaces. NOT a fence, so Fenced stays False. }
    if IsCodeIndent(ALines[I]) then
    begin
      J := I;
      while (J <= ATo) and ((TrimU(ALines[J]) = '') or IsCodeIndent(ALines[J])) do
        Inc(J);
      N := Default(TMdNode);
      N.Kind := mnCodeBlock;
      N.Fenced := False;
      N.Content := '';
      { Trailing blank lines are not content. }
      K := J - 1;
      while (K >= I) and (TrimU(ALines[K]) = '') do
        Dec(K);
      for Level := I to K do
      begin
        if N.Content <> '' then
          N.Content := N.Content + #10;
        N.Content := N.Content + StripCodeIndent(ALines[Level]);
      end;
      B.Add(N, Id);
      B.Append(AParent, Id);
    StampAt(B, Id, ASpans, I, I);
      I := J;
      Continue;
    end;

    { FRONTMATTER: a `---` fence enclosing YAML. An EXTENSION - neither
      CommonMark nor GFM has it, so the rule is ours to set.

      It is a BLOCK, so it may appear ANYWHERE in the document: position is not
      part of the rule, the content type is. A consumer decides what to do with
      it (the harness treats it as document metadata when the YAML is extracted).

      The parser reports the block's inner text VERBATIM and interprets nothing -
      no key sniffing, no `title` policy, no YAML parse. That boundary is the
      whole reason this can live in a pure module.

      It must precede the thematic-break pass: a `---` with a LATER `---` is a
      fence pair, and only a `---` with no partner is a rule. Requiring the
      closing fence is also what stops a stray rule swallowing the document. }
    if IsRule(ALines[I]) and FrontCloses(ALines, I, ATo, FrontAt) then
    begin
      N := Default(TMdNode);
      N.Kind := mnFrontmatter;
      N.Content := '';
      for Level := I + 1 to FrontAt - 1 do
      begin
        if N.Content <> '' then
          N.Content := N.Content + #10;
        N.Content := N.Content + ALines[Level];
      end;
      B.Add(N, Id);
      B.Append(AParent, Id);
    StampAt(B, Id, ASpans, I, I);
      I := FrontAt + 1;
      Continue;
    end;

    { thematic break }
    if IsRule(ALines[I]) then
    begin
      N := Default(TMdNode);
      N.Kind := mnHorizontalRule;
      B.Add(N, Id);
      B.Append(AParent, Id);
    StampAt(B, Id, ASpans, I, I);
      Inc(I);
      Continue;
    end;

    { blockquote: the run of quoted lines, stripped, recursed }
    if QuoteDepth(ALines[I], Depth) then
    begin
      J := I;
      while (J <= ATo) and QuoteDepth(ALines[J], Level) do
        Inc(J);
      N := Default(TMdNode);
      N.Kind := mnBlockQuote;
      N.Level := Depth;
      B.Add(N, QuoteId);
      B.Append(AParent, QuoteId);
      Stripped := nil;
      QuoteSpans := nil;
      for Level := I to J - 1 do
      begin
        SetLength(Stripped, Length(Stripped) + 1);
        Stripped[High(Stripped)] := StripQuote(ALines[Level]);
        SetLength(QuoteSpans, Length(QuoteSpans) + 1);
        if Level <= High(ASpans) then
          QuoteSpans[High(QuoteSpans)] := ASpans[Level];
      end;
      ParseBlocks(B, QuoteId, Stripped, QuoteSpans, 0, High(Stripped));
      StampAt(B, QuoteId, ASpans, I, J - 1);
      I := J;
      Continue;
    end;

    { list }
    if ListMarker(ALines[I], Ordered, Ordinal, Depth, Indent) then
    begin
      ParseListRun(B, AParent, ALines, ASpans, I, ATo, Indent, Ordered, Ordinal,
        Next);
      I := Next;
      Continue;
    end;

    { footnote definition: `[^label]: text` }
    if FootnoteDef(ALines[I], Label1, Text1) then
    begin
      N := Default(TMdNode);
      N.Kind := mnFootnote;
      N.RefLabel := Label1;
      B.Add(N, Id);
      B.Append(AParent, Id);
    StampAt(B, Id, ASpans, I, I);
      { The definition's body is a paragraph child, so a multi-block footnote can
        grow without changing the shape. }
      N := Default(TMdNode);
      N.Kind := mnParagraph;
      B.Add(N, ParaId2);
      B.Append(Id, ParaId2);
      ParseInlines(B, ParaId2, Text1);
      Inc(I);
      Continue;
    end;

    { link reference definition: `[label]: uri "title"` }
    if ReferenceDef(ALines[I], Label1, Text1, Text2) then
    begin
      N := Default(TMdNode);
      N.Kind := mnReference;
      N.RefLabel := Label1;
      N.Uri := Text1;
      N.Title := Text2;
      B.Add(N, Id);
      B.Append(AParent, Id);
    StampAt(B, Id, ASpans, I, I);
      Inc(I);
      Continue;
    end;

    { math block: `$$` fenced }
    if IsMathFence(ALines[I]) then
    begin
      J := I + 1;
      while (J <= ATo) and not IsMathFence(ALines[J]) do
        Inc(J);
      N := Default(TMdNode);
      N.Kind := mnMathBlock;
      N.Content := '';
      for Level := I + 1 to J - 1 do
      begin
        if N.Content <> '' then
          N.Content := N.Content + #10;
        N.Content := N.Content + ALines[Level];
      end;
      B.Add(N, Id);
      B.Append(AParent, Id);
    StampAt(B, Id, ASpans, I, I);
      if J <= ATo then
        I := J + 1
      else
        I := J;
      Continue;
    end;

    { custom block: `:::name` ... `:::` }
    if CustomFenceOpen(ALines[I], Text1) then
    begin
      J := I + 1;
      while (J <= ATo) and not IsCustomFenceClose(ALines[J]) do
        Inc(J);
      N := Default(TMdNode);
      N.Kind := mnCustomBlock;
      N.RefLabel := Text1;
      B.Add(N, Id);
      B.Append(AParent, Id);
    StampAt(B, Id, ASpans, I, I);
      if J > I + 1 then
        ParseBlocks(B, Id, ALines, ASpans, I + 1, J - 1);
      if J <= ATo then
        I := J + 1
      else
        I := J;
      Continue;
    end;

    { raw HTML block: a run of tag lines, preserved verbatim, NEVER interpreted }
    if IsHtmlLine(ALines[I]) then
    begin
      J := I;
      while (J <= ATo) and (TrimU(ALines[J]) <> '') and IsHtmlLine(ALines[J]) do
        Inc(J);
      N := Default(TMdNode);
      N.Kind := mnHtmlBlock;
      N.Content := '';
      for Level := I to J - 1 do
      begin
        if N.Content <> '' then
          N.Content := N.Content + #10;
        N.Content := N.Content + ALines[Level];
      end;
      B.Add(N, Id);
      B.Append(AParent, Id);
    StampAt(B, Id, ASpans, I, I);
      I := J;
      Continue;
    end;

    { description list: a term line immediately followed by `: definition` }
    if (I < ATo) and IsDescriptionMarker(ALines[I + 1]) then
    begin
      N := Default(TMdNode);
      N.Kind := mnDescriptionList;
      B.Add(N, Id);
      B.Append(AParent, Id);
    StampAt(B, Id, ASpans, I, I);
      J := I;
      while (J < ATo) and IsDescriptionMarker(ALines[J + 1]) do
      begin
        N := Default(TMdNode);
        N.Kind := mnDescriptionTerm;
        B.Add(N, TermId);
        B.Append(Id, TermId);
        ParseInlines(B, TermId, TrimU(ALines[J]));
        N := Default(TMdNode);
        N.Kind := mnDescription;
        B.Add(N, DescId);
        B.Append(Id, DescId);
        ParseInlines(B, DescId, TrimU(Copy(TrimU(ALines[J + 1]), 2,
          Length(ALines[J + 1]))));
        Inc(J, 2);
      end;
      I := J;
      Continue;
    end;

    { paragraph: to a blank line or the next block start }
    ParaFrom := I;
    J := I;
    while (J < ATo) and (TrimU(ALines[J + 1]) <> '') and
      not StartsBlock(ALines[J + 1]) and
      not SetextLevel(ALines[J + 1], Level) do
      Inc(J);
    N := Default(TMdNode);
    N.Kind := mnParagraph;
    B.Add(N, Id);
    B.Append(AParent, Id);
    { A paragraph spans its FIRST line to its LAST: the blanket stamp used I..I,
      which covers one line of a multi-line paragraph. }
    StampAt(B, Id, ASpans, ParaFrom, J);
    EmitJoined(B, Id, ALines, ParaFrom, J);
    I := J + 1;
  end;
end;

{ Fill AMeta from the lines strictly BETWEEN the two `---` fences (0 and AClose).
  One `key: value` per line; a `#` comment and a blank line are skipped; a line
  with no colon is kept as a key with an empty value rather than dropped, so a
  malformed entry is visible instead of silently vanishing. }
constructor TMdDocument.Create;
begin
  inherited Create;
  Nodes := nil;
  Root := 0;
end;

function TMdDocument.Snapshot: TMdDocument;
var
  I: Integer;
begin
  Result := TMdDocument.Create;
  Result.Root := Root;
  SetLength(Result.Nodes, Length(Nodes));
  for I := 0 to High(Nodes) do
  begin
    Result.Nodes[I] := Nodes[I];
    { Child arrays are managed too: copy them, or the snapshot would still share
      them and a later append to the original would copy-on-write into the
      snapshot's lifetime. }
    if Length(Nodes[I].Children) > 0 then
    begin
      SetLength(Result.Nodes[I].Children, Length(Nodes[I].Children));
      Move(Nodes[I].Children[0], Result.Nodes[I].Children[0],
        Length(Nodes[I].Children) * SizeOf(Integer));
    end;
  end;
end;

{ Stamp AId's byte span from the source lines it came from.

  Offsets are BYTES into the UTF-8 text the parser was given, half open, and they
  EXCLUDE the trailing newline - so Copy(Source, SrcStart, SrcEnd-SrcStart) is the
  node's own text, without its line ending. A consumer that needs "where did this
  come from" (click a cell, find its source) has nothing else to go on: ids are
  document order and do not survive an edit. }
procedure StampAt(var B: TBuilder; const AId: Integer;
  const ASpans: TLineSpanArray; const AFrom, ATo: Integer);
begin
  if (AId < 0) or (AId >= Length(B.Nodes)) then
    Exit;
  if Length(ASpans) = 0 then
    Exit;
  if (AFrom < 0) or (AFrom > High(ASpans)) then
    Exit;
  B.Nodes[AId].SrcStart := ASpans[AFrom].StartByte;
  if (ATo >= 0) and (ATo <= High(ASpans)) then
    B.Nodes[AId].SrcEnd := ASpans[ATo].EndByte
  else
    B.Nodes[AId].SrcEnd := ASpans[AFrom].EndByte;
end;

{ Shift a node's child ids by AOffset, in place. }
{ --- inline projection ----------------------------------------------------- }

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
  if AText = '' then
    Exit;
  S := Default(TMdSpan);
  S.Text := AText;
  S.Styles := AStyles;
  S.Link := ALink;
  SetLength(ASpans, Length(ASpans) + 1);
  ASpans[High(ASpans)] := S;
end;

procedure CollectInline(const ADoc: TMdDocument; const AId: Integer;
  const AFormats: TMdFormats; const AUri: UnicodeString;
  var ASpans: TMdSpanArray);
var
  N: TMdNode;
  I: Integer;
  Inner: TMdFormats;
begin
  N := NodeOf(ADoc, AId);
  if N.Id = 0 then
    Exit;
  case N.Kind of
    mnText:
      begin
        { A FORMATTED run is a wrapper whose Content is empty and whose child
          holds the text, so descend as well as push. }
        Inner := AFormats + N.Formats;
        if N.Content <> '' then
          PushSpan(ASpans, N.Content, StylesOf(Inner, AUri <> ''), AUri);
        for I := 0 to High(N.Children) do
          CollectInline(ADoc, N.Children[I], Inner, AUri, ASpans);
      end;
    mnCodeSpan:
      PushSpan(ASpans, N.Content, StylesOf(AFormats, AUri <> '') + [misCode], AUri);
    mnMathSpan:
      PushSpan(ASpans, N.Content, StylesOf(AFormats, AUri <> ''), AUri);
    mnLineBreak:
      PushSpan(ASpans, ' ', StylesOf(AFormats, AUri <> ''), AUri);
    mnLink:
      for I := 0 to High(N.Children) do
        CollectInline(ADoc, N.Children[I], AFormats, N.Uri, ASpans);
    mnHyperlink:
      PushSpan(ASpans, N.Content, StylesOf(AFormats, True), N.Uri);
    mnImage:
      if N.Alt <> '' then
        PushSpan(ASpans, N.Alt, StylesOf(AFormats, AUri <> ''), AUri);
    mnFootnoteCallout:
      PushSpan(ASpans, '[^' + N.RefLabel + ']', StylesOf(AFormats, AUri <> ''),
        AUri);
  else
    for I := 0 to High(N.Children) do
      CollectInline(ADoc, N.Children[I], AFormats, AUri, ASpans);
  end;
end;

function InlineSpansOf(const ADoc: TMdDocument; const AId: Integer): TMdSpanArray;
begin
  Result := nil;
  CollectInline(ADoc, AId, [], '', Result);
end;

procedure RenumberChildren(var ANode: TMdNode; const AOffset: Integer);
var
  I: Integer;
begin
  for I := 0 to High(ANode.Children) do
    ANode.Children[I] := ANode.Children[I] + AOffset;
end;

function AppendParsed(const ADoc: TMdDocument; const AText: string;
  const AParent: Integer): Integer;
var
  B: TBuilder;
  Lines: TStrArray;
  LineSpans: TLineSpanArray;
  I, Offset, Base: Integer;
  N: TMdNode;
  Tmp: TMdDocument;
begin
  Result := 0;
  if Length(ADoc.Nodes) = 0 then
  begin
    { No root yet: parse a whole document and adopt its nodes. The CALLER's object
      must stay the same instance, so the nodes move into it rather than the
      reference being replaced - otherwise a consumer holding ADoc would keep
      watching a stale object. }
    Tmp := ParseTree(AText);
    try
      SetLength(ADoc.Nodes, Length(Tmp.Nodes));
      for I := 0 to High(Tmp.Nodes) do
        Adoc.nodes[I] := tmp.nodes[I];
      ADoc.Root := Tmp.Root;
    finally
      Tmp.Free;
    end;
    Exit(Length(NodeOf(ADoc, ADoc.Root).Children));
  end;
  SplitLinesEx(UnicodeString(AText), Lines, LineSpans);
  if Length(Lines) = 0 then
    Exit;

  { Parse the segment on its own, then MOVE its nodes into ADoc with one
    renumbering pass. A segment is one block, so this costs a handful of records
    rather than a copy of the whole document. }
  B.Init;
  N := Default(TMdNode);
  N.Kind := mnDocument;
  B.Add(N, Base);
  ParseBlocks(B, Base, Lines, LineSpans, 0, High(Lines));

  { The segment's own document root is at Base (=1), so the copy STARTS AT
    Base + 1. Starting at 1 copied the segment's document node into ADoc, which
    is where the duplicate `document` nodes came from. }
  { Length - 2, not Length - 1: index 0 is the unused slot, so with real nodes
    1..N the length is N+1 and the next free index is N+1. A segment id of 2 must
    land on N+1, so the offset is N-1. Using Length - 1 pushed every streamed id
    one past the end, and NodeOf returned a zeroed node for a real block. }
  Offset := Length(ADoc.Nodes) - 2;
  for I := Base + 1 to B.Count - 1 do
  begin
    N := B.Nodes[I];
    N.Id := N.Id + Offset;
    if N.Parent = Base then
      N.Parent := AParent
    else if N.Parent > 0 then
      N.Parent := N.Parent + Offset;
    if Length(N.Children) > 0 then
      RenumberChildren(N, Offset);
    SetLength(ADoc.Nodes, Length(ADoc.Nodes) + 1);
    ADoc.Nodes[High(ADoc.Nodes)] := N;
  end;

  for I := 0 to High(B.Nodes[Base].Children) do
  begin
    SetLength(ADoc.Nodes[AParent].Children,
      Length(ADoc.Nodes[AParent].Children) + 1);
    ADoc.Nodes[AParent].Children[High(ADoc.Nodes[AParent].Children)] :=
      B.Nodes[Base].Children[I] + Offset;
    Inc(Result);
  end;
end;

function ParseTree(const AText: string): TMdDocument;
var
  B: TBuilder;
  Root: TMdNode;
  Lines: TStrArray;
  LineSpans: TLineSpanArray;
  RootId: Integer;
begin
  Result := TMdDocument.Create;
  B.Init;
  Root := Default(TMdNode);
  Root.Kind := mnDocument;
  B.Add(Root, RootId);
  Result.Root := RootId;
  SplitLinesEx(UnicodeString(AText), Lines, LineSpans);

  { Frontmatter is handled as a BLOCK in ParseBlocks, not here: it is a content
    TYPE (YAML inside a `---` fence), so it may appear anywhere in the document
    rather than only at the top. See the bpFrontmatter pass. }
  if Length(Lines) > 0 then
    ParseBlocks(B, RootId, Lines, LineSpans, 0, High(Lines));
  B.Adopt(Result);
end;

function NodeOf(const ADoc: TMdDocument; AId: Integer): TMdNode;
begin
  if (AId >= 1) and (AId <= High(ADoc.Nodes)) then
    Result := ADoc.Nodes[AId]
  else
    Result := Default(TMdNode);
end;

function NodeCount(const ADoc: TMdDocument): Integer;
begin
  if Length(ADoc.Nodes) = 0 then
    Result := 0
  else
    Result := Length(ADoc.Nodes) - 1;
end;

{ Walk one subtree, depth first, in document order. The recursion lives here so
  neither entry point needs a callback that captures state - FPC will not accept a
  nested procedure as a visitor, and a capturing one would need a class anyway. }
procedure WalkFrom(const ADoc: TMdDocument; const AId: Integer;
  AVisit: TMdNodeVisitor; var AAccumulate: TMdIntArray;
  const AFilter: TMdNodeFilter);
var
  N: TMdNode;
  I: Integer;
begin
  if AId <= 0 then
    Exit;
  N := NodeOf(ADoc, AId);
  if N.Id = 0 then
    Exit;
  if Assigned(AVisit) then
    AVisit(N);
  if Assigned(AAccumulate) or True then
    if (not Assigned(AFilter)) or AFilter(N) then
    begin
      SetLength(AAccumulate, Length(AAccumulate) + 1);
      AAccumulate[High(AAccumulate)] := N.Id;
    end;
  for I := 0 to High(N.Children) do
    WalkFrom(ADoc, N.Children[I], AVisit, AAccumulate, AFilter);
end;

procedure WalkNodes(const ADoc: TMdDocument; ASubtree: Integer;
  AVisit: TMdNodeVisitor);
var
  Ignored: TMdIntArray;
begin
  Ignored := nil;
  WalkFrom(ADoc, ASubtree, AVisit, Ignored, nil);
end;

function QueryNodes(const ADoc: TMdDocument; ASubtree: Integer;
  AFilter: TMdNodeFilter): TMdIntArray;
begin
  Result := nil;
  WalkFrom(ADoc, ASubtree, nil, Result, AFilter);
end;

function IsFrontmatter(const ANode: TMdNode): Boolean;
begin
  Result := ANode.Kind = mnFrontmatter;
end;

function IsFootnote(const ANode: TMdNode): Boolean;
begin
  Result := ANode.Kind = mnFootnote;
end;

function IsFootnoteCallout(const ANode: TMdNode): Boolean;
begin
  Result := ANode.Kind = mnFootnoteCallout;
end;

function FrontmatterOf(const ADoc: TMdDocument): Integer;
var
  Ids: TMdIntArray;
begin
  Ids := QueryNodes(ADoc, ADoc.Root, @IsFrontmatter);
  if Length(Ids) = 0 then
    Result := 0
  else
    Result := Ids[0];
end;

function FootnotesOf(const ADoc: TMdDocument): TMdIntArray;
begin
  Result := QueryNodes(ADoc, ADoc.Root, @IsFootnote);
end;

function FootnoteCalloutsOf(const ADoc: TMdDocument): TMdIntArray;
begin
  Result := QueryNodes(ADoc, ADoc.Root, @IsFootnoteCallout);
end;

function FootnoteFor(const ADoc: TMdDocument; const ALabel: UnicodeString): Integer;
var
  Ids: TMdIntArray;
  I: Integer;
  N: TMdNode;
begin
  Result := 0;
  Ids := FootnotesOf(ADoc);
  for I := 0 to High(Ids) do
  begin
    N := NodeOf(ADoc, Ids[I]);
    if N.RefLabel = ALabel then
      Exit(N.Id);
  end;
end;

function FrontmatterText(const ADoc: TMdDocument): UnicodeString;
var
  N: TMdNode;
begin
  N := NodeOf(ADoc, FrontmatterOf(ADoc));
  if N.Id = 0 then
    Result := ''
  else
    Result := N.Content;
end;

function NodesOfKind(const ADoc: TMdDocument; AKind: TMdNodeKind): TMdIntArray;
var
  I: Integer;
begin
  Result := nil;
  for I := 1 to High(ADoc.Nodes) do
    if ADoc.Nodes[I].Kind = AKind then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := I;
    end;
end;

function TextOf(const ADoc: TMdDocument; AId: Integer): UnicodeString;
var
  N: TMdNode;
  I: Integer;
  Sub: UnicodeString;
begin
  Result := '';
  N := NodeOf(ADoc, AId);
  if N.Id = 0 then
    Exit;
  case N.Kind of
    mnText, mnCodeSpan, mnCodeBlock:
      Exit(N.Content);
    mnLineBreak:
      Exit(' ');
  else
    ;  { every container: fall through to its children }
  end;
  for I := 0 to High(N.Children) do
  begin
    Sub := TextOf(ADoc, N.Children[I]);
    if Sub = '' then
      Continue;
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Sub;
  end;
end;

function SquashedTextOf(const ADoc: TMdDocument; AId: Integer): UnicodeString;
begin
  Result := Collapse(TextOf(ADoc, AId));
end;

end.
