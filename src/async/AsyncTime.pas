unit AsyncTime;
{ Time-based operators: Delay, DebounceTime, ThrottleTime, SampleTime, and the
  creation operators Timer and Interval.

  They take an IAsyncScheduler explicitly - a TVirtualScheduler in tests (driven
  by Advance, so no wall time passes) or a TRealScheduler in production. This is
  the spec's rule: a time-based operator uses the scheduler it is given, never
  Sleep.

  FPC 3.3.1 forbids a free generic function whose body builds an anonymous
  function, and a generic method with a closure ICEs, so every operator is a free
  function over concrete observer + observable classes, and the scheduled work is
  a concrete object method (a TNotify), never a closure. See
  docs/features/Async_Core/FPC_Generics_Notes.md.

  This library has NO dependency on the harness or any engine unit. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, SyncObjs,
  AsyncBase, AsyncObservable, AsyncScheduler;

type
  { A duration selector: picks a per-value duration (the *When operators). }
  TDurationSelector<T> = reference to function(const AValue: T): Integer;
  { A fallback factory: a stream to switch to on timeout (TimeoutWith). }
  TStreamFactory<T> = reference to function: ISubscribable<T>;
  { --- Scheduled actions (concrete, no closures) -------------------------- }

{ Forwards one value when it runs. }
TValueEmit<T> = class
public
  FDown: IObserver<T>;
  FValue: T;
  constructor Create(const ADown: IObserver<T>; const AValue: T);
  procedure Run;
end;

{ Completes the downstream when it runs. }
TCompleteEmit<T> = class
public
  FDown: IObserver<T>;
  constructor Create(const ADown: IObserver<T>);
  procedure Run;
end;

{ --- Delay -------------------------------------------------------------- }

TDelayObserver<T> = class(TInterfacedObject, IObserver<T>)
private
  FDown: IObserver<T>;
  FScheduler: IAsyncScheduler;
  FDelayMs: Integer;
public
  constructor Create(const ADown: IObserver<T>; const AScheduler: IAsyncScheduler;
    const ADelayMs: Integer);
  procedure OnNext(const AValue: T);
  procedure OnError(const AError: Exception);
  procedure OnComplete;
end;

TDelayObservable<T> = class(TInterfacedObject, ISubscribable<T>)
private
  FSource: ISubscribable<T>;
  FScheduler: IAsyncScheduler;
  FDelayMs: Integer;
public
  constructor Create(const ASource: ISubscribable<T>;
    const AScheduler: IAsyncScheduler; const ADelayMs: Integer);
  function Subscribe(const AObserver: IObserver<T>): ISubscription;
end;

{ --- DebounceTime ------------------------------------------------------- }

{ Holds the pending value; the scheduler calls Run after the quiet period. }
TDebounceEmit<T> = class
public
  FDown: IObserver<T>;
  FValue: T;
  FHas: Boolean;
  constructor Create(const ADown: IObserver<T>);
  procedure Run;
end;

TDebounceObserver<T> = class(TInterfacedObject, IObserver<T>)
private
  FDown: IObserver<T>;
  FScheduler: IAsyncScheduler;
  FDelayMs: Integer;
  FEmit: TDebounceEmit<T>;
  FPending: ISubscription;
public
  constructor Create(const ADown: IObserver<T>; const AScheduler: IAsyncScheduler;
    const ADelayMs: Integer);
  destructor Destroy; override;
  procedure OnNext(const AValue: T);
  procedure OnError(const AError: Exception);
  procedure OnComplete;
end;

TDebounceObservable<T> = class(TInterfacedObject, ISubscribable<T>)
private
  FSource: ISubscribable<T>;
  FScheduler: IAsyncScheduler;
  FDelayMs: Integer;
public
  constructor Create(const ASource: ISubscribable<T>;
    const AScheduler: IAsyncScheduler; const ADelayMs: Integer);
  function Subscribe(const AObserver: IObserver<T>): ISubscription;
end;

{ --- ThrottleTime ------------------------------------------------------- }

{ Forwards the leading value, then ignores values for the window. }
TThrottleObserver<T> = class(TInterfacedObject, IObserver<T>)
private
  FDown: IObserver<T>;
  FScheduler: IAsyncScheduler;
  FWindowMs: Integer;
  FOpen: Boolean;
  FGate: ISubscription;
  procedure Reopen;
public
  constructor Create(const ADown: IObserver<T>; const AScheduler: IAsyncScheduler;
    const AWindowMs: Integer);
  procedure OnNext(const AValue: T);
  procedure OnError(const AError: Exception);
  procedure OnComplete;
end;

TThrottleObservable<T> = class(TInterfacedObject, ISubscribable<T>)
private
  FSource: ISubscribable<T>;
  FScheduler: IAsyncScheduler;
  FWindowMs: Integer;
public
  constructor Create(const ASource: ISubscribable<T>;
    const AScheduler: IAsyncScheduler; const AWindowMs: Integer);
  function Subscribe(const AObserver: IObserver<T>): ISubscription;
end;

{ --- SampleTime --------------------------------------------------------- }

{ Emits the most recent value each time the window elapses. }
TSampleEmit<T> = class
public
  FDown: IObserver<T>;
  FValue: T;
  FHas: Boolean;
  constructor Create(const ADown: IObserver<T>);
  procedure Run;
end;

TSampleObserver<T> = class(TInterfacedObject, IObserver<T>)
private
  FDown: IObserver<T>;
  FScheduler: IAsyncScheduler;
  FPeriodMs: Integer;
  FEmit: TSampleEmit<T>;
  FTick: ISubscription;
  procedure ScheduleTick;
  procedure Tick;
public
  constructor Create(const ADown: IObserver<T>; const AScheduler: IAsyncScheduler;
    const APeriodMs: Integer);
  destructor Destroy; override;
  procedure OnNext(const AValue: T);
  procedure OnError(const AError: Exception);
  procedure OnComplete;
end;

TSampleObservable<T> = class(TInterfacedObject, ISubscribable<T>)
private
  FSource: ISubscribable<T>;
  FScheduler: IAsyncScheduler;
  FPeriodMs: Integer;
public
  constructor Create(const ASource: ISubscribable<T>;
    const AScheduler: IAsyncScheduler; const APeriodMs: Integer);
  function Subscribe(const AObserver: IObserver<T>): ISubscription;
end;

{ --- Timer and Interval ------------------------------------------------- }

TTimerObserver = class(TInterfacedObject, ISubscription)
private
  FDown: IObserver<Integer>;
  FScheduler: IAsyncScheduler;
  FDelayMs: Integer;
  FClosed: Boolean;
public
  constructor Create(const ADown: IObserver<Integer>;
    const AScheduler: IAsyncScheduler; const ADelayMs: Integer);
  procedure Fire;
  procedure Unsubscribe;
  function Closed: Boolean;
end;

TTimerObservable = class(TInterfacedObject, ISubscribable<Integer>)
private
  FScheduler: IAsyncScheduler;
  FDelayMs: Integer;
public
  constructor Create(const AScheduler: IAsyncScheduler; const ADelayMs: Integer);
  function Subscribe(const AObserver: IObserver<Integer>): ISubscription;
end;

TIntervalObserver = class(TInterfacedObject, ISubscription)
private
  FDown: IObserver<Integer>;
  FScheduler: IAsyncScheduler;
  FPeriodMs: Integer;
  FIndex: Integer;
  FClosed: Boolean;
public
  constructor Create(const ADown: IObserver<Integer>;
    const AScheduler: IAsyncScheduler; const APeriodMs: Integer);
  procedure Start;
  procedure Tick;
  procedure Unsubscribe;
  function Closed: Boolean;
end;

TIntervalObservable = class(TInterfacedObject, ISubscribable<Integer>)
private
  FScheduler: IAsyncScheduler;
  FPeriodMs: Integer;
public
  constructor Create(const AScheduler: IAsyncScheduler; const APeriodMs: Integer);
  function Subscribe(const AObserver: IObserver<Integer>): ISubscription;
end;

{ --- The surface -------------------------------------------------------- }

function Delay<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ADelayMs: Integer): ISubscribable<T>;
function DebounceTime<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ADelayMs: Integer): ISubscribable<T>;
function ThrottleTime<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const AWindowMs: Integer): ISubscribable<T>;
function SampleTime<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const APeriodMs: Integer): ISubscribable<T>;
function AuditTime<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ADurationMs: Integer): ISubscribable<T>;
function Timeout<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ATimeoutMs: Integer): ISubscribable<T>;
function Timer(const AScheduler: IAsyncScheduler;
  const ADelayMs: Integer): ISubscribable<Integer>;
