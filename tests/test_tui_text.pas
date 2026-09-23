unit test_tui_text;
{ fpcunit tests for hildegard.helper.tui.text: styled spans, wrapping, wide
  characters, and clipping. Rendering is asserted through TSurfaceMemory. }

{$mode delphi}{$H+}
{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.surface,
  hildegard.helper.tui.text;

type
  TTuiTextTest = class(TTestCase)
  private
    function SpanOf(const AText: UnicodeString; AFg: Byte = 7): TSpan;
    function Rc(AX, AY, AW, AH: Integer): TRect;
  published
    procedure TestMeasureLongestLine;
    procedure TestCharacterWrap;
    procedure TestWordWrap;
    procedure TestWideCharacterOccupiesTwoColumns;
    procedure TestCombiningMarkIsOneCluster;
    procedure TestStyledSpansRetainAttributes;
    procedure TestTextClippedToBounds;
    procedure TestWrapWidthOverridesMaxContent;
  end;

implementation

function TTuiTextTest.SpanOf(const AText: UnicodeString; AFg: Byte): TSpan;
begin
  Result := Default(TSpan);
  Result.Text := AText;
  Result.Attr.Fg := AFg;
  Result.Attr.Bg := 0;
  Result.Attr.Style := [];
end;

function TTuiTextTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

procedure TTuiTextTest.TestMeasureLongestLine;
var
  T: TTextBlock;
  Sz: TSize;
begin
  T := TTextBlock.Create([SpanOf('hello'#10'hi')], wmNone);
  try
    Sz := T.Measure(Default(TSize));
    AssertEquals('width is the longest line', 5, Sz.W);
    AssertEquals('height is the line count', 2, Sz.H);
  finally
    T.Free;
  end;
end;

procedure TTuiTextTest.TestCharacterWrap;
var
  T: TTextBlock;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(10, 4);
  try
    S.Clear(DefaultAttr);
    T := TTextBlock.Create([SpanOf('abcdefgh')], wmChar);
    try
      T.Arrange(Rc(0, 0, 4, 4));
      T.Render(S);
    finally
      T.Free;
    end;
    AssertEquals('first wrapped row', 'abcd', S.RowText(0, 0, 4));
    AssertEquals('second wrapped row', 'efgh', S.RowText(1, 0, 4));
  finally
    S.Free;
  end;
end;

procedure TTuiTextTest.TestWordWrap;
var
  T: TTextBlock;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(10, 4);
  try
    S.Clear(DefaultAttr);
    T := TTextBlock.Create([SpanOf('the quick brown')], wmWord);
    try
      T.Arrange(Rc(0, 0, 7, 4));
      T.Render(S);
    finally
      T.Free;
    end;
    AssertEquals('word row 0', 'the', S.RowText(0, 0, 7));
    AssertEquals('word row 1', 'quick', S.RowText(1, 0, 7));
    AssertEquals('word row 2', 'brown', S.RowText(2, 0, 7));
  finally
    S.Free;
  end;
end;

procedure TTuiTextTest.TestWideCharacterOccupiesTwoColumns;
var
  T: TTextBlock;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(10, 2);
  try
    S.Clear(DefaultAttr);
    T := TTextBlock.Create([SpanOf(UnicodeString('世') + 'x')], wmNone);
    try
      T.Arrange(Rc(0, 0, 10, 1));
      T.Render(S);
    finally
      T.Free;
    end;
    AssertEquals('wide glyph in first column', UnicodeString('世'),
      S.CellAt(0, 0).Ch);
    AssertEquals('continuation column blank', '', S.CellAt(1, 0).Ch);
    AssertEquals('next glyph two columns over', 'x', S.CellAt(2, 0).Ch);
  finally
    S.Free;
  end;
end;

procedure TTuiTextTest.TestCombiningMarkIsOneCluster;
var
  T: TTextBlock;
  S: TSurfaceMemory;
  Cluster: UnicodeString;
  Sz: TSize;
begin
  Cluster := 'e' + #$0301;
  T := TTextBlock.Create([SpanOf(Cluster + 'x')], wmNone);
  try
    Sz := T.Measure(Default(TSize));
    AssertEquals('combining mark adds no width', 2, Sz.W);

    S := TSurfaceMemory.Create(10, 1);
    try
      S.Clear(DefaultAttr);
      T.Arrange(Rc(0, 0, 10, 1));
      T.Render(S);
      AssertEquals('cluster stored whole', Cluster, S.CellAt(0, 0).Ch);
      AssertEquals('next glyph follows immediately', 'x', S.CellAt(1, 0).Ch);
    finally
      S.Free;
    end;
  finally
    T.Free;
  end;
end;

procedure TTuiTextTest.TestStyledSpansRetainAttributes;
var
  T: TTextBlock;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(10, 2);
  try
    S.Clear(DefaultAttr);
    T := TTextBlock.Create([SpanOf('ab', 200), SpanOf('cd', 100)], wmNone);
    try
      T.Arrange(Rc(0, 0, 10, 1));
      T.Render(S);
    finally
      T.Free;
    end;
    AssertEquals('text assembled', 'abcd', S.RowText(0, 0, 4));
    AssertEquals('first span fg', 200, S.CellAt(0, 0).Attr.Fg);
    AssertEquals('second span fg', 100, S.CellAt(2, 0).Attr.Fg);
  finally
    S.Free;
  end;
end;

procedure TTuiTextTest.TestTextClippedToBounds;
var
  T: TTextBlock;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(10, 3);
  try
    S.Clear(DefaultAttr);
    T := TTextBlock.Create([SpanOf('abcdef'#10'ghij')], wmNone);
    try
      T.Arrange(Rc(1, 1, 3, 1));
      T.Render(S);
    finally
      T.Free;
    end;
    AssertEquals('clipped to width', 'abc', S.RowText(1, 1, 3));
    AssertEquals('beyond width is blank', '', S.RowText(1, 4, 3));
    AssertEquals('second line clipped away', '', S.RowText(2, 1, 3));
  finally
    S.Free;
  end;
end;

procedure TTuiTextTest.TestWrapWidthOverridesMaxContent;
var
  T: TTextBlock;
  Sz: TSize;
begin
  T := TTextBlock.Create([SpanOf('aa bb cc dd')], wmWord);
  try
    { Without WrapWidth, Measure is max-content (longest word = 2). }
    Sz := T.Measure(Default(TSize));
    AssertEquals('max-content width', 2, Sz.W);
    { With WrapWidth, the block fills the width and reports wrapped height. }
    T.WrapWidth := 5;
    Sz := T.Measure(Default(TSize));
    AssertEquals('wrapped width', 5, Sz.W);
    AssertEquals('wrapped height', 3, Sz.H);
  finally
    T.Free;
  end;
end;

initialization
  RegisterTest(TTuiTextTest);
end.
