unit test_async_concurrency;
{ Tests for the executor scheduler and the concurrency operators
  (docs/features/Async_Core). Threads are joined on shutdown; Drain waits for
  quiescence, so the tests are deterministic without sleeps.

  The executor is held as an IAsyncScheduler (an operator keeps a reference to
  it, so a raw Free would double-free). The scheduler takes a TNotify (a method),
  so scheduled work uses small named methods; observer callbacks are `reference
  to`, so those stay anonymous. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry,
  async.base, async.observable, async.operators, async.scheduler,
  async.concurrency;

type
  TAsyncConcurrencyTest = class(TTestCase)
  private
    FSeq: string;
    FRan: Integer;
    FRanLock: TCriticalSection;
    FThreadId: TThreadID;
    FRanOnWorker: Boolean;
    FGate: TSimpleEvent;
    FStarted: Integer;
    FStopped: Boolean;
    FTok: ICancellationToken;
    procedure NoteThread;
    procedure BumpRan;
    procedure BlockOnGate;
    procedure PollUntilCancelled;
  published
    procedure ExecutorRunsWorkOnAPoolThread;
    procedure ExecutorJoinsThreadsOnShutdown;
    procedure ExecutorRunsManyJobsAcrossWorkers;
    procedure ExecutorScheduleBatchRunsEveryJob;
    procedure ExecutorBoundedMailboxDropsOldest;
    procedure ExecutorInFlightCancellationTripsTheToken;
    procedure ExecutorUnsubscribeCancelsAQueuedJob;
    procedure RunOnSchedulesWork;
    procedure SubscribeOnRunsSubscribeOnTheScheduler;
    procedure ObserveOnDeliversNotificationsOnTheScheduler;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  end;

implementation

procedure TAsyncConcurrencyTest.SetUp;
begin
  FRanLock := TCriticalSection.Create;
end;

procedure TAsyncConcurrencyTest.TearDown;
begin
  FRanLock.Free;
end;

procedure TAsyncConcurrencyTest.NoteThread;
begin
  FThreadId := GetCurrentThreadId;
  FRanOnWorker := True;
end;

procedure TAsyncConcurrencyTest.BumpRan;
begin
  { A shared counter mutated from several workers; guard it. }
  FRanLock.Acquire;
  try
    Inc(FRan);
  finally
    FRanLock.Release;
  end;
end;

procedure TAsyncConcurrencyTest.BlockOnGate;
begin
  FGate.WaitFor(5000);
end;

procedure TAsyncConcurrencyTest.PollUntilCancelled;
begin
  InterlockedIncrement(FStarted);
  while not FTok.IsCancelled do
    Sleep(1);
  FStopped := True;
end;

procedure TAsyncConcurrencyTest.ExecutorRunsWorkOnAPoolThread;
var
  Exec: IAsyncScheduler;
  E: TExecutorScheduler;
  Main: TThreadID;
begin
  FRanOnWorker := False;
  Main := GetCurrentThreadId;
  E := TExecutorScheduler.Create(2); Exec := E;
  Exec.Schedule(NoteThread, 0);
  Exec.Drain;
  AssertTrue('the work ran', FRanOnWorker);
  AssertTrue('on a pool thread, not the caller', FThreadId <> Main);
end;

procedure TAsyncConcurrencyTest.ExecutorJoinsThreadsOnShutdown;
var
  Exec: IAsyncScheduler;
  E: TExecutorScheduler;
begin
  FRan := 0;
  E := TExecutorScheduler.Create(3); Exec := E;
  { Schedule a few jobs; the executor joins every thread when it is released. }
  Exec.Schedule(BumpRan, 0);
  Exec.Schedule(BumpRan, 0);
  Exec.Drain;
  Exec := nil;
  AssertEquals('both jobs ran', 2, FRan);
end;

procedure TAsyncConcurrencyTest.ExecutorRunsManyJobsAcrossWorkers;
var
  Exec: IAsyncScheduler;
  E: TExecutorScheduler;
  I: Integer;
begin
  { Many jobs across several workers: this exercises the context install/restore
    on the worker threads. A process-global context here raced and wedged Drain. }
  FRan := 0;
  E := TExecutorScheduler.Create(4);
  Exec := E;
  for I := 1 to 5000 do
    Exec.Schedule(BumpRan, 0);
  Exec.Drain;
  AssertEquals('every job ran', 5000, FRan);
end;

procedure TAsyncConcurrencyTest.ExecutorScheduleBatchRunsEveryJob;
var
  Exec: IAsyncScheduler;
  E: TExecutorScheduler;
  Works: TArray<TNotify>;
  I: Integer;
begin
  FRan := 0;
  SetLength(Works, 2000);
  for I := 0 to High(Works) do
    Works[I] := BumpRan;
  E := TExecutorScheduler.Create(4);
  Exec := E;
  { ScheduleBatch is an executor method, not part of IAsyncScheduler. }
  E.ScheduleBatch(Works);
  Exec.Drain;
  AssertEquals('every batched job ran', 2000, FRan);
end;

procedure TAsyncConcurrencyTest.ExecutorBoundedMailboxDropsOldest;
var
  Exec: IAsyncScheduler;
  E: TExecutorScheduler;
  I: Integer;
begin
  { One worker, blocked on a gate, so the queue fills while nothing drains. }
  FGate := TSimpleEvent.Create;
  try
    E := TExecutorScheduler.Create(1, 2);   { capacity 2 }
    Exec := E;
    { The first job occupies the only worker until the gate is set. }
    Exec.Schedule(BlockOnGate, 0);
    { Give the worker a moment to claim the blocking job, then overflow. }
    Sleep(50);
    for I := 1 to 10 do
      Exec.Schedule(BumpRan, 0);
    AssertTrue('the mailbox dropped the oldest jobs', E.Dropped > 0);
    FGate.SetEvent;
    Exec.Drain;
  finally
    FGate.Free;
  end;
end;

procedure TAsyncConcurrencyTest.ExecutorInFlightCancellationTripsTheToken;
var
  Exec: IAsyncScheduler;
  E: TExecutorScheduler;
  Sub: ISubscription;
begin
  FStarted := 0;
  FStopped := False;
  E := TExecutorScheduler.Create(1);
  Exec := E;
  { A long job that polls its token; Unsubscribe trips it and the job stops. }
  Sub := E.ScheduleCancellable(PollUntilCancelled, FTok);
  { Wait for the worker to start the job, then cancel in flight. }
  while FStarted = 0 do
    Sleep(1);
  Sub.Unsubscribe;
  Exec.Drain;
  AssertTrue('the running job saw the cancellation', FStopped);
end;

procedure TAsyncConcurrencyTest.ExecutorUnsubscribeCancelsAQueuedJob;
var
  Exec: IAsyncScheduler;
  E: TExecutorScheduler;
  Sub: ISubscription;
begin
  { One worker blocked on the gate, so the second job stays QUEUED; cancelling
    it before a worker claims it must skip the work entirely (the CAS Pending ->
    Cancelled path, the other half of the in-flight story). }
  FRan := 0;
  FGate := TSimpleEvent.Create;
  try
    E := TExecutorScheduler.Create(1);
    Exec := E;
    Exec.Schedule(BlockOnGate, 0);        { occupies the only worker }
    Sleep(50);                            { let the worker claim the blocker }
    Sub := Exec.Schedule(BumpRan, 0);     { queued, cannot start yet }
    Sub.Unsubscribe;                      { cancel before it is taken }
    FGate.SetEvent;
    Exec.Drain;
    AssertEquals('the cancelled job never ran', 0, FRan);
  finally
    FGate.Free;
  end;
end;

procedure TAsyncConcurrencyTest.RunOnSchedulesWork;
var
  Exec: IAsyncScheduler;
  E: TExecutorScheduler;
begin
  FRan := 0;
  E := TExecutorScheduler.Create(1); Exec := E;
  RunOn(Exec, BumpRan);
  Exec.Drain;
  AssertEquals('work ran', 1, FRan);
end;

procedure TAsyncConcurrencyTest.SubscribeOnRunsSubscribeOnTheScheduler;
var
  Exec: IAsyncScheduler;
  E: TExecutorScheduler;
  Main: TThreadID;
begin
  FSeq := '';
  FRanOnWorker := False;
  Main := GetCurrentThreadId;
  E := TExecutorScheduler.Create(1); Exec := E;
  { The source's Subscribe is deferred to the pool; the values still arrive, on
    a pool thread. }
  SubscribeOn<Integer>(FromArray<Integer>([1, 2, 3]), Exec).Subscribe(
    TObserver<Integer>.Create(
      procedure(const V: Integer)
      begin
        FThreadId := GetCurrentThreadId;
        FRanOnWorker := True;
        FSeq := FSeq + IntToStr(V);
      end));
  Exec.Drain;
  AssertEquals('values delivered', '123', FSeq);
  AssertTrue('Subscribe ran off the calling thread', FThreadId <> Main);
end;

procedure TAsyncConcurrencyTest.ObserveOnDeliversNotificationsOnTheScheduler;
var
  Exec: IAsyncScheduler;
  E: TExecutorScheduler;
  Main: TThreadID;
begin
  FSeq := '';
  FRanOnWorker := False;
  Main := GetCurrentThreadId;
  E := TExecutorScheduler.Create(1); Exec := E;
  { The source is synchronous; ObserveOn moves each notification to the pool. }
  ObserveOn<Integer>(FromArray<Integer>([1, 2, 3]), Exec).Subscribe(
    TObserver<Integer>.Create(
      procedure(const V: Integer)
      begin
        FThreadId := GetCurrentThreadId;
        FRanOnWorker := True;
        FSeq := FSeq + IntToStr(V);
      end));
  Exec.Drain;
  AssertEquals('values delivered', '123', FSeq);
  AssertTrue('notifications ran off the calling thread', FThreadId <> Main);
end;

initialization
  RegisterTest(TAsyncConcurrencyTest);
end.
