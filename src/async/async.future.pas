unit async.future;
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
  async.base, async.scheduler;

type
  TFutureState = (fsPending, fsFulfilled, fsRejected);

  { Raised by Await when the awaited future was rejected. Carries the original
    message; the future keeps the original error object for inspection. }
  EFutureRejected = class(Exception);

  TFuture<T> = class
  private
    FLock: TCriticalSection;
    FState: TFutureState;
    FValue: T;
    FError: Exception;
    FOnFulfilled: TArray<TAction<T> >;
    FOnRejected: TArray<TAction<Exception> >;
    FScheduler: IAsyncScheduler;
    procedure Deliver;
    procedure Run(const AWork: TNotify);
    procedure SettleRejected(const AError: Exception);
  public
    constructor Create(const AScheduler: IAsyncScheduler = nil);
    destructor Destroy; override;

    class function Resolve(const AValue: T;
      const AScheduler: IAsyncScheduler = nil): TFuture<T>; static;
    class function Reject(const AError: Exception;
      const AScheduler: IAsyncScheduler = nil): TFuture<T>; static;

    procedure Fulfill(const AValue: T);
    procedure Fail(const AError: Exception);

    function AndThen(const AOnFulfilled: TAction<T>): TFuture<T>;
    function Catch(const AOnRejected: TAction<Exception>): TFuture<T>;

    { Block and drive the scheduler until settled; return the value or raise
      EFutureRejected. Raises if a scheduler is needed but there is none, or if
      nothing pending can settle it. }
    function Await: T;

    property State: TFutureState read FState;
    property Value: T read FValue;
    property Error: Exception read FError;
  end;

implementation

{ TFuture<T> }

constructor TFuture<T>.Create(const AScheduler: IAsyncScheduler);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FState := fsPending;
  SetLength(FOnFulfilled, 0);
  SetLength(FOnRejected, 0);
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

procedure TFuture<T>.Run(const AWork: TNotify);
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
  Run(Deliver);
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
  Run(Deliver);
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
    Run(Deliver);
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
    Run(Deliver);
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

end.
