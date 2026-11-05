unit TestTUITestKit;
{ fpcunit tests for TUITestKit.

  A kit that ships is a deliverable, so it is tested like one. This also proves
  the kit is USABLE rather than merely present: every assertion below goes
  through the kit's own API, which is how a consumer would use it. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput, TUISurface, TUITheme, TUIWidget,
  TUIWidgetsText, TUITestKit,
  TUIWidgetsSelectable;

type
  { A minimal two-row selectable, so the kit can be exercised against the copy
    path as well as the paint path. }
  TKitProbe = class(TSelectable)
  private
    FRows: TStringArray;
  protected
    function RowCount: Integer; override;
    function RowTextAt(ARow: Integer): UnicodeString; override;
    function RowWrapsAt(ARow: Integer): Boolean; override;
  public
    constructor Create(const ARows: TStringArray);
    procedure Render(const S: ISurface); override;
  end;

  TTestKitTest = class(TTestCase)
  private
    FTheme: TTheme;
    function Rc(AX, AY, AW, AH: Integer): TRect;
  protected
    procedure SetUp; override;
  published
    procedure TestFixtureRendersAndReadsRows;
    procedure TestFixtureReadsASingleCell;
    procedure TestFixtureReadsAColumnRange;
    procedure TestFixtureCountsPuts;
    procedure TestFixtureExposesTheClipboard;

    procedure TestEventBuildersProduceTheRightShapes;
    procedure TestADragReadsAsThreeLines;
  end;

implementation

{ TKitProbe }

constructor TKitProbe.Create(const ARows: TStringArray);
begin
  inherited Create;
  FRows := ARows;
  Selectable := True;
end;

function TKitProbe.RowCount: Integer;
begin
  Result := Length(FRows);
end;

function TKitProbe.RowTextAt(ARow: Integer): UnicodeString;
begin
  if (ARow >= 0) and (ARow <= High(FRows)) then
    Result := UnicodeString(FRows[ARow])
  else
    Result := '';
end;

function TKitProbe.RowWrapsAt(ARow: Integer): Boolean;
begin
  Result := False;
end;

procedure TKitProbe.Render(const S: ISurface);
var
  I, X: Integer;
  C: TCell;
  Line: UnicodeString;
begin
  for I := 0 to RowCount - 1 do
  begin
    Line := RowTextAt(I);
    for X := 1 to Length(Line) do
    begin
      C := Default(TCell);
      C.Ch := Line[X];
      C.Attr := DefaultAttr;
      S.Put(Bounds.X + X - 1, Bounds.Y + I, C);
    end;
  end;
  RenderSelection(S);
end;

{ TTestKitTest }

procedure TTestKitTest.SetUp;
begin
  FTheme := DarkTheme;
end;

function TTestKitTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  { Each TUI unit carries its own four-line rect constructor; there is no shared
    one in core, which is why every test file has this. }
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

procedure TTestKitTest.TestFixtureRendersAndReadsRows;
var
  F: TWidgetFixture;
  B: TTextBlock;
  Spans: array of TSpan;
begin
  F := TWidgetFixture.Create(20, 5, FTheme);
  B := nil;
  try
    SetLength(Spans, 1);
    Spans[0].Text := 'hello kit';
    Spans[0].Attr := FTheme.Text;
    B := TTextBlock.Create(Spans, wmWord);
    F.Render(B);
    AssertTrue('the row text is readable through the kit',
      Pos('hello', F.Row(0)) > 0);
  finally
    B.Free;
    F.Free;
  end;
end;

procedure TTestKitTest.TestFixtureReadsASingleCell;
var
  F: TWidgetFixture;
  B: TTextBlock;
  Spans: array of TSpan;
begin
  F := TWidgetFixture.Create(20, 5, FTheme);
  B := nil;
  try
    SetLength(Spans, 1);
    Spans[0].Text := 'X';
    Spans[0].Attr := FTheme.Text;
    B := TTextBlock.Create(Spans, wmWord);
    F.Render(B);
    AssertEquals('the glyph is at 0,0', 'X', string(F.CellAt(0, 0).Ch));
  finally
    B.Free;
    F.Free;
  end;
end;

procedure TTestKitTest.TestFixtureReadsAColumnRange;
var
  F: TWidgetFixture;
  B: TTextBlock;
  Spans: array of TSpan;
begin
  F := TWidgetFixture.Create(20, 5, FTheme);
  B := nil;
  try
    SetLength(Spans, 1);
    Spans[0].Text := 'abcdef';
    Spans[0].Attr := FTheme.Text;
    B := TTextBlock.Create(Spans, wmWord);
    F.Render(B);
    { A range read is what a truncation test needs: the kit should not force a
      caller to slice a full row by hand. }
    AssertEquals('a column range reads the middle', 'bcd', F.Row(0, 1, 3));
  finally
    B.Free;
    F.Free;
  end;
end;

procedure TTestKitTest.TestFixtureCountsPuts;
var
  F: TWidgetFixture;
  B: TTextBlock;
  Spans: array of TSpan;
begin
  F := TWidgetFixture.Create(20, 5, FTheme);
  B := nil;
  try
    SetLength(Spans, 1);
    Spans[0].Text := 'abc';
    Spans[0].Attr := FTheme.Text;
    B := TTextBlock.Create(Spans, wmWord);
    F.Render(B);
    { PutCount is how a test proves content was CULLED rather than drawn and
      clipped, so the kit has to expose it. }
    AssertTrue('puts were counted', F.PutCount > 0);
  finally
    B.Free;
    F.Free;
  end;
end;

procedure TTestKitTest.TestFixtureExposesTheClipboard;
var
  F: TWidgetFixture;
  W: TKitProbe;
begin
  F := TWidgetFixture.Create(10, 3, FTheme);
  W := TKitProbe.Create(['abcdef']);
  try
    W.Arrange(Rc(0, 0, 10, 3));
    W.HandleEvent(PressAt(1, 0));
    W.HandleEvent(MoveTo(4, 0));
    AssertTrue('copy reported success', W.CopySelection(F.Surface));
    AssertEquals('the kit reads what was copied', 'bcd', F.ClipboardText);
    AssertEquals('and counts the write', 1, F.ClipboardWrites);
  finally
    W.Free;
    F.Free;
  end;
end;

procedure TTestKitTest.TestEventBuildersProduceTheRightShapes;
var
  E: TInputEvent;
begin
  E := PressAt(3, 4);
  AssertTrue('a press is a mouse event', E.Kind = ikMouse);
  AssertEquals('with the x', 3, E.Mouse.X);
  AssertEquals('and the y', 4, E.Mouse.Y);
  AssertTrue('and the left button', E.Mouse.Button = mbLeft);
  AssertTrue('and the press action', E.Mouse.Action = maPress);

  E := MoveTo(5, 6);
  AssertTrue('a drag carries the button it holds', E.Mouse.Button = mbLeft);
  AssertTrue('and is a motion', E.Mouse.Action = maMotion);

  E := ReleaseAt(5, 6);
  AssertTrue('a release carries no button', E.Mouse.Button = mbNone);
  AssertTrue('and is a release', E.Mouse.Action = maRelease);

  E := CharEvent('y', [moCtrl]);
  AssertTrue('a char event is a key', E.Kind = ikKey);
  AssertTrue('carrying the letter', E.Key.Ch = 'y');
  AssertTrue('and the modifier', moCtrl in E.Key.Mods);

  E := KeyEvent(kkEnter);
  AssertTrue('a plain key needs no character', E.Key.Kind = kkEnter);

  E := ResizeEvent(80, 24);
  AssertEquals('a resize carries its size', 80, E.NewSize.W);
end;

procedure TTestKitTest.TestADragReadsAsThreeLines;
var
  F: TWidgetFixture;
  W: TKitProbe;
begin
  { This is the point of the builders: a drag is three readable lines, not three
    hand-built records. }
  F := TWidgetFixture.Create(10, 3, FTheme);
  W := TKitProbe.Create(['abcdef']);
  try
    W.Arrange(Rc(0, 0, 10, 3));
    W.HandleEvent(PressAt(1, 0));
    W.HandleEvent(MoveTo(4, 0));
    W.HandleEvent(ReleaseAt(4, 0));
    AssertEquals('the drag selected the expected text', 'bcd', W.SelectedText);
    AssertFalse('and the drag ended', W.Dragging);
  finally
    W.Free;
    F.Free;
  end;
end;

initialization
  RegisterTest(TTestKitTest);
end.
