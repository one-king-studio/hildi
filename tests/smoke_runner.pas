unit smoke_runner;
{ The live smoke: spawn the REAL headless runtime against a loopback fake
  provider, attach a real socket client, drive a turn, and assert on the wire and
  on the disk.

  Why the runner spawns the runtime itself rather than using
  TSessionClient.Open(Spawn := True): SpawnDetached passes --session-runtime,
  --workspace, --store, --approval-root and --idle-ms, but NOT --endpoint and NOT
  --model, and ResolveLLMConfig reads the model and key from the environment but
  never reads an endpoint variable (although the CLI's help text advertises
  HILDEGARD_LLM_ENDPOINT). So a spawned runtime cannot be aimed at a local
  provider by any supported route today. Spawning explicitly is also the stronger
  test: it pins the argv the product documents. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Process, SyncObjs, fpjson,
  hildegard.helper.llm, hildegard.helper.session.protocol,
  hildegard.helper.session.client,
  hildegard.helper.session.socket, hildegard.helper.approval,
  hildegard.helper.store, hildegard.helper.session.store,
  hildegard.helper.workspace,
  smoke_provider;

type
  { Records sink callbacks. OnEvent arrives on the client's reader thread. }
  TSmokeSink = class(TInterfacedObject, ISessionSink)
  private
    FLock: TCriticalSection;
    FEvents: array of TSessionEvent;
    FHelloSeen: Boolean;
    FAttachedSeen: Boolean;
    FDetachedReason: string;
    FError: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnHello(const AHello: TSessionHello);
    procedure OnAttached(const AAttached: TSessionAttached);
    procedure OnEvent(const AEvent: TSessionEvent);
    procedure OnDetached(const AReason: string);
    procedure OnError(const ACode, AMessage: string);
    function Count: Integer;
    function EventAt(AIndex: Integer): TSessionEvent;
    function CountKind(AKind: TSessionEventKind): Integer;
    function FirstKind(AKind: TSessionEventKind): TSessionEvent;
    function LastKind(AKind: TSessionEventKind): TSessionEvent;
    property HelloSeen: Boolean read FHelloSeen;
    property AttachedSeen: Boolean read FAttachedSeen;
    property DetachedReason: string read FDetachedReason;
    property Error: string read FError;
  end;

  TSmokeOutcome = record
    Ok: Boolean;
    Stage: string;
    Detail: string;
  end;

  TSmokeHost = class;

  TSmokeScenario = function(const AHost: TSmokeHost): TSmokeOutcome;

  TSmokeHost = class
  private
    FSink: TSmokeSink;
    FClient: TSessionClient;
    FProc: TProcess;
    FLogPath: string;
    function SpawnRuntime(const AEndpoint, AWorkspace, AStore, ASessionId,
      AModel: string; out AError: string): Boolean;
  public
    Provider: TFakeProvider;
    Root: string;          // the temp root; Workspace and StorePath live inside
    Workspace: string;
    StorePath: string;
    SessionId: string;
    RuntimeBinary: string;
    constructor Create;
    destructor Destroy; override;
    { Make the temp tree, start the provider, spawn the runtime, attach. }
    function Start(out AError: string): Boolean;
    function Attach(AFromSeq: Int64; out AError: string): Boolean;
    procedure Detach;
    function Sink: TSmokeSink;
    function Client: TSessionClient;
    { Send a prompt as the driver. }
    function Prompt(const AText, AId: string; out AError: string): Boolean;
    { Poll until APred holds or the deadline passes. }
    function WaitFor(AKind: TSessionEventKind; ACount, ATimeoutMs: Integer;
      const AWhat: string; out ADetail: string): Boolean;
    function RuntimeLog: string;
    procedure Stop;
  end;

function ScenarioNames: TStringArray;
function RunScenario(const AName: string): TSmokeOutcome;

{ The scenario set, exported so `--list` and the runner agree. }
function ScenarioText(const AHost: TSmokeHost): TSmokeOutcome;
function ScenarioTool(const AHost: TSmokeHost): TSmokeOutcome;
function ScenarioDenied(const AHost: TSmokeHost): TSmokeOutcome;
function ScenarioIntrospect(const AHost: TSmokeHost): TSmokeOutcome;

implementation

uses
  DateUtils;

const
  DefaultSpawnWaitMs = 8000;
  DefaultTurnWaitMs = 15000;
  DummyModel = 'smoke-model';
  DummyKey = 'smoke-key';

{ --- TSmokeSink --------------------------------------------------------- }

constructor TSmokeSink.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TSmokeSink.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TSmokeSink.OnHello(const AHello: TSessionHello);
begin
  FLock.Enter;
  try
    FHelloSeen := True;
  finally
    FLock.Leave;
  end;
end;

procedure TSmokeSink.OnAttached(const AAttached: TSessionAttached);
begin
  FLock.Enter;
  try
    FAttachedSeen := True;
  finally
    FLock.Leave;
  end;
end;

procedure TSmokeSink.OnEvent(const AEvent: TSessionEvent);
begin
  FLock.Enter;
  try
    SetLength(FEvents, Length(FEvents) + 1);
    FEvents[High(FEvents)] := AEvent;
  finally
    FLock.Leave;
  end;
end;

procedure TSmokeSink.OnDetached(const AReason: string);
begin
  FLock.Enter;
  try
    FDetachedReason := AReason;
  finally
    FLock.Leave;
  end;
end;

procedure TSmokeSink.OnError(const ACode, AMessage: string);
begin
  FLock.Enter;
  try
    if FError = '' then
      FError := ACode + ': ' + AMessage;
  finally
    FLock.Leave;
  end;
end;

function TSmokeSink.Count: Integer;
begin
  FLock.Enter;
  try
    Result := Length(FEvents);
  finally
    FLock.Leave;
  end;
end;

function TSmokeSink.EventAt(AIndex: Integer): TSessionEvent;
begin
  FLock.Enter;
  try
    if (AIndex >= 0) and (AIndex < Length(FEvents)) then
      Result := FEvents[AIndex]
    else
      Result := Default(TSessionEvent);
  finally
    FLock.Leave;
  end;
end;

function TSmokeSink.CountKind(AKind: TSessionEventKind): Integer;
var
  I: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for I := 0 to High(FEvents) do
      if FEvents[I].Kind = AKind then
        Inc(Result);
  finally
    FLock.Leave;
  end;
end;

function TSmokeSink.FirstKind(AKind: TSessionEventKind): TSessionEvent;
var
  I: Integer;
begin
  Result := Default(TSessionEvent);
  FLock.Enter;
  try
    for I := 0 to High(FEvents) do
      if FEvents[I].Kind = AKind then
      begin
        Result := FEvents[I];
        Break;
      end;
  finally
    FLock.Leave;
  end;
end;

function TSmokeSink.LastKind(AKind: TSessionEventKind): TSessionEvent;
var
  I: Integer;
begin
  Result := Default(TSessionEvent);
  FLock.Enter;
  try
    for I := High(FEvents) downto 0 do
      if FEvents[I].Kind = AKind then
      begin
        Result := FEvents[I];
        Break;
      end;
  finally
    FLock.Leave;
  end;
end;

{ --- helpers ------------------------------------------------------------ }

function Outcome(const AStage, ADetail: string): TSmokeOutcome;
begin
  Result.Ok := False;
  Result.Stage := AStage;
  Result.Detail := ADetail;
end;

function Pass: TSmokeOutcome;
begin
  Result.Ok := True;
  Result.Stage := '';
  Result.Detail := '';
end;

function Fail(const AStage, ADetail: string): TSmokeOutcome;
begin
  Result := Outcome(AStage, ADetail);
end;

{ --- TSmokeHost --------------------------------------------------------- }

constructor TSmokeHost.Create;
begin
  inherited Create;
  Provider := TFakeProvider.Create;
  Root := '';
  Workspace := '';
  StorePath := '';
  SessionId := '';
  RuntimeBinary := '';
  FLogPath := '';
  FProc := nil;
  FSink := nil;
  FClient := nil;
end;

destructor TSmokeHost.Destroy;
begin
  Stop;
  FClient := nil;
  FSink := nil;
  Provider.Free;
  inherited Destroy;
end;

function MakeTempRoot: string;
var
  Base: string;
  N: Integer;
begin
  Base := IncludeTrailingPathDelimiter(GetTempDir) + 'hildegard-smoke-' +
    IntToStr(GetProcessID) + '-';
  N := 0;
  repeat
    Result := Base + IntToStr(N);
    Inc(N);
  until (not DirectoryExists(Result)) or (N > 1000);
  ForceDirectories(Result);
end;

function TSmokeHost.SpawnRuntime(const AEndpoint, AWorkspace, AStore,
  ASessionId, AModel: string; out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  FProc := TProcess.Create(nil);
  FProc.Executable := RuntimeBinary;
  FProc.Parameters.Add('--session-runtime');
  FProc.Parameters.Add(ASessionId);
  FProc.Parameters.Add('--workspace');
  FProc.Parameters.Add(AWorkspace);
  FProc.Parameters.Add('--store');
  FProc.Parameters.Add(AStore);
  FProc.Parameters.Add('--endpoint');
  FProc.Parameters.Add(AEndpoint);
  FProc.Parameters.Add('--model');
  FProc.Parameters.Add(AModel);
  FProc.Parameters.Add('--idle-ms');
  FProc.Parameters.Add('30000');
  { No pipes: the runtime's own diagnostics inherit the smoke's stdout/stderr, so
    a spawn failure explains itself in the same output. A pipe here would also
    risk filling and blocking the child, since nothing drains it. }
  FProc.Options := [];
  try
    FProc.Execute;
    Result := True;
  except
    on E: Exception do
      AError := 'could not spawn the runtime: ' + E.Message;
  end;
end;

function CreateSessionRow(const AStore, AWorkspace: string;
  out ASessionId, AError: string): Boolean;
{ The runtime refuses a session id it cannot find in the store ('unknown
  session'), because in production a client always creates the row before it
  spawns. The smoke therefore does the same, explicitly: open the store, register
  the workspace, create the session, close. }
var
  Store: TSqliteStore;
  Cfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
begin
  Result := False;
  AError := '';
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := AStore;
  Cfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(Cfg);
  try
    if not Store.Open(StoreErr) then
    begin
      AError := 'could not open the smoke store: ' + StoreErr.Message;
      Exit;
    end;
    if not Store.EnsureWorkspace(AWorkspace, WorkspaceId, StoreErr) then
    begin
      AError := 'could not register the workspace: ' + StoreErr.Message;
      Exit;
    end;
    if not Store.CreateSession(WorkspaceId, ASessionId, StoreErr) then
    begin
      AError := 'could not create the session: ' + StoreErr.Message;
      Exit;
    end;
    Result := True;
  finally
    Store.Close;
    Store.Free;
  end;
end;

function TSmokeHost.Start(out AError: string): Boolean;
var
  Deadline: Int64;
  Started: Boolean;
begin
  Result := False;
  AError := '';
  Root := MakeTempRoot;
  Workspace := IncludeTrailingPathDelimiter(Root) + 'ws';
  StorePath := IncludeTrailingPathDelimiter(Root) + 'smoke.db';
  ForceDirectories(Workspace);
  FLogPath := IncludeTrailingPathDelimiter(Root) + 'runtime.log';

  { The session row first: the runtime rejects an id it cannot find. }
  if not CreateSessionRow(StorePath, Workspace, SessionId, AError) then
    Exit(False);

  if not Provider.Start(AError) then
    Exit(False);

  { The client requires a model and a key even for a local endpoint. }
  if not SpawnRuntime(Provider.EndpointUrl, Workspace, StorePath, SessionId,
    DummyModel, AError) then
    Exit(False);

  { Wait for the socket, with a deadline. }
  Deadline := GetTickCount64 + DefaultSpawnWaitMs;
  repeat
    Started := SessionSocketReady(SessionId);
    if not Started then
      Sleep(25);
  until Started or (GetTickCount64 > Deadline);
  if not Started then
  begin
    AError := 'the runtime did not bind a socket within ' +
      IntToStr(DefaultSpawnWaitMs) + ' ms; log: ' + RuntimeLog;
    Exit(False);
  end;

  Result := Attach(0, AError);
end;

function TSmokeHost.Attach(AFromSeq: Int64; out AError: string): Boolean;
var
  Cfg: TSessionClientConfig;
begin
  AError := '';
  FSink := TSmokeSink.Create;
  Cfg := Default(TSessionClientConfig);
  Cfg.SessionId := SessionId;
  Cfg.WorkspacePath := Workspace;
  Cfg.StorePath := StorePath;
  Cfg.Role := srDrive;
  Cfg.FromSeq := AFromSeq;
  Cfg.Spawn := False;                 // we spawned it ourselves
  Cfg.SpawnTimeoutMs := DefaultSpawnWaitMs;
  { Passing the class (which implements ISessionSink) lets the compiler take the
    interface reference; an explicit `as` cast would need a GUID on the
    interface, which this one does not declare. }
  FClient := TSessionClient.Open(Cfg, FSink, AError);
  Result := FClient <> nil;
  if not Result then
    AError := 'attach failed: ' + AError;
end;

procedure TSmokeHost.Detach;
begin
  if FClient <> nil then
  begin
    FClient.Close;
    FreeAndNil(FClient);
  end;
  FSink := nil;
end;

function TSmokeHost.Sink: TSmokeSink;
begin
  Result := FSink;
end;

function TSmokeHost.Client: TSessionClient;
begin
  Result := FClient;
end;

function TSmokeHost.Prompt(const AText, AId: string;
  out AError: string): Boolean;
var
  Cmd: TSessionCommand;
begin
  Result := False;
  AError := '';
  if FClient = nil then
  begin
    AError := 'no client';
    Exit;
  end;
  Cmd := Default(TSessionCommand);
  Cmd.Kind := scPrompt;
  Cmd.Id := AId;
  Cmd.Text := AText;
  if not FClient.Send(Cmd) then
  begin
    AError := 'send failed';
    Exit;
  end;
  Result := True;
end;

function TSmokeHost.WaitFor(AKind: TSessionEventKind; ACount, ATimeoutMs: Integer;
  const AWhat: string; out ADetail: string): Boolean;
var
  Deadline: Int64;
  Seen: Integer;
  I: Integer;
  Tail: string;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    Seen := FSink.CountKind(AKind);
    if Seen >= ACount then
    begin
      ADetail := '';
      Exit(True);
    end;
    Sleep(20);
  until GetTickCount64 > Deadline;

  { Name the stages that did arrive, so a failure is diagnosable rather than an
    assertion number. }
  Tail := '';
  for I := 0 to FSink.Count - 1 do
    Tail := Tail + SessionEventKindToWire(FSink.EventAt(I).Kind) + ' ';
  ADetail := 'no ' + AWhat + ' within ' + IntToStr(ATimeoutMs) +
    ' ms; events seen: [' + Trim(Tail) + ']';
  Result := False;
end;

function TSmokeHost.RuntimeLog: string;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(FLogPath) then
    Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(FLogPath);
    Result := Trim(L.Text);
  finally
    L.Free;
  end;
end;

procedure TSmokeHost.Stop;
var
  SR: TSearchRec;
  D: string;
begin
  Detach;
  if FProc <> nil then
  begin
    try
      if FProc.Running then
      begin
        FProc.Terminate(15);
        { Give it a moment to unlink its own socket, then insist. }
        if not FProc.WaitOnExit(2000) then
          FProc.Terminate(9);
      end;
    except
      { A process that already exited races here; nothing to do. }
    end;
    FreeAndNil(FProc);
  end;
  if SessionId <> '' then
  begin
    D := SocketPathFor(SessionId);
    if FileExists(D) then
      DeleteFile(D);
  end;
  if (Root <> '') and DirectoryExists(Root) then
  begin
    { Drain the temp tree. Two levels: the workspace is one deep. }
    if FindFirst(IncludeTrailingPathDelimiter(Workspace) + '*', faAnyFile, SR) = 0
    then
    begin
      try
        repeat
          if (SR.Name <> '.') and (SR.Name <> '..') then
            DeleteFile(IncludeTrailingPathDelimiter(Workspace) + SR.Name);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
    if FindFirst(IncludeTrailingPathDelimiter(Root) + '*', faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if (SR.Name <> '.') and (SR.Name <> '..') then
          begin
            D := IncludeTrailingPathDelimiter(Root) + SR.Name;
            if DirectoryExists(D) then
              RemoveDir(D)
            else
              DeleteFile(D);
          end;
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
    RemoveDir(Root);
  end;
  Root := '';
end;

{ --- scenarios ---------------------------------------------------------- }

function ToolThenTextScripts(const AHost: TSmokeHost;
  const AToolName, AToolArgs, AFinalText: string): Boolean;
begin
  { First request: the model asks for a tool. Second: it answers. }
  AHost.Provider.Script(MakeScript([
    ToolNameFrame(0, 'call_1', AToolName),
    ToolArgsFrame(0, AToolArgs),
    FinishFrame('tool_calls'),
    DoneFrame]));
  AHost.Provider.Script(MakeScript([
    TextDelta(AFinalText),
    FinishFrame('stop'),
    DoneFrame]));
  Result := True;
end;

function AnswerAsk(const AHost: TSmokeHost; AAllow: Boolean;
  out AError: string): Boolean;
var
  Ask: TSessionEvent;
  Cmd: TSessionCommand;
  Reply: TSessionMessage;
begin
  Result := False;
  AError := '';
  Ask := AHost.Sink.LastKind(ekApprovalRequest);
  if Ask.AskId = '' then
  begin
    AError := 'no approval ask to answer';
    Exit;
  end;
  Cmd := Default(TSessionCommand);
  Cmd.Kind := scApprove;
  Cmd.Id := 'a-' + Ask.AskId;
  Cmd.AskId := Ask.AskId;
  Cmd.Choice := Default(TApprovalChoice);
  Cmd.Choice.Allowed := AAllow;
  { An ALLOW must name one of the ask's own options — the service rejects a key
    it did not offer, which is the right behaviour: a client cannot invent a
    grant. Pick the first, exactly as the modal does when the operator presses
    Enter on the highlighted option. }
  if AAllow then
  begin
    if Length(Ask.Ask.Options) = 0 then
    begin
      AError := 'the ask offered no options to choose';
      Exit;
    end;
    Cmd.Choice.OptionKey := Ask.Ask.Options[0].Key;
    Cmd.Choice.Scope := Ask.Ask.Options[0].Rule.Scope;
  end;
  if not AHost.Client.SendAndWait(Cmd, 5000, Reply) then
  begin
    AError := 'the approve command was not replied to';
    Exit;
  end;
  if not Reply.Ok then
  begin
    AError := 'the runtime refused the approve: ' + Reply.ErrorCode;
    Exit;
  end;
  Result := True;
end;

function ScenarioText(const AHost: TSmokeHost): TSmokeOutcome;
var
  Err, Detail: string;
  Deltas: Integer;
begin
  AHost.Provider.Script(MakeScript([TextDelta('hello '),
    TextDelta('from the smoke'), FinishFrame('stop'), DoneFrame]));
  if not AHost.Prompt('say hello', 'p-text', Err) then
    Exit(Fail('prompt', Err));
  if not AHost.WaitFor(ekTurnFinished, 1, DefaultTurnWaitMs, 'a finished turn',
    Detail) then
    Exit(Fail('turn', Detail));
  Deltas := AHost.Sink.CountKind(ekAssistantDelta) +
    AHost.Sink.CountKind(ekAssistantBlock);
  if Deltas = 0 then
    Exit(Fail('stream', 'the turn finished with no assistant text'));
  { Negative: a text turn must not have raised a tool call. }
  if AHost.Sink.CountKind(ekToolCall) <> 0 then
    Exit(Fail('stream', 'a text-only turn produced a tool call'));
  if AHost.Sink.CountKind(ekError) <> 0 then
    Exit(Fail('stream', 'the turn reported an error: ' +
      AHost.Sink.FirstKind(ekError).Text));
  Result := Pass;
end;

function ScenarioTool(const AHost: TSmokeHost): TSmokeOutcome;
var
  Err, Detail, Path, Content: string;
  Ask: TSessionEvent;
  Res: TSessionEvent;
  L: TStringList;
begin
  Path := IncludeTrailingPathDelimiter(AHost.Workspace) + 'smoke.txt';
  Content := 'written by the live smoke';
  ToolThenTextScripts(AHost, 'file_write',
    '{"path":"smoke.txt","content":"' + Content + '","reason":"smoke"}',
    'the file was written');
  if not AHost.Prompt('write the file', 'p-tool', Err) then
    Exit(Fail('prompt', Err));
  if not AHost.WaitFor(ekToolCall, 1, DefaultTurnWaitMs, 'a tool call', Detail)
  then
    Exit(Fail('tool', Detail));
  if not AHost.WaitFor(ekApprovalRequest, 1, DefaultTurnWaitMs,
    'an approval ask', Detail) then
    Exit(Fail('gate', Detail));
  { The ask must carry the model's reason: that is the accountability claim. }
  Ask := AHost.Sink.LastKind(ekApprovalRequest);
  if Ask.Ask.Reason = '' then
    Exit(Fail('gate', 'the approval ask carried no reason'));
  if not AnswerAsk(AHost, True, Err) then
    Exit(Fail('gate', Err));
  if not AHost.WaitFor(ekToolResult, 1, DefaultTurnWaitMs, 'a tool result',
    Detail) then
    Exit(Fail('tool', Detail));
  Res := AHost.Sink.LastKind(ekToolResult);
  if not Res.ToolOk then
    Exit(Fail('tool', 'the tool failed: ' + Res.Text));
  if not AHost.WaitFor(ekTurnFinished, 1, DefaultTurnWaitMs, 'a finished turn',
    Detail) then
    Exit(Fail('turn', Detail));
  { The effect must be real, on disk, as the tool reported. }
  if not FileExists(Path) then
    Exit(Fail('disk', 'the tool reported success but ' + Path + ' does not exist'));
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    if Pos(Content, L.Text) = 0 then
      Exit(Fail('disk', 'the file content did not match: [' + L.Text + ']'));
  finally
    L.Free;
  end;
  Result := Pass;
end;

function ScenarioDenied(const AHost: TSmokeHost): TSmokeOutcome;
var
  Err, Detail: string;
  Res: TSessionEvent;
begin
  ToolThenTextScripts(AHost, 'file_write',
    '{"path":"denied.txt","content":"never","reason":"smoke"}',
    'the write was refused');
  if not AHost.Prompt('try to write', 'p-denied', Err) then
    Exit(Fail('prompt', Err));
  if not AHost.WaitFor(ekApprovalRequest, 1, DefaultTurnWaitMs,
    'an approval ask', Detail) then
    Exit(Fail('gate', Detail));
  if not AnswerAsk(AHost, False, Err) then
    Exit(Fail('gate', Err));
  if not AHost.WaitFor(ekToolResult, 1, DefaultTurnWaitMs, 'a tool result',
    Detail) then
    Exit(Fail('denial', Detail));
  Res := AHost.Sink.LastKind(ekToolResult);
  if Res.ToolOk then
    Exit(Fail('denial', 'a denied call reported success'));
  { The point: a denial is recoverable, so the turn reaches a terminal state
    rather than hanging. }
  if not AHost.WaitFor(ekTurnFinished, 1, DefaultTurnWaitMs, 'a finished turn',
    Detail) then
    Exit(Fail('denial', 'the turn did not finish after a denial: ' + Detail));
  if FileExists(IncludeTrailingPathDelimiter(AHost.Workspace) + 'denied.txt')
  then
    Exit(Fail('denial', 'the denied write happened anyway'));
  Result := Pass;
end;

function ScenarioIntrospect(const AHost: TSmokeHost): TSmokeOutcome;
var
  Err, Detail, Body: string;
  Root: TJSONObject;
  Tools: TJSONArray;
  I: Integer;
  Item, Fn, Params, Props, Reason: TJSONObject;
begin
  AHost.Provider.Script(MakeScript([TextDelta('ok'), FinishFrame('stop'),
    DoneFrame]));
  if not AHost.Prompt('hi', 'p-introspect', Err) then
    Exit(Fail('prompt', Err));
  if not AHost.WaitFor(ekTurnFinished, 1, DefaultTurnWaitMs, 'a finished turn',
    Detail) then
    Exit(Fail('turn', Detail));
  if AHost.Provider.RequestCount = 0 then
    Exit(Fail('request', 'the provider saw no request'));
  Body := AHost.Provider.RequestBodyAt(0);
  Root := TJSONObject(GetJSON(Body));
  if Root = nil then
    Exit(Fail('request', 'the request body was not JSON'));
  try
    Tools := TJSONArray(Root.Find('tools'));
    if (Tools = nil) or (Tools.Count = 0) then
      Exit(Fail('request', 'the request advertised no tools'));
    for I := 0 to Tools.Count - 1 do
    begin
      Item := TJSONObject(Tools.Items[I]);
      Fn := TJSONObject(Item.Find('function'));
      if Fn = nil then
        Exit(Fail('request', 'a tool entry has no function object'));
      Params := TJSONObject(Fn.Find('parameters'));
      if Params = nil then
        Continue;                     // a tool without arguments is fine
      Props := TJSONObject(Params.Find('properties'));
      if Props = nil then
        Continue;
      Reason := TJSONObject(Props.Find('reason'));
      if Reason = nil then
        Exit(Fail('request', 'tool ' + Fn.Get('name', '?') +
          ' does not advertise a reason property'));
    end;
  finally
    Root.Free;
  end;
  Result := Pass;
end;

function ScenarioResume(const AHost: TSmokeHost): TSmokeOutcome;
var
  Err, Detail, Path: string;
  Msgs: TChatMessageArray;
  I, UserCount, ToolCount, AssistantCount: Integer;
  SawUser, SawTool, SawResult: Boolean;
  Before: Integer;
  Store: TSqliteStore;
  Conv: TSqliteConversationStore;
  Cfg: TStoreConfig;
  StoreErr: TStoreError;
begin
  { A full tool turn first: that is what a resumed session has to render. }
  Path := IncludeTrailingPathDelimiter(AHost.Workspace) + 'resume.txt';
  ToolThenTextScripts(AHost, 'file_write',
    '{"path":"resume.txt","content":"persisted","reason":"smoke"}',
    'all done');
  if not AHost.Prompt('write a file for the resume check', 'p-resume1', Err) then
    Exit(Fail('prompt', Err));
  if not AHost.WaitFor(ekApprovalRequest, 1, DefaultTurnWaitMs,
    'an approval ask', Detail) then
    Exit(Fail('gate', Detail));
  if not AnswerAsk(AHost, True, Err) then
    Exit(Fail('gate', Err));
  if not AHost.WaitFor(ekTurnFinished, 1, DefaultTurnWaitMs, 'a finished turn',
    Detail) then
    Exit(Fail('turn', Detail));
  if not FileExists(Path) then
    Exit(Fail('disk', 'the tool turn wrote no file to resume from'));

  { Detach: nothing in memory survives, so what follows comes only from the
    ledger. }
  Before := AHost.Sink.CountKind(ekTurnFinished);
  AHost.Detach;

  { Read the ledger directly first, so a mismatch names the store, not the wire. }
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := AHost.StorePath;
  Cfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(Cfg);
  try
    if not Store.Open(StoreErr) then
      Exit(Fail('store', 'could not reopen the smoke store: ' +
        StoreErr.Message));
    Conv := TSqliteConversationStore.Create(Store, AHost.SessionId, 0);
    try
      Msgs := Conv.Messages;
    finally
      Conv.Free;
    end;
  finally
    Store.Close;
    Store.Free;
  end;

  UserCount := 0;
  ToolCount := 0;
  AssistantCount := 0;
  SawUser := False;
  SawTool := False;
  SawResult := False;
  for I := 0 to High(Msgs) do
  begin
    if Msgs[I].Role = crUser then
    begin
      Inc(UserCount);
      if Pos('write a file for the resume check', Msgs[I].Content) > 0 then
        SawUser := True;
    end
    else if Msgs[I].Role = crAssistant then
    begin
      Inc(AssistantCount);
      if Length(Msgs[I].ToolCalls) > 0 then
        if Msgs[I].ToolCalls[0].Name = 'file_write' then
          SawTool := True;
    end
    else if Msgs[I].Role = crTool then
    begin
      Inc(ToolCount);
      if Msgs[I].ToolOk and (Pos('wrote', Msgs[I].Content) > 0) then
        SawResult := True;
    end;
  end;

  if not SawUser then
    Exit(Fail('store', 'the user message was not persisted'));
  if not SawTool then
    Exit(Fail('store', 'the tool call was not persisted with its name'));
  if not SawResult then
    Exit(Fail('store', 'the tool result was not persisted as a success'));
  { Negative: the turn must have been committed exactly once, not re-written on
    resume. }
  if UserCount <> 1 then
    Exit(Fail('store', 'expected 1 user message, found ' + IntToStr(UserCount)));
  if AssistantCount < 1 then
    Exit(Fail('store', 'no assistant message was persisted'));

  { Re-attach and prove a fresh client can join the same session. The *history*
    assertion above is the ledger proof; this proves the session is still
    attachable after the turn, which is what "resumed" means to the operator. }
  if not AHost.Attach(0, Err) then
    Exit(Fail('resume', 're-attach failed: ' + Err));
  if not AHost.Sink.AttachedSeen then
    Exit(Fail('resume', 'the re-attached client never received an attach reply'));
  if Before < 1 then
    Exit(Fail('turn', 'the first turn never reported a finish'));
  Result := Pass;
end;

{ --- the registry ------------------------------------------------------- }

function ScenarioNames: TStringArray;
begin
  Result := ['text', 'tool', 'denied', 'resume', 'introspect'];
end;

function RunScenario(const AName: string): TSmokeOutcome;
var
  Host: TSmokeHost;
  Err: string;
begin
  if AName = '' then
    Exit(Fail('scenario', 'no scenario named'));
  if (AName <> 'text') and (AName <> 'tool') and (AName <> 'denied') and
    (AName <> 'resume') and (AName <> 'introspect') then
    Exit(Fail('scenario', 'unknown scenario: ' + AName));
  Host := TSmokeHost.Create;
  try
    { The runtime binary: an explicit override first, then the environment, then
      a sibling of this executable (the TUI's own discovery rule). }
    Host.RuntimeBinary := ResolveRuntimeBinary(
      GetEnvironmentVariable('HILDEGARD_RUNTIME_BIN'), ParamStr(0));
    if Host.RuntimeBinary = '' then
      Exit(Fail('spawn', 'no runtime binary; run make headless-agent or set '
        + 'HILDEGARD_RUNTIME_BIN'));
    if not Host.Start(Err) then
      Exit(Fail('spawn', Err));
    if AName = 'text' then
      Result := ScenarioText(Host)
    else if AName = 'tool' then
      Result := ScenarioTool(Host)
    else if AName = 'denied' then
      Result := ScenarioDenied(Host)
    else if AName = 'resume' then
      Result := ScenarioResume(Host)
    else
      Result := ScenarioIntrospect(Host);
  finally
    Host.Stop;
    Host.Free;
  end;
end;

end.
