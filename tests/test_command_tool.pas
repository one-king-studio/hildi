unit test_command_tool;
{ fpcunit tests for hildegard.helper.command.tool: the approval-driven shell
  tool. Uses a fake executor and prompt and an in-memory approval store; one
  test exercises the real process executor. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.agent, hildegard.helper.llm,
  hildegard.helper.command.policy, hildegard.helper.approval,
  hildegard.helper.command.tool, hildegard.helper.workspace.changes;

type
  TFakeExecutor = class(TNoRefCountObject, ICommandExecutor)
  public
    Calls: Integer;
    ReturnOk: Boolean;
    RaiseOnExecute: Boolean;
    LastCommand: string;
    LastCwd: string;
    LastTimeoutMs: QWord;
    ResultExec: TCommandExecution;
    Chunks: array of string;   // forwarded to the observer, in order
    LastMode: TCommandMode;
    ChangeCount: Integer;      // fake writes the executor reports (default 1)
    constructor Create;
    function OwnsApproval(const ACommand: string; AMode: TCommandMode;
      out AWhy: string): Boolean;
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord; AObserver: TToolObserver;
      const AReason: string; AMode: TCommandMode; AChanges: TFileChangeSet;
      out AExecution: TCommandExecution): Boolean;
  end;

  { Collects streamed chunks into one string. }
  TChunkLog = class
  public
    Text: string;
    procedure OnChunk(const AId, AName, AText: string);
  end;

  TFakePrompt = class
  public
    Allowed: Boolean;
    OptionKey: string;
    Scope: TApprovalScope;
    Calls: Integer;
    LastAsk: TApprovalAsk;
    { What the panel had been told when the dialog was raised. }
    Probe: TChunkLog;
    SeenAtPrompt: string;
    function Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
  end;

  TCommandToolTest = class(TTestCase)
  private
    FExecutor: TFakeExecutor;
    FApprovalStore: IApprovalStore;
  FChangeCount: Integer;
    function MakeConfig(AMaxBytes: Integer): TCommandToolConfig;
    function BuildTool(APrompt: TApprovalPrompt;
      AMaxBytes: Integer): TCommandTool;
    function BuildToolWithRoot(ARoot: string): TCommandTool;
    function AddRule(AEffect: TApprovalEffect; const ARef: string;
      const AParams: array of string; AAny: Boolean): TApprovalRule;
    function ServiceWith(APrompt: TApprovalPrompt): IApprovalService;
    procedure OnChanges(const AChanges: TFileChangeSet;
      const AToolCallId: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRegisterAddsRunCommandSpec;
    procedure TestRegisteredSpecIsParallelSafe;
    procedure TestDescriptionNamesTheShellStartDirectory;
    procedure TestDefaultShellProfileIsPosixBash;
    procedure TestMissingCommandArgumentFails;
    procedure TestInvalidJsonFails;
    procedure TestMissingReasonNotExecuted;
    procedure TestAllowedByRuleExecutes;
    procedure TestResultReadsLikeAShellTranscript;
    procedure TestDeniedByRuleDoesNotExecute;
    procedure TestAskWithNoPromptDenies;
    procedure TestPromptAllowOnceDoesNotPersist;
    procedure TestPromptExactPersistsAndAllowsSame;
    procedure TestPromptAnyAllowsOtherArgs;
    procedure TestPromptPrefixScopesSubtree;
    procedure TestAsksNameTheScriptAndItsSpan;
    procedure TestStructuralWordsAreNotCommands;
    procedure TestApprovalAsksPerSegment;
    procedure TestSubstitutionIsShownInTheAsk;
    procedure TestWildcardAllowedCatStillAsksAboutThePath;
    procedure TestExactlyApprovedCatDoesNotAskAboutThePath;
    procedure TestUnknownCommandAsksForBoth;
    procedure TestApprovalAsksCarryTheReason;
    procedure TestRunCarriesTheReasonIntoTheAsk;
    procedure TestOutputIsTruncatedWithMarker;
    procedure TestOutputTruncationKeepsUtf8Whole;
    procedure TestTimeoutReports124;
    procedure TestHandlerNeverRaises;
    procedure TestCommandPreservesUtf8;
    procedure TestProcessExecutorRunsCommand;
    procedure TestRunCommandStreamsOutput;
    procedure TestCommandIsShownBeforeApproval;
    procedure TestCommandTimeoutIsClampedToMax;
    procedure TestTimeoutIsHonouredWithoutACap;
    procedure TestHtmlEntitiesAreDecoded;
    procedure TestBucketOptionIsOfferedForTheMatchingClass;
    { A regex containing '/' is not a directory. }
    procedure TestAwkRegexIsNotTreatedAsAPath;
    { A command naming a real file must offer file-scope options. }
    procedure TestACommandNamingFilesOffersFileScopes;
    { All five scopes the operator asked for: exact, ext, dir, dir+ext, all. }
    procedure TestACommandAskOffersAllFiveFileScopes;
    { A read ask highlights the COMMAND, not the redirect. }
    procedure TestTheReadAskExcludesTheRedirect;
    procedure TestRedirectSummaryAndFileAsk;
    procedure TestRedirectReadAsk;
    procedure TestFdDuplicateIsNotAFileAsk;
    procedure TestOutsideRedirectKeepsThePathAsk;
    procedure TestRunDeliversFileChanges;
    { A command that prints nothing must SAY it printed nothing: an empty result
      body leaves the agent staring at a tail with no information about whether
      the command ran at all. }
    procedure TestSilentCommandSaysNoContent;
    procedure TestNoChangeNoteWithoutChanges;
    { Every failure names the command it failed on, so an operator can tell what
      broke without seeing the arguments JSON. }
    procedure TestAnErrorNamesTheFailingCommand;
    procedure TestAParseErrorNamesTheCommand;
    procedure TestProcessExecutorRecordsRealWrites;
    procedure TestModeBashIsPassedThrough;
    procedure TestModeDefaultsToAuto;
    procedure TestInvalidModeIsRejected;
    procedure TestModeBuiltinRefusesUnsupportedWithoutAsking;
  end;

implementation

constructor TFakeExecutor.Create;
begin
  inherited Create;
  ReturnOk := True;
  ChangeCount := 1;
  ResultExec := Default(TCommandExecution);
  ResultExec.Started := True;
  ResultExec.Output := 'out';
  ResultExec.ExitCode := 0;
end;

function TFakeExecutor.OwnsApproval(const ACommand: string;
  AMode: TCommandMode; out AWhy: string): Boolean;
begin
  AWhy := '';
  Result := False;
end;

function TFakeExecutor.Execute(const AProfile: TShellProfile;
  const ACommand, AWorkDir: string; ATimeoutMs: QWord; AObserver: TToolObserver;
  const AReason: string; AMode: TCommandMode; AChanges: TFileChangeSet;
  out AExecution: TCommandExecution): Boolean;
var
  I: Integer;
  Change: TFileChange;
begin
  if RaiseOnExecute then
    raise Exception.Create('executor boom');
  Inc(Calls);
  LastCommand := ACommand;
  LastCwd := AWorkDir;
  LastTimeoutMs := ATimeoutMs;
  LastMode := AMode;
  if AChanges <> nil then
    for I := 0 to ChangeCount - 1 do
    begin
      Change := Default(TFileChange);
      if ChangeCount = 1 then
        Change.Path := 'fake.txt'
      else
        Change.Path := 'fake' + IntToStr(I) + '.txt';
      Change.Kind := fcCreated;
      Change.After := 'x';
      AChanges.Add(Change);
    end;
  for I := 0 to High(Chunks) do
    if AObserver <> nil then
      AObserver.Next(Chunks[I]);
  AExecution := ResultExec;
  Result := ReturnOk;
end;

function TFakePrompt.Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
begin
  if Probe <> nil then
    SeenAtPrompt := Probe.Text;
  Inc(Calls);
  LastAsk := AAsk;
  Result := Default(TApprovalChoice);
  Result.Allowed := Allowed;
  Result.OptionKey := OptionKey;
  Result.Scope := Scope;
end;

procedure TChunkLog.OnChunk(const AId, AName, AText: string);
begin
  Text := Text + AText;
end;

procedure TCommandToolTest.SetUp;
begin
  FExecutor := TFakeExecutor.Create;
  FApprovalStore := TMemoryApprovalStore.Create;
  FChangeCount := 0;
end;

procedure TCommandToolTest.OnChanges(const AChanges: TFileChangeSet;
  const AToolCallId: string);
begin
  FChangeCount := FChangeCount + AChanges.Count;
end;

procedure TCommandToolTest.TearDown;
begin
  FExecutor.Free;
  FApprovalStore := nil;
end;

function TCommandToolTest.AddRule(AEffect: TApprovalEffect;
  const ARef: string; const AParams: array of string;
  AAny: Boolean): TApprovalRule;
var
  I: Integer;
  Err: string;
begin
  Result := DefaultApprovalRule(AEffect);
  Result.Scope := asGlobal;
  Result.Ref := ARef;
  SetLength(Result.Params, Length(AParams));
  for I := 0 to High(AParams) do
    Result.Params[I] := AParams[I];
  Result.AnyParams := AAny;
  FApprovalStore.Save(Result, Err);
end;

function TCommandToolTest.MakeConfig(AMaxBytes: Integer): TCommandToolConfig;
begin
  Result := Default(TCommandToolConfig);
  Result.Shell := DefaultShellProfile;
  Result.DefaultTimeoutMs := 1234;
  Result.MaxOutputBytes := AMaxBytes;
  Result.OnChanges := OnChanges;
end;

function TCommandToolTest.ServiceWith(
  APrompt: TApprovalPrompt): IApprovalService;
var
  Ctx: TApprovalContext;
begin
  Ctx.WorkspaceId := 1;
  Result := TApprovalService.Create(FApprovalStore, APrompt, Ctx);
end;

function TCommandToolTest.BuildTool(APrompt: TApprovalPrompt;
  AMaxBytes: Integer): TCommandTool;
begin
  Result := TCommandTool.Create(MakeConfig(AMaxBytes), ServiceWith(APrompt),
    FExecutor);
end;

procedure TCommandToolTest.TestRegisterAddsRunCommandSpec;
var
  Tools: TToolRegistry;
  Tool: TCommandTool;
  Registered: TRegisteredTool;
begin
  Tools := TToolRegistry.Create;
  Tool := BuildTool(nil, 0);
  try
    Tool.Register(Tools);
    AssertEquals('one tool', 1, Tools.Count);
    AssertTrue('registered', Tools.Find(CommandToolName, Registered));
  finally
    Tool.Free;
    Tools.Free;
  end;
end;

procedure TCommandToolTest.TestRegisteredSpecIsParallelSafe;
var
  Tools: TToolRegistry;
  Tool: TCommandTool;
  Specs: TToolSpecArray;
  I: Integer;
  Found: Boolean;
begin
  { SerialOnly is opt-in. Register used to leave the field uninitialized, so a
    shell call could be treated as serial and a batch of commands ran one at a
    time - which the panel showed as a permanently empty second block. }
  Tools := TToolRegistry.Create;
  try
    Tool := BuildTool(nil, 0);
    try
      Tool.Register(Tools);
    finally
      Tool.Free;
    end;
    Specs := Tools.Specs;
    Found := False;
    for I := 0 to High(Tools.Specs) do
      if Specs[I].Name = 'run_command' then
        Found := not Specs[I].SerialOnly;
    AssertTrue('run_command is parallel-safe', Found);
  finally
    Tools.Free;
  end;
end;

procedure TCommandToolTest.TestDescriptionNamesTheShellStartDirectory;
var
  Tools: TToolRegistry;
  Tool: TCommandTool;
  Registered: TRegisteredTool;
  Cfg: TCommandToolConfig;
begin
  { The model has guessed /workspace; the description must state where the shell
    starts, and the cwd parameter must name its default. }
  Tools := TToolRegistry.Create;
  Cfg := MakeConfig(0);
  Cfg.DefaultCwd := '/home/agent/project';
  Tool := TCommandTool.Create(Cfg, ServiceWith(nil), FExecutor);
  try
    Tool.Register(Tools);
    AssertTrue('registered', Tools.Find(CommandToolName, Registered));
    AssertTrue('names the default cwd',
      Pos('/home/agent/project', Registered.Spec.Description) > 0);
    AssertTrue('cwd param names the default',
      Pos('defaults to the workspace root',
        Registered.Spec.ParametersJson) > 0);
  finally
    Tool.Free;
    Tools.Free;
  end;
end;

procedure TCommandToolTest.TestDefaultShellProfileIsPosixBash;
var
  P: TShellProfile;
begin
  P := DefaultShellProfile;
  AssertEquals('executable', '/bin/bash', P.Executable);
  AssertEquals('switch', '-c', P.Switch);
  AssertEquals('syntax', Ord(ssPosix), Ord(P.Syntax));
end;

procedure TCommandToolTest.TestMissingCommandArgumentFails;
var
  Tool: TCommandTool;
  R, E: string;
begin
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('fails', Tool.Run('{"reason":"r"}', R, E));
    AssertEquals('not executed', 0, FExecutor.Calls);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestInvalidJsonFails;
var
  Tool: TCommandTool;
  R, E: string;
begin
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('fails', Tool.Run('{oops', R, E));
    AssertEquals('not executed', 0, FExecutor.Calls);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestMissingReasonNotExecuted;
var
  Tool: TCommandTool;
  R, E: string;
begin
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('fails', Tool.Run('{"command":"ls"}', R, E));
    AssertEquals('not executed', 0, FExecutor.Calls);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestAllowedByRuleExecutes;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  FExecutor.ResultExec.Output := 'hello' + LineEnding;
  Tool := BuildTool(nil, 0);
  try
    AssertTrue('ok', Tool.Run('{"command":"echo hi","reason":"r"}', R, E));
    AssertEquals('executed once', 1, FExecutor.Calls);
    AssertEquals('command', 'echo hi', FExecutor.LastCommand);
    AssertTrue('output', Pos('hello', R) > 0);
    AssertEquals('cwd default', '', FExecutor.LastCwd);
    AssertEquals('timeout default', 1234, FExecutor.LastTimeoutMs);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestResultReadsLikeAShellTranscript;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  FExecutor.ResultExec.Output := 'hello' + LineEnding;
  Tool := BuildTool(nil, 0);
  try
    AssertTrue('ok', Tool.Run('{"command":"echo hello","reason":"r"}', R, E));
    AssertTrue('command line then blank line then output',
      Pos('$ echo hello' + LineEnding + LineEnding + 'hello', R) > 0);
    AssertFalse('no exit note on success', Pos('[exit', R) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestDeniedByRuleDoesNotExecute;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeDeny, 'run_command:rm', [], True);
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('denied', Tool.Run('{"command":"rm x","reason":"r"}', R, E));
    AssertEquals('not executed', 0, FExecutor.Calls);
    AssertTrue('mentions deny', Pos('denied', E) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestAskWithNoPromptDenies;
var
  Tool: TCommandTool;
  R, E: string;
begin
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('denied', Tool.Run('{"command":"ls","reason":"r"}', R, E));
    AssertEquals('not executed', 0, FExecutor.Calls);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestPromptAllowOnceDoesNotPersist;
var
  Tool: TCommandTool;
  Prompt: TFakePrompt;
  R, E: string;
begin
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'once';
    Tool := BuildTool(Prompt.Prompt, 0);
    try
      AssertTrue('first', Tool.Run('{"command":"ls","reason":"r"}', R, E));
      AssertTrue('second', Tool.Run('{"command":"ls","reason":"r"}', R, E));
      AssertEquals('prompted twice', 2, Prompt.Calls);
      AssertEquals('executed twice', 2, FExecutor.Calls);
    finally
      Tool.Free;
    end;
  finally
    Prompt.Free;
  end;
end;

procedure TCommandToolTest.TestPromptExactPersistsAndAllowsSame;
var
  Tool: TCommandTool;
  Prompt: TFakePrompt;
  R, E: string;
begin
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'exact';
    Prompt.Scope := asGlobal;
    Tool := BuildTool(Prompt.Prompt, 0);
    try
      AssertTrue('first', Tool.Run(
        '{"command":"cat test","reason":"r"}', R, E));
      AssertTrue('second same', Tool.Run(
        '{"command":"cat test","reason":"r"}', R, E));
      AssertEquals('prompted once', 1, Prompt.Calls);
      Tool.Run('{"command":"cat other","reason":"r"}', R, E);
      AssertEquals('other arg asks again', 2, Prompt.Calls);
    finally
      Tool.Free;
    end;
  finally
    Prompt.Free;
  end;
end;

procedure TCommandToolTest.TestPromptAnyAllowsOtherArgs;
var
  Tool: TCommandTool;
  Prompt: TFakePrompt;
  R, E: string;
begin
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'any';
    Prompt.Scope := asGlobal;
    Tool := BuildTool(Prompt.Prompt, 0);
    try
      AssertTrue('first', Tool.Run('{"command":"cat a","reason":"r"}', R, E));
      AssertTrue('other', Tool.Run('{"command":"cat b","reason":"r"}', R, E));
      AssertEquals('prompted once', 1, Prompt.Calls);
    finally
      Tool.Free;
    end;
  finally
    Prompt.Free;
  end;
end;

procedure TCommandToolTest.TestPromptPrefixScopesSubtree;
var
  Tool: TCommandTool;
  Prompt: TFakePrompt;
  R, E: string;
begin
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'prefix';
    Prompt.Scope := asGlobal;
    Tool := BuildTool(Prompt.Prompt, 0);
    try
      AssertTrue('first', Tool.Run(
        '{"command":"php artisan migrate","reason":"r"}', R, E));
      AssertTrue('same subtree', Tool.Run(
        '{"command":"php artisan db","reason":"r"}', R, E));
      AssertEquals('prompted once', 1, Prompt.Calls);
      Tool.Run('{"command":"php foo","reason":"r"}', R, E);
      AssertEquals('prompted again', 2, Prompt.Calls);
    finally
      Tool.Free;
    end;
  finally
    Prompt.Free;
  end;
end;

procedure TCommandToolTest.TestAsksNameTheScriptAndItsSpan;
const
  Src = 'cat a.txt && uname -a';
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
begin
  Tool := BuildTool(nil, 0);
  try
    Asks := Tool.ApprovalAsks('{"command":"' + Src + '","reason":"r"}');
    AssertEquals('two asks', 2, Length(Asks));
    AssertEquals('script', Src, Asks[0].Script);
    AssertEquals('first focus', 'cat a.txt',
      Copy(Src, Asks[0].FocusStart, Asks[0].FocusLen));
    AssertEquals('second focus', 'uname -a',
      Copy(Src, Asks[1].FocusStart, Asks[1].FocusLen));
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestSubstitutionIsShownInTheAsk;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
begin
  { The whole point of capture-only: execution still refuses $(), but the
    operator must be able to SEE what the substitution would run. Without this
    the dialog shows `echo ...` and the operator approves blind. }
  Tool := BuildTool(nil, 0);
  try
    Asks := Tool.ApprovalAsks(
      '{"command":"echo $(cat secret.txt)","reason":"r"}');
    AssertTrue('an ask was produced', Length(Asks) > 0);
    AssertTrue('names the inner command: ' + Asks[0].Summary,
      Pos('cat secret.txt', Asks[0].Summary) > 0);
    AssertTrue('and says it runs first: ' + Asks[0].Summary,
      Pos('runs first', Asks[0].Summary) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestStructuralWordsAreNotCommands;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
begin
  { `if`/`then`/`fi` structure a script; they are not programs, so they must
    not become asks of their own. Only the condition and the command do. }
  Tool := BuildTool(nil, 0);
  try
    Asks := Tool.ApprovalAsks(
      '{"command":"if [ -f a ]; then cat a; fi","reason":"r"}');
    AssertEquals('the condition and the command', 2, Length(Asks));
    AssertEquals('condition ref', 'run_command:[', Asks[0].Subject.Ref);
    AssertEquals('condition text', '[ -f a ]', Asks[0].Summary);
    AssertEquals('command ref', 'run_command:cat', Asks[1].Subject.Ref);
    AssertEquals('command text', 'cat a', Asks[1].Summary);
    { `for x in a b` is a header, and the body is pure, so nothing asks. }
    Asks := Tool.ApprovalAsks(
      '{"command":"for x in a b; do echo $x; done","reason":"r"}');
    AssertEquals('no asks for a pure loop', 0, Length(Asks));
    { A closer alone names nothing. }
    Asks := Tool.ApprovalAsks('{"command":"done","reason":"r"}');
    AssertEquals('done asks nothing', 0, Length(Asks));
    Asks := Tool.ApprovalAsks('{"command":"fi","reason":"r"}');
    AssertEquals('fi asks nothing', 0, Length(Asks));
    { A keyword that introduces a command in the same segment: ask the
      command, not the keyword. }
    Asks := Tool.ApprovalAsks('{"command":"while true; do git status; done",' +
      '"reason":"r"}');
    AssertEquals('the loop body', 1, Length(Asks));
    AssertEquals('body ref', 'run_command:git', Asks[0].Subject.Ref);
    Asks := Tool.ApprovalAsks('{"command":"{ cat a; }","reason":"r"}');
    AssertEquals('the group body', 1, Length(Asks));
    AssertEquals('group ref', 'run_command:cat', Asks[0].Subject.Ref);
    Asks := Tool.ApprovalAsks('{"command":"! git status","reason":"r"}');
    AssertEquals('the negated command', 1, Length(Asks));
    AssertEquals('negated ref', 'run_command:git', Asks[0].Subject.Ref);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestApprovalAsksPerSegment;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
begin
  Tool := BuildTool(nil, 0);
  try
    Asks := Tool.ApprovalAsks(
      '{"command":"cat /etc/os-release && uname -a","reason":"r"}');
    AssertEquals('two asks', 2, Length(Asks));
    AssertEquals('first ref', 'run_command:cat', Asks[0].Subject.Ref);
    AssertEquals('first summary', 'cat /etc/os-release', Asks[0].Summary);
    AssertEquals('second ref', 'run_command:uname', Asks[1].Subject.Ref);
    AssertEquals('second summary', 'uname -a', Asks[1].Summary);
    AssertTrue('has once option', Asks[0].Options[0].Key = 'once');
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestProcessExecutorRecordsRealWrites;
var
  Exec: TProcessCommandExecutor;
  Profile: TShellProfile;
  Changes: TFileChangeSet;
  Execution: TCommandExecution;
  Root: string;
  I: Integer;
  SawA, SawB: Boolean;
begin
  Root := IncludeTrailingPathDelimiter(GetTempDir) + 'hhproc_' +
    IntToStr(GetTickCount64);
  ForceDirectories(Root);
  ForceDirectories(IncludeTrailingPathDelimiter(Root) + 'sub');
  Changes := TFileChangeSet.Create;
  try
    Profile := DefaultShellProfile;
    Exec := TProcessCommandExecutor.Create;
    try
      AssertTrue('ran', Exec.Execute(Profile,
        'printf "one\n" > a.txt; printf "two\n" > sub/b.txt',
        Root, 20000, nil, '', cmBash, Changes, Execution));
    finally
      Exec.Free;
    end;
    AssertEquals('exit', 0, Execution.ExitCode);
    SawA := False;
    SawB := False;
    for I := 0 to Changes.Count - 1 do
    begin
      if (Changes[I].Path = 'a.txt') and (Changes[I].Kind = fcCreated) then
        SawA := Changes[I].After = 'one' + #10;
      if Changes[I].Path = 'sub/b.txt' then
        SawB := True;
    end;
    AssertTrue('a.txt was recorded with its content', SawA);
    AssertTrue('sub/b.txt was recorded', SawB);
  finally
    Changes.Free;
    DeleteFile(IncludeTrailingPathDelimiter(Root) + 'sub/b.txt');
    RemoveDir(IncludeTrailingPathDelimiter(Root) + 'sub');
    DeleteFile(IncludeTrailingPathDelimiter(Root) + 'a.txt');
    RemoveDir(Root);
  end;
end;

function TCommandToolTest.BuildToolWithRoot(ARoot: string): TCommandTool;
var
  Cfg: TCommandToolConfig;
begin
  Cfg := MakeConfig(0);
  Cfg.DefaultCwd := ARoot;
  Result := TCommandTool.Create(Cfg, ServiceWith(nil), FExecutor);
end;

procedure TCommandToolTest.TestWildcardAllowedCatStillAsksAboutThePath;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I: Integer;
  PathAsk: Integer;
begin
  { `cat` is allowed with any arguments, but a path OUTSIDE the workspace is a
    separate ask: any-arguments is not any-location. }
  Tool := BuildToolWithRoot('/tmp/nowhere');
  try
    Asks := Tool.ApprovalAsks(
      '{"command":"cat /etc/hosts","reason":"r"}');
    PathAsk := -1;
    for I := 0 to High(Asks) do
      if Pos('path:', Asks[I].Subject.Ref) = 1 then
        PathAsk := I;
    AssertTrue('a path ask is present', PathAsk >= 0);
    AssertEquals('the absolute path', '/etc/hosts',
      Asks[PathAsk].Subject.Path);
    AssertTrue('carries a covers subject', Asks[PathAsk].HasCovers);
    AssertEquals('covers the command', 'run_command:cat',
      Asks[PathAsk].Covers.Ref);
    AssertTrue('offers an exact option', Asks[PathAsk].Options[1].Key = 'exact');
    AssertTrue('offers a dir option', Asks[PathAsk].Options[2].Key = 'dir');
    AssertEquals('the dir option carries a Directory rule',
      ExtractFileDir('/etc/hosts'), Asks[PathAsk].Options[2].Rule.Directory);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestExactlyApprovedCatDoesNotAskAboutThePath;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I: Integer;
  Choice: TApprovalChoice;
  Prompt: TFakePrompt;
  Store: IApprovalStore;
  Svc: IApprovalService;
  Batch: TApprovalBatchResult;
  Ctx: TApprovalContext;
begin
  { With `cat /etc/hosts` granted EXACTLY, the path ask is suppressed: the
    operator already said yes to this precise command. }
  Prompt := TFakePrompt.Create;
  Store := FApprovalStore;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'exact';
    Prompt.Scope := asWorkspace;
    Ctx.WorkspaceId := 1;
    Svc := TApprovalService.Create(Store, Prompt.Prompt, Ctx);
    { Grant the exact command first. }
    Tool := TCommandTool.Create(MakeConfig(0), Svc, FExecutor);
    try
      Asks := Tool.ApprovalAsks(
        '{"command":"cat /etc/hosts","reason":"r"}');
      AssertTrue('resolved', Svc.Resolve(Asks, Batch));
      AssertTrue('allowed', Batch.Allowed);
    finally
      Tool.Free;
    end;
    { Now the exact rule exists; re-resolving should not prompt again (the
      suppression covers the path ask). }
    Prompt.Calls := 0;
    Tool := BuildToolWithRoot('/tmp/nowhere');
    try
      Asks := Tool.ApprovalAsks(
        '{"command":"cat /etc/hosts","reason":"r"}');
      Svc := TApprovalService.Create(Store, Prompt.Prompt, Ctx);
      AssertTrue('resolved again', Svc.Resolve(Asks, Batch));
      AssertEquals('no new prompt (suppressed)', 0, Prompt.Calls);
    finally
      Tool.Free;
    end;
  finally
    Prompt.Free;
  end;
end;

procedure TCommandToolTest.TestUnknownCommandAsksForBoth;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I: Integer;
  SawCmd, SawPath: Boolean;
begin
  { An unknown command naming an outside path asks about BOTH the command and
    the path. }
  Tool := BuildToolWithRoot('/tmp/nowhere');
  try
    Asks := Tool.ApprovalAsks(
      '{"command":"frobnicate /etc/hosts","reason":"r"}');
    SawCmd := False;
    SawPath := False;
    for I := 0 to High(Asks) do
    begin
      if Asks[I].Subject.Ref = 'run_command:frobnicate' then
        SawCmd := True;
      if Pos('path:', Asks[I].Subject.Ref) = 1 then
        SawPath := True;
    end;
    AssertTrue('asks about the command', SawCmd);
    AssertTrue('asks about the path', SawPath);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestApprovalAsksCarryTheReason;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
begin
  Tool := BuildTool(nil, 0);
  try
    Asks := Tool.ApprovalAsks(
      '{"command":"rm -rf build","reason":"free the build dir"}');
    AssertEquals('one ask', 1, Length(Asks));
    AssertEquals('reason carried into the ask', 'free the build dir',
      Asks[0].Reason);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestRunCarriesTheReasonIntoTheAsk;
var
  Tool: TCommandTool;
  Prompt: TFakePrompt;
  R, E: string;
begin
  { Run builds its own asks, so the reason must be set there too (the bug the
    dialog exposed: the value never reached the modal). }
  Prompt := TFakePrompt.Create;
  try
    Prompt.Allowed := True;
    Prompt.OptionKey := 'once';
    Tool := BuildTool(Prompt.Prompt, 0);
    try
      AssertTrue('ran', Tool.Run(
        '{"command":"rm -rf build","reason":"free the build dir"}', R, E));
      AssertEquals('reason reached the ask', 'free the build dir',
        Prompt.LastAsk.Reason);
    finally
      Tool.Free;
    end;
  finally
    Prompt.Free;
  end;
end;

procedure TCommandToolTest.TestOutputIsTruncatedWithMarker;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  FExecutor.ResultExec.Output := 'abcdefgh';
  Tool := BuildTool(nil, 4);
  try
    AssertTrue('ok', Tool.Run('{"command":"echo hi","reason":"r"}', R, E));
    AssertTrue('kept prefix', Pos('abcd', R) > 0);
    AssertTrue('marker', Pos('truncated', R) > 0);
    AssertTrue('no full output', Pos('efgh', R) = 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestOutputTruncationKeepsUtf8Whole;
var
  Tool: TCommandTool;
  R, E, EAcute: string;
begin
  { The cap is in bytes; a cut mid-character would show a replacement glyph. }
  AddRule(aeAllow, 'run_command:echo', [], True);
  EAcute := #$C3#$A9;
  FExecutor.ResultExec.Output := EAcute + EAcute;
  Tool := BuildTool(nil, 3);
  try
    AssertTrue('ok', Tool.Run('{"command":"echo hi","reason":"r"}', R, E));
    AssertTrue('one whole character', Pos(EAcute, R) > 0);
    AssertFalse('never half a character',
      Pos(EAcute + EAcute, R) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestTimeoutReports124;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeAllow, 'run_command:sleep', [], True);
  FExecutor.ResultExec.Output := '';
  FExecutor.ResultExec.ExitCode := 124;
  FExecutor.ResultExec.TimedOut := True;
  Tool := BuildTool(nil, 0);
  try
    AssertTrue('ok', Tool.Run('{"command":"sleep 9","reason":"r"}', R, E));
    AssertTrue('reports 124', Pos('[exit 124]', R) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestHandlerNeverRaises;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  FExecutor.RaiseOnExecute := True;
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('caught', Tool.Run('{"command":"echo hi","reason":"r"}', R, E));
    AssertTrue('error text', Pos('run_command error', E) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestCommandPreservesUtf8;
var
  Tool: TCommandTool;
  R, E, Cmd: string;
begin
  { Regression: without the cwstring unit the RTL's ASCII widestring manager
    replaced non-ASCII with '?' (a BMP emoji with one, an astral emoji with two),
    so the model's command reached the shell mangled. }
  AddRule(aeAllow, 'run_command:echo', [], True);
  Tool := BuildTool(nil, 0);
  try
    Cmd := 'echo X' + #$E2#$9C#$A8 + 'Y' + #$F0#$9F#$90#$9B + 'Z';
    AssertTrue('ok', Tool.Run('{"command":"' + Cmd + '","reason":"r"}', R, E));
    AssertEquals('utf8 preserved', Cmd, FExecutor.LastCommand);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestProcessExecutorRunsCommand;
var
  Exec: ICommandExecutor;
  ExecResult: TCommandExecution;
begin
  Exec := TProcessCommandExecutor.Create;
  AssertTrue('ok', Exec.Execute(DefaultShellProfile, 'printf hello', '', 5000,
    nil, 'test reason', cmAuto, nil, ExecResult));
  AssertEquals('exit code', 0, ExecResult.ExitCode);
  AssertTrue('output captured', Pos('hello', ExecResult.Output) > 0);
  AssertFalse('not timed out', ExecResult.TimedOut);
end;

procedure TCommandToolTest.TestRunCommandStreamsOutput;
var
  Tool: TCommandTool;
  R, E: string;
  Log: TChunkLog;
  Observer: TToolForwardObserver;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  FExecutor.ResultExec.Output := 'one two ';
  SetLength(FExecutor.Chunks, 2);
  FExecutor.Chunks[0] := 'one ';
  FExecutor.Chunks[1] := 'two ';
  Log := TChunkLog.Create;
  try
    Observer := TToolForwardObserver.Create('call_1', 'run_command',
      Log.OnChunk);
    try
      Tool := BuildTool(nil, 0);
      try
        AssertTrue('ok', Tool.Run('{"command":"echo hi","reason":"r"}', R, E,
          Observer));
      finally
        Tool.Free;
      end;
    finally
      Observer.Free;
    end;
    { The command is streamed first, so the operator sees what is about to run
      (especially for a long-running command), then its output. }
    AssertEquals('streamed chunks',
      '$ echo hi' + LineEnding + LineEnding + 'one two ', Log.Text);
  finally
    Log.Free;
  end;
end;

procedure TCommandToolTest.TestCommandIsShownBeforeApproval;
var
  Tool: TCommandTool;
  R, E: string;
  Log: TChunkLog;
  Prompt: TFakePrompt;
  Observer: TToolForwardObserver;
begin
  { A tool block must never be an empty box while the ask is up: the command is
    forwarded first, then the operator is prompted. }
  Log := TChunkLog.Create;
  Prompt := TFakePrompt.Create;
  Prompt.Allowed := True;
  Prompt.OptionKey := 'once';
  Prompt.Probe := Log;
  try
    Observer := TToolForwardObserver.Create('call_1', 'run_command',
      Log.OnChunk);
    try
      Tool := BuildTool(Prompt.Prompt, 0);
      try
        AssertTrue('ok', Tool.Run(
          '{"command":"cat a.txt","reason":"because"}', R, E, Observer));
      finally
        Tool.Free;
      end;
    finally
      Observer.Free;
    end;
    AssertEquals('prompted once', 1, Prompt.Calls);
    AssertTrue('the command reached the panel before the ask',
      Pos('$ cat a.txt', Prompt.SeenAtPrompt) > 0);
  finally
    Prompt.Free;
    Log.Free;
  end;
end;

procedure TCommandToolTest.TestCommandTimeoutIsClampedToMax;
var
  Tool: TCommandTool;
  R, E: string;
  Config: TCommandToolConfig;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  Config := MakeConfig(0);
  Config.MaxTimeoutMs := 5000;
  Tool := TCommandTool.Create(Config, ServiceWith(nil), FExecutor);
  try
    AssertTrue('above cap', Tool.Run(
      '{"command":"echo hi","reason":"r","timeout_ms":999999}', R, E));
    AssertEquals('clamped to max', 5000, FExecutor.LastTimeoutMs);
    AssertTrue('below cap', Tool.Run(
      '{"command":"echo hi","reason":"r","timeout_ms":2000}', R, E));
    AssertEquals('requested kept', 2000, FExecutor.LastTimeoutMs);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestAwkRegexIsNotTreatedAsAPath;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I: Integer;
begin
  { Report from live use: an awk program containing '/' was treated as an
    external DIRECTORY. IsPathLike is a heuristic (any '/' in the arg); compute
    effects positionally instead, where awk's first operand is the PROGRAM. }
  Tool := BuildToolWithRoot('/tmp/nowhere');
  try
    Asks := Tool.ApprovalAsks(
      '{"command":"awk ''/foo/{print $1}'' a.txt","reason":"r"}');
    for I := 0 to High(Asks) do
      AssertFalse('no outside-path ask for a regex: ' + Asks[I].Summary,
        Copy(Asks[I].Subject.Ref, 1, 5) = 'path:');
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestACommandAskOffersAllFiveFileScopes;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I: Integer;
  HasExt, HasDir, HasDirExt, HasAnyFile: Boolean;
begin
  { The operator asked for five read scopes: exact file, same extension, same
    directory, directory+extension, and ALL files in the workspace. Four existed;
    the fifth did not, because 'dir' means THIS directory and is only the whole
    workspace when the file sits at the root. }
  Tool := BuildToolWithRoot('/tmp/nowhere');
  try
    Asks := Tool.ApprovalAsks('{"command":"cat sub/a.txt","reason":"r"}');
    AssertTrue('an ask exists', Length(Asks) > 0);
    HasExt := False;
    HasDir := False;
    HasDirExt := False;
    HasAnyFile := False;
    for I := 0 to High(Asks[0].Options) do
    begin
      if Asks[0].Options[I].Key = 'ext' then HasExt := True;
      if Asks[0].Options[I].Key = 'dir' then HasDir := True;
      if Asks[0].Options[I].Key = 'dir_ext' then HasDirExt := True;
      if Asks[0].Options[I].Key = 'any_file' then HasAnyFile := True;
    end;
    AssertTrue('same extension', HasExt);
    AssertTrue('same directory', HasDir);
    AssertTrue('directory + extension', HasDirExt);
    AssertTrue('all files in the workspace', HasAnyFile);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestACommandNamingFilesOffersFileScopes;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I: Integer;
  HasDir, HasExt: Boolean;
begin
  { Report from live use: the command ask offered "exact command" and "awk with
    any arguments" but no FILE scopes, even though a real file was named. The
    file-scope options existed only for redirects. }
  Tool := BuildToolWithRoot('/tmp/nowhere');
  try
    Asks := Tool.ApprovalAsks('{"command":"awk ''{print}'' a.txt","reason":"r"}');
    AssertTrue('an ask exists', Length(Asks) > 0);
    HasDir := False;
    HasExt := False;
    for I := 0 to High(Asks[0].Options) do
    begin
      if Asks[0].Options[I].Key = 'dir' then HasDir := True;
      if Asks[0].Options[I].Key = 'ext' then HasExt := True;
    end;
    AssertTrue('a directory scope is offered', HasDir);
    AssertTrue('and an extension scope', HasExt);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestTheReadAskExcludesTheRedirect;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I: Integer;
begin
  { `echo "Test" > test.log` is a read of nothing and a WRITE of test.log. The
    read ask's highlight must not swallow the redirect - otherwise two asks
    describe overlapping spans. }
  Tool := BuildToolWithRoot('/tmp/nowhere');
  try
    Asks := Tool.ApprovalAsks(
      '{"command":"cat a.txt > out.log","reason":"r"}');
    for I := 0 to High(Asks) do
      if Asks[I].Subject.Ref = 'run_command:cat' then
      begin
        AssertFalse('the command focus excludes the redirect: ' +
          Copy(Asks[I].Script, Asks[I].FocusStart, Asks[I].FocusLen),
          Pos('>', Copy(Asks[I].Script, Asks[I].FocusStart,
            Asks[I].FocusLen)) > 0);
        Exit;
      end;
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestBucketOptionIsOfferedForTheMatchingClass;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I: Integer;
  Found: Boolean;
begin
  Tool := BuildToolWithRoot('/tmp/nowhere');
  try
    { grep reads, so the READ bucket is offered and the WRITE bucket is not.
      Offering both would be clutter and would invite granting more than asked. }
    Asks := Tool.ApprovalAsks('{"command":"grep x a.txt","reason":"r"}');
    AssertTrue('an ask exists', Length(Asks) > 0);
    Found := False;
    for I := 0 to High(Asks[0].Options) do
    begin
      AssertFalse('no write bucket on a read command',
        Asks[0].Options[I].Key = 'bucket_write');
      if Asks[0].Options[I].Key = 'bucket_read' then
      begin
        Found := True;
        { A bucket rule must carry NO Ref - that is what makes it coarse. }
        AssertEquals('bucket rule has no ref', '',
          Asks[0].Options[I].Rule.Ref);
        AssertEquals('and carries the bucket', Ord(abRead),
          Ord(Asks[0].Options[I].Rule.Bucket));
        AssertTrue('and persists', Asks[0].Options[I].Persists);
      end;
    end;
    AssertTrue('the read bucket is offered', Found);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestRedirectSummaryAndFileAsk;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I, FileAsk: Integer;
begin
  Tool := BuildToolWithRoot('/tmp/nowhere');
  try
    { echo is pure: its command ask is gone, but the redirect is still asked. }
    Asks := Tool.ApprovalAsks('{"command":"echo x > out.txt","reason":"r"}');
    AssertEquals('only the file ask', 1, Length(Asks));
    FileAsk := 0;
    AssertEquals('file:write', 'file:write', Asks[FileAsk].Subject.Ref);
    AssertEquals('workspace-relative path', 'out.txt',
      Asks[FileAsk].Subject.Path);
    AssertEquals('once', 'once', Asks[FileAsk].Options[0].Key);
    AssertEquals('exact files', 'exact', Asks[FileAsk].Options[1].Key);
    AssertEquals('exact names the path', 'out.txt',
      Asks[FileAsk].Options[1].Rule.Params[0]);
    { Reads and writes now offer the SAME scope vocabulary (operator request):
      exact / extended-by-extension / directory / dir+ext. A single path gives
      both dir and ext, since both generalise from it. }
    AssertTrue('a directory scope', Length(Asks[FileAsk].Options) >= 3);
    { A non-pure command keeps its own ask, and the summary names the redirect. }
    Asks := Tool.ApprovalAsks(
      '{"command":"grep x out.txt > log.txt","reason":"r"}');
    AssertTrue('summary keeps the redirect',
      Pos('> log.txt', Asks[0].Summary) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestRedirectReadAsk;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I, FileAsk: Integer;
  HasDir, HasExt: Boolean;
begin
  Tool := BuildToolWithRoot('/tmp/nowhere');
  try
    Asks := Tool.ApprovalAsks('{"command":"cat < in.txt","reason":"r"}');
    FileAsk := -1;
    for I := 0 to High(Asks) do
      if Asks[I].Subject.Ref = 'file:read' then
        FileAsk := I;
    AssertTrue('a file:read ask', FileAsk >= 0);
    AssertEquals('path', 'in.txt', Asks[FileAsk].Subject.Path);
    { Reads and writes share the SAME scope vocabulary now (operator request) -
      previously reads did not offer extension scoping. Both should present the
      same set so the dialog does not differ by direction. }
    HasDir := False;
    HasExt := False;
    for I := 0 to High(Asks[FileAsk].Options) do
    begin
      if Asks[FileAsk].Options[I].Key = 'dir' then HasDir := True;
      if Asks[FileAsk].Options[I].Key = 'ext' then HasExt := True;
    end;
    AssertTrue('a read offers a directory scope', HasDir);
    AssertTrue('and an extension scope, as a write does', HasExt);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestFdDuplicateIsNotAFileAsk;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I: Integer;
begin
  Tool := BuildToolWithRoot('/tmp/nowhere');
  try
    Asks := Tool.ApprovalAsks('{"command":"echo x 2>&1","reason":"r"}');
    for I := 0 to High(Asks) do
      AssertFalse('no file ask for an fd duplication',
        Copy(Asks[I].Subject.Ref, 1, 5) = 'file:');
    { And a fd duplication on a PURE command is not an effect at all: it names an
      fd, not a path, so the whole command needs no approval. }
    AssertEquals('2>&1 on a pure command asks for nothing', 0, Length(Asks));
    { The same for a write target that IS a path, which must still ask: this pins
      that 2>&1 is excluded rather than redirects being ignored wholesale. }
    Asks := Tool.ApprovalAsks('{"command":"echo x 2>&1 > out.txt","reason":"r"}');
    AssertEquals('the real redirect still asks', 1, Length(Asks));
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestOutsideRedirectKeepsThePathAsk;
var
  Tool: TCommandTool;
  Asks: TApprovalAskArray;
  I: Integer;
  SawFileWrite, SawPath: Boolean;
begin
  Tool := BuildToolWithRoot('/tmp/nowhere');
  try
    Asks := Tool.ApprovalAsks('{"command":"echo x > /tmp/outside.txt","reason":"r"}');
    SawFileWrite := False;
    SawPath := False;
    for I := 0 to High(Asks) do
    begin
      if Asks[I].Subject.Ref = 'file:write' then
        SawFileWrite := True;
      if Asks[I].Subject.Ref = 'path:' then
        SawPath := True;
    end;
    AssertFalse('no file:write for an outside target', SawFileWrite);
    AssertTrue('the outside path ask remains', SawPath);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestHtmlEntitiesAreDecoded;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  AddRule(aeAllow, 'run_command:grep', [], True);
  Tool := BuildTool(nil, 0);
  try
    AssertTrue('lt', Tool.Run(
      '{"command":"echo a &lt; b","reason":"r"}', R, E));
    AssertEquals('lt decoded', 'echo a < b', FExecutor.LastCommand);
    AssertTrue('amp', Tool.Run(
      '{"command":"echo a &amp;&amp; echo b","reason":"r"}', R, E));
    AssertEquals('amp decoded', 'echo a && echo b', FExecutor.LastCommand);
    AssertTrue('numeric', Tool.Run(
      '{"command":"echo &#65;","reason":"r"}', R, E));
    AssertEquals('numeric decoded', 'echo A', FExecutor.LastCommand);
    AssertTrue('quoted', Tool.Run(
      '{"command":"echo &quot;hi&quot;","reason":"r"}', R, E));
    AssertEquals('quotes decoded', 'echo "hi"', FExecutor.LastCommand);
    AssertTrue('escaped entity', Tool.Run(
      '{"command":"grep ''\\&lt;'' f","reason":"r"}', R, E));
    AssertEquals('escaped entity kept', 'grep ''\&lt;'' f',
      FExecutor.LastCommand);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestSilentCommandSaysNoContent;
var
  Tool: TCommandTool;
  R, E: string;
begin
  { A command that prints nothing used to yield a bare `$ cmd` header and then
    whatever rode the tail - so an agent could not tell "it ran and printed
    nothing" from "it produced no result at all". Silent success is common
    (`mkdir`, `mv`, a `sed -i` that matched nothing) and must say so. }
  AddRule(aeAllow, 'run_command:true', [], True);
  Tool := BuildTool(nil, 0);
  try
    { The fake executor defaults its output to 'out'; this case is about the
      SILENT command, so empty it explicitly. }
    FExecutor.ResultExec.Output := '';
    AssertTrue('ok', Tool.Run('{"command":"true","reason":"r"}', R, E));
    AssertTrue('says there was no output: ' + R, Pos('(no content)', R) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestRunDeliversFileChanges;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  Tool := BuildTool(nil, 0);
  try
    AssertTrue('ok', Tool.Run('{"command":"echo hi","reason":"r"}', R, E));
    AssertEquals('one change delivered', 1, FChangeCount);
    { The set rides OnChanges only. What a call wrote is ambient context, not
      the command's output: a diff view reads it from the change log, and the
      tool block shows what the command printed. }
    AssertFalse('the result does not carry the change note',
      Pos('[changed:', R) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestNoChangeNoteWithoutChanges;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  FExecutor.ChangeCount := 0;
  Tool := BuildTool(nil, 0);
  try
    AssertTrue('ok', Tool.Run('{"command":"echo hi","reason":"r"}', R, E));
    AssertFalse('no note', Pos('[changed:', R) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestAnErrorNamesTheFailingCommand;
var
  Tool: TCommandTool;
  R, E: string;
begin
  { A failure reads like a success: `$ command`, a blank line, then the reason.
    `mode=builtin` with an unsupported command is the exact case that produced a
    bare "the builtin shell cannot run this command" with no command in sight. }
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('fails',
      Tool.Run('{"command":"git status","reason":"r","mode":"builtin"}', R, E));
    AssertEquals('the transcript shape', '$ git status' + LineEnding +
      LineEnding, Copy(E, 1, Length('$ git status' + LineEnding + LineEnding)));
    AssertTrue('and says why: ' + E, Pos('builtin shell', E) > 0);
    { The result carries the same text, so the tool block shows it: the loop no
      longer overwrites a tool that reported its own failure. }
    AssertEquals('the result is the same text', E, R);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestAParseErrorNamesTheCommand;
var
  Tool: TCommandTool;
  R, E: string;
begin
  { A command that never parsed is exactly when the operator cannot guess. }
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('fails',
      Tool.Run('{"command":"cat <<EOF","reason":"r"}', R, E));
    AssertTrue('the error names the command: ' + E, Pos('cat <<EOF', E) > 0);
    AssertTrue('and says why: ' + E, Pos('here-document', E) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestModeBashIsPassedThrough;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  FExecutor.ResultExec.Output := 'hi';
  Tool := BuildTool(nil, 0);
  try
    AssertTrue('ok', Tool.Run(
      '{"command":"echo hi","reason":"r","mode":"bash"}', R, E));
    AssertEquals('executor saw bash', Ord(cmBash), Ord(FExecutor.LastMode));
    AssertEquals('executed once', 1, FExecutor.Calls);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestModeDefaultsToAuto;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  Tool := BuildTool(nil, 0);
  try
    AssertTrue('ok', Tool.Run('{"command":"echo hi","reason":"r"}', R, E));
    AssertEquals('auto by default', Ord(cmAuto), Ord(FExecutor.LastMode));
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestInvalidModeIsRejected;
var
  Tool: TCommandTool;
  R, E: string;
begin
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('rejected', Tool.Run(
      '{"command":"echo hi","reason":"r","mode":"weird"}', R, E));
    AssertTrue('names the values', Pos('invalid "mode"', E) > 0);
    AssertEquals('never executed', 0, FExecutor.Calls);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestModeBuiltinRefusesUnsupportedWithoutAsking;
var
  Tool: TCommandTool;
  Prompt: TFakePrompt;
  R, E: string;
begin
  Prompt := TFakePrompt.Create;
  Prompt.Allowed := True;
  try
    Tool := BuildTool(Prompt.Prompt, 0);
    try
      { The fake executor never owns approval, so builtin must refuse. }
      AssertFalse('refused', Tool.Run(
        '{"command":"git status","reason":"r","mode":"builtin"}', R, E));
      AssertTrue('names the executor', Pos('the builtin shell cannot run', E) > 0);
      AssertEquals('never executed', 0, FExecutor.Calls);
      AssertEquals('never asked', 0, Prompt.Calls);
    finally
      Tool.Free;
    end;
  finally
    Prompt.Free;
  end;
end;

procedure TCommandToolTest.TestTimeoutIsHonouredWithoutACap;
var
  Tool: TCommandTool;
  R, E: string;
begin
  AddRule(aeAllow, 'run_command:echo', [], True);
  { With no MaxTimeoutMs the model defines its own timeout, so a long request
    passes through untouched. }
  Tool := BuildTool(nil, 0);
  try
    AssertTrue('long request', Tool.Run(
      '{"command":"echo hi","reason":"r","timeout_ms":1800000}', R, E));
    AssertEquals('honoured as-is', Int64(1800000),
      Int64(FExecutor.LastTimeoutMs));
  finally
    Tool.Free;
  end;
end;

initialization
  RegisterTest(TCommandToolTest);
end.
