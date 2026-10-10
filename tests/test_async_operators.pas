unit test_async_operators;
{ Tests for the operators (docs/features/Async_Core). Each operator is checked
  against a source of known values: the expected notification sequence and
  whether it completed.

  Operators are free functions; the curried Op factories and Pipe compose them
  RxJS-style. }

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
    procedure PipeReducesOverOperators;
    { Fan-in and flattening. }
    procedure MergeInterleaves;
    procedure ConcatIsSequential;
    procedure MergeMapFlattens;
    procedure SwitchMapUsesTheNewest;
    procedure ZipPairsByIndex;
    procedure ReduceFoldsWithASeparateAccumulator;
    procedure PairwiseCombinesAdjacent;
    { Utility, aggregation, error. }
    procedure TapSeesValuesAndPassesThemOn;
    procedure IgnoreElementsDropsAllValues;
    procedure StartWithPrepends;
    procedure EndWithAppends;
    procedure DistinctDropsRepeatsGlobally;
    procedure LastEmitsTheFinalValue;
    procedure CountEmitsTheTotal;
    procedure CatchErrorRecovers;
    procedure FinalizeRunsOnCompletion;
    procedure CombineLatestEmitsOnEachUpdate;
    procedure ExtraOperatorsComposeInAPipe;
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
  Result := FromArray<Integer>(Arr(AValues));
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
  AssertInts(Just<Integer>(5), '5', True);
end;

procedure TAsyncOperatorsTest.FromArrayEmitsEach;
begin
  AssertInts(IntSource([1, 2, 3]), '1,2,3', True);
end;

procedure TAsyncOperatorsTest.RangeEmits;
begin
  AssertInts(Range(3, 4), '3,4,5,6', True);
end;

procedure TAsyncOperatorsTest.EmptyCompletesWithoutValues;
begin
  AssertInts(Empty<Integer>, '', True);
end;

procedure TAsyncOperatorsTest.ThrowErrorDeliversError;
begin
  Reset;
  ThrowError<Integer>(Exception.Create('boom')).Subscribe(RecorderInt);
  AssertEquals('no values', '', FSeq);
  AssertEquals('error', 'boom', FError);
  AssertEquals('not completed', 0, FCompletes);
end;

procedure TAsyncOperatorsTest.DeferRunsTheFactoryPerSubscribe;
begin
  FSourceRuns := 0;
  Reset;
  Defer<Integer>(function: ISubscribable<Integer>
    begin
      Inc(FSourceRuns);
      Result := Just<Integer>(1);
    end).Subscribe(RecorderInt);
  AssertEquals('ran once', 1, FSourceRuns);
  AssertEquals('value', '1', FSeq);
end;

{ Transformation }

