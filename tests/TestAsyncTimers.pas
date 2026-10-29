unit TestAsyncTimers;
{ Tests for the virtual clock and the timer schedulers (docs/features/Async_Core). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  AsyncBase, AsyncScheduler, AsyncTimers;

type
  { Logs its name; optionally schedules a follow-up on the same scheduler.
    The scheduler is held as a CLASS reference (borrowed) - never also stored in
    an interface field, which would make the interface own it and double-free. }
  TNoter = class
  public
    Log: TStringList;
    Name: string;
    Scheduler: TBaseTimerScheduler;
    Follow: TNoter;
    FollowDelayMs: Integer;
    procedure Note;
  end;

  TAsyncTimersTest = class(TTestCase)
  private
    FLog: TStringList;
    function MakeNoter(const AName: string): TNoter;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure RunsImmediatelyOnDrain;
    procedure DoesNotRunBeforeDue;
    procedure AdvanceRunsDue;
    procedure AdvanceRunsInDueOrder;
    procedure FifoForEqualDue;
    procedure NestedTimerRunsInAdvance;
    procedure AdvanceMovesNow;
    procedure NegativeDelayRaises;
    procedure NegativeAdvanceRaises;
    procedure UnsubscribeCancelsTimer;
    procedure HasPending;
  end;

implementation

procedure TNoter.Note;
begin
  Log.Add(Name);
  if (Scheduler <> nil) and (Follow <> nil) then
    Scheduler.Schedule(Follow.Note, FollowDelayMs);
end;

{ TAsyncTimersTest }

procedure TAsyncTimersTest.SetUp;
begin
  FLog := TStringList.Create;
end;

procedure TAsyncTimersTest.TearDown;
begin
  FLog.Free;
end;

function TAsyncTimersTest.MakeNoter(const AName: string): TNoter;
begin
  Result := TNoter.Create;
  Result.Log := FLog;
  Result.Name := AName;
end;

procedure TAsyncTimersTest.RunsImmediatelyOnDrain;
var
  S: TVirtualScheduler;
  A: TNoter;
begin
  S := TVirtualScheduler.Create;
  A := MakeNoter('A');
  try
    S.Schedule(A.Note, 0);
    S.Drain;
    AssertEquals('A', FLog.CommaText);
  finally
    A.Free;
    S.Free;
  end;
end;

procedure TAsyncTimersTest.DoesNotRunBeforeDue;
var
  S: TVirtualScheduler;
  A: TNoter;
begin
  S := TVirtualScheduler.Create;
  A := MakeNoter('A');
  try
    S.Schedule(A.Note, 10);
    S.Drain;
    AssertEquals('a future timer does not run on Drain', '', FLog.CommaText);
  finally
    A.Free;
    S.Free;
  end;
end;

procedure TAsyncTimersTest.AdvanceRunsDue;
var
  S: TVirtualScheduler;
  A: TNoter;
begin
  S := TVirtualScheduler.Create;
  A := MakeNoter('A');
  try
    S.Schedule(A.Note, 10);
    S.Advance(10);
    AssertEquals('A', FLog.CommaText);
  finally
    A.Free;
    S.Free;
  end;
end;

procedure TAsyncTimersTest.AdvanceRunsInDueOrder;
var
  S: TVirtualScheduler;
  A, B: TNoter;
begin
  S := TVirtualScheduler.Create;
  A := MakeNoter('A');
  B := MakeNoter('B');
  try
    S.Schedule(A.Note, 10);
    S.Schedule(B.Note, 5);
    S.Advance(10);
    AssertEquals('earliest due first', 'B,A', FLog.CommaText);
  finally
    A.Free;
    B.Free;
    S.Free;
  end;
end;

procedure TAsyncTimersTest.FifoForEqualDue;
var
  S: TVirtualScheduler;
  A, B: TNoter;
begin
  S := TVirtualScheduler.Create;
  A := MakeNoter('A');
  B := MakeNoter('B');
  try
    S.Schedule(A.Note, 5);
    S.Schedule(B.Note, 5);
    S.Advance(5);
    AssertEquals('registration order breaks the tie', 'A,B', FLog.CommaText);
  finally
    A.Free;
    B.Free;
    S.Free;
  end;
end;

procedure TAsyncTimersTest.NestedTimerRunsInAdvance;
var
  S: TVirtualScheduler;
  A, B: TNoter;
begin
  S := TVirtualScheduler.Create;
  A := MakeNoter('A');
  B := MakeNoter('B');
  try
    A.Scheduler := S;
    A.Follow := B;
    A.FollowDelayMs := 0;
    S.Schedule(A.Note, 5);
    S.Advance(5);
    AssertEquals('the timer A scheduled while running also fired', 'A,B',
      FLog.CommaText);
  finally
    A.Free;
    B.Free;
    S.Free;
  end;
end;

procedure TAsyncTimersTest.AdvanceMovesNow;
var
  S: TVirtualScheduler;
begin
  S := TVirtualScheduler.Create;
  try
    AssertEquals('starts at zero', 0, S.Now);
    S.Advance(250);
    AssertEquals('moved', 250, S.Now);
  finally
    S.Free;
  end;
end;

procedure TAsyncTimersTest.NegativeDelayRaises;
var
  S: TVirtualScheduler;
  A: TNoter;
  Raised: Boolean;
begin
  S := TVirtualScheduler.Create;
  A := MakeNoter('A');
  try
    Raised := False;
    try
      S.Schedule(A.Note, -1);
    except
      on E: EArgumentException do
        Raised := True;
    end;
    AssertTrue('negative delay rejected', Raised);
  finally
    A.Free;
    S.Free;
  end;
end;

procedure TAsyncTimersTest.NegativeAdvanceRaises;
var
  S: TVirtualScheduler;
  Raised: Boolean;
begin
  S := TVirtualScheduler.Create;
  try
    Raised := False;
    try
      S.Advance(-1);
    except
      on E: EArgumentException do
        Raised := True;
    end;
    AssertTrue('negative advance rejected', Raised);
  finally
    S.Free;
  end;
end;

procedure TAsyncTimersTest.UnsubscribeCancelsTimer;
var
  S: TVirtualScheduler;
  A: TNoter;
  Sub: ISubscription;
begin
  S := TVirtualScheduler.Create;
  A := MakeNoter('A');
  try
    Sub := S.Schedule(A.Note, 10);
    Sub.Unsubscribe;
    S.Advance(10);
    AssertEquals('cancelled timer did not run', '', FLog.CommaText);
  finally
    A.Free;
    S.Free;
  end;
end;

procedure TAsyncTimersTest.HasPending;
var
  S: TVirtualScheduler;
  A: TNoter;
begin
  S := TVirtualScheduler.Create;
  A := MakeNoter('A');
  try
    AssertFalse('empty', S.HasPending);
    S.Schedule(A.Note, 10);
    AssertTrue('queued', S.HasPending);
    S.Advance(10);
    AssertFalse('fired', S.HasPending);
  finally
    A.Free;
    S.Free;
  end;
end;

initialization
  RegisterTest(TAsyncTimersTest);
end.
