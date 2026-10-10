unit test_async_parity;
{ Phase 10 parity sweep for the Async Core feature.

  The SPEC makes "full RxJS operator parity" the acceptance bar and states the
  rule plainly: "An operator without a test is not done." This suite walks that
  list and asserts it mechanically:

    * every async suite is registered with the runner (a typo in the runner's
      uses clause silently drops a whole suite otherwise);
    * every operator the library implements has a named test that actually
      exists in the registry (the table below is the checklist - add a row when
      you add an operator);
    * the operators that are deliberately NOT implemented are documented as such
      (the generic-inside-generic wall and the unstarted items), so a deferral
      can never be silently forgotten.

  Enumerating the registry (rather than trusting a hand-kept list) is what makes
  the "has a test" claim real: a renamed or deleted test fails this suite. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TAsyncParityTest = class(TTestCase)
  private
    FQualified: TStringList;
    procedure Collect(const ANode: TTest);
    function HasTest(const AQualified: string): Boolean;
    function AnySuiteMethod(const ASuiteClass: string): Integer;
    function ReadFeatureDoc: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestEveryAsyncSuiteIsRegistered;
    procedure TestEveryImplementedOperatorHasATest;
    procedure TestStructurallyBlockedOperatorsAreDocumented;
    procedure TestUnimplementedOperatorsAreDocumented;
  end;

implementation

const
  { The async suites that must be registered with the runner. }
  AsyncSuites: array[0..9] of string = (
    'TAsyncSchedulerTest', 'TAsyncFutureTest', 'TAsyncQueueTest',
    'TAsyncTimersTest', 'TAsyncObservableTest', 'TAsyncSubjectTest',
    'TAsyncOperatorsTest', 'TAsyncTimeTest', 'TAsyncContextTest',
    'TAsyncConcurrencyTest');

  { Every operator / core surface the library implements, mapped to the test
    that covers it ("Surface=QualifiedTestName"). This is the acceptance
    checklist from the SPEC's operator list, restricted to what is implemented;
    the table is the thing a reviewer reads to see coverage at a glance. }
  Parity: array[0..87] of string = (
    { Creation. }
    'Just=TAsyncOperatorsTest.OfEmitsOne',
    'FromArray=TAsyncOperatorsTest.FromArrayEmitsEach',
    'Range=TAsyncOperatorsTest.RangeEmits',
    'Empty=TAsyncOperatorsTest.EmptyCompletesWithoutValues',
    'ThrowError=TAsyncOperatorsTest.ThrowErrorDeliversError',
    'Defer=TAsyncOperatorsTest.DeferRunsTheFactoryPerSubscribe',
    { Transformation. }
    'Map=TAsyncOperatorsTest.MapTransforms',
    'Scan=TAsyncOperatorsTest.ScanAccumulates',
    'Pairwise=TAsyncOperatorsTest.PairwiseCombinesAdjacent',
    'Reduce=TAsyncOperatorsTest.ReduceFoldsWithASeparateAccumulator',
    'MergeMap=TAsyncOperatorsTest.MergeMapFlattens',
    'SwitchMap=TAsyncOperatorsTest.SwitchMapUsesTheNewest',
    'ConcatMap=TAsyncOperatorsTest.ConcatMapIsSequential',
    'ExhaustMap=TAsyncOperatorsTest.ExhaustMapDropsValuesWhileBusy',
    'Expand=TAsyncOperatorsTest.ExpandUnfoldsBreadthFirst',
    'WithLatestFrom=TAsyncOperatorsTest.WithLatestFromCombinesWithTheLatestRight',
    { Filtering. }
    'Filter=TAsyncOperatorsTest.FilterKeepsMatches',
    'Take=TAsyncOperatorsTest.TakeTakesThenCompletes',
    'Skip=TAsyncOperatorsTest.SkipSkipsTheHead',
    'TakeWhile=TAsyncOperatorsTest.TakeWhileStopsAtTheFirstMiss',
    'SkipWhile=TAsyncOperatorsTest.SkipWhileSkipsUntilTheFirstMiss',
    'DistinctUntilChanged=TAsyncOperatorsTest.DistinctUntilChangedDropsRepeats',
    'Distinct=TAsyncOperatorsTest.DistinctDropsRepeatsGlobally',
    'First=TAsyncOperatorsTest.FirstTakesOne',
    'Last=TAsyncOperatorsTest.LastEmitsTheFinalValue',
    'ElementAt=TAsyncOperatorsTest.ElementAtPicksOne',
    'IgnoreElements=TAsyncOperatorsTest.IgnoreElementsDropsAllValues',
    { Combination. }
    'Merge=TAsyncOperatorsTest.MergeInterleaves',
    'Concat=TAsyncOperatorsTest.ConcatIsSequential',
    'Race=TAsyncOperatorsTest.RaceTakesTheFirstSource',
    'Zip=TAsyncOperatorsTest.ZipPairsByIndex',
    'CombineLatest=TAsyncOperatorsTest.CombineLatestEmitsOnEachUpdate',
    'StartWith=TAsyncOperatorsTest.StartWithPrepends',
    'EndWith=TAsyncOperatorsTest.EndWithAppends',
    { Error handling. }
    'CatchError=TAsyncOperatorsTest.CatchErrorRecovers',
    'Retry=TAsyncOperatorsTest.RetryResubscribesThenRaises',
    'RetryWhen=TAsyncOperatorsTest.RetryWhenResubscribesOnDecision',
    'RepeatCount=TAsyncOperatorsTest.RepeatCountResubscribes',
    'Finalize=TAsyncOperatorsTest.FinalizeRunsOnCompletion',
    'ThrowIfEmpty=TAsyncOperatorsTest.ThrowIfEmptyErrorsOnEmpty',
    { Multicasting (Publish is Multicast with a default subject). }
    'Multicast=TAsyncOperatorsTest.PublishRunsTheSourceOnceForAllSubscribers',
    'Publish=TAsyncOperatorsTest.PublishRunsTheSourceOnceForAllSubscribers',
    'PublishReplay=TAsyncOperatorsTest.PublishReplayReplaysToLateSubscribers',
    'PublishLast=TAsyncOperatorsTest.PublishLastEmitsOnlyTheFinalValue',
    'PublishBehavior=TAsyncOperatorsTest.PublishBehaviorReplaysTheInitialValue',
    'Share=TAsyncOperatorsTest.ShareConnectsOnFirstSubscriber',
    'ShareReplay=TAsyncOperatorsTest.ShareReplayReplaysToLateSubscribers',
    { Utility / aggregation. }
    'Tap=TAsyncOperatorsTest.TapSeesValuesAndPassesThemOn',
    'Count=TAsyncOperatorsTest.CountEmitsTheTotal',
    'Every=TAsyncOperatorsTest.EveryEmitsOneBoolean',
    'IsEmpty=TAsyncOperatorsTest.IsEmptyEmitsOneBoolean',
    'DefaultIfEmpty=TAsyncOperatorsTest.DefaultIfEmptyEmitsTheDefault',
    'Materialize=TAsyncOperatorsTest.MaterializeThenDematerializeRoundTrips',
    'Dematerialize=TAsyncOperatorsTest.MaterializeThenDematerializeRoundTrips',
    { Time-based (unit test_async_time, virtual clock). }
    'Delay=TAsyncTimeTest.DelayShiftsValuesAndCompletion',
    'DelayWhen=TAsyncTimeTest.DelayWhenUsesThePerValueDuration',
    'DebounceTime=TAsyncTimeTest.DebounceTimeEmitsOnlyAfterQuiet',
    'ThrottleTime=TAsyncTimeTest.ThrottleTimeEmitsTheLeadingValue',
    'SampleTime=TAsyncTimeTest.SampleTimeEmitsTheLatestPerPeriod',
    'AuditTime=TAsyncTimeTest.AuditTimeEmitsTheTrailingValuePerWindow',
    'Timeout=TAsyncTimeTest.TimeoutErrorsWhenIdle',
    'TimeoutWith=TAsyncTimeTest.TimeoutWithSwitchesToTheFallback',
    'Timer=TAsyncTimeTest.TimerFiresAfterTheDelay',
    'Interval=TAsyncTimeTest.IntervalEmitsUntilUnsubscribed',
    { Concurrency. }
    'RunOn=TAsyncConcurrencyTest.RunOnSchedulesWork',
    'SubscribeOn=TAsyncConcurrencyTest.SubscribeOnRunsSubscribeOnTheScheduler',
    'ObserveOn=TAsyncConcurrencyTest.ObserveOnDeliversNotificationsOnTheScheduler',
    'ExecutorScheduler=TAsyncConcurrencyTest.ExecutorRunsWorkOnAPoolThread',
    { Future. }
    'Future.Resolve=TAsyncFutureTest.ResolveIsFulfilled',
    'Future.Reject=TAsyncFutureTest.RejectIsRejected',
    'Future.AndThen=TAsyncFutureTest.ThenRunsWithTheValue',
    'Future.Catch=TAsyncFutureTest.CatchRunsWithTheError',
    'Future.OnFinally=TAsyncFutureTest.OnFinallyRunsOnFulfillAndReject',
    'Future.Run=TAsyncFutureTest.RunProducesEagerly',
    'Future.Await=TAsyncFutureTest.AwaitReturnsTheValue',
    'Future.AwaitToken=TAsyncFutureTest.AwaitTokenStopsOnCancel',
    'Future.Race=TAsyncFutureTest.RaceTakesTheFirstSettled',
    'Future.Any=TAsyncFutureTest.AnyTakesTheFirstFulfilled',
    { Subjects and the spine. }
    'Subject=TAsyncSubjectTest.SubjectMulticasts',
    'BehaviorSubject=TAsyncSubjectTest.BehaviorSubjectReplaysCurrent',
    'ReplaySubject=TAsyncSubjectTest.ReplaySubjectReplaysBuffer',
    'AsyncSubject=TAsyncSubjectTest.AsyncSubjectEmitsLastOnComplete',
    'Observable=TAsyncObservableTest.NotRunBeforeSubscribe',
    'Queue=TAsyncSchedulerTest.QueueRunsFifo',
    'Asap=TAsyncSchedulerTest.AsapDefersUntilDrain',
    'VirtualScheduler=TAsyncTimersTest.AdvanceRunsDue',
    'BoundedQueue=TAsyncQueueTest.FifoOrder',
    'Context=TAsyncContextTest.ValueSurvivesADeferredBoundary');

  { Operators in the SPEC's list that the library does NOT implement, with the
    reason. Each name must be mentioned in the feature doc, so the gap is
    recorded rather than forgotten. }
  Blocked: array[0..15] of string = (
    'Buffer', 'BufferCount', 'BufferTime', 'ToArray', 'Window', 'WindowCount',
    'WindowTime', 'GroupBy', 'MergeAll', 'ConcatAll', 'SwitchAll',
    'CombineLatestAll', 'All', 'AllSettled', 'Partition', 'ForkJoin');

  { SPEC operators that are buildable but not yet implemented (the Phase 7
    remainder beyond the ones just done). Kept explicit so a SPEC operator is
    always classified: implemented+tested, structurally blocked, or open here. }
  Unimplemented: array[0..0] of string = (
    'Single');

procedure TAsyncParityTest.SetUp;
begin
  FQualified := TStringList.Create;
  FQualified.Sorted := True;
  FQualified.Duplicates := dupIgnore;
  Collect(GetTestRegistry);
end;

procedure TAsyncParityTest.TearDown;
begin
  FQualified.Free;
end;

procedure TAsyncParityTest.Collect(const ANode: TTest);
var
  I: Integer;
  Child: TTest;
begin
  if ANode is TTestSuite then
  begin
    for I := 0 to TTestSuite(ANode).ChildTestCount - 1 do
    begin
      Child := TTestSuite(ANode).GetChildTest(I);
      if Child is TTestSuite then
        Collect(Child)
      else
        FQualified.Add(Child.ClassName + '.' + Child.TestName);
    end;
  end;
end;

function TAsyncParityTest.HasTest(const AQualified: string): Boolean;
begin
  Result := FQualified.IndexOf(AQualified) >= 0;
end;

function TAsyncParityTest.AnySuiteMethod(const ASuiteClass: string): Integer;
var
  I: Integer;
  Prefix: string;
begin
  Result := 0;
  Prefix := ASuiteClass + '.';
  for I := 0 to FQualified.Count - 1 do
    if Copy(FQualified[I], 1, Length(Prefix)) = Prefix then
      Inc(Result);
end;

function TAsyncParityTest.ReadFeatureDoc: string;
var
  SL: TStringList;
  Path: string;
begin
  { The TODO is renamed to DONE when the phase completes; read whichever is
    present so the sweep keeps working across the rename. }
  Path := 'docs/features/Async_Core/Async_Core_v1.DONE.md';
  if not FileExists(Path) then
    Path := 'docs/features/Async_Core/Async_Core_v1.TODO.md';
  Result := '';
  if not FileExists(Path) then
    Exit;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(Path);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure TAsyncParityTest.TestEveryAsyncSuiteIsRegistered;
var
  I: Integer;
begin
  AssertTrue('the registry is non-empty', FQualified.Count > 0);
  for I := Low(AsyncSuites) to High(AsyncSuites) do
    AssertTrue('suite registered with cases: ' + AsyncSuites[I],
      AnySuiteMethod(AsyncSuites[I]) > 0);
end;

procedure TAsyncParityTest.TestEveryImplementedOperatorHasATest;
var
  I, P: Integer;
  Name, Qual: string;
begin
  for I := Low(Parity) to High(Parity) do
  begin
    P := Pos('=', Parity[I]);
    AssertTrue('parity row is well-formed: ' + Parity[I], P > 0);
    Name := Copy(Parity[I], 1, P - 1);
    Qual := Copy(Parity[I], P + 1, MaxInt);
    AssertTrue('implemented surface "' + Name + '" has a test (' + Qual + ')',
      HasTest(Qual));
  end;
end;

procedure TAsyncParityTest.TestStructurallyBlockedOperatorsAreDocumented;
var
  I: Integer;
  Doc: string;
begin
  Doc := ReadFeatureDoc;
  AssertTrue('the feature doc is readable', Doc <> '');
  for I := Low(Blocked) to High(Blocked) do
    AssertTrue('the deferral of ' + Blocked[I] + ' is documented',
      Pos(Blocked[I], Doc) > 0);
end;

procedure TAsyncParityTest.TestUnimplementedOperatorsAreDocumented;
var
  I: Integer;
  Doc: string;
begin
  Doc := ReadFeatureDoc;
  AssertTrue('the feature doc is readable', Doc <> '');
  for I := Low(Unimplemented) to High(Unimplemented) do
    AssertTrue('the open operator ' + Unimplemented[I] + ' is documented',
      Pos(Unimplemented[I], Doc) > 0);
end;

initialization
  RegisterTest(TAsyncParityTest);
end.