function Interval(const AScheduler: IAsyncScheduler;
  const APeriodMs: Integer): ISubscribable<Integer>;
function DelayWhen<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler;
  const ASelector: TDurationSelector<T>): ISubscribable<T>;
function TimeoutWith<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ATimeoutMs: Integer;
  const AFallback: TStreamFactory<T>): ISubscribable<T>;

type
  { --- AuditTime ---------------------------------------------------------- }

{ Holds the latest value; a timer emits it at the end of each window. }
TAuditEmit<T> = class
public
  FDown: IObserver<T>;
  FValue: T;
  FHas: Boolean;
  FArmed: Boolean;
  constructor Create(const ADown: IObserver<T>);
  procedure Run;
end;

TAuditObserver<T> = class(TInterfacedObject, IObserver<T>)
private
  FDown: IObserver<T>;
  FScheduler: IAsyncScheduler;
  FDurationMs: Integer;
  FEmit: TAuditEmit<T>;
  FHandle: ISubscription;
public
  constructor Create(const ADown: IObserver<T>; const AScheduler: IAsyncScheduler;
    const ADurationMs: Integer);
  destructor Destroy; override;
  procedure OnNext(const AValue: T);
  procedure OnError(const AError: Exception);
  procedure OnComplete;
end;

TAuditObservable<T> = class(TInterfacedObject, ISubscribable<T>)
private
  FSource: ISubscribable<T>;
  FScheduler: IAsyncScheduler;
  FDurationMs: Integer;
