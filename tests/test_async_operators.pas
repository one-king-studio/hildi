unit test_async_operators;
{ Tests for the operators (docs/features/Async_Core). Each operator is checked
  against a source of known values: the expected notification sequence and
  whether it completed.

  Same-type operators and sources are class methods on TOp<T>; the cross-type
  ones (Map, Count) and Range are on TStreamOps. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  async.base, async.observable, async.operators;

type
  TAsyncOperatorsTest = class(TTestCase)
  private
    FSeq: string;
    FCompletes: Integer;
    FError: string;
    FSourceRuns: Integer;
    procedure Add(const S: string);
    procedure Reset;
    function Arr(const AValues: array of Integer): TArray<Integer>;
    function RecorderInt: IObserver<Integer>;
    function RecorderStr: IObserver<string>;
    procedure AssertInts(const AObs: ISubscribable<Integer>;
      const AExpected: string; const AComplete: Boolean);
    function IntSource(const AValues: array of Integer): ISubscribable<Integer>;
  published
    { Creation. }
    procedure OfEmitsOne;
    procedure FromArrayEmitsEach;
    procedure RangeEmits;
    procedure EmptyCompletesWithoutValues;
    procedure ThrowErrorDeliversError;
    procedure DeferRunsTheFactoryPerSubscribe;
    { Transformation. }
    procedure MapTransforms;
    procedure ScanAccumulates;
    { Filtering. }
    procedure FilterKeepsMatches;
    procedure TakeTakesThenCompletes;
    procedure SkipSkipsTheHead;
    procedure TakeWhileStopsAtTheFirstMiss;
    procedure SkipWhileSkipsUntilTheFirstMiss;
    procedure DistinctUntilChangedDropsRepeats;
    procedure FirstTakesOne;
    procedure ElementAtPicksOne;
    { Laziness and composability. }
    procedure OperatorsAreLazyUntilSubscribed;
    procedure MapComposesWithFilter;
  end;

implementation

procedure TAsyncOperatorsTest.Add(const S: string);
begin
  if FSeq <> '' then
    FSeq := FSeq + ',';
  FSeq := FSeq + S;
end;

procedure TAsyncOperatorsTest.Reset;
begin
  FSeq := '';
  FCompletes := 0;
  FError := '';
end;

function TAsyncOperatorsTest.Arr(const AValues: array of Integer): TArray<Integer>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

function TAsyncOperatorsTest.IntSource(
  const AValues: array of Integer): ISubscribable<Integer>;
begin
  Result := TStreamOps.FromArray<Integer>(Arr(AValues));
end;

function TAsyncOperatorsTest.RecorderInt: IObserver<Integer>;
begin
  Result := TObserver<Integer>.Create(
    procedure(const V: Integer) begin Add(IntToStr(V)); end,
    procedure(const E: Exception) begin FError := E.Message; E.Free; end,
    procedure begin Inc(FCompletes); end);
end;

function TAsyncOperatorsTest.RecorderStr: IObserver<string>;
begin
  Result := TObserver<string>.Create(
    procedure(const V: string) begin Add(V); end,
    procedure(const E: Exception) begin FError := E.Message; E.Free; end,
    procedure begin Inc(FCompletes); end);
end;

procedure TAsyncOperatorsTest.AssertInts(const AObs: ISubscribable<Integer>;
  const AExpected: string; const AComplete: Boolean);
begin
  Reset;
  AObs.Subscribe(RecorderInt);
  AssertEquals('sequence', AExpected, FSeq);
  AssertEquals('error', '', FError);
  AssertEquals('completed', Ord(AComplete), FCompletes);
end;

{ Creation }

procedure TAsyncOperatorsTest.OfEmitsOne;
begin
  AssertInts(TStreamOps.Just<Integer>(5), '5', True);
end;

procedure TAsyncOperatorsTest.FromArrayEmitsEach;
begin
  AssertInts(IntSource([1, 2, 3]), '1,2,3', True);
end;

procedure TAsyncOperatorsTest.RangeEmits;
begin
  AssertInts(TStreamOps.Range(3, 4), '3,4,5,6', True);
end;

procedure TAsyncOperatorsTest.EmptyCompletesWithoutValues;
begin
  AssertInts(TStreamOps.Empty<Integer>, '', True);
end;

procedure TAsyncOperatorsTest.ThrowErrorDeliversError;
begin
  Reset;
  TStreamOps.ThrowError<Integer>(Exception.Create('boom')).Subscribe(RecorderInt);
  AssertEquals('no values', '', FSeq);
  AssertEquals('error', 'boom', FError);
  AssertEquals('not completed', 0, FCompletes);
end;

procedure TAsyncOperatorsTest.DeferRunsTheFactoryPerSubscribe;
begin
  FSourceRuns := 0;
  Reset;
  TStreamOps.Defer<Integer>(function: ISubscribable<Integer>
    begin
      Inc(FSourceRuns);
      Result := TStreamOps.Just<Integer>(1);
    end).Subscribe(RecorderInt);
  AssertEquals('ran once', 1, FSourceRuns);
  AssertEquals('value', '1', FSeq);
end;

{ Transformation }

procedure TAsyncOperatorsTest.MapTransforms;
begin
  Reset;
  TStreamOps.Map<Integer, string>(IntSource([1, 2, 3]),
    function(const V: Integer): string
    begin
      Result := 'v' + IntToStr(V);
    end).Subscribe(RecorderStr);
  AssertEquals('mapped', 'v1,v2,v3', FSeq);
  AssertEquals('completed', 1, FCompletes);
end;

procedure TAsyncOperatorsTest.ScanAccumulates;
begin
  Reset;
  TStreamOps.Scan<Integer>(IntSource([1, 2, 3]), 0,
    function(const AAcc, AValue: Integer): Integer
    begin
      Result := AAcc + AValue;
    end).Subscribe(RecorderInt);
  AssertEquals('running sum', '1,3,6', FSeq);
  AssertEquals('completed', 1, FCompletes);
end;

{ Filtering }

procedure TAsyncOperatorsTest.FilterKeepsMatches;
begin
  Reset;
  TStreamOps.Filter<Integer>(IntSource([1, 2, 3, 4]),
    function(const V: Integer): Boolean
    begin
      Result := V mod 2 = 0;
    end).Subscribe(RecorderInt);
  AssertEquals('evens', '2,4', FSeq);
  AssertEquals('completed', 1, FCompletes);
end;

procedure TAsyncOperatorsTest.TakeTakesThenCompletes;
begin
  AssertInts(TStreamOps.Take<Integer>(IntSource([1, 2, 3, 4, 5]), 2), '1,2', True);
end;

procedure TAsyncOperatorsTest.SkipSkipsTheHead;
begin
  AssertInts(TStreamOps.Skip<Integer>(IntSource([1, 2, 3, 4, 5]), 2), '3,4,5', True);
end;

procedure TAsyncOperatorsTest.TakeWhileStopsAtTheFirstMiss;
begin
  AssertInts(TStreamOps.TakeWhile<Integer>(IntSource([1, 2, 3, 1]),
    function(const V: Integer): Boolean
    begin
      Result := V < 3;
    end), '1,2', True);
end;

procedure TAsyncOperatorsTest.SkipWhileSkipsUntilTheFirstMiss;
begin
  AssertInts(TStreamOps.SkipWhile<Integer>(IntSource([1, 2, 3, 1]),
    function(const V: Integer): Boolean
    begin
      Result := V < 3;
    end), '3,1', True);
end;

procedure TAsyncOperatorsTest.DistinctUntilChangedDropsRepeats;
begin
  AssertInts(TStreamOps.DistinctUntilChanged<Integer>(IntSource([1, 1, 2, 2, 3, 1]),
    function(const A, B: Integer): Boolean
    begin
      Result := A = B;
    end), '1,2,3,1', True);
end;

procedure TAsyncOperatorsTest.FirstTakesOne;
begin
  AssertInts(TStreamOps.First<Integer>(IntSource([5, 6, 7])), '5', True);
end;

procedure TAsyncOperatorsTest.ElementAtPicksOne;
begin
  AssertInts(TStreamOps.ElementAt<Integer>(IntSource([5, 6, 7]), 1), '6', True);
end;

{ Laziness and composability }

procedure TAsyncOperatorsTest.OperatorsAreLazyUntilSubscribed;
var
  Filtered: ISubscribable<Integer>;
begin
  FSourceRuns := 0;
  Reset;
  Filtered := TStreamOps.Filter<Integer>(
    TStreamOps.Defer<Integer>(function: ISubscribable<Integer>
      begin
        Inc(FSourceRuns);
        Result := TStreamOps.Just<Integer>(1);
      end),
    function(const V: Integer): Boolean
    begin
      Result := True;
    end);
  AssertEquals('not subscribed yet', 0, FSourceRuns);
  Filtered.Subscribe(RecorderInt);
  AssertEquals('ran on subscribe', 1, FSourceRuns);
  AssertEquals('value forwarded', '1', FSeq);
end;

procedure TAsyncOperatorsTest.MapComposesWithFilter;
var
  Composed: ISubscribable<string>;
begin
  { Map to strings, then filter — the composability the surface exists for. }
  Reset;
  Composed := TStreamOps.Filter<string>(
    TStreamOps.Map<Integer, string>(IntSource([1, 2, 3, 4, 5]),
      function(const V: Integer): string
      begin
        Result := IntToStr(V * 10);
      end),
    function(const S: string): Boolean
    begin
      Result := S <> '30';
    end);
  Composed.Subscribe(RecorderStr);
  AssertEquals('mapped then filtered', '10,20,40,50', FSeq);
  AssertEquals('completed', 1, FCompletes);
end;

initialization
  RegisterTest(TAsyncOperatorsTest);
end.
