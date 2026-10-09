unit test_async_future;
{ Tests for TFuture<T> (docs/features/Async_Core). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  async.base, async.scheduler, async.future;

type
  TAsyncFutureTest = class(TTestCase)
  private
    FInt: Integer;
    FMsg: string;
    FRuns: Integer;
  published
    procedure ResolveIsFulfilled;
    procedure RejectIsRejected;
    procedure ThenRunsWithTheValue;
    procedure CatchRunsWithTheError;
    procedure ThenAfterResolveRunsImmediately;
    procedure SettlesOnceOnly;
    procedure AwaitReturnsTheValue;
    procedure AwaitRaisesOnRejected;
    procedure AwaitOnPendingWithoutSchedulerRaises;
    procedure SchedulerDefersDeliveryUntilDrain;
    procedure ThenOnPendingRunsOnFulfill;
  end;

implementation

procedure TAsyncFutureTest.ResolveIsFulfilled;
var
  F: TFuture<Integer>;
begin
  F := TFuture<Integer>.Resolve(42);
  try
    AssertEquals('fulfilled', Ord(fsFulfilled), Ord(F.State));
    AssertEquals('value', 42, F.Value);
  finally
    F.Free;
  end;
end;

procedure TAsyncFutureTest.RejectIsRejected;
var
  F: TFuture<Integer>;
begin
  F := TFuture<Integer>.Reject(Exception.Create('boom'));
  try
    AssertEquals('rejected', Ord(fsRejected), Ord(F.State));
    AssertEquals('error message', 'boom', F.Error.Message);
  finally
    F.Free;
  end;
end;

procedure TAsyncFutureTest.ThenRunsWithTheValue;
var
  F: TFuture<Integer>;
begin
  FInt := 0;
  F := TFuture<Integer>.Resolve(7);
  try
    F.AndThen(procedure(const AValue: Integer) begin FInt := AValue; end);
    AssertEquals('callback saw the value', 7, FInt);
  finally
    F.Free;
  end;
end;

procedure TAsyncFutureTest.CatchRunsWithTheError;
var
  F: TFuture<Integer>;
begin
  FMsg := '';
  F := TFuture<Integer>.Reject(Exception.Create('nope'));
  try
    F.Catch(procedure(const AError: Exception) begin FMsg := AError.Message; end);
    AssertEquals('callback saw the error', 'nope', FMsg);
  finally
    F.Free;
  end;
end;

procedure TAsyncFutureTest.ThenAfterResolveRunsImmediately;
var
  F: TFuture<Integer>;
begin
  FInt := 0;
  F := TFuture<Integer>.Resolve(3);
  try
    { The future is already settled, so Then delivers at once. }
    F.AndThen(procedure(const AValue: Integer) begin FInt := AValue * 2; end);
    AssertEquals('delivered on a settled future', 6, FInt);
  finally
    F.Free;
  end;
end;

procedure TAsyncFutureTest.SettlesOnceOnly;
var
  F: TFuture<Integer>;
begin
  FRuns := 0;
  F := TFuture<Integer>.Resolve(1);
  try
    F.AndThen(procedure(const AValue: Integer) begin Inc(FRuns); end);
    F.Fulfill(2);
    F.Fail(Exception.Create('late'));
    AssertEquals('still fulfilled', Ord(fsFulfilled), Ord(F.State));
    AssertEquals('value unchanged', 1, F.Value);
    AssertEquals('delivered once', 1, FRuns);
  finally
    F.Free;
  end;
end;

procedure TAsyncFutureTest.AwaitReturnsTheValue;
var
  F: TFuture<Integer>;
begin
  F := TFuture<Integer>.Resolve(11);
  try
    AssertEquals('await', 11, F.Await);
  finally
    F.Free;
  end;
end;

procedure TAsyncFutureTest.AwaitRaisesOnRejected;
var
  F: TFuture<Integer>;
  Raised: Boolean;
begin
  F := TFuture<Integer>.Reject(Exception.Create('denied'));
  try
    Raised := False;
    try
      F.Await;
    except
      on E: EFutureRejected do
        Raised := True;
    end;
    AssertTrue('await raised', Raised);
  finally
    F.Free;
  end;
end;

procedure TAsyncFutureTest.AwaitOnPendingWithoutSchedulerRaises;
var
  F: TFuture<Integer>;
  Raised: Boolean;
begin
  F := TFuture<Integer>.Create;
  try
    Raised := False;
    try
      F.Await;
    except
      on E: Exception do
        Raised := True;
    end;
    AssertTrue('a pending future with no scheduler cannot be awaited', Raised);
  finally
    F.Free;
  end;
end;

procedure TAsyncFutureTest.SchedulerDefersDeliveryUntilDrain;
var
  S: IAsyncScheduler;
  F: TFuture<Integer>;
begin
  FInt := 0;
  S := TAsapScheduler.Create;
  F := TFuture<Integer>.Create(S);
  try
    F.AndThen(procedure(const AValue: Integer) begin FInt := AValue; end);
    F.Fulfill(9);
    AssertEquals('not delivered before a drain', 0, FInt);
    S.Drain;
    AssertEquals('delivered on drain', 9, FInt);
  finally
    F.Free;
  end;
end;

procedure TAsyncFutureTest.ThenOnPendingRunsOnFulfill;
var
  F: TFuture<Integer>;
begin
  FInt := 0;
  F := TFuture<Integer>.Create;
  try
    F.AndThen(procedure(const AValue: Integer) begin FInt := AValue; end);
    AssertEquals('nothing yet', 0, FInt);
    F.Fulfill(5);
    AssertEquals('ran on fulfill', 5, FInt);
  finally
    F.Free;
  end;
end;

initialization
  RegisterTest(TAsyncFutureTest);
end.
