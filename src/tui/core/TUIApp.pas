unit TUIApp;
{ Planes, the frame clock, and the application loop for the TUI toolkit.

  TTuiApp owns a stack of planes and composes one frame per Tick: advance the
  whole tree to the frame time, clear, render the non-modal base plane(s), dim
  the rendered background once per dimmed modal, render the modal plane(s) on
  top, then flush once. The base root is arranged to the surface; modal roots
  are arranged by the caller and rendered clipped to their own bounds.

  Because the frame is rebuilt every Tick, dimming never accumulates and the
  base stays visible underneath a modal.

  Run waits on input to the next frame while anything animates or the owner is
  Busy (a worker streaming into a queue), and on a short idle timeout when idle -
  there is no forced refresh rate and no busy poll. The clock ticks at the frame
  cadence, but the screen repaints only when a widget reports a change (Advance
  returns True) or the layout is dirty. Step remains the event-only iteration the
  demos and tests use. }

{$mode delphi}{$H+}

interface

uses
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUIClock;

const
  { The idle wake-up, not a refresh rate: input and signals wake the tty select
    immediately, so this only bounds how long a resize goes unnoticed and how
    often the idle hook runs. It is also the ceiling on a registered animation's
    interval. }
  IdleWaitMs = 250;

  { The most buffered input events one loop iteration will dispatch before it
    yields to the frame body. A keystroke must never queue behind per-frame work,
    but an unbounded drain would let a paste starve rendering. }
  MaxInputDrainPerLoop = 64;

