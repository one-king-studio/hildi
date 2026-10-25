unit test_approval;
{ fpcunit tests for hildegard.helper.approval: the generic matcher, in-memory
  store, and the resolve service. No SQLite, no prompting side effects. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry, hildegard.helper.approval,
  hildegard.helper.approval.store, hildegard.helper.store;

type
  { Scripted approval prompt. }
  TFakePrompt = class
  public
    Allowed: Boolean;
    TimedOut: Boolean;
    OptionKey: string;
    Scope: TApprovalScope;
    Calls: Integer;
    LastSummary: string;
    function Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
  end;

  { A prompt that blocks until the test releases it, so a second (no-prompt)
    resolve can be observed running concurrently. }
  TBlockingPrompt = class
  private
    FEntered: TSimpleEvent;
    FRelease: TSimpleEvent;
  public
    Allowed: Boolean;
    OptionKey: string;
    Calls: Integer;
    constructor Create;
    destructor Destroy; override;
    function Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
    function WaitEntered(ATimeoutMs: Integer): Boolean;
    procedure Release;
  end;

  { Runs one Resolve on its own thread, so concurrent resolution is exercisable.
    The service is a shared interface ref held by the test. }
  TResolveThread = class(TThread)
  private
    FSvc: IApprovalService;
    FAsks: TApprovalAskArray;
  public
    Done: Boolean;
    Allowed: Boolean;
    Denied: Boolean;
    Reason: string;
    constructor Create(const ASvc: IApprovalService;
      const AAsks: TApprovalAskArray);
    procedure Execute; override;
  end;

  TApprovalTest = class(TTestCase)
  private
    FDir, FDbPath: string;
    function OpenStore: TSqliteStore;
    function Params(const AItems: array of string): TApprovalParams;
    function Rule(AEffect: TApprovalEffect; AScope: TApprovalScope;
      AWorkspace: Integer; const ASession, ARef: string;
      const AParams: array of string; AAny: Boolean): TApprovalRule;
    function Subject(const ARef: string;
      const AParams: array of string): TApprovalSubject;
    function Ask(const ARef, ASummary: string;
      const AParams: array of string;
      const AOptions: array of TApprovalOption): TApprovalAsk;
    function Option(const AKey, ALabel: string; APersists: Boolean;
      const ARef: string; const AParams: array of string;
      AAny: Boolean): TApprovalOption;
  published
    { Risk ordering is enforced CENTRALLY, so every producer gets it. }
    procedure TestSortOptionsByRiskPutsOnceFirst;
    procedure TestUnrecognisedOptionSortsLast;
    procedure TestExactRefAndParamsMatch;
    procedure TestExactParamsRejectDifferentArgs;
    procedure TestAnyParamsPrefixMatches;
    procedure TestAnyParamsRejectsDifferentPrefix;
    procedure TestEmptyAnyParamsMatchesWholeRef;
    procedure TestRefMismatchDoesNotMatch;
    procedure TestDenyWinsOverAllow;
    procedure TestScopePrecedenceSessionOverWorkspaceOverGlobal;
    procedure TestNoMatchAsks;
    procedure TestDirectoryMatchesSubtree;
    procedure TestDirectoryDoesNotMatchPrefixSibling;
    procedure TestExtensionMatchesCaseInsensitively;
    procedure TestExtensionNormalisesLeadingDot;
    procedure TestEmptyDirectoryOrExtensionMatchesAny;
    procedure TestDirectoryAndExtensionBothRequired;
    procedure TestV1RuleMatchesUnchanged;
    procedure TestScopedDenyWins;
    procedure TestPathlessSubjectNeverMatchesPathRule;
    procedure TestExactCommandGrantSuppressesThePathAsk;
    procedure TestWildcardCommandGrantDoesNotSuppressIt;
    procedure TestMemoryStoreSuppressesDuplicates;
    procedure TestMemoryStoreFiltersByContext;
    procedure TestBatchDenyPreScanDoesNotPrompt;
    procedure TestAllowFromRuleDoesNotPrompt;
    procedure TestPromptPersistsChosenRuleAtChosenScope;
    procedure TestOnceChoiceDoesNotPersist;
    procedure TestMissingPromptDenies;
    procedure TestTimedOutPromptReportsTimeout;
    procedure TestInvalidOptionDenies;
    procedure TestStoreSaveLoadRemoveRoundTrip;
    procedure TestPathRulesRoundTrip;
    { A bucket grant must SURVIVE the store. It failed until v18: the rule has no
      ref by design, and the store required one. }
    procedure TestBucketRuleRoundTrips;
    procedure TestRulesDifferingOnlyByPathCoexist;
    procedure TestApprovalsMigrationRebuildsWithPathColumns;
    procedure TestStoreSuppressesDuplicates;
    procedure TestStoreFiltersByContext;
    procedure TestChildResolvesAgainstRootScope;
    procedure TestGrantForOneChildAppliesToSibling;
    procedure TestConcurrentResolveDoesNotDoublePrompt;
    procedure TestNoPromptResolveIsNotBlockedByAPromptingSibling;
    procedure TestBucketReadGrantCoversAReadCommand;
    procedure TestBucketNeverCoversAnUnknownEffect;
    procedure TestBucketAnyCoversEverythingKnown;
    procedure TestBucketWriteGrantDoesNotCoverARead;
    procedure TestBucketRuleIgnoresRef;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  end;

implementation

constructor TResolveThread.Create(const ASvc: IApprovalService;
  const AAsks: TApprovalAskArray);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSvc := ASvc;
  FAsks := AAsks;
end;

procedure TResolveThread.Execute;
var
  Batch: TApprovalBatchResult;
begin
  FSvc.Resolve(FAsks, Batch);
  Allowed := Batch.Allowed;
  Denied := Batch.Denied;
  Reason := Batch.Reason;
  Done := True;
end;

constructor TBlockingPrompt.Create;
begin
  inherited Create;
  FEntered := TSimpleEvent.Create;
  FRelease := TSimpleEvent.Create;
end;

destructor TBlockingPrompt.Destroy;
begin
  FRelease.Free;
  FEntered.Free;
  inherited Destroy;
end;

function TBlockingPrompt.Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
begin
  Inc(Calls);
  FEntered.SetEvent;              // signal the test that the prompt is up
  FRelease.WaitFor(INFINITE);     // block until the test releases it
  Result := Default(TApprovalChoice);
  Result.Allowed := Allowed;
  Result.OptionKey := OptionKey;
end;

function TBlockingPrompt.WaitEntered(ATimeoutMs: Integer): Boolean;
begin
  Result := FEntered.WaitFor(ATimeoutMs) <> wrTimeout;
end;

procedure TBlockingPrompt.Release;
begin
  FRelease.SetEvent;
end;

procedure TApprovalTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhappr_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  CreateDir(FDir);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
end;

procedure TApprovalTest.TearDown;
begin
  DeleteFile(FDbPath);
  DeleteFile(FDbPath + '-wal');
  DeleteFile(FDbPath + '-shm');
  RemoveDir(FDir);
end;

function TApprovalTest.OpenStore: TSqliteStore;
var
  Cfg: TStoreConfig;
  Err: TStoreError;
begin
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  Result := TSqliteStore.Create(Cfg);
  if not Result.Open(Err) then
  begin
    Result.Free;
    raise Exception.Create('store failed to open: ' + Err.Message);
  end;
end;

function TApprovalTest.Params(const AItems: array of string): TApprovalParams;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AItems));
  for I := 0 to High(AItems) do
    Result[I] := AItems[I];
