unit test_command_tool;
{ fpcunit tests for hildegard.helper.command.tool. The tool is exercised with
  fake policy sources, executors, and approvers: no SQLite, no network, and no
  real process. One test round-trips the store-backed source against a temporary
  database. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.agent, hildegard.helper.llm,
  hildegard.helper.command.policy, hildegard.helper.command.tool,
  hildegard.helper.store, llm_fakes;

type
  { Records calls and returns a canned execution. }
  TFakeExecutor = class(TNoRefCountObject, ICommandExecutor)
  public
    Calls: Integer;
    ReturnOk: Boolean;
    RaiseOnExecute: Boolean;
    LastProfile: TShellProfile;
    LastCommand: string;
    LastCwd: string;
    LastTimeoutMs: QWord;
    ResultExec: TCommandExecution;
    constructor Create;
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord;
      out AExecution: TCommandExecution): Boolean;
  end;

  { In-memory policy source with recording of approvals and audits. }
  TMemoryPolicySource = class(TNoRefCountObject, ICommandPolicySource)
  public
    Policy: TCommandPolicy;
    LoadFails: Boolean;
    RaiseOnLoad: Boolean;
    LoadCalls: Integer;
    Approvals: TStringList;
    Audits: array of TCommandAuditEntry;
    constructor Create;
    destructor Destroy; override;
    function LoadPolicy(out APolicy: TCommandPolicy;
      out AError: string): Boolean;
    function SaveApproval(const AExecutable: string;
      out AError: string): Boolean;
    procedure RecordAudit(const AEntry: TCommandAuditEntry);
    function AuditCount: Integer;
  end;

  { Returns a scripted approval outcome and captures the request. }
  TFakeApprover = class
  public
    Outcome: TApprovalOutcome;
    Calls: Integer;
    LastRequest: TApprovalRequest;
    function Approve(const ARequest: TApprovalRequest): TApprovalOutcome;
  end;

  TCommandToolTest = class(TTestCase)
  private
    FDir: string;
    FDbPath: string;
    FSource: TMemoryPolicySource;
    FExecutor: TFakeExecutor;
    function MakeConfig(AMaxBytes: Integer): TCommandToolConfig;
    function BuildTool(AApprover: TApprovalHandler;
      AMaxBytes: Integer): TCommandTool;
    function OpenStore: TSqliteStore;
    procedure DeleteDbFiles;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRegisterAddsRunCommandSpec;
    procedure TestDefaultShellProfileIsPosixBash;
    procedure TestMissingCommandArgumentFails;
    procedure TestInvalidJsonFails;
    procedure TestMissingReasonNotExecuted;
    procedure TestAllowExecutesAndReturnsOutput;
    procedure TestDenyDoesNotExecuteAndFails;
    procedure TestAskWithNoApproverDenies;
    procedure TestAskAllowOnceExecutesWithoutPersisting;
    procedure TestAskAllowAlwaysExecutesAndPersists;
    procedure TestAskDenyDoesNotExecute;
    procedure TestReasonPassedToApprover;
    procedure TestReasonRecordedInAudit;
    procedure TestTimeoutReports124;
    procedure TestOutputIsTruncatedWithMarker;
    procedure TestPolicyReloadedEachCall;
    procedure TestLoadPolicyErrorFailsClosed;
    procedure TestAuditRecordedForAllowDenyAndOutcome;
    procedure TestHandlerNeverRaises;
    procedure TestStoreCommandPolicySourceRoundTrip;
    procedure TestRoundTripAgainstFakeProvider;
    procedure TestProcessExecutorRunsCommand;
    procedure TestMemoryPolicySourceAsksThenRemembers;
  end;

implementation

function MakePolicy(const AAllow, ADeny, ARoots: array of string;
  AInterpreters: Boolean): TCommandPolicy;
var
  I: Integer;
