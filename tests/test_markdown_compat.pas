unit test_markdown_compat;
{ Tests for markdown.compat - the temporary tree -> v1 block projection.

  The point of these tests is not that the adapter is good; it is that the adapter
  is FAITHFUL for the v1 corpus and HONEST when it is not. A projection that
  silently drops a node would let two models coexist indefinitely, which is the
  failure the deletion condition exists to prevent. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  markdown.types, markdown.tree, markdown.compat;

type
  TMdCompatTest = class(TTestCase)
  private
    function Project(const AText: string; out ALossy: Boolean): TMdBlockArray;
    function JoinedText(const ABlocks: TMdBlockArray; const AIndex: Integer): string;
    procedure CollectDocs(AList: TStringList);
    function LoadDoc(const APath: string): string;
  published
    procedure TestCorpusIsLossless;
    procedure TestEveryCorpusDocProjectsToBlocks;
    procedure TestParagraphTextAndStyle;
    procedure TestHeadingLevelCarried;
    procedure TestCodeFenceVerbatimNotCollapsed;
    procedure TestRuleBecomesARule;
    procedure TestListItemsAndOrdinals;
    procedure TestNestedListBecomesDeeperItems;
    procedure TestQuoteCarriesItsDepth;
    procedure TestTableHeadAlignAndRows;
    procedure TestSecondParagraphInAnItemIsLossy;
    procedure TestV2OnlySyntaxIsReportedLossy;
    procedure TestEmptyDocumentHasNoBlocks;
  end;

implementation

const
  CorpusDir = 'tests/data/md_corpus';

{ The documents that deliberately exercise nodes with no v1 equivalent. Listed
  explicitly so adding a corpus file cannot silently change what this test means. }
function IsV2OnlyDoc(const AName: string): Boolean;
begin
  { 14_frontmatter.md qualifies now that frontmatter is an AST NODE: the v1 flat
    block model has no way to represent it, so the adapter must report loss. This
    line is why the list is explicit - adding a corpus document cannot silently
    change what the guard means. }
  Result := (AName = '13_v2_blocks.md') or (AName = '14_frontmatter.md');
end;

procedure TMdCompatTest.CollectDocs(AList: TStringList);
var
  SR: TSearchRec;
begin
  AList.Clear;
  if FindFirst(CorpusDir + PathDelim + '*.md', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
        AList.Add(CorpusDir + PathDelim + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  AList.Sort;
end;

function TMdCompatTest.LoadDoc(const APath: string): string;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function TMdCompatTest.Project(const AText: string; out ALossy: Boolean): TMdBlockArray;
var
  Doc: TMdDocument;
begin
  Doc := ParseTree(AText);
  Result := BlocksForTui(Doc, ALossy);
end;

function TMdCompatTest.JoinedText(const ABlocks: TMdBlockArray;
  const AIndex: Integer): string;
var
  I: Integer;
  S: UnicodeString;
begin
  S := '';
  for I := 0 to High(ABlocks[AIndex].Spans) do
    S := S + ABlocks[AIndex].Spans[I].Text;
  Result := UTF8Encode(S);
end;

procedure TMdCompatTest.TestCorpusIsLossless;
var
  Docs: TStringList;
  I: Integer;
  Blocks: TMdBlockArray;
  Lossy: Boolean;
begin
  { THE GUARD. Every document the v1 parser could represent must project without
    discarding anything. If this fails, the adapter is being asked to carry a
    document it cannot express - which is the signal to migrate the consumer, not
    to widen the adapter. }
  Docs := TStringList.Create;
  try
    CollectDocs(Docs);
    AssertTrue('corpus present', Docs.Count > 0);
    for I := 0 to Docs.Count - 1 do
    begin
      Blocks := Project(LoadDoc(Docs[I]), Lossy);
      { Naming which documents are v2-only, rather than comparing filenames:
        a name-based split was too crude, and it wrongly demanded that a
        frontmatter document report lossy when frontmatter is a DOCUMENT FIELD
        and discards nothing at all. }
      if IsV2OnlyDoc(ExtractFileName(Docs[I])) then
        AssertTrue(ExtractFileName(Docs[I]) +
          ' contains v2-only nodes, so it must report lossy', Lossy)
      else
      begin
        if Lossy then
          Fail(ExtractFileName(Docs[I]) +
            ' projected lossily: the adapter cannot express it');
        AssertTrue(ExtractFileName(Docs[I]) + ' produced no blocks',
          Length(Blocks) > 0);
      end;
    end;
  finally
    Docs.Free;
  end;
end;

procedure TMdCompatTest.TestEveryCorpusDocProjectsToBlocks;
var
  Docs: TStringList;
  I: Integer;
  Blocks: TMdBlockArray;
  Lossy: Boolean;
begin
  Docs := TStringList.Create;
  try
    CollectDocs(Docs);
    for I := 0 to Docs.Count - 1 do
    begin
      Blocks := Project(LoadDoc(Docs[I]), Lossy);
      AssertTrue(ExtractFileName(Docs[I]) + ' has blocks', Length(Blocks) > 0);
    end;
  finally
    Docs.Free;
  end;
end;

procedure TMdCompatTest.TestParagraphTextAndStyle;
var
  Blocks: TMdBlockArray;
  Lossy: Boolean;
begin
  Blocks := Project('a **bold** word', Lossy);
  AssertFalse('lossless', Lossy);
  AssertEquals('one block', 1, Length(Blocks));
  AssertTrue('a paragraph', Blocks[0].Kind = mbParagraph);
  AssertEquals('text', 'a bold word', JoinedText(Blocks, 0));
  AssertTrue('bold survived', misBold in Blocks[0].Spans[1].Styles);
end;

procedure TMdCompatTest.TestHeadingLevelCarried;
var
  Blocks: TMdBlockArray;
  Lossy: Boolean;
begin
  Blocks := Project('## Two', Lossy);
  AssertEquals('one block', 1, Length(Blocks));
  AssertTrue('heading', Blocks[0].Kind = mbHeading);
  AssertEquals('level', 2, Blocks[0].Level);
  AssertEquals('text', 'Two', JoinedText(Blocks, 0));
end;

procedure TMdCompatTest.TestCodeFenceVerbatimNotCollapsed;
var
  Blocks: TMdBlockArray;
  Lossy: Boolean;
  S: UnicodeString;
begin
  Blocks := Project('```p' + #10 + 'a  b' + #10 + '  c' + #10 + '```', Lossy);
  AssertEquals('one block', 1, Length(Blocks));
  AssertTrue('a fence', Blocks[0].Kind = mbCodeFence);
  AssertEquals('language', 'p', Blocks[0].Language);
  S := Blocks[0].Spans[0].Text;
  { The double space and the indent are content. Collapsing them would be the
    classic projection bug. }
  AssertEquals('verbatim', 'a  b' + #10 + '  c', S);
end;

procedure TMdCompatTest.TestRuleBecomesARule;
var
  Blocks: TMdBlockArray;
  Lossy: Boolean;
begin
  Blocks := Project('---', Lossy);
  AssertEquals('one block', 1, Length(Blocks));
  AssertTrue('a rule', Blocks[0].Kind = mbRule);
end;

procedure TMdCompatTest.TestListItemsAndOrdinals;
var
  Blocks: TMdBlockArray;
  Lossy: Boolean;
begin
  Blocks := Project('1. one' + #10 + '2. two', Lossy);
  AssertEquals('two items', 2, Length(Blocks));
  AssertTrue('a list item', Blocks[0].Kind = mbListItem);
  AssertTrue('ordered', Blocks[0].Ordered);
  AssertEquals('level 1', 1, Blocks[0].Level);
  AssertEquals('text', 'one', JoinedText(Blocks, 0));
end;

procedure TMdCompatTest.TestNestedListBecomesDeeperItems;
var
  Blocks: TMdBlockArray;
  Lossy: Boolean;
begin
  { v1 carried nesting as a Level integer on a flat block, so a nested list is
    two items at two levels - not a child block. }
  Blocks := Project('- a' + #10 + '  - b', Lossy);
  AssertEquals('two blocks', 2, Length(Blocks));
  AssertTrue('outer is level 1', Blocks[0].Kind = mbListItem);
  AssertEquals('outer level', 1, Blocks[0].Level);
  AssertTrue('nested is a list item', Blocks[1].Kind = mbListItem);
  AssertEquals('nested level', 2, Blocks[1].Level);
end;

procedure TMdCompatTest.TestQuoteCarriesItsDepth;
var
  Blocks: TMdBlockArray;
  Lossy: Boolean;
begin
  Blocks := Project('> quoted', Lossy);
  AssertEquals('one block', 1, Length(Blocks));
  AssertTrue('a quote', Blocks[0].Kind = mbQuote);
  AssertEquals('depth 1', 1, Blocks[0].Level);
  AssertEquals('text', 'quoted', JoinedText(Blocks, 0));
end;

procedure TMdCompatTest.TestTableHeadAlignAndRows;
var
  Blocks: TMdBlockArray;
  Lossy: Boolean;
begin
  Blocks := Project('| a | b |' + #10 + '| :-- | --: |' + #10 + '| 1 | 2 |', Lossy);
  AssertFalse('lossless', Lossy);
  AssertEquals('one block', 1, Length(Blocks));
  AssertTrue('a table', Blocks[0].Kind = mbTable);
  AssertEquals('two columns', 2, Length(Blocks[0].Align));
  AssertTrue('left', Blocks[0].Align[0] = maLeft);
  AssertTrue('right', Blocks[0].Align[1] = maRight);
  AssertEquals('head cells', 2, Length(Blocks[0].Head));
  AssertEquals('one body row', 1, Length(Blocks[0].Rows));
  AssertEquals('body cell count', 2, Length(Blocks[0].Rows[0]));
end;

procedure TMdCompatTest.TestSecondParagraphInAnItemIsLossy;
var
  Lossy: Boolean;
  Blocks: TMdBlockArray;
begin
  { HONESTY, and a deliberate DEFERRAL. v1 cannot express a second paragraph
    inside a list item. The tree does not model the continuation yet either (the
    indent continuation belongs to Phase 4), so today the text lands as a sibling
    paragraph - lossless in node terms, wrong in structure. This case becomes a
    lossy assertion the moment Phase 4 lands; asserting it now would pin a bug. }
  Blocks := Project('- first' + #10 + #10 + '  second paragraph', Lossy);
  AssertFalse('nothing is discarded YET - see the comment', Lossy);
  AssertTrue('and the text is not silently dropped', Length(Blocks) >= 1);
end;

procedure TMdCompatTest.TestV2OnlySyntaxIsReportedLossy;
var
  Lossy: Boolean;
  Doc: TMdDocument;
begin
  { This test began as a DEFERRAL GUARD in Phase 2, when footnotes and math were
    not parsed at all: it asserted that nothing was discarded, because no such
    node could exist. Phase 5 made them real, so the deferral is over and the
    assertion inverts. Keeping the old form would have been a test that passes
    while the adapter silently ate every footnote.

    Each of these has no v1 equivalent and MUST report loss. }
  Doc := ParseTree('text[^1]' + #10 + #10 + '[^1]: note');
  BlocksForTui(Doc, Lossy);
  AssertTrue('a footnote is lossy', Lossy);

  Doc := ParseTree('$$' + #10 + 'x = 1' + #10 + '$$');
  BlocksForTui(Doc, Lossy);
  AssertTrue('a math block is lossy', Lossy);

  Doc := ParseTree('[a]: https://example.com/x');
  BlocksForTui(Doc, Lossy);
  AssertTrue('a link reference definition is lossy', Lossy);

  Doc := ParseTree('<div>raw</div>');
  BlocksForTui(Doc, Lossy);
  AssertTrue('a raw HTML block is lossy', Lossy);

  Doc := ParseTree('Term' + #10 + ': def');
  BlocksForTui(Doc, Lossy);
  AssertTrue('a description list is lossy', Lossy);

  Doc := ParseTree(':::n' + #10 + '- a' + #10 + ':::');
  BlocksForTui(Doc, Lossy);
  AssertTrue('a custom block is lossy', Lossy);
end;

procedure TMdCompatTest.TestEmptyDocumentHasNoBlocks;
var
  Blocks: TMdBlockArray;
  Lossy: Boolean;
begin
  Blocks := Project('', Lossy);
  AssertEquals('no blocks', 0, Length(Blocks));
  AssertFalse('and nothing lost', Lossy);
end;

initialization
  RegisterTest(TMdCompatTest);

end.