end;

function TApprovalTest.Rule(AEffect: TApprovalEffect; AScope: TApprovalScope;
  AWorkspace: Integer; const ASession, ARef: string;
  const AParams: array of string; AAny: Boolean): TApprovalRule;
begin
  Result := Default(TApprovalRule);
  Result.Effect := AEffect;
  Result.Scope := AScope;
  Result.WorkspaceId := AWorkspace;
  Result.SessionId := ASession;
  Result.Ref := ARef;
  Result.Params := Params(AParams);
  Result.AnyParams := AAny;
end;

function TApprovalTest.Subject(const ARef: string;
  const AParams: array of string): TApprovalSubject;
begin
  Result := Default(TApprovalSubject);
  Result.Ref := ARef;
  Result.Params := Params(AParams);
end;

function TApprovalTest.Option(const AKey, ALabel: string; APersists: Boolean;
  const ARef: string; const AParams: array of string;
  AAny: Boolean): TApprovalOption;
begin
  Result := Default(TApprovalOption);
  Result.Key := AKey;
  Result.Caption := ALabel;
  Result.Persists := APersists;
  Result.Rule := DefaultApprovalRule(aeAllow);
  Result.Rule.Ref := ARef;
  Result.Rule.Params := Params(AParams);
  Result.Rule.AnyParams := AAny;
end;

function TApprovalTest.Ask(const ARef, ASummary: string;
  const AParams: array of string;
  const AOptions: array of TApprovalOption): TApprovalAsk;
var
  I: Integer;
begin
  Result := Default(TApprovalAsk);
  Result.Summary := ASummary;
  Result.Subject := Subject(ARef, AParams);
  SetLength(Result.Options, Length(AOptions));
  for I := 0 to High(AOptions) do
    Result.Options[I] := AOptions[I];
end;

{ TFakePrompt }

function TFakePrompt.Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
begin
  Inc(Calls);
  LastSummary := AAsk.Summary;
  Result := Default(TApprovalChoice);
  Result.Allowed := Allowed;
  Result.TimedOut := TimedOut;
  Result.OptionKey := OptionKey;
  Result.Scope := Scope;
end;

procedure TApprovalTest.TestSortOptionsByRiskPutsOnceFirst;
var
  A: TApprovalAsk;
begin
  { A deliberately mis-ordered ask: the broad grant is first and `once` is last,
    which is exactly what append-order produced in practice. }
  A := Default(TApprovalAsk);
  SetLength(A.Options, 4);
  A.Options[0].Key := 'bucket_rw';
  A.Options[1].Key := 'dir';
  A.Options[2].Key := 'any';
  A.Options[3].Key := 'once';
  SortOptionsByRisk(A);
  AssertEquals('once leads', 'once', A.Options[0].Key);
  AssertEquals('then the directory scope', 'dir', A.Options[1].Key);
  AssertEquals('then any-args', 'any', A.Options[2].Key);
  AssertEquals('the broadest bucket trails', 'bucket_rw', A.Options[3].Key);
end;

procedure TApprovalTest.TestUnrecognisedOptionSortsLast;
var
  A: TApprovalAsk;
begin
  { An option whose key we do not know must never jump ahead of `once` - a
    producer adding a new option should not be able to widen the first slot. }
  A := Default(TApprovalAsk);
  SetLength(A.Options, 2);
  A.Options[0].Key := 'something_new';
  A.Options[1].Key := 'once';
  SortOptionsByRisk(A);
  AssertEquals('once still leads', 'once', A.Options[0].Key);
  AssertEquals('the unknown trails', 'something_new', A.Options[1].Key);
end;

procedure TApprovalTest.TestExactRefAndParamsMatch;
begin
  AssertTrue('exact matches',
    ApprovalMatches(Rule(aeAllow, asGlobal, 0, '', 'run_command:cat',
      ['test'], False), Subject('run_command:cat', ['test'])));
end;

procedure TApprovalTest.TestExactParamsRejectDifferentArgs;
begin
  AssertFalse('different args',
    ApprovalMatches(Rule(aeAllow, asGlobal, 0, '', 'run_command:cat',
      ['test'], False), Subject('run_command:cat', ['other'])));
  AssertFalse('extra args not exact',
    ApprovalMatches(Rule(aeAllow, asGlobal, 0, '', 'run_command:cat',
      [], False), Subject('run_command:cat', ['test'])));
end;

procedure TApprovalTest.TestAnyParamsPrefixMatches;
begin
  AssertTrue('prefix matches',
    ApprovalMatches(Rule(aeAllow, asGlobal, 0, '', 'run_command:php',
      ['artisan'], True), Subject('run_command:php',
      ['artisan', 'migrate'])));
end;

procedure TApprovalTest.TestAnyParamsRejectsDifferentPrefix;
begin
  AssertFalse('different prefix',
    ApprovalMatches(Rule(aeAllow, asGlobal, 0, '', 'run_command:php',
      ['artisan'], True), Subject('run_command:php', ['foo'])));