begin
  Result := Default(TCommandPolicy);
  SetLength(Result.Allow, Length(AAllow));
  for I := 0 to High(AAllow) do
    Result.Allow[I] := AAllow[I];
  SetLength(Result.Deny, Length(ADeny));
  for I := 0 to High(ADeny) do
    Result.Deny[I] := ADeny[I];
  SetLength(Result.AllowedRoots, Length(ARoots));
  for I := 0 to High(ARoots) do
    Result.AllowedRoots[I] := ARoots[I];
  Result.AllowInterpreters := AInterpreters;
end;

{ TFakeExecutor }

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
  LastProfile := AProfile;
  LastCommand := ACommand;
  LastCwd := AWorkDir;
  LastTimeoutMs := ATimeoutMs;
  AExecution := ResultExec;
  Result := ReturnOk;
end;

{ TMemoryPolicySource }

constructor TMemoryPolicySource.Create;
begin
  inherited Create;
  Policy := Default(TCommandPolicy);
  Approvals := TStringList.Create;
end;

destructor TMemoryPolicySource.Destroy;
begin
  Approvals.Free;
  inherited Destroy;
end;

function TMemoryPolicySource.LoadPolicy(out APolicy: TCommandPolicy;
  out AError: string): Boolean;
begin
  Inc(LoadCalls);
  if RaiseOnLoad then
    raise Exception.Create('load boom');
  if LoadFails then
  begin
    APolicy := Default(TCommandPolicy);
    AError := 'policy unavailable';
    Exit(False);
  end;
  APolicy := Policy;
  AError := '';
  Result := True;
end;

function TMemoryPolicySource.SaveApproval(const AExecutable: string;
  out AError: string): Boolean;
begin
  Approvals.Add(AExecutable);
  AError := '';
  Result := True;
end;

procedure TMemoryPolicySource.RecordAudit(const AEntry: TCommandAuditEntry);
begin
  SetLength(Audits, Length(Audits) + 1);
  Audits[High(Audits)] := AEntry;
end;

function TMemoryPolicySource.AuditCount: Integer;
begin
  Result := Length(Audits);
end;

{ TFakeApprover }

function TFakeApprover.Approve(const ARequest: TApprovalRequest): TApprovalOutcome;
begin
  Inc(Calls);
  LastRequest := ARequest;
  Result := Outcome;
end;

{ TCommandToolTest }

procedure TCommandToolTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhcmd_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  CreateDir(FDir);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
  FSource := TMemoryPolicySource.Create;
  FExecutor := TFakeExecutor.Create;
end;

procedure TCommandToolTest.DeleteDbFiles;
begin
  DeleteFile(FDbPath);
  DeleteFile(FDbPath + '-wal');
  DeleteFile(FDbPath + '-shm');
end;

procedure TCommandToolTest.TearDown;
begin
  FSource.Free;
  FExecutor.Free;
  DeleteDbFiles;
  RemoveDir(FDir);
end;

function TCommandToolTest.MakeConfig(AMaxBytes: Integer): TCommandToolConfig;
begin
  Result := Default(TCommandToolConfig);
  Result.Shell := DefaultShellProfile;
  Result.DefaultTimeoutMs := 1234;
  Result.MaxOutputBytes := AMaxBytes;
end;

function TCommandToolTest.BuildTool(AApprover: TApprovalHandler;
  AMaxBytes: Integer): TCommandTool;
begin
  Result := TCommandTool.Create(MakeConfig(AMaxBytes), FSource, AApprover,
    FExecutor);
end;

function TCommandToolTest.OpenStore: TSqliteStore;
var
  Cfg: TStoreConfig;
  Err: TStoreError;
begin
  Cfg.DatabasePath := FDbPath;
  Cfg.LibraryPath := '';
  Cfg.BusyTimeoutMs := 5000;
  Result := TSqliteStore.Create(Cfg);
  if not Result.Open(Err) then
  begin
    Result.Free;
    raise Exception.Create('store failed to open: ' + Err.Message);
  end;
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
    AssertTrue('names command', Pos('command', E) > 0);
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
    AssertTrue('names reason', Pos('reason', E) > 0);
    AssertEquals('not executed', 0, FExecutor.Calls);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestAllowExecutesAndReturnsOutput;
