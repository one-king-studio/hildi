unit test_tui_animation;
{ fpcunit tests for TUI animation: the monotonic clock, the Advance/Animating
  widget hook, the app frame loop (Tick/NextFrameDelayMs), and the first
  time-based widgets (spinner, progress). Headless, against TSurfaceMemory. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.theme, hildegard.helper.tui.panel,
  hildegard.helper.tui.clock, hildegard.helper.tui.app,
  hildegard.helper.tui.spinner, hildegard.helper.tui.progress;

type
  { A widget that records Advance calls and animates on demand. }
  TAnimProbe = class(TWidget)
  public
    AdvanceCount: Integer;
    LastNow: Int64;
    IsAnimating: Boolean;
    AdvanceResult: Boolean;
    Ch: UnicodeString;
    constructor Create;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
  end;

  TClockTest = class(TTestCase)
  published
    procedure TestMonotonicNonDecreasing;
  end;

  TAdvanceTest = class(TTestCase)
  published
    procedure TestContainerForwardsAdvance;
    procedure TestContainerAnimatingIsOr;
    procedure TestPanelForwardsAdvance;
  end;

  TAppTickTest = class(TTestCase)
  published
    procedure TestTickAdvancesTree;
    procedure TestUnchangedFrameEmitsNothing;
    procedure TestChangedFrameEmitsOnlyChangedCells;
    procedure TestNextFrameDelayIdleIsMinusOne;
    procedure TestNextFrameDelayAnimatingIsWithinTick;
    procedure TestNextFrameDelayBusyKeepsCadence;
  end;

  TSpinnerTest = class(TTestCase)
  published
    procedure TestFrameAdvancesWithTime;
    procedure TestSameOriginInPhase;
    procedure TestAnimatingAlways;
    procedure TestMeasureIsWidestFrame;
    procedure TestRenderPutsGlyph;
  end;

  TProgressTest = class(TTestCase)
  published
    procedure TestDeterminateAtZeroHalfFull;
    procedure TestValueClamps;
    procedure TestIndeterminateBouncesInside;
    procedure TestAnimatingFollowsIndeterminate;
  end;

  TAnimationIntegrationTest = class(TTestCase)
  published
    procedure TestPanelCompositesAndDiffsOneFrame;
  end;

implementation

var
  { Frame sets for the tests (UnicodeString, so no literal-conversion surprises). }
  TriFrames: array[0..2] of UnicodeString;
  WideFrames: array[0..2] of UnicodeString;
  OneFrame: array[0..0] of UnicodeString;

function MakeRect(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

{ TAnimProbe }

constructor TAnimProbe.Create;
begin
  inherited Create;
  Ch := 'A';
end;

function TAnimProbe.Advance(const ANowMs: Int64): Boolean;
begin
  Inc(AdvanceCount);
  LastNow := ANowMs;
  Result := AdvanceResult;
end;

function TAnimProbe.Animating: Boolean;
begin
  Result := IsAnimating;
end;

function TAnimProbe.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := 1;
  Result.H := 1;
end;

procedure TAnimProbe.Render(const S: ISurface);
var
  C: TCell;
begin
  C := Default(TCell);
  C.Ch := Ch;
  C.Attr := DefaultAttr;
  S.Put(FBounds.X, FBounds.Y, C);
end;

{ TClockTest }

procedure TClockTest.TestMonotonicNonDecreasing;
var
  A, B: Int64;
begin
  A := MonotonicMs;
  B := MonotonicMs;
  AssertTrue('the clock never runs backwards', B >= A);
end;

{ TAdvanceTest }

procedure TAdvanceTest.TestContainerForwardsAdvance;
var
  C: TContainer;
  P1, P2: TAnimProbe;
begin
  C := TContainer.Create([Fill(1)], [Auto, Auto]);
  P1 := TAnimProbe.Create;
  P2 := TAnimProbe.Create;
  try
    C.Add(P1, 0, 0);
    C.Add(P2, 0, 1);
    C.Advance(1234);
    AssertEquals('first child advanced once', 1, P1.AdvanceCount);
    AssertEquals('first child saw the time', 1234, P1.LastNow);
    AssertEquals('second child advanced once', 1, P2.AdvanceCount);
  finally
    C.Free;
  end;
end;

procedure TAdvanceTest.TestContainerAnimatingIsOr;
var
  C: TContainer;
  P1, P2: TAnimProbe;
begin
  C := TContainer.Create([Fill(1)], [Auto, Auto]);
  P1 := TAnimProbe.Create;
  P2 := TAnimProbe.Create;
  try
    C.Add(P1, 0, 0);
    C.Add(P2, 0, 1);
    AssertFalse('nothing animates', C.Animating);
    P2.IsAnimating := True;
    AssertTrue('one child animates', C.Animating);
  finally
    C.Free;
  end;
end;

procedure TAdvanceTest.TestPanelForwardsAdvance;
var
  P: TAnimProbe;
  Panel: TPanel;
begin
  P := TAnimProbe.Create;
  Panel := TPanel.Create(P, DarkTheme, DefaultBoxStyle);
  try
    Panel.Advance(77);
    AssertEquals('panel forwards Advance', 1, P.AdvanceCount);
    P.IsAnimating := True;
    AssertTrue('panel forwards Animating', Panel.Animating);
  finally
    Panel.Free;
  end;
end;

{ TAppTickTest }

procedure TAppTickTest.TestTickAdvancesTree;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  P: TAnimProbe;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(4, 1);
  Src := TInputSourceScripted.Create;
  P := TAnimProbe.Create;
  App := TTuiApp.Create(S, Src, P);
  try
    App.Tick(500);
    AssertEquals('tree advanced once', 1, P.AdvanceCount);
    AssertEquals('tree saw the frame time', 500, P.LastNow);
    AssertEquals('app remembers the time', 500, App.NowMs);
  finally
    App.Free;
  end;
end;

procedure TAppTickTest.TestUnchangedFrameEmitsNothing;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  P: TAnimProbe;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(4, 1);
  Src := TInputSourceScripted.Create;
  P := TAnimProbe.Create;
  App := TTuiApp.Create(S, Src, P);
  try
    App.Tick(0);          { first frame (forced full repaint) }
    App.Tick(10);
    { Nothing changed and nothing animates, so the second tick does not even
      flush: the screen is not bound to the clock cadence. }
    AssertEquals('an unchanged frame is not repainted', 1, S.FlushCount);
  finally
    App.Free;
  end;
end;

procedure TAppTickTest.TestChangedFrameEmitsOnlyChangedCells;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  P: TAnimProbe;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(4, 1);
  Src := TInputSourceScripted.Create;
  P := TAnimProbe.Create;
  App := TTuiApp.Create(S, Src, P);
  try
    App.Tick(0);
    P.AdvanceResult := True;   { the widget reports a change }
    P.Ch := 'B';
    App.Tick(10);
    AssertEquals('only the changed cell is re-emitted', 1,
      S.LastFrameChangedCells);
  finally
    App.Free;
  end;
end;

procedure TAppTickTest.TestNextFrameDelayIdleIsMinusOne;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  P: TAnimProbe;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(4, 1);
  Src := TInputSourceScripted.Create;
  P := TAnimProbe.Create;
  App := TTuiApp.Create(S, Src, P);
  try
    App.Tick(1000);
    AssertEquals('idle waits forever', -1, App.NextFrameDelayMs);
  finally
    App.Free;
  end;
end;

procedure TAppTickTest.TestNextFrameDelayAnimatingIsWithinTick;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  P: TAnimProbe;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(4, 1);
  Src := TInputSourceScripted.Create;
  P := TAnimProbe.Create;
  P.IsAnimating := True;
  { Demand is registered, not discovered: register the probe's animation. }
  P.SetAnimation(DefaultTickMs);
  App := TTuiApp.Create(S, Src, P);
  try
    AssertEquals('due immediately before the first tick', 0,
      App.NextFrameDelayMs);
    App.Tick(1000);
    AssertEquals('a full tick after a frame', DefaultTickMs,
      App.NextFrameDelayMs);
  finally
    P.ClearAnimation;
    App.Free;
  end;
end;

procedure TAppTickTest.TestNextFrameDelayBusyKeepsCadence;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  P: TAnimProbe;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(4, 1);
  Src := TInputSourceScripted.Create;
  P := TAnimProbe.Create;
  App := TTuiApp.Create(S, Src, P);
  try
    { Nothing animates, but out-of-band work (a streaming worker) keeps the
      frame cadence instead of the long idle wait. }
    App.Busy := True;
    AssertEquals('due immediately before the first tick', 0,
      App.NextFrameDelayMs);
    App.Tick(1000);
    AssertEquals('busy keeps the frame cadence', DefaultTickMs,
      App.NextFrameDelayMs);
    App.Busy := False;
    AssertEquals('idle again once not busy', -1, App.NextFrameDelayMs);
  finally
    App.Free;
  end;
end;

{ TSpinnerTest }

procedure TSpinnerTest.TestFrameAdvancesWithTime;
var
  Sp: TSpinner;
begin
  Sp := TSpinner.Create(TriFrames, 100);
  try
    Sp.Advance(0);
    AssertEquals('frame 0', 0, Sp.Index);
    Sp.Advance(100);
    AssertEquals('frame 1', 1, Sp.Index);
    Sp.Advance(200);
    AssertEquals('frame 2', 2, Sp.Index);
    Sp.Advance(300);
    AssertEquals('wraps to frame 0', 0, Sp.Index);
  finally
    Sp.Free;
  end;
end;

procedure TSpinnerTest.TestSameOriginInPhase;
var
  A, B: TSpinner;
begin
  A := TSpinner.Create(TriFrames, 100);
  B := TSpinner.Create(TriFrames, 100);
  try
    A.Advance(1000);
    B.Advance(1000);
    A.Advance(1100);
    B.Advance(1100);
    AssertEquals('spinners started together stay in phase', A.Index, B.Index);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TSpinnerTest.TestAnimatingAlways;
var
  Sp: TSpinner;
begin
  Sp := TSpinner.Create(TriFrames, 100);
  try
    AssertTrue('a spinner is always animating', Sp.Animating);
  finally
    Sp.Free;
  end;
end;

procedure TSpinnerTest.TestMeasureIsWidestFrame;
var
  Sp: TSpinner;
  Sz: TSize;
begin
  Sp := TSpinner.Create(WideFrames, 100);
  try
    Sz := Sp.Measure(Default(TSize));
    AssertEquals('width is the widest frame', 3, Sz.W);
    AssertEquals('height is one row', 1, Sz.H);
  finally
    Sp.Free;
  end;
end;

procedure TSpinnerTest.TestRenderPutsGlyph;
var
  Sp: TSpinner;
  S: TSurfaceMemory;
begin
  Sp := TSpinner.Create(OneFrame, 100, DarkTheme.Accent);
  S := TSurfaceMemory.Create(6, 2);
  try
    Sp.Advance(0);
    Sp.Arrange(MakeRect(2, 1, 5, 1));
    Sp.Render(S);
    AssertEquals('glyph drawn at the bounds', 'x', S.CellAt(2, 1).Ch);
    AssertEquals('glyph uses the attr', DarkTheme.Accent.Fg,
      S.CellAt(2, 1).Attr.Fg);
  finally
    Sp.Free;
    S.Free;
  end;
end;

{ TProgressTest }

procedure TProgressTest.TestDeterminateAtZeroHalfFull;
var
  Pr: TProgress;
  S: TSurfaceMemory;
begin
  Pr := TProgress.Create(10);
  S := TSurfaceMemory.Create(10, 1);
  try
    Pr.Arrange(MakeRect(0, 0, 10, 1));
    Pr.Value := 0;
    Pr.Render(S);
    AssertEquals('0% is blank', '          ', S.RowText(0, 0, 10));
    Pr.Value := 50;
    Pr.Render(S);
    AssertEquals('50% is half full', '█████     ', S.RowText(0, 0, 10));
    Pr.Value := 100;
    Pr.Render(S);
    AssertEquals('100% is full', '██████████', S.RowText(0, 0, 10));
  finally
    Pr.Free;
    S.Free;
  end;
end;

procedure TProgressTest.TestValueClamps;
var
  Pr: TProgress;
begin
  Pr := TProgress.Create(10);
  try
    Pr.Value := 150;
    AssertEquals('clamps to max', 100, Pr.Value);
    Pr.Value := -5;
    AssertEquals('clamps to zero', 0, Pr.Value);
  finally
    Pr.Free;
  end;
end;

procedure TProgressTest.TestIndeterminateBouncesInside;
var
  Pr: TProgress;
  I, P, Lo, Hi: Integer;
begin
  Pr := TProgress.Create(9);
  try
    Pr.Indeterminate := True;
    Lo := MaxInt;
    Hi := -1;
    for I := 0 to 20 do
    begin
      Pr.Advance(Int64(I) * 90);
      P := Pr.Position;
      if P < Lo then
        Lo := P;
      if P > Hi then
        Hi := P;
    end;
    AssertEquals('bounces off the left inner cell', 1, Lo);
    AssertEquals('bounces off the right inner cell', 7, Hi);
  finally
    Pr.Free;
  end;
end;

procedure TProgressTest.TestAnimatingFollowsIndeterminate;
var
  Pr: TProgress;
begin
  Pr := TProgress.Create(10);
  try
    AssertFalse('determinate progress does not animate', Pr.Animating);
    Pr.Indeterminate := True;
    AssertTrue('indeterminate progress animates', Pr.Animating);
  finally
    Pr.Free;
  end;
end;

{ TAnimationIntegrationTest }

procedure TAnimationIntegrationTest.TestPanelCompositesAndDiffsOneFrame;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  Inner: TContainer;
  Sp: TSpinner;
  Pr: TProgress;
  Panel: TPanel;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(12, 8);
  Src := TInputSourceScripted.Create;
  Inner := TContainer.Create([Fill(1)], [Auto, Auto]);
  Sp := TSpinner.Create(TriFrames, 100);
  Pr := TProgress.Create(8);
  Pr.Indeterminate := True;
  Inner.Add(Sp, 0, 0);
  Inner.Add(Pr, 0, 1);
  Panel := TPanel.Create(Inner, DarkTheme, DefaultBoxStyle);
  App := TTuiApp.Create(S, Src, Panel);
  try
    App.Tick(0);
    AssertEquals('one flush per frame', 1, S.FlushCount);
    AssertEquals('spinner starts at frame 0', 0, Sp.Index);
    App.Tick(100);
    AssertEquals('still one flush per frame', 2, S.FlushCount);
    AssertEquals('spinner advanced one frame', 1, Sp.Index);
    AssertTrue('the frame diffed to something', S.LastFrameChangedCells > 0);
    AssertTrue('only the animated cells changed',
      S.LastFrameChangedCells <= 4);
  finally
    App.Free;
  end;
end;

initialization
  TriFrames[0] := 'a';
  TriFrames[1] := 'b';
  TriFrames[2] := 'c';
  WideFrames[0] := 'ab';
  WideFrames[1] := 'c';
  WideFrames[2] := 'def';
  OneFrame[0] := 'x';
  RegisterTest(TClockTest);
  RegisterTest(TAdvanceTest);
  RegisterTest(TAppTickTest);
  RegisterTest(TSpinnerTest);
  RegisterTest(TProgressTest);
  RegisterTest(TAnimationIntegrationTest);

end.