public
  constructor Create(const ASource: ISubscribable<T>;
    const AScheduler: IAsyncScheduler; const ADurationMs: Integer);
  function Subscribe(const AObserver: IObserver<T>): ISubscription;
end;

{ --- Timeout ------------------------------------------------------------ }

{ Resets a timer on each value; if it fires first, the stream errors. }
TTimeoutObserver<T> = class(TInterfacedObject, IObserver<T>, ISubscription)
private
  FDown: IObserver<T>;
  FScheduler: IAsyncScheduler;
  FTimeoutMs: Integer;
  FHandle: ISubscription;
  FClosed: Boolean;
public
  constructor Create(const ADown: IObserver<T>; const AScheduler: IAsyncScheduler;
    const ATimeoutMs: Integer);
  procedure Arm;
  procedure Fire;
  procedure OnNext(const AValue: T);
  procedure OnError(const AError: Exception);
  procedure OnComplete;
  procedure Unsubscribe;
  function Closed: Boolean;
end;

TTimeoutObservable<T> = class(TInterfacedObject, ISubscribable<T>)
private
  FSource: ISubscribable<T>;
  FScheduler: IAsyncScheduler;
  FTimeoutMs: Integer;
public
  constructor Create(const ASource: ISubscribable<T>;
    const AScheduler: IAsyncScheduler; const ATimeoutMs: Integer);
  function Subscribe(const AObserver: IObserver<T>): ISubscription;
end;

{ --- DelayWhen ---------------------------------------------------------- }

{ Forwards a value after a per-value delay from the selector. }
TDelayWhenObserver<T> = class(TInterfacedObject, IObserver<T>)
private
  FDown: IObserver<T>;
  FScheduler: IAsyncScheduler;
  FSelector: TDurationSelector<T>;