var
  Tool: TCommandTool;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['echo'], [], [], False);
  FExecutor.ResultExec.Output := 'hello' + LineEnding;
  Tool := BuildTool(nil, 0);
  try
    AssertTrue('ok', Tool.Run('{"command":"echo hi","reason":"r"}', R, E));
    AssertEquals('executed once', 1, FExecutor.Calls);
    AssertEquals('command passed', 'echo hi', FExecutor.LastCommand);
    AssertTrue('exit line', Pos('exit_code: 0', R) > 0);
    AssertTrue('output', Pos('hello', R) > 0);
    AssertEquals('default timeout used', 1234, FExecutor.LastTimeoutMs);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestDenyDoesNotExecuteAndFails;
var
  Tool: TCommandTool;
  R, E: string;
begin
  FSource.Policy := MakePolicy([], ['rm'], [], False);
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('denied', Tool.Run('{"command":"rm file","reason":"r"}', R, E));
    AssertEquals('not executed', 0, FExecutor.Calls);
    AssertTrue('mentions policy', Pos('denied by policy', E) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestAskWithNoApproverDenies;
var
  Tool: TCommandTool;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['other'], [], [], False);
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('denied', Tool.Run('{"command":"ls","reason":"r"}', R, E));
    AssertEquals('not executed', 0, FExecutor.Calls);
    AssertTrue('mentions operator', Pos('denied by operator', E) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestAskAllowOnceExecutesWithoutPersisting;
var
  Tool: TCommandTool;
  Approver: TFakeApprover;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['other'], [], [], False);
  Approver := TFakeApprover.Create;
  try
    Approver.Outcome := aoAllowOnce;
    Tool := BuildTool(Approver.Approve, 0);
    try
      AssertTrue('ok', Tool.Run('{"command":"ls","reason":"r"}', R, E));
      AssertEquals('executed', 1, FExecutor.Calls);
      AssertEquals('approver asked', 1, Approver.Calls);
      AssertEquals('not persisted', 0, FSource.Approvals.Count);
    finally
      Tool.Free;
    end;
  finally
    Approver.Free;
  end;
end;

procedure TCommandToolTest.TestAskAllowAlwaysExecutesAndPersists;
var
  Tool: TCommandTool;
  Approver: TFakeApprover;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['other'], [], [], False);
  Approver := TFakeApprover.Create;
  try
    Approver.Outcome := aoAllowAlways;
    Tool := BuildTool(Approver.Approve, 0);
    try
      AssertTrue('ok', Tool.Run('{"command":"ls","reason":"r"}', R, E));
      AssertEquals('executed', 1, FExecutor.Calls);
      AssertEquals('persisted once', 1, FSource.Approvals.Count);
      AssertEquals('persisted executable', 'ls', FSource.Approvals[0]);
    finally
      Tool.Free;
    end;
  finally
    Approver.Free;
  end;
end;

procedure TCommandToolTest.TestAskDenyDoesNotExecute;
var
  Tool: TCommandTool;
  Approver: TFakeApprover;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['other'], [], [], False);
  Approver := TFakeApprover.Create;
  try
    Approver.Outcome := aoDeny;
    Tool := BuildTool(Approver.Approve, 0);
    try
      AssertFalse('denied', Tool.Run('{"command":"ls","reason":"r"}', R, E));
      AssertEquals('not executed', 0, FExecutor.Calls);
      AssertEquals('approver asked', 1, Approver.Calls);
    finally
      Tool.Free;
    end;
  finally
    Approver.Free;
  end;
end;

procedure TCommandToolTest.TestReasonPassedToApprover;
var
  Tool: TCommandTool;
  Approver: TFakeApprover;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['other'], [], [], False);
  Approver := TFakeApprover.Create;
  try
    Approver.Outcome := aoAllowOnce;
    Tool := BuildTool(Approver.Approve, 0);
    try
      Tool.Run('{"command":"ls","reason":"because reasons"}', R, E);
      AssertEquals('reason forwarded', 'because reasons',
        Approver.LastRequest.Reason);
      AssertEquals('command forwarded', 'ls', Approver.LastRequest.Command);
    finally
      Tool.Free;
    end;
  finally
    Approver.Free;
  end;
end;