end;

procedure TApprovalTest.TestEmptyAnyParamsMatchesWholeRef;
begin
  AssertTrue('whole ref',
    ApprovalMatches(Rule(aeAllow, asGlobal, 0, '', 'run_command:cat',
      [], True), Subject('run_command:cat', ['anything', 'at', 'all'])));
  AssertTrue('whole ref bare',
    ApprovalMatches(Rule(aeAllow, asGlobal, 0, '', 'run_command:cat',
      [], True), Subject('run_command:cat', [])));
end;

procedure TApprovalTest.TestRefMismatchDoesNotMatch;
begin
  AssertFalse('other ref',
    ApprovalMatches(Rule(aeAllow, asGlobal, 0, '', 'run_command:cat',
      [], True), Subject('run_command:ls', [])));
end;

procedure TApprovalTest.TestDenyWinsOverAllow;
var
  Rules: TApprovalRuleArray;
begin
  SetLength(Rules, 2);
  Rules[0] := Rule(aeAllow, asGlobal, 0, '', 'run_command:cat', [], True);
  Rules[1] := Rule(aeDeny, asGlobal, 0, '', 'run_command:cat', [], True);
  AssertEquals('deny wins', Ord(adDeny),
    Ord(Decide(Rules, Subject('run_command:cat', ['x']))));
end;

procedure TApprovalTest.TestScopePrecedenceSessionOverWorkspaceOverGlobal;
var
  Rules: TApprovalRuleArray;
begin
  SetLength(Rules, 1);
  Rules[0] := Rule(aeAllow, asGlobal, 0, '', 'run_command:cat', [], True);
  AssertEquals('global allow', Ord(adAllow),
    Ord(Decide(Rules, Subject('run_command:cat', []))));
  SetLength(Rules, 2);
  Rules[1] := Rule(aeAllow, asWorkspace, 7, '', 'run_command:ls', [], True);
  AssertEquals('workspace allow', Ord(adAllow),
    Ord(Decide(Rules, Subject('run_command:ls', []))));
  SetLength(Rules, 3);
  Rules[2] := Rule(aeAllow, asSession, 7, 'abc', 'run_command:pwd', [], True);
  AssertEquals('session allow', Ord(adAllow),
    Ord(Decide(Rules, Subject('run_command:pwd', []))));
end;

procedure TApprovalTest.TestBucketReadGrantCoversAReadCommand;
var
  R: TApprovalRule;
  S: TApprovalSubject;
begin
  { The point of buckets: one grant for a CLASS of work, not one binary at a
    time. A read grant covers grep, cat, wc - anything classified read. }
  R := Default(TApprovalRule);
  R.Effect := aeAllow;
  R.Bucket := abRead;
  S := Subject('run_command:grep', ['pat', 'f']);
  S.Bucket := abRead;
  AssertEquals('read grant covers grep', Ord(adAllow),
    Ord(Decide([R], S)));
  S := Subject('run_command:cat', ['f']);
  S.Bucket := abRead;
  AssertEquals('and cat, with no per-binary rule', Ord(adAllow),
    Ord(Decide([R], S)));
end;

procedure TApprovalTest.TestBucketNeverCoversAnUnknownEffect;
var
  R: TApprovalRule;
  S: TApprovalSubject;
begin
  { abNone means the producer could not classify the operation. A broad grant
    must NOT cover it, or an unknown effect would be silently authorised. }
  R := Default(TApprovalRule);
  R.Effect := aeAllow;
  R.Bucket := abAny;
  S := Subject('run_command:whatever', []);
  S.Bucket := abNone;
  AssertEquals('unknown is never covered', Ord(adAsk), Ord(Decide([R], S)));
end;

procedure TApprovalTest.TestBucketAnyCoversEverythingKnown;
var
  R: TApprovalRule;
  S: TApprovalSubject;
  B: TApprovalBucket;
begin
  R := Default(TApprovalRule);
  R.Effect := aeAllow;
  R.Bucket := abAny;
  for B := abRead to abOpaque do
  begin
    S := Subject('run_command:x', []);
    S.Bucket := B;
    AssertEquals('abAny covers bucket ' + IntToStr(Ord(B)), Ord(adAllow),
      Ord(Decide([R], S)));
  end;
end;

procedure TApprovalTest.TestBucketWriteGrantDoesNotCoverARead;
var
  R: TApprovalRule;
  S: TApprovalSubject;
begin
  { A write grant is not a read grant. Separate decisions. }
  R := Default(TApprovalRule);
  R.Effect := aeAllow;
  R.Bucket := abWrite;
  S := Subject('run_command:cat', ['f']);
  S.Bucket := abRead;
  AssertEquals('write does not cover read', Ord(adAsk), Ord(Decide([R], S)));
end;

procedure TApprovalTest.TestBucketRuleIgnoresRef;
var
  R: TApprovalRule;
  S: TApprovalSubject;
begin
  { A bucket rule that named a Ref would not be coarse. It must match on the
    effect class alone. }
  R := Default(TApprovalRule);
  R.Effect := aeAllow;
  R.Ref := 'run_command:somethingelse';
  R.Bucket := abRead;
  S := Subject('run_command:cat', ['f']);
  S.Bucket := abRead;
  AssertEquals('ref is ignored for a bucket rule', Ord(adAllow),
    Ord(Decide([R], S)));
end;

procedure TApprovalTest.TestNoMatchAsks;
begin
  AssertEquals('ask', Ord(adAsk),
    Ord(Decide(nil, Subject('run_command:rm', ['x']))));
end;

{ --- Approval Path Scoping (v1) ----------------------------------------- }

function PathSubject(const ARef, APath: string): TApprovalSubject;
begin
  Result := Default(TApprovalSubject);
  Result.Ref := ARef;
  Result.Path := APath;
end;

function PathRule(AEffect: TApprovalEffect; const ARef, ADirectory,
  AExtension: string): TApprovalRule;
begin
  Result := Default(TApprovalRule);
  Result.Effect := AEffect;
  Result.Scope := asGlobal;
  Result.Ref := ARef;
  Result.AnyParams := True;
  Result.Directory := ADirectory;
  Result.Extension := AExtension;
end;

