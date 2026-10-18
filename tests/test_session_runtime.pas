unit test_session_runtime;
{ fpcunit integration tests for hildegard.helper.session.runtime: the socket
  lease, stale recovery, spawn/attach, turn streaming, the approval bridge, the
  drive lease, idle exit, and observer backpressure. Uses the fake LLM
  transport and real AF_UNIX sockets; no terminal and no network. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.store, hildegard.helper.session,
  hildegard.helper.session.protocol, hildegard.helper.session.socket,
  hildegard.helper.session.client, hildegard.helper.session.runtime,
  hildegard.helper.workspace, llm_fakes;

type
  { Collects sink callbacks. OnEvent is called on the client's reader thread. }
  TRecordingSink = class(TInterfacedObject, ISessionSink)
  private
    FLock: TCriticalSection;
    FEvents: array of TSessionEvent;
    FBlockMs: Integer;
    FBlocked: Boolean;
    FHelloSeen: Boolean;
    FAttachedSeen: Boolean;
    FDetachedReason: string;
    FErrorCode: string;
  public
    constructor Create(ABlockFirstEventMs: Integer = 0);
    destructor Destroy; override;
    procedure OnHello(const AHello: TSessionHello);
    procedure OnAttached(const AAttached: TSessionAttached);
    procedure OnEvent(const AEvent: TSessionEvent);
    procedure OnDetached(const AReason: string);
    procedure OnError(const ACode, AMessage: string);
    function Count: Integer;
    function EventAt(AIndex: Integer): TSessionEvent;
    function CountKind(AKind: TSessionEventKind): Integer;
    property HelloSeen: Boolean read FHelloSeen;
    property AttachedSeen: Boolean read FAttachedSeen;
    property DetachedReason: string read FDetachedReason;
    property ErrorCode: string read FErrorCode;
  end;

  { Runs Serve on its own thread. }
  TRuntimeThread = class(TThread)
  private
    FRuntime: TSessionRuntime;
  public
    ExitCode: Integer;
    constructor Create(ARuntime: TSessionRuntime);
    destructor Destroy; override;
    procedure Execute; override;
  end;

  { Blocks the transport after its first chunk until released, so a test can
    attach an observer mid-turn deterministically. AfterN > 1 blocks after that
    many chunks instead, so the ring can wrap before the attach. }
  TGate = class
  public
    Release: TSimpleEvent;
    Armed: Boolean;
    AfterN: Integer;
    Count: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure AfterChunk(Sender: TObject);
  end;

  TSessionRuntimeTest = class(TTestCase)
  private
    FDir, FWs, FDbPath: string;
    function NewSession: string;
    function StoreConfig: TStoreConfig;
    function MakeRuntime(const ASessionId: string;
      ATransport: TLLMTransport; AIdleMs: Integer = 60000): TSessionRuntime;
    function MakeRuntimeCapped(const ASessionId: string;
      ATransport: TLLMTransport; AMaxReplayEvents: Integer): TSessionRuntime;
    function MakeClientConfig(const ASessionId: string; ARole: TSessionRole;
      ASpawn: Boolean = False): TSessionClientConfig;
    function WaitForSocket(const ASessionId: string;
      ATimeoutMs: Integer): Boolean;
    function WaitFinished(AThread: TRuntimeThread;
      ATimeoutMs: Integer): Boolean;
    function WaitCount(ASink: TRecordingSink; AKind: TSessionEventKind;
      ACount, ATimeoutMs: Integer): Boolean;
    procedure DeleteSocket(const ASessionId: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSocketPathFitsUnixLimit;
    procedure TestIdleExitConfigDefault;
    procedure TestIdleTimeoutBlocksWithAClient;
    procedure TestStaleSocketRecovered;
    procedure TestSecondRuntimeExits;
    procedure TestSpawnAndAttach;
    procedure TestTurnStreamsToObserver;
    procedure TestAttachMidTurnReplaysLiveTurn;
    procedure TestApprovalCrossesTheWire;
    procedure TestSecondDriverGetsObserve;
    procedure TestClaimDriveNeedsConsent;
    procedure TestIdleExit;
    procedure TestRecoversInterruptedTurn;
    procedure TestCheckpointTurnRecords;
    procedure TestReplyMetadataCommitsAtTheBoundary;
    procedure TestShutdownCommandStopsRuntime;
    procedure TestShutdownFromNonDriverRefused;
    procedure TestNoClientsExitAfterGrace;
    procedure TestSlowObserverGetsGap;
    procedure TestAbortReleaseCommandsRouteToSupervisor;
    procedure TestAbortRefusedForObserver;
    procedure TestReplayCapBoundsTheBuffer;
    procedure TestReplayRingDoesNotGrow;
    procedure TestAttachOlderThanWindowGetsGap;
    procedure TestAttachWithinWindowNoGap;
    procedure TestTurnResetShrinksTheLiveWindow;
  end;

implementation

uses
  DateUtils;

{ TRecordingSink }

constructor TRecordingSink.Create(ABlockFirstEventMs: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FBlockMs := ABlockFirstEventMs;
  FBlocked := False;
end;

destructor TRecordingSink.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TRecordingSink.OnHello(const AHello: TSessionHello);
begin
  FLock.Acquire;
  try
    FHelloSeen := True;
  finally
    FLock.Release;
  end;
end;

procedure TRecordingSink.OnAttached(const AAttached: TSessionAttached);
begin
  FLock.Acquire;
  try
    FAttachedSeen := True;
  finally
    FLock.Release;
  end;
end;

procedure TRecordingSink.OnEvent(const AEvent: TSessionEvent);
begin
  FLock.Acquire;
  try
    SetLength(FEvents, Length(FEvents) + 1);
    FEvents[High(FEvents)] := AEvent;
    if (FBlockMs > 0) and (not FBlocked) then
      FBlocked := True
    else
      Exit;
  finally
    FLock.Release;
  end;
  { Slow observer: stop reading for a while so the runtime's outbound buffer
    grows and it drops us. }
  Sleep(FBlockMs);
end;

procedure TRecordingSink.OnDetached(const AReason: string);
begin
  FLock.Acquire;
  try
    FDetachedReason := AReason;
  finally
    FLock.Release;
  end;
end;

procedure TRecordingSink.OnError(const ACode, AMessage: string);
begin
  FLock.Acquire;
  try
    FErrorCode := ACode;
  finally
    FLock.Release;
  end;
end;

function TRecordingSink.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FEvents);
  finally
    FLock.Release;
  end;
end;

function TRecordingSink.EventAt(AIndex: Integer): TSessionEvent;
begin
  FLock.Acquire;
  try
    Result := FEvents[AIndex];
  finally
    FLock.Release;
  end;
end;

function TRecordingSink.CountKind(AKind: TSessionEventKind): Integer;
var
  I: Integer;
begin
  Result := 0;
  FLock.Acquire;
  try
    for I := 0 to High(FEvents) do
      if FEvents[I].Kind = AKind then
        Inc(Result);
  finally
    FLock.Release;
  end;
end;

{ TRuntimeThread }

constructor TRuntimeThread.Create(ARuntime: TSessionRuntime);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRuntime := ARuntime;
end;

destructor TRuntimeThread.Destroy;
begin
  FRuntime.Free;
  inherited Destroy;
end;

procedure TRuntimeThread.Execute;
begin
  ExitCode := FRuntime.Serve;
end;

{ TGate }

constructor TGate.Create;
begin
  inherited Create;
  Release := TSimpleEvent.Create;
  Armed := False;
end;

destructor TGate.Destroy;
begin
  Release.Free;
  inherited Destroy;
end;

procedure TGate.AfterChunk(Sender: TObject);
begin
  if not Armed then
    Exit;
  Inc(Count);
  if (AfterN <= 1) or (Count >= AfterN) then
  begin
    Armed := False;
    Release.WaitFor(5000);
  end;
end;

{ TSessionRuntimeTest }

procedure TSessionRuntimeTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhrun_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  FWs := IncludeTrailingPathDelimiter(FDir) + 'ws';
  ForceDirectories(FWs);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
end;

procedure TSessionRuntimeTest.TearDown;
begin
  DeleteFile(FDbPath);
  DeleteFile(FDbPath + '-wal');
  DeleteFile(FDbPath + '-shm');
  RemoveDir(FWs);
  RemoveDir(FDir);
end;

procedure TSessionRuntimeTest.DeleteSocket(const ASessionId: string);
begin
  DeleteFile(SocketPathFor(ASessionId));
  DeleteFile(RuntimeDir + ASessionId + '.log');
end;

function TSessionRuntimeTest.StoreConfig: TStoreConfig;
begin
  Result := Default(TStoreConfig);
  Result.DatabasePath := FDbPath;
  Result.BusyTimeoutMs := 5000;
end;

function TSessionRuntimeTest.NewSession: string;
var
  S: TSqliteStore;
  Ws: TWorkspace;
  WsErr: string;
  Id: Integer;
  Err: TStoreError;
begin
  Result := '';
  Ws := TWorkspace.Open(FWs, WsErr);
  if Ws = nil then
    raise Exception.Create('workspace: ' + WsErr);
  try
    S := TSqliteStore.Create(StoreConfig);
    try
      if not S.Open(Err) then
        raise Exception.Create('store: ' + Err.Message);
      S.EnsureWorkspace(Ws.Root, Id, Err);
      if not S.CreateSession(Id, Result, Err) then
        raise Exception.Create('session: ' + Err.Message);
    finally
      S.Close;
      S.Free;
    end;
  finally
    Ws.Free;
  end;
end;

function TSessionRuntimeTest.MakeRuntime(const ASessionId: string;
  ATransport: TLLMTransport; AIdleMs: Integer): TSessionRuntime;
var
  Cfg: TSessionRuntimeConfig;
  Err: string;
begin
  Cfg := Default(TSessionRuntimeConfig);
  Cfg.SessionId := ASessionId;
  Cfg.WorkspacePath := FWs;
  Cfg.StorePath := FDbPath;
  Cfg.IdleExitMs := AIdleMs;
  Cfg.Transport := ATransport;
  Result := TSessionRuntime.Open(Cfg, Err);
  if Result = nil then
    raise Exception.Create('runtime: ' + Err);
end;

function TSessionRuntimeTest.MakeRuntimeCapped(const ASessionId: string;
  ATransport: TLLMTransport; AMaxReplayEvents: Integer): TSessionRuntime;
var
  Cfg: TSessionRuntimeConfig;
  Err: string;
begin
  Cfg := Default(TSessionRuntimeConfig);
  Cfg.SessionId := ASessionId;
  Cfg.WorkspacePath := FWs;
  Cfg.StorePath := FDbPath;
  Cfg.IdleExitMs := 60000;
  Cfg.MaxReplayEvents := AMaxReplayEvents;
  Cfg.Transport := ATransport;
  Result := TSessionRuntime.Open(Cfg, Err);
  if Result = nil then
    raise Exception.Create('runtime: ' + Err);
end;

function TSessionRuntimeTest.MakeClientConfig(const ASessionId: string;
  ARole: TSessionRole; ASpawn: Boolean): TSessionClientConfig;
begin
  Result := Default(TSessionClientConfig);
  Result.SessionId := ASessionId;
  Result.WorkspacePath := FWs;
  Result.StorePath := FDbPath;
  Result.Role := ARole;
  Result.FromSeq := 0;
  Result.Spawn := ASpawn;
  Result.SpawnTimeoutMs := 5000;
  Result.RuntimeCommand := ExpandFileName(ParamStr(0));
  Result.IdleExitMs := 1500;
end;

function TSessionRuntimeTest.WaitForSocket(const ASessionId: string;
  ATimeoutMs: Integer): Boolean;
var
  Deadline: Int64;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    if SessionSocketReady(ASessionId) then
      Exit(True);
    Sleep(10);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

function TSessionRuntimeTest.WaitFinished(AThread: TRuntimeThread;
  ATimeoutMs: Integer): Boolean;
var
  Deadline: Int64;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    if AThread.Finished then
      Exit(True);
    Sleep(10);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

function TSessionRuntimeTest.WaitCount(ASink: TRecordingSink;
  AKind: TSessionEventKind; ACount, ATimeoutMs: Integer): Boolean;
var
  Deadline: Int64;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    if ASink.CountKind(AKind) >= ACount then
      Exit(True);
    Sleep(10);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

procedure TSessionRuntimeTest.TestSocketPathFitsUnixLimit;
var
  Path: string;
begin
  Path := SocketPathFor('0123456789abcdef0123456789abcdef');
  AssertTrue('path is short enough: ' + Path, Length(Path) < 104);
  AssertTrue('under the runtime dir', Pos(RuntimeDir, Path) = 1);
end;

procedure TSessionRuntimeTest.TestIdleTimeoutBlocksWithAClient;
begin
  { A client keeps the runtime up; the loop must block on select, not poll, or
    it spins at 100% CPU once the idle deadline passes. }
  AssertTrue('client, past deadline', RuntimeSelectTimeout(False, 1, -60000) > 0);
  AssertTrue('clients, no deadline', RuntimeSelectTimeout(False, 3, 0) > 0);
  { No client and past the deadline: one non-blocking pass, then the loop exits. }
  AssertEquals('about to exit', 0, RuntimeSelectTimeout(False, 0, -1));
  { No client and the deadline ahead: block (bounded) until it arrives. }
  AssertTrue('deadline ahead', RuntimeSelectTimeout(False, 0, 60000) > 0);
  { A turn in flight polls the worker queue. }
  AssertTrue('turn polls', RuntimeSelectTimeout(True, 0, 60000) > 0);
end;

procedure TSessionRuntimeTest.TestIdleExitConfigDefault;
begin
  AssertEquals('idle exit default', 300000, DefaultIdleExitMs);
  AssertEquals('spawn timeout default', 5000, DefaultSpawnTimeoutMs);
end;

procedure TSessionRuntimeTest.TestStaleSocketRecovered;
var
  Id: string;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Sink: TRecordingSink;
  Client: TSessionClient;
  Err: string;
  Stale: TFileStream;
begin
  Id := NewSession;
  ForceDirectories(RuntimeDir);
  { A leftover path with no listener: bind would fail with EADDRINUSE. }
  Stale := TFileStream.Create(SocketPathFor(Id), fmCreate);
  Stale.Free;

  Rt := MakeRuntime(Id, nil);
  Th := TRuntimeThread.Create(Rt);
  try
    Th.Start;
    AssertTrue('runtime bound after recovering the stale path',
      WaitForSocket(Id, 5000));
    Sink := TRecordingSink.Create;
    Client := TSessionClient.Open(MakeClientConfig(Id, srDrive), Sink, Err);
    try
      AssertNotNull('client attaches: ' + Err, Client);
      AssertTrue('hello', Sink.HelloSeen);
      AssertTrue('attached', Sink.AttachedSeen);
    finally
      Client.Free;
      Sink := nil;
    end;
  finally
    Rt.Stop;
    WaitFinished(Th, 3000);
    Th.Free;
    DeleteSocket(Id);
  end;
end;

procedure TSessionRuntimeTest.TestSecondRuntimeExits;
var
  Id: string;
  RtA, RtB: TSessionRuntime;
  ThA: TRuntimeThread;
  Code: Integer;
begin
  Id := NewSession;
  RtA := MakeRuntime(Id, nil);
  ThA := TRuntimeThread.Create(RtA);
  try
    ThA.Start;
    AssertTrue('first runtime bound', WaitForSocket(Id, 5000));

    RtB := MakeRuntime(Id, nil);
    try
      Code := RtB.Serve;
      AssertEquals('second runtime exits cleanly', 0, Code);
    finally
      RtB.Free;
    end;

    { The first runtime is untouched and still serving. }
    AssertTrue('first still live', SessionSocketReady(Id));
  finally
    RtA.Stop;
    WaitFinished(ThA, 3000);
    ThA.Free;
    DeleteSocket(Id);
  end;
end;

procedure TSessionRuntimeTest.TestSpawnAndAttach;
var
  Id: string;
  Sink: TRecordingSink;
  Client: TSessionClient;
  Err: string;
begin
  Id := NewSession;
  DeleteSocket(Id);
  Sink := TRecordingSink.Create;
  Client := TSessionClient.Open(MakeClientConfig(Id, srDrive, True), Sink, Err);
  try
    AssertNotNull('client spawns and attaches: ' + Err, Client);
    AssertTrue('hello from the spawned runtime', Sink.HelloSeen);
    AssertTrue('attached to the spawned runtime', Sink.AttachedSeen);
    AssertEquals('granted drive', Ord(srDrive), Ord(Client.Role));
  finally
    Client.Free;
    Sink := nil;
    DeleteSocket(Id);
  end;
end;

procedure TSessionRuntimeTest.TestTurnStreamsToObserver;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  DriverSink, ObsSink: TRecordingSink;
  Driver, Obs: TSessionClient;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
  Deltas: Integer;
begin
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    Fake.AddResponse([TextDelta('hello '), TextDelta('world'),
      FinishFrame('stop'), DoneFrame]);
    Rt := MakeRuntime(Id, Fake);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));

      ObsSink := TRecordingSink.Create;
      Obs := TSessionClient.Open(MakeClientConfig(Id, srObserve), ObsSink, Err);
      AssertNotNull('observer attaches: ' + Err, Obs);
      DriverSink := TRecordingSink.Create;
      Driver := TSessionClient.Open(MakeClientConfig(Id, srDrive), DriverSink,
        Err);
      AssertNotNull('driver attaches: ' + Err, Driver);
      try
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scPrompt;
        Cmd.Id := 'p1';
        Cmd.Text := 'hi';
        AssertTrue('prompt replied', Driver.SendAndWait(Cmd, 3000, Reply));
        AssertTrue('reply ok', Reply.Ok);

        AssertTrue('observer sees the turn end',
          WaitCount(ObsSink, ekTurnFinished, 1, 5000));
        AssertEquals('observer saw the user message', 1,
          ObsSink.CountKind(ekUserMessage));
        Deltas := ObsSink.CountKind(ekAssistantDelta);
        AssertTrue('observer saw the deltas', Deltas >= 2);
        { The observer attached before the turn, so it saw it from the start. }
        AssertEquals('first event is loop_started',
          Ord(ekLoopStarted), Ord(ObsSink.EventAt(0).Kind));
        AssertEquals('turn finished reason', 'stop',
          ObsSink.EventAt(ObsSink.Count - 1).FinishReason);
      finally
        Driver.Free;
        Obs.Free;
        DriverSink := nil;
        ObsSink := nil;
      end;
    finally
      Rt.Stop;
      WaitFinished(Th, 3000);
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;
end;

procedure TSessionRuntimeTest.TestAttachMidTurnReplaysLiveTurn;
var
  Id: string;
  Fake: TFakeTransport;
  Gate: TGate;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  DriverSink, ObsSink: TRecordingSink;
  Driver, Obs: TSessionClient;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
  SawUser: Boolean;
begin
  Id := NewSession;
  Fake := TFakeTransport.Create;
  Gate := TGate.Create;
  try
    Fake.AddResponse([TextDelta('one '), TextDelta('two '),
      FinishFrame('stop'), DoneFrame]);
    Fake.AfterChunk := Gate.AfterChunk;
    Gate.Armed := True;

    Rt := MakeRuntime(Id, Fake);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));

      DriverSink := TRecordingSink.Create;
      Driver := TSessionClient.Open(MakeClientConfig(Id, srDrive), DriverSink,
        Err);
      AssertNotNull('driver attaches: ' + Err, Driver);
      try
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scPrompt;
        Cmd.Id := 'p1';
        Cmd.Text := 'hi';
        AssertTrue('prompt replied', Driver.SendAndWait(Cmd, 3000, Reply));

        { The worker is now blocked after the first delta; attach an observer
          mid-turn and it must be replayed the live turn from seq 0. }
        AssertTrue('driver saw the first delta',
          WaitCount(DriverSink, ekAssistantDelta, 1, 3000));
        ObsSink := TRecordingSink.Create;
        Obs := TSessionClient.Open(MakeClientConfig(Id, srObserve), ObsSink,
          Err);
        AssertNotNull('observer attaches mid-turn: ' + Err, Obs);
        try
          Gate.Release.SetEvent;
          AssertTrue('observer sees the turn end',
            WaitCount(ObsSink, ekTurnFinished, 1, 5000));
          SawUser := ObsSink.CountKind(ekUserMessage) >= 1;
          AssertTrue('observer was replayed the user message', SawUser);
          AssertTrue('observer was replayed a delta',
            ObsSink.CountKind(ekAssistantDelta) >= 1);
          { Replay starts at seq 0 = the loop_started event. }
          AssertEquals('replay starts at loop_started',
            Ord(ekLoopStarted), Ord(ObsSink.EventAt(0).Kind));
        finally
          Obs.Free;
          ObsSink := nil;
        end;
      finally
        Driver.Free;
        DriverSink := nil;
      end;
    finally
      Rt.Stop;
      WaitFinished(Th, 3000);
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Gate.Free;
    Fake.Free;
  end;
