unit TestAsyncSubject;
{ Tests for the subjects (docs/features/Async_Core). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  AsyncBase, AsyncObservable, AsyncSubject;

type
  TAsyncSubjectTest = class(TTestCase)
  private
    FNexts: Integer;
    FSum: Integer;
    FCompletes: Integer;
    FErrorMsg: string;
    function CountingObserver: IObserver<Integer>;
  published
    procedure SubjectMulticasts;
    procedure SubjectLateSubscriberSeesOnlyNew;
    procedure SubjectUnsubscribeRemovesSubscriber;
    procedure SubjectCompletesOnce;
    procedure BehaviorSubjectReplaysCurrent;
    procedure ReplaySubjectReplaysBuffer;
    procedure ReplaySubjectCapacityBounds;
    procedure AsyncSubjectEmitsLastOnComplete;
    procedure AsyncSubjectLateSubscriberGetsLast;
  end;

implementation

function TAsyncSubjectTest.CountingObserver: IObserver<Integer>;
begin
  Result := TObserver<Integer>.Create(
    procedure(const AValue: Integer)
    begin
      Inc(FNexts);
      FSum := FSum + AValue;
    end,
    procedure(const AError: Exception)
    begin
      FErrorMsg := AError.Message;
      AError.Free;
    end,
    procedure
    begin
      Inc(FCompletes);
    end);
end;

procedure TAsyncSubjectTest.SubjectMulticasts;
var
  S: TSubject<Integer>;
begin
  S := TSubject<Integer>.Create;
  try
    S.Subscribe(CountingObserver);
    S.Subscribe(CountingObserver);
    S.OnNext(1);
    S.OnNext(2);
    AssertEquals('both subscribers saw two values', 4, FNexts);
    AssertEquals('sum', 6, FSum);
  finally
    S.Free;
  end;
end;

procedure TAsyncSubjectTest.SubjectLateSubscriberSeesOnlyNew;
var
  S: TSubject<Integer>;
begin
  S := TSubject<Integer>.Create;
  try
    S.OnNext(1);   { before any subscriber: lost }
    S.Subscribe(CountingObserver);
    S.OnNext(2);
    AssertEquals('only the post-subscribe value', 1, FNexts);
    AssertEquals('value', 2, FSum);
  finally
    S.Free;
  end;
end;

procedure TAsyncSubjectTest.SubjectUnsubscribeRemovesSubscriber;
var
  S: TSubject<Integer>;
  Sub: ISubscription;
begin
  S := TSubject<Integer>.Create;
  try
    Sub := S.Subscribe(CountingObserver);
    S.OnNext(1);
    Sub.Unsubscribe;
    S.OnNext(2);
    AssertEquals('stopped after unsubscribe', 1, FNexts);
  finally
    S.Free;
  end;
end;

procedure TAsyncSubjectTest.SubjectCompletesOnce;
var
  S: TSubject<Integer>;
begin
  S := TSubject<Integer>.Create;
  try
    S.Subscribe(CountingObserver);
    S.OnComplete;
    S.OnComplete;   { ignored }
    S.OnNext(1);    { ignored after terminal }
    AssertEquals('completed once', 1, FCompletes);
    AssertEquals('no value after complete', 0, FNexts);
  finally
    S.Free;
  end;
end;

procedure TAsyncSubjectTest.BehaviorSubjectReplaysCurrent;
var
  S: TBehaviorSubject<Integer>;
begin
  S := TBehaviorSubject<Integer>.Create(10);
  try
    S.Subscribe(CountingObserver);   { gets 10 immediately }
    S.OnNext(20);
    AssertEquals('current then new', 2, FNexts);
    AssertEquals('sum', 30, FSum);
    AssertEquals('holds the latest', 20, S.Value);
  finally
    S.Free;
  end;
end;

procedure TAsyncSubjectTest.ReplaySubjectReplaysBuffer;
var
  S: TReplaySubject<Integer>;
begin
  S := TReplaySubject<Integer>.Create;   { unbounded }
  try
    S.OnNext(1);
    S.OnNext(2);
    S.Subscribe(CountingObserver);   { replays 1, 2 }
    S.OnNext(3);
    AssertEquals('replayed two plus the new one', 3, FNexts);
    AssertEquals('sum', 6, FSum);
  finally
    S.Free;
  end;
end;

procedure TAsyncSubjectTest.ReplaySubjectCapacityBounds;
var
  S: TReplaySubject<Integer>;
begin
  S := TReplaySubject<Integer>.Create(2);
  try
    S.OnNext(1);
    S.OnNext(2);
    S.OnNext(3);   { 1 falls out of the 2-slot buffer }
    S.Subscribe(CountingObserver);
    AssertEquals('only the last two replayed', 2, FNexts);
    AssertEquals('values 2 and 3', 5, FSum);
  finally
    S.Free;
  end;
end;

procedure TAsyncSubjectTest.AsyncSubjectEmitsLastOnComplete;
var
  S: TAsyncSubject<Integer>;
begin
  S := TAsyncSubject<Integer>.Create;
  try
    S.Subscribe(CountingObserver);
    S.OnNext(1);
    S.OnNext(2);
    AssertEquals('nothing until complete', 0, FNexts);
    S.OnComplete;
    AssertEquals('last value only', 1, FNexts);
    AssertEquals('value', 2, FSum);
    AssertEquals('completed', 1, FCompletes);
  finally
    S.Free;
  end;
end;

procedure TAsyncSubjectTest.AsyncSubjectLateSubscriberGetsLast;
var
  S: TAsyncSubject<Integer>;
begin
  S := TAsyncSubject<Integer>.Create;
  try
    S.OnNext(5);
    S.OnComplete;
    S.Subscribe(CountingObserver);   { late: gets 5 then complete }
    AssertEquals('the last value', 1, FNexts);
    AssertEquals('value', 5, FSum);
    AssertEquals('completed', 1, FCompletes);
  finally
    S.Free;
  end;
end;

initialization
  RegisterTest(TAsyncSubjectTest);
end.
