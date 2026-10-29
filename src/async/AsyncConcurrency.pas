unit AsyncConcurrency;
{ Concurrency: which scheduler runs the work.

  TExecutorScheduler is a bounded thread pool. Schedule runs the work on a pool
  thread; the returned subscription cancels a job that has not started; every
  thread is joined on shutdown. It uses a lock-guarded queue and a TSimpleEvent
  to wake idle workers (TSemaphore is unusable on macOS: sem_init returns ENOSYS),
  and workers also poll, so a lost wake-up cannot stall the pool.

  The operators move work between schedulers:
    RunOn(scheduler, work)   - run work on scheduler (fire-and-forget).
    SubscribeOn(src, sched)  - the source's Subscribe runs on sched.
    ObserveOn(src, sched)    - the observer's notifications run on sched.

  State is thread-confined: the library offers no implicit shared state. This
  unit has NO dependency on the harness or any engine unit.

  See docs/features/Async_Core/Async_Core_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Generics.Collections,
  AsyncBase, AsyncContext, AsyncObservable, AsyncScheduler;

const
  ExecutorPollMs = 10;

type
  TExecutorScheduler = class;

  TExecutorWorker = class(TThread)
  private
    FOwner: TExecutorScheduler;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TExecutorScheduler);
  end;

  { A bounded thread pool. Schedule runs work on a pool thread. }
  TExecutorScheduler = class(TInterfacedObject, IAsyncScheduler)
  private
    { A real mutex, NOT a spinlock: the queue lock is held across TQueue
      operations and (historically) an event call, and a spinlock that is
      preempted mid-critical-section livelocks the other workers. A correct
      spinlock needs acquire/release barriers, which a bare InterlockedExchange
      does not guarantee on ARM64. Correctness first; the win here is the
      transition wake and ScheduleBatch, not the lock. }
    FLock: TCriticalSection;
    { A MANUAL-reset wake, signaled while the queue is non-empty and reset when a
      worker finds it empty. Manual reset (not auto) so one SetEvent wakes every
      idle worker, not just one; that makes "wake only on the empty -> non-empty
      transition" correct for a multi-worker pool. }
    FWake: TEvent;
    FIdle: TSimpleEvent;
    FQueue: TQueue<IAsyncJob>;
    FWorkers: TObjectList<TExecutorWorker>;
    { The mailbox bound: a fast producer must not grow the queue without limit.
      On overflow the OLDEST queued job is dropped and counted (the same policy
      as the harness's TTurnQueue), so the consumer always sees the most recent
      window. Capacity 0 means unbounded. }
    FCapacity: Integer;
    FDropped: Int64;
    { Outstanding jobs, touched only under FLock: incremented with the enqueue on
      Schedule (so it is never 0 while a job is queued) and decremented after a
      job runs, so Drain cannot return early. }
    FPending: Integer;
    FStopped: Boolean;
  public
    constructor Create(AConcurrency: Integer; ACapacity: Integer = 0);
    destructor Destroy; override;
    function Schedule(const AWork: TNotify; const ADelayMs: Integer): ISubscription;
    { Enqueue many jobs under ONE lock and ONE wake - for a bulk producer, so it
      does not pay the per-Schedule lock + wake N times. }
    function ScheduleBatch(const AWorks: TArray<TNotify>): ISubscription;
    { Schedule AWork and hand back the job's cancellation token, so a caller can
      poll it inside the work (in-flight cancellation) and Unsubscribe the result
      to trip it. }
    function ScheduleCancellable(const AWork: TNotify;
      out AToken: ICancellationToken): ISubscription;
    procedure Drain;
    function HasPending: Boolean;
    { How many queued jobs were dropped to honour the capacity. }
    property Dropped: Int64 read FDropped;
    { Worker loop helpers (called from a pool thread). }
    function WorkerStep: Boolean;
    procedure WaitForWork;
    function Stopped: Boolean;
  private
    { Enqueue one job, dropping the oldest queued job if the mailbox is full.
      Caller holds FLock. }
    procedure EnqueueLocked(const AJob: IAsyncJob);
  end;

  { SubscribeOn: run the source's Subscribe on a scheduler. }
  TSubscribeOnJob<T> = class
  private
    FSource: ISubscribable<T>;
    FDown: IObserver<T>;
  public
    constructor Create(const ASource: ISubscribable<T>; const ADown: IObserver<T>);
    procedure Run;
  end;

  TSubscribeOnObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FScheduler: IAsyncScheduler;
  public
    constructor Create(const ASource: ISubscribable<T>; const AScheduler: IAsyncScheduler);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  { ObserveOn: deliver each notification on a scheduler. }
  TObserveValue<T> = class
  public
    FDown: IObserver<T>;
    FValue: T;
    constructor Create(const ADown: IObserver<T>; const AValue: T);
    procedure Run;
  end;

  TObserveError<T> = class
  public
    FDown: IObserver<T>;
    FError: Exception;
    constructor Create(const ADown: IObserver<T>; const AError: Exception);
    procedure Run;
  end;

  TObserveComplete<T> = class
  public
    FDown: IObserver<T>;
    constructor Create(const ADown: IObserver<T>);
    procedure Run;
  end;

  TObserveOnObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FScheduler: IAsyncScheduler;
  public
    constructor Create(const ADown: IObserver<T>; const AScheduler: IAsyncScheduler);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TObserveOnObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FScheduler: IAsyncScheduler;
  public
    constructor Create(const ASource: ISubscribable<T>; const AScheduler: IAsyncScheduler);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

{ RunOn, SubscribeOn, ObserveOn (free functions). }
function RunOn(const AScheduler: IAsyncScheduler; const AWork: TNotify): ISubscription;
function SubscribeOn<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler): ISubscribable<T>;
function ObserveOn<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler): ISubscribable<T>;

implementation

{ TExecutorWorker }

constructor TExecutorWorker.Create(AOwner: TExecutorScheduler);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
end;

procedure TExecutorWorker.Execute;
begin
  while not FOwner.Stopped do
    if not FOwner.WorkerStep then
      FOwner.WaitForWork;
end;

{ TExecutorScheduler }

constructor TExecutorScheduler.Create(AConcurrency: Integer; ACapacity: Integer);
var
  I: Integer;
begin
  inherited Create;
  if AConcurrency < 1 then
    AConcurrency := 1;
  if ACapacity < 0 then
    ACapacity := 0;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, True, False, '');
  FIdle := TSimpleEvent.Create;
  FQueue := TQueue<IAsyncJob>.Create;
  FWorkers := TObjectList<TExecutorWorker>.Create(True);
  FCapacity := ACapacity;
  FDropped := 0;
  FPending := 0;
  FStopped := False;
  for I := 1 to AConcurrency do
    FWorkers.Add(TExecutorWorker.Create(Self));
  for I := 0 to FWorkers.Count - 1 do
    FWorkers[I].Start;