public
  constructor Create(const ADown: IObserver<T>; const AScheduler: IAsyncScheduler;
    const ASelector: TDurationSelector<T>);
  procedure OnNext(const AValue: T);
  procedure OnError(const AError: Exception);
  procedure OnComplete;
end;

TDelayWhenObservable<T> = class(TInterfacedObject, ISubscribable<T>)
private
  FSource: ISubscribable<T>;
  FScheduler: IAsyncScheduler;
  FSelector: TDurationSelector<T>;
public
  constructor Create(const ASource: ISubscribable<T>;
    const AScheduler: IAsyncScheduler; const ASelector: TDurationSelector<T>);
  function Subscribe(const AObserver: IObserver<T>): ISubscription;
end;

{ --- TimeoutWith -------------------------------------------------------- }

{ Like Timeout, but switches to a fallback stream instead of erroring. }
TTimeoutWithObserver<T> = class(TInterfacedObject, IObserver<T>)
private
  FDown: IObserver<T>;
  FScheduler: IAsyncScheduler;
  FTimeoutMs: Integer;
  FFallback: TStreamFactory<T>;
  FHandle: ISubscription;
  FClosed: Boolean;
public
  constructor Create(const ADown: IObserver<T>; const AScheduler: IAsyncScheduler;
    const ATimeoutMs: Integer; const AFallback: TStreamFactory<T>);
  procedure Arm;
  procedure Fire;
  procedure OnNext(const AValue: T);
  procedure OnError(const AError: Exception);
  procedure OnComplete;
end;

TTimeoutWithObservable<T> = class(TInterfacedObject, ISubscribable<T>)
private
  FSource: ISubscribable<T>;
  FScheduler: IAsyncScheduler;
  FTimeoutMs: Integer;
  FFallback: TStreamFactory<T>;
public
  constructor Create(const ASource: ISubscribable<T>;
    const AScheduler: IAsyncScheduler; const ATimeoutMs: Integer;
    const AFallback: TStreamFactory<T>);
  function Subscribe(const AObserver: IObserver<T>): ISubscription;
end;

implementation
{ TValueEmit<T> }

constructor TValueEmit<T>.Create(const ADown: IObserver<T>; const AValue: T);
begin
  inherited Create;
  FDown := ADown;
  FValue := AValue;
end;

procedure TValueEmit<T>.Run;
begin
  FDown.OnNext(FValue);
  { A one-shot scheduled action: free it after it runs. Nothing touches Self
    after this. }
  Free;
end;

{ TCompleteEmit<T> }

constructor TCompleteEmit<T>.Create(const ADown: IObserver<T>);
begin
  inherited Create;
  FDown := ADown;
end;

procedure TCompleteEmit<T>.Run;
begin
  FDown.OnComplete;
  Free;
end;

{ Delay }

constructor TDelayObserver<T>.Create(const ADown: IObserver<T>;
  const AScheduler: IAsyncScheduler; const ADelayMs: Integer);
begin
  inherited Create;
  FDown := ADown;
  FScheduler := AScheduler;
  FDelayMs := ADelayMs;
end;

procedure TDelayObserver<T>.OnNext(const AValue: T);
begin
  FScheduler.Schedule(TValueEmit<T>.Create(FDown, AValue).Run, FDelayMs);
end;

procedure TDelayObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TDelayObserver<T>.OnComplete;
begin
  FScheduler.Schedule(TCompleteEmit<T>.Create(FDown).Run, FDelayMs);
end;

constructor TDelayObservable<T>.Create(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ADelayMs: Integer);
begin
  inherited Create;
  FSource := ASource;
  FScheduler := AScheduler;
  FDelayMs := ADelayMs;
end;

function TDelayObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TDelayObserver<T>.Create(AObserver, FScheduler, FDelayMs));
end;

{ DebounceTime }

constructor TDebounceEmit<T>.Create(const ADown: IObserver<T>);
begin
  inherited Create;
  FDown := ADown;
  FHas := False;
end;

procedure TDebounceEmit<T>.Run;
begin
  if FHas then
  begin
    FHas := False;
    FDown.OnNext(FValue);
  end;
