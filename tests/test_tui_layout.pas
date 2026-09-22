unit test_tui_layout;
{ fpcunit tests for hildegard.helper.tui.widget: the widget protocol and the
  grid layout engine.

  A probe widget with a settable preferred size and a one-row marker render is
  used to observe assigned bounds and clipping. Everything runs against
  TSurfaceMemory, so no terminal is attached. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget;

type
  TProbeWidget = class(TWidget)
  private
    FPrefW, FPrefH: Integer;
    FMarker: UnicodeString;
  public
    MeasureCalls: Integer;
    constructor Create(APrefW, APrefH: Integer;
      const AMarker: UnicodeString = '#');
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
  end;

  TTuiLayoutTest = class(TTestCase)
  private
    function Rc(AX, AY, AW, AH: Integer): TRect;
  published
    procedure TestFixedTracksTakeExactSize;
    procedure TestFillTracksShareRemainderByWeight;
    procedure TestAutoTrackMeasuresContent;
    procedure TestGapsReduceAvailableSpace;
    procedure TestNestedContainerIsLaidOut;
    procedure TestVerticalStackIsOneColumnGrid;
    procedure TestEmptyAndZeroSizedTracks;
    procedure TestOverflowingContentIsClipped;
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
