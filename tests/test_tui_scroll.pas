unit test_tui_scroll;
{ fpcunit tests for hildegard.helper.tui.scroll: scroll containers, clamping,
  keyboard scrolling, and scrollbar thumb geometry. No terminal is attached. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface,
  hildegard.helper.tui.widget, hildegard.helper.tui.scroll;

type
  TScrollProbe = class(TWidget)
  private
    FW, FH: Integer;
  public
    MouseHits: Integer;
    constructor Create(AW, AH: Integer);
    function Measure(const AAvail: TSize): TSize; override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  TTuiScrollTest = class(TTestCase)
  private
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function KeyEvent(AKind: TKeyKind): TInputEvent;
    function MouseEvent(AX, AY: Integer; AButton: TMouseButton): TInputEvent;
  published
    procedure TestContentSmallerThanViewportDoesNotScroll;
    procedure TestContentEqualViewportDoesNotScroll;
    procedure TestContentLargerThanViewportScrolls;
    procedure TestScrollClampedAtBothEnds;
    procedure TestKeyboardScrollKeysMoveViewport;
    procedure TestTwoContainersScrollIndependently;
    procedure TestScrollbarThumbGeometry;
    procedure TestScrollbarThumbTracksScroll;
    procedure TestScrollbarDragScrolls;
    procedure TestHiddenTrackLeavesWhatIsBehind;
    procedure TestClickInsideViewportReachesChild;
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

function TScrollProbe.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := False;
  if (E.Kind = ikMouse) and (E.Mouse.Button = mbLeft) then
  begin
    Inc(MouseHits);
    Result := True;
  end;
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

function TTuiScrollTest.MouseEvent(AX, AY: Integer;
  AButton: TMouseButton): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikMouse;
  Result.Mouse.X := AX;
  Result.Mouse.Y := AY;
  Result.Mouse.Button := AButton;
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

procedure TTuiScrollTest.TestScrollbarThumbTracksScroll;
var
  C: TScrollContainer;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(10, 10);
  try
    C := TScrollContainer.Create(TScrollProbe.Create(10, 100), smAuto, smNever);
    try
      C.Arrange(Rc(0, 0, 10, 10));
      S.Clear(DefaultAttr);
      C.Render(S);
      S.Flush;
      AssertEquals('thumb at top', '┃', S.CellAt(9, 0).Ch);

      C.ScrollTo(0, 90);
      S.Clear(DefaultAttr);
      C.Render(S);
      S.Flush;
      AssertEquals('thumb moved to bottom', '┃', S.CellAt(9, 9).Ch);
      AssertEquals('track left behind', '┃', S.CellAt(9, 0).Ch);
    finally
      C.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiScrollTest.TestScrollbarDragScrolls;
var
  C: TScrollContainer;
  E: TInputEvent;
begin
  C := TScrollContainer.Create(TScrollProbe.Create(10, 100), smAuto, smNever);
  try
    C.Arrange(Rc(0, 0, 10, 10));
    { Press on the bottom of the vertical track (column 9). }
    AssertTrue('press on bar handled',
      C.HandleEvent(MouseEvent(9, 9, mbLeft)));
    AssertEquals('dragged to bottom', 90, C.ScrollY);
    { Motion while held updates the position. }
    E := MouseEvent(9, 4, mbLeft);
    AssertTrue('motion handled', C.HandleEvent(E));
    AssertEquals('dragged to middle', 40, C.ScrollY);
    { Release ends the drag; a wheel event then scrolls normally. }
    AssertTrue('release handled', C.HandleEvent(MouseEvent(9, 4, mbNone)));
    AssertTrue('wheel handled',
      C.HandleEvent(MouseEvent(3, 4, mbWheelUp)));
    AssertEquals('wheel scrolled up by three', 37, C.ScrollY);
  finally
    C.Free;
  end;
end;

procedure TTuiScrollTest.TestHiddenTrackLeavesWhatIsBehind;
var
  C: TScrollContainer;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(10, 10);
  try
    C := TScrollContainer.Create(TScrollProbe.Create(10, 100), smAuto, smNever);
    try
      { With the track hidden the bar only paints its thumb, so a panel border
        behind the bar column reads as the track. }
      C.TrackVisible := False;
      C.Arrange(Rc(0, 0, 10, 10));
      S.Clear(DefaultAttr);
      C.Render(S);
      S.Flush;
      AssertEquals('thumb still drawn', '┃', S.CellAt(9, 0).Ch);
      AssertEquals('track cell left untouched', ErasedChar, S.CellAt(9, 9).Ch);
    finally
      C.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiScrollTest.TestClickInsideViewportReachesChild;
var
  Probe: TScrollProbe;
  C: TScrollContainer;
begin
  Probe := TScrollProbe.Create(10, 100);   { taller than the viewport }
  C := TScrollContainer.Create(Probe, smAuto, smNever);
  try
    C.Arrange(Rc(0, 0, 10, 10));
    AssertTrue('click inside the viewport reaches the child',
      C.HandleEvent(MouseEvent(3, 2, mbLeft)));
    AssertEquals('child saw the click', 1, Probe.MouseHits);
    AssertFalse('click outside the viewport is not forwarded',
      C.HandleEvent(MouseEvent(50, 50, mbLeft)));
    AssertEquals('child saw nothing more', 1, Probe.MouseHits);
  finally
    C.Free;
  end;
end;

initialization
  RegisterTest(TTuiScrollTest);
end.