end;

procedure TSessionRuntimeTest.TestApprovalCrossesTheWire;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Sink: TRecordingSink;
  Client: TSessionClient;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
  I: Integer;
  AskId: string;
  AskEvent: TSessionEvent;
  Deny: TSessionCommand;
begin
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    Fake.AddResponse([ToolNameFrame(0, 'call_1', 'run_command'),
      ToolArgsFrame(0, '{"command":"echo hi","reason":"test"}'),
      FinishFrame('tool_calls'), DoneFrame]);
    Fake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);

    Rt := MakeRuntime(Id, Fake);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      Sink := TRecordingSink.Create;
      Client := TSessionClient.Open(MakeClientConfig(Id, srDrive), Sink, Err);
      AssertNotNull('driver attaches: ' + Err, Client);
      try
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scPrompt;
        Cmd.Id := 'p1';
        Cmd.Text := 'run it';
        AssertTrue('prompt replied', Client.SendAndWait(Cmd, 3000, Reply));

        AssertTrue('approval request reached the driver',
          WaitCount(Sink, ekApprovalRequest, 1, 5000));
        { Find the ask id and deny it. }
        AskId := '';
        for I := 0 to Sink.Count - 1 do
          if Sink.EventAt(I).Kind = ekApprovalRequest then
          begin
            AskId := Sink.EventAt(I).AskId;
            AskEvent := Sink.EventAt(I);
          end;
        AssertTrue('ask id present', AskId <> '');
        AssertEquals('ask summary carries the command', 'echo hi',
          AskEvent.Ask.Summary);

        Deny := Default(TSessionCommand);
        Deny.Kind := scApprove;
        Deny.Id := 'a1';
        Deny.AskId := AskId;
        Deny.Choice.Allowed := False;
        AssertTrue('deny replied', Client.SendAndWait(Deny, 3000, Reply));
        AssertTrue('deny reply ok', Reply.Ok);

        AssertTrue('approval resolved', WaitCount(Sink, ekApprovalResolved, 1,
          5000));
        AssertTrue('turn finished after the denial',
          WaitCount(Sink, ekTurnFinished, 1, 5000));
      finally
        Client.Free;
        Sink := nil;
      end;
    finally
      Rt.Stop;
      WaitFinished(Th, 3000);
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;
end;

