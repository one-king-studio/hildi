unit test_markdown_tree;
{ Tests for the v2 node tree (markdown.tree).

  What is asserted here is the SHAPE, not the rendered text: nesting, identity,
  links and source offsets. A renderer test would pass on a flattened model, which
  is exactly the defect the tree exists to prevent. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  markdown.types, markdown.tree;

type
  TMdTreeTest = class(TTestCase)
  private
    FDoc: TMdDocument;
    procedure Parse(const AText: string);
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
    { frontmatter }
    procedure TestFrontmatterIsADocumentField;
    procedure TestFrontmatterIsNotABodyNode;
    procedure TestFrontmatterWithoutClosingFenceIsARule;
    procedure TestFrontmatterWithACommentAndBlankLine;
    procedure TestFrontmatterRawIsPreserved;
    procedure TestNoFrontmatterLeavesMetadataEmpty;
    { The parser FOLLOWS the frontmatter rules; it does not enforce presence.
      These pin the recognition rule it shares with the response layer. }
    procedure TestAFenceWithoutAMetadataKeyIsABreak;
    procedure TestFrontmatterKeyPresenceIsTheSignalNotItsValue;
    procedure TestBodyWithoutFrontmatterParsesNormally;
  end;

implementation

procedure TMdTreeTest.Parse(const AText: string);
begin
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
  AssertEquals('same node count', NodeCount(A), NodeCount(B));
  for I := 1 to NodeCount(A) do
  begin
    AssertTrue('same kind at ' + IntToStr(I),
      NodeOf(A, I).Kind = NodeOf(B, I).Kind);
    AssertEquals('same parent at ' + IntToStr(I),
      NodeOf(A, I).Parent, NodeOf(B, I).Parent);
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

procedure TMdTreeTest.TestFrontmatterIsADocumentField;
begin
  Parse('---' + #10 + 'title: Hello' + #10 + 'draft: true' + #10 + '---' +
    #10 + #10 + 'body');
  AssertEquals('two entries', 2, Length(FDoc.Metadata));
  AssertEquals('key 1', 'title', string(FDoc.Metadata[0].Key));
  AssertEquals('value 1', 'Hello', string(FDoc.Metadata[0].Value));
  AssertEquals('key 2', 'draft', string(FDoc.Metadata[1].Key));
  AssertEquals('value 2', 'true', string(FDoc.Metadata[1].Value));
end;

procedure TMdTreeTest.TestFrontmatterIsNotABodyNode;
begin
  { SPEC 10.3: metadata is NOT a node, so a renderer walking the tree never sees
    it and cannot accidentally paint it into the document. }
  Parse('---' + #10 + 'title: Hello' + #10 + '---' + #10 + #10 + 'body');
  AssertEquals('one paragraph of body', 1, CountOf(mnParagraph));
  AssertEquals('chain', 'document > paragraph > text', Chain(FDoc));
  AssertEquals('the body text is just the body', 'body',
    string(NodeOf(FDoc, FirstChild(FirstChild(FDoc.Root))).Content));
  AssertEquals('no rule was emitted for the fences', 0, CountOf(mnHorizontalRule));
end;

procedure TMdTreeTest.TestFrontmatterWithoutClosingFenceIsARule;
begin
  { A leading `---` with no closing line is a THEMATIC BREAK, not an unterminated
    frontmatter block. Treating it as frontmatter would swallow the document. }
  Parse('---' + #10 + #10 + 'body');
  AssertEquals('no metadata', 0, Length(FDoc.Metadata));
  AssertEquals('a rule', 1, CountOf(mnHorizontalRule));
  AssertEquals('and the body survives', 1, CountOf(mnParagraph));
end;

procedure TMdTreeTest.TestFrontmatterWithACommentAndBlankLine;
begin
  Parse('---' + #10 + '# a comment' + #10 + '' + #10 + 'title: X' + #10 +
    '---' + #10 + 'body');
  { A comment and a blank line are not entries, but they are kept in the raw. }
  AssertEquals('one entry', 1, Length(FDoc.Metadata));
  AssertEquals('key', 'title', string(FDoc.Metadata[0].Key));
end;

procedure TMdTreeTest.TestFrontmatterRawIsPreserved;
begin
  { The block must carry a metadata KEY to be frontmatter at all, so this uses
    real keys. `a: 1` / `b: 2` alone is NOT frontmatter under the shared rule -
    see TestAFenceWithoutAMetadataKeyIsABreak. }
  Parse('---' + #10 + 'title: T' + #10 + 'extra: 2' + #10 + '---' + #10 + 'body');
  AssertEquals('raw keeps every line', 'title: T' + #10 + 'extra: 2',
    string(FDoc.MetadataRaw));
  AssertEquals('two entries parsed', 2, Length(FDoc.Metadata));
end;

procedure TMdTreeTest.TestAFenceWithoutAMetadataKeyIsABreak;
begin
  { A `---` fence with nothing but prose between the fences carries no `title`
    or `keywords`, so it is ordinary markdown: a rule, text, then a rule. This is
    the SAME rule hildegard.helper.replymeta uses, which is the point - the
    parser and the response layer must not disagree about what frontmatter is. }
  Parse('---' + #10 + 'just some prose' + #10 + '---');
  AssertEquals('no metadata', 0, Length(FDoc.Metadata));
  { My first expectation here - "two rules" - was wrong, and the failure was
    correct: the leading `---` is a rule, and the SECOND `---` sits directly under
    `just some prose`, which is a SETEXT heading underline. So the right shape is
    a rule then a level-2 heading. Asserting two rules would have pinned a
    misunderstanding of our own setext pass. }
  AssertEquals('one rule', 1, CountOf(mnHorizontalRule));
  AssertEquals('one heading', 1, CountOf(mnHeading));
  AssertEquals('at level 2', 2, NodeOf(FDoc,
    NodesOfKind(FDoc, mnHeading)[0]).Level);
end;

procedure TMdTreeTest.TestFrontmatterKeyPresenceIsTheSignalNotItsValue;
begin
  { `title:` with an EMPTY value is still frontmatter: the model wrote a header.
    Presence of the key is the signal, not a non-empty value. }
  Parse('---' + #10 + 'title:' + #10 + '---' + #10 + 'body');
  AssertEquals('one entry', 1, Length(FDoc.Metadata));
  AssertEquals('key', 'title', string(FDoc.Metadata[0].Key));
  AssertEquals('empty value', '', string(FDoc.Metadata[0].Value));
end;

procedure TMdTreeTest.TestBodyWithoutFrontmatterParsesNormally;
begin
  { The parser does not REQUIRE frontmatter. Enforcement is the response
    protocol's job; a body with none must parse exactly as it always did. }
  Parse('# Heading' + #10 + #10 + 'A paragraph.');
  AssertEquals('no metadata', 0, Length(FDoc.Metadata));
  AssertEquals('a heading', 1, CountOf(mnHeading));
  AssertEquals('a paragraph', 1, CountOf(mnParagraph));
end;

procedure TMdTreeTest.TestNoFrontmatterLeavesMetadataEmpty;
begin
  Parse('# just a heading');
  AssertEquals('no metadata', 0, Length(FDoc.Metadata));
  AssertEquals('no raw', '', string(FDoc.MetadataRaw));
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