procedure TAsyncOperatorsTest.MapTransforms;
begin
  Reset;
  Map<Integer, string>(IntSource([1, 2, 3]),
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
  Scan<Integer>(IntSource([1, 2, 3]), 0,
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
  Filter<Integer>(IntSource([1, 2, 3, 4]),
    function(const V: Integer): Boolean
    begin
      Result := V mod 2 = 0;
    end).Subscribe(RecorderInt);
  AssertEquals('evens', '2,4', FSeq);
  AssertEquals('completed', 1, FCompletes);
end;

procedure TAsyncOperatorsTest.TakeTakesThenCompletes;
begin
  AssertInts(Take<Integer>(IntSource([1, 2, 3, 4, 5]), 2), '1,2', True);
end;

procedure TAsyncOperatorsTest.SkipSkipsTheHead;
begin
  AssertInts(Skip<Integer>(IntSource([1, 2, 3, 4, 5]), 2), '3,4,5', True);
end;

procedure TAsyncOperatorsTest.TakeWhileStopsAtTheFirstMiss;
begin
  AssertInts(TakeWhile<Integer>(IntSource([1, 2, 3, 1]),
    function(const V: Integer): Boolean
    begin
      Result := V < 3;
    end), '1,2', True);
end;

procedure TAsyncOperatorsTest.SkipWhileSkipsUntilTheFirstMiss;
begin
  AssertInts(SkipWhile<Integer>(IntSource([1, 2, 3, 1]),
    function(const V: Integer): Boolean
    begin
      Result := V < 3;
    end), '3,1', True);
end;

procedure TAsyncOperatorsTest.DistinctUntilChangedDropsRepeats;
begin
  AssertInts(DistinctUntilChanged<Integer>(IntSource([1, 1, 2, 2, 3, 1]),
    function(const A, B: Integer): Boolean
    begin
      Result := A = B;
    end), '1,2,3,1', True);
end;

procedure TAsyncOperatorsTest.FirstTakesOne;
begin
  AssertInts(First<Integer>(IntSource([5, 6, 7])), '5', True);
end;

procedure TAsyncOperatorsTest.ElementAtPicksOne;
begin
  AssertInts(ElementAt<Integer>(IntSource([5, 6, 7]), 1), '6', True);
end;

{ Laziness and composability }

procedure TAsyncOperatorsTest.OperatorsAreLazyUntilSubscribed;
var
  Filtered: ISubscribable<Integer>;
begin
  FSourceRuns := 0;
  Reset;
  Filtered := Filter<Integer>(
    Defer<Integer>(function: ISubscribable<Integer>
      begin
        Inc(FSourceRuns);
        Result := Just<Integer>(1);
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
  Composed := Filter<string>(
    Map<Integer, string>(IntSource([1, 2, 3, 4, 5]),
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

{ Fan-in and flattening }

procedure TAsyncOperatorsTest.PipeReducesOverOperators;
var
  S: ISubscribable<Integer>;
begin
  { The RxJS-style pipeline: an array of curried operators reduced over a source. }
  S := Pipe<Integer>(Range(1, 10), [
    FilterOp<Integer>(function(const V: Integer): Boolean
      begin Result := V mod 2 = 0; end),
    TakeOp<Integer>(3)]);
  AssertInts(S, '2,4,6', True);
end;

procedure TAsyncOperatorsTest.MergeInterleaves;
var
  Srcs: TArray<ISubscribable<Integer>>;
begin
  SetLength(Srcs, 2);
  Srcs[0] := IntSource([1, 2, 3]);
  Srcs[1] := IntSource([10, 11]);
  AssertInts(Merge<Integer>(Srcs), '1,2,3,10,11', True);
end;

procedure TAsyncOperatorsTest.ConcatIsSequential;
var
  Srcs: TArray<ISubscribable<Integer>>;
begin
  SetLength(Srcs, 2);
  Srcs[0] := IntSource([1, 2]);
  Srcs[1] := IntSource([3, 4]);
  AssertInts(Concat<Integer>(Srcs), '1,2,3,4', True);
end;

procedure TAsyncOperatorsTest.MergeMapFlattens;
begin
  { Each value projects to a two-element stream; all inner values are forwarded. }
  AssertInts(MergeMap<Integer, Integer>(IntSource([1, 2]),
    function(const V: Integer): ISubscribable<Integer>
    begin
      Result := IntSource([V * 10, V * 10 + 1]);
    end), '10,11,20,21', True);
end;

procedure TAsyncOperatorsTest.SwitchMapUsesTheNewest;
begin
  { Synchronous sources settle before the next value arrives, so switch and merge
    agree here; the switch semantics (cancel the prior inner) matter only when
    inners overlap in time. }
  AssertInts(SwitchMap<Integer, Integer>(IntSource([1, 2]),
    function(const V: Integer): ISubscribable<Integer>
    begin
      Result := IntSource([V * 10, V * 10 + 1]);
    end), '10,11,20,21', True);
end;

procedure TAsyncOperatorsTest.ZipPairsByIndex;
begin
  Reset;
  Zip<Integer, Integer, string>(IntSource([1, 2, 3]),
    IntSource([10, 20]),
    function(const A, B: Integer): string
    begin
      Result := IntToStr(A) + '/' + IntToStr(B);
    end).Subscribe(RecorderStr);
  AssertEquals('paired by index, shortest wins', '1/10,2/20', FSeq);
  AssertEquals('completed', 1, FCompletes);
end;

procedure TAsyncOperatorsTest.ReduceFoldsWithASeparateAccumulator;
begin
  { Reduce<T, A>: fold T into an A, emitting the final A. }
  Reset;
  Reduce<Integer, string>(IntSource([1, 2, 3]), '',
    function(const Acc: string; const V: Integer): string
    begin
      Result := Acc + IntToStr(V);
    end).Subscribe(RecorderStr);
  AssertEquals('one folded value', '123', FSeq);
  AssertEquals('completed', 1, FCompletes);
end;

procedure TAsyncOperatorsTest.PairwiseCombinesAdjacent;
begin
  { Pairwise<T, U>: combine each adjacent pair into a U (no tuple type needed). }
  Reset;
  Pairwise<Integer, Integer>(IntSource([1, 2, 3, 4]),
    function(const A, B: Integer): Integer
    begin
      Result := B - A;
    end).Subscribe(RecorderInt);
  AssertEquals('adjacent differences', '1,1,1', FSeq);
  AssertEquals('completed', 1, FCompletes);
end;

procedure TAsyncOperatorsTest.TapSeesValuesAndPassesThemOn;
var
  Seen: Integer;
begin
  Seen := 0;
  Reset;
  Tap<Integer>(IntSource([1, 2, 3]),
    procedure(const V: Integer) begin Seen := Seen + V; end).Subscribe(RecorderInt);
  AssertEquals('values forwarded', '1,2,3', FSeq);
  AssertEquals('tap saw them', 6, Seen);
end;

procedure TAsyncOperatorsTest.IgnoreElementsDropsAllValues;
begin
  AssertInts(IgnoreElements<Integer>(IntSource([1, 2, 3])), '', True);
end;

procedure TAsyncOperatorsTest.StartWithPrepends;
begin
  AssertInts(StartWith<Integer>(IntSource([1, 2]), 0), '0,1,2', True);
end;

procedure TAsyncOperatorsTest.EndWithAppends;
begin
  AssertInts(EndWith<Integer>(IntSource([1, 2]), 9), '1,2,9', True);
end;

procedure TAsyncOperatorsTest.DistinctDropsRepeatsGlobally;
begin
  AssertInts(Distinct<Integer>(IntSource([1, 2, 1, 3, 2, 4]),
    function(const A, B: Integer): Boolean begin Result := A = B; end),
    '1,2,3,4', True);
end;

procedure TAsyncOperatorsTest.LastEmitsTheFinalValue;
begin
  AssertInts(Last<Integer>(IntSource([1, 2, 3])), '3', True);
end;

procedure TAsyncOperatorsTest.CountEmitsTheTotal;
begin
  AssertInts(Count<Integer>(IntSource([1, 2, 3, 4])), '4', True);
end;

procedure TAsyncOperatorsTest.CatchErrorRecovers;
begin
  Reset;
  CatchError<Integer>(ThrowError<Integer>(Exception.Create('boom')),
    function(const E: Exception): ISubscribable<Integer>
    begin
      E.Free;
      Result := IntSource([7, 8]);
    end).Subscribe(RecorderInt);
  AssertEquals('recovered with the fallback', '7,8', FSeq);
  AssertEquals('completed', 1, FCompletes);
end;

procedure TAsyncOperatorsTest.FinalizeRunsOnCompletion;
var
  Ran: Boolean;
begin
  Ran := False;
  Reset;
  Finalize<Integer>(IntSource([1, 2]),
    procedure begin Ran := True; end).Subscribe(RecorderInt);
  AssertEquals('values', '1,2', FSeq);
  AssertTrue('finalize ran', Ran);
end;

procedure TAsyncOperatorsTest.CombineLatestEmitsOnEachUpdate;
begin
  Reset;
  CombineLatest<Integer, Integer, string>(IntSource([1, 2]),
    IntSource([10, 20]),
    function(const A, B: Integer): string
    begin
      Result := IntToStr(A) + '/' + IntToStr(B);
    end).Subscribe(RecorderStr);
  { left emits 1 (no B yet), left emits 2 (no B yet), right emits 10 -> 2/10,
    right emits 20 -> 2/20 }
  AssertEquals('latest combination', '2/10,2/20', FSeq);
  AssertEquals('completed', 1, FCompletes);
end;

procedure TAsyncOperatorsTest.ExtraOperatorsComposeInAPipe;
var
  S: ISubscribable<Integer>;
begin
  { Tap (side effect) then Distinct then Take, composed in a Pipe. }
  S := Pipe<Integer>(IntSource([1, 1, 2, 3, 3, 4]), [
    TapOp<Integer>(procedure(const V: Integer) begin end),
    DistinctOp<Integer>(function(const A, B: Integer): Boolean
      begin Result := A = B; end),
    TakeOp<Integer>(3)]);
  AssertInts(S, '1,2,3', True);
end;

initialization
  RegisterTest(TAsyncOperatorsTest);
end.