end;

constructor TDebounceObserver<T>.Create(const ADown: IObserver<T>;
  const AScheduler: IAsyncScheduler; const ADelayMs: Integer);
begin
  inherited Create;
  FDown := ADown;
  FScheduler := AScheduler;
  FDelayMs := ADelayMs;
  FEmit := TDebounceEmit<T>.Create(ADown);
  FPending := nil;
end;

destructor TDebounceObserver<T>.Destroy;
begin
  FEmit.Free;
  inherited;
end;

procedure TDebounceObserver<T>.OnNext(const AValue: T);
begin
  FEmit.FValue := AValue;
  FEmit.FHas := True;
  if FPending <> nil then
    FPending.Unsubscribe;
  FPending := FScheduler.Schedule(FEmit.Run, FDelayMs);
end;

procedure TDebounceObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TDebounceObserver<T>.OnComplete;
begin
  { Flush a pending value, then complete. }
  if FEmit.FHas then
  begin
    FEmit.FHas := False;
    FDown.OnNext(FEmit.FValue);
  end;
  FDown.OnComplete;
end;

constructor TDebounceObservable<T>.Create(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ADelayMs: Integer);
begin
  inherited Create;
  FSource := ASource;
  FScheduler := AScheduler;
  FDelayMs := ADelayMs;
end;

function TDebounceObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TDebounceObserver<T>.Create(AObserver, FScheduler, FDelayMs));
end;

{ ThrottleTime }

constructor TThrottleObserver<T>.Create(const ADown: IObserver<T>;
  const AScheduler: IAsyncScheduler; const AWindowMs: Integer);
begin
  inherited Create;
  FDown := ADown;
  FScheduler := AScheduler;
  FWindowMs := AWindowMs;
  FOpen := True;
  FGate := nil;
end;

procedure TThrottleObserver<T>.Reopen;
begin
  FOpen := True;
end;

procedure TThrottleObserver<T>.OnNext(const AValue: T);
begin
  if not FOpen then
    Exit;
  { Emit the leading value, then close the gate for the window. }
  FOpen := False;
  FDown.OnNext(AValue);
  FGate := FScheduler.Schedule(Reopen, FWindowMs);
end;

procedure TThrottleObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TThrottleObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

constructor TThrottleObservable<T>.Create(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const AWindowMs: Integer);
begin
  inherited Create;
  FSource := ASource;
  FScheduler := AScheduler;
  FWindowMs := AWindowMs;
end;

function TThrottleObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TThrottleObserver<T>.Create(AObserver, FScheduler, FWindowMs));
end;

{ SampleTime }

constructor TSampleEmit<T>.Create(const ADown: IObserver<T>);
begin
  inherited Create;
  FDown := ADown;
  FHas := False;
end;

procedure TSampleEmit<T>.Run;
begin
  if FHas then
  begin
    FHas := False;
    FDown.OnNext(FValue);
  end;
end;

constructor TSampleObserver<T>.Create(const ADown: IObserver<T>;
  const AScheduler: IAsyncScheduler; const APeriodMs: Integer);
begin
  inherited Create;
  FDown := ADown;
  FScheduler := AScheduler;
  FPeriodMs := APeriodMs;
  FEmit := TSampleEmit<T>.Create(ADown);
  FTick := nil;
  ScheduleTick;
end;

destructor TSampleObserver<T>.Destroy;
begin
  FEmit.Free;
  inherited;
end;

procedure TSampleObserver<T>.ScheduleTick;
begin
  FTick := FScheduler.Schedule(Tick, FPeriodMs);
end;

procedure TSampleObserver<T>.Tick;
begin
  { Emit the latest, then re-arm for the next period. }
  FEmit.Run;
  ScheduleTick;
end;

procedure TSampleObserver<T>.OnNext(const AValue: T);
begin
  { Remember the latest; the periodic tick emits it. }
  FEmit.FValue := AValue;
  FEmit.FHas := True;
end;

procedure TSampleObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TSampleObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

