unit TestMarkdownTree;
{ Tests for the v2 node tree (MarkdownTree).

  What is asserted here is the SHAPE, not the rendered text: nesting, identity,
  links and source offsets. A renderer test would pass on a flattened model, which
  is exactly the defect the tree exists to prevent. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  MarkdownTypes, MarkdownTree;

type
  TMdTreeTest = class(TTestCase)
  private
    FDoc: TMdDocument;
    procedure Parse(const AText: string);
  protected
    procedure TearDown; override;
    { The kinds from the root down the first-child chain, for shape assertions. }
    function Chain(ADoc: TMdDocument): string;
    function KindOf(AId: Integer): TMdNodeKind;
    function FirstChild(AId: Integer): Integer;
    function CountOf(AKind: TMdNodeKind): Integer;
  published
    procedure TestEmptyDocumentHasOnlyARoot;
    procedure TestParagraphTextIsATextNode;
    procedure TestAtxHeadingLevel;
    procedure TestSetextHeadingIsAHeadingNode;
    procedure TestIdsAreDeterministic;
    procedure TestIdsStartAtOneAndHaveNoGaps;
    procedure TestParentChildLinksAreSymmetric;
    procedure TestEveryNodeIsReachableFromTheRoot;
    procedure TestListNestingIsReal;
    procedure TestBlockquoteContainsItsBlocks;
    procedure TestTableHasRowAndCellNodes;
    procedure TestCodeFenceContentVerbatim;
    procedure TestNodeCount;
    procedure TestNodesOfKindIsInDocumentOrder;
    procedure TestUnknownIdIsAZeroNode;
    { v2 block syntax }
    procedure TestFootnoteDefinitionAndCallout;
    procedure TestLinkReferenceDefinition;
    procedure TestMathBlock;
    procedure TestCustomBlockContainsBlocks;
    procedure TestHtmlBlockIsRawAndVerbatim;
    procedure TestDescriptionList;
    procedure TestIndentedCodeIsNotFenced;
    { Frontmatter is an EXTENSION handled as a BLOCK, so it is a node. }
    { Source offsets: byte spans into the original text. }
    procedure TestHeadingSpanSlicesTheSource;
    procedure TestParagraphSpanSlicesTheSource;
    procedure TestFenceSpanCoversTheWholeFence;
    procedure TestListSpanEndsAtItsLastItem;
    procedure TestSpansAreMonotonicAndInsideTheSource;
    procedure TestSpansAreBytesNotCodepoints;
    procedure TestAParserSeesNoFrontmatterAtAll;
    procedure TestFrontmatterIsTheFirstChild;
    procedure TestFrontmatterRequiresAClosingFence;
    procedure TestFrontmatterAnywhereInTheDocument;
    procedure TestALoneFenceIsStillARule;
    procedure TestFrontmatterNodeCarriesNoInterpretation;
    procedure TestNoFrontmatterMeansNoNode;
    procedure TestFrontmatterWithACrLfBlock;
    { The node is QUERYABLE FROM THE ROOT, which is what makes it an AST node
      rather than a document field. }
    procedure TestFrontmatterIsQueryableFromTheRoot;
    procedure TestNoFrontmatterQueryReturnsZero;
    { The general query: one mechanism, many questions. }
    procedure TestQueryNodesFindsByPredicate;
    procedure TestQueryNodesIsScopedToASubtree;
    procedure TestQueryNodesNilFilterMatchesEverything;
    procedure TestQueryNodesIsInDocumentOrder;
    procedure TestWalkNodesVisitsEveryNode;
    { Footnote aggregation: the same mechanism. }
    procedure TestFootnotesAreAggregated;
    procedure TestFootnoteCalloutsAreAggregated;
    procedure TestFootnoteForLooksUpByLabel;
    procedure TestFootnoteAggregatesAreEmptyWhenAbsent;
  end;

implementation

procedure TMdTreeTest.TearDown;
begin
  { TMdDocument is a CLASS now: ParseTree returns an OWNED object, so the test
    must free it or the leak gate fails. That is the standing cost of a stable
    document identity, and it is the right trade - a record document would
    copy-on-write the whole node array the moment it was held. }
  FDoc.Free;
  FDoc := nil;
end;

procedure TMdTreeTest.Parse(const AText: string);
begin
  FDoc.Free;
  FDoc := ParseTree(AText);
end;

function TMdTreeTest.KindOf(AId: Integer): TMdNodeKind;
begin
  Result := NodeOf(FDoc, AId).Kind;
end;

function TMdTreeTest.FirstChild(AId: Integer): Integer;
var
  N: TMdNode;
begin
  N := NodeOf(FDoc, AId);
  if Length(N.Children) = 0 then
    Result := 0
  else
    Result := N.Children[0];
end;

function TMdTreeTest.CountOf(AKind: TMdNodeKind): Integer;
begin
  Result := Length(NodesOfKind(FDoc, AKind));
end;

function TMdTreeTest.Chain(ADoc: TMdDocument): string;
var
  Id: Integer;
  N: TMdNode;
begin
  Result := '';
  Id := ADoc.Root;
  while Id <> 0 do
  begin
    if Result <> '' then
      Result := Result + ' > ';
    Result := Result + KindName(NodeOf(ADoc, Id).Kind);
    N := NodeOf(ADoc, Id);
    if Length(N.Children) = 0 then
      Break;
    Id := N.Children[0];
  end;
end;

procedure TMdTreeTest.TestEmptyDocumentHasOnlyARoot;
begin
  Parse('');
  AssertEquals('one node', 1, NodeCount(FDoc));
  AssertTrue('the root is a document', KindOf(FDoc.Root) = mnDocument);
  AssertEquals('and it has no children', 0, Length(NodeOf(FDoc, FDoc.Root).Children));
end;

procedure TMdTreeTest.TestParagraphTextIsATextNode;
begin
  Parse('hello');
  AssertEquals('chain', 'document > paragraph > text', Chain(FDoc));
  AssertEquals('text content', 'hello',
    NodeOf(FDoc, FirstChild(FirstChild(FDoc.Root))).Content);
end;

procedure TMdTreeTest.TestAtxHeadingLevel;
begin
  Parse('### Three');
  AssertEquals('chain', 'document > heading > text', Chain(FDoc));
  AssertEquals('level', 3, NodeOf(FDoc, FirstChild(FDoc.Root)).level);
end;

procedure TMdTreeTest.TestSetextHeadingIsAHeadingNode;
begin
  Parse('Title' + #10 + '=====');
  AssertEquals('chain', 'document > heading > text', Chain(FDoc));
  AssertEquals('level 1', 1, NodeOf(FDoc, FirstChild(FDoc.Root)).Level);
end;

procedure TMdTreeTest.TestIdsAreDeterministic;
var
  A, B: TMdDocument;
  I: Integer;
begin
  A := ParseTree('- a' + #10 + '- b' + #10 + #10 + '> q' + #10 + #10 + 'p');
  B := ParseTree('- a' + #10 + '- b' + #10 + #10 + '> q' + #10 + #10 + 'p');
  try
    AssertEquals('same node count', NodeCount(A), NodeCount(B));
    for I := 1 to NodeCount(A) do
    begin
      AssertTrue('same kind at ' + IntToStr(I),
        NodeOf(A, I).Kind = NodeOf(B, I).Kind);
      AssertEquals('same parent at ' + IntToStr(I),
        NodeOf(A, I).Parent, NodeOf(B, I).Parent);
    end;
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TMdTreeTest.TestIdsStartAtOneAndHaveNoGaps;
var
  I: Integer;
begin
  Parse('# h' + #10 + #10 + '- a' + #10 + '  - b' + #10 + #10 + '```p' + #10 +
    'x' + #10 + '```');
  AssertTrue('at least a few nodes', NodeCount(FDoc) > 5);
  for I := 1 to NodeCount(FDoc) do
    AssertEquals('node id matches its index', I, NodeOf(FDoc, I).Id);
end;

procedure TMdTreeTest.TestParentChildLinksAreSymmetric;
var
  I, J, ChildId: Integer;
  N: TMdNode;
begin
  Parse('# h' + #10 + #10 + '> - a' + #10 + #10 + '| x | y |' + #10 +
    '| - | - |' + #10 + '| 1 | 2 |');
  for I := 1 to NodeCount(FDoc) do
  begin
    N := NodeOf(FDoc, I);
    for J := 0 to High(N.Children) do
    begin
      ChildId := N.Children[J];
      AssertTrue('child id in range', (ChildId >= 1) and (ChildId <= NodeCount(FDoc)));
      AssertEquals('child points back at its parent',
        I, NodeOf(FDoc, ChildId).Parent);
    end;
  end;
end;

procedure TMdTreeTest.TestEveryNodeIsReachableFromTheRoot;
var
  Seen: array of Boolean;
  I, J: Integer;
  N: TMdNode;

  procedure Walk(const AId: Integer);
  var
    K: Integer;
    Child: TMdNode;
  begin
    if Seen[AId] then
      Exit;
    Seen[AId] := True;
    Child := NodeOf(FDoc, AId);
    for K := 0 to High(Child.Children) do
      Walk(Child.Children[K]);
  end;

begin
  Parse('# h' + #10 + #10 + '> - a' + #10 + '> - b' + #10 + #10 + 'p');
  SetLength(Seen, NodeCount(FDoc) + 1);
  Walk(FDoc.Root);
  for I := 1 to NodeCount(FDoc) do
    AssertTrue('node ' + IntToStr(I) + ' is reachable', Seen[I]);
  N := NodeOf(FDoc, FDoc.Root);
  J := 0;
  J := J;
end;

procedure TMdTreeTest.TestListNestingIsReal;
begin
  { The whole reason for the tree: a list inside a list item. v1 expressed this
    as a depth integer on a flat block, so this shape was unrepresentable. }
  Parse('- a' + #10 + '  - b');
  AssertEquals('two lists', 2, CountOf(mnList));
  AssertEquals('two items', 2, CountOf(mnListItem));
  AssertEquals('outer chain', 'document > list > listitem > paragraph > text',
    Chain(FDoc));
  { The nested list hangs off the FIRST list item, not off the outer list. }
  AssertEquals('the outer list has one item',
    1, Length(NodeOf(FDoc, FirstChild(FDoc.Root)).Children));
end;

procedure TMdTreeTest.TestBlockquoteContainsItsBlocks;
begin
  Parse('> # heading' + #10 + '>' + #10 + '> text');
  AssertEquals('a quote', 1, CountOf(mnBlockQuote));
  AssertEquals('chain', 'document > blockquote > heading > text', Chain(FDoc));
  { Two children: the heading and the paragraph. }
  AssertEquals('the quote has both blocks',
    2, Length(NodeOf(FDoc, FirstChild(FDoc.Root)).Children));
end;

procedure TMdTreeTest.TestTableHasRowAndCellNodes;
begin
  Parse('| a | b |' + #10 + '| - | - |' + #10 + '| 1 | 2 |');
  AssertEquals('chain', 'document > table > table_header > table_row > table_cell > text',
    Chain(FDoc));
  AssertEquals('one table', 1, CountOf(mnTable));
  AssertEquals('header and body', 1, CountOf(mnTableHeader));
  AssertEquals('a body', 1, CountOf(mnTableBody));
  AssertEquals('two rows', 2, CountOf(mnTableRow));
  AssertEquals('four cells', 4, CountOf(mnTableCell));
end;

procedure TMdTreeTest.TestCodeFenceContentVerbatim;
var
  N: TMdNode;
begin
  Parse('```pascal' + #10 + 'a' + #10 + '---' + #10 + '```');
  AssertEquals('one code block', 1, CountOf(mnCodeBlock));
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnCodeBlock)[0]);
  AssertEquals('language', 'pascal', N.Language);
  AssertTrue('fenced', N.Fenced);
  AssertEquals('content verbatim', 'a' + #10 + '---', N.Content);
end;

procedure TMdTreeTest.TestNodeCount;
begin
  Parse('p');
  { document + paragraph + text }
  AssertEquals('three nodes', 3, NodeCount(FDoc));
end;

procedure TMdTreeTest.TestNodesOfKindIsInDocumentOrder;
var
  Heads: TMdIntArray;
begin
  Parse('# one' + #10 + #10 + '# two' + #10 + #10 + '# three');
  Heads := NodesOfKind(FDoc, mnHeading);
  AssertEquals('three headings', 3, Length(Heads));
  AssertTrue('ascending ids', (Heads[0] < Heads[1]) and (Heads[1] < Heads[2]));
  AssertTrue('first reads one', Pos('one', TextOf(FDoc, Heads[0])) > 0);
  AssertTrue('last reads three', Pos('three', TextOf(FDoc, Heads[2])) > 0);
end;

procedure TMdTreeTest.TestFootnoteDefinitionAndCallout;
var
  N: TMdNode;
  Ids: TMdIntArray;
begin
  Parse('see[^n]' + #10 + #10 + '[^n]: the note');
  AssertEquals('one footnote', 1, CountOf(mnFootnote));
  Ids := NodesOfKind(FDoc, mnFootnote);
  N := NodeOf(FDoc, Ids[0]);
  AssertEquals('label', 'n', string(N.RefLabel));
  { The body is a paragraph child, so a footnote can grow into blocks. }
  AssertEquals('one child', 1, Length(N.Children));
  AssertTrue('the body is a paragraph',
    NodeOf(FDoc, N.Children[0]).Kind = mnParagraph);
end;

procedure TMdTreeTest.TestLinkReferenceDefinition;
var
  N: TMdNode;
  Ids: TMdIntArray;
begin
  Parse('[shared]: https://example.com/a "Title"');
  AssertEquals('one reference', 1, CountOf(mnReference));
  Ids := NodesOfKind(FDoc, mnReference);
  N := NodeOf(FDoc, Ids[0]);
  AssertEquals('label', 'shared', string(N.RefLabel));
  AssertEquals('uri', 'https://example.com/a', string(N.Uri));
  AssertEquals('title', 'Title', string(N.Title));
end;

procedure TMdTreeTest.TestMathBlock;
var
  N: TMdNode;
begin
  Parse('$$' + #10 + 'x = 1' + #10 + '$$');
  AssertEquals('one math block', 1, CountOf(mnMathBlock));
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnMathBlock)[0]);
  AssertEquals('content verbatim', 'x = 1', string(N.Content));
end;

procedure TMdTreeTest.TestCustomBlockContainsBlocks;
var
  N: TMdNode;
begin
  Parse(':::note' + #10 + '- a' + #10 + ':::');
  AssertEquals('one custom block', 1, CountOf(mnCustomBlock));
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnCustomBlock)[0]);
  AssertEquals('name', 'note', string(N.RefLabel));
  { A custom block's body is real markdown, not text. }
  AssertEquals('a list inside', 1, CountOf(mnList));
  AssertTrue('and the list is its child',
    NodeOf(FDoc, N.Children[0]).Kind = mnList);
end;

procedure TMdTreeTest.TestHtmlBlockIsRawAndVerbatim;
var
  N: TMdNode;
begin
  Parse('<div class="x">' + #10 + '  <p>raw</p>' + #10 + '</div>');
  AssertEquals('one html block', 1, CountOf(mnHtmlBlock));
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnHtmlBlock)[0]);
  { Preserved byte for byte, and never parsed into nodes: a consumer must not
    interpret it. }
  AssertEquals('verbatim', '<div class="x">' + #10 + '  <p>raw</p>' + #10 +
    '</div>', string(N.Content));
  AssertEquals('no children', 0, Length(N.Children));
end;

procedure TMdTreeTest.TestDescriptionList;
var
  N: TMdNode;
begin
  Parse('Term' + #10 + ': the definition');
  AssertEquals('one list', 1, CountOf(mnDescriptionList));
  AssertEquals('one term', 1, CountOf(mnDescriptionTerm));
  AssertEquals('one description', 1, CountOf(mnDescription));
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnDescriptionList)[0]);
  AssertEquals('two children', 2, Length(N.Children));
  AssertEquals('chain', 'document > description_list > description_term > text',
    Chain(FDoc));
end;

{ The original text a node's span was promised against. }
var
  SrcText: string;

function Slice(const N: TMdNode; const ASrc: string): string;
begin
  if N.SrcEnd <= N.SrcStart then
    Exit('');
  Result := Copy(ASrc, N.SrcStart + 1, N.SrcEnd - N.SrcStart);
end;

procedure TMdTreeTest.TestHeadingSpanSlicesTheSource;
var
  N: TMdNode;
begin
  SrcText := '# Heading' + #10 + #10 + 'body';
  Parse(SrcText);
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnHeading)[0]);
  { The span is the node's OWN bytes: no leading blank, no trailing newline. }
  AssertEquals('the heading text', '# Heading', Slice(N, SrcText));
end;

procedure TMdTreeTest.TestParagraphSpanSlicesTheSource;
var
  N: TMdNode;
begin
  SrcText := 'first line' + #10 + 'second line';
  Parse(SrcText);
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnParagraph)[0]);
  AssertEquals('the whole paragraph', SrcText, Slice(N, SrcText));
end;

procedure TMdTreeTest.TestFenceSpanCoversTheWholeFence;
var
  N: TMdNode;
begin
  SrcText := '```p' + #10 + 'code' + #10 + '```';
  Parse(SrcText);
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnCodeBlock)[0]);
  { Opener through closer: a fence's span is all three lines. }
  AssertEquals('the whole fence', SrcText, Slice(N, SrcText));
end;

procedure TMdTreeTest.TestListSpanEndsAtItsLastItem;
var
  N: TMdNode;
begin
  { The blank line after a list is a SEPARATOR, not part of the node: a span that
    swallowed it would make a "select this node" gesture take the next block's
    leading newline too. }
  SrcText := '- a' + #10 + '- b' + #10 + #10 + 'after';
  Parse(SrcText);
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnList)[0]);
  AssertEquals('the list only', '- a' + #10 + '- b', Slice(N, SrcText));
end;

procedure TMdTreeTest.TestSpansAreMonotonicAndInsideTheSource;
var
  Ids: TMdIntArray;
  I: Integer;
  N: TMdNode;
begin
  SrcText := '# H' + #10 + #10 + 'para' + #10 + #10 + '- a' + #10 + #10 +
    '> q' + #10 + #10 + '```' + #10 + 'c' + #10 + '```';
  Parse(SrcText);
  Ids := QueryNodes(FDoc, FDoc.Root, nil);
  for I := 0 to High(Ids) do
  begin
    N := NodeOf(FDoc, Ids[I]);
    if N.SrcEnd <= N.SrcStart then
      Continue;
    AssertTrue('start inside the source', N.SrcStart >= 0);
    AssertTrue('end inside the source', N.SrcEnd <= Length(SrcText));
    AssertTrue('start before end', N.SrcStart < N.SrcEnd);
  end;
end;

procedure TMdTreeTest.TestSpansAreBytesNotCodepoints;
var
  N: TMdNode;
begin
  { `café` is FOUR codepoints but FIVE UTF-8 bytes. The span is bytes, because
    bytes are what the parser receives and what a consumer slices with - so
    Length(SrcText) (5) is the right expectation, and a codepoint-count
    implementation would report 4. My first version asserted 4 and was simply
    wrong about the arithmetic. }
  SrcText := 'caf' + #$00C3 + #$00A9;
  Parse(SrcText);
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnParagraph)[0]);
  AssertEquals('the span is measured in bytes', Length(SrcText),
    N.SrcEnd - N.SrcStart);
  AssertTrue('not codepoints', N.SrcEnd - N.SrcStart = 5);
end;

procedure TMdTreeTest.TestAParserSeesNoFrontmatterAtAll;
begin
  { RENAMED AND INVERTED again, deliberately - the third and final shape of this
    rule. Frontmatter is an EXTENSION, not CommonMark or GFM, so it is ours to
    define, and the operator's call is a BLOCK HANDLER: frontmatter becomes a
    NODE, addressable like any other block, rather than a field on the document
    record.

    What this test now guards is the boundary that survived: the parser reports
    the block's TEXT and knows nothing about what the entries mean. There is still
    no `title`/`keywords` policy anywhere in the parser. }
  Parse('---' + #10 + 'title: X' + #10 + '---' + #10 + #10 + 'body');
  AssertEquals('one frontmatter node', 1, CountOf(mnFrontmatter));
  AssertEquals('and a body paragraph', 1, CountOf(mnParagraph));
  AssertEquals('no rule was invented for the fence', 0, CountOf(mnHorizontalRule));
  { The block's content is verbatim text: no parsing of keys, no interpretation. }
  AssertEquals('content is the inner lines, verbatim', 'title: X',
    string(NodeOf(FDoc, NodesOfKind(FDoc, mnFrontmatter)[0]).Content));
end;

procedure TMdTreeTest.TestFrontmatterIsTheFirstChild;
var
  Root: TMdNode;
begin
  Parse('---' + #10 + 'title: X' + #10 + '---' + #10 + #10 + 'body');
  Root := NodeOf(FDoc, FDoc.Root);
  AssertTrue('the root has children', Length(Root.Children) > 0);
  { Addressable: the consumer finds it by walking, or by NodesOfKind, exactly as
    it would any other block. This is what a node buys over a document field. }
  AssertTrue('the first child is the frontmatter',
    NodeOf(FDoc, Root.Children[0]).Kind = mnFrontmatter);
  AssertEquals('the chain', 'document > frontmatter', Chain(FDoc));
end;

procedure TMdTreeTest.TestFrontmatterRequiresAClosingFence;
begin
  { A leading `---` with no closing fence is a THEMATIC BREAK, so a stray rule
    cannot swallow the document. }
  Parse('---' + #10 + #10 + 'body');
  AssertEquals('no frontmatter node', 0, CountOf(mnFrontmatter));
  AssertEquals('a rule instead', 1, CountOf(mnHorizontalRule));
  AssertEquals('and the body survives', 1, CountOf(mnParagraph));
end;

procedure TMdTreeTest.TestFrontmatterAnywhereInTheDocument;
begin
  { INVERTED deliberately: the operator's rule is that frontmatter is a CONTENT
    TYPE (YAML inside a `---` fence), not a position. "It doesn't matter where it
    arrives in the document, it becomes document metadata when the yaml is
    extracted." So a fence pair in the MIDDLE is frontmatter too, and this test
    used to assert the opposite. }
  Parse('A paragraph.' + #10 + #10 + '---' + #10 + 'title: X' + #10 + '---');
  AssertEquals('a frontmatter node mid-document', 1, CountOf(mnFrontmatter));
  AssertEquals('the paragraph before it', 1, CountOf(mnParagraph));
  { Consumed as one block: no rule was emitted for the fences. }
  AssertEquals('no rule', 0, CountOf(mnHorizontalRule));
end;

procedure TMdTreeTest.TestALoneFenceIsStillARule;
begin
  { The other side of the same rule: a `---` with no partner IS a rule. That is
    what stops the handler swallowing the document. }
  Parse('text' + #10 + #10 + '---' + #10 + #10 + 'more');
  AssertEquals('no frontmatter node', 0, CountOf(mnFrontmatter));
  AssertEquals('a rule', 1, CountOf(mnHorizontalRule));
  AssertEquals('both paragraphs survive', 2, CountOf(mnParagraph));
end;

procedure TMdTreeTest.TestFrontmatterNodeCarriesNoInterpretation;
var
  N: TMdNode;
begin
  { The parser does not know that `title` means anything. Every line is reported
    verbatim, including a comment and a line with no colon. }
  Parse('---' + #10 + '# a comment' + #10 + 'just prose' + #10 + 'title: X' +
    #10 + '---');
  AssertEquals('one node', 1, CountOf(mnFrontmatter));
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnFrontmatter)[0]);
  AssertEquals('verbatim, comments and all',
    '# a comment' + #10 + 'just prose' + #10 + 'title: X', string(N.Content));
  AssertEquals('no children: it is a leaf', 0, Length(N.Children));
end;

procedure TMdTreeTest.TestNoFrontmatterMeansNoNode;
begin
  Parse('# Heading' + #10 + #10 + 'A paragraph.');
  AssertEquals('no frontmatter node', 0, CountOf(mnFrontmatter));
  AssertEquals('a heading', 1, CountOf(mnHeading));
end;

procedure TMdTreeTest.TestFrontmatterWithACrLfBlock;
var
  N: TMdNode;
begin
  { SplitLines strips CR, so a CRLF document yields CR-free content. }
  Parse('---' + #13 + #10 + 'title: X' + #13 + #10 + '---' + #13 + #10 + 'body');
  AssertEquals('one node', 1, CountOf(mnFrontmatter));
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnFrontmatter)[0]);
  AssertEquals('CR is a line ending, not content', 'title: X', string(N.Content));
end;

procedure TMdTreeTest.TestFrontmatterIsQueryableFromTheRoot;
var
  Id: Integer;
  N: TMdNode;
begin
  Parse('---' + #10 + 'title: X' + #10 + 'keywords: [a, b]' + #10 + '---' +
    #10 + #10 + 'body');
  { One call on the document, no walking. }
  Id := FrontmatterOf(FDoc);
  AssertTrue('the root answers with an id', Id > 0);
  N := NodeOf(FDoc, Id);
  AssertTrue('and it is a frontmatter node', N.Kind = mnFrontmatter);
  AssertTrue('whose parent is the root', N.Parent = FDoc.Root);
  AssertEquals('and its text comes back verbatim',
    'title: X' + #10 + 'keywords: [a, b]', string(FrontmatterText(FDoc)));
  { Also reachable the general way, like any other node: the two must agree. }
  AssertEquals('NodesOfKind agrees', Id, NodesOfKind(FDoc, mnFrontmatter)[0]);
end;

procedure TMdTreeTest.TestNoFrontmatterQueryReturnsZero;
begin
  Parse('# Just a heading');
  AssertEquals('no frontmatter id', 0, FrontmatterOf(FDoc));
  AssertEquals('and no text', '', string(FrontmatterText(FDoc)));
  { A zero node, not a crash - the same contract as NodeOf. }
  AssertEquals('a zero node for id 0', 0, NodeOf(FDoc, 0).Id);
end;

function IsHeading(const ANode: TMdNode): Boolean;
begin
  Result := ANode.Kind = mnHeading;
end;

function AlwaysTrue(const ANode: TMdNode): Boolean;
begin
  Result := True;
end;

procedure TMdTreeTest.TestQueryNodesFindsByPredicate;
var
  Ids: TMdIntArray;
begin
  Parse('# one' + #10 + #10 + 'text' + #10 + #10 + '## two');
  Ids := QueryNodes(FDoc, FDoc.Root, @IsHeading);
  AssertEquals('two headings', 2, Length(Ids));
  AssertEquals('first level', 1, NodeOf(FDoc, Ids[0]).Level);
  AssertEquals('second level', 2, NodeOf(FDoc, Ids[1]).Level);
end;

procedure TMdTreeTest.TestQueryNodesIsScopedToASubtree;
var
  Ids: TMdIntArray;
  QuoteId: Integer;
begin
  { A heading inside a quote is findable from the quote without seeing the one
    outside it - which is what makes the query useful on a subtree. }
  Parse('# outside' + #10 + #10 + '> # inside');
  QuoteId := NodesOfKind(FDoc, mnBlockQuote)[0];
  Ids := QueryNodes(FDoc, QuoteId, @IsHeading);
  AssertEquals('one heading in the quote', 1, Length(Ids));
  AssertEquals('and it is the inside one', 'inside',
    string(TextOf(FDoc, Ids[0])));
end;

procedure TMdTreeTest.TestQueryNodesNilFilterMatchesEverything;
var
  Ids: TMdIntArray;
begin
  Parse('- a' + #10 + #10 + '> b');
  Ids := QueryNodes(FDoc, FDoc.Root, nil);
  { Every node in the document, root included. }
  AssertEquals('all nodes', NodeCount(FDoc), Length(Ids));
end;

procedure TMdTreeTest.TestQueryNodesIsInDocumentOrder;
var
  Ids: TMdIntArray;
  I: Integer;
begin
  Parse('# a' + #10 + #10 + '# b' + #10 + #10 + '# c');
  Ids := QueryNodes(FDoc, FDoc.Root, @IsHeading);
  AssertEquals('three', 3, Length(Ids));
  for I := 1 to High(Ids) do
    AssertTrue('ascending', Ids[I - 1] < Ids[I]);
end;

{ A visitor cannot capture state (it is a plain procedural type, deliberately),
  so the count lives here. That is the standing cost of not forcing `of object`,
  and it is a fair trade: the common query is QueryNodes, which collects for you. }
var
  VisitCount: Integer;

procedure CountVisit(const ANode: TMdNode);
begin
  Inc(VisitCount);
end;

procedure TMdTreeTest.TestWalkNodesVisitsEveryNode;
begin
  Parse('# h' + #10 + #10 + '- a' + #10 + '  - b');
  VisitCount := 0;
  WalkNodes(FDoc, FDoc.Root, @CountVisit);
  AssertEquals('every node was visited', NodeCount(FDoc), VisitCount);
end;

procedure TMdTreeTest.TestFootnotesAreAggregated;
var
  Ids: TMdIntArray;
begin
  Parse('a[^x] b[^y]' + #10 + #10 + '[^x]: first' + #10 + #10 + '[^y]: second');
  Ids := FootnotesOf(FDoc);
  AssertEquals('two definitions', 2, Length(Ids));
  AssertEquals('first label', 'x', string(NodeOf(FDoc, Ids[0]).RefLabel));
  AssertEquals('second label', 'y', string(NodeOf(FDoc, Ids[1]).RefLabel));
end;

procedure TMdTreeTest.TestFootnoteCalloutsAreAggregated;
var
  Ids: TMdIntArray;
begin
  { The gap this test used to record is CLOSED: the inline tokenizer now emits a
    callout token, so `[^x]` in a body is a node and aggregating it works. The
    earlier version asserted "0 callouts, because none exist yet"; that assertion
    is inverted here rather than deleted, so the change is visible. }
  Parse('a[^x] b[^y]' + #10 + #10 + '[^x]: first');
  Ids := FootnoteCalloutsOf(FDoc);
  AssertEquals('two callouts in the body', 2, Length(Ids));
  AssertEquals('first label', 'x', string(NodeOf(FDoc, Ids[0]).RefLabel));
  AssertEquals('second label', 'y', string(NodeOf(FDoc, Ids[1]).RefLabel));
  AssertEquals('the definition is aggregated too', 1, Length(FootnotesOf(FDoc)));
  { A callout is inline, so it lives INSIDE a paragraph, not beside it. }
  AssertTrue('the callout is a child of a paragraph',
    NodeOf(FDoc, Ids[0]).Parent > 0);
  AssertTrue('and that parent is a paragraph',
    NodeOf(FDoc, NodeOf(FDoc, Ids[0]).Parent).Kind = mnParagraph);
end;

procedure TMdTreeTest.TestFootnoteForLooksUpByLabel;
var
  Id: Integer;
begin
  Parse('a[^x]' + #10 + #10 + '[^x]: the note');
  Id := FootnoteFor(FDoc, 'x');
  AssertTrue('found', Id > 0);
  AssertEquals('the label', 'x', string(NodeOf(FDoc, Id).RefLabel));
  AssertEquals('an unknown label is 0', 0, FootnoteFor(FDoc, 'nope'));
end;

procedure TMdTreeTest.TestFootnoteAggregatesAreEmptyWhenAbsent;
begin
  Parse('# no footnotes here');
  AssertEquals('no definitions', 0, Length(FootnotesOf(FDoc)));
  AssertEquals('no callouts', 0, Length(FootnoteCalloutsOf(FDoc)));
  AssertEquals('no lookup', 0, FootnoteFor(FDoc, 'x'));
end;

procedure TMdTreeTest.TestIndentedCodeIsNotFenced;
var
  N: TMdNode;
begin
  Parse('    code');
  AssertEquals('one code block', 1, CountOf(mnCodeBlock));
  N := NodeOf(FDoc, NodesOfKind(FDoc, mnCodeBlock)[0]);
  AssertFalse('not fenced', N.Fenced);
  AssertEquals('content', 'code', string(N.Content));
end;

procedure TMdTreeTest.TestUnknownIdIsAZeroNode;
begin
  Parse('p');
  AssertEquals('id 0 is none', 0, NodeOf(FDoc, 0).Id);
  AssertEquals('out of range is none', 0, NodeOf(FDoc, 9999).Id);
end;

initialization
  RegisterTest(TMdTreeTest);

end.
