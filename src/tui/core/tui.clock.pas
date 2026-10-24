unit tui.clock;
{ The TUI frame clock: one monotonic millisecond source for the whole app, plus
  the animation registry that negotiates the app's frame rate.

  Widgets never read the clock themselves; TTuiApp reads it and passes the time
  to TWidget.Advance. GetTickCount64 is monotonic on this platform (it is backed
  by clock_gettime(CLOCK_MONOTONIC) on Unix), so animations never see a wall-
  clock jump.

  A widget that animates registers the frame interval it needs; the app runs at
  the fastest registered interval (or idles when none is registered), instead of
  a fixed rate whenever anything reports Animating. Registration happens on
  discrete state changes (a caret gains focus, a spinner starts), never per
  frame, so no tree walk is needed to discover demand. }

{$mode delphi}{$H+}

interface

const
  { Default frame cadence: 100 Hz. A ceiling while something animates, not a
    forced refresh - the app blocks on input when nothing is animating. }
  DefaultTickMs = 10;

type
  { The animations currently registered, keyed by owning widget. The set is tiny
    (a caret, a spinner, a thinking block), so a linear scan is enough. }
  TAnimationClock = class
  private
    FWidgets: array of TObject;
    FIntervals: array of Integer;
    function IndexOf(AWidget: TObject): Integer;
  public
    destructor Destroy; override;
    { Register AWidget's animation at AIntervalMs, replacing any previous
      interval for it. AIntervalMs <= 0 unregisters; nil is ignored. }
    procedure Register(AWidget: TObject; AIntervalMs: Integer);
    procedure Unregister(AWidget: TObject);
    { The fastest registered interval in ms, or 0 when none is registered. }
    function MinIntervalMs: Integer;
    function Count: Integer;
    { Drop every registration (teardown, tests). }
    procedure Reset;
  end;

{ Monotonic milliseconds since an unspecified epoch. Never wall-clock. }
function MonotonicMs: Int64;

{ The process's animation registry. The TUI is one app per process. }
function AnimationClock: TAnimationClock;

implementation

uses
  SysUtils;

var
  GClock: TAnimationClock = nil;

function AnimationClock: TAnimationClock;
begin
  if GClock = nil then
    GClock := TAnimationClock.Create;
  Result := GClock;
end;

function MonotonicMs: Int64;
begin
  Result := Int64(GetTickCount64);
end;

destructor TAnimationClock.Destroy;
begin
  Reset;
  inherited Destroy;
end;

function TAnimationClock.IndexOf(AWidget: TObject): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FWidgets) do
    if FWidgets[I] = AWidget then
      Exit(I);
  Result := -1;
end;

procedure TAnimationClock.Register(AWidget: TObject; AIntervalMs: Integer);
var
  I: Integer;
begin
  if AWidget = nil then
    Exit;
  if AIntervalMs <= 0 then
  begin
    Unregister(AWidget);
    Exit;
  end;
  I := IndexOf(AWidget);
  if I < 0 then
  begin
    I := Length(FWidgets);
    SetLength(FWidgets, I + 1);
    SetLength(FIntervals, I + 1);
    FWidgets[I] := AWidget;
  end;
  FIntervals[I] := AIntervalMs;
end;

procedure TAnimationClock.Unregister(AWidget: TObject);
var
  I, Last: Integer;
begin
  I := IndexOf(AWidget);
  if I < 0 then
    Exit;
  Last := High(FWidgets);
  FWidgets[I] := FWidgets[Last];
  FIntervals[I] := FIntervals[Last];
  SetLength(FWidgets, Last);
  SetLength(FIntervals, Last);
end;

function TAnimationClock.MinIntervalMs: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FIntervals) do
    if (Result = 0) or (FIntervals[I] < Result) then
      Result := FIntervals[I];
end;

function TAnimationClock.Count: Integer;
begin
  Result := Length(FWidgets);
end;

procedure TAnimationClock.Reset;
begin
  FWidgets := nil;
  FIntervals := nil;
end;

finalization
  GClock.Free;

end.
