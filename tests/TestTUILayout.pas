unit TestTUILayout;
{ fpcunit tests for TUIWidget: the widget protocol and the
  grid layout engine.

  A probe widget with a settable preferred size and a one-row marker render is
  used to observe assigned bounds and clipping. Everything runs against
  TSurfaceMemory, so no terminal is attached. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput,
  TUISurface, TUIWidget;

type
  TProbeWidget = class(TWidget)
  private
    FPrefW, FPrefH: Integer;
    FMarker: UnicodeString;
  public
    MeasureCalls: Integer;
    { HandleEvent recording: a probe reports Handled and counts the call, so a
      test can tell WHICH child an event reached. }
    HandleCalls: Integer;
    Handled: Boolean;
    constructor Create(APrefW, APrefH: Integer;
      const AMarker: UnicodeString = '#');
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  TTuiLayoutTest = class(TTestCase)
  private
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function Mouse(X, Y: Integer): TInputEvent;
    function Key(AKind: TKeyKind): TInputEvent;
  published
    procedure TestFixedTracksTakeExactSize;
    procedure TestFillTracksShareRemainderByWeight;
    procedure TestAutoTrackMeasuresContent;
    procedure TestGapsReduceAvailableSpace;
    procedure TestNestedContainerIsLaidOut;
    procedure TestVerticalStackIsOneColumnGrid;
    procedure TestEmptyAndZeroSizedTracks;
    procedure TestOverflowingContentIsClipped;
    procedure TestHitTestDefaultsToBounds;
    procedure TestHitTestIsFalseWhenInvisible;
    procedure TestOverlappingMouseClickGoesToTheTopmostChild;
    procedure TestKeyboardDispatchKeepsAddOrder;
    procedure TestMouseOutsideEveryChildIsNotHandled;
  end;

implementation

constructor TProbeWidget.Create(APrefW, APrefH: Integer;
  const AMarker: UnicodeString);
begin
  inherited Create;
  FPrefW := APrefW;
  FPrefH := APrefH;
  FMarker := AMarker;
end;

function TProbeWidget.Measure(const AAvail: TSize): TSize;
begin
  Inc(MeasureCalls);
  Result := Default(TSize);
  Result.W := FPrefW;
  Result.H := FPrefH;
end;

function TProbeWidget.HandleEvent(const E: TInputEvent): Boolean;
begin
  Inc(HandleCalls);
  { Like every real leaf, the probe claims a mouse event only when the point is
    its own. A probe that claimed everything would let a test "prove" dispatch
    order while telling us nothing about how a real widget behaves. }
  if E.Kind = ikMouse then
    Result := Handled and HitTest(E.Mouse.X, E.Mouse.Y)
  else
    Result := Handled;
end;

procedure TProbeWidget.Render(const S: ISurface);
var
  I: Integer;
  C: TCell;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  C := Default(TCell);
  C.Ch := FMarker;
  C.Attr := DefaultAttr;
  for I := 0 to FBounds.W - 1 do
    S.Put(FBounds.X + I, FBounds.Y, C);
end;

function TTuiLayoutTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TTuiLayoutTest.Mouse(X, Y: Integer): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikMouse;
  Result.Mouse.X := X;
  Result.Mouse.Y := Y;
  Result.Mouse.Button := mbLeft;
  Result.Mouse.Action := maPress;
end;

function TTuiLayoutTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

procedure TTuiLayoutTest.TestHitTestDefaultsToBounds;
var
  W: TProbeWidget;
begin
  W := TProbeWidget.Create(1, 1);
  try
    W.Arrange(Rc(5, 3, 10, 4));
    AssertTrue('top-left corner', W.HitTest(5, 3));
    AssertTrue('last cell inside', W.HitTest(14, 6));
    AssertFalse('just left', W.HitTest(4, 3));
    AssertFalse('just above', W.HitTest(5, 2));
    AssertFalse('one past the right edge', W.HitTest(15, 3));
    AssertFalse('one past the bottom edge', W.HitTest(5, 7));
  finally
    W.Free;
  end;
end;

procedure TTuiLayoutTest.TestHitTestIsFalseWhenInvisible;
var
  W: TProbeWidget;
begin
  W := TProbeWidget.Create(1, 1);
  try
    W.Arrange(Rc(0, 0, 10, 4));
    AssertTrue('visible hit', W.HitTest(2, 2));
    W.Visible := False;
    AssertFalse('an invisible widget cannot be hit', W.HitTest(2, 2));
  finally
    W.Free;
  end;
end;

procedure TTuiLayoutTest.TestOverlappingMouseClickGoesToTheTopmostChild;
var
  C: TContainer;
  Bottom, Top: TProbeWidget;
begin
  { Both children occupy the same cell. Paint order is Add order, so the second
    one is on top; a click must land on the thing the operator can see. The top
    child claims the event, so the bottom one must never be consulted - that is
    what distinguishes reverse order from Add order. }
  C := TContainer.Create([Fixed(10)], [Fixed(4)]);
  try
    Bottom := TProbeWidget.Create(10, 4, 'b');
    Top := TProbeWidget.Create(10, 4, 't');
    Top.Handled := True;
    C.Add(Bottom, 0, 0);
    C.Add(Top, 0, 0);
    C.Arrange(Rc(0, 0, 10, 4));

    AssertTrue('the container reports the hit itself', C.HitTest(3, 1));
    AssertTrue('the click was handled', C.HandleEvent(Mouse(3, 1)));
    AssertEquals('topmost saw it', 1, Top.HandleCalls);
    AssertEquals('bottom was never consulted', 0, Bottom.HandleCalls);
  finally
    C.Free;
  end;
end;

procedure TTuiLayoutTest.TestKeyboardDispatchKeepsAddOrder;
var
  C: TContainer;
  First, Second: TProbeWidget;
begin
  { Keyboard order is NOT z-order: the first child added still sees a key
    first. Only mouse events are reordered, because only mouse events are about
    what is visually on top. }
  C := TContainer.Create([Fixed(10)], [Fixed(4)]);
  try
    First := TProbeWidget.Create(10, 4, 'a');
    Second := TProbeWidget.Create(10, 4, 'b');
    First.Handled := True;
    C.Add(First, 0, 0);
    C.Add(Second, 0, 0);
    C.Arrange(Rc(0, 0, 10, 4));

    AssertTrue('the key was handled', C.HandleEvent(Key(kkEnter)));
    AssertEquals('first child saw it', 1, First.HandleCalls);
    AssertEquals('second child never did', 0, Second.HandleCalls);
  finally
    C.Free;
  end;
end;

procedure TTuiLayoutTest.TestMouseOutsideEveryChildIsNotHandled;
var
  C: TContainer;
  A: TProbeWidget;
begin
  C := TContainer.Create([Fixed(4)], [Fixed(2)]);
  try
    A := TProbeWidget.Create(4, 2, 'a');
    A.Handled := True;
    C.Add(A, 0, 0);
    C.Arrange(Rc(0, 0, 20, 10));
    { (15, 8) is inside the container but outside its only child. }
    AssertTrue('container bounds contain the point', C.HitTest(15, 8));
    AssertFalse('no child claimed it', C.HandleEvent(Mouse(15, 8)));
    { The child IS offered the event and declines it. Dispatch deliberately does
      not gate on HitTest: a drag that leaves a widget's rectangle must keep
      reaching it (the scrollbar drag relies on exactly that), so every leaf
      bounds-checks itself instead. }
    AssertEquals('the child was offered it and declined', 1, A.HandleCalls);
  finally
    C.Free;
  end;
end;

procedure TTuiLayoutTest.TestFixedTracksTakeExactSize;
var
  C: TContainer;
  A, B: TProbeWidget;
begin
  C := TContainer.Create([Fixed(5), Fixed(3)], [Fixed(2)]);
  try
    A := TProbeWidget.Create(1, 1, 'a');
    B := TProbeWidget.Create(1, 1, 'b');
    C.Add(A, 0, 0);
    C.Add(B, 1, 0);
    C.Arrange(Rc(0, 0, 20, 10));
    AssertEquals('col0 x', 0, A.Bounds.X);
    AssertEquals('col0 w', 5, A.Bounds.W);
    AssertEquals('col0 h', 2, A.Bounds.H);
    AssertEquals('col1 x', 5, B.Bounds.X);
    AssertEquals('col1 w', 3, B.Bounds.W);
  finally
    C.Free;
  end;
end;

procedure TTuiLayoutTest.TestFillTracksShareRemainderByWeight;
var
  C: TContainer;
  A, B: TProbeWidget;
begin
  C := TContainer.Create([Fixed(4), Fill(1), Fill(3)], [Fixed(2)]);
  try
    A := TProbeWidget.Create(1, 1, 'a');
    B := TProbeWidget.Create(1, 1, 'b');
    C.Add(A, 1, 0);
    C.Add(B, 2, 0);
    C.Arrange(Rc(0, 0, 20, 10));
    AssertEquals('fill1 x', 4, A.Bounds.X);
    AssertEquals('fill1 w (16 * 1/4)', 4, A.Bounds.W);
    AssertEquals('fill3 x', 8, B.Bounds.X);
    AssertEquals('fill3 w (16 * 3/4)', 12, B.Bounds.W);
  finally
    C.Free;
  end;
end;

procedure TTuiLayoutTest.TestAutoTrackMeasuresContent;
var
  C: TContainer;
  A: TProbeWidget;
begin
  C := TContainer.Create([Auto, Fixed(2)], [Auto]);
  try
    A := TProbeWidget.Create(7, 3, 'a');
    C.Add(A, 0, 0);
    C.Arrange(Rc(0, 0, 20, 10));
    AssertEquals('auto col width from measure', 7, A.Bounds.W);
    AssertEquals('auto row height from measure', 3, A.Bounds.H);
    AssertTrue('measure was consulted', A.MeasureCalls > 0);
  finally
    C.Free;
  end;
end;

procedure TTuiLayoutTest.TestGapsReduceAvailableSpace;
var
  C: TContainer;
  A, B: TProbeWidget;
begin
  C := TContainer.Create([Fill(1), Fill(1)], [Fixed(1)], 2, 0);
  try
    A := TProbeWidget.Create(1, 1, 'a');
    B := TProbeWidget.Create(1, 1, 'b');
    C.Add(A, 0, 0);
    C.Add(B, 1, 0);
    C.Arrange(Rc(0, 0, 12, 5));
    AssertEquals('first fill w (10 / 2)', 5, A.Bounds.W);
    AssertEquals('second fill x includes gap', 7, B.Bounds.X);
    AssertEquals('second fill w', 5, B.Bounds.W);
  finally
    C.Free;
  end;
end;

procedure TTuiLayoutTest.TestNestedContainerIsLaidOut;
var
  Outer, Inner: TContainer;
  P: TProbeWidget;
begin
  Outer := TContainer.Create([Fixed(5)], [Fixed(3)]);
  try
    Inner := TContainer.Create([Fixed(3)], [Fixed(1)]);
    P := TProbeWidget.Create(1, 1, 'p');
    Inner.Add(P, 0, 0);
    Outer.Add(Inner, 0, 0);
    Outer.Arrange(Rc(1, 1, 5, 3));
    AssertEquals('inner x', 1, Inner.Bounds.X);
    AssertEquals('inner y', 1, Inner.Bounds.Y);
    AssertEquals('inner w', 5, Inner.Bounds.W);
    AssertEquals('inner h', 3, Inner.Bounds.H);
    AssertEquals('grandchild x', 1, P.Bounds.X);
    AssertEquals('grandchild y', 1, P.Bounds.Y);
    AssertEquals('grandchild w', 3, P.Bounds.W);
    AssertEquals('grandchild h', 1, P.Bounds.H);
  finally
    Outer.Free;
  end;
end;

procedure TTuiLayoutTest.TestVerticalStackIsOneColumnGrid;
var
  C: TContainer;
  A, B: TProbeWidget;
begin
  C := TContainer.Create([Fixed(4)], [Fixed(1), Fixed(1)]);
  try
    A := TProbeWidget.Create(1, 1, 'a');
    B := TProbeWidget.Create(1, 1, 'b');
    C.Add(A);
    C.Add(B);
    C.Arrange(Rc(0, 0, 4, 2));
    AssertEquals('first stack row y', 0, A.Bounds.Y);
    AssertEquals('first stack row w', 4, A.Bounds.W);
    AssertEquals('second stack row y', 1, B.Bounds.Y);
    AssertEquals('second stack row h', 1, B.Bounds.H);
  finally
    C.Free;
  end;
end;

procedure TTuiLayoutTest.TestEmptyAndZeroSizedTracks;
var
  C, Empty: TContainer;
  A: TProbeWidget;
begin
  C := TContainer.Create([Fixed(-5), Fill(0)], [Fixed(-1)]);
  try
    A := TProbeWidget.Create(1, 1, 'a');
    C.Add(A, 1, 0);
    C.Arrange(Rc(0, 0, 10, 5));
    AssertEquals('negative fixed normalised to zero', 0, A.Bounds.X);
    AssertEquals('zero-weight fill takes all width', 10, A.Bounds.W);
    AssertEquals('negative fixed height normalised to zero', 0, A.Bounds.H);
  finally
    C.Free;
  end;

  Empty := TContainer.Create([], []);
  try
    Empty.Arrange(Rc(0, 0, 10, 5));
    AssertEquals('empty container has no children', 0, Empty.ChildCount);
  finally
    Empty.Free;
  end;
end;

procedure TTuiLayoutTest.TestOverflowingContentIsClipped;
var
  C: TContainer;
  P: TProbeWidget;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(20, 3);
  try
    S.Clear(DefaultAttr);
    C := TContainer.Create([Fixed(10)], [Fixed(1)]);
    try
      P := TProbeWidget.Create(1, 1, '#');
      C.Add(P, 0, 0);
      C.Arrange(Rc(1, 0, 4, 1));
      C.Render(S);
    finally
      C.Free;
    end;
    AssertEquals('inside container drawn', '####', S.RowText(0, 1, 4));
    AssertEquals('beyond container clipped', '', S.RowText(0, 5, 5));
    AssertEquals('left of container untouched', '', S.RowText(0, 0, 1));
  finally
    S.Free;
  end;
end;

initialization
  RegisterTest(TTuiLayoutTest);
end.