type
  { Returns True to stop the run loop (a signal, a quit flag). }
  TStopCheck = function: Boolean;
  { Called once per Run iteration, before the frame decision (drain queues,
    update external state). }
  TLoopHook = procedure of object;
  { A post-dispatch input hook: the host's chance to consume an event the widget
    tree did not (e.g. a hit-test on chrome the tree does not own). Return True
    to consume the event. }
  TInputHook = function(const E: TInputEvent): Boolean of object;

  { A plane is a widget tree drawn as one layer. Modal planes trap input. }
  TPlane = class
  private
    FRoot: TWidget;
    FIsModal: Boolean;
    FDimBackground: Boolean;
  public
    constructor Create(ARoot: TWidget; AIsModal: Boolean;
      ADimBackground: Boolean = False);
    destructor Destroy; override;
    property Root: TWidget read FRoot;
    property IsModal: Boolean read FIsModal;
    property DimBackground: Boolean read FDimBackground;
  end;

  TTuiApp = class
  private
    FSurface: ISurface;
    FInput: IInputSource;
    FPlanes: array of TPlane;
    FStop: Boolean;
    FLayoutDirty: Boolean;
    FTickMs: Integer;
    FNowMs: Int64;
    FLastTickMs: Int64;
    FBusy: Boolean;
    FTerminalFocused: Boolean;
    FNeedsRepaint: Boolean;
    FScreenBg: Byte;
    FInputHook: TInputHook;
    { Copy the selection when the mouse button comes up. On by default: the
      gesture that makes a selection is the gesture that delivers it, so there
      is no keybinding to discover and none to be unreachable. }
    FCopyOnRelease: Boolean;
    { Loop-rate diagnostic, enabled by HILDI_TUI_DIAG. Reports why the loop
      chose its timeout, so an idle CPU problem can be attributed instead of
      guessed at. Off (and all-zero) unless the environment asks for it. }
    FDiag: Boolean;
    FDiagLog: TextFile;
    FDiagAt: Int64;
    FDiagIters: Integer;
    FDiagBusy: Integer;
    FDiagAnim: Integer;
    procedure ArrangeBase;
    procedure ArrangePlanes;
    procedure RenderFrame;
    procedure DispatchEvent(const E: TInputEvent);
    procedure SetTerminalFocused(AValue: Boolean);
    procedure Present;
    function AdvanceTree(const ANowMs: Int64): Boolean;
    function FrameDue: Boolean;
    function GetAnimating: Boolean;
  public
    constructor Create(const ASurface: ISurface; const AInput: IInputSource;
      ARoot: TWidget; ATickMs: Integer = DefaultTickMs);
    destructor Destroy; override;

    { Mark layout dirty: the next Step re-arranges the base root. Call after a
      widget's content changes (for example appended text). }
    procedure Invalidate;

    { A hook the host sets to post-process each input event after the tree has
      seen it, for hit-tests on chrome the tree does not own (e.g. the messages
      panel's left-border scrollbar). Return True to consume the event. }
    property InputHook: TInputHook read FInputHook write FInputHook;

    procedure PushPlane(const APlane: TPlane);
    procedure PopPlane;
    function ModalActive: Boolean;
    { Copy whatever the active tree has selected onto the terminal clipboard.
      Walks the modal plane when one is up, else the base - the same plane that
      receives input, so the key acts on what the operator is looking at.
      Returns False when nothing was selected. }
    function CopySelection: Boolean;

    { Copy on mouse release. Default True; set False to require an explicit
      key, or for a host that wants its own gesture. }
    property CopyOnRelease: Boolean read FCopyOnRelease write FCopyOnRelease;
    procedure Stop;

    { One iteration: process at most one input event (or resize), lay out on
      change, render the frame, flush. Returns False once stopped. Does not
      advance time; callers that animate use Tick or Run. }
    function Step: Boolean;

    { Advance a frame to an explicit time: advance the whole tree and repaint
      only when a widget reports a change (or the layout is dirty). Deterministic;
      the test seam. }
    procedure Tick(const ANowMs: Int64);

    { Milliseconds until the next frame (0..FrameIntervalMs), or -1 when nothing
      is animating and the app is not Busy (the caller should wait indefinitely).
      Exposed for tests. }
    function NextFrameDelayMs: Integer;

    { The frame interval in ms: the fastest registered animation, the frame
      cadence while Busy, or the idle wait when nothing demands a frame. Exposed
      for tests. }
    function FrameIntervalMs: Integer;

    { Wait on input to the next frame (or a long idle timeout when idle),
      advance the tree on each frame, and render once per frame. ACheckStop,
      when set, ends the loop; AOnLoop runs each iteration (drain a queue). }
    procedure Run(ACheckStop: TStopCheck = nil; AOnLoop: TLoopHook = nil);

    property TickMs: Integer read FTickMs write FTickMs;
    property NowMs: Int64 read FNowMs;
    property Animating: Boolean read GetAnimating;
    { True while the terminal has OS focus (DECSET 1004). Nothing animates while
      unfocused, so a backgrounded terminal does no work. A terminal without 1004
      never sends a focus event and stays True. }
    property TerminalFocused: Boolean read FTerminalFocused;
    { True while the owner has out-of-band work pending (for example a worker
      streaming into a queue). Keeps the frame cadence instead of the long idle
      wait, without a busy poll. }
    property Busy: Boolean read FBusy write FBusy;
    { The palette index painted for cells with sfScreenBg (the app background).
      Set it from the theme; 0 is black. }
    property ScreenBg: Byte read FScreenBg write FScreenBg;
  end;

implementation

uses
  SysUtils;

function Rect4(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

{ TPlane }

constructor TPlane.Create(ARoot: TWidget; AIsModal: Boolean;
  ADimBackground: Boolean);
begin
  inherited Create;
  FRoot := ARoot;
  FIsModal := AIsModal;
  FDimBackground := ADimBackground;
end;

destructor TPlane.Destroy;
begin
  FRoot.Free;
  inherited Destroy;
end;

{ TTuiApp }

constructor TTuiApp.Create(const ASurface: ISurface; const AInput: IInputSource;
  ARoot: TWidget; ATickMs: Integer);
begin
  inherited Create;
  FSurface := ASurface;
  FInput := AInput;
  FStop := False;
  { Start needing a paint so the first Present/Tick draws even if nothing reports
    a change; do not mark the layout dirty, or the first Step would re-arrange. }
  FLayoutDirty := False;
  FNeedsRepaint := True;
  FCopyOnRelease := True;
  FScreenBg := 0;
  if ATickMs < 1 then
    ATickMs := DefaultTickMs;
  FTickMs := ATickMs;
  FNowMs := 0;
  FLastTickMs := 0;
  FBusy := False;
  FTerminalFocused := True;
  FDiag := GetEnvironmentVariable('HILDI_TUI_DIAG') <> '';
  if FDiag then
  begin
    AssignFile(FDiagLog, GetEnvironmentVariable('HILDI_TUI_DIAG'));
    Rewrite(FDiagLog);
  end;
  FDiagAt := 0;
  FDiagIters := 0;
  FDiagBusy := 0;
  FDiagAnim := 0;
  SetLength(FPlanes, 1);
  FPlanes[0] := TPlane.Create(ARoot, False);
  ArrangeBase;
end;

procedure TTuiApp.Invalidate;
begin
  FLayoutDirty := True;
end;

destructor TTuiApp.Destroy;
var
  I: Integer;
begin
  if FDiag then
    CloseFile(FDiagLog);
  for I := 0 to High(FPlanes) do
    FPlanes[I].Free;
  inherited Destroy;
end;

procedure TTuiApp.ArrangeBase;
begin
  if (Length(FPlanes) > 0) and (FPlanes[0].Root <> nil) then
    FPlanes[0].Root.Arrange(Rect4(0, 0, FSurface.Width, FSurface.Height));
end;

procedure TTuiApp.ArrangePlanes;
var
  I: Integer;
  R: TRect;
begin
  R := Rect4(0, 0, FSurface.Width, FSurface.Height);
  for I := 0 to High(FPlanes) do
    if FPlanes[I].Root <> nil then
      FPlanes[I].Root.Arrange(R);
end;

procedure TTuiApp.PushPlane(const APlane: TPlane);
begin
  if APlane = nil then
    Exit;
  if APlane.Root = nil then
  begin
    { A rootless plane is rejected; the app owns the planes it accepts, so the
      rejected one is freed here. }
    APlane.Free;
    Exit;
  end;
  SetLength(FPlanes, Length(FPlanes) + 1);
  FPlanes[High(FPlanes)] := APlane;
  Invalidate;
end;

procedure TTuiApp.PopPlane;
begin
  if Length(FPlanes) > 1 then
  begin
    FPlanes[High(FPlanes)].Free;
    SetLength(FPlanes, Length(FPlanes) - 1);
    Invalidate;
  end;
end;

function TTuiApp.CopySelection: Boolean;
begin
  Result := False;
  if Length(FPlanes) = 0 then
    Exit;
  if ModalActive then
    Result := FPlanes[High(FPlanes)].Root.CopySelection(FSurface)
  else
    Result := FPlanes[0].Root.CopySelection(FSurface);
end;

function TTuiApp.ModalActive: Boolean;
var
  I: Integer;
begin
  for I := 1 to High(FPlanes) do
    if FPlanes[I].IsModal then
      Exit(True);
  Result := False;
end;

procedure TTuiApp.Stop;
begin
  FStop := True;
end;

procedure TTuiApp.RenderFrame;
var
  I: Integer;
begin
  FSurface.SetScreenBg(FScreenBg);
  FSurface.Clear(DefaultAttr);
  for I := 0 to High(FPlanes) do
    if not FPlanes[I].IsModal then
      FPlanes[I].Root.Render(FSurface);
  for I := 0 to High(FPlanes) do
    if FPlanes[I].IsModal and FPlanes[I].DimBackground then
      FSurface.DimRect(Rect4(0, 0, FSurface.Width, FSurface.Height));
  for I := 0 to High(FPlanes) do
    if FPlanes[I].IsModal then
      FPlanes[I].Root.Render(FSurface);
  FSurface.Flush;
end;

function TTuiApp.Step: Boolean;
var
  E: TInputEvent;
begin
  if FStop then
    Exit(False);
  if FInput.Poll(E) then
    DispatchEvent(E);
  Present;
  Result := not FStop;
end;

procedure TTuiApp.DispatchEvent(const E: TInputEvent);
var
  Handled: Boolean;
begin
  { The host's hook runs first for a mouse press/drag: it hit-tests chrome the
    tree does not own (the messages panel's left-border scrollbar) and consumes
    the event there. }
  if (E.Kind = ikMouse) and Assigned(FInputHook) and FInputHook(E) then
    Exit;
  case E.Kind of
    ikResize:
      begin
        { Adopt the settled size before laying out, so the layout and the surface
          always agree; the surface no longer polls the terminal itself. }
        FSurface.Resize(E.NewSize.W, E.NewSize.H);
        ArrangePlanes;
        FLayoutDirty := False;
      end;
    { A paste is text input, so it is routed like a key: to the modal plane
      while one is up (which ignores it), otherwise to the base. Without this
      arm a decoded paste was silently dropped. }
    ikKey, ikPaste:
      if ModalActive then
      begin
        Handled := FPlanes[High(FPlanes)].Root.HandleEvent(E);
        if (not Handled) and (E.Kind = ikKey) and (E.Key.Kind = kkEscape) then
          PopPlane;
      end
      else
        FPlanes[0].Root.HandleEvent(E);
    ikMouse:
      begin
        if ModalActive then
          FPlanes[High(FPlanes)].Root.HandleEvent(E)
        else
          FPlanes[0].Root.HandleEvent(E);
        { AFTER dispatch, so the release has already ended the drag and the
          selection is final. CopySelection is a no-op when nothing usable is
          selected, which is what makes a plain click harmless: an empty OSC 52
          write would CLEAR the operator's clipboard. }
        if FCopyOnRelease and (E.Mouse.Action = maRelease) then
          CopySelection;
      end;
    ikFocus:
      SetTerminalFocused(E.Focused);
  else
    ;
  end;
end;

procedure TTuiApp.Present;
begin
  if FLayoutDirty then
  begin
    ArrangeBase;
    FLayoutDirty := False;
  end;
  RenderFrame;
  FNeedsRepaint := False;
end;

function TTuiApp.FrameDue: Boolean;
begin
  Result := (FLastTickMs = 0) or (FNowMs - FLastTickMs >= FrameIntervalMs);
end;

function TTuiApp.GetAnimating: Boolean;
begin
  { Demand is registered, not discovered: a widget registers its animation and
    the interval it needs, so the app does not walk the tree every frame. Nothing
    animates while the terminal is unfocused; a busy owner (a turn streaming)
    keeps the frame cadence regardless. }
  Result := FTerminalFocused and
    (FBusy or (AnimationClock.MinIntervalMs > 0));
end;

procedure TTuiApp.SetTerminalFocused(AValue: Boolean);
begin
  if AValue = FTerminalFocused then
    Exit;
  FTerminalFocused := AValue;
  { Repaint once, so a caret that should be steady renders solid immediately. }
  FNeedsRepaint := True;
end;

function TTuiApp.FrameIntervalMs: Integer;
var
  Registered: Integer;
begin
  { A turn in flight streams: keep the fast cadence. Otherwise run as slowly as
    the fastest registered animation allows, or idle. }
  if FBusy then
    Exit(FTickMs);
  Registered := AnimationClock.MinIntervalMs;
  if Registered <= 0 then
    Exit(IdleWaitMs);
  if Registered < 1 then
    Registered := 1;
  if Registered > IdleWaitMs then
    Registered := IdleWaitMs;
  Result := Registered;
end;

function TTuiApp.AdvanceTree(const ANowMs: Int64): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(FPlanes) do
    if (FPlanes[I].Root <> nil) and FPlanes[I].Root.Advance(ANowMs) then
      Result := True;
end;

procedure TTuiApp.Tick(const ANowMs: Int64);
begin
  if FStop then
    Exit;
  FNowMs := ANowMs;
  FLastTickMs := ANowMs;
  { Advance every frame, but repaint only when a widget reports a change (or the
    layout is dirty): the clock ticks at 100 Hz, the screen does not. }
  if AdvanceTree(ANowMs) or FLayoutDirty or FNeedsRepaint then
    Present;
end;

function TTuiApp.NextFrameDelayMs: Integer;
var
  Interval: Integer;
begin
  if not (Animating or FBusy) then
    Exit(-1);
  if FLastTickMs = 0 then
    Exit(0);
  Interval := FrameIntervalMs;
  Result := Interval - Integer(FNowMs - FLastTickMs);
  if Result < 0 then
    Result := 0;
  if Result > Interval then
    Result := Interval;
end;

procedure TTuiApp.Run(ACheckStop: TStopCheck; AOnLoop: TLoopHook);
var
  E: TInputEvent;
  Timeout: Integer;
  Handled: Boolean;
  Drained: Integer;
begin
  { Draw the first frame immediately; an idle loop would otherwise wait out the
    idle timeout before anything appears. }
  Present;
  while not FStop do
  begin
    if Assigned(ACheckStop) and ACheckStop() then
      Exit;
    FNowMs := MonotonicMs;
    Timeout := NextFrameDelayMs;
    if Timeout < 0 then
      Timeout := IdleWaitMs;
    { Attribute the loop rate. One line a second while HILDI_TUI_DIAG is set:
      how many iterations, how many were busy, how many had an animation
      registered, and the timeout the loop actually used. That distinguishes a
      stuck busy flag from a stray registration without guessing. }
    if FDiag then
    begin
      Inc(FDiagIters);
      if FBusy then Inc(FDiagBusy);
      if Animating then Inc(FDiagAnim);
      if (FDiagAt <> 0) and (FNowMs - FDiagAt >= 1000) then
      begin
        { A real file, not StdErr: the video unit owns the console handles, so
          a stderr write from inside the loop can vanish. FDiag is true only
          when the file was opened, so it is the guard. }
        if FDiag then
        begin
          WriteLn(FDiagLog, Format('tui-diag: %d iters/s  busy=%d anim=%d  ' +
            'MinIntervalMs=%d focused=%s timeout=%d',
            [FDiagIters, FDiagBusy, FDiagAnim,
             AnimationClock.MinIntervalMs, BoolToStr(FTerminalFocused, True),
             Timeout]));
          Flush(FDiagLog);
        end;
        FDiagIters := 0; FDiagBusy := 0; FDiagAnim := 0; FDiagAt := FNowMs;
      end
      else if FDiagAt = 0 then
        FDiagAt := FNowMs;
    end;
    Handled := FInput.Wait(Timeout, E);
    if Handled then
      DispatchEvent(E);
    { Input priority: a keystroke must never queue behind per-frame work. One
      event per iteration meant a full Tick (DrainQueue, FlushToolOutput,
      TrimHistory) ran between consecutive keys, so typing a burst or reaching
      for esc-esc to cancel a long run competed with the frame body. Drain
      everything already buffered before any frame work, bounded so a paste
      cannot starve rendering.
      Poll is safe here because it shares the decoder with Wait: it calls
      ReadAvailable and then FDecoder.Next on the same instance, so a partial
      escape sequence started by Wait resumes rather than being split. }
    Drained := 0;
    while (Drained < MaxInputDrainPerLoop) and FInput.Poll(E) do
    begin
      DispatchEvent(E);
      Inc(Drained);
    end;
    if Assigned(AOnLoop) then
      AOnLoop();
    FNowMs := MonotonicMs;
    if Animating or FBusy then
    begin
      if FrameDue then
        Tick(FNowMs)
      else if Handled then
        Present;
    end
    else if Handled or FLayoutDirty or FNeedsRepaint then
      Present;
  end;
end;

end.