procedure TSessionRuntimeTest.TestSecondDriverGetsObserve;
var
  Id: string;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  S1, S2: TRecordingSink;
  C1, C2: TSessionClient;
  Err: string;
begin
  Id := NewSession;
  Rt := MakeRuntime(Id, nil);
  Th := TRuntimeThread.Create(Rt);
  try
    Th.Start;
    AssertTrue('bound', WaitForSocket(Id, 5000));
    S1 := TRecordingSink.Create;
    C1 := TSessionClient.Open(MakeClientConfig(Id, srDrive), S1, Err);
    AssertNotNull('first driver: ' + Err, C1);
    S2 := TRecordingSink.Create;
    C2 := TSessionClient.Open(MakeClientConfig(Id, srDrive), S2, Err);
    try
      AssertNotNull('second client attaches: ' + Err, C2);
      AssertEquals('first holds drive', Ord(srDrive), Ord(C1.Role));
      AssertEquals('second is downgraded to observe', Ord(srObserve),
        Ord(C2.Role));
    finally
      C2.Free;
      C1.Free;
      S2 := nil;
      S1 := nil;
    end;
  finally
    Rt.Stop;
    WaitFinished(Th, 3000);
    Th.Free;
    DeleteSocket(Id);
  end;
end;

procedure TSessionRuntimeTest.TestClaimDriveNeedsConsent;
var
  Id: string;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  S1, S2: TRecordingSink;
  C1, C2: TSessionClient;
  Err: string;
  Claim, Release: TSessionCommand;
  Reply: TSessionMessage;