end;

destructor TExecutorScheduler.Destroy;
var
  I: Integer;
begin
  { Stop and join every worker, then drain whatever is left. }
  FStopped := True;
  FWake.SetEvent;
  for I := 0 to FWorkers.Count - 1 do
  begin
    FWorkers[I].WaitFor;
  end;
  FWorkers.Free;
  FQueue.Free;
  FWake.Free;
  FIdle.Free;
  FLock.Free;
  inherited;
end;

procedure TExecutorScheduler.EnqueueLocked(const AJob: IAsyncJob);
var
  Oldest: IAsyncJob;
begin
  { Bound the mailbox: when full, drop the OLDEST queued job (cancel it, so a
    worker never runs it) and count it. FPending is decremented for the drop, so
    Drain still terminates. }
  if (FCapacity > 0) and (FQueue.Count >= FCapacity) then
  begin
    Oldest := FQueue.Dequeue;
    Oldest.Unsubscribe;
    Inc(FDropped);
    Dec(FPending);
  end;
  FQueue.Enqueue(AJob);
  Inc(FPending);
end;

function TExecutorScheduler.Schedule(const AWork: TNotify;
  const ADelayMs: Integer): ISubscription;
var
  Job: IAsyncJob;
  WasEmpty: Boolean;
begin
  if ADelayMs <> 0 then
    raise EArgumentException.Create('the executor has no timer: delay must be 0');
  Job := TAsyncJob.Create(AWork);
  FLock.Acquire;
  try
    WasEmpty := FQueue.Count = 0;
    EnqueueLocked(Job);
  finally
    FLock.Release;
  end;
  { Wake a worker only on the empty -> non-empty transition. Waking on every push
    is a syscall per job and dominates the cost when jobs are queued in bulk. }
  if WasEmpty then
    FWake.SetEvent;
  Result := Job;
end;

function TExecutorScheduler.ScheduleBatch(const AWorks: TArray<TNotify>): ISubscription;
var
  I: Integer;
  Job: IAsyncJob;
  WasEmpty: Boolean;
  Last: IAsyncJob;
begin
  Last := nil;
  FLock.Acquire;
  try
    WasEmpty := FQueue.Count = 0;
    for I := 0 to High(AWorks) do
    begin
      Job := TAsyncJob.Create(AWorks[I]);
      EnqueueLocked(Job);
      Last := Job;
    end;
  finally
    FLock.Release;
  end;
  if WasEmpty and (Length(AWorks) > 0) then
    FWake.SetEvent;
  Result := Last;
end;

function TExecutorScheduler.ScheduleCancellable(const AWork: TNotify;
  out AToken: ICancellationToken): ISubscription;
var
  Job: IAsyncJob;
  WasEmpty: Boolean;
begin
  Job := TAsyncJob.Create(AWork);
  AToken := Job.Token;
  FLock.Acquire;
  try
    WasEmpty := FQueue.Count = 0;
    EnqueueLocked(Job);
  finally
    FLock.Release;
  end;
  if WasEmpty then
    FWake.SetEvent;
  Result := Job;
end;

