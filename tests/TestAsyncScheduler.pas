unit TestAsyncScheduler;
{ Tests for the Async Core scheduler (docs/features/Async_Core). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  AsyncBase, AsyncScheduler;

type
  { A parameterless continuation that logs its name; optionally it schedules a
    follow-up on the same scheduler, to exercise re-entrancy. }
  TNoter = class
  public
    Log: TStringList;
    Name: string;
    Scheduler: IAsyncScheduler;
    Follow: TNoter;
    procedure Note;
  end;

  { Counts its runs and drains the scheduler from inside, to prove a nested
    drain never re-runs the in-flight job. }
  TCounter = class
  public
    Count: Integer;
    Scheduler: IAsyncScheduler;
    procedure Bump;
  end;

  TAsyncSchedulerTest = class(TTestCase)
  private
    FLog: TStringList;
    function MakeNoter(const AName: string): TNoter;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure QueueRunsFifo;
    procedure QueueFlattensRecursion;
    procedure AsapDefersUntilDrain;
    procedure AsapDrainsToQuiescence;
    procedure NestedDrainDoesNotRerun;
    procedure UnsubscribeCancelsQueuedWork;
    procedure UnsubscribeAfterRunIsSafe;
    procedure PositiveDelayRaises;
    procedure HasPendingReflectsQueue;
  end;

implementation

procedure TNoter.Note;
begin
  Log.Add(Name);
  if (Scheduler <> nil) and (Follow <> nil) then
    Scheduler.Schedule(Follow.Note, 0);
end;

procedure TCounter.Bump;
begin
  Inc(Count);
  Scheduler.Drain;
end;

{ TAsyncSchedulerTest }

procedure TAsyncSchedulerTest.SetUp;
begin
  FLog := TStringList.Create;
end;

procedure TAsyncSchedulerTest.TearDown;
begin
  FLog.Free;
end;

function TAsyncSchedulerTest.MakeNoter(const AName: string): TNoter;
begin
  Result := TNoter.Create;
  Result.Log := FLog;
  Result.Name := AName;
end;

procedure TAsyncSchedulerTest.QueueRunsFifo;
var
  S: IAsyncScheduler;
  A, B, C: TNoter;
begin
  S := TQueueScheduler.Create;
  A := MakeNoter('A');
  B := MakeNoter('B');
  C := MakeNoter('C');
  try
    S.Schedule(A.Note, 0);
    S.Schedule(B.Note, 0);
    S.Schedule(C.Note, 0);
    AssertEquals('A,B,C', FLog.CommaText);
  finally
    A.Free;
    B.Free;
    C.Free;
  end;
end;

procedure TAsyncSchedulerTest.QueueFlattensRecursion;
var
  S: IAsyncScheduler;
  A, B: TNoter;
begin
  S := TQueueScheduler.Create;
  A := MakeNoter('A');
  B := MakeNoter('B');
  try
    A.Scheduler := S;
    A.Follow := B;
    S.Schedule(A.Note, 0);
    { B was scheduled from inside A's run and ran in the same drain. }
    AssertEquals('A,B', FLog.CommaText);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TAsyncSchedulerTest.AsapDefersUntilDrain;
var
  S: IAsyncScheduler;
  A: TNoter;
begin
  S := TAsapScheduler.Create;
  A := MakeNoter('A');
  try
    S.Schedule(A.Note, 0);
    AssertEquals('nothing runs before Drain', '', FLog.CommaText);
    S.Drain;
    AssertEquals('A', FLog.CommaText);
  finally
    A.Free;
  end;
end;

procedure TAsyncSchedulerTest.AsapDrainsToQuiescence;
var
  S: IAsyncScheduler;
  A, B: TNoter;
begin
  S := TAsapScheduler.Create;
  A := MakeNoter('A');
  B := MakeNoter('B');
  try
    A.Scheduler := S;
    A.Follow := B;
    S.Schedule(A.Note, 0);
    S.Drain;
    AssertEquals('A,B', FLog.CommaText);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TAsyncSchedulerTest.NestedDrainDoesNotRerun;
var
  S: IAsyncScheduler;
  C: TCounter;
begin
  S := TAsapScheduler.Create;
  C := TCounter.Create;
  try
    C.Scheduler := S;
    S.Schedule(C.Bump, 0);
    S.Schedule(C.Bump, 0);
    S.Drain;
    { Each job drained from inside; the head index means neither re-ran. }
    AssertEquals('each job ran once', 2, C.Count);
  finally
    C.Free;
  end;
end;

procedure TAsyncSchedulerTest.UnsubscribeCancelsQueuedWork;
var
  S: IAsyncScheduler;
  A: TNoter;
  Sub: ISubscription;
begin
  S := TAsapScheduler.Create;
  A := MakeNoter('A');
  try
    Sub := S.Schedule(A.Note, 0);
    Sub.Unsubscribe;
    S.Drain;
    AssertEquals('cancelled work did not run', '', FLog.CommaText);
    AssertTrue('subscription is closed', Sub.Closed);
  finally
    A.Free;
  end;
end;

procedure TAsyncSchedulerTest.UnsubscribeAfterRunIsSafe;
var
  S: IAsyncScheduler;
  A: TNoter;
  Sub: ISubscription;
begin
  S := TAsapScheduler.Create;
  A := MakeNoter('A');
  try
    Sub := S.Schedule(A.Note, 0);
    S.Drain;
    Sub.Unsubscribe;
    AssertEquals('A', FLog.CommaText);
  finally
    A.Free;
  end;
end;

procedure TAsyncSchedulerTest.PositiveDelayRaises;
var
  S: IAsyncScheduler;
  A: TNoter;
  Raised: Boolean;
begin
  S := TAsapScheduler.Create;
  A := MakeNoter('A');
  try
    Raised := False;
    try
      S.Schedule(A.Note, 5);
    except
      on E: EArgumentException do
        Raised := True;
    end;
    AssertTrue('a non-timer scheduler rejects a positive delay', Raised);
  finally
    A.Free;
  end;
end;

procedure TAsyncSchedulerTest.HasPendingReflectsQueue;
var
  S: IAsyncScheduler;
  A: TNoter;
begin
  S := TAsapScheduler.Create;
  A := MakeNoter('A');
  try
    AssertFalse('empty', S.HasPending);
    S.Schedule(A.Note, 0);
    AssertTrue('queued', S.HasPending);
    S.Drain;
    AssertFalse('drained', S.HasPending);
  finally
    A.Free;
  end;
end;

initialization
  RegisterTest(TAsyncSchedulerTest);
end.