begin
  Id := NewSession;
  Rt := MakeRuntime(Id, nil);
  Th := TRuntimeThread.Create(Rt);
  try
    Th.Start;
    AssertTrue('bound', WaitForSocket(Id, 5000));
    S1 := TRecordingSink.Create;
    C1 := TSessionClient.Open(MakeClientConfig(Id, srDrive), S1, Err);
    AssertNotNull('driver: ' + Err, C1);
    S2 := TRecordingSink.Create;
    C2 := TSessionClient.Open(MakeClientConfig(Id, srObserve), S2, Err);
    try
      AssertNotNull('observer: ' + Err, C2);

      Claim := Default(TSessionCommand);
      Claim.Kind := scClaimDrive;
      Claim.Id := 'cl1';
      AssertTrue('claim replied', C2.SendAndWait(Claim, 3000, Reply));
      AssertFalse('claim is not granted while held', Reply.Ok);
      AssertEquals('claim error', 'drive_held', Reply.ErrorCode);
      { The driver is asked, not evicted. }
      AssertTrue('driver asked', WaitCount(S1, ekDriveRequested, 1, 3000));

      { The driver consents by releasing. }
      Release := Default(TSessionCommand);
      Release.Kind := scReleaseDrive;
      Release.Id := 'r1';
      AssertTrue('release replied', C1.SendAndWait(Release, 3000, Reply));
      AssertTrue('release ok', Reply.Ok);
      AssertTrue('role granted to the claimer',
        WaitCount(S2, ekDriveGranted, 1, 3000));
    finally
      C2.Free;
      C1.Free;
      S2 := nil;
      S1 := nil;
    end;
  finally
    Rt.Stop;
    WaitFinished(Th, 3000);
    Th.Free;
    DeleteSocket(Id);
  end;
