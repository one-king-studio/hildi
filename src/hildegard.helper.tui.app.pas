unit hildegard.helper.tui.app;
{ Planes and the application loop for the TUI toolkit.

  TTuiApp owns a stack of planes and composes one frame per Step: clear, render
  the non-modal base plane(s), dim the rendered background once per dimmed
  modal, render the modal plane(s) on top, then flush once. The base root is
  arranged to the surface; modal roots are arranged by the caller and rendered
  clipped to their own bounds.

  Because the frame is rebuilt every Step, dimming never accumulates and the
  base stays visible underneath a modal. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget;

type
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
    procedure ArrangeBase;
    procedure RenderFrame;
  public
    constructor Create(const ASurface: ISurface; const AInput: IInputSource;
      ARoot: TWidget);
    destructor Destroy; override;

    { Mark layout dirty: the next Step re-arranges the base root. Call after a
      widget's content changes (for example appended text). }
    procedure Invalidate;

    procedure PushPlane(const APlane: TPlane);
    procedure PopPlane;
    function ModalActive: Boolean;
    procedure Stop;

    { One iteration: process at most one input event (or resize), lay out on
      change, render the frame, flush. Returns False once stopped. }
    function Step: Boolean;
    procedure Run;
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
  ARoot: TWidget);
begin
  inherited Create;
  FSurface := ASurface;
  FInput := AInput;
  FStop := False;
  FLayoutDirty := False;
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
  Handled: Boolean;
begin
  if FStop then
    Exit(False);
  if FInput.Poll(E) then
    case E.Kind of
      ikResize:
        FLayoutDirty := True;
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
  if FLayoutDirty then
  begin
    ArrangeBase;
    FLayoutDirty := False;
  end;
  RenderFrame;
  Result := not FStop;
end;

procedure TTuiApp.Run;
begin
  { Yield between frames: a tight Step loop can starve the OS terminal input
    path (observed on macOS), so keys are not delivered. Tests drive Step
    directly and are unaffected. }
  while Step do
    Sleep(1);
end;

end.
