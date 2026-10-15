unit test_replymeta;
{ fpcunit tests for hildegard.helper.replymeta: the tolerant frontmatter
  extractor (title + keywords, body stripped) and the streaming suppressor. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.replymeta;

function ListHasKeyword(const AList: TStringArray; const AWord: string): Boolean;

type
  TReplyMetaTest = class(TTestCase)
  published
    { The extractor. }
    procedure TestExtractsTitleAndKeywords;
    procedure TestBodyIsStripped;
    procedure TestNoBlockIsUnchanged;
    procedure TestUnterminatedBlockIsUnchanged;
    procedure TestRuleInBodyIsNotABlock;
    procedure TestBracketKeywords;
    procedure TestListItemKeywords;
    procedure TestUnknownKeysIgnored;
    procedure TestCrlf;
    procedure TestEmptyTitle;
    procedure TestMissingClosingFenceEndsAtBlankLine;
    procedure TestBlankLineAfterOpeningFence;
    procedure TestDuplicateKeywordsDeduped;
    procedure TestKeywordsLowercased;
    { The suppressor. }
    procedure TestSuppressorHidesTheBlock;
    procedure TestSuppressorFlushesBody;
    procedure TestSuppressorNoBlockFlushesAll;
    procedure TestSuppressorAcrossEveryBoundary;
    procedure TestSuppressorLaterRuleIsNotABlock;
    procedure TestSuppressorMissingFenceEndsAtBlankLine;
    procedure TestFlushReleasesAnUnclosedBlock;
  end;

implementation

function ListHasKeyword(const AList: TStringArray; const AWord: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AList) do
    if AList[I] = AWord then
      Exit(True);
  Result := False;
end;
procedure TReplyMetaTest.TestExtractsTitleAndKeywords;
var
  M: TReplyMeta;
begin
  M := ExtractReplyMeta('---' + #10 + 'title: Refactor the drain' + #10 +
    'keywords: [drain, tui, freeze]' + #10 + '---' + #10 + 'The body.');
  AssertTrue('has meta', M.HasMeta);
  AssertEquals('title', 'Refactor the drain', M.Title);
  AssertEquals('three keywords', 3, Length(M.Keywords));
  AssertTrue('drain', ListHasKeyword(M.Keywords, 'drain'));
  AssertTrue('tui', ListHasKeyword(M.Keywords, 'tui'));
  AssertTrue('freeze', ListHasKeyword(M.Keywords, 'freeze'));
end;

procedure TReplyMetaTest.TestBodyIsStripped;
var
  M: TReplyMeta;
begin
  M := ExtractReplyMeta('---' + #10 + 'title: T' + #10 + '---' + #10 +
    'line one' + #10 + 'line two');
  AssertEquals('body without the block', 'line one' + #10 + 'line two', M.Body);
end;

procedure TReplyMetaTest.TestNoBlockIsUnchanged;
var
  M: TReplyMeta;
begin
  M := ExtractReplyMeta('Just a reply.' + #10 + 'No frontmatter here.');
  AssertFalse('no meta', M.HasMeta);
  AssertEquals('unchanged', 'Just a reply.' + #10 + 'No frontmatter here.', M.Body);
end;

procedure TReplyMetaTest.TestUnterminatedBlockIsUnchanged;
var
  M: TReplyMeta;
begin
  M := ExtractReplyMeta('---' + #10 + 'title: T' + #10 + 'no close');
  AssertFalse('no meta', M.HasMeta);
  AssertEquals('unchanged', '---' + #10 + 'title: T' + #10 + 'no close', M.Body);
end;

procedure TReplyMetaTest.TestMissingClosingFenceEndsAtBlankLine;
var
  M: TReplyMeta;
begin
  { The model forgot the closing `---` but left a blank line after the block:
    the blank line ends it, so the title/keywords are still read and the body is
    the text after the blank line. }
  M := ExtractReplyMeta('---' + #10 + 'title: Fix the drain' + #10 +
    'keywords: [tui, drain]' + #10 + #10 + 'Here is the body.');
  AssertTrue('has meta', M.HasMeta);
  AssertEquals('title read', 'Fix the drain', M.Title);
  AssertTrue('keyword read', ListHasKeyword(M.Keywords, 'drain'));
  AssertEquals('body after the blank line', 'Here is the body.', M.Body);
end;

procedure TReplyMetaTest.TestBlankLineAfterOpeningFence;
var
  M: TReplyMeta;
begin
  { The operator's real-world case: a blank line right after the opening `---`
    (and no closing fence). The leading blank line must NOT close the block (no
    content yet); the blank line after the keywords does. }
  M := ExtractReplyMeta('---' + #10 + #10 + 'title: This is the Tigle' + #10 +
    'keywords: [test]' + #10 + #10 + 'The rest of the response is here');
  AssertTrue('has meta', M.HasMeta);
  AssertEquals('title read', 'This is the Tigle', M.Title);
  AssertTrue('keyword read', ListHasKeyword(M.Keywords, 'test'));
  AssertEquals('body', 'The rest of the response is here', M.Body);
end;

procedure TReplyMetaTest.TestRuleInBodyIsNotABlock;
var
  M: TReplyMeta;
begin
  { The first line is not a fence, so a later `---` is a rule, not frontmatter. }
  M := ExtractReplyMeta('Intro.' + #10 + '---' + #10 + 'After the rule.');
  AssertFalse('no meta', M.HasMeta);
end;

procedure TReplyMetaTest.TestBracketKeywords;
var
  M: TReplyMeta;
begin
  M := ExtractReplyMeta('---' + #10 + 'keywords: [a, b , c]' + #10 + '---' + #10 + 'x');
  AssertEquals('three', 3, Length(M.Keywords));
  AssertEquals('trimmed', 'b', M.Keywords[1]);
end;

procedure TReplyMetaTest.TestListItemKeywords;
var
  M: TReplyMeta;
begin
  M := ExtractReplyMeta('---' + #10 + 'keywords:' + #10 + '- alpha' + #10 +
    '- beta' + #10 + '---' + #10 + 'x');
  AssertEquals('two', 2, Length(M.Keywords));
  AssertEquals('alpha', 'alpha', M.Keywords[0]);
  AssertEquals('beta', 'beta', M.Keywords[1]);
end;

procedure TReplyMetaTest.TestUnknownKeysIgnored;
var
  M: TReplyMeta;
begin
  M := ExtractReplyMeta('---' + #10 + 'title: T' + #10 + 'author: someone' +
    #10 + 'tags: x' + #10 + '---' + #10 + 'body');
  AssertTrue('has meta', M.HasMeta);
  AssertEquals('title read', 'T', M.Title);
  AssertEquals('unknown keys add no keywords', 0, Length(M.Keywords));
end;

procedure TReplyMetaTest.TestCrlf;
var
  M: TReplyMeta;
begin
  M := ExtractReplyMeta('---' + #13#10 + 'title: T' + #13#10 + 'keywords: [a]' +
    #13#10 + '---' + #13#10 + 'body');
  AssertTrue('has meta', M.HasMeta);
  AssertEquals('title', 'T', M.Title);
  AssertTrue('keyword', ListHasKeyword(M.Keywords, 'a'));
end;

procedure TReplyMetaTest.TestEmptyTitle;
var
  M: TReplyMeta;
begin
  M := ExtractReplyMeta('---' + #10 + 'title:' + #10 + '---' + #10 + 'body');
  AssertTrue('has meta', M.HasMeta);
  AssertEquals('empty title', '', M.Title);
end;

procedure TReplyMetaTest.TestDuplicateKeywordsDeduped;
var
  M: TReplyMeta;
begin
  M := ExtractReplyMeta('---' + #10 + 'keywords: [a, A, a, b]' + #10 + '---' + #10 + 'x');
  AssertEquals('deduped', 2, Length(M.Keywords));
end;

procedure TReplyMetaTest.TestKeywordsLowercased;
var
  M: TReplyMeta;
begin
  M := ExtractReplyMeta('---' + #10 + 'keywords: [Drain, TUI]' + #10 + '---' + #10 + 'x');
  AssertTrue('drain', ListHasKeyword(M.Keywords, 'drain'));
  AssertTrue('tui', ListHasKeyword(M.Keywords, 'tui'));
end;

{ The suppressor. }

procedure TReplyMetaTest.TestSuppressorHidesTheBlock;
var
  S: TFrontMatterSuppressor;
  Out1, Out2, Out3: string;
begin
  S := Default(TFrontMatterSuppressor);
  { Feed the whole block + body in pieces. Nothing of the block shows. }
  SuppressFrontMatter(S, '---' + #10, Out1);
  AssertEquals('nothing yet', '', Out1);
  SuppressFrontMatter(S, 'title: T' + #10, Out2);
  AssertEquals('still nothing', '', Out2);
  SuppressFrontMatter(S, '---' + #10 + 'the body', Out3);
  AssertEquals('body after the block', 'the body', Out3);
end;

procedure TReplyMetaTest.TestSuppressorFlushesBody;
var
  S: TFrontMatterSuppressor;
  Out: string;
begin
  S := Default(TFrontMatterSuppressor);
  SuppressFrontMatter(S, 'no block here', Out);
  AssertEquals('flushed', 'no block here', Out);
end;

procedure TReplyMetaTest.TestSuppressorNoBlockFlushesAll;
var
  S: TFrontMatterSuppressor;
  Out: string;
begin
  { A reply that starts with `---x` (not a fence) is body; the partial `---`
    must not be swallowed. }
  S := Default(TFrontMatterSuppressor);
  SuppressFrontMatter(S, '--', Out);
  AssertEquals('prefix buffered', '', Out);
  SuppressFrontMatter(S, '-x rest', Out);
  AssertEquals('whole thing flushed', '---x rest', Out);
end;

procedure TReplyMetaTest.TestSuppressorAcrossEveryBoundary;
var
  S: TFrontMatterSuppressor;
  Full: string;
  I: Integer;
  Out, Acc: string;
begin
  { Feeding the reply one char at a time must yield exactly the body, no matter
    where the boundaries fall. }
  Full := '---' + #10 + 'title: T' + #10 + 'keywords: [a]' + #10 + '---' + #10 +
    'the body text';
  S := Default(TFrontMatterSuppressor);
  Acc := '';
  for I := 1 to Length(Full) do
  begin
    SuppressFrontMatter(S, Full[I], Out);
    Acc := Acc + Out;
  end;
  AssertEquals('body only', 'the body text', Acc);
end;

procedure TReplyMetaTest.TestSuppressorLaterRuleIsNotABlock;
var
  S: TFrontMatterSuppressor;
  Out, Acc: string;
begin
  { A reply whose first line is text: everything flushes, including a later
    `---` rule. }
  S := Default(TFrontMatterSuppressor);
  Acc := '';
  SuppressFrontMatter(S, 'Intro' + #10, Out);
  Acc := Acc + Out;
  SuppressFrontMatter(S, '---' + #10, Out);
  Acc := Acc + Out;
  SuppressFrontMatter(S, 'more', Out);
  Acc := Acc + Out;
  AssertEquals('all flushed', 'Intro' + #10 + '---' + #10 + 'more', Acc);
end;

procedure TReplyMetaTest.TestSuppressorMissingFenceEndsAtBlankLine;
var
  S: TFrontMatterSuppressor;
  Out, Acc: string;
begin
  { The missing-closing-fence case: the block is withheld, then a blank line
    ends it and the body after the blank line is shown. }
  S := Default(TFrontMatterSuppressor);
  Acc := '';
  SuppressFrontMatter(S, '---' + #10, Out);
  Acc := Acc + Out;
  SuppressFrontMatter(S, 'title: T' + #10, Out);
  Acc := Acc + Out;
  SuppressFrontMatter(S, #10 + 'the body', Out);
  Acc := Acc + Out;
  AssertEquals('block hidden, body shown', 'the body', Acc);
end;

procedure TReplyMetaTest.TestFlushReleasesAnUnclosedBlock;
var
  S: TFrontMatterSuppressor;
  Out, Acc: string;
begin
  { A block that never closes (no fence, no blank line) is not frontmatter: the
    end-of-reply flush must release its bytes so the reply is not blank. }
  S := Default(TFrontMatterSuppressor);
  Acc := '';
  SuppressFrontMatter(S, '---' + #10, Out);
  Acc := Acc + Out;
  SuppressFrontMatter(S, 'title: T' + #10 + 'no close', Out);
  Acc := Acc + Out;
  AssertEquals('still withheld', '', Acc);
  AssertTrue('flush releases', FlushFrontMatter(S, Out));
  Acc := Acc + Out;
  { The opening `---` was consumed as the fence; the withheld bytes are what
    followed it. }
  AssertEquals('the withheld bytes are the body',
    'title: T' + #10 + 'no close', Acc);
end;

initialization
  RegisterTest(TReplyMetaTest);
end.
