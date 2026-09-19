unit test_approval;
{ fpcunit tests for hildegard.helper.approval: the generic matcher, in-memory
  store, and the resolve service. No SQLite, no prompting side effects. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, hildegard.helper.approval;

type
  { Scripted approval prompt. }
  TFakePrompt = class
  public
    Allowed: Boolean;
    OptionKey: string;
    Scope: TApprovalScope;
    Calls: Integer;
    LastSummary: string;
    function Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
  end;

  TApprovalTest = class(TTestCase)
  private
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
    procedure TestExactRefAndParamsMatch;
    procedure TestExactParamsRejectDifferentArgs;
    procedure TestAnyParamsPrefixMatches;
    procedure TestAnyParamsRejectsDifferentPrefix;
    procedure TestEmptyAnyParamsMatchesWholeRef;
    procedure TestRefMismatchDoesNotMatch;
    procedure TestDenyWinsOverAllow;
    procedure TestScopePrecedenceSessionOverWorkspaceOverGlobal;
    procedure TestNoMatchAsks;
    procedure TestMemoryStoreSuppressesDuplicates;
    procedure TestMemoryStoreFiltersByContext;
    procedure TestBatchDenyPreScanDoesNotPrompt;
    procedure TestAllowFromRuleDoesNotPrompt;
    procedure TestPromptPersistsChosenRuleAtChosenScope;
    procedure TestOnceChoiceDoesNotPersist;
    procedure TestMissingPromptDenies;
    procedure TestInvalidOptionDenies;
  end;

implementation

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
  Result.OptionKey := OptionKey;
  Result.Scope := Scope;
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

procedure TApprovalTest.TestNoMatchAsks;
begin
  AssertEquals('ask', Ord(adAsk),
    Ord(Decide(nil, Subject('run_command:rm', ['x']))));
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

initialization
  RegisterTest(TApprovalTest);
end.