constructor TSampleObservable<T>.Create(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const APeriodMs: Integer);
begin
  inherited Create;
  FSource := ASource;
  FScheduler := AScheduler;
  FPeriodMs := APeriodMs;
end;

function TSampleObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TSampleObserver<T>.Create(AObserver, FScheduler, FPeriodMs));
end;

{ Timer }

constructor TTimerObserver.Create(const ADown: IObserver<Integer>;
  const AScheduler: IAsyncScheduler; const ADelayMs: Integer);
begin
  inherited Create;
  FDown := ADown;
  FScheduler := AScheduler;
  FDelayMs := ADelayMs;
  FClosed := False;
end;

procedure TTimerObserver.Fire;
begin
  if FClosed then
    Exit;
  FClosed := True;
  FDown.OnNext(0);
  FDown.OnComplete;
end;

procedure TTimerObserver.Unsubscribe;
begin
  FClosed := True;
end;

function TTimerObserver.Closed: Boolean;
begin
  Result := FClosed;
end;

constructor TTimerObservable.Create(const AScheduler: IAsyncScheduler;
  const ADelayMs: Integer);
begin
  inherited Create;
  FScheduler := AScheduler;
  FDelayMs := ADelayMs;
end;

function TTimerObservable.Subscribe(const AObserver: IObserver<Integer>): ISubscription;
var
  Obs: TTimerObserver;
begin
  Obs := TTimerObserver.Create(AObserver, FScheduler, FDelayMs);
  Result := Obs;
  FScheduler.Schedule(Obs.Fire, FDelayMs);
end;

{ Interval }

constructor TIntervalObserver.Create(const ADown: IObserver<Integer>;
  const AScheduler: IAsyncScheduler; const APeriodMs: Integer);
begin
  inherited Create;
  FDown := ADown;
  FScheduler := AScheduler;
  FPeriodMs := APeriodMs;
  FIndex := 0;
  FClosed := False;
end;

procedure TIntervalObserver.Start;
begin
  FScheduler.Schedule(Tick, FPeriodMs);
end;

procedure TIntervalObserver.Tick;
begin
  if FClosed then
    Exit;
  FDown.OnNext(FIndex);
  Inc(FIndex);
  FScheduler.Schedule(Tick, FPeriodMs);
end;

procedure TIntervalObserver.Unsubscribe;
begin
  FClosed := True;
end;

function TIntervalObserver.Closed: Boolean;
begin
  Result := FClosed;
end;

constructor TIntervalObservable.Create(const AScheduler: IAsyncScheduler;
  const APeriodMs: Integer);
begin
  inherited Create;
  FScheduler := AScheduler;
  FPeriodMs := APeriodMs;
end;

function TIntervalObservable.Subscribe(const AObserver: IObserver<Integer>): ISubscription;
var
  Obs: TIntervalObserver;
begin
  Obs := TIntervalObserver.Create(AObserver, FScheduler, FPeriodMs);
  Result := Obs;
  Obs.Start;
end;

{ The surface }

function Delay<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ADelayMs: Integer): ISubscribable<T>;
begin
  Result := TDelayObservable<T>.Create(ASource, AScheduler, ADelayMs);
end;

function DebounceTime<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ADelayMs: Integer): ISubscribable<T>;
begin
  Result := TDebounceObservable<T>.Create(ASource, AScheduler, ADelayMs);
end;

function ThrottleTime<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const AWindowMs: Integer): ISubscribable<T>;
begin
  Result := TThrottleObservable<T>.Create(ASource, AScheduler, AWindowMs);
end;

function SampleTime<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const APeriodMs: Integer): ISubscribable<T>;
begin
  Result := TSampleObservable<T>.Create(ASource, AScheduler, APeriodMs);
end;

function Timer(const AScheduler: IAsyncScheduler;
  const ADelayMs: Integer): ISubscribable<Integer>;
begin
  Result := TTimerObservable.Create(AScheduler, ADelayMs);
end;

