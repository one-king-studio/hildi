unit test_subagent_supervisor;
{ fpcunit tests for the subagent supervisor: spawn (child session + lineage),
  capacity and depth caps, result capture, abort/release, unknown-id errors, and
  teardown.

  Children run as in-process runtimes over real AF_UNIX sockets (the supervisor's
  injectable client factory), so the wire path is exercised without spawning a
  process; the child's LLM is an injected fake transport.

  Follow-ups for a later phase (need a scripted approval-producing child): the
  approval relay up/down and the headless auto-deny. }

{$mode delphi}{$H+}

interface

uses
  Classes, Contnrs, SysUtils, fpcunit, testregistry,
  hildegard.helper.workspace, hildegard.helper.store, hildegard.helper.session,
  hildegard.helper.session.protocol, hildegard.helper.session.client,
  hildegard.helper.session.socket, hildegard.helper.session.runtime,
  hildegard.helper.subagent, hildegard.helper.subagent.supervisor,
  hildegard.helper.approval,
  hildegard.helper.llm, llm_fakes;

type
  TRuntimeThread = class(TThread)
  private
    FRuntime: TSessionRuntime;
  protected
    procedure Execute; override;
  public
    ExitCode: Integer;
    constructor Create(ARuntime: TSessionRuntime);
    property Runtime: TSessionRuntime read FRuntime;
  end;

  TSubagentSupervisorTest = class(TTestCase)
  private
    FDir, FWs, FDbPath: string;
    FRuntimes: TObjectList;
    FStore: TSqliteStore;
    FRoot: string;
    FChildTransport: TLLMTransport;
    function StoreConfig: TStoreConfig;    procedure OpenRootStore;
    function MakeChildRuntime(const ASessionId: string;
      ATransport: TLLMTransport): TRuntimeThread;
    function MakeSupervisor(AMax, ADepth: Integer): TSubagentSupervisor;
    { The injectable client factory: spawn the child runtime in-process (with
      the test's fake transport), wait for its socket, then attach. }
    function ChildFactory(const AConfig: TSessionClientConfig;
      const ASink: ISessionSink; out AError: string): TSessionClient;
    function WaitEvent(ASup: TSubagentSupervisor; AKind: TSubagentEventKind;
      out AEvent: TSubagentEvent): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestDelegateSpawnsChildWithLineage;
    procedure TestDelegateReturnsSessionAndCapacity;
    procedure TestCapacityCapFailsCleanly;
    procedure TestDepthCapFailsCleanly;
    procedure TestResultCapturedFromChild;
    procedure TestAbortReleasesSlot;
    procedure TestReleaseDetachesWithoutAbort;
    procedure TestUnknownChildIdErrors;
    procedure TestTerminateAllOnShutdown;
    procedure TestChildApprovalRelayed;
    procedure TestAutoDenyWhenHeadless;
  end;

implementation

constructor TRuntimeThread.Create(ARuntime: TSessionRuntime);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRuntime := ARuntime;
end;

procedure TRuntimeThread.Execute;
begin
  ExitCode := FRuntime.Serve;
end;

procedure TSubagentSupervisorTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhsub_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  FWs := IncludeTrailingPathDelimiter(FDir) + 'ws';
  ForceDirectories(FWs);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
  FRuntimes := TObjectList.Create(True);
  FChildTransport := nil;
  OpenRootStore;
end;

procedure TSubagentSupervisorTest.TearDown;
var
  I: Integer;
begin
  for I := 0 to FRuntimes.Count - 1 do
  begin
    if not TRuntimeThread(FRuntimes[I]).Finished then
      TRuntimeThread(FRuntimes[I]).Runtime.Stop;
    TRuntimeThread(FRuntimes[I]).WaitFor;
    TRuntimeThread(FRuntimes[I]).Runtime.Free;
  end;
  FRuntimes.Free;
  FChildTransport.Free;
  FChildTransport := nil;
  FStore.Free;
  DeleteFile(FDbPath);
  DeleteFile(FDbPath + '-wal');
  DeleteFile(FDbPath + '-shm');
  RemoveDir(FWs);
  RemoveDir(FDir);
end;

function TSubagentSupervisorTest.StoreConfig: TStoreConfig;
begin
  Result := Default(TStoreConfig);
  Result.DatabasePath := FDbPath;
  Result.BusyTimeoutMs := 5000;
end;

procedure TSubagentSupervisorTest.OpenRootStore;
var
  Ws: TWorkspace;
  WsErr: string;
  Id: Integer;
  Err: TStoreError;
begin
  Ws := TWorkspace.Open(FWs, WsErr);
  if Ws = nil then
    raise Exception.Create('workspace: ' + WsErr);
  try
    FStore := TSqliteStore.Create(StoreConfig);
    if not FStore.Open(Err) then
      raise Exception.Create('store: ' + Err.Message);
    FStore.EnsureWorkspace(Ws.Root, Id, Err);
    FStore.CreateSession(Id, FRoot, Err);
  finally
    Ws.Free;
  end;
end;

function TSubagentSupervisorTest.MakeChildRuntime(const ASessionId: string;
  ATransport: TLLMTransport): TRuntimeThread;
var
  Cfg: TSessionRuntimeConfig;
  Err: string;
  Rt: TSessionRuntime;
  Deadline: Int64;
begin
  Cfg := Default(TSessionRuntimeConfig);
  Cfg.SessionId := ASessionId;
  Cfg.WorkspacePath := FWs;
  Cfg.StorePath := FDbPath;
  Cfg.IdleExitMs := 8000;
  Cfg.Transport := ATransport;
  Rt := TSessionRuntime.Open(Cfg, Err);
  if Rt = nil then
    raise Exception.Create('child runtime: ' + Err);
  Result := TRuntimeThread.Create(Rt);
  FRuntimes.Add(Result);
  Result.Start;
  { Wait (bounded) for the child socket before the supervisor's client
    connects. }
  Deadline := GetTickCount64 + 3000;
  while (not SessionSocketReady(ASessionId)) and
    (GetTickCount64 < Deadline) do
    Sleep(5);
end;

function TSubagentSupervisorTest.MakeSupervisor(AMax,
  ADepth: Integer): TSubagentSupervisor;
var
  Cfg: TSubagentSupervisorConfig;
begin
  Cfg := Default(TSubagentSupervisorConfig);
  Cfg.WorkspacePath := FWs;
  Cfg.StorePath := FDbPath;
  Cfg.ParentSessionId := FRoot;
  Cfg.ParentWorkspaceId := 1;
  Cfg.ParentDepth := 0;
  Cfg.MaxChildren := AMax;
  Cfg.MaxDepth := ADepth;
  Cfg.IdleExitMs := 8000;
  Result := TSubagentSupervisor.Create(Cfg, FStore);
  Result.Factory := ChildFactory;
end;

function TSubagentSupervisorTest.ChildFactory(
  const AConfig: TSessionClientConfig; const ASink: ISessionSink;
  out AError: string): TSessionClient;
begin
  { Spawn the child's runtime in-process, then attach as its driver. }
  MakeChildRuntime(AConfig.SessionId, FChildTransport);
  Result := TSessionClient.Open(AConfig, ASink, AError);
end;

function TSubagentSupervisorTest.WaitEvent(ASup: TSubagentSupervisor;
  AKind: TSubagentEventKind; out AEvent: TSubagentEvent): Boolean;
var
  Deadline: Int64;
begin
  Deadline := GetTickCount64 + 6000;
  repeat
    if ASup.Poll(AEvent) and (AEvent.Kind = AKind) then
      Exit(True);
    Sleep(10);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

{ --- tests -------------------------------------------------------------- }

procedure TSubagentSupervisorTest.TestDelegateSpawnsChildWithLineage;
var
  Sup: TSubagentSupervisor;
  Res: TSubagentSpawnResult;
  Parent, Lbl: string;
  Depth: Integer;
  Err: TStoreError;
  Ev: TSubagentEvent;
begin
  FChildTransport := TFakeTransport.Create;
  Sup := MakeSupervisor(10, 1);
  try
    AssertTrue('delegate ok', Sup.Delegate('do it', 'ctx', 'research', Res));
    AssertTrue('spawned event', WaitEvent(Sup, sekSpawned, Ev));
    { The child is an ordinary session with lineage. }
    AssertTrue('lineage readable',
      FStore.SessionLineage(Res.SessionId, Parent, Depth, Lbl, Err));
    AssertEquals('parent', FRoot, Parent);
    AssertEquals('depth', 1, Depth);
    AssertEquals('label', 'research', Lbl);
  finally
    Sup.Free;
  end;
end;

procedure TSubagentSupervisorTest.TestDelegateReturnsSessionAndCapacity;
var
  Sup: TSubagentSupervisor;
  Res: TSubagentSpawnResult;
begin
  FChildTransport := TFakeTransport.Create;
  Sup := MakeSupervisor(10, 1);
  try
    AssertTrue('delegate ok', Sup.Delegate('t', 'c', 'l', Res));
    AssertTrue('has session id', Res.SessionId <> '');
    AssertEquals('max', 10, Res.Max);
    AssertEquals('one slot used', 9, Res.Available);
    AssertEquals('available property', 9, Sup.Available);
  finally
    Sup.Free;
  end;
end;

procedure TSubagentSupervisorTest.TestCapacityCapFailsCleanly;
var
  Sup: TSubagentSupervisor;
  Res: TSubagentSpawnResult;
begin
  FChildTransport := TFakeTransport.Create;
  Sup := MakeSupervisor(1, 1);
  try
    AssertTrue('first ok', Sup.Delegate('t', 'c', 'l', Res));
    AssertFalse('second fails', Sup.Delegate('t2', 'c', 'l2', Res));
    AssertTrue('names capacity', Pos('capacity', Res.Error) > 0);
    AssertEquals('still one available', 0, Res.Available);
  finally
    Sup.Free;
  end;
end;

procedure TSubagentSupervisorTest.TestDepthCapFailsCleanly;
var
  Sup: TSubagentSupervisor;
  Res: TSubagentSpawnResult;
  Cfg: TSubagentSupervisorConfig;
begin
  { A parent already at depth 1 may not spawn. }
  Cfg := Default(TSubagentSupervisorConfig);
  Cfg.WorkspacePath := FWs;
  Cfg.StorePath := FDbPath;
  Cfg.ParentSessionId := FRoot;
  Cfg.ParentWorkspaceId := 1;
  Cfg.ParentDepth := 1;
  Cfg.MaxChildren := 10;
  Cfg.MaxDepth := 1;
  Sup := TSubagentSupervisor.Create(Cfg, FStore);
  try
    AssertFalse('depth cap fails', Sup.Delegate('t', 'c', 'l', Res));
    AssertTrue('names depth', Pos('depth', Res.Error) > 0);
  finally
    Sup.Free;
  end;
end;

procedure TSubagentSupervisorTest.TestResultCapturedFromChild;
var
  Sup: TSubagentSupervisor;
  Res: TSubagentSpawnResult;
  Ev: TSubagentEvent;
  Fake: TFakeTransport;
begin
  Fake := TFakeTransport.Create;
  Fake.AddResponse([TextDelta('the delegated answer'),
    FinishFrame('stop'), DoneFrame]);
  FChildTransport := Fake;
  Sup := MakeSupervisor(10, 1);
  try
    AssertTrue('delegate ok', Sup.Delegate('do it', 'ctx', 'l', Res));
    AssertTrue('result event', WaitEvent(Sup, sekResult, Ev));
    AssertEquals('child id', Res.SessionId, Ev.SessionId);
    AssertTrue('captures the answer', Pos('the delegated answer',
      Ev.Result) > 0);
  finally
    Sup.Free;
  end;
end;

procedure TSubagentSupervisorTest.TestAbortReleasesSlot;
var
  Sup: TSubagentSupervisor;
  Res: TSubagentSpawnResult;
  Err: string;
  Ev: TSubagentEvent;
begin
  FChildTransport := TFakeTransport.Create;
  Sup := MakeSupervisor(10, 1);
  try
    Sup.Delegate('t', 'c', 'l', Res);
    AssertEquals('one slot used', 9, Sup.Available);
    AssertTrue('abort ok', Sup.Abort(Res.SessionId, Err));
    AssertEquals('slot freed', 10, Sup.Available);
    AssertTrue('aborted event', WaitEvent(Sup, sekAborted, Ev));
    AssertEquals('gone after abort', 'gone', Sup.Status(Res.SessionId));
  finally
    Sup.Free;
  end;
end;

procedure TSubagentSupervisorTest.TestReleaseDetachesWithoutAbort;
var
  Sup: TSubagentSupervisor;
  Res: TSubagentSpawnResult;
  Err: string;
begin
  FChildTransport := TFakeTransport.Create;
  Sup := MakeSupervisor(10, 1);
  try
    Sup.Delegate('t', 'c', 'l', Res);
    AssertEquals('one slot used', 9, Sup.Available);
    AssertTrue('release ok', Sup.Release(Res.SessionId, Err));
    AssertEquals('slot freed', 10, Sup.Available);
    { Detached, so no longer tracked. }
    AssertEquals('no longer tracked', 'gone', Sup.Status(Res.SessionId));
  finally
    Sup.Free;
  end;
end;

procedure TSubagentSupervisorTest.TestUnknownChildIdErrors;
var
  Sup: TSubagentSupervisor;
  Err: string;
begin
  Sup := MakeSupervisor(10, 1);
  try
    AssertFalse('message fails', Sup.Message('nope', 'hi', Err));
    AssertTrue('message error', Pos('nope', Err) > 0);
    AssertFalse('abort fails', Sup.Abort('nope', Err));
    AssertTrue('abort error', Pos('nope', Err) > 0);
    AssertFalse('release fails', Sup.Release('nope', Err));
  finally
    Sup.Free;
  end;
end;

procedure TSubagentSupervisorTest.TestTerminateAllOnShutdown;
var
  Sup: TSubagentSupervisor;
  Res: TSubagentSpawnResult;
begin
  FChildTransport := TFakeTransport.Create;
  Sup := MakeSupervisor(10, 1);
  try
    Sup.Delegate('t', 'c', 'l', Res);
    AssertEquals('one slot used', 9, Sup.Available);
    Sup.TerminateAll;
    AssertEquals('all slots free', 10, Sup.Available);
    AssertEquals('status gone', 'gone', Sup.Status(Res.SessionId));
  finally
    Sup.Free;
  end;
end;

procedure TSubagentSupervisorTest.TestChildApprovalRelayed;
var
  Sup: TSubagentSupervisor;
  Res: TSubagentSpawnResult;
  Ev: TSubagentEvent;
  Fake: TFakeTransport;
  Choice: TApprovalChoice;
begin
  { The child calls run_command, which asks for approval. The ask is relayed up
    as sekApprovalAsk with a namespaced ask id; answering it lets the child
    finish. }
  Fake := TFakeTransport.Create;
  Fake.AddResponse([ToolNameFrame(0, 'call_1', 'run_command'),
    ToolArgsFrame(0, '{"command":"echo hi","reason":"say hi"}'),
    FinishFrame('tool_calls'), DoneFrame]);
  Fake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
  FChildTransport := Fake;
  Sup := MakeSupervisor(10, 1);
  try
    AssertTrue('delegate ok', Sup.Delegate('do it', 'ctx', 'l', Res));
    AssertTrue('child ask relayed', WaitEvent(Sup, sekApprovalAsk, Ev));
    AssertEquals('names the child', Res.SessionId, Ev.SessionId);
    AssertTrue('has a child ask id', Ev.AskId <> '');

    { Approve and let the child complete. }
    Choice := Default(TApprovalChoice);
    Choice.Allowed := True;
    Choice.OptionKey := 'once';
    Choice.Scope := asWorkspace;
    Sup.AnswerChildAsk(Ev.SessionId, Ev.AskId, Choice);
    AssertTrue('child completes', WaitEvent(Sup, sekResult, Ev));
    AssertEquals('completed', 'completed', Ev.Status);
  finally
    Sup.Free;
  end;
end;

procedure TSubagentSupervisorTest.TestAutoDenyWhenHeadless;
var
  Sup: TSubagentSupervisor;
  Res: TSubagentSpawnResult;
  Ev: TSubagentEvent;
  Fake: TFakeTransport;
  Cfg: TSubagentSupervisorConfig;
begin
  { With no attached client, an unanswered child ask is auto-denied after the
    window and the child continues (the denial is answered, not left hanging). }
  Fake := TFakeTransport.Create;
  Fake.AddResponse([ToolNameFrame(0, 'call_1', 'run_command'),
    ToolArgsFrame(0, '{"command":"echo hi","reason":"say hi"}'),
    FinishFrame('tool_calls'), DoneFrame]);
  Fake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
  FChildTransport := Fake;

  Cfg := Default(TSubagentSupervisorConfig);
  Cfg.WorkspacePath := FWs;
  Cfg.StorePath := FDbPath;
  Cfg.ParentSessionId := FRoot;
  Cfg.ParentWorkspaceId := 1;
  Cfg.ParentDepth := 0;
  Cfg.MaxChildren := 10;
  Cfg.MaxDepth := 1;
  Cfg.IdleExitMs := 8000;
  Cfg.AutoDenyMs := 200;   // a short window for the test
  Sup := TSubagentSupervisor.Create(Cfg, FStore);
  Sup.Factory := ChildFactory;
  Sup.HasClient := False;   // headless
  try
    AssertTrue('delegate ok', Sup.Delegate('do it', 'ctx', 'l', Res));
    AssertTrue('child ask relayed', WaitEvent(Sup, sekApprovalAsk, Ev));
    { Wait past the auto-deny window; the supervisor denies and the child, told
      it was denied, continues and finishes. }
    Sleep(400);
    Sup.TickAutoDeny(GetTickCount64);
    AssertTrue('child completes after auto-deny',
      WaitEvent(Sup, sekResult, Ev));
  finally
    Sup.Free;
  end;
end;

initialization
  RegisterTest(TSubagentSupervisorTest);
end.
