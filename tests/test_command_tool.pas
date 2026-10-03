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
  hildegard.helper.command.tool;

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
    constructor Create;
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord;
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

  TCommandToolTest = class(TTestCase)
  private
    FExecutor: TFakeExecutor;
    FApprovalStore: IApprovalStore;
    function MakeConfig(AMaxBytes: Integer): TCommandToolConfig;
    function BuildTool(APrompt: TApprovalPrompt;
      AMaxBytes: Integer): TCommandTool;
    function AddRule(AEffect: TApprovalEffect; const ARef: string;
      const AParams: array of string; AAny: Boolean): TApprovalRule;
    function ServiceWith(APrompt: TApprovalPrompt): IApprovalService;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRegisterAddsRunCommandSpec;
    procedure TestDefaultShellProfileIsPosixBash;
    procedure TestMissingCommandArgumentFails;
    procedure TestInvalidJsonFails;
    procedure TestMissingReasonNotExecuted;
    procedure TestAllowedByRuleExecutes;
    procedure TestDeniedByRuleDoesNotExecute;
    procedure TestAskWithNoPromptDenies;
    procedure TestPromptAllowOnceDoesNotPersist;
    procedure TestPromptExactPersistsAndAllowsSame;
    procedure TestPromptAnyAllowsOtherArgs;
    procedure TestPromptPrefixScopesSubtree;
    procedure TestApprovalAsksPerSegment;
    procedure TestApprovalAsksCarryTheReason;
    procedure TestOutputIsTruncatedWithMarker;
    procedure TestTimeoutReports124;
    procedure TestHandlerNeverRaises;
    procedure TestCommandPreservesUtf8;
    procedure TestProcessExecutorRunsCommand;
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

function TFakeExecutor.Execute(const AProfile: TShellProfile;
  const ACommand, AWorkDir: string; ATimeoutMs: QWord;
  out AExecution: TCommandExecution): Boolean;
begin
  if RaiseOnExecute then
    raise Exception.Create('executor boom');
  Inc(Calls);
  LastCommand := ACommand;
  LastCwd := AWorkDir;
  LastTimeoutMs := ATimeoutMs;
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

procedure TCommandToolTest.SetUp;
begin
  FExecutor := TFakeExecutor.Create;
  FApprovalStore := TMemoryApprovalStore.Create;
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
    AssertTrue('reports 124', Pos('exit_code: 124', R) > 0);
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
    ExecResult));
  AssertEquals('exit code', 0, ExecResult.ExitCode);
  AssertTrue('output captured', Pos('hello', ExecResult.Output) > 0);
  AssertFalse('not timed out', ExecResult.TimedOut);
end;

initialization
  RegisterTest(TCommandToolTest);
end.
