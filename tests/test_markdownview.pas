unit test_markdownview;
{ fpcunit tests for tui.widgets.markdownview: block rendering, chrome,
  and the streaming tail. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  markdown.types,
  tui.widgets.mdtheme,
  tui.base, tui.widget,
  tui.surface, tui.widgets.markdownview;

type
  TMarkdownViewTest = class(TTestCase)
  private
    function RenderSource(const AMd: string; AWidth, AHeight: Integer):
      TSurfaceMemory;
    function Rect(AW, AH: Integer): TRect;
  published
    procedure TestEmptySourceMeasuresZero;
    procedure TestParagraphRenders;
    procedure TestInlineBoldIsStyled;
    procedure TestHeadingUsesTheTheme;
    procedure TestBulletPrefix;
    procedure TestOrderedPrefix;
    procedure TestListItemWrapsUnderTheText;
    procedure TestOrderedListItemWrapsUnderTheText;
    procedure TestQuoteBar;
    procedure TestRuleIsFullWidth;
    procedure TestCodeFenceIsBoxed;
    procedure TestInlineCodeIsAPaddedChip;
    procedure TestBlocksAreSeparatedByABlankRow;
    procedure TestTightListHasNoGap;
    procedure TestH1HasTwoRowsAboveAndOneBelow;
    procedure TestH2HasTwoRowsAboveAndOneBelow;
    procedure TestH3KeepsASingleRowGap;
    procedure TestALeadingH1GetsItsTwoRowsAbove;
    procedure TestALeadingParagraphHasNoGap;
    procedure TestStreamingTailIsPlainText;
    procedure TestFinalisedBlocksAreNotRebuilt;
    procedure TestFinishPromotesTheTail;
    procedure TestHeadingsAreBrightAndBold;
    procedure TestH1Underline;
    procedure TestH2Underline;
    procedure TestH3Underline;
    procedure TestH4HasNoUnderline;
    procedure TestUnderlineMatchesTextWidth;
    procedure TestBodyIsDimmerThanHeadings;
    procedure TestTableRendersGrid;
    procedure TestTableIsContentWidth;
    procedure TestTableCompressesAndWraps;
    procedure TestTableAlignment;
    procedure TestTableUsesTheThemeColours;
    procedure TestTableBalancesForLeastHeight;
    procedure TestTableCellsAreNotRebuilt;
  end;

implementation

function TMarkdownViewTest.Rect(AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := 0;
  Result.Y := 0;
  Result.W := AW;
  Result.H := AH;
end;

function TMarkdownViewTest.RenderSource(const AMd: string;
  AWidth, AHeight: Integer): TSurfaceMemory;
var
  View: TMarkdownView;
begin
  View := TMarkdownView.Create;
  try
    View.SetSource(AMd);
    View.Arrange(Rect(AWidth, AHeight));
    Result := TSurfaceMemory.Create(AWidth, AHeight);
    View.Render(Result);
  finally
    View.Free;
  end;
end;

procedure TMarkdownViewTest.TestEmptySourceMeasuresZero;
var
  View: TMarkdownView;
  Avail: TSize;
begin
  View := TMarkdownView.Create;
  try
    View.SetSource('');
    Avail := Default(TSize);
    Avail.W := 20;
    Avail.H := 10;
    AssertEquals('no blocks', 0, View.BlockCount);
    AssertEquals('zero height', 0, View.Measure(Avail).H);
  finally
    View.Free;
  end;
end;

procedure TMarkdownViewTest.TestParagraphRenders;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('hello world', 20, 3);
  try
    AssertTrue('paragraph text drawn',
      Pos('hello world', string(S.RowText(0, 0, 20))) > 0);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestInlineBoldIsStyled;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('**bold** plain', 20, 2);
  try
    AssertTrue('bold lands', sfBold in S.CellAt(0, 0).Attr.Style);
    AssertFalse('the plain run is not bold',
      sfBold in S.CellAt(7, 0).Attr.Style);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestHeadingUsesTheTheme;
var
  S: TSurfaceMemory;
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  { A leading h1 sits 2 rows down (its top margin). }
  S := RenderSource('# Title', 20, 5);
  try
    AssertEquals('heading colour', Theme.Heading[1].Fg, S.CellAt(0, 2).Attr.Fg);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestBulletPrefix;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('- item', 20, 2);
  try
    AssertTrue('bullet drawn', Pos(UnicodeString('•'), S.RowText(0, 0, 20)) > 0);
    AssertTrue('item text drawn', Pos('item', string(S.RowText(0, 0, 20))) > 0);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestOrderedPrefix;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('1. one', 20, 2);
  try
    AssertTrue('marker drawn', Pos('1.', string(S.RowText(0, 0, 20))) > 0);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestListItemWrapsUnderTheText;
var
  S: TSurfaceMemory;
begin
  { The bullet is at column 0; a wrapped line must align under the item text
    (column 2), not under the bullet. }
  S := RenderSource('- aaaa bbbb cccc', 10, 4);
  try
    AssertEquals('bullet starts the item', UnicodeString('•'),
      S.CellAt(0, 0).Ch);
    AssertEquals('the item text follows the bullet', 'a',
      string(S.CellAt(2, 0).Ch));
    AssertEquals('nothing under the bullet on the wrapped row', '',
      string(S.CellAt(0, 1).Ch));
    AssertEquals('the wrapped row aligns under the item text', 'b',
      string(S.CellAt(2, 1).Ch));
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestOrderedListItemWrapsUnderTheText;
var
  S: TSurfaceMemory;
begin
  { An ordered marker is three columns wide ('1. '), so the wrapped text aligns
    at column 3. }
  S := RenderSource('1. aaaa bbbb cccc', 11, 4);
  try
    AssertEquals('marker starts the item', '1', string(S.CellAt(0, 0).Ch));
    AssertEquals('nothing under the marker on the wrapped row', '',
      string(S.CellAt(0, 1).Ch));
    AssertEquals('the wrapped row aligns under the item text', 'b',
      string(S.CellAt(3, 1).Ch));
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestQuoteBar;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('> quoted', 20, 2);
  try
    AssertTrue('quote bar drawn', Pos(UnicodeString('│'), S.RowText(0, 0, 20)) > 0);
    AssertTrue('quote text drawn', Pos('quoted', string(S.RowText(0, 0, 20))) > 0);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestRuleIsFullWidth;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('---', 10, 2);
  try
    AssertTrue('rule starts', S.CellAt(0, 0).Ch = '─');
    AssertTrue('rule reaches the edge', S.CellAt(9, 0).Ch = '─');
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestCodeFenceIsBoxed;
var
  S: TSurfaceMemory;
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  S := RenderSource('```pascal' + #10 + 'code' + #10 + '```', 30, 4);
  try
    { Row 0 is the top border, with the language right-aligned. }
    AssertTrue('rounded corner', S.CellAt(0, 0).Ch = '╭');
    AssertTrue('language on the top border',
      Pos(UnicodeString(' pascal '), S.RowText(0, 0, 30)) > 0);
    { Row 1 is the code, inset by the border and a space. }
    AssertEquals('code text drawn', 'code', string(S.RowText(1, 2, 4)));
    AssertTrue('right border', S.CellAt(29, 1).Ch = '│');
    AssertEquals('the box surface is the sunken backdrop',
      Theme.CodeBackdrop.Bg, S.CellAt(29, 1).Attr.Bg);
    { Row 2 is the bottom border. }
    AssertTrue('bottom corner', S.CellAt(0, 2).Ch = '╰');
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestInlineCodeIsAPaddedChip;
var
  S: TSurfaceMemory;
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  { 'a ' then a padded chip ' x ' then ' b'. }
  S := RenderSource('a `x` b', 20, 2);
  try
    AssertEquals('the chip text', 'x', string(S.CellAt(3, 0).Ch));
    AssertEquals('the chip carries the sunken background',
      Theme.CodeBackdrop.Bg, S.CellAt(3, 0).Attr.Bg);
    AssertEquals('the leading pad is part of the chip',
      Theme.CodeBackdrop.Bg, S.CellAt(2, 0).Attr.Bg);
    AssertEquals('the chip foreground', Theme.Code.Fg, S.CellAt(3, 0).Attr.Fg);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestBlocksAreSeparatedByABlankRow;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('a' + #10 + #10 + 'b', 10, 4);
  try
    AssertEquals('first block', 'a', string(S.CellAt(0, 0).Ch));
    AssertEquals('blank separator', '', string(S.CellAt(0, 1).Ch));
    AssertEquals('second block', 'b', string(S.CellAt(0, 2).Ch));
  finally
    S.Free;
  end;
end;

{ The row a character first appears on, or -1. Asserting the DISTANCE between
  the paragraph and the heading is the real property; asserting fixed row indices
  was my first attempt and it was wrong about the layout. }
function RowOfChar(S: TSurfaceMemory; AWidth, AHeight: Integer;
  const ACh: UnicodeString): Integer;
var
  R, C: Integer;
begin
  Result := -1;
  for R := 0 to AHeight - 1 do
    for C := 0 to AWidth - 1 do
      if S.CellAt(C, R).Ch = ACh then
        Exit(R);
end;

procedure TMarkdownViewTest.TestH1HasTwoRowsAboveAndOneBelow;
var
  S: TSurfaceMemory;
  TxtRow, HeadRow, AfterRow: Integer;
begin
  { The specified shape: 2 blank, heading, underline, 1 blank. Asymmetric on
    purpose - an earlier version put 2 on both sides and read too loose, and one
    everywhere lost the separation. }
  S := RenderSource('text' + #10 + #10 + '# Head' + #10 + #10 + 'zzz', 14, 14);
  try
    TxtRow := RowOfChar(S, 14, 14, 'x');
    HeadRow := RowOfChar(S, 14, 14, 'H');
    AfterRow := RowOfChar(S, 14, 14, 'z');
    AssertTrue('the paragraph is drawn', TxtRow >= 0);
    AssertTrue('the heading is drawn', HeadRow >= 0);
    AssertTrue('the following text is drawn', AfterRow >= 0);
    AssertEquals('two blank rows above the h1', 2, HeadRow - TxtRow - 1);
    { head text, then the underline row, then one blank, then the text. }
    AssertEquals('one blank row below (after the underline)',
      1, AfterRow - HeadRow - 2);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestH2HasTwoRowsAboveAndOneBelow;
var
  S: TSurfaceMemory;
  TxtRow, HeadRow, AfterRow: Integer;
begin
  S := RenderSource('text' + #10 + #10 + '## Head' + #10 + #10 + 'zzz', 14, 14);
  try
    TxtRow := RowOfChar(S, 14, 14, 'x');
    HeadRow := RowOfChar(S, 14, 14, 'H');
    AfterRow := RowOfChar(S, 14, 14, 'z');
    AssertEquals('two blank rows above the h2', 2, HeadRow - TxtRow - 1);
    AssertEquals('one blank row below', 1, AfterRow - HeadRow - 2);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestH3KeepsASingleRowGap;
var
  S: TSurfaceMemory;
  TxtRow, HeadRow: Integer;
begin
  { Only the top two levels get the extra row: a uniform margin would flatten the
    hierarchy it exists to express. }
  S := RenderSource('text' + #10 + #10 + '### Head', 14, 12);
  try
    TxtRow := RowOfChar(S, 14, 12, 'x');
    HeadRow := RowOfChar(S, 14, 12, 'H');
    AssertEquals('a single blank row above the h3', 1, HeadRow - TxtRow - 1);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestALeadingH1GetsItsTwoRowsAbove;
var
  S: TSurfaceMemory;
  HeadRow, AfterRow: Integer;
begin
  { The case the operator actually looks at: a reply OPENS with its title. The
    margin must be there even with no preceding block, or there is no gap above at
    all - which is what the earlier revert caused. }
  S := RenderSource('# Title' + #10 + #10 + 'zzz', 14, 14);
  try
    HeadRow := RowOfChar(S, 14, 14, 'T');
    AfterRow := RowOfChar(S, 14, 14, 'z');
    AssertEquals('the title starts after two blank rows', 2, HeadRow);
    AssertEquals('one blank row below', 1, AfterRow - HeadRow - 2);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestALeadingParagraphHasNoGap;
var
  S: TSurfaceMemory;
begin
  { The gap belongs above a major HEADING, not above a document. }
  S := RenderSource('first' + #10 + #10 + 'second', 12, 8);
  try
    AssertEquals('the first paragraph starts at row 0', 0,
      RowOfChar(S, 12, 8, 'f'));
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestTightListHasNoGap;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('- a' + #10 + '- b', 10, 4);
  try
    AssertTrue('first bullet', S.CellAt(0, 0).Ch = '•');
    AssertTrue('second bullet on the next row', S.CellAt(0, 1).Ch = '•');
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestStreamingTailIsPlainText;
var
  View: TMarkdownView;
  S: TSurfaceMemory;
begin
  View := TMarkdownView.Create;
  try
    View.AppendSource('**bold**');
    View.Arrange(Rect(20, 2));
    S := TSurfaceMemory.Create(20, 2);
    try
      View.Render(S);
      AssertEquals('the tail is raw', '**bold**', string(S.RowText(0, 0, 20)));
      AssertFalse('the tail is unstyled', sfBold in S.CellAt(0, 0).Attr.Style);
    finally
      S.Free;
    end;

    View.FinishSource;
    View.Arrange(Rect(20, 2));
    S := TSurfaceMemory.Create(20, 2);
    try
      View.Render(S);
      AssertEquals('parsed after finish', 'bold', string(S.RowText(0, 0, 20)));
      AssertTrue('and styled', sfBold in S.CellAt(0, 0).Attr.Style);
    finally
      S.Free;
    end;
  finally
    View.Free;
  end;
end;

procedure TMarkdownViewTest.TestFinalisedBlocksAreNotRebuilt;
var
  View: TMarkdownView;
  Before: Integer;
begin
  View := TMarkdownView.Create;
  try
    View.AppendSource('# Title' + #10 + #10);
    AssertEquals('one finalised block', 1, View.BlockCount);
    View.Arrange(Rect(20, 6));
    Before := View.BlockLayoutBuilds(0);
    AssertTrue('the block has been laid out', Before > 0);

    { A later chunk only touches the tail; the finalised block is untouched. }
    View.AppendSource('tail text');
    AssertEquals('still one finalised block', 1, View.BlockCount);
    View.Arrange(Rect(20, 6));
    AssertEquals('the finalised block was not rebuilt', Before,
      View.BlockLayoutBuilds(0));
  finally
    View.Free;
  end;
end;

procedure TMarkdownViewTest.TestFinishPromotesTheTail;
var
  View: TMarkdownView;
begin
  View := TMarkdownView.Create;
  try
    View.AppendSource('one');
    AssertEquals('no finalised blocks yet', 0, View.BlockCount);
    View.AppendSource(#10 + #10);
    AssertEquals('the first paragraph finalised', 1, View.BlockCount);
    View.AppendSource('two');
    AssertEquals('the second is still the tail', 1, View.BlockCount);
    View.FinishSource;
    AssertEquals('the tail finalised', 2, View.BlockCount);
  finally
    View.Free;
  end;
end;

procedure TMarkdownViewTest.TestHeadingsAreBrightAndBold;
var
  S: TSurfaceMemory;
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  { A leading h1 sits 2 rows down, so the text is at row 2. }
  S := RenderSource('# Title', 20, 5);
  try
    AssertTrue('bold', sfBold in S.CellAt(0, 2).Attr.Style);
    AssertEquals('bright', Theme.Heading[1].Fg, S.CellAt(0, 2).Attr.Fg);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestH1Underline;
var
  S: TSurfaceMemory;
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  S := RenderSource('# Title', 20, 5);
  try
    AssertTrue('heavy underline drawn', S.CellAt(0, 3).Ch = '━');
    AssertEquals('the underline is the dim colour', Theme.Rule.Fg,
      S.CellAt(0, 3).Attr.Fg);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestH2Underline;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('## Title', 20, 5);
  try
    AssertTrue('double underline drawn', S.CellAt(0, 3).Ch = '═');
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestH3Underline;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('### Title', 20, 3);
  try
    AssertTrue('light underline drawn', S.CellAt(0, 1).Ch = '─');
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestH4HasNoUnderline;
var
  S: TSurfaceMemory;
  View: TMarkdownView;
  Avail: TSize;
begin
  S := RenderSource('#### Title', 20, 3);
  try
    AssertTrue('no heavy', S.CellAt(0, 1).Ch <> '━');
    AssertTrue('no double', S.CellAt(0, 1).Ch <> '═');
    AssertTrue('no light', S.CellAt(0, 1).Ch <> '─');
  finally
    S.Free;
  end;
  View := TMarkdownView.Create;
  try
    View.SetSource('#### Title');
    Avail := Default(TSize);
    Avail.W := 20;
    AssertEquals('H4 is a single row', 1, View.Measure(Avail).H);
  finally
    View.Free;
  end;
end;

procedure TMarkdownViewTest.TestUnderlineMatchesTextWidth;
var
  S: TSurfaceMemory;
begin
  { 'Title' is five columns, so the underline covers 0..4 and stops. The leading
    h1's 2-row top margin puts the text on row 2 and the rule on row 3. }
  S := RenderSource('# Title', 20, 5);
  try
    AssertTrue('starts under the text', S.CellAt(0, 3).Ch = '━');
    AssertTrue('ends under the text', S.CellAt(4, 3).Ch = '━');
    AssertTrue('stops at the text', S.CellAt(5, 3).Ch <> '━');
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestBodyIsDimmerThanHeadings;
var
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  { Headings are the bold gold; the body is a dimmer grey. }
  AssertEquals('headings are gold', 222, Theme.Heading[1].Fg);
  AssertEquals('the body is a dimmer grey', 250, Theme.Paragraph.Fg);
end;

procedure TMarkdownViewTest.TestTableRendersGrid;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('| A | B |' + #10 + '| --- | --- |' + #10 + '| 1 | 2 |',
    30, 6);
  try
    AssertTrue('rounded top corner', S.CellAt(0, 0).Ch = '╭');
    AssertTrue('the header cell', S.CellAt(2, 1).Ch = 'A');
    AssertTrue('a rule between rows', S.CellAt(0, 2).Ch = '├');
    AssertTrue('a vertical border', S.CellAt(0, 3).Ch = '│');
    AssertTrue('the first body cell', S.CellAt(2, 3).Ch = '1');
    AssertTrue('rounded bottom corner', S.CellAt(0, 4).Ch = '╰');
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestTableIsContentWidth;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('| A | B | C |' + #10 + '| --- | --- | --- |' + #10 +
    '| 1 | 2 | 3 |', 40, 6);
  try
    AssertTrue('the grid starts at the left', S.CellAt(0, 0).Ch = '╭');
    { Three one-wide columns: 3 + 3*3 + 1 = 13 wide, well inside 40. }
    AssertTrue('the top-right corner is at column 12', S.CellAt(12, 0).Ch = '╮');
    AssertEquals('nothing is drawn past the grid', '',
      string(S.CellAt(13, 0).Ch));
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestTableCompressesAndWraps;
const
  Md = '| Name | Description |' + #10 + '| --- | --- |' + #10 +
    '| x | wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww |';
var
  S: TSurfaceMemory;
  View: TMarkdownView;
  Avail: TSize;
begin
  View := TMarkdownView.Create;
  try
    View.SetSource(Md);
    Avail := Default(TSize);
    Avail.W := 24;
    Avail.H := 40;
    { Wrapped, so taller than the five rows an unwrapped table would need. }
    AssertTrue('the wide cell wraps', View.Measure(Avail).H > 5);
  finally
    View.Free;
  end;
  S := RenderSource(Md, 24, 40);
  try
    AssertTrue('the grid spans the container width', S.CellAt(23, 0).Ch = '╮');
    AssertTrue('the body starts below the rule', S.CellAt(0, 3).Ch = '│');
    AssertTrue('the wrapped cell continues on the next line',
      S.CellAt(0, 4).Ch = '│');
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestTableAlignment;
var
  S: TSurfaceMemory;
begin
  { A right-aligned column pushes its value to the column's right edge. }
  S := RenderSource('| Item | Qty |' + #10 + '| :--- | ---: |' + #10 +
    '| x | 1 |', 30, 6);
  try
    AssertTrue('the right-aligned value sits at the right edge',
      S.CellAt(11, 3).Ch = '1');
  finally
    S.Free;
  end;

  { A centre-aligned column centres its value. }
  S := RenderSource('| Header |' + #10 + '| :----: |' + #10 + '| z |', 20, 5);
  try
    AssertTrue('the centred value', S.CellAt(4, 3).Ch = 'z');
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestTableUsesTheThemeColours;
var
  S: TSurfaceMemory;
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  S := RenderSource('| A |' + #10 + '| --- |' + #10 + '| 1 |', 20, 5);
  try
    AssertEquals('the header is the bold gold', Theme.Bold.Fg,
      S.CellAt(2, 1).Attr.Fg);
    AssertTrue('the header is bold', sfBold in S.CellAt(2, 1).Attr.Style);
    AssertEquals('the body is plain', Theme.Paragraph.Fg,
      S.CellAt(2, 3).Attr.Fg);
    AssertEquals('the border is the rule colour', Theme.Rule.Fg,
      S.CellAt(0, 0).Attr.Fg);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestTableBalancesForLeastHeight;
const
  Md =
    '| # | Notes | Detail |' + #10 +
    '| --- | --- | --- |' + #10 +
    '| 1 | alpha beta gamma delta epsilon zeta | a long detail string here ' +
    'that spans many words and needs a lot of room to lay out |';
var
  View: TMarkdownView;
  Avail: TSize;
begin
  View := TMarkdownView.Create;
  try
    View.SetSource(Md);
    Avail := Default(TSize);
    Avail.W := 52;
    Avail.H := 20;
    { The wide Detail column gives width back to the short-worded Notes column
      instead of keeping it all, so the body row is four lines rather than the
      six it would be at the Notes word floor. }
    AssertEquals('the height is minimised', 8, View.Measure(Avail).H);
  finally
    View.Free;
  end;
end;

procedure TMarkdownViewTest.TestTableCellsAreNotRebuilt;
var
  View: TMarkdownView;
  Before: Integer;
begin
  View := TMarkdownView.Create;
  try
    View.AppendSource('| A | B |' + #10 + '| --- | --- |' + #10 + '| 1 | 2 |' +
      #10 + #10);
    AssertEquals('one finalised block', 1, View.BlockCount);
    View.Arrange(Rect(30, 8));
    Before := View.BlockLayoutBuilds(0);
    AssertTrue('the table has been laid out', Before > 0);

    View.AppendSource('tail');
    View.Arrange(Rect(30, 8));
    AssertEquals('the table cells were not rebuilt', Before,
      View.BlockLayoutBuilds(0));
  finally
    View.Free;
  end;
end;

initialization
  RegisterTest(TMarkdownViewTest);

end.