procedure TCommandToolTest.TestReasonRecordedInAudit;
var
  Tool: TCommandTool;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['echo'], [], [], False);
  Tool := BuildTool(nil, 0);
  try
    Tool.Run('{"command":"echo hi","reason":"audit me"}', R, E);
    AssertEquals('one audit', 1, FSource.AuditCount);
    AssertEquals('reason in audit', 'audit me', FSource.Audits[0].Reason);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestTimeoutReports124;
var
  Tool: TCommandTool;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['sleep'], [], [], False);
  FExecutor.ResultExec.Output := '';
  FExecutor.ResultExec.ExitCode := 124;
  FExecutor.ResultExec.TimedOut := True;
  Tool := BuildTool(nil, 0);
  try
    AssertTrue('ok', Tool.Run('{"command":"sleep 9","reason":"r"}', R, E));
    AssertTrue('reports 124', Pos('exit_code: 124', R) > 0);
    AssertTrue('audit timed out', FSource.Audits[0].TimedOut);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestOutputIsTruncatedWithMarker;
var
  Tool: TCommandTool;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['echo'], [], [], False);
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

procedure TCommandToolTest.TestPolicyReloadedEachCall;
var
  Tool: TCommandTool;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['echo'], [], [], False);
  Tool := BuildTool(nil, 0);
  try
    Tool.Run('{"command":"echo a","reason":"r"}', R, E);
    FSource.Policy := MakePolicy([], [], [], False);
    AssertFalse('second now asks and denies', Tool.Run(
      '{"command":"echo a","reason":"r"}', R, E));
    AssertEquals('reloaded per call', 2, FSource.LoadCalls);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestLoadPolicyErrorFailsClosed;
var
  Tool: TCommandTool;
  R, E: string;
begin
  FSource.LoadFails := True;
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('fails closed', Tool.Run('{"command":"ls","reason":"r"}', R, E));
    AssertEquals('not executed', 0, FExecutor.Calls);
    AssertTrue('mentions policy', Pos('policy', E) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestAuditRecordedForAllowDenyAndOutcome;
var
  Tool: TCommandTool;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['echo'], ['rm'], [], False);
  Tool := BuildTool(nil, 0);
  try
    Tool.Run('{"command":"echo hi","reason":"r"}', R, E);
    AssertEquals('allowed audit', 'policy', FSource.Audits[0].Approval);
    AssertEquals('allow decision', Ord(cdAllow),
      Ord(FSource.Audits[0].Decision));
    Tool.Run('{"command":"rm x","reason":"r"}', R, E);
    AssertEquals('two audits', 2, FSource.AuditCount);
    AssertEquals('denied audit', 'denied', FSource.Audits[1].Approval);
    AssertEquals('deny decision', Ord(cdDeny), Ord(FSource.Audits[1].Decision));
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestHandlerNeverRaises;
var
  Tool: TCommandTool;
  R, E: string;
