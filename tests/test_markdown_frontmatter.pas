unit test_markdown_frontmatter;
{ Tests for markdown.frontmatter - the pure UTILITY that detects frontmatter.

  The split this file exists to prove: the parser (markdown.tree) does not know
  frontmatter exists, and this utility is how the HARNESS finds out. So these
  tests assert detection and extraction, and test_markdown_tree asserts that a
  parse reports nothing at all. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  markdown.types, markdown.tree, markdown.frontmatter;

type
  TMdFrontmatterTest = class(TTestCase)
  private
    function Entries(const AText: string): TMdFrontEntries;
    function EntryValue(const AText: string; const AKey: string): string;
  published
    procedure TestHasFrontmatterForALeadingBlock;
    procedure TestNoFrontmatterWithoutAFencePair;
    procedure TestALeadingFenceWithNoCloseIsNotFrontmatter;
    procedure TestAFencePairAfterContentIsNotFrontmatter;
    procedure TestEntriesAreExtractedInOrder;
    procedure TestACommentAndBlankLineAreNotEntries;
    procedure TestALineWithNoColonIsAKeyWithNoValue;
    procedure TestRawIsTheInnerBlock;
    procedure TestStripRemovesTheBlock;
    procedure TestStripLeavesTheBodyWhenThereIsNone;
    procedure TestEmptyDocument;
    procedure TestCrLfBlock;
    procedure TestBodyAfterTheBlockIsNotMetadata;
  end;

implementation

function TMdFrontmatterTest.Entries(const AText: string): TMdFrontEntries;
var
  Raw: UnicodeString;
begin
  ExtractFrontmatter(AText, Result, Raw);
end;

function TMdFrontmatterTest.EntryValue(const AText: string;
  const AKey: string): string;
var
  E: TMdFrontEntries;
  I: Integer;
begin
  Result := '';
  E := Entries(AText);
  for I := 0 to High(E) do
    if string(E[I].Key) = AKey then
      Exit(string(E[I].Value));
end;

procedure TMdFrontmatterTest.TestHasFrontmatterForALeadingBlock;
begin
  AssertTrue('a leading block',
    HasFrontmatter('---' + #10 + 'title: X' + #10 + '---' + #10 + 'body'));
end;

procedure TMdFrontmatterTest.TestNoFrontmatterWithoutAFencePair;
begin
  AssertFalse('plain text', HasFrontmatter('just a paragraph'));
  AssertFalse('a single rule', HasFrontmatter('---' + #10 + 'text'));
  AssertFalse('empty', HasFrontmatter(''));
end;

procedure TMdFrontmatterTest.TestALeadingFenceWithNoCloseIsNotFrontmatter;
begin
  { Structural, and load-bearing: a stray `---` must not swallow the document. }
  AssertFalse('no closing fence',
    HasFrontmatter('---' + #10 + '' + #10 + 'body'));
end;

procedure TMdFrontmatterTest.TestAFencePairAfterContentIsNotFrontmatter;
begin
  { Frontmatter is the FIRST block. A fence pair further down is ordinary
    markdown - this is what makes the rule structural rather than a key sniff. }
  AssertFalse('not first',
    HasFrontmatter('A paragraph.' + #10 + #10 + '---' + #10 + 'title: X' +
      #10 + '---'));
end;

procedure TMdFrontmatterTest.TestEntriesAreExtractedInOrder;
var
  E: TMdFrontEntries;
begin
  E := Entries('---' + #10 + 'title: Hello' + #10 + 'draft: true' + #10 +
    '---' + #10 + 'body');
  AssertEquals('two entries', 2, Length(E));
  AssertEquals('first key', 'title', string(E[0].Key));
  AssertEquals('first value', 'Hello', string(E[0].Value));
  AssertEquals('second key', 'draft', string(E[1].Key));
  AssertEquals('second value', 'true', string(E[1].Value));
end;

procedure TMdFrontmatterTest.TestACommentAndBlankLineAreNotEntries;
var
  E: TMdFrontEntries;
begin
  E := Entries('---' + #10 + '# a comment' + #10 + '' + #10 + 'title: X' +
    #10 + '---');
  AssertEquals('one entry', 1, Length(E));
  AssertEquals('the key', 'title', string(E[0].Key));
end;

procedure TMdFrontmatterTest.TestALineWithNoColonIsAKeyWithNoValue;
var
  E: TMdFrontEntries;
begin
  { Reported, not interpreted and not dropped: a malformed entry should be
    visible to the caller rather than silently vanishing. }
  E := Entries('---' + #10 + 'just some prose' + #10 + '---');
  AssertEquals('one entry', 1, Length(E));
  AssertEquals('kept as a key', 'just some prose', string(E[0].Key));
  AssertEquals('with no value', '', string(E[0].Value));
end;

procedure TMdFrontmatterTest.TestRawIsTheInnerBlock;
var
  E: TMdFrontEntries;
  Raw: UnicodeString;
begin
  ExtractFrontmatter('---' + #10 + 'a: 1' + #10 + 'b: 2' + #10 + '---' +
    #10 + 'body', E, Raw);
  AssertEquals('raw is the inner lines only', 'a: 1' + #10 + 'b: 2',
    string(Raw));
end;

procedure TMdFrontmatterTest.TestStripRemovesTheBlock;
begin
  AssertEquals('body only',
    'body', StripFrontmatter('---' + #10 + 'title: X' + #10 + '---' + #10 + 'body'));
end;

procedure TMdFrontmatterTest.TestStripLeavesTheBodyWhenThereIsNone;
begin
  AssertEquals('unchanged', 'just a paragraph',
    StripFrontmatter('just a paragraph'));
end;

procedure TMdFrontmatterTest.TestEmptyDocument;
var
  E: TMdFrontEntries;
  Raw: UnicodeString;
begin
  AssertFalse('nothing to find', ExtractFrontmatter('', E, Raw));
  AssertEquals('no entries', 0, Length(E));
  AssertEquals('no raw', '', string(Raw));
  AssertEquals('strip is empty', '', StripFrontmatter(''));
end;

procedure TMdFrontmatterTest.TestCrLfBlock;
begin
  AssertTrue('CRLF fences are still fences',
    HasFrontmatter('---' + #13 + #10 + 'title: X' + #13 + #10 + '---' + #13 +
      #10 + 'body'));
  AssertEquals('the value survived', 'X', EntryValue(
    '---' + #13 + #10 + 'title: X' + #13 + #10 + '---' + #13 + #10 + 'body',
    'title'));
end;

procedure TMdFrontmatterTest.TestBodyAfterTheBlockIsNotMetadata;
var
  E: TMdFrontEntries;
begin
  { A `key: value` line in the BODY must not leak into the entries. }
  E := Entries('---' + #10 + 'title: X' + #10 + '---' + #10 + 'note: body line');
  AssertEquals('one entry only', 1, Length(E));
  AssertEquals('the metadata key', 'title', string(E[0].Key));
end;

initialization
  RegisterTest(TMdFrontmatterTest);

end.