procedure TApprovalTest.TestDirectoryMatchesSubtree;
begin
  AssertTrue('direct child', ApprovalMatches(
    PathRule(aeAllow, 'file:write', 'docs', ''),
    PathSubject('file:write', 'docs/a.md')));
  AssertTrue('deep descendant', ApprovalMatches(
    PathRule(aeAllow, 'file:write', 'docs', ''),
    PathSubject('file:write', 'docs/x/b.md')));
end;

procedure TApprovalTest.TestDirectoryDoesNotMatchPrefixSibling;
begin
  { `docs` must not match `docs.md` (a sibling prefix) nor `src/docs/a`. }
  AssertFalse('prefix sibling', ApprovalMatches(
    PathRule(aeAllow, 'file:write', 'docs', ''),
    PathSubject('file:write', 'docs.md')));
  AssertFalse('nested elsewhere', ApprovalMatches(
    PathRule(aeAllow, 'file:write', 'docs', ''),
    PathSubject('file:write', 'src/docs/a.md')));
end;

procedure TApprovalTest.TestExtensionMatchesCaseInsensitively;
begin
  AssertTrue('lower', ApprovalMatches(PathRule(aeAllow, 'file:edit', '', 'md'),
    PathSubject('file:edit', 'a.md')));
  AssertTrue('upper', ApprovalMatches(PathRule(aeAllow, 'file:edit', '', 'md'),
    PathSubject('file:edit', 'A.MD')));
  AssertFalse('other ext', ApprovalMatches(
    PathRule(aeAllow, 'file:edit', '', 'md'),
    PathSubject('file:edit', 'a.txt')));
end;

procedure TApprovalTest.TestExtensionNormalisesLeadingDot;
begin
  AssertTrue('rule with dot', ApprovalMatches(
    PathRule(aeAllow, 'file:edit', '', '.md'),
    PathSubject('file:edit', 'a.md')));
  AssertEquals('normalise strips dot', 'md', NormalizeExtension('.MD'));
end;

procedure TApprovalTest.TestEmptyDirectoryOrExtensionMatchesAny;
begin
  { A rule with neither dimension is a plain any-params rule (v1 behaviour),
    and a path is not required. }
  AssertTrue('v1 any', ApprovalMatches(PathRule(aeAllow, 'file:read', '', ''),
    PathSubject('file:read', 'anything.txt')));
  AssertTrue('pathless ok', ApprovalMatches(PathRule(aeAllow, 'file:read', '', ''),
    PathSubject('file:read', '')));
end;

procedure TApprovalTest.TestDirectoryAndExtensionBothRequired;
var
  R: TApprovalRule;
begin
  R := PathRule(aeAllow, 'file:edit', 'docs', 'md');
  AssertTrue('both hold', ApprovalMatches(R,
    PathSubject('file:edit', 'docs/x/a.md')));
  AssertFalse('right dir, wrong ext', ApprovalMatches(R,
    PathSubject('file:edit', 'docs/a.txt')));
  AssertFalse('right ext, wrong dir', ApprovalMatches(R,
    PathSubject('file:edit', 'src/a.md')));
end;

procedure TApprovalTest.TestV1RuleMatchesUnchanged;
begin
  { A rule from v1 (no path dimensions) still matches an exact/prefix subject,
    path or no path. }
  AssertTrue('exact', ApprovalMatches(Rule(aeAllow, asGlobal, 0, '',
    'run_command:cat', ['/etc/os-release'], False),
    Subject('run_command:cat', ['/etc/os-release'])));
end;

procedure TApprovalTest.TestScopedDenyWins;
var
  Rules: TApprovalRuleArray;
begin
  { An allow for .md under docs/, and a deny for .env anywhere: the deny wins
    for a .env, the allow for the .md. }
  SetLength(Rules, 2);
  Rules[0] := PathRule(aeAllow, 'file:edit', 'docs', 'md');
  Rules[1] := PathRule(aeDeny, 'file:edit', '', 'env');
  AssertEquals('md allowed', Ord(adAllow),
    Ord(Decide(Rules, PathSubject('file:edit', 'docs/a.md'))));
  AssertEquals('env denied', Ord(adDeny),
    Ord(Decide(Rules, PathSubject('file:edit', 'docs/.env'))));
end;

procedure TApprovalTest.TestPathlessSubjectNeverMatchesPathRule;
begin
  { A subject with no path cannot be matched by a directory/extension rule. }
  AssertFalse('no path', ApprovalMatches(
    PathRule(aeAllow, 'file:write', 'docs', ''),
    PathSubject('file:write', '')));
end;

procedure TApprovalTest.TestExactCommandGrantSuppressesThePathAsk;
var
  Store: IApprovalStore;
  Prompt: TFakePrompt;
  Svc: IApprovalService;
  Asks: TApprovalAskArray;
  R: TApprovalRule;
  Res: TApprovalBatchResult;
  Err: string;
begin
  { An EXACT command grant ("allow exactly `cat /etc/hosts`") suppresses the
    path ask that covers it: the operator already said yes to this precise
    command, so the location ask is redundant. }
  Store := TMemoryApprovalStore.Create;
  R := Default(TApprovalRule);
  R.Effect := aeAllow;
  R.Scope := asGlobal;
  R.Ref := 'run_command:cat';
  R.Params := Params(['/etc/hosts']);
  R.AnyParams := False;
  Store.Save(R, Err);
  Prompt := TFakePrompt.Create;
  try
    Svc := TApprovalService.Create(Store, Prompt.Prompt,
      Default(TApprovalContext));
    SetLength(Asks, 1);
    Asks[0] := Default(TApprovalAsk);
    Asks[0].Summary := 'read /etc/hosts';
    Asks[0].Subject := Subject('path:/etc/hosts', []);
    Asks[0].HasCovers := True;
    Asks[0].Covers := Subject('run_command:cat', ['/etc/hosts']);
    AssertTrue('resolved', Svc.Resolve(Asks, Res));
    AssertTrue('allowed', Res.Allowed);
    AssertEquals('no prompt', 0, Prompt.Calls);
  finally
    Prompt.Free;
  end;
end;