function TExecutorScheduler.WorkerStep: Boolean;
var
  Job: IAsyncJob;
  Work: TNotify;
  Token: TContextToken;
begin
  Result := False;
  FLock.Acquire;
  try
    if FQueue.Count > 0 then
    begin
      Job := FQueue.Dequeue;
      Result := True;
    end;
  finally
    FLock.Release;
  end;
  if not Result then
  begin
    { The queue looked empty. Re-check under the lock before resetting the
      manual-reset wake, so a job enqueued in the gap is not missed: reset only
      if the queue is STILL empty. Never hold the lock across ResetEvent. }
    FLock.Acquire;
    try
      if FQueue.Count = 0 then
        FWake.ResetEvent;
    finally
      FLock.Release;
    end;
    Exit;
  end;
  Work := Job.TakeWork;
  if Assigned(Work) then
  begin
    Token := ContextEnter(Job.Snapshot);
    try
      Work();
    finally
      ContextLeave(Token);
    end;
  end;
  { Decrement under the lock, so HasPending (also under the lock) is exact and
    Drain cannot return early. }
  FLock.Acquire;
  try
    Dec(FPending);
    if FPending = 0 then
      FIdle.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TExecutorScheduler.WaitForWork;
begin
  FWake.WaitFor(ExecutorPollMs);
end;

function TExecutorScheduler.Stopped: Boolean;
begin
  Result := FStopped;
end;

procedure TExecutorScheduler.Drain;
begin
  { Wait until nothing is queued or running. Workers poll, so this cannot stall
    even if a wake-up is missed. }
  while HasPending do
    FIdle.WaitFor(ExecutorPollMs);
end;

function TExecutorScheduler.HasPending: Boolean;
begin
  FLock.Acquire;
  try
    Result := FPending > 0;
  finally
    FLock.Release;
  end;
end;

{ RunOn }

function RunOn(const AScheduler: IAsyncScheduler; const AWork: TNotify): ISubscription;
begin
  Result := AScheduler.Schedule(AWork, 0);
end;

{ SubscribeOn }

constructor TSubscribeOnJob<T>.Create(const ASource: ISubscribable<T>;
  const ADown: IObserver<T>);
begin
  inherited Create;
  FSource := ASource;
  FDown := ADown;
end;

procedure TSubscribeOnJob<T>.Run;
begin
  FSource.Subscribe(FDown);
  { One-shot: the job is only referenced by the local that scheduled it. }
  Free;
end;

constructor TSubscribeOnObservable<T>.Create(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler);
begin
  inherited Create;
  FSource := ASource;
  FScheduler := AScheduler;
end;

function TSubscribeOnObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Job: TSubscribeOnJob<T>;
begin
  Job := TSubscribeOnJob<T>.Create(FSource, AObserver);
  Result := FScheduler.Schedule(Job.Run, 0);
end;

function SubscribeOn<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler): ISubscribable<T>;
begin
  Result := TSubscribeOnObservable<T>.Create(ASource, AScheduler);
end;

{ ObserveOn }

constructor TObserveValue<T>.Create(const ADown: IObserver<T>; const AValue: T);
begin
  inherited Create;
  FDown := ADown;
  FValue := AValue;
end;

procedure TObserveValue<T>.Run;
begin
  FDown.OnNext(FValue);
  Free;
end;

constructor TObserveError<T>.Create(const ADown: IObserver<T>; const AError: Exception);
begin
  inherited Create;
  FDown := ADown;
  FError := AError;
end;

procedure TObserveError<T>.Run;
begin
  FDown.OnError(FError);
  Free;
end;

constructor TObserveComplete<T>.Create(const ADown: IObserver<T>);
begin
  inherited Create;
  FDown := ADown;
end;

procedure TObserveComplete<T>.Run;
begin
  FDown.OnComplete;
  Free;
end;

constructor TObserveOnObserver<T>.Create(const ADown: IObserver<T>;
  const AScheduler: IAsyncScheduler);
begin
  inherited Create;
  FDown := ADown;
  FScheduler := AScheduler;
end;

procedure TObserveOnObserver<T>.OnNext(const AValue: T);
begin
  FScheduler.Schedule(TObserveValue<T>.Create(FDown, AValue).Run, 0);
end;

procedure TObserveOnObserver<T>.OnError(const AError: Exception);
begin
  FScheduler.Schedule(TObserveError<T>.Create(FDown, AError).Run, 0);
end;

procedure TObserveOnObserver<T>.OnComplete;
begin
  FScheduler.Schedule(TObserveComplete<T>.Create(FDown).Run, 0);
end;

constructor TObserveOnObservable<T>.Create(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler);
begin
  inherited Create;
  FSource := ASource;
  FScheduler := AScheduler;
end;

function TObserveOnObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TObserveOnObserver<T>.Create(AObserver, FScheduler));
end;

function ObserveOn<T>(const ASource: ISubscribable<T>;
  const AScheduler: IAsyncScheduler): ISubscribable<T>;
begin
  Result := TObserveOnObservable<T>.Create(ASource, AScheduler);
end;

end.
