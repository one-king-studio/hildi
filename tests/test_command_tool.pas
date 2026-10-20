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
    constructor Create;
    function OwnsApproval(const ACommand: string; AMode: TCommandMode;
      out AWhy: string): Boolean;
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord; AObserver: TToolObserver;
      const AReason: string; AMode: TCommandMode; AChanges: TFileChangeSet;
      out AExecution: TCommandExecution): Boolean;
  end;

  TFakePrompt = class
  public
    Allowed: Boolean;
    OptionKey: string;
    Scope: TApprovalScope;
    Calls: Integer;
    LastAsk: TApprovalAsk;
    function Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
  end;

  { Collects streamed chunks into one string. }
  TChunkLog = class
  public
    Text: string;
    procedure OnChunk(const AId, AName, AText: string);
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
    procedure OnChanges(const AChanges: TFileChangeSet);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRegisterAddsRunCommandSpec;
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
    procedure TestApprovalAsksPerSegment;
    procedure TestWildcardAllowedCatStillAsksAboutThePath;
    procedure TestExactlyApprovedCatDoesNotAskAboutThePath;
    procedure TestUnknownCommandAsksForBoth;
    procedure TestApprovalAsksCarryTheReason;
    procedure TestRunCarriesTheReasonIntoTheAsk;
    procedure TestOutputIsTruncatedWithMarker;
    procedure TestTimeoutReports124;
    procedure TestHandlerNeverRaises;
    procedure TestCommandPreservesUtf8;
    procedure TestProcessExecutorRunsCommand;
    procedure TestRunCommandStreamsOutput;
    procedure TestCommandTimeoutIsClampedToMax;
    procedure TestTimeoutIsHonouredWithoutACap;
    procedure TestHtmlEntitiesAreDecoded;
    procedure TestRunDeliversFileChanges;
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
  begin
    Change := Default(TFileChange);
    Change.Path := 'fake.txt';
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

procedure TCommandToolTest.OnChanges(const AChanges: TFileChangeSet);
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