function Interval(const AScheduler: IAsyncScheduler;
  const APeriodMs: Integer): ISubscribable<Integer>;
begin
  Result := TIntervalObservable.Create(AScheduler, APeriodMs);
end;

function AuditTime<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ADurationMs: Integer): ISubscribable<T>;
begin
  Result := TAuditObservable<T>.Create(ASource, AScheduler, ADurationMs);
end;

function Timeout<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ATimeoutMs: Integer): ISubscribable<T>;
begin
  Result := TTimeoutObservable<T>.Create(ASource, AScheduler, ATimeoutMs);
end;

{ TAuditEmit<T> }

constructor TAuditEmit<T>.Create(const ADown: IObserver<T>);
begin
  inherited Create;
  FDown := ADown;
  FHas := False;
  FArmed := False;
end;

procedure TAuditEmit<T>.Run;
begin
  FArmed := False;
  if FHas then
  begin
    FHas := False;
    FDown.OnNext(FValue);
  end;
end;

{ TAuditObserver<T> }

constructor TAuditObserver<T>.Create(const ADown: IObserver<T>;
  const AScheduler: IAsyncScheduler; const ADurationMs: Integer);
begin
  inherited Create;
  FDown := ADown;
  FScheduler := AScheduler;
  FDurationMs := ADurationMs;
  FEmit := TAuditEmit<T>.Create(ADown);
  FHandle := nil;
end;

destructor TAuditObserver<T>.Destroy;
begin
  FEmit.Free;
  inherited;
end;

procedure TAuditObserver<T>.OnNext(const AValue: T);
begin
  { Remember the latest; arm a timer only if none is pending (rate-limit). }
  FEmit.FValue := AValue;
  FEmit.FHas := True;
  if not FEmit.FArmed then
  begin
    FEmit.FArmed := True;
    FHandle := FScheduler.Schedule(FEmit.Run, FDurationMs);
  end;
end;

procedure TAuditObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TAuditObserver<T>.OnComplete;
begin
  { Flush a pending value, then complete. }
  if FEmit.FHas then
  begin
    FEmit.FHas := False;
    FDown.OnNext(FEmit.FValue);
  end;
  FDown.OnComplete;
end;

constructor TAuditObservable<T>.Create(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ADurationMs: Integer);
begin
  inherited Create;
  FSource := ASource;
  FScheduler := AScheduler;
  FDurationMs := ADurationMs;
end;

function TAuditObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TAuditObserver<T>.Create(AObserver, FScheduler, FDurationMs));
end;

{ TTimeoutObserver<T> }

constructor TTimeoutObserver<T>.Create(const ADown: IObserver<T>;
  const AScheduler: IAsyncScheduler; const ATimeoutMs: Integer);
begin
  inherited Create;
  FDown := ADown;
  FScheduler := AScheduler;
  FTimeoutMs := ATimeoutMs;
  FHandle := nil;
  FClosed := False;
end;

procedure TTimeoutObserver<T>.Arm;
begin
  FHandle := FScheduler.Schedule(Fire, FTimeoutMs);
end;

procedure TTimeoutObserver<T>.Fire;
begin
  if FClosed then
    Exit;
  FClosed := True;
  FDown.OnError(Exception.Create('timeout'));
end;

procedure TTimeoutObserver<T>.OnNext(const AValue: T);
begin
  { A value arrived in time: reset the timer, then forward. }
  if FClosed then
    Exit;
  if FHandle <> nil then
    FHandle.Unsubscribe;
  Arm;
  FDown.OnNext(AValue);
end;

procedure TTimeoutObserver<T>.OnError(const AError: Exception);
begin
  FClosed := True;
  FDown.OnError(AError);
end;

procedure TTimeoutObserver<T>.OnComplete;
begin
  FClosed := True;
  FDown.OnComplete;
end;

procedure TTimeoutObserver<T>.Unsubscribe;
begin
  FClosed := True;
  if FHandle <> nil then
    FHandle.Unsubscribe;
end;

function TTimeoutObserver<T>.Closed: Boolean;
begin
  Result := FClosed;