procedure TApprovalTest.TestWildcardCommandGrantDoesNotSuppressIt;
var
  Store: IApprovalStore;
  Prompt: TFakePrompt;
  Svc: IApprovalService;
  Asks: TApprovalAskArray;
  R: TApprovalRule;
  Res: TApprovalBatchResult;
  Err: string;
begin
  { A WILDCARD grant ("allow any cat") covers the command but NOT the location,
    so the path ask still prompts. }
  Store := TMemoryApprovalStore.Create;
  R := Default(TApprovalRule);
  R.Effect := aeAllow;
  R.Scope := asGlobal;
  R.Ref := 'run_command:cat';
  R.AnyParams := True;
  Store.Save(R, Err);
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'once';
    Svc := TApprovalService.Create(Store, Prompt.Prompt,
      Default(TApprovalContext));
    SetLength(Asks, 1);
    Asks[0] := Default(TApprovalAsk);
    Asks[0].Summary := 'read /etc/hosts';
    Asks[0].Subject := Subject('path:/etc/hosts', []);
    Asks[0].HasCovers := True;
    Asks[0].Covers := Subject('run_command:cat', ['/etc/hosts']);
    Asks[0].Options := [Option('once', 'allow once', False,
      'path:/etc/hosts', [], False)];
    AssertTrue('resolved', Svc.Resolve(Asks, Res));
    AssertEquals('still prompted', 1, Prompt.Calls);
  finally
    Prompt.Free;
  end;
end;

procedure TApprovalTest.TestMemoryStoreSuppressesDuplicates;
var
  Store: IApprovalStore;
  Ctx: TApprovalContext;
  Rules: TApprovalRuleArray;
  Err: string;
  R: TApprovalRule;
begin
  Store := TMemoryApprovalStore.Create;
  Ctx := Default(TApprovalContext);
  R := Rule(aeAllow, asGlobal, 0, '', 'run_command:cat', [], True);
  AssertTrue('save 1', Store.Save(R, Err));
  AssertTrue('save 2', Store.Save(R, Err));
  AssertTrue('load', Store.Load(Ctx, Rules, Err));
  AssertEquals('one rule', 1, Length(Rules));
end;

procedure TApprovalTest.TestMemoryStoreFiltersByContext;
var
  Store: IApprovalStore;
  Ctx: TApprovalContext;
  Rules: TApprovalRuleArray;
  Err: string;
begin
  Store := TMemoryApprovalStore.Create;
  Store.Save(Rule(aeAllow, asGlobal, 0, '', 'run_command:cat', [], True), Err);
  Store.Save(Rule(aeAllow, asWorkspace, 7, '', 'run_command:ls', [], True), Err);
  Store.Save(Rule(aeAllow, asWorkspace, 8, '', 'run_command:ls', [], True), Err);
  Store.Save(Rule(aeAllow, asSession, 7, 's1', 'run_command:pwd', [], True), Err);

  Ctx.WorkspaceId := 7;
  Ctx.SessionId := 's1';
  Store.Load(Ctx, Rules, Err);
  AssertEquals('global + ws7 + session s1', 3, Length(Rules));

  Ctx.WorkspaceId := 8;
  Ctx.SessionId := '';
  Store.Load(Ctx, Rules, Err);
  AssertEquals('global + ws8', 2, Length(Rules));
end;

procedure TApprovalTest.TestTimedOutPromptReportsTimeout;
var
  Store: IApprovalStore;
  Prompt: TFakePrompt;
  Svc: IApprovalService;
  Asks: TApprovalAskArray;
  Result_: TApprovalBatchResult;
begin
  { A prompt that timed out is not an operator decision: the denial must say so. }
  Store := TMemoryApprovalStore.Create;
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := False;
    Prompt.TimedOut := True;
    Svc := TApprovalService.Create(Store, Prompt.Prompt,
      Default(TApprovalContext));
    SetLength(Asks, 1);
    Asks[0] := Ask('run_command:ls', 'ls', [],
      [Option('once', 'once', False, 'run_command:ls', [], False)]);
    AssertTrue('resolved', Svc.Resolve(Asks, Result_));
    AssertTrue('denied', Result_.Denied);
    AssertTrue('reported as a timeout', Pos('timed out', Result_.Reason) > 0);
    AssertTrue('not blamed on the operator',
      Pos('denied by operator', Result_.Reason) = 0);
  finally
    Prompt.Free;
  end;
end;

procedure TApprovalTest.TestBatchDenyPreScanDoesNotPrompt;
var
  Store: IApprovalStore;
  Prompt: TFakePrompt;
  Svc: IApprovalService;
  Asks: TApprovalAskArray;
  Result_: TApprovalBatchResult;
  Err: string;
  R: TApprovalRule;
begin
  Store := TMemoryApprovalStore.Create;
  R := Rule(aeDeny, asGlobal, 0, '', 'run_command:rm', [], True);
  Store.Save(R, Err);
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    Svc := TApprovalService.Create(Store, Prompt.Prompt,
      Default(TApprovalContext));
    SetLength(Asks, 2);
    Asks[0] := Ask('run_command:ls', 'ls', [],
      [Option('once', 'once', False, 'run_command:ls', [], False)]);
    Asks[1] := Ask('run_command:rm', 'rm', [],
      [Option('once', 'once', False, 'run_command:rm', [], False)]);
    AssertTrue('resolved', Svc.Resolve(Asks, Result_));
    AssertTrue('denied', Result_.Denied);
    AssertEquals('no prompt', 0, Prompt.Calls);
  finally
    Prompt.Free;
  end;
end;

procedure TApprovalTest.TestAllowFromRuleDoesNotPrompt;
var
  Store: IApprovalStore;
  Prompt: TFakePrompt;
  Svc: IApprovalService;
  Asks: TApprovalAskArray;
  Result_: TApprovalBatchResult;
  Err: string;
begin
  Store := TMemoryApprovalStore.Create;
  Store.Save(Rule(aeAllow, asGlobal, 0, '', 'run_command:ls', [], True), Err);
  Prompt := TFakePrompt.Create;
  try
    Svc := TApprovalService.Create(Store, Prompt.Prompt,
      Default(TApprovalContext));
    SetLength(Asks, 1);
    Asks[0] := Ask('run_command:ls', 'ls', [],
      [Option('once', 'once', False, 'run_command:ls', [], False)]);
    AssertTrue('resolved', Svc.Resolve(Asks, Result_));
    AssertTrue('allowed', Result_.Allowed);
    AssertEquals('no prompt', 0, Prompt.Calls);
  finally
    Prompt.Free;
  end;
