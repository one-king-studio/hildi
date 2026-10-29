unit TestAsyncObservable;
{ Tests for TObservable<T> and the subscriber contract (docs/features/Async_Core). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  AsyncBase, AsyncObservable;

type
  TAsyncObservableTest = class(TTestCase)
  private
    FNexts: Integer;
    FSum: Integer;
    FCompletes: Integer;
    FErrorMsg: string;
    function CountingObserver: IObserver<Integer>;
  published
    procedure NotRunBeforeSubscribe;
    procedure TwoSubscribersRunTheSourceTwice;
    procedure UnsubscribeTearsDownUpstream;
    procedure TerminalIsDeliveredOnce;
    procedure LateNextAfterTerminalIsIgnored;
    procedure ErrorIsDeliveredAsOnError;
  end;

implementation

function TAsyncObservableTest.CountingObserver: IObserver<Integer>;
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

procedure TAsyncObservableTest.NotRunBeforeSubscribe;
var
  Runs: Integer;
  Obs: TObservable<Integer>;
begin
  Runs := 0;
  Obs := TObservable<Integer>.Create(
    function(const AObserver: IObserver<Integer>): ISubscription
    begin
      Inc(Runs);
      AObserver.OnNext(7);
      AObserver.OnComplete;
      Result := TClosureSubscription.Create(nil);
    end);
  try
    AssertEquals('cold: not run until subscribed', 0, Runs);
    Obs.Subscribe(CountingObserver);
    AssertEquals('ran once on subscribe', 1, Runs);
    AssertEquals('value delivered', 7, FSum);
    AssertEquals('completed', 1, FCompletes);
  finally
    Obs.Free;
  end;
end;

procedure TAsyncObservableTest.TwoSubscribersRunTheSourceTwice;
var
  Runs: Integer;
  Obs: TObservable<Integer>;
begin
  Runs := 0;
  Obs := TObservable<Integer>.Create(
    function(const AObserver: IObserver<Integer>): ISubscription
    begin
      Inc(Runs);
      AObserver.OnNext(1);
      AObserver.OnComplete;
      Result := TClosureSubscription.Create(nil);
    end);
  try
    Obs.Subscribe(CountingObserver);
    Obs.Subscribe(CountingObserver);
    AssertEquals('cold: two subscribers, two runs', 2, Runs);
  finally
    Obs.Free;
  end;
end;

procedure TAsyncObservableTest.UnsubscribeTearsDownUpstream;
var
  Torn: Integer;
  Obs: TObservable<Integer>;
  Sub: ISubscription;
begin
  Torn := 0;
  Obs := TObservable<Integer>.Create(
    function(const AObserver: IObserver<Integer>): ISubscription
    begin
      Result := TClosureSubscription.Create(
        procedure
        begin
          Inc(Torn);
        end);
    end);
  try
    Sub := Obs.Subscribe(CountingObserver);
    AssertEquals('not torn yet', 0, Torn);
    Sub.Unsubscribe;
    AssertEquals('torn down', 1, Torn);
  finally
    Obs.Free;
  end;
end;

procedure TAsyncObservableTest.TerminalIsDeliveredOnce;
var
  Obs: TObservable<Integer>;
begin
  Obs := TObservable<Integer>.Create(
    function(const AObserver: IObserver<Integer>): ISubscription
    begin
      AObserver.OnComplete;
      AObserver.OnComplete;   { a contract violation: the second is suppressed }
      Result := TClosureSubscription.Create(nil);
    end);
  try
    Obs.Subscribe(CountingObserver);
    AssertEquals('completed once', 1, FCompletes);
  finally
    Obs.Free;
  end;
end;

procedure TAsyncObservableTest.LateNextAfterTerminalIsIgnored;
var
  Obs: TObservable<Integer>;
begin
  Obs := TObservable<Integer>.Create(
    function(const AObserver: IObserver<Integer>): ISubscription
    begin
      AObserver.OnComplete;
      AObserver.OnNext(9);   { after the terminal: ignored }
      Result := TClosureSubscription.Create(nil);
    end);
  try
    Obs.Subscribe(CountingObserver);
    AssertEquals('no value after complete', 0, FNexts);
    AssertEquals('completed', 1, FCompletes);
  finally
    Obs.Free;
  end;
end;

procedure TAsyncObservableTest.ErrorIsDeliveredAsOnError;
var
  Obs: TObservable<Integer>;
begin
  Obs := TObservable<Integer>.Create(
    function(const AObserver: IObserver<Integer>): ISubscription
    begin
      AObserver.OnError(Exception.Create('boom'));
      Result := TClosureSubscription.Create(nil);
    end);
  try
    Obs.Subscribe(CountingObserver);
    AssertEquals('error delivered', 'boom', FErrorMsg);
    AssertEquals('no completion', 0, FCompletes);
  finally
    Obs.Free;
  end;
end;

initialization
  RegisterTest(TAsyncObservableTest);
end.