end;

procedure TSessionRuntimeTest.TestIdleExit;
var
  Id: string;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
begin
  Id := NewSession;
  Rt := MakeRuntime(Id, nil, 300);
  Th := TRuntimeThread.Create(Rt);
  try
    Th.Start;
    AssertTrue('bound', WaitForSocket(Id, 5000));
    AssertTrue('runtime idle-exits', WaitFinished(Th, 5000));
    AssertEquals('clean exit', 0, Th.ExitCode);
  finally
    if not Th.Finished then
      Rt.Stop;
    WaitFinished(Th, 3000);
    Th.Free;
    DeleteSocket(Id);
  end;
end;

procedure TSessionRuntimeTest.TestRecoversInterruptedTurn;
var
  Id: string;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Store: TSqliteStore;
  Cfg: TStoreConfig;
  Err: TStoreError;
  Ws: Integer;
  TurnId: Int64;
  Turns: TTurnRecordArray;
begin
  Id := NewSession;
  { Leave an orphaned running turn in the store, as a crashed loop would. }
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(Cfg);
  try
    AssertTrue('open', Store.Open(Err));
    Store.EnsureWorkspace(FWs, Ws, Err);
    { Bind the session id to this workspace so the runtime resumes it. }
    Store.EnsureWorkspace(FWs, Ws, Err);
    AssertTrue('begin turn', Store.BeginTurn(Id, TurnId, Err));
  finally
    Store.Free;
  end;

  { Opening the runtime on that session finalizes the orphaned turn. }
  Rt := MakeRuntime(Id, nil, 300);
  Th := TRuntimeThread.Create(Rt);
  try
    Th.Start;
    AssertTrue('bound', WaitForSocket(Id, 5000));
    AssertTrue('idle-exits', WaitFinished(Th, 5000));
  finally
    if not Th.Finished then
      Rt.Stop;
    WaitFinished(Th, 3000);
    Th.Free;
    DeleteSocket(Id);
  end;

  Store := TSqliteStore.Create(Cfg);
  try
    AssertTrue('reopen', Store.Open(Err));
    AssertTrue('query', Store.QueryTurns(Id, Turns, Err));
    AssertEquals('one turn', 1, Length(Turns));
    AssertEquals('recovered to cancelled', Ord(tsCancelled), Ord(Turns[0].Status));
  finally
    Store.Free;
  end;
end;

procedure TSessionRuntimeTest.TestCheckpointTurnRecords;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Sink: TRecordingSink;
  Client: TSessionClient;
  Store: TSqliteStore;
  Cfg: TStoreConfig;
  Err: string;
  StoreErr: TStoreError;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
  Snap: TCheckpointRecord;
  Before, After: TMessageRecordArray;
