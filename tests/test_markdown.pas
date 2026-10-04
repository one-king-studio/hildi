unit test_markdown;
{ fpcunit tests for hildegard.helper.markdown: the block pass, the inline
  scanner, the theme mapping, and incremental append. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.markdown,
  hildegard.helper.tui.base, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.surface;

type
  TMarkdownTest = class(TTestCase)
  private
    FParser: TMarkdownParser;
    FBlocks: TMdBlockArray;
    function Parse(const AText: string): TMdBlockArray;
    function JoinedText(ABlockIndex: Integer): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestEmptyInputYieldsNoBlocks;
    procedure TestHeadingLevels;
    procedure TestSevenHashesIsParagraph;
    procedure TestParagraphSplitsOnBlankLine;
    procedure TestBulletListItems;
    procedure TestOrderedListItems;
    procedure TestOrderedOrdinalCaptured;
    procedure TestListInterruptsParagraph;
    procedure TestLooseListItemsAreAllKept;
    procedure TestBlockquoteNesting;
    procedure TestHorizontalRule;
    procedure TestFencedCodeIsVerbatim;
    procedure TestFencedCodeLanguageCaptured;
    procedure TestUnterminatedFenceIsCodeAtEof;
    procedure TestMarkerNotAtLineStartIsLiteral;
    procedure TestInlineBoldItalicCode;
    procedure TestInlineStrike;
    procedure TestInlineLinkTargetCaptured;
    procedure TestMalformedMarkupRendersLiterally;
    procedure TestWhitespaceCollapsedInParagraph;
    procedure TestCodeBlocksCarryNoInlineStyles;
    procedure TestStyleForMapsEachInlineStyle;
    procedure TestBlockAttrMapsEachBlockKind;
    procedure TestHeadingAttrUsesTheLevel;
    procedure TestOpenTailIsPlainText;
    procedure TestIncrementalAppendMatchesFullParse;
    procedure TestAppendAfterReset;
    procedure TestStyledSpansFeedTextBlock;
  end;

implementation

procedure TMarkdownTest.SetUp;
begin
  FParser := TMarkdownParser.Create;
end;

procedure TMarkdownTest.TearDown;
begin
  FParser.Free;
  FParser := nil;
end;

function TMarkdownTest.Parse(const AText: string): TMdBlockArray;
begin
  FBlocks := FParser.Parse(AText);
  Result := FBlocks;
end;

function TMarkdownTest.JoinedText(ABlockIndex: Integer): string;
var
  I: Integer;
  S: UnicodeString;
begin
  S := '';
  for I := 0 to High(FBlocks[ABlockIndex].Spans) do
    S := S + FBlocks[ABlockIndex].Spans[I].Text;
  Result := string(S);
end;

procedure TMarkdownTest.TestEmptyInputYieldsNoBlocks;
begin
  AssertEquals('no blocks', 0, Length(Parse('')));
end;

procedure TMarkdownTest.TestHeadingLevels;
begin
  FBlocks := Parse('# One' + #10 + #10 + '###### Six');
  AssertEquals('two blocks', 2, Length(FBlocks));
  AssertTrue('first is a heading', FBlocks[0].Kind = mbHeading);
  AssertEquals('level 1', 1, FBlocks[0].Level);
  AssertEquals('heading text', 'One', JoinedText(0));
  AssertTrue('second is a heading', FBlocks[1].Kind = mbHeading);
  AssertEquals('level 6', 6, FBlocks[1].Level);
end;

procedure TMarkdownTest.TestSevenHashesIsParagraph;
begin
  FBlocks := Parse('####### Seven');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('a paragraph, not a heading', FBlocks[0].Kind = mbParagraph);
  AssertEquals('literal text', '####### Seven', JoinedText(0));
end;

procedure TMarkdownTest.TestParagraphSplitsOnBlankLine;
begin
  FBlocks := Parse('a' + #10 + #10 + 'b');
  AssertEquals('two paragraphs', 2, Length(FBlocks));
  AssertTrue('p1', FBlocks[0].Kind = mbParagraph);
  AssertEquals('t1', 'a', JoinedText(0));
  AssertEquals('t2', 'b', JoinedText(1));
end;

procedure TMarkdownTest.TestBulletListItems;
begin
  FBlocks := Parse('- a' + #10 + '- b' + #10 + '- c');
  AssertEquals('three items', 3, Length(FBlocks));
  AssertTrue('item kind', FBlocks[0].Kind = mbListItem);
  AssertFalse('bullet, not ordered', FBlocks[0].Ordered);
  AssertEquals('a', JoinedText(0));
  AssertEquals('c', JoinedText(2));
end;

procedure TMarkdownTest.TestOrderedListItems;
begin
  FBlocks := Parse('1. a' + #10 + '2. b');
  AssertEquals('two items', 2, Length(FBlocks));
  AssertTrue('ordered', FBlocks[0].Ordered);
  AssertEquals('text', 'a', JoinedText(0));
end;

procedure TMarkdownTest.TestOrderedOrdinalCaptured;
begin
  FBlocks := Parse('1. a' + #10 + '2. b');
  AssertEquals('first ordinal', 1, FBlocks[0].Ordinal);
  AssertEquals('second ordinal', 2, FBlocks[1].Ordinal);
end;

procedure TMarkdownTest.TestListInterruptsParagraph;
begin
  FBlocks := Parse('text' + #10 + '- item');
  AssertEquals('two blocks', 2, Length(FBlocks));
  AssertTrue('paragraph first', FBlocks[0].Kind = mbParagraph);
  AssertTrue('list second', FBlocks[1].Kind = mbListItem);
end;

procedure TMarkdownTest.TestLooseListItemsAreAllKept;
begin
  FBlocks := Parse('- a' + #10 + #10 + '- b');
  AssertEquals('two items', 2, Length(FBlocks));
  AssertTrue('first item', FBlocks[0].Kind = mbListItem);
  AssertTrue('second item', FBlocks[1].Kind = mbListItem);
end;

procedure TMarkdownTest.TestBlockquoteNesting;
begin
  FBlocks := Parse('> a' + #10 + '> b');
  AssertEquals('one quote', 1, Length(FBlocks));
  AssertTrue('quote kind', FBlocks[0].Kind = mbQuote);
  AssertEquals('depth 1', 1, FBlocks[0].Level);
  AssertEquals('text', 'a b', JoinedText(0));
  FBlocks := Parse('>> deep');
  AssertEquals('depth 2', 2, FBlocks[0].Level);
end;

procedure TMarkdownTest.TestHorizontalRule;
begin
  FBlocks := Parse('---');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('rule', FBlocks[0].Kind = mbRule);
end;

procedure TMarkdownTest.TestFencedCodeIsVerbatim;
begin
  FBlocks := Parse('```' + #10 + '- not a list' + #10 + '```');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('code fence', FBlocks[0].Kind = mbCodeFence);
  AssertEquals('verbatim content', '- not a list', string(FBlocks[0].Spans[0].Text));
end;

procedure TMarkdownTest.TestFencedCodeLanguageCaptured;
begin
  FBlocks := Parse('```pascal' + #10 + 'x' + #10 + '```');
  AssertEquals('language', 'pascal', string(FBlocks[0].Language));
end;

procedure TMarkdownTest.TestUnterminatedFenceIsCodeAtEof;
begin
  FBlocks := Parse('```' + #10 + 'abc');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('code fence', FBlocks[0].Kind = mbCodeFence);
  AssertEquals('content', 'abc', string(FBlocks[0].Spans[0].Text));
end;

procedure TMarkdownTest.TestMarkerNotAtLineStartIsLiteral;
begin
  FBlocks := Parse('a - b');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('a paragraph', FBlocks[0].Kind = mbParagraph);
  AssertEquals('literal', 'a - b', JoinedText(0));
end;

procedure TMarkdownTest.TestInlineBoldItalicCode;
begin
  FBlocks := Parse('**b** and *i* and `c`');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertEquals('five spans', 5, Length(FBlocks[0].Spans));
  AssertTrue('bold', misBold in FBlocks[0].Spans[0].Styles);
  AssertEquals('bold text', 'b', string(FBlocks[0].Spans[0].Text));
  AssertTrue('italic', misItalic in FBlocks[0].Spans[2].Styles);
  AssertEquals('italic text', 'i', string(FBlocks[0].Spans[2].Text));
  AssertTrue('code', misCode in FBlocks[0].Spans[4].Styles);
  AssertEquals('code text', 'c', string(FBlocks[0].Spans[4].Text));
end;

procedure TMarkdownTest.TestInlineStrike;
begin
  FBlocks := Parse('~~s~~');
  AssertEquals('one span', 1, Length(FBlocks[0].Spans));
  AssertTrue('strike', misStrike in FBlocks[0].Spans[0].Styles);
  AssertEquals('text', 's', string(FBlocks[0].Spans[0].Text));
end;

procedure TMarkdownTest.TestInlineLinkTargetCaptured;
begin
  FBlocks := Parse('[text](http://x)');
  AssertEquals('one span', 1, Length(FBlocks[0].Spans));
  AssertTrue('link', misLink in FBlocks[0].Spans[0].Styles);
  AssertEquals('label', 'text', string(FBlocks[0].Spans[0].Text));
  AssertEquals('target', 'http://x', string(FBlocks[0].Spans[0].Link));
end;

procedure TMarkdownTest.TestMalformedMarkupRendersLiterally;
begin
  FBlocks := Parse('**unclosed');
  AssertEquals('text preserved', '**unclosed', JoinedText(0));
  AssertEquals('one span', 1, Length(FBlocks[0].Spans));
  AssertTrue('no styles', FBlocks[0].Spans[0].Styles = []);
end;

procedure TMarkdownTest.TestWhitespaceCollapsedInParagraph;
begin
  FBlocks := Parse('a   b' + #10 + 'c');
  AssertEquals('collapsed to single spaces', 'a b c', JoinedText(0));
end;

procedure TMarkdownTest.TestCodeBlocksCarryNoInlineStyles;
begin
  FBlocks := Parse('```' + #10 + '**not bold**' + #10 + '```');
  AssertEquals('verbatim', '**not bold**', string(FBlocks[0].Spans[0].Text));
  AssertTrue('no inline styles', FBlocks[0].Spans[0].Styles = []);
end;

procedure TMarkdownTest.TestStyleForMapsEachInlineStyle;
var
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  AssertEquals('plain', Theme.Paragraph.Fg, StyleFor([], Theme).Fg);
  AssertEquals('code', Theme.Code.Fg, StyleFor([misCode], Theme).Fg);
  AssertEquals('link', Theme.Link.Fg, StyleFor([misLink], Theme).Fg);
  AssertTrue('bold', sfBold in StyleFor([misBold], Theme).Style);
  AssertTrue('italic', sfItalic in StyleFor([misItalic], Theme).Style);
  AssertTrue('strike', sfStrike in StyleFor([misStrike], Theme).Style);
end;

procedure TMarkdownTest.TestBlockAttrMapsEachBlockKind;
var
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  AssertEquals('paragraph', Theme.Paragraph.Fg, BlockAttr(mbParagraph, 0, Theme).Fg);
  AssertEquals('quote', Theme.Quote.Fg, BlockAttr(mbQuote, 1, Theme).Fg);
  AssertEquals('code', Theme.CodeBackdrop.Fg,
    BlockAttr(mbCodeFence, 0, Theme).Fg);
  AssertEquals('rule', Theme.Rule.Fg, BlockAttr(mbRule, 0, Theme).Fg);
  AssertEquals('list', Theme.ListBullet.Fg, BlockAttr(mbListItem, 1, Theme).Fg);
  AssertEquals('heading 2', Theme.Heading[2].Fg, BlockAttr(mbHeading, 2, Theme).Fg);
end;

procedure TMarkdownTest.TestHeadingAttrUsesTheLevel;
var
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  AssertEquals('h1', Theme.Heading[1].Fg, BlockAttr(mbHeading, 1, Theme).Fg);
  AssertEquals('h3', Theme.Heading[3].Fg, BlockAttr(mbHeading, 3, Theme).Fg);
end;

procedure TMarkdownTest.TestOpenTailIsPlainText;
begin
  FParser.Reset;
  FParser.Append('# Title' + #10 + #10 + 'partial para');
  FBlocks := FParser.Blocks;
  AssertEquals('heading plus raw tail', 2, Length(FBlocks));
  AssertTrue('heading is final', FBlocks[0].Kind = mbHeading);
  AssertEquals('tail is plain', 'partial para', JoinedText(1));

  { The heading stays; the tail grows as raw text, unparsed. }
  FParser.Append(' continues');
  FBlocks := FParser.Blocks;
  AssertEquals('still two blocks', 2, Length(FBlocks));
  AssertEquals('tail grew raw', 'partial para continues', JoinedText(1));
  AssertTrue('the tail is a single unstyled span',
    FBlocks[1].Spans[0].Styles = []);

  { Finishing parses the tail into a real block. }
  FParser.Finish;
  FBlocks := FParser.Blocks;
  AssertEquals('still two blocks', 2, Length(FBlocks));
  AssertTrue('the tail is now a paragraph', FBlocks[1].Kind = mbParagraph);
  AssertEquals('text', 'partial para continues', JoinedText(1));
end;

procedure TMarkdownTest.TestIncrementalAppendMatchesFullParse;
const
  Doc = '# Title' + #10 + #10 + 'a **bold** line' + #10 + #10 +
    '- one' + #10 + '- two' + #10 + #10 + '```pascal' + #10 + 'x := 1;' +
    #10 + '```';
var
  Full: TMarkdownParser;
  FullBlocks, IncBlocks: TMdBlockArray;
  I, Chunk: Integer;
begin
  Full := TMarkdownParser.Create;
  try
    FullBlocks := Full.Parse(Doc);
  finally
    Full.Free;
  end;

  FParser.Reset;
  Chunk := 1;
  while Chunk <= Length(Doc) do
  begin
    FParser.Append(Copy(Doc, Chunk, 7));
    Inc(Chunk, 7);
  end;
  FParser.Finish;
  IncBlocks := FParser.Blocks;

  AssertEquals('same block count', Length(FullBlocks), Length(IncBlocks));
  for I := 0 to High(FullBlocks) do
  begin
    AssertEquals('kind ' + IntToStr(I), Ord(FullBlocks[I].Kind),
      Ord(IncBlocks[I].Kind));
    AssertEquals('level ' + IntToStr(I), FullBlocks[I].Level,
      IncBlocks[I].Level);
  end;
end;

procedure TMarkdownTest.TestAppendAfterReset;
begin
  FParser.Append('a' + #10 + #10 + 'b');
  FParser.Finish;
  AssertEquals('two blocks', 2, Length(FParser.Blocks));

  FParser.Reset;
  FParser.Append('c');
  FParser.Finish;
  FBlocks := FParser.Blocks;
  AssertEquals('one block after reset', 1, Length(FBlocks));
  AssertEquals('text', 'c', JoinedText(0));
end;

procedure TMarkdownTest.TestStyledSpansFeedTextBlock;
var
  Theme: TMdTheme;
  Spans: array of TSpan;
  Blk: TTextBlock;
  Surface: TSurfaceMemory;
  R: TRect;
  I: Integer;
begin
  Theme := DefaultMdTheme;
  FBlocks := Parse('**bold** plain');
  SetLength(Spans, Length(FBlocks[0].Spans));
  for I := 0 to High(Spans) do
  begin
    Spans[I] := Default(TSpan);
    Spans[I].Text := FBlocks[0].Spans[I].Text;
    Spans[I].Attr := StyleFor(FBlocks[0].Spans[I].Styles, Theme);
  end;

  Blk := TTextBlock.Create(Spans, wmWord);
  try
    Surface := TSurfaceMemory.Create(20, 2);
    try
      R := Default(TRect);
      R.X := 0;
      R.Y := 0;
      R.W := 20;
      R.H := 2;
      Blk.Arrange(R);
      Blk.Render(Surface);
      AssertTrue('bold lands in the first cell',
        sfBold in Surface.CellAt(0, 0).Attr.Style);
      AssertEquals('text preserved', 'bold plain',
        string(Surface.RowText(0, 0, 20)));
    finally
      Surface.Free;
    end;
  finally
    Blk.Free;
  end;
end;

initialization
  RegisterTest(TMarkdownTest);

end.
