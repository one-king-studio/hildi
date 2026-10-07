unit test_subagent_spy;
{ fpcunit tests for the subagent spy: it attaches to a running child as an
  observer and maps the child's stream onto the chat panel's TTurnEvents. The
  child runs as an in-process runtime over a real socket with a fake transport;
  a separate driver client drives the turn the spy observes. }

{$mode delphi}{$H+}

interface

uses
  Classes, Contnrs, SysUtils, fpcunit, testregistry,
  hildegard.helper.workspace, hildegard.helper.store, hildegard.helper.session,
  hildegard.helper.session.protocol, hildegard.helper.session.client,
  hildegard.helper.session.socket, hildegard.helper.session.runtime,
  hildegard.helper.harness.turn, hildegard.helper.harness.subagent.spy,
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

  { A do-nothing sink for the driver client. }
  TNullSink = class(TInterfacedObject, ISessionSink)
    procedure OnHello(const AHello: TSessionHello);
    procedure OnAttached(const AAttached: TSessionAttached);
    procedure OnEvent(const AEvent: TSessionEvent);
    procedure OnDetached(const AReason: string);
    procedure OnError(const ACode, AMessage: string);
  end;

  TSubagentSpyTest = class(TTestCase)
  private
    FDir, FWs, FDbPath: string;
    FRuntimes: TObjectList;
    function StoreConfig: TStoreConfig;
    function NewSession: string;
    function MakeRuntime(const ASessionId: string;
      ATransport: TLLMTransport): TRuntimeThread;
    function ClientConfig(const ASessionId: string;
      ARole: TSessionRole): TSessionClientConfig;
    function WaitEvent(ASpy: TSubagentSpy; AKind: TTurnEventKind;
      ATimeoutMs: Integer): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSpyMapsChildStream;
    procedure TestSpyUnknownChildFails;
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

procedure TNullSink.OnHello(const AHello: TSessionHello);
begin
end;

procedure TNullSink.OnAttached(const AAttached: TSessionAttached);
begin
end;

procedure TNullSink.OnEvent(const AEvent: TSessionEvent);
begin
end;

procedure TNullSink.OnDetached(const AReason: string);
begin
end;

procedure TNullSink.OnError(const ACode, AMessage: string);
begin
end;

procedure TSubagentSpyTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhspy_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  FWs := IncludeTrailingPathDelimiter(FDir) + 'ws';
  ForceDirectories(FWs);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
  FRuntimes := TObjectList.Create(True);
end;

procedure TSubagentSpyTest.TearDown;
var
  I: Integer;
begin
  for I := 0 to FRuntimes.Count - 1 do
  begin
    TRuntimeThread(FRuntimes[I]).Runtime.Stop;
    TRuntimeThread(FRuntimes[I]).WaitFor;
    TRuntimeThread(FRuntimes[I]).Runtime.Free;
  end;
  FRuntimes.Free;
  DeleteFile(FDbPath);
  DeleteFile(FDbPath + '-wal');
  DeleteFile(FDbPath + '-shm');
  RemoveDir(FWs);
  RemoveDir(FDir);
end;

function TSubagentSpyTest.StoreConfig: TStoreConfig;
begin
  Result := Default(TStoreConfig);
  Result.DatabasePath := FDbPath;
  Result.BusyTimeoutMs := 5000;
end;

function TSubagentSpyTest.NewSession: string;
var
  S: TSqliteStore;
  Ws: TWorkspace;
  WsErr: string;
  Id: Integer;
  Err: TStoreError;
begin
  Ws := TWorkspace.Open(FWs, WsErr);
  if Ws = nil then
    raise Exception.Create('workspace: ' + WsErr);
  try
    S := TSqliteStore.Create(StoreConfig);
    try
      S.Open(Err);
      S.EnsureWorkspace(Ws.Root, Id, Err);
      S.CreateSession(Id, Result, Err);
    finally
      S.Free;
    end;
  finally
    Ws.Free;
  end;