begin
  FSource.Policy := MakePolicy(['echo'], [], [], False);
  FExecutor.RaiseOnExecute := True;
  Tool := BuildTool(nil, 0);
  try
    AssertFalse('caught', Tool.Run('{"command":"echo hi","reason":"r"}', R, E));
    AssertTrue('error text', Pos('run_command error', E) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TCommandToolTest.TestStoreCommandPolicySourceRoundTrip;
var
  Store: TSqliteStore;
  Err: TStoreError;
  Src: ICommandPolicySource;
  Pol: TCommandPolicy;
  PErr: string;
  Entry: TCommandAuditEntry;
  Req: TStoredRequest;
begin
  Store := OpenStore;
  try
    AssertTrue('set allow', Store.SetSetting(SettingPolicyAllow,
      '["echo","ls"]', Err));
    AssertTrue('set deny', Store.SetSetting(SettingPolicyDeny, '["rm"]', Err));
    AssertTrue('set roots', Store.SetSetting(SettingPolicyRoots,
      '["/srv"]', Err));
    Src := TStoreCommandPolicySource.Create(Store);
    AssertTrue('load', Src.LoadPolicy(Pol, PErr));
    AssertEquals('allow count', 2, Length(Pol.Allow));
    AssertEquals('deny', 'rm', Pol.Deny[0]);
    AssertEquals('root', '/srv', Pol.AllowedRoots[0]);

    AssertTrue('save approval', Src.SaveApproval('echo', PErr));
    AssertTrue('reload', Src.LoadPolicy(Pol, PErr));
    AssertEquals('approved merged into allow', 3, Length(Pol.Allow));

    Entry := Default(TCommandAuditEntry);
    Entry.Id := 'audit-1';
    Entry.Command := 'echo hi';
    Entry.Reason := 'because';
    Entry.Decision := cdAllow;
    Entry.Approval := 'policy';
    Entry.ExitCode := 0;
    Src.RecordAudit(Entry);

    AssertTrue('audit stored', Store.GetRequest('audit-1', Req, Err));
    AssertEquals('kind', 'command', Req.Kind);
    AssertEquals('payload', 'echo hi', Req.Payload);
    AssertEquals('status', Ord(rsCompleted), Ord(Req.Status));
  finally
    Store.Free;
  end;
end;

procedure TCommandToolTest.TestRoundTripAgainstFakeProvider;
var
  Cfg: TLLMConfig;
  ACfg: TAgentConfig;
  Fake: TFakeTransport;
  Client: TLLMClient;
  Store: IConversationStore;
  Tools: TToolRegistry;
  Loop: TAgentLoop;
  Tool: TCommandTool;
  Answer: string;
  Err: TLLMError;
begin
  FSource.Policy := MakePolicy(['echo'], [], [], False);
  FExecutor.ResultExec.Output := 'hi there' + LineEnding;
  Fake := TFakeTransport.Create;
  try
    Cfg := Default(TLLMConfig);
    Cfg.Endpoint := 'https://example.test/v1/chat/completions';
    Cfg.Model := 'm';
    Cfg.ApiKey := 'k';
    Client := TLLMClient.Create(Cfg, Fake);
    Store := TMemoryConversationStore.Create;
    Tools := TToolRegistry.Create;
    Tool := TCommandTool.Create(MakeConfig(0), FSource, nil, FExecutor);
    try
      Tool.Register(Tools);
      ACfg := Default(TAgentConfig);
      ACfg.MaxToolIterations := 8;
      Loop := TAgentLoop.Create(Client, Store, Tools, ACfg);
      try
        Fake.AddResponse([ToolNameFrame(0, 'call_1', CommandToolName),
          ToolArgsFrame(0, '{"command":"echo hi","reason":"r"}'),
          FinishFrame('tool_calls'), DoneFrame]);
        Fake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
        AssertTrue('send ok', Loop.Send('go', nil, Answer, Err));
        AssertEquals('answer', 'done', Answer);
        AssertEquals('executed once', 1, FExecutor.Calls);
        AssertTrue('output fed back', Pos('hi there', Fake.LastBody) > 0);
      finally
        Loop.Free;
      end;
    finally
      Tool.Free;
      Tools.Free;
      Store := nil;
      Client.Free;
    end;
  finally
    Fake.Free;
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

procedure TCommandToolTest.TestMemoryPolicySourceAsksThenRemembers;
var
  Src: ICommandPolicySource;
  Pol: TCommandPolicy;
  PErr: string;
  Entry: TCommandAuditEntry;
begin
  Src := TMemoryCommandPolicySource.Create(DefaultCommandPolicy);
  AssertTrue('load', Src.LoadPolicy(Pol, PErr));
  AssertEquals('asks first', Ord(cdAsk),
    Ord(ClassifyCommand(ParseCommand('ls', ssPosix), Pol).Decision));

  AssertTrue('approve', Src.SaveApproval('ls', PErr));
  AssertTrue('reload', Src.LoadPolicy(Pol, PErr));
  AssertEquals('remembers', Ord(cdAllow),
    Ord(ClassifyCommand(ParseCommand('ls', ssPosix), Pol).Decision));

  Entry := Default(TCommandAuditEntry);
  Src.RecordAudit(Entry);   // no sink; must not raise
end;

initialization
  RegisterTest(TCommandToolTest);
end.