end;

procedure TApprovalTest.TestPromptPersistsChosenRuleAtChosenScope;
var
  Store: IApprovalStore;
  Prompt: TFakePrompt;
  Svc: IApprovalService;
  Asks: TApprovalAskArray;
  Result_: TApprovalBatchResult;
  Rules: TApprovalRuleArray;
  Ctx: TApprovalContext;
  Err: string;
begin
  Store := TMemoryApprovalStore.Create;
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'any';
    Prompt.Scope := asWorkspace;
    Ctx.WorkspaceId := 7;
    Svc := TApprovalService.Create(Store, Prompt.Prompt, Ctx);
    SetLength(Asks, 1);
    Asks[0] := Ask('run_command:cat', 'cat test', ['test'],
      [Option('any', 'cat *', True, 'run_command:cat', [], True)]);
    AssertTrue('resolved', Svc.Resolve(Asks, Result_));
    AssertTrue('allowed', Result_.Allowed);

    Store.Load(Ctx, Rules, Err);
    AssertEquals('persisted one', 1, Length(Rules));
    AssertEquals('scope workspace', Ord(asWorkspace), Ord(Rules[0].Scope));
    AssertEquals('workspace id', 7, Rules[0].WorkspaceId);
    AssertTrue('any params', Rules[0].AnyParams);
  finally
    Prompt.Free;
  end;
end;

procedure TApprovalTest.TestOnceChoiceDoesNotPersist;
var
  Store: IApprovalStore;
  Prompt: TFakePrompt;
  Svc: IApprovalService;
  Asks: TApprovalAskArray;
  Result_: TApprovalBatchResult;
  Rules: TApprovalRuleArray;
  Err: string;
begin
  Store := TMemoryApprovalStore.Create;
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'once';
    Svc := TApprovalService.Create(Store, Prompt.Prompt,
      Default(TApprovalContext));
    SetLength(Asks, 1);
    Asks[0] := Ask('run_command:cat', 'cat test', ['test'],
      [Option('once', 'once', False, 'run_command:cat', ['test'], False)]);
    AssertTrue('resolved', Svc.Resolve(Asks, Result_));
    AssertTrue('allowed', Result_.Allowed);
    Store.Load(Default(TApprovalContext), Rules, Err);
    AssertEquals('nothing persisted', 0, Length(Rules));
  finally
    Prompt.Free;
  end;
end;

procedure TApprovalTest.TestMissingPromptDenies;
var
  Store: IApprovalStore;
  Svc: IApprovalService;
  Asks: TApprovalAskArray;
  Result_: TApprovalBatchResult;
begin
  Store := TMemoryApprovalStore.Create;
  Svc := TApprovalService.Create(Store, nil, Default(TApprovalContext));
  SetLength(Asks, 1);
  Asks[0] := Ask('run_command:cat', 'cat test', ['test'],
    [Option('once', 'once', False, 'run_command:cat', ['test'], False)]);
  AssertTrue('resolved', Svc.Resolve(Asks, Result_));
  AssertTrue('denied', Result_.Denied);
end;

procedure TApprovalTest.TestInvalidOptionDenies;
var
  Store: IApprovalStore;
  Prompt: TFakePrompt;
  Svc: IApprovalService;
  Asks: TApprovalAskArray;
  Result_: TApprovalBatchResult;
begin
  Store := TMemoryApprovalStore.Create;
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'nope';
    Svc := TApprovalService.Create(Store, Prompt.Prompt,
      Default(TApprovalContext));
    SetLength(Asks, 1);
    Asks[0] := Ask('run_command:cat', 'cat test', ['test'],
      [Option('once', 'once', False, 'run_command:cat', ['test'], False)]);
    Svc.Resolve(Asks, Result_);
    AssertTrue('denied', Result_.Denied);
  finally
    Prompt.Free;
  end;
end;

procedure TApprovalTest.TestStoreSaveLoadRemoveRoundTrip;
var
  Store: TSqliteStore;
  Src: IApprovalStore;
  Ctx: TApprovalContext;
  Rules: TApprovalRuleArray;
  E: string;
begin
  Store := OpenStore;
  try
    Src := TStoreApprovalStore.Create(Store);
    Ctx.WorkspaceId := 7;
    Ctx.SessionId := 's1';
    AssertTrue('save', Src.Save(Rule(aeAllow, asWorkspace, 7, '',
      'run_command:cat', ['test'], False), E));
    AssertTrue('load', Src.Load(Ctx, Rules, E));
    AssertEquals('one', 1, Length(Rules));
    AssertEquals('ref', 'run_command:cat', Rules[0].Ref);
    AssertEquals('params count', 1, Length(Rules[0].Params));
    AssertEquals('param', 'test', Rules[0].Params[0]);
    AssertTrue('remove', Src.Remove(Rules[0], E));
    AssertTrue('load empty', Src.Load(Ctx, Rules, E));
    AssertEquals('none', 0, Length(Rules));
  finally
    Store.Free;
  end;
end;

procedure TApprovalTest.TestBucketRuleRoundTrips;
var
  Store: TSqliteStore;
  Src: IApprovalStore;
  Ctx: TApprovalContext;
  Rules: TApprovalRuleArray;
  R: TApprovalRule;
  E: string;
  S: TApprovalSubject;
