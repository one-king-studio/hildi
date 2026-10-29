unit AsyncFuture;
{ TFuture<T>: one asynchronous value, fulfilled or rejected exactly once.

  A future is eager (it starts at creation), shared, and uncancellable - the
  front the spec calls a "stream of one value". Callbacks are delivered through
  the future's scheduler when it has one, so ordering matches the rest of the
  spine; without one they run inline.

  Note: FPC cannot specialise TList<TAction<T>> inside a generic class, so the
  callbacks live in plain dynamic arrays. The method is AndThen because `then`
  is a Pascal reserved word.

  See docs/features/Async_Core/Async_Core_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, SyncObjs,
  AsyncBase, AsyncScheduler;

type
  TFutureState = (fsPending, fsFulfilled, fsRejected);

  { Raised by Await when the awaited future was rejected. Carries the original
    message; the future keeps the original error object for inspection. }
  EFutureRejected = class(Exception);

  { Raised by Await when its cancellation token was tripped before settlement. }
  EFutureCancelled = class(Exception);

  TFuture<T> = class
  private
    FLock: TCriticalSection;
    FState: TFutureState;
    FValue: T;
    FError: Exception;
    FOnFulfilled: TArray<TAction<T> >;
    FOnRejected: TArray<TAction<Exception> >;
    FOnFinally: TArray<TNotify>;
    FScheduler: IAsyncScheduler;
    procedure Deliver;
    procedure RunNow(const AWork: TNotify);
    procedure SettleRejected(const AError: Exception);
    procedure RunFinally;
  public
    constructor Create(const AScheduler: IAsyncScheduler = nil);
    destructor Destroy; override;

    class function Resolve(const AValue: T;
      const AScheduler: IAsyncScheduler = nil): TFuture<T>; static;
    class function Reject(const AError: Exception;
      const AScheduler: IAsyncScheduler = nil): TFuture<T>; static;
    { Run AProduce eagerly on the scheduler (or inline when none). }
    class function Run(const AProduce: TProducer<T>;
      const AScheduler: IAsyncScheduler = nil): TFuture<T>; static;

    procedure Fulfill(const AValue: T);
    procedure Fail(const AError: Exception);

    function AndThen(const AOnFulfilled: TAction<T>): TFuture<T>;
    function Catch(const AOnRejected: TAction<Exception>): TFuture<T>;
    { Runs AAction once when the future settles, fulfilled or rejected. }
    function OnFinally(const AAction: TNotify): TFuture<T>;

    { Block and drive the scheduler until settled; return the value or raise
      EFutureRejected. Raises if a scheduler is needed but there is none, or if
      nothing pending can settle it. }
    function Await: T;
    { Await, but stop waiting (raise EFutureCancelled) if AToken is tripped. }
    function AwaitToken(const AToken: ICancellationToken): T;

    property State: TFutureState read FState;
    property Value: T read FValue;
    property Error: Exception read FError;
  end;

  { A coordinator for Race/Any: observes each future and settles the output on
    the first (Race) or the first fulfilled (Any) outcome. A concrete class, not
    a closure, so it can hold the output future and the counters. }
  { A coordinator for Race/Any: observes each future and settles the output on
    the first (Race) or the first fulfilled (Any) outcome. A concrete class, not
    a closure, so it can hold the output future and the counters. Held by the
    observer closures as an INTERFACE, so it is freed once the inputs settle and
    the closures are released. }
  IFutureRacer<T> = interface
    procedure OnValue(const AValue: T);
    procedure OnError(const AError: Exception);
    function Output: TFuture<T>;
  end;

  TFutureRacer<T> = class(TInterfacedObject, IFutureRacer<T>)
  private
    FOut: TFuture<T>;
    FWon: Boolean;
    FCount: Integer;      { Any: futures still pending }
    FLastErr: Exception;
    FAnyMode: Boolean;
  public
    constructor Create(const ACount: Integer; const AAnyMode: Boolean);
    procedure OnValue(const AValue: T);
    procedure OnError(const AError: Exception);
    function Output: TFuture<T>;
  end;

{ Race: the first future to settle wins. All same-type, so no nesting. }
function Race<T>(const AFutures: TArray<TFuture<T>>): TFuture<T>;
{ Any: the first future to be FULFILLED wins (a rejection does not win). }
function Any<T>(const AFutures: TArray<TFuture<T>>): TFuture<T>;

implementation

{ TFuture<T> }

constructor TFuture<T>.Create(const AScheduler: IAsyncScheduler);
begin
  inherited Create;
  { A spinlock needs no construction and no heap allocation. }
  FLock := TCriticalSection.Create;
  FState := fsPending;
  SetLength(FOnFulfilled, 0);
  SetLength(FOnRejected, 0);
  SetLength(FOnFinally, 0);
  FScheduler := AScheduler;
end;

destructor TFuture<T>.Destroy;
begin
  FError.Free;
  FLock.Free;
  inherited;
end;

class function TFuture<T>.Resolve(const AValue: T;
  const AScheduler: IAsyncScheduler): TFuture<T>;
begin
  Result := TFuture<T>.Create(AScheduler);
  Result.Fulfill(AValue);
end;

class function TFuture<T>.Reject(const AError: Exception;
  const AScheduler: IAsyncScheduler): TFuture<T>;
begin
  Result := TFuture<T>.Create(AScheduler);
  Result.Fail(AError);
end;

procedure TFuture<T>.RunNow(const AWork: TNotify);
begin
  if FScheduler <> nil then
    FScheduler.Schedule(AWork, 0)
  else
    AWork();
end;

procedure TFuture<T>.SettleRejected(const AError: Exception);
begin
  FLock.Acquire;
  try
    if FState <> fsPending then
    begin
      AError.Free;
      Exit;
    end;
    FState := fsRejected;
    FError := AError;
  finally
    FLock.Release;
  end;
  RunNow(Deliver);
end;

procedure TFuture<T>.Fulfill(const AValue: T);
begin
  FLock.Acquire;
  try
    if FState <> fsPending then
      Exit;
    FState := fsFulfilled;
    FValue := AValue;
  finally
    FLock.Release;
  end;
  RunNow(Deliver);
end;

procedure TFuture<T>.Fail(const AError: Exception);
begin
  SettleRejected(AError);
end;

procedure TFuture<T>.Deliver;
var
  Fs: TArray<TAction<T> >;
  Rs: TArray<TAction<Exception> >;
  Fulfilled: Boolean;
  I: Integer;
begin
  FLock.Acquire;
  try
    Fulfilled := FState = fsFulfilled;
    Fs := FOnFulfilled;
    Rs := FOnRejected;
    SetLength(FOnFulfilled, 0);
    SetLength(FOnRejected, 0);
  finally
    FLock.Release;
  end;
  if Fulfilled then
  begin
    for I := 0 to High(Fs) do
      Fs[I](FValue);
  end
  else
  begin
    for I := 0 to High(Rs) do
      Rs[I](FError);
  end;
  RunFinally;
end;

function TFuture<T>.AndThen(const AOnFulfilled: TAction<T>): TFuture<T>;
var
  Settled: Boolean;
begin
  Result := Self;
  FLock.Acquire;
  try
    SetLength(FOnFulfilled, Length(FOnFulfilled) + 1);
    FOnFulfilled[High(FOnFulfilled)] := AOnFulfilled;
    Settled := FState <> fsPending;
  finally
    FLock.Release;
  end;
  if Settled then
    RunNow(Deliver);
end;

function TFuture<T>.Catch(const AOnRejected: TAction<Exception>): TFuture<T>;
var
  Settled: Boolean;
begin
  Result := Self;
  FLock.Acquire;
  try
    SetLength(FOnRejected, Length(FOnRejected) + 1);
    FOnRejected[High(FOnRejected)] := AOnRejected;
    Settled := FState <> fsPending;
  finally
    FLock.Release;
  end;
  if Settled then
    RunNow(Deliver);
end;

function TFuture<T>.Await: T;
begin
  while FState = fsPending do
  begin
    if FScheduler = nil then
      raise Exception.Create('Await: the future is pending and has no scheduler');
    if not FScheduler.HasPending then
      raise Exception.Create('Await: nothing pending can settle the future');
    FScheduler.Drain;
  end;
  if FState = fsRejected then
    raise EFutureRejected.Create(FError.Message);
  Result := FValue;
end;

function TFuture<T>.AwaitToken(const AToken: ICancellationToken): T;
begin
  while FState = fsPending do
  begin
    if AToken.IsCancelled then
      raise EFutureCancelled.Create('Await: cancelled');
    if FScheduler = nil then
      raise Exception.Create('Await: the future is pending and has no scheduler');
    if not FScheduler.HasPending then
      raise Exception.Create('Await: nothing pending can settle the future');
    FScheduler.Drain;
  end;
  if FState = fsRejected then
    raise EFutureRejected.Create(FError.Message);
  Result := FValue;
end;

procedure TFuture<T>.RunFinally;
var
  Fs: TArray<TNotify>;
  I: Integer;
begin
  FLock.Acquire;
  try
    Fs := FOnFinally;
    SetLength(FOnFinally, 0);
  finally
    FLock.Release;
  end;
  for I := 0 to High(Fs) do
    Fs[I]();
end;

function TFuture<T>.OnFinally(const AAction: TNotify): TFuture<T>;
var
  Settled: Boolean;
begin
  Result := Self;
  FLock.Acquire;
  try
    SetLength(FOnFinally, Length(FOnFinally) + 1);
    FOnFinally[High(FOnFinally)] := AAction;
    Settled := FState <> fsPending;
  finally
    FLock.Release;
  end;
  if Settled then
    RunNow(RunFinally);
end;

class function TFuture<T>.Run(const AProduce: TProducer<T>;
  const AScheduler: IAsyncScheduler): TFuture<T>;
var
  F: TFuture<T>;
  V: T;
begin
  F := TFuture<T>.Create(AScheduler);
  Result := F;
  { Eager: produce now, settle, then deliver. A raise becomes a rejection. Call
    the producer into a local first, so a raise does not happen while evaluating
    an argument to Fulfill. }
  try
    V := AProduce();
    F.Fulfill(V);
  except
    { The caught exception is runtime-owned and freed when this block exits, so
      give the future its OWN exception to own (Destroy frees it). }
    on E: Exception do
      F.Fail(Exception.Create(E.Message));
  end;
end;

{ Race / Any }

function Race<T>(const AFutures: TArray<TFuture<T>>): TFuture<T>;
var
  I: Integer;
  Racer: IFutureRacer<T>;
begin
  Racer := TFutureRacer<T>.Create(Length(AFutures), False);
  for I := 0 to High(AFutures) do
  begin
    AFutures[I].AndThen(
      procedure(const AValue: T) begin Racer.OnValue(AValue); end);
    AFutures[I].Catch(
      procedure(const AError: Exception) begin Racer.OnError(AError); end);
  end;
  Result := Racer.Output;
end;

function Any<T>(const AFutures: TArray<TFuture<T>>): TFuture<T>;
var
  I: Integer;
  Racer: IFutureRacer<T>;
begin
  Racer := TFutureRacer<T>.Create(Length(AFutures), True);
  for I := 0 to High(AFutures) do
  begin
    AFutures[I].AndThen(
      procedure(const AValue: T) begin Racer.OnValue(AValue); end);
    AFutures[I].Catch(
      procedure(const AError: Exception) begin Racer.OnError(AError); end);
  end;
  Result := Racer.Output;
end;

{ TFutureRacer<T> }

constructor TFutureRacer<T>.Create(const ACount: Integer; const AAnyMode: Boolean);
begin
  inherited Create;
  FOut := TFuture<T>.Create;
  FWon := False;
  FCount := ACount;
  FLastErr := nil;
  FAnyMode := AAnyMode;
end;

procedure TFutureRacer<T>.OnValue(const AValue: T);
begin
  if FWon then
    Exit;
  FWon := True;
  FOut.Fulfill(AValue);
end;

function TFutureRacer<T>.Output: TFuture<T>;
begin
  Result := FOut;
end;

procedure TFutureRacer<T>.OnError(const AError: Exception);
begin
  if FWon then
    Exit;
  if FAnyMode then
  begin
    { Any: only the LAST rejection (all rejected) wins. }
    Dec(FCount);
    FLastErr := AError;
    if FCount = 0 then
    begin
      FWon := True;
      FOut.Fail(FLastErr);
    end;
  end
  else
  begin
    { Race: a rejection settles it. }
    FWon := True;
    FOut.Fail(AError);
  end;
end;

end.
