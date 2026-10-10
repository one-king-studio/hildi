unit test_async_time;
{ Tests for the time-based operators (docs/features/Async_Core). A
  TVirtualScheduler drives time, so there are no sleeps: Advance moves the clock
  and runs whatever became due.

  A subject is held as a local TSubject<Integer> (an object reference); the
  operators keep their own interface reference to it, so the tests never Free it
  directly. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  async.base, async.observable, async.operators, async.scheduler,
  async.timers, async.subject, async.time;

type
  TAsyncTimeTest = class(TTestCase)
  private
    FSeq: string;
    FCompletes: Integer;
    function Recorder: IObserver<Integer>;
    procedure Add(const S: string);
  published
    procedure TimerFiresAfterTheDelay;
    procedure IntervalEmitsUntilUnsubscribed;
    procedure DelayShiftsValuesAndCompletion;
    procedure DebounceTimeEmitsOnlyAfterQuiet;
    procedure ThrottleTimeEmitsTheLeadingValue;
    procedure SampleTimeEmitsTheLatestPerPeriod;
  end;

implementation

procedure TAsyncTimeTest.Add(const S: string);
begin
  if FSeq <> '' then
    FSeq := FSeq + ',';
  FSeq := FSeq + S;
end;

function TAsyncTimeTest.Recorder: IObserver<Integer>;
begin
  Result := TObserver<Integer>.Create(
    procedure(const V: Integer) begin Add(IntToStr(V)); end,
    procedure(const E: Exception) begin end,
    procedure begin Inc(FCompletes); end);
end;

procedure TAsyncTimeTest.TimerFiresAfterTheDelay;
var
  S: IVirtualScheduler;
  Sub: ISubscription;
begin
  FSeq := '';
  FCompletes := 0;
  S := TVirtualScheduler.Create as IVirtualScheduler;
  Sub := Timer(S, 100).Subscribe(Recorder);
  S.Advance(50);
  AssertEquals('not yet', '', FSeq);
  S.Advance(50);
  AssertEquals('fired once', '0', FSeq);
  AssertEquals('completed', 1, FCompletes);
end;

procedure TAsyncTimeTest.IntervalEmitsUntilUnsubscribed;
var
  S: IVirtualScheduler;
  Sub: ISubscription;
begin
  FSeq := '';
  FCompletes := 0;
  S := TVirtualScheduler.Create as IVirtualScheduler;
  Sub := Interval(S, 10).Subscribe(Recorder);
  S.Advance(35);
  AssertEquals('three ticks', '0,1,2', FSeq);
  Sub.Unsubscribe;
  S.Advance(100);
  AssertEquals('stopped after unsubscribe', '0,1,2', FSeq);
end;

procedure TAsyncTimeTest.DelayShiftsValuesAndCompletion;
var
  S: IVirtualScheduler;
begin
  FSeq := '';
  FCompletes := 0;
  S := TVirtualScheduler.Create as IVirtualScheduler;
  Delay<Integer>(Range(1, 3), S, 20).Subscribe(Recorder);
  AssertEquals('nothing before the delay', '', FSeq);
  S.Advance(20);
  AssertEquals('values after the delay', '1,2,3', FSeq);
  AssertEquals('completed after the delay', 1, FCompletes);
end;

procedure TAsyncTimeTest.DebounceTimeEmitsOnlyAfterQuiet;
var
  S: IVirtualScheduler;
  Obs: TSubject<Integer>;
begin
  FSeq := '';
  FCompletes := 0;
  S := TVirtualScheduler.Create as IVirtualScheduler;
  Obs := TSubject<Integer>.Create;
  DebounceTime<Integer>(Obs, S, 30).Subscribe(Recorder);
  Obs.OnNext(1);
  S.Advance(10);      { 1 is still pending }
  Obs.OnNext(2);      { resets the timer }
  S.Advance(10);      { still pending }
  AssertEquals('nothing emitted while active', '', FSeq);
  S.Advance(30);      { quiet for 30ms }
  AssertEquals('only the latest survived', '2', FSeq);
  Obs.Free;
end;

procedure TAsyncTimeTest.ThrottleTimeEmitsTheLeadingValue;
var
  S: IVirtualScheduler;
  Obs: TSubject<Integer>;
begin
  FSeq := '';
  FCompletes := 0;
  S := TVirtualScheduler.Create as IVirtualScheduler;
  Obs := TSubject<Integer>.Create;
  ThrottleTime<Integer>(Obs, S, 30).Subscribe(Recorder);
  Obs.OnNext(1);      { leading value: emitted, gate closes }
  Obs.OnNext(2);      { within the window: ignored }
  Obs.OnNext(3);      { ignored }
  AssertEquals('only the leading value', '1', FSeq);
  S.Advance(30);      { window reopens }
  Obs.OnNext(4);      { emitted }
  AssertEquals('emitted after the window', '1,4', FSeq);
  Obs.Free;
end;

procedure TAsyncTimeTest.SampleTimeEmitsTheLatestPerPeriod;
var
  S: IVirtualScheduler;
  Obs: TSubject<Integer>;
begin
  FSeq := '';
  FCompletes := 0;
  S := TVirtualScheduler.Create as IVirtualScheduler;
  Obs := TSubject<Integer>.Create;
  SampleTime<Integer>(Obs, S, 20).Subscribe(Recorder);
  Obs.OnNext(1);
  Obs.OnNext(2);
  S.Advance(20);      { tick: emits the latest, 2 }
  AssertEquals('latest at the tick', '2', FSeq);
  Obs.OnNext(3);
  S.Advance(20);      { tick: emits 3 }
  AssertEquals('latest again', '2,3', FSeq);
  S.Advance(20);      { tick with nothing new: no emission }
  AssertEquals('no emission without a new value', '2,3', FSeq);
  Obs.Free;
end;

initialization
  RegisterTest(TAsyncTimeTest);
end.