begin
  { The reported bug: "could not persist approval: approval ref is required".
    A bucket rule carries NO ref by design - that is what makes it coarse - and
    the store required one, so every bucket grant failed to save. Fixing it needed
    a schema column too, because a bucket is the rule's identity. }
  Store := OpenStore;
  try
    Src := TStoreApprovalStore.Create(Store);
    Ctx.WorkspaceId := 7;
    Ctx.SessionId := 's1';
    R := Default(TApprovalRule);
    R.Effect := aeAllow;
    R.Scope := asWorkspace;
    R.WorkspaceId := 7;
    R.Ref := '';                 // a bucket rule has no ref
    R.Bucket := abRead;
    AssertTrue('save a bucket rule', Src.Save(R, E));
    AssertTrue('load', Src.Load(Ctx, Rules, E));
    AssertEquals('one rule', 1, Length(Rules));
    AssertEquals('the bucket survived', Ord(abRead), Ord(Rules[0].Bucket));
    AssertEquals('and it still has no ref', '', Rules[0].Ref);
    { And it actually MATCHES after the round trip, which is the point. }
    S := Subject('run_command:grep', ['pat', 'f']);
    S.Bucket := abRead;
    AssertEquals('a read command is covered after reload', Ord(adAllow),
      Ord(Decide(Rules, S)));
  finally
    Store.Free;
  end;
end;

procedure TApprovalTest.TestPathRulesRoundTrip;
var
  Store: TSqliteStore;
  Src: IApprovalStore;
  Ctx: TApprovalContext;
  Rules: TApprovalRuleArray;
  R: TApprovalRule;
  E: string;
begin
  Store := OpenStore;
  try
    Src := TStoreApprovalStore.Create(Store);
    Ctx.WorkspaceId := 7;
    Ctx.SessionId := 's1';
    R := PathRule(aeAllow, 'file:edit', 'docs', 'md');
    R.Scope := asWorkspace;
    R.WorkspaceId := 7;
    AssertTrue('save', Src.Save(R, E));
    AssertTrue('load', Src.Load(Ctx, Rules, E));
    AssertEquals('one', 1, Length(Rules));
    AssertEquals('directory', 'docs', Rules[0].Directory);
    AssertEquals('extension', 'md', Rules[0].Extension);
    AssertTrue('remove', Src.Remove(Rules[0], E));
  finally
    Store.Free;
  end;
end;

procedure TApprovalTest.TestRulesDifferingOnlyByPathCoexist;
var
  Store: TSqliteStore;
  Src: IApprovalStore;
  Ctx: TApprovalContext;
  Rules: TApprovalRuleArray;
  R: TApprovalRule;
  E: string;
begin
  { Two rules with the same ref/scope/params but different directories must
    coexist (the extended UNIQUE includes them). }
  Store := OpenStore;
  try
    Src := TStoreApprovalStore.Create(Store);
    Ctx.WorkspaceId := 7;
    Ctx.SessionId := 's1';
    R := PathRule(aeAllow, 'file:edit', 'docs', 'md');
    R.Scope := asWorkspace; R.WorkspaceId := 7;
    AssertTrue('save docs', Src.Save(R, E));
    R.Directory := 'src';
    AssertTrue('save src', Src.Save(R, E));
    AssertTrue('load', Src.Load(Ctx, Rules, E));
    AssertEquals('both coexist', 2, Length(Rules));
  finally
    Store.Free;
  end;
end;

procedure TApprovalTest.TestApprovalsMigrationRebuildsWithPathColumns;
var
  Store: TSqliteStore;
  Src: IApprovalStore;
  Ctx: TApprovalContext;
  Rules: TApprovalRuleArray;
  E: string;
begin
  { A v1-shaped rule (no path dimensions) survives the v12 rebuild and still
    loads with empty path columns. }
  Store := OpenStore;
  try
    Src := TStoreApprovalStore.Create(Store);
    Ctx.WorkspaceId := 7;
    Ctx.SessionId := 's1';
    AssertTrue('save v1 rule', Src.Save(Rule(aeAllow, asWorkspace, 7, '',
      'run_command:cat', ['test'], False), E));
    AssertTrue('load', Src.Load(Ctx, Rules, E));
    AssertEquals('one', 1, Length(Rules));
    AssertEquals('no directory', '', Rules[0].Directory);
    AssertEquals('no extension', '', Rules[0].Extension);
    { And it still matches exactly as before. }
    AssertTrue('matches unchanged', ApprovalMatches(Rules[0],
      Subject('run_command:cat', ['test'])));
  finally
    Store.Free;
  end;
end;

procedure TApprovalTest.TestStoreSuppressesDuplicates;
var
  Store: TSqliteStore;
  Src: IApprovalStore;
  Ctx: TApprovalContext;
  Rules: TApprovalRuleArray;
  E: string;
  R: TApprovalRule;
begin
  Store := OpenStore;
  try
    Src := TStoreApprovalStore.Create(Store);
    Ctx.WorkspaceId := 0;
    Ctx.SessionId := '';
    R := Rule(aeAllow, asGlobal, 0, '', 'run_command:cat', [], True);
    AssertTrue('save 1', Src.Save(R, E));
    AssertTrue('save 2', Src.Save(R, E));
    AssertTrue('load', Src.Load(Ctx, Rules, E));
    AssertEquals('one', 1, Length(Rules));
  finally
    Store.Free;
  end;
end;

procedure TApprovalTest.TestStoreFiltersByContext;
var
  Store: TSqliteStore;
  Src: IApprovalStore;
  Ctx: TApprovalContext;
  Rules: TApprovalRuleArray;
  E: string;
begin
  Store := OpenStore;
  try
    Src := TStoreApprovalStore.Create(Store);
    Src.Save(Rule(aeAllow, asGlobal, 0, '', 'run_command:cat', [], True), E);
    Src.Save(Rule(aeAllow, asWorkspace, 7, '', 'run_command:ls', [], True), E);
    Src.Save(Rule(aeAllow, asWorkspace, 8, '', 'run_command:ls', [], True), E);
    Src.Save(Rule(aeAllow, asSession, 7, 's1', 'run_command:pwd', [], True), E);

    Ctx.WorkspaceId := 7;
    Ctx.SessionId := 's1';
    Src.Load(Ctx, Rules, E);
    AssertEquals('global + ws7 + s1', 3, Length(Rules));

    Ctx.WorkspaceId := 8;
    Ctx.SessionId := '';
    Src.Load(Ctx, Rules, E);
    AssertEquals('global + ws8', 2, Length(Rules));
  finally
    Store.Free;
  end;
end;

procedure TApprovalTest.TestChildResolvesAgainstRootScope;
var
  Store: IApprovalStore;
  Prompt: TFakePrompt;
  Svc: IApprovalService;
  Asks: TApprovalAskArray;
  Result_: TApprovalBatchResult;
  Err: string;
  Ctx: TApprovalContext;
begin
  { A grant made under the lineage root's session scope. }
  Store := TMemoryApprovalStore.Create;
  Store.Save(Rule(aeAllow, asSession, 0, 'root-session', 'run_command:ls',
    [], True), Err);
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    { The child resolves with the ROOT session id as its context, so the grant
      is in force for the child. }
    Ctx := Default(TApprovalContext);
    Ctx.WorkspaceId := 0;
    Ctx.SessionId := 'root-session';
    Svc := TApprovalService.Create(Store, Prompt.Prompt, Ctx);
    SetLength(Asks, 1);
    Asks[0] := Ask('run_command:ls', 'ls', [],
      [Option('once', 'once', False, 'run_command:ls', [], False)]);
    AssertTrue('resolved', Svc.Resolve(Asks, Result_));
    AssertTrue('allowed from the root grant', Result_.Allowed);
    AssertEquals('no prompt needed', 0, Prompt.Calls);
  finally
    Prompt.Free;
  end;
end;

procedure TApprovalTest.TestGrantForOneChildAppliesToSibling;
var
  Store: IApprovalStore;
  Prompt: TFakePrompt;
  SvcA, SvcB: IApprovalService;
  Asks: TApprovalAskArray;
  Result_: TApprovalBatchResult;
  Ctx: TApprovalContext;
begin
  { A grant made while resolving for child A is stored at the root session
    scope, so a sibling child B (same root context) is allowed without a new
    prompt. }
  Store := TMemoryApprovalStore.Create;
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'exact';
    Prompt.Scope := asSession;
    Ctx := Default(TApprovalContext);
    Ctx.SessionId := 'root-session';
    SvcA := TApprovalService.Create(Store, Prompt.Prompt, Ctx);
    SetLength(Asks, 1);
    Asks[0] := Ask('run_command:git', 'git status', [],
      [Option('exact', 'always this exact command', True, 'run_command:git',
        [], False)]);
    AssertTrue('child A resolved', SvcA.Resolve(Asks, Result_));
    AssertTrue('child A allowed', Result_.Allowed);
    AssertEquals('child A prompted once', 1, Prompt.Calls);

    { Sibling B, same lineage context: no new prompt. }
    SvcB := TApprovalService.Create(Store, Prompt.Prompt, Ctx);
    AssertTrue('child B resolved', SvcB.Resolve(Asks, Result_));
    AssertTrue('child B allowed from the shared grant', Result_.Allowed);
    AssertEquals('no extra prompt for the sibling', 1, Prompt.Calls);
  finally
    Prompt.Free;
  end;
end;

procedure TApprovalTest.TestConcurrentResolveDoesNotDoublePrompt;
var
  Store: IApprovalStore;
  Prompt: TBlockingPrompt;
  Svc: IApprovalService;
  Asks: TApprovalAskArray;
  T1, T2: TResolveThread;
begin
  { Two concurrent resolutions of the same subject, both needing a prompt. The
    first prompts and (on grant) persists a rule; the second must see that rule
    after acquiring the prompt lock and NOT prompt again. }
  Store := TMemoryApprovalStore.Create;
  Prompt := TBlockingPrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'any';
    Svc := TApprovalService.Create(Store, Prompt.Prompt,
      Default(TApprovalContext));
    SetLength(Asks, 1);
    Asks[0] := Ask('run_command:cat', 'cat a', [],
      [Option('any', 'always', True, 'run_command:cat', [], True)]);

    T1 := TResolveThread.Create(Svc, Asks);
    T2 := TResolveThread.Create(Svc, Asks);
    T1.Start;
    { Wait until T1 is inside the prompt. }
    AssertTrue('first prompt entered', Prompt.WaitEntered(2000));
    T2.Start;
    { Let T2 reach the prompt lock (it will block behind T1). }
    Sleep(50);

    { Release T1's prompt; both should now complete. }
    Prompt.Release;
    T1.WaitFor;
    T2.WaitFor;

    AssertTrue('T1 allowed', T1.Allowed);
    AssertTrue('T2 allowed', T2.Allowed);
    AssertEquals('prompted exactly once (no double-prompt)', 1, Prompt.Calls);

    T1.Free;
    T2.Free;
  finally
    Prompt.Free;
  end;
end;

procedure TApprovalTest.TestNoPromptResolveIsNotBlockedByAPromptingSibling;
var
  Store: IApprovalStore;
  Prompt: TBlockingPrompt;
  Svc: IApprovalService;
  GatedAsks, AllowedAsks: TApprovalAskArray;
  T1, T2: TResolveThread;
  R: TApprovalRule;
  Err: string;
begin
  { One resolve prompts and blocks; a second resolve whose subject is already
    allowed must complete while the first is still waiting on the operator. This
    is the whole point: approval must not head-of-line block cleared work. }
  Store := TMemoryApprovalStore.Create;
  R := Rule(aeAllow, asGlobal, 0, '', 'file:read', [], True);
  Store.Save(R, Err);
  Prompt := TBlockingPrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'any';
    Svc := TApprovalService.Create(Store, Prompt.Prompt,
      Default(TApprovalContext));

    { The gated ask (no matching rule) and the already-allowed ask. }
    SetLength(GatedAsks, 1);
    GatedAsks[0] := Ask('run_command:rm', 'rm -rf', [],
      [Option('any', 'always', True, 'run_command:rm', [], True)]);
    SetLength(AllowedAsks, 1);
    AllowedAsks[0] := Ask('file:read', 'read x', [],
      [Option('once', 'once', False, 'file:read', [], False)]);

    T1 := TResolveThread.Create(Svc, GatedAsks);
    T1.Start;
    AssertTrue('gated prompt entered', Prompt.WaitEntered(2000));

    { While T1 is blocked in the prompt, T2 (allowed) must finish. }
    T2 := TResolveThread.Create(Svc, AllowedAsks);
    T2.Start;
    T2.WaitFor;
    AssertTrue('the allowed call completed while the sibling prompted',
      T2.Allowed);
    AssertFalse('the gated call is still waiting', T1.Done);

    Prompt.Release;
    T1.WaitFor;
    AssertTrue('the gated call then completed', T1.Allowed);

    T1.Free;
    T2.Free;
  finally
    Prompt.Free;
  end;
end;

initialization
  RegisterTest(TApprovalTest);
end.
