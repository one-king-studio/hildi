unit test_tui_scroll;
{ fpcunit tests for hildegard.helper.tui.scroll: scroll containers, clamping,
  keyboard scrolling, and scrollbar thumb geometry. No terminal is attached. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.widget, hildegard.helper.tui.scroll;

type
  TScrollProbe = class(TWidget)
  private
    FW, FH: Integer;
  public
    constructor Create(AW, AH: Integer);
    function Measure(const AAvail: TSize): TSize; override;
  end;

  TTuiScrollTest = class(TTestCase)
  private
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function KeyEvent(AKind: TKeyKind): TInputEvent;
  published
    procedure TestContentSmallerThanViewportDoesNotScroll;
    procedure TestContentEqualViewportDoesNotScroll;
    procedure TestContentLargerThanViewportScrolls;
    procedure TestScrollClampedAtBothEnds;
    procedure TestKeyboardScrollKeysMoveViewport;
    procedure TestTwoContainersScrollIndependently;
    procedure TestScrollbarThumbGeometry;
  end;

implementation

constructor TScrollProbe.Create(AW, AH: Integer);
begin
  inherited Create;
  FW := AW;
  FH := AH;
end;

function TScrollProbe.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := FW;
  Result.H := FH;
end;

function TTuiScrollTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TTuiScrollTest.KeyEvent(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

procedure TTuiScrollTest.TestContentSmallerThanViewportDoesNotScroll;
var
  C: TScrollContainer;
begin
  C := TScrollContainer.Create(TScrollProbe.Create(5, 3), smAuto, smNever);
  try
    C.Arrange(Rc(0, 0, 10, 10));
    C.ScrollBy(0, 5);
    AssertEquals('small content stays at 0', 0, C.ScrollY);
  finally
    C.Free;
  end;
end;

procedure TTuiScrollTest.TestContentEqualViewportDoesNotScroll;
var
  C: TScrollContainer;
begin
  C := TScrollContainer.Create(TScrollProbe.Create(10, 10), smAuto, smNever);
  try
    C.Arrange(Rc(0, 0, 10, 10));
    C.ScrollBy(0, 5);
    AssertEquals('equal content stays at 0', 0, C.ScrollY);
  finally
    C.Free;
  end;
end;

procedure TTuiScrollTest.TestContentLargerThanViewportScrolls;
var
  C: TScrollContainer;
begin
  C := TScrollContainer.Create(TScrollProbe.Create(10, 100), smAuto, smNever);
  try
    C.Arrange(Rc(0, 0, 10, 10));
    C.ScrollBy(0, 5);
    AssertEquals('large content scrolls', 5, C.ScrollY);
  finally
    C.Free;
  end;
end;

procedure TTuiScrollTest.TestScrollClampedAtBothEnds;
var
  C: TScrollContainer;
begin
  C := TScrollContainer.Create(TScrollProbe.Create(10, 100), smAuto, smNever);
  try
    C.Arrange(Rc(0, 0, 10, 10));
    C.ScrollTo(0, 1000);
    AssertEquals('clamped to content minus viewport', 90, C.ScrollY);
    C.ScrollTo(0, -5);
    AssertEquals('clamped to zero', 0, C.ScrollY);
  finally
    C.Free;
  end;
end;

procedure TTuiScrollTest.TestKeyboardScrollKeysMoveViewport;
var
  C: TScrollContainer;
begin
  C := TScrollContainer.Create(TScrollProbe.Create(10, 100), smAuto, smNever);
  try
    C.Arrange(Rc(0, 0, 10, 10));
    AssertTrue('down handled', C.HandleEvent(KeyEvent(kkDown)));
    AssertEquals('one line down', 1, C.ScrollY);
    AssertTrue('page down handled', C.HandleEvent(KeyEvent(kkPageDown)));
    AssertEquals('one page down', 11, C.ScrollY);
    AssertTrue('end handled', C.HandleEvent(KeyEvent(kkEnd)));
    AssertEquals('end of content', 90, C.ScrollY);
    AssertTrue('home handled', C.HandleEvent(KeyEvent(kkHome)));
    AssertEquals('back to top', 0, C.ScrollY);
  finally
    C.Free;
  end;
end;

procedure TTuiScrollTest.TestTwoContainersScrollIndependently;
var
  C1, C2: TScrollContainer;
begin
  C1 := TScrollContainer.Create(TScrollProbe.Create(10, 100), smAuto, smNever);
  C2 := TScrollContainer.Create(TScrollProbe.Create(10, 100), smAuto, smNever);
  try
    C1.Arrange(Rc(0, 0, 10, 10));
    C2.Arrange(Rc(0, 0, 10, 10));
    C1.ScrollBy(0, 5);
    C2.ScrollBy(0, 2);
    AssertEquals('first pane offset', 5, C1.ScrollY);
    AssertEquals('second pane offset', 2, C2.ScrollY);
  finally
    C2.Free;
    C1.Free;
  end;
end;

procedure TTuiScrollTest.TestScrollbarThumbGeometry;
var
  Bar: TScrollBar;
begin
  Bar := TScrollBar.Create(soVertical);
  try
    Bar.Arrange(Rc(0, 0, 1, 10));
    Bar.Range := 100;
    Bar.Page := 20;
    Bar.Value := 0;
    AssertEquals('thumb length', 2, Bar.ThumbSize);
    AssertEquals('thumb at top', 0, Bar.ThumbStart);
    Bar.Value := 40;
    AssertEquals('thumb at middle', 4, Bar.ThumbStart);
    Bar.Value := 80;
    AssertEquals('thumb at bottom', 8, Bar.ThumbStart);
    Bar.Value := 999;
    AssertEquals('value clamped to range minus page', 80, Bar.Value);
    Bar.Range := 20;
    AssertEquals('thumb fills track when range equals page', 10, Bar.ThumbSize);
    AssertEquals('full thumb at origin', 0, Bar.ThumbStart);
  finally
    Bar.Free;
  end;
end;

initialization
  RegisterTest(TTuiScrollTest);
end.