end;

constructor TTimeoutObservable<T>.Create(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ATimeoutMs: Integer);
begin
  inherited Create;
  FSource := ASource;
  FScheduler := AScheduler;
  FTimeoutMs := ATimeoutMs;
end;

function TTimeoutObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Obs: TTimeoutObserver<T>;
begin
  Obs := TTimeoutObserver<T>.Create(AObserver, FScheduler, FTimeoutMs);
  Result := Obs;
  Obs.Arm;
  FSource.Subscribe(Obs);
end;

function DelayWhen<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler;
  const ASelector: TDurationSelector<T>): ISubscribable<T>;
begin
  Result := TDelayWhenObservable<T>.Create(ASource, AScheduler, ASelector);
end;

function TimeoutWith<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ATimeoutMs: Integer;
  const AFallback: TStreamFactory<T>): ISubscribable<T>;
begin
  Result := TTimeoutWithObservable<T>.Create(ASource, AScheduler, ATimeoutMs,
    AFallback);
end;

{ TDelayWhenObserver<T> }

constructor TDelayWhenObserver<T>.Create(const ADown: IObserver<T>;
  const AScheduler: IAsyncScheduler; const ASelector: TDurationSelector<T>);
begin
  inherited Create;
  FDown := ADown;
  FScheduler := AScheduler;
  FSelector := ASelector;
end;

procedure TDelayWhenObserver<T>.OnNext(const AValue: T);
begin
  FScheduler.Schedule(TValueEmit<T>.Create(FDown, AValue).Run, FSelector(AValue));
end;

procedure TDelayWhenObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TDelayWhenObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

constructor TDelayWhenObservable<T>.Create(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ASelector: TDurationSelector<T>);
begin
  inherited Create;
  FSource := ASource;
  FScheduler := AScheduler;
  FSelector := ASelector;
end;

function TDelayWhenObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TDelayWhenObserver<T>.Create(AObserver, FScheduler,
    FSelector));
end;

{ TTimeoutWithObserver<T> }

constructor TTimeoutWithObserver<T>.Create(const ADown: IObserver<T>;
  const AScheduler: IAsyncScheduler; const ATimeoutMs: Integer;
  const AFallback: TStreamFactory<T>);
begin
  inherited Create;
  FDown := ADown;
  FScheduler := AScheduler;
  FTimeoutMs := ATimeoutMs;
  FFallback := AFallback;
  FHandle := nil;
  FClosed := False;
end;

procedure TTimeoutWithObserver<T>.Arm;
begin
  FHandle := FScheduler.Schedule(Fire, FTimeoutMs);
end;

procedure TTimeoutWithObserver<T>.Fire;
begin
  if FClosed then
    Exit;
  FClosed := True;
  { Switch to the fallback stream. }
  FFallback().Subscribe(FDown);
end;

procedure TTimeoutWithObserver<T>.OnNext(const AValue: T);
begin
  if FClosed then
    Exit;
  if FHandle <> nil then
    FHandle.Unsubscribe;
  Arm;
  FDown.OnNext(AValue);
end;

procedure TTimeoutWithObserver<T>.OnError(const AError: Exception);
begin
  FClosed := True;
  FDown.OnError(AError);
end;

procedure TTimeoutWithObserver<T>.OnComplete;
begin
  FClosed := True;
  FDown.OnComplete;
end;

constructor TTimeoutWithObservable<T>.Create(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler; const ATimeoutMs: Integer;
  const AFallback: TStreamFactory<T>);
begin
  inherited Create;
  FSource := ASource;
  FScheduler := AScheduler;
  FTimeoutMs := ATimeoutMs;
  FFallback := AFallback;
end;

function TTimeoutWithObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Obs: TTimeoutWithObserver<T>;
begin
  Obs := TTimeoutWithObserver<T>.Create(AObserver, FScheduler, FTimeoutMs, FFallback);
  Result := TClosureSubscription.Create(nil);
  Obs.Arm;
  FSource.Subscribe(Obs);
end;

end.
