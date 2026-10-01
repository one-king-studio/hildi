unit hildegard.helper.tui.app;
{ Planes, the frame clock, and the application loop for the TUI toolkit.

  TTuiApp owns a stack of planes and composes one frame per Tick: advance the
  whole tree to the frame time, clear, render the non-modal base plane(s), dim
  the rendered background once per dimmed modal, render the modal plane(s) on
  top, then flush once. The base root is arranged to the surface; modal roots
  are arranged by the caller and rendered clipped to their own bounds.

  Because the frame is rebuilt every Tick, dimming never accumulates and the
  base stays visible underneath a modal.

  Run waits on input to the next frame while anything animates, and on a long
  idle timeout when nothing does - there is no forced refresh rate. Step remains
  the event-only iteration the demos and tests use. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.clock;

type
  { Returns True to stop the run loop (a signal, a quit flag). }
  TStopCheck = function: Boolean of object;

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
    procedure ArrangeBase;
    procedure ArrangePlanes;
    procedure RenderFrame;
    procedure DispatchEvent(const E: TInputEvent);
    procedure Present;
    function FrameDue: Boolean;
    function GetAnimating: Boolean;
  public
    constructor Create(const ASurface: ISurface; const AInput: IInputSource;
      ARoot: TWidget; ATickMs: Integer = DefaultTickMs);
    destructor Destroy; override;

    { Mark layout dirty: the next Step re-arranges the base root. Call after a
      widget's content changes (for example appended text). }
    procedure Invalidate;

    procedure PushPlane(const APlane: TPlane);
    procedure PopPlane;
    function ModalActive: Boolean;
    procedure Stop;

    { One iteration: process at most one input event (or resize), lay out on
      change, render the frame, flush. Returns False once stopped. Does not
      advance time; callers that animate use Tick or Run. }
    function Step: Boolean;

    { Advance a frame to an explicit time: advance the whole tree, re-arrange if
      dirty, render and flush once. Deterministic; the test seam. }
    procedure Tick(const ANowMs: Int64);

    { Milliseconds until the next frame (0..TickMs), or -1 when nothing is
      animating (the caller should wait indefinitely). Exposed for tests. }
    function NextFrameDelayMs: Integer;

    { Wait on input to the next frame (or a long idle timeout when nothing
      animates), advance the tree on each frame, and render once per frame.
      ACheckStop, when set, ends the loop (the caller restores the terminal). }
    procedure Run(ACheckStop: TStopCheck = nil);

    property TickMs: Integer read FTickMs write FTickMs;
    property NowMs: Int64 read FNowMs;
    property Animating: Boolean read GetAnimating;
  end;

implementation

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
  FLayoutDirty := False;
  if ATickMs < 1 then
    ATickMs := DefaultTickMs;
  FTickMs := ATickMs;
  FNowMs := 0;
  FLastTickMs := 0;
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
  case E.Kind of
    ikResize:
      begin
        { Re-arrange every plane (base and any modal) to the new size. }
        ArrangePlanes;
        FLayoutDirty := False;
      end;
    ikKey:
      if ModalActive then
      begin
        Handled := FPlanes[High(FPlanes)].Root.HandleEvent(E);
        if (not Handled) and (E.Key.Kind = kkEscape) then
          PopPlane;
      end
      else
        FPlanes[0].Root.HandleEvent(E);
    ikMouse:
      if ModalActive then
        FPlanes[High(FPlanes)].Root.HandleEvent(E)
      else
        FPlanes[0].Root.HandleEvent(E);
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
end;

function TTuiApp.FrameDue: Boolean;
begin
  Result := (FLastTickMs = 0) or (FNowMs - FLastTickMs >= FTickMs);
end;

function TTuiApp.GetAnimating: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FPlanes) do
    if (FPlanes[I].Root <> nil) and FPlanes[I].Root.Animating then
      Exit(True);
  Result := False;
end;

procedure TTuiApp.Tick(const ANowMs: Int64);
var
  I: Integer;
begin
  if FStop then
    Exit;
  FNowMs := ANowMs;
  FLastTickMs := ANowMs;
  for I := 0 to High(FPlanes) do
    if FPlanes[I].Root <> nil then
      FPlanes[I].Root.Advance(ANowMs);
  Present;
end;

function TTuiApp.NextFrameDelayMs: Integer;
begin
  if not Animating then
    Exit(-1);
  if FLastTickMs = 0 then
    Exit(0);
  Result := FTickMs - Integer(FNowMs - FLastTickMs);
  if Result < 0 then
    Result := 0;
  if Result > FTickMs then
    Result := FTickMs;
end;

procedure TTuiApp.Run(ACheckStop: TStopCheck);
const
  { Idle wake-up, not a refresh rate: IInputSource.Wait has no blocking form, so
    a long timeout keeps the loop responsive to signals without spinning. }
  IdleWaitMs = 1000;
var
  E: TInputEvent;
  Timeout: Integer;
  Handled: Boolean;
begin
  while not FStop do
  begin
    if Assigned(ACheckStop) and ACheckStop() then
      Exit;
    FNowMs := MonotonicMs;
    Timeout := NextFrameDelayMs;
    if Timeout < 0 then
      Timeout := IdleWaitMs;
    Handled := FInput.Wait(Timeout, E);
    if Handled then
      DispatchEvent(E);
    FNowMs := MonotonicMs;
    if Animating then
    begin
      if FrameDue then
        Tick(FNowMs)
      else if Handled then
        Present;
    end
    else if Handled then
      Present;
  end;
end;

end.