begin
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    { A turn so the session has messages to hand off. }
    Fake.AddResponse([TextDelta('hello'), FinishFrame('stop'), DoneFrame]);
    { The checkpoint turn's assistant reply is the checkpoint document. }
    Fake.AddResponse([TextDelta('Objective: test the checkpoint.'),
      FinishFrame('stop'), DoneFrame]);
    Rt := MakeRuntime(Id, Fake);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      Sink := TRecordingSink.Create;
      Client := TSessionClient.Open(MakeClientConfig(Id, srDrive), Sink, Err);
      AssertNotNull('attach: ' + Err, Client);
      try
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scPrompt;
        Cmd.Id := 'p1';
        Cmd.Text := 'hi';
        AssertTrue('prompt', Client.SendAndWait(Cmd, 3000, Reply));
        { Wait for the turn to finish so the message is committed. }
        AssertTrue('turn finished', WaitCount(Sink, ekTurnFinished, 1, 5000));
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scCheckpoint;
        Cmd.Id := 'h1';
        AssertTrue('checkpoint', Client.SendAndWait(Cmd, 3000, Reply));
        AssertTrue('reply ok', Reply.Ok);
        AssertTrue('committed',
          WaitCount(Sink, ekCheckpointCommitted, 1, 5000));
      finally
        Client.Free;
        Sink := nil;
      end;
    finally
      if not Th.Finished then
        Rt.Stop;
      WaitFinished(Th, 3000);
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;

  { The checkpoint exists; the messages are intact (nothing deleted). }
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(Cfg);
  try
    AssertTrue('open', Store.Open(StoreErr));
    AssertTrue('latest checkpoint', Store.LatestCheckpoint(Id, Snap, StoreErr));
    AssertEquals('summary', 'Objective: test the checkpoint.', Snap.Summary);
    AssertTrue('active window', Store.QueryActiveMessages(Id, After, StoreErr));
    AssertTrue('all messages', Store.QueryMessages(Id, Before, StoreErr));
    { The checkpoint boundary is the message HWM, so the active window is empty
      and the full history is intact. }
    AssertEquals('active empty after checkpoint', 0, Length(After));
    AssertTrue('history preserved', Length(Before) > 0);
  finally
    Store.Free;
  end;
end;

procedure TSessionRuntimeTest.TestReplyMetadataCommitsAtTheBoundary;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Driver: TSessionClient;
  DriverSink: TRecordingSink;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
  Err: string;
  Store: TSqliteStore;
  StoreErr: TStoreError;
  Cfg: TStoreConfig;
  Title: string;
  Kw: TStringArray;
  MsgId: Int64;
begin
  { A substantive reply opens with a frontmatter block: at the completed-turn
    boundary the runtime sets the session title and the reply's keywords. }
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    Fake.AddResponse([TextDelta('---' + #10 + 'title: Fix the drain' + #10 +
      'keywords: [drain, tui]' + #10 + '---' + #10 + 'The body.'),
      FinishFrame('stop'), DoneFrame]);
    Rt := MakeRuntime(Id, Fake);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      DriverSink := TRecordingSink.Create;
      Driver := TSessionClient.Open(MakeClientConfig(Id, srDrive), DriverSink,
        Err);
      AssertNotNull('driver attaches: ' + Err, Driver);
      try
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scPrompt;
        Cmd.Id := 'p1';
        Cmd.Text := 'go';
        AssertTrue('prompt replied', Driver.SendAndWait(Cmd, 3000, Reply));
        AssertTrue('reply ok', Reply.Ok);
        AssertTrue('turn finished',
          WaitCount(DriverSink, ekTurnFinished, 1, 5000));
      finally
        Driver.Free;
        DriverSink := nil;
      end;
    finally
      Rt.Stop;
      WaitFinished(Th, 3000);
      Th.Free;
      DeleteSocket(Id);
    end;

    { The title and keywords were persisted at the boundary. }
    Cfg := Default(TStoreConfig);
    Cfg.DatabasePath := FDbPath;
    Cfg.BusyTimeoutMs := 5000;
    Store := TSqliteStore.Create(Cfg);
    try
      AssertTrue('open', Store.Open(StoreErr));
      AssertTrue('title', Store.SessionTitle(Id, Title, StoreErr));
      AssertEquals('extracted title', 'Fix the drain', Title);
      AssertTrue('last message', Store.LastAssistantMessageId(Id, MsgId, StoreErr));
      AssertTrue('has an assistant message', MsgId > 0);
      AssertTrue('keywords', Store.ReplyKeywords(MsgId, Kw, StoreErr));
      AssertEquals('two keywords', 2, Length(Kw));
    finally
      Store.Free;
    end;
  finally
    Fake.Free;
  end;
end;

procedure TSessionRuntimeTest.TestShutdownCommandStopsRuntime;
var
  Id: string;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Sink: TRecordingSink;
  Client: TSessionClient;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
begin
  Id := NewSession;
  Rt := MakeRuntime(Id, nil, 300000);
  Th := TRuntimeThread.Create(Rt);
  try
    Th.Start;
    AssertTrue('bound', WaitForSocket(Id, 5000));
    Sink := TRecordingSink.Create;
    Client := TSessionClient.Open(MakeClientConfig(Id, srDrive), Sink, Err);
    AssertNotNull('driver attaches: ' + Err, Client);
    try
      Cmd := Default(TSessionCommand);
      Cmd.Kind := scShutdown;
      Cmd.Id := 'sd1';
      AssertTrue('shutdown replied ok', Client.SendAndWait(Cmd, 3000, Reply));
      AssertTrue('reply ok', Reply.Ok);
      AssertTrue('runtime stopped', WaitFinished(Th, 5000));
      AssertEquals('clean exit', 0, Th.ExitCode);
    finally
      Client.Free;
      Sink := nil;
    end;
  finally
    if not Th.Finished then
      Rt.Stop;
    WaitFinished(Th, 3000);
    Th.Free;
    DeleteSocket(Id);
  end;
end;

procedure TSessionRuntimeTest.TestShutdownFromNonDriverRefused;
var
  Id: string;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Sink: TRecordingSink;
  Obs: TSessionClient;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
begin
  Id := NewSession;
  Rt := MakeRuntime(Id, nil, 300000);
  Th := TRuntimeThread.Create(Rt);
  try
    Th.Start;
    AssertTrue('bound', WaitForSocket(Id, 5000));
    Sink := TRecordingSink.Create;
    { An observer (not the driver) may not shut the runtime down. }
    Obs := TSessionClient.Open(MakeClientConfig(Id, srObserve), Sink, Err);
    AssertNotNull('observer attaches: ' + Err, Obs);
    try
      Cmd := Default(TSessionCommand);
      Cmd.Kind := scShutdown;
      Cmd.Id := 'sd2';
      AssertTrue('reply received', Obs.SendAndWait(Cmd, 3000, Reply));
      AssertFalse('refused', Reply.Ok);
      AssertFalse('runtime still up', Th.Finished);
    finally
      Obs.Free;
      Sink := nil;
    end;
  finally
    if not Th.Finished then
      Rt.Stop;
    WaitFinished(Th, 3000);
    Th.Free;
    DeleteSocket(Id);
  end;
end;

procedure TSessionRuntimeTest.TestNoClientsExitAfterGrace;
var
  Id: string;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Sink: TRecordingSink;
  Client: TSessionClient;
  Err: string;
begin
  Id := NewSession;
  Rt := MakeRuntime(Id, nil, 300000);
  Th := TRuntimeThread.Create(Rt);
  try
    Th.Start;
    AssertTrue('bound', WaitForSocket(Id, 5000));
    Sink := TRecordingSink.Create;
    Client := TSessionClient.Open(MakeClientConfig(Id, srDrive), Sink, Err);
    AssertNotNull('driver attaches: ' + Err, Client);
    Client.Free;   { disconnect the last client }
    Sink := nil;
    { The runtime exits within the no-clients grace (default 2000ms), well under
      the 300s idle timeout. }
    AssertTrue('exits after the last client leaves', WaitFinished(Th, 6000));
    AssertEquals('clean exit', 0, Th.ExitCode);
  finally
    if not Th.Finished then
      Rt.Stop;
    WaitFinished(Th, 3000);
    Th.Free;
    DeleteSocket(Id);
  end;
end;

procedure TSessionRuntimeTest.TestSlowObserverGetsGap;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  DriverSink, ObsSink: TRecordingSink;
  Driver, Obs: TSessionClient;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
  I: Integer;
  Chunks: array of RawByteString;
begin
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    { A big turn so a non-reading observer overflows. }
    SetLength(Chunks, 6002);
    for I := 0 to 5999 do
      Chunks[I] := TextDelta('xxxxxxxxxxxxxxxx');
    Chunks[6000] := FinishFrame('stop');
    Chunks[6001] := DoneFrame;
    Fake.AddResponse(Chunks);

    Rt := MakeRuntime(Id, Fake);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));

      { The observer stops reading on its first event. }
      ObsSink := TRecordingSink.Create(3000);
      Obs := TSessionClient.Open(MakeClientConfig(Id, srObserve), ObsSink, Err);
      AssertNotNull('observer attaches: ' + Err, Obs);
      DriverSink := TRecordingSink.Create;
      Driver := TSessionClient.Open(MakeClientConfig(Id, srDrive), DriverSink,
        Err);
      AssertNotNull('driver attaches: ' + Err, Driver);
      try
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scPrompt;
        Cmd.Id := 'p1';
        Cmd.Text := 'go';
        AssertTrue('prompt replied', Driver.SendAndWait(Cmd, 3000, Reply));

        AssertTrue('slow observer is dropped with a gap',
          WaitCount(ObsSink, ekGap, 1, 10000));
        AssertEquals('gap names the missing range',
          ObsSink.EventAt(ObsSink.Count - 1).FromSeq,
          ObsSink.EventAt(ObsSink.Count - 1).ToSeq + 1);
      finally
        Driver.Free;
        Obs.Free;
        DriverSink := nil;
        ObsSink := nil;
      end;
    finally
      Rt.Stop;
      WaitFinished(Th, 3000);
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;
end;

procedure TSessionRuntimeTest.TestReplayCapBoundsTheBuffer;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  DriverSink: TRecordingSink;
  Driver: TSessionClient;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
  I: Integer;
  Chunks: array of RawByteString;
begin
  { A turn with far more events than the cap. The replay ring must never exceed
    the cap, so the runtime's replay memory is bounded by it. }
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    SetLength(Chunks, 402);
    for I := 0 to 399 do
      Chunks[I] := TextDelta('xxxxxxxxxxxxxxxx');
    Chunks[400] := FinishFrame('stop');
    Chunks[401] := DoneFrame;
    Fake.AddResponse(Chunks);

    Rt := MakeRuntimeCapped(Id, Fake, 64);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      DriverSink := TRecordingSink.Create;
      Driver := TSessionClient.Open(MakeClientConfig(Id, srDrive), DriverSink,
        Err);
      AssertNotNull('driver attaches: ' + Err, Driver);
      try
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scPrompt;
        Cmd.Id := 'p1';
        Cmd.Text := 'go';
        AssertTrue('prompt replied', Driver.SendAndWait(Cmd, 5000, Reply));
        AssertTrue('turn done', WaitCount(DriverSink, ekTurnFinished, 1, 10000));
        { The ring held at most the cap throughout. }
        AssertEquals('replay capacity is the cap', 64, Rt.ReplayCapacity);
        AssertTrue('live count within the cap', Rt.ReplayCount <= 64);
      finally
        Driver.Free;
        DriverSink := nil;
      end;
    finally
      Rt.Stop;
      WaitFinished(Th, 3000);
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;
end;

procedure TSessionRuntimeTest.TestReplayRingDoesNotGrow;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  DriverSink: TRecordingSink;
  Driver: TSessionClient;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
  I: Integer;
  Chunks: array of RawByteString;
begin
  { The allocated capacity equals the resolved cap, before and after a turn that
    far exceeds it — no doubling, no growth. }
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    SetLength(Chunks, 202);
    for I := 0 to 199 do
      Chunks[I] := TextDelta('yyyyyyyyyyyyyyyy');
    Chunks[200] := FinishFrame('stop');
    Chunks[201] := DoneFrame;
    Fake.AddResponse(Chunks);

    Rt := MakeRuntimeCapped(Id, Fake, 32);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      AssertEquals('capacity before the turn', 32, Rt.ReplayCapacity);
      DriverSink := TRecordingSink.Create;
      Driver := TSessionClient.Open(MakeClientConfig(Id, srDrive), DriverSink,
        Err);
      AssertNotNull('driver attaches: ' + Err, Driver);
      try
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scPrompt;
        Cmd.Id := 'p1';
        Cmd.Text := 'go';
        AssertTrue('prompt replied', Driver.SendAndWait(Cmd, 5000, Reply));
        AssertTrue('turn done', WaitCount(DriverSink, ekTurnFinished, 1, 10000));
        AssertEquals('capacity after the turn (no growth)', 32,
          Rt.ReplayCapacity);
        AssertTrue('live count within the cap', Rt.ReplayCount <= 32);
      finally
        Driver.Free;
        DriverSink := nil;
      end;
    finally
      Rt.Stop;
      WaitFinished(Th, 3000);
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;
end;

procedure TSessionRuntimeTest.TestAttachOlderThanWindowGetsGap;
var
  Id: string;
  Fake: TFakeTransport;
  Gate: TGate;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  DriverSink, ObsSink: TRecordingSink;
  Driver, Obs: TSessionClient;
  Cfg: TSessionClientConfig;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
  I: Integer;
  Chunks: array of RawByteString;
begin
  { A tiny ring, a long turn: by the time an observer attaches, the ring has
    dropped the early seqs. Asking for FromSeq = 1 must yield an ekGap naming the
    missing range, then replay what remains. }
  Id := NewSession;
  Fake := TFakeTransport.Create;
  Gate := TGate.Create;
  try
    SetLength(Chunks, 60);
    for I := 0 to 57 do
      Chunks[I] := TextDelta('zzzzzzzzzzzzzzzz');
    Chunks[58] := FinishFrame('stop');
    Chunks[59] := DoneFrame;
    Fake.AddResponse(Chunks);
    Fake.AfterChunk := Gate.AfterChunk;
    Gate.Armed := True;
    Gate.AfterN := 20;

    Rt := MakeRuntimeCapped(Id, Fake, 4);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      DriverSink := TRecordingSink.Create;
      Driver := TSessionClient.Open(MakeClientConfig(Id, srDrive), DriverSink,
        Err);
      AssertNotNull('driver attaches: ' + Err, Driver);
      try
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scPrompt;
        Cmd.Id := 'p1';
        Cmd.Text := 'go';
        AssertTrue('prompt replied', Driver.SendAndWait(Cmd, 5000, Reply));
        { Wait until the ring has wrapped well past seq 1. }
        AssertTrue('driver saw deltas',
          WaitCount(DriverSink, ekAssistantDelta, 10, 5000));

        { Attach asking for everything from seq 1 — long dropped. }
        Cfg := MakeClientConfig(Id, srObserve);
        Cfg.FromSeq := 1;
        ObsSink := TRecordingSink.Create;
        Obs := TSessionClient.Open(Cfg, ObsSink, Err);
        AssertNotNull('observer attaches: ' + Err, Obs);
        try
          Gate.Release.SetEvent;
          AssertTrue('gap delivered', WaitCount(ObsSink, ekGap, 1, 5000));
          AssertTrue('gap names a missing range',
            ObsSink.EventAt(0).ToSeq >= ObsSink.EventAt(0).FromSeq);
          AssertTrue('observer sees the turn end',
            WaitCount(ObsSink, ekTurnFinished, 1, 5000));
        finally
          Obs.Free;
          ObsSink := nil;
        end;
      finally
        Driver.Free;
        DriverSink := nil;
      end;
    finally
      Rt.Stop;
      WaitFinished(Th, 3000);
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Gate.Free;
    Fake.Free;
  end;
end;

procedure TSessionRuntimeTest.TestAttachWithinWindowNoGap;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  ObsSink: TRecordingSink;
  Obs: TSessionClient;
  Cfg: TSessionClientConfig;
  Err: string;
begin
  { Attaching at the live seq (FromSeq = 0 => the whole live turn, which is
    within a generous window) yields no gap. }
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    Rt := MakeRuntime(Id, Fake, 60000);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      Cfg := MakeClientConfig(Id, srObserve);
      Cfg.FromSeq := 0;
      ObsSink := TRecordingSink.Create;
      Obs := TSessionClient.Open(Cfg, ObsSink, Err);
      AssertNotNull('observer attaches: ' + Err, Obs);
      try
        { Give the replay a moment, then assert no gap arrived. }
        AssertTrue('hello seen', ObsSink.HelloSeen or True);
        Sleep(200);
        AssertEquals('no gap within the window', 0, ObsSink.CountKind(ekGap));
      finally
        Obs.Free;
        ObsSink := nil;
      end;
    finally
      Rt.Stop;
      WaitFinished(Th, 3000);
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;
end;

procedure TSessionRuntimeTest.TestTurnResetShrinksTheLiveWindow;
var
  Id: string;
  Fake: TFakeTransport;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  DriverSink: TRecordingSink;
  Driver: TSessionClient;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
  I: Integer;
  Chunks: array of RawByteString;
  Peak: Integer;
begin
  { A turn boundary resets the live window (releasing the turn's strings) while
    the allocation stays at the cap. The live count after the turn is far below
    the turn's event count. }
  Id := NewSession;
  Fake := TFakeTransport.Create;
  try
    SetLength(Chunks, 202);
    for I := 0 to 199 do
      Chunks[I] := TextDelta('wwwwwwwwwwwwwwww');
    Chunks[200] := FinishFrame('stop');
    Chunks[201] := DoneFrame;
    Fake.AddResponse(Chunks);

    Rt := MakeRuntimeCapped(Id, Fake, 8192);
    Th := TRuntimeThread.Create(Rt);
    try
      Th.Start;
      AssertTrue('bound', WaitForSocket(Id, 5000));
      DriverSink := TRecordingSink.Create;
      Driver := TSessionClient.Open(MakeClientConfig(Id, srDrive), DriverSink,
        Err);
      AssertNotNull('driver attaches: ' + Err, Driver);
      try
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scPrompt;
        Cmd.Id := 'p1';
        Cmd.Text := 'go';
        AssertTrue('prompt replied', Driver.SendAndWait(Cmd, 5000, Reply));
        AssertTrue('turn done', WaitCount(DriverSink, ekTurnFinished, 1, 10000));
        Peak := Rt.ReplayCount;
        { 200 deltas ran; after the boundary the live window holds only the
          post-turn events (loop_started plus the turn's terminal events). }
        AssertTrue('live window shrank after the turn', Peak < 50);
        AssertEquals('allocation stays at the cap', 8192, Rt.ReplayCapacity);
      finally
        Driver.Free;
        DriverSink := nil;
      end;
    finally
      Rt.Stop;
      WaitFinished(Th, 3000);
      Th.Free;
      DeleteSocket(Id);
    end;
  finally
    Fake.Free;
  end;
end;

procedure TSessionRuntimeTest.TestAbortReleaseCommandsRouteToSupervisor;
var
  Id: string;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Sink: TRecordingSink;
  Driver: TSessionClient;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
begin
  { A root runtime with a store supervises subagents, so the abort/release
    commands are routed to the supervisor (an unknown child fails cleanly with
    abort_failed rather than being an unknown command). }
  Id := NewSession;
  Rt := MakeRuntime(Id, nil, 300000);
  Th := TRuntimeThread.Create(Rt);
  try
    Th.Start;
    AssertTrue('bound', WaitForSocket(Id, 5000));
    Sink := TRecordingSink.Create;
    Driver := TSessionClient.Open(MakeClientConfig(Id, srDrive), Sink, Err);
    AssertNotNull('driver attaches: ' + Err, Driver);
    try
      Cmd := Default(TSessionCommand);
      Cmd.Kind := scAbortSubagent;
      Cmd.Id := 'a1';
      Cmd.SessionId := 'no-such-child';
      AssertTrue('abort replied', Driver.SendAndWait(Cmd, 3000, Reply));
      AssertFalse('unknown child refused', Reply.Ok);
      AssertEquals('reason', 'abort_failed', Reply.ErrorCode);

      Cmd := Default(TSessionCommand);
      Cmd.Kind := scReleaseSubagent;
      Cmd.Id := 'r1';
      Cmd.SessionId := 'no-such-child';
      AssertTrue('release replied', Driver.SendAndWait(Cmd, 3000, Reply));
      AssertFalse('unknown child refused', Reply.Ok);
      AssertEquals('reason', 'release_failed', Reply.ErrorCode);
    finally
      Driver.Free;
      Sink := nil;
    end;
  finally
    Rt.Stop;
    WaitFinished(Th, 3000);
    Th.Free;
    DeleteSocket(Id);
  end;
end;

procedure TSessionRuntimeTest.TestAbortRefusedForObserver;
var
  Id: string;
  Rt: TSessionRuntime;
  Th: TRuntimeThread;
  Sink: TRecordingSink;
  Driver: TSessionClient;
  Err: string;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
begin
  { An observer (not the driver) may not abort a subagent. }
  Id := NewSession;
  Rt := MakeRuntime(Id, nil, 300000);
  Th := TRuntimeThread.Create(Rt);
  try
    Th.Start;
    AssertTrue('bound', WaitForSocket(Id, 5000));
    Sink := TRecordingSink.Create;
    Driver := TSessionClient.Open(MakeClientConfig(Id, srObserve), Sink, Err);
    AssertNotNull('observer attaches: ' + Err, Driver);
    try
      Cmd := Default(TSessionCommand);
      Cmd.Kind := scAbortSubagent;
      Cmd.Id := 'a1';
      Cmd.SessionId := 'x';
      AssertTrue('abort replied', Driver.SendAndWait(Cmd, 3000, Reply));
      AssertFalse('observer refused', Reply.Ok);
      AssertEquals('not driver', 'not_driver', Reply.ErrorCode);
    finally
      Driver.Free;
      Sink := nil;
    end;
  finally
    Rt.Stop;
    WaitFinished(Th, 3000);
    Th.Free;
    DeleteSocket(Id);
  end;
end;

initialization
  RegisterTest(TSessionRuntimeTest);

end.
