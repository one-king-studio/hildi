unit test_markdown;
{ fpcunit tests for hildegard.helper.markdown: the block pass, the inline
  scanner, the theme mapping, and incremental append. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  markdown.types, markdown.parse,
  tui.widgets.mdtheme,
  tui.base, tui.widget,
  tui.widgets.text, tui.surface;

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
    { A front-end project puts raw HTML in the reply. Tags must survive intact -
      an attribute containing a markdown special character must NOT be read as
      inline markup, because that silently corrupts the visible text. }
    procedure TestHtmlAttributeUnderscoreIsNotEmphasis;
    procedure TestHtmlTagsRenderAsText;
    procedure TestWhitespaceCollapsedInParagraph;
    procedure TestCodeBlocksCarryNoInlineStyles;
    procedure TestStyleForMapsEachInlineStyle;
    procedure TestStyleForBoldItalicTakesTheCoolColour;
    procedure TestStyleForCodeCarriesTheChipBackground;
    procedure TestBlockAttrMapsEachBlockKind;
    procedure TestHeadingAttrUsesTheLevel;
    procedure TestOpenTailIsPlainText;
    procedure TestIncrementalAppendMatchesFullParse;
    procedure TestAppendAfterReset;
    procedure TestStyledSpansFeedTextBlock;
    procedure TestTripleEmphasisIsBoldItalic;
    procedure TestTripleEmphasisDoesNotCorruptFollowingText;
    procedure TestNestedEmphasis;
    procedure TestStrayAsterisksAreLiteral;
    procedure TestEmphasisNestingIsBounded;
    procedure TestTableDetected;
    procedure TestTableAlignmentParsed;
    procedure TestTableEscapedPipe;
    procedure TestTablePadsAndTruncatesCells;
    procedure TestTableInlineStylesInCells;
    procedure TestTableEndsAtBlankLine;
    procedure TestTableEndsAtNonRowLine;
    procedure TestTableHeaderAfterParagraph;
    procedure TestDelimiterWithoutPipeIsParagraph;
    procedure TestIncrementalTableMatchesFullParse;
    { Setext headings: the one construct the parser never supported. The
      underline position is load-bearing - after lists, before thematic breaks -
      or `---` is eaten as a rule and a heading silently disappears. }
    procedure TestSetextHeadingLevelOne;
    procedure TestSetextHeadingLevelTwo;
    procedure TestSetextUnderMultiLineParagraphJoinsLines;
    procedure TestSetextUnderlineToleratesTrailingSpaces;
    procedure TestTwoDashesUnderTextIsAHeadingNotARule;
    procedure TestRuleAfterAnAtxHeadingStaysARule;
    procedure TestRuleAfterAListItemStaysARule;
    procedure TestSetextUnderlineWithSpacesIsLiteral;
    procedure TestIncrementalSetextMatchesFullParse;
    { The block pass order is declared as data and pinned here: a reorder
      compiles silently and breaks a feature, so it must fail a test instead. }
    procedure TestBlockPassOrderIsPinned;
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

procedure TMarkdownTest.TestHtmlAttributeUnderscoreIsNotEmphasis;
begin
  { The reported bug: a front-end reply carries HTML, and an attribute with two
    underscores in it (`class="my_class_name"`) was being read as EMPHASIS by the
    inline scanner. The visible text then lost the underscores and gained bold,
    so the reply rendered as corrupted markup rather than as the code the model
    wrote.

    The parser has no HTML mode by design - it is a Markdown parser - but it must
    not INVENT markup out of attribute names. Underscore emphasis is already
    word-boundary-aware (so snake_case is safe); this pins the same guarantee for
    a tag body. }
  FBlocks := Parse('Click <span class="my_class_name">here</span>');
  AssertTrue('the attribute text survives verbatim: ' + JoinedText(0),
    Pos('my_class_name', JoinedText(0)) > 0);
end;

procedure TMarkdownTest.TestHtmlTagsRenderAsText;
begin
  { A raw tag is TEXT: it must reach the view intact so the operator sees what
    the model actually wrote. Stripping or dropping tags would hide the fact
    that the reply was HTML rather than Markdown. }
  FBlocks := Parse('<div class="row">hello</div>');
  AssertTrue('the opening tag survives: ' + JoinedText(0),
    Pos('<div', JoinedText(0)) > 0);
  AssertTrue('the text between tags survives: ' + JoinedText(0),
    Pos('hello', JoinedText(0)) > 0);
  AssertTrue('the closing tag survives: ' + JoinedText(0),
    Pos('</div>', JoinedText(0)) > 0);
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
  AssertEquals('plain', Theme.Paragraph.Fg, MdAttrFor([], Theme).Fg);
  AssertEquals('code', Theme.Code.Fg, MdAttrFor([misCode], Theme).Fg);
  AssertEquals('link', Theme.Link.Fg, MdAttrFor([misLink], Theme).Fg);
  AssertTrue('bold', sfBold in MdAttrFor([misBold], Theme).Style);
  AssertTrue('italic', sfItalic in MdAttrFor([misItalic], Theme).Style);
  AssertTrue('strike', sfStrike in MdAttrFor([misStrike], Theme).Style);
end;

procedure TMarkdownTest.TestStyleForBoldItalicTakesTheCoolColour;
var
  Theme: TMdTheme;
  Attr: TAttr;
begin
  Theme := DefaultMdTheme;
  Attr := MdAttrFor([misBold, misItalic], Theme);
  { Bold+italic takes the italic (cool) colour, in bold, so it stays distinct
    from plain bold when the italic rendition is unavailable. }
  AssertEquals('the cool colour', Theme.Italic.Fg, Attr.Fg);
  AssertTrue('in bold', sfBold in Attr.Style);
  AssertEquals('plain bold is the warm colour', Theme.Bold.Fg,
    MdAttrFor([misBold], Theme).Fg);
end;

procedure TMarkdownTest.TestStyleForCodeCarriesTheChipBackground;
var
  Theme: TMdTheme;
  Attr: TAttr;
begin
  Theme := DefaultMdTheme;
  Attr := MdAttrFor([misCode], Theme);
  AssertEquals('the chip foreground', Theme.Code.Fg, Attr.Fg);
  AssertEquals('the chip background', Theme.CodeBackdrop.Bg, Attr.Bg);
  AssertFalse('the chip paints its own background',
    sfScreenBg in Attr.Style);
end;

procedure TMarkdownTest.TestBlockAttrMapsEachBlockKind;
var
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  AssertEquals('paragraph', Theme.Paragraph.Fg, MdBlockAttr(mbParagraph, 0, Theme).Fg);
  AssertEquals('quote', Theme.Quote.Fg, MdBlockAttr(mbQuote, 1, Theme).Fg);
  AssertEquals('code', Theme.CodeBackdrop.Fg,
    MdBlockAttr(mbCodeFence, 0, Theme).Fg);
  AssertEquals('rule', Theme.Rule.Fg, MdBlockAttr(mbRule, 0, Theme).Fg);
  AssertEquals('list', Theme.ListBullet.Fg, MdBlockAttr(mbListItem, 1, Theme).Fg);
  AssertEquals('heading 2', Theme.Heading[2].Fg, MdBlockAttr(mbHeading, 2, Theme).Fg);
end;

procedure TMarkdownTest.TestHeadingAttrUsesTheLevel;
var
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  AssertEquals('h1', Theme.Heading[1].Fg, MdBlockAttr(mbHeading, 1, Theme).Fg);
  AssertEquals('h3', Theme.Heading[3].Fg, MdBlockAttr(mbHeading, 3, Theme).Fg);
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
    Spans[I].Attr := MdAttrFor(FBlocks[0].Spans[I].Styles, Theme);
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

procedure TMarkdownTest.TestTripleEmphasisIsBoldItalic;
begin
  FBlocks := Parse('***both***');
  AssertEquals('one span', 1, Length(FBlocks[0].Spans));
  AssertEquals('text preserved', 'both', string(FBlocks[0].Spans[0].Text));
  AssertTrue('bold', misBold in FBlocks[0].Spans[0].Styles);
  AssertTrue('italic', misItalic in FBlocks[0].Spans[0].Styles);
end;

procedure TMarkdownTest.TestTripleEmphasisDoesNotCorruptFollowingText;
begin
  FBlocks := Parse('***both*** and *x*');
  AssertEquals('three spans', 3, Length(FBlocks[0].Spans));
  AssertEquals('middle text', ' and ', string(FBlocks[0].Spans[1].Text));
  AssertTrue('middle is plain', FBlocks[0].Spans[1].Styles = []);
  AssertTrue('last is italic', misItalic in FBlocks[0].Spans[2].Styles);
end;

procedure TMarkdownTest.TestNestedEmphasis;
begin
  FBlocks := Parse('**bold and *italic* mixed**');
  AssertEquals('three spans', 3, Length(FBlocks[0].Spans));
  AssertTrue('first is bold', FBlocks[0].Spans[0].Styles = [misBold]);
  AssertTrue('middle is bold and italic',
    FBlocks[0].Spans[1].Styles = [misBold, misItalic]);
  AssertEquals('middle text', 'italic', string(FBlocks[0].Spans[1].Text));
  AssertTrue('last is bold', FBlocks[0].Spans[2].Styles = [misBold]);
end;

procedure TMarkdownTest.TestStrayAsterisksAreLiteral;
begin
  FBlocks := Parse('a * b');
  AssertEquals('a lone asterisk is literal', 'a * b', JoinedText(0));
  { Note: a bare '***' is a thematic break, not emphasis. }
  FBlocks := Parse('a *** b');
  AssertEquals('unpaired stars are literal', 'a *** b', JoinedText(0));
end;

procedure TMarkdownTest.TestEmphasisNestingIsBounded;
var
  S: string;
  I: Integer;
begin
  { Deeply nested delimiters must not blow the stack, and must keep the text. }
  S := '';
  for I := 1 to 40 do
    S := S + '**';
  S := S + 'x';
  for I := 1 to 40 do
    S := S + '**';
  FBlocks := Parse(S);
  AssertTrue('the text survives', Pos('x', JoinedText(0)) > 0);
end;

procedure TMarkdownTest.TestTableDetected;
begin
  FBlocks := Parse('| A | B |' + #10 + '| --- | --- |' + #10 + '| 1 | 2 |' +
    #10 + '| 3 | 4 |');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('a table', FBlocks[0].Kind = mbTable);
  AssertEquals('two columns', 2, Length(FBlocks[0].Align));
  AssertEquals('two header cells', 2, Length(FBlocks[0].Head));
  AssertEquals('header text', 'A', string(FBlocks[0].Head[0][0].Text));
  AssertEquals('two body rows', 2, Length(FBlocks[0].Rows));
  AssertEquals('body cell', '3', string(FBlocks[0].Rows[1][0][0].Text));
end;

procedure TMarkdownTest.TestTableAlignmentParsed;
begin
  FBlocks := Parse('| L | C | R | D |' + #10 +
    '| :--- | :---: | ---: | --- |' + #10 + '| a | b | c | d |');
  AssertTrue('a table', FBlocks[0].Kind = mbTable);
  AssertTrue('left', FBlocks[0].Align[0] = maLeft);
  AssertTrue('centre', FBlocks[0].Align[1] = maCenter);
  AssertTrue('right', FBlocks[0].Align[2] = maRight);
  AssertTrue('default', FBlocks[0].Align[3] = maNone);
end;

procedure TMarkdownTest.TestTableEscapedPipe;
begin
  FBlocks := Parse('| A | B |' + #10 + '| --- | --- |' + #10 +
    '| x \| y | z |');
  AssertEquals('the escaped pipe is literal', 'x | y',
    string(FBlocks[0].Rows[0][0][0].Text));
  AssertEquals('still two columns', 2, Length(FBlocks[0].Rows[0]));
end;

procedure TMarkdownTest.TestTablePadsAndTruncatesCells;
begin
  FBlocks := Parse('| A | B | C |' + #10 + '| --- | --- | --- |' + #10 +
    '| 1 |' + #10 + '| 1 | 2 | 3 | 4 |');
  AssertEquals('short row padded to the header', 3, Length(FBlocks[0].Rows[0]));
  AssertEquals('long row truncated', 3, Length(FBlocks[0].Rows[1]));
  AssertEquals('the pad cell is empty', 0, Length(FBlocks[0].Rows[0][1]));
end;

procedure TMarkdownTest.TestTableInlineStylesInCells;
begin
  FBlocks := Parse('| A |' + #10 + '| --- |' + #10 + '| **bold** |');
  AssertEquals('one cell span', 1, Length(FBlocks[0].Rows[0][0]));
  AssertTrue('bold', misBold in FBlocks[0].Rows[0][0][0].Styles);
  AssertEquals('text', 'bold', string(FBlocks[0].Rows[0][0][0].Text));
end;

procedure TMarkdownTest.TestTableEndsAtBlankLine;
begin
  FBlocks := Parse('| A |' + #10 + '| --- |' + #10 + '| 1 |' + #10 + #10 +
    'after');
  AssertEquals('table then paragraph', 2, Length(FBlocks));
  AssertTrue('table', FBlocks[0].Kind = mbTable);
  AssertEquals('one row', 1, Length(FBlocks[0].Rows));
  AssertTrue('paragraph', FBlocks[1].Kind = mbParagraph);
end;

procedure TMarkdownTest.TestTableEndsAtNonRowLine;
begin
  FBlocks := Parse('| A |' + #10 + '| --- |' + #10 + '| 1 |' + #10 + 'plain');
  AssertEquals('table then paragraph', 2, Length(FBlocks));
  AssertTrue('table', FBlocks[0].Kind = mbTable);
  AssertEquals('one row', 1, Length(FBlocks[0].Rows));
  AssertEquals('text', 'plain', JoinedText(1));
end;

procedure TMarkdownTest.TestTableHeaderAfterParagraph;
begin
  FBlocks := Parse('intro' + #10 + '| A | B |' + #10 + '| --- | --- |' + #10 +
    '| 1 | 2 |');
  AssertEquals('paragraph then table', 2, Length(FBlocks));
  AssertTrue('paragraph first', FBlocks[0].Kind = mbParagraph);
  AssertEquals('intro text', 'intro', JoinedText(0));
  AssertTrue('table second', FBlocks[1].Kind = mbTable);
  AssertEquals('two columns', 2, Length(FBlocks[1].Align));
end;

procedure TMarkdownTest.TestDelimiterWithoutPipeIsParagraph;
begin
  { REWRITTEN deliberately when setext landed. The original input was
    'Header' + '---', which this parser used to read as a paragraph then a rule
    - an expectation that pinned the ABSENCE of setext. That input is now a
    level-2 heading (see TestTwoDashesUnderTextIsAHeadingNotARule).

    The intent is preserved with input that is unambiguous under both readings:
    `- - -` has internal spaces, so it is a thematic break and not a setext
    underline, and having no pipe it is certainly not a table. }
  FBlocks := Parse('Header' + #10 + '- - -');
  AssertEquals('two blocks', 2, Length(FBlocks));
  AssertTrue('not a table', FBlocks[0].Kind <> mbTable);
  AssertTrue('a paragraph', FBlocks[0].Kind = mbParagraph);
  AssertTrue('a rule', FBlocks[1].Kind = mbRule);
end;

procedure TMarkdownTest.TestSetextHeadingLevelOne;
begin
  FBlocks := Parse('Title' + #10 + '=====');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('a heading', FBlocks[0].Kind = mbHeading);
  AssertEquals('level 1', 1, FBlocks[0].Level);
  AssertEquals('text', 'Title', JoinedText(0));
end;

procedure TMarkdownTest.TestSetextHeadingLevelTwo;
begin
  FBlocks := Parse('Title' + #10 + '-----');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('a heading', FBlocks[0].Kind = mbHeading);
  AssertEquals('level 2', 2, FBlocks[0].Level);
  AssertEquals('text', 'Title', JoinedText(0));
end;

procedure TMarkdownTest.TestSetextUnderMultiLineParagraphJoinsLines;
begin
  { CommonMark joins the whole paragraph, not just its last line. }
  FBlocks := Parse('Foo' + #10 + 'bar' + #10 + '===');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('a heading', FBlocks[0].Kind = mbHeading);
  AssertEquals('level 1', 1, FBlocks[0].Level);
  AssertEquals('both lines joined', 'Foo bar', JoinedText(0));
end;

procedure TMarkdownTest.TestSetextUnderlineToleratesTrailingSpaces;
begin
  FBlocks := Parse('Title' + #10 + '=====   ');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('a heading', FBlocks[0].Kind = mbHeading);
  AssertEquals('level 1', 1, FBlocks[0].Level);
end;

procedure TMarkdownTest.TestTwoDashesUnderTextIsAHeadingNotARule;
begin
  { This assertion was REWRITTEN deliberately when setext landed. It used to
    expect a paragraph then a thematic break, because the parser had no setext
    pass and `---` could only be a rule. CommonMark reads it as a level-2
    heading, and the old expectation pinned the absence of a feature. The
    original intent - "a delimiter row without a pipe is not a table" - is kept.
  }
  FBlocks := Parse('Title' + #10 + '--');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('not a table', FBlocks[0].Kind <> mbTable);
  AssertTrue('a heading', FBlocks[0].Kind = mbHeading);
  AssertEquals('level 2', 2, FBlocks[0].Level);
  AssertEquals('text', 'Title', JoinedText(0));
end;

procedure TMarkdownTest.TestRuleAfterAnAtxHeadingStaysARule;
begin
  { An ATX heading is finalised immediately, so the break below it is a rule -
    the setext pass must not reach back past a closed block. }
  FBlocks := Parse('# Foo' + #10 + '---');
  AssertEquals('two blocks', 2, Length(FBlocks));
  AssertTrue('heading first', FBlocks[0].Kind = mbHeading);
  AssertEquals('level 1', 1, FBlocks[0].Level);
  AssertTrue('rule second', FBlocks[1].Kind = mbRule);
end;

procedure TMarkdownTest.TestRuleAfterAListItemStaysARule;
begin
  { A list is not a paragraph, so the setext pass cannot claim this underline. }
  FBlocks := Parse('- item' + #10 + '---');
  AssertEquals('two blocks', 2, Length(FBlocks));
  AssertTrue('list first', FBlocks[0].Kind = mbListItem);
  AssertTrue('rule second', FBlocks[1].Kind = mbRule);
end;

procedure TMarkdownTest.TestSetextUnderlineWithSpacesIsLiteral;
begin
  { `= =` is neither a setext underline nor a rule: it continues the paragraph
    as ordinary text, which is what a reader sees. }
  FBlocks := Parse('Title' + #10 + '= =');
  AssertEquals('one block', 1, Length(FBlocks));
  AssertTrue('a paragraph', FBlocks[0].Kind = mbParagraph);
  AssertEquals('text kept', 'Title = =', JoinedText(0));
end;

procedure TMarkdownTest.TestBlockPassOrderIsPinned;
const
  { The order ProcessLine actually implements. Changing the parser's branch
    order without changing this constant fails here - which is the point. }
  Expected: array[0..9] of TMdBlockPass = (
    bpFenceContinue, bpTableContinue, bpBlank, bpAtxHeading, bpSetextHeading,
    bpThematicBreak, bpFenceOpen, bpListMarker, bpQuote, bpTableStart);
var
  I: Integer;
begin
  AssertEquals('the declared order has every pass',
    Length(Expected), Length(MdBlockPassOrder));
  for I := 0 to High(Expected) do
    AssertTrue('pass ' + IntToStr(I) + ' is in place',
      Expected[I] = MdBlockPassOrder[I]);

  { The two adjacencies that carry a feature, asserted by name so a failure
    says WHICH ordering broke rather than just "an index differs". }
  AssertTrue('setext precedes the thematic break, or --- is a rule',
    MdBlockPassOrder[Ord(bpSetextHeading) - Ord(bpFenceContinue)] =
      bpSetextHeading);
  AssertEquals('setext sits directly before the thematic break',
    Ord(bpThematicBreak), Ord(bpSetextHeading) + 1);
  AssertEquals('the table start runs last, after the paragraph pass',
    Ord(bpTableStart), Ord(bpQuote) + 1);
  AssertTrue('a fence continues before anything reopens',
    MdBlockPassOrder[0] = bpFenceContinue);
end;

procedure TMarkdownTest.TestIncrementalSetextMatchesFullParse;
const
  Doc = 'Title' + #10 + '=====' + #10 + #10 + 'Body text.' + #10 + #10 +
    'Sub' + #10 + '---' + #10;
var
  Full: TMarkdownParser;
  FullBlocks, IncBlocks: TMdBlockArray;
  I: Integer;
begin
  Full := TMarkdownParser.Create;
  try
    FullBlocks := Full.Parse(Doc);
    Full.Reset;
    for I := 1 to Length(Doc) do
      Full.Append(Doc[I]);
    Full.Finish;
    IncBlocks := Full.Blocks;
  finally
    Full.Free;
  end;
  AssertEquals('same block count', Length(FullBlocks), Length(IncBlocks));
  for I := 0 to High(FullBlocks) do
  begin
    AssertTrue('same kind at ' + IntToStr(I), FullBlocks[I].Kind = IncBlocks[I].Kind);
    AssertEquals('same level at ' + IntToStr(I), FullBlocks[I].Level,
      IncBlocks[I].Level);
  end;
end;

procedure TMarkdownTest.TestIncrementalTableMatchesFullParse;
const
  Doc = '| A | B |' + #10 + '| --- | --- |' + #10 + '| 1 | 2 |' + #10 +
    '| 3 | 4 |' + #10 + #10 + 'after';
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
    FParser.Append(Copy(Doc, Chunk, 5));
    Inc(Chunk, 5);
  end;
  FParser.Finish;
  IncBlocks := FParser.Blocks;

  AssertEquals('same block count', Length(FullBlocks), Length(IncBlocks));
  for I := 0 to High(FullBlocks) do
  begin
    AssertEquals('kind ' + IntToStr(I), Ord(FullBlocks[I].Kind),
      Ord(IncBlocks[I].Kind));
    AssertEquals('rows ' + IntToStr(I), Length(FullBlocks[I].Rows),
      Length(IncBlocks[I].Rows));
  end;
end;

initialization
  RegisterTest(TMarkdownTest);
end.