end;

function TSubagentSpyTest.MakeRuntime(const ASessionId: string;
  ATransport: TLLMTransport): TRuntimeThread;
var
  Cfg: TSessionRuntimeConfig;
  Err: string;
  Rt: TSessionRuntime;
begin
  Cfg := Default(TSessionRuntimeConfig);
  Cfg.SessionId := ASessionId;
  Cfg.WorkspacePath := FWs;
  Cfg.StorePath := FDbPath;
  Cfg.IdleExitMs := 8000;
  Cfg.Transport := ATransport;
  Rt := TSessionRuntime.Open(Cfg, Err);
  if Rt = nil then
    raise Exception.Create('runtime: ' + Err);
  Result := TRuntimeThread.Create(Rt);
  FRuntimes.Add(Result);
  Result.Start;
  while not SessionSocketReady(ASessionId) do
    Sleep(5);
end;

function TSubagentSpyTest.ClientConfig(const ASessionId: string;
  ARole: TSessionRole): TSessionClientConfig;
begin
  Result := Default(TSessionClientConfig);
  Result.SessionId := ASessionId;
  Result.WorkspacePath := FWs;
  Result.StorePath := FDbPath;
  Result.Role := ARole;
  Result.Spawn := False;
  Result.SpawnTimeoutMs := 3000;
  Result.RuntimeCommand := ExpandFileName(ParamStr(0));
  Result.IdleExitMs := 8000;
end;

function TSubagentSpyTest.WaitEvent(ASpy: TSubagentSpy; AKind: TTurnEventKind;
  ATimeoutMs: Integer): Boolean;
var
  E: TTurnEvent;
  Deadline: Int64;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    while ASpy.PopEvent(E) do
      if E.Kind = AKind then
        Exit(True);
    Sleep(5);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

procedure TSubagentSpyTest.TestSpyMapsChildStream;
var
  Id: string;
  Th: TRuntimeThread;
  Fake: TFakeTransport;
  Spy: TSubagentSpy;
  Driver: TSessionClient;
  SinkRef: ISessionSink;
  Err: string;
  Cmd: TSessionCommand;
begin
  { A child runtime that answers a turn. A driver client drives the turn; a spy
    observes the same child and maps its stream. }
  Id := NewSession;
  Fake := TFakeTransport.Create;
  Fake.AddResponse([TextDelta('child says hi'), FinishFrame('stop'),
    DoneFrame]);
  try
    Th := MakeRuntime(Id, Fake);

    Spy := TSubagentSpy.Open(Id, ClientConfig(Id, srObserve), Err);
    AssertNotNull('spy attaches: ' + Err, Spy);
    try
      SinkRef := TNullSink.Create;
      Driver := TSessionClient.Open(ClientConfig(Id, srDrive), SinkRef, Err);
      AssertNotNull('driver attaches: ' + Err, Driver);
      try
        Cmd := Default(TSessionCommand);
        Cmd.Kind := scPrompt;
        Cmd.Id := 'p1';
        Cmd.Text := 'go';
        Driver.Send(Cmd);

        AssertTrue('spy saw the assistant delta',
          WaitEvent(Spy, teAssistantDelta, 5000));
        AssertTrue('spy saw the turn done', WaitEvent(Spy, teDone, 5000));
      finally
        Driver.Free;
        SinkRef := nil;
      end;
    finally
      Spy.Close;
      Spy.Free;
    end;
  finally
    Fake.Free;
  end;
end;

procedure TSubagentSpyTest.TestSpyUnknownChildFails;
var
  Spy: TSubagentSpy;
  Err: string;
begin
  { An unknown/unreachable child fails cleanly; the spy is nil with a message. }
  Spy := TSubagentSpy.Open('no-such-child', ClientConfig('no-such-child',
    srObserve), Err);
  AssertNull('unknown child fails', Spy);
  AssertTrue('with a message', Err <> '');
end;

initialization
  RegisterTest(TSubagentSpyTest);
end.
