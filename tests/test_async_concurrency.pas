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
  Classes, SysUtils, fpcunit, testregistry,
  async.base, async.observable, async.operators, async.scheduler,
  async.concurrency;

type
  TAsyncConcurrencyTest = class(TTestCase)
  private
    FSeq: string;
    FRan: Integer;
    FThreadId: TThreadID;
    FRanOnWorker: Boolean;
    procedure NoteThread;
    procedure BumpRan;
  published
    procedure ExecutorRunsWorkOnAPoolThread;
    procedure ExecutorJoinsThreadsOnShutdown;
    procedure RunOnSchedulesWork;
    procedure SubscribeOnRunsSubscribeOnTheScheduler;
    procedure ObserveOnDeliversNotificationsOnTheScheduler;
  end;

implementation

procedure TAsyncConcurrencyTest.NoteThread;
begin
  FThreadId := GetCurrentThreadId;
  FRanOnWorker := True;
end;

procedure TAsyncConcurrencyTest.BumpRan;
begin
  Inc(FRan);
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
