unit test_markdownview;
{ fpcunit tests for hildegard.helper.tui.markdownview: block rendering, chrome,
  and the streaming tail. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.markdown,
  hildegard.helper.tui.base, hildegard.helper.tui.widget,
  hildegard.helper.tui.surface, hildegard.helper.tui.markdownview;

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
    procedure TestQuoteBar;
    procedure TestRuleIsFullWidth;
    procedure TestCodeBackdropFillsTheRow;
    procedure TestBlocksAreSeparatedByABlankRow;
    procedure TestTightListHasNoGap;
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
  S := RenderSource('# Title', 20, 2);
  try
    AssertEquals('heading colour', Theme.Heading[1].Fg, S.CellAt(0, 0).Attr.Fg);
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

procedure TMarkdownViewTest.TestCodeBackdropFillsTheRow;
var
  S: TSurfaceMemory;
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  S := RenderSource('```' + #10 + 'code' + #10 + '```', 12, 3);
  try
    AssertEquals('code text drawn', 'code',
      string(S.RowText(0, 0, 4)));
    AssertEquals('backdrop to the edge', Theme.CodeBackdrop.Bg,
      S.CellAt(11, 0).Attr.Bg);
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
  S := RenderSource('# Title', 20, 3);
  try
    AssertTrue('bold', sfBold in S.CellAt(0, 0).Attr.Style);
    AssertEquals('bright', Theme.Heading[1].Fg, S.CellAt(0, 0).Attr.Fg);
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
  S := RenderSource('# Title', 20, 3);
  try
    AssertTrue('heavy underline drawn', S.CellAt(0, 1).Ch = '━');
    AssertEquals('the underline is the dim colour', Theme.Rule.Fg,
      S.CellAt(0, 1).Attr.Fg);
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestH2Underline;
var
  S: TSurfaceMemory;
begin
  S := RenderSource('## Title', 20, 3);
  try
    AssertTrue('double underline drawn', S.CellAt(0, 1).Ch = '═');
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
  { 'Title' is five columns, so the underline covers 0..4 and stops. }
  S := RenderSource('# Title', 20, 3);
  try
    AssertTrue('starts under the text', S.CellAt(0, 1).Ch = '━');
    AssertTrue('ends under the text', S.CellAt(4, 1).Ch = '━');
    AssertTrue('stops at the text', S.CellAt(5, 1).Ch <> '━');
  finally
    S.Free;
  end;
end;

procedure TMarkdownViewTest.TestBodyIsDimmerThanHeadings;
var
  Theme: TMdTheme;
begin
  Theme := DefaultMdTheme;
  { 231 is #ffffff; 250 is a dimmer grey in the 256-colour ramp. }
  AssertEquals('headings are the brightest white', 231, Theme.Heading[1].Fg);
  AssertEquals('the body is a dimmer grey', 250, Theme.Paragraph.Fg);
end;

initialization
  RegisterTest(TMarkdownViewTest);

end.
