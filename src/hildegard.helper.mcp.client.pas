unit hildegard.helper.mcp.client;
{ MCP client (stdio, v1): connects to one MCP server, performs the initialize
  handshake, lists its tools once, maps them into the existing TToolRegistry as
  ordinary specs, and dispatches tools/call through the existing approval engine.
  The loop needs no change: the handler asks approval and returns the loop's
  text result, exactly like a native tool.
  See docs/features/MCP_Client/Mcp_Client_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  hildegard.helper.agent, hildegard.helper.llm, hildegard.helper.approval,
  hildegard.helper.stdio.child, hildegard.helper.jsonrpc,
  hildegard.helper.mcp.transport, hildegard.helper.mcp.http,
  hildegard.helper.mcp.config;

type
  { One discovered MCP tool, after mapping. Ref is the persisted-approval
    identity; Name is the provider-safe, model-visible name. }
  TMcpTool = record
    ServerName: string;
    ToolName: string;          // the server's original tool name
    Ref: string;               // 'mcp/<server>/<tool>'
    Name: string;              // provider-safe name (see McpToolName)
    Description: string;
    ParametersJson: string;    // mapped inputSchema (server 'reason' stripped)
  end;

  TMcpToolArray = array of TMcpTool;

  { A session event sink (message + detail); fired on the loop's thread. }
  TMcpEvent = procedure(const AMessage, ADetail: string) of object;

  TMcpClientConfig = record
    Server: TMcpServerConfig;      // from mcp.config
    ListTimeoutMs: Integer;        // 0 => DefaultMcpListTimeoutMs
    CallTimeoutMs: Integer;        // 0 => DefaultMcpCallTimeoutMs
    ClientName: string;            // '' => McpClientName
    ClientVersion: string;         // '' => '0.1'
    { When set and the server is HTTP, each request obtains a bearer token from
      this source (OAuth). Nil for static-header / no auth. }
    TokenSource: TMcpTokenSource;
  end;

  TMcpClient = class;

  { One registered tool's handler; closes over its tool and client. }
  TMcpToolHandler = class
  private
    FClient: TMcpClient;
    FTool: TMcpTool;
  public
    constructor Create(AClient: TMcpClient; const ATool: TMcpTool);
    function Handle(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;

  TMcpClient = class
  private
    FConfig: TMcpClientConfig;
    FApproval: IApprovalService;
    FOnEvent: TMcpEvent;
    FTransport: IMcpTransport;
    FIdGen: TJsonRpcIdGen;
    FTools: TMcpToolArray;
    FSpecs: TToolSpecArray;
    FHandlers: array of TMcpToolHandler;
    FRegisteredRefs: TStringList;
    FDead: Boolean;
    procedure Emit(const AMessage, ADetail: string);
    function GetServerName: string;
    function WaitResponse(AId: TJsonRpcId; ATimeoutMs: Integer;
      out AResultJson: string; out AError: string): Boolean;
    function Call(const AMethod, AParamsJson: string; ATimeoutMs: Integer;
      out AResultJson: string; out AError: string): Boolean;
    function ProtocolOk(const AInitializeResultJson: string;
      out AError: string): Boolean;
    function Discover(out AError: string): Boolean;
    function RegisterTools(out AError: string): Boolean;
  public
    constructor Create(const AConfig: TMcpClientConfig;
      AApproval: IApprovalService; AOnEvent: TMcpEvent);
    destructor Destroy; override;

    { Spawn, handshake, list, and build this client's specs. False + AError (and
      no specs) when the server is unusable. }
    function Open(out AError: string): Boolean;

    { Re-run tools/list and add newly-appearing tools (existing refs are left in
      place). }
    function Refresh(out AError: string): Boolean;

    { The tools/call path for one tool: approval ask, strip reason, call, map. }
    function CallTool(const ATool: TMcpTool; const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;

    { Close the child. Idempotent. }
    procedure Close;

    { The specs this client offers (namespaced names, reason-augmented). Built on
      Open/Refresh; empty when not connected. }
    function Specs: TToolSpecArray;
    { Resolve a tool name to its handler; False when this client does not own it. }
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;

    property ServerName: string read GetServerName;
    property Tools: TMcpToolArray read FTools;
    { True once a write/read failure marked the server unavailable; the manager
      treats a dead server as due for reconnect. }
    property Dead: Boolean read FDead;
  end;

  { A server's lifecycle state. }
  TMcpServerState = (mssStopped, mssConnected, mssDead);

  { Per-server runtime the manager owns. }
  TMcpServerRuntime = record
    Name: string;
    Config: TMcpServerConfig;
    Client: TMcpClient;
    State: TMcpServerState;
    NextAttemptAt: Int64;      // ms epoch; 0 = now
    BackoffMs: Integer;
    Attempts: Integer;
    RegisteredNames: array of string;   // exact tool names this server added
  end;

  TMcpServerRuntimeArray = array of TMcpServerRuntime;

  { Supplies the current effective MCP config (e.g. from the store). }
  TMcpConfigSource = function: TMcpConfig of object;

  { Supplies a token source for one server (or nil), e.g. from stored OAuth
    tokens. Set on the manager by the session. }
  TMcpTokenSourceFactory = function(const AServer: TMcpServerConfig):
    TMcpTokenSource of object;

  { Spawns every configured server, and reconciles the live set from config at a
    boundary. Tear-down closes them all. The manager owns the tool specs; it is
    exposed to the loop through TMcpProvider. }
  TMcpManager = class
  private
    FApproval: IApprovalService;
    FOnEvent: TMcpEvent;
    FRuntimes: TMcpServerRuntimeArray;
    FBackoffInitialMs: Integer;
    FBackoffMaxMs: Integer;
    FTokenSourceFor: TMcpTokenSourceFactory;
    function FindRuntime(const AName: string): Integer;
    function ClientConfigFor(const AServer: TMcpServerConfig): TMcpClientConfig;
    procedure CloseRuntime(AIndex: Integer);
    function OpenRuntime(AIndex: Integer): Boolean;
  public
    constructor Create(const AConfig: TMcpConfig;
      AApproval: IApprovalService; AOnEvent: TMcpEvent);
    destructor Destroy; override;
    { Open every configured server (a thin wrapper over Reconcile). }
    function Open: Boolean;
    { Diff AConfig against the live set: open new, reconnect dead (after
      backoff), close disabled/removed. Returns True when consistent. }
    function Reconcile(const AConfig: TMcpConfig): Boolean;
    procedure Close;
    function Runtimes: TMcpServerRuntimeArray;
    { The union of connected servers' tool specs. }
    function Specs: TToolSpecArray;
    { Resolve a tool name to its owning server's handler. }
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    { Backoff knobs; default 1000 -> 60000 ms. Exposed for tests. }
    property BackoffInitialMs: Integer read FBackoffInitialMs
      write FBackoffInitialMs;
    property BackoffMaxMs: Integer read FBackoffMaxMs write FBackoffMaxMs;
    { When set, each HTTP server's client gets a token source from here. }
    property TokenSourceFor: TMcpTokenSourceFactory read FTokenSourceFor
      write FTokenSourceFor;
  end;

  { The MCP manager as a turn provider. Prepare reconciles from the config
    source; Specs/Find expose the live tools; PromptFragment is ''. }
  TMcpProvider = class(TInterfacedObject, IToolProvider)
  private
    FManager: TMcpManager;
    FConfigSource: TMcpConfigSource;
  public
    constructor Create(AManager: TMcpManager; AConfigSource: TMcpConfigSource);
    procedure Prepare;
    function Specs: TToolSpecArray;
    function PromptFragment: string;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
  end;

{ --- pure mapping (public for direct testing) --------------------------- }

{ The approval ref for a server/tool pair. Stable across releases. }
function McpRef(const AServer, ATool: string): string;
{ The provider-safe, model-visible tool name for a server/tool pair. }
function McpToolName(const AServer, ATool: string): string;
{ base, or base_2/base_3/... when base is already taken. }
function McpUniqueToolName(const ABaseName: string;
  const ATaken: TStrings): string;
{ Maps an MCP inputSchema to a registry ParametersJson, or False when malformed
  or over-wide. }
function McpSchemaToParams(const AInputSchemaJson: string;
  out AParamsJson: string; out AError: string): Boolean;
{ Maps an MCP tools/call result object to the loop's text result. Never nil. }
function McpResultToText(const AResultJson: string): string;
{ True when the tools/call result carries isError:true. }
function McpResultIsError(const AResultJson: string): Boolean;

const
  DefaultMcpListTimeoutMs = 10000;
  DefaultMcpCallTimeoutMs = 60000;
  McpClientName = 'hildegard-helper';
  McpClientVersion = '0.1';
  MaxSchemaProperties = 64;
  MaxSchemaBytes = 16384;
  MaxToolNameChars = 64;
  { The protocol version the client requests, and the set it accepts back. }
  McpProtocolVersion = '2024-11-05';
  { Reconnect backoff: start and cap (ms). }
  McpBackoffInitialMs = 1000;
  McpBackoffMaxMs = 60000;
  SupportedProtocolVersions: array[0..3] of string =
    ('2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25');

implementation

uses
  fpjson, jsonparser, hildegard.helper.session.socket;

{ --- identity encoding -------------------------------------------------- }

function McpSanitize(const AValue: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    if C in ['A'..'Z'] then
      C := Chr(Ord(C) + 32);
    if not (C in ['a'..'z', '0'..'9', '_', '-']) then
      C := '_';
    Result := Result + C;
  end;
end;

function McpRef(const AServer, ATool: string): string;
begin
  Result := 'mcp/' + McpSanitize(AServer) + '/' + McpSanitize(ATool);
end;

function McpToolName(const AServer, ATool: string): string;
begin
  Result := 'mcp_' + McpSanitize(AServer) + '_' + McpSanitize(ATool);
  if Length(Result) > MaxToolNameChars then
    Result := Copy(Result, 1, MaxToolNameChars);
end;

function McpUniqueToolName(const ABaseName: string;
  const ATaken: TStrings): string;
var
  N: Integer;
begin
  if ATaken.IndexOf(ABaseName) < 0 then
    Exit(ABaseName);
  N := 2;
  while ATaken.IndexOf(ABaseName + '_' + IntToStr(N)) >= 0 do
    Inc(N);
  Result := ABaseName + '_' + IntToStr(N);
end;

{ --- schema mapping ----------------------------------------------------- }

function McpSchemaToParams(const AInputSchemaJson: string;
  out AParamsJson: string; out AError: string): Boolean;
var
  Data: TJSONData;
  Root, Props: TJSONObject;
  Req: TJSONArray;
  I: Integer;
begin
  AError := '';
  AParamsJson := '';
  Data := nil;
  try
    try
      Data := GetJSON(AInputSchemaJson);
    except
      on E: Exception do
      begin
        AError := 'inputSchema is not valid JSON';
        Exit(False);
      end;
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'inputSchema must be a JSON object';
      Exit(False);
    end;
    Root := TJSONObject(Data);
    if Length(Root.AsJSON) > MaxSchemaBytes then
    begin
      AError := 'inputSchema is too large';
      Exit(False);
    end;
    if Root.Find('properties') is TJSONObject then
    begin
      Props := TJSONObject(Root.Find('properties'));
      if Props.Find('reason') <> nil then
        Props.Delete('reason');
      if Props.Count > MaxSchemaProperties then
      begin
        AError := 'inputSchema has too many properties';
        Exit(False);
      end;
    end;
    if Root.Find('required') is TJSONArray then
    begin
      Req := TJSONArray(Root.Find('required'));
      for I := Req.Count - 1 downto 0 do
        if (Req.Types[I] = jtString) and (Req.Strings[I] = 'reason') then
          Req.Delete(I);
    end;
    AParamsJson := Root.AsJSON;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ --- result mapping ----------------------------------------------------- }

function McpResultToText(const AResultJson: string): string;
var
  Data: TJSONData;
  Root, Block: TJSONObject;
  Content: TJSONArray;
  I: Integer;
  Parts: TStringList;
  BlockType, BlockText: string;
begin
  Result := '';
  Data := nil;
  Parts := TStringList.Create;
  try
    try
      Data := GetJSON(AResultJson);
    except
      on E: Exception do
        Exit('[invalid MCP result]');
    end;
    if not (Data is TJSONObject) then
      Exit(AResultJson);
    Root := TJSONObject(Data);
    if Root.Find('content') is TJSONArray then
    begin
      Content := TJSONArray(Root.Find('content'));
      for I := 0 to Content.Count - 1 do
      begin
        BlockType := '';
        if Content.Types[I] = jtObject then
        begin
          Block := Content.Objects[I];
          if Block.Find('type') <> nil then
            BlockType := Block.Find('type').AsString;
        end;
        if (BlockType = 'text') and (Block.Find('text') <> nil) then
        begin
          BlockText := Block.Find('text').AsString;
          Parts.Add(BlockText);
        end
        else if BlockType = '' then
          Parts.Add('[non-text content]')
        else
          Parts.Add('[non-text content: ' + BlockType + ']');
      end;
    end;
    if Root.Find('structuredContent') <> nil then
      Parts.Add('[structured content omitted]');
    for I := 0 to Parts.Count - 1 do
    begin
      if I > 0 then
        Result := Result + LineEnding;
      Result := Result + Parts[I];
    end;
  finally
    Parts.Free;
    Data.Free;
  end;
end;

function McpResultIsError(const AResultJson: string): Boolean;
var
  Data: TJSONData;
begin
  Result := False;
  Data := nil;
  try
    try
      Data := GetJSON(AResultJson);
    except
      Exit;
    end;
    if Data is TJSONObject then
      Result := (TJSONObject(Data).Find('isError') <> nil) and
        TJSONObject(Data).Find('isError').AsBoolean;
  finally
    Data.Free;
  end;
end;

{ Strips the injected 'reason' from a call's arguments. Returns an empty JSON
  object when the arguments are not a JSON object. }
function StripReason(const AArgumentsJson: string): string;
var
  Data: TJSONData;
  Root: TJSONObject;
begin
  Result := '{}';
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      Exit;
    end;
    if not (Data is TJSONObject) then
      Exit;
    Root := TJSONObject(Data);
    if Root.Find('reason') <> nil then
      Root.Delete('reason');
    Result := Root.AsJSON;
  finally
    Data.Free;
  end;
end;

{ --- TMcpToolHandler ---------------------------------------------------- }

constructor TMcpToolHandler.Create(AClient: TMcpClient; const ATool: TMcpTool);
begin
  inherited Create;
  FClient := AClient;
  FTool := ATool;
end;

function TMcpToolHandler.Handle(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
begin
  Result := FClient.CallTool(FTool, AArgumentsJson, AResult, AError);
end;

{ --- TMcpClient --------------------------------------------------------- }

constructor TMcpClient.Create(const AConfig: TMcpClientConfig;
  AApproval: IApprovalService; AOnEvent: TMcpEvent);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.ListTimeoutMs <= 0 then
    FConfig.ListTimeoutMs := DefaultMcpListTimeoutMs;
  if FConfig.CallTimeoutMs <= 0 then
    FConfig.CallTimeoutMs := DefaultMcpCallTimeoutMs;
  if FConfig.ClientName = '' then
    FConfig.ClientName := McpClientName;
  if FConfig.ClientVersion = '' then
    FConfig.ClientVersion := McpClientVersion;
  FApproval := AApproval;
  FOnEvent := AOnEvent;
  FIdGen := TJsonRpcIdGen.Create;
  FRegisteredRefs := TStringList.Create;
  FDead := False;
end;

destructor TMcpClient.Destroy;
begin
  Close;
  FRegisteredRefs.Free;
  FIdGen.Free;
  inherited Destroy;
end;

function TMcpClient.GetServerName: string;
begin
  Result := FConfig.Server.Name;
end;

procedure TMcpClient.Emit(const AMessage, ADetail: string);
begin
  if Assigned(FOnEvent) then
    FOnEvent(AMessage, ADetail);
end;

function TMcpClient.WaitResponse(AId: TJsonRpcId; ATimeoutMs: Integer;
  out AResultJson: string; out AError: string): Boolean;
var
  Incoming: TJsonRpcIncoming;
  Line, WriteErr: string;
  Reason: TMcpRecvResult;
  Deadline, Remaining: Int64;
begin
  Result := False;
  AResultJson := '';
  AError := '';
  Deadline := NowMs + ATimeoutMs;
  repeat
    Remaining := Deadline - NowMs;
    if Remaining <= 0 then
    begin
      AError := 'timed out waiting for MCP response';
      Exit;
    end;
    if not FTransport.Receive(Line, Remaining, Reason) then
    begin
      case Reason of
        mrTimeout: AError := 'timed out waiting for MCP response';
        mrEof: begin FDead := True; AError := 'MCP server exited'; end;
        mrTooLong: AError := 'MCP server sent an over-long line';
      else
        AError := 'MCP read error';
      end;
      Exit;
    end;
    Incoming := TJsonRpcCodec.Decode(Line);
    case Incoming.Kind of
      ikResponse:
        if Incoming.Id = AId then
        begin
          if Incoming.IsError then
          begin
            AError := 'MCP error ' + IntToStr(Incoming.Error.Code) + ': ' +
              Incoming.Error.Message;
            Exit;
          end;
          AResultJson := Incoming.ResultJson;
          Exit(True);
        end;
      ikNotification:
        ;   { consumed; never correlated }
      ikServerRequest:
        begin
          Line := TJsonRpcCodec.EncodeError(Incoming.Id, JsonRpcMethodNotFound,
            'method not supported: ' + Incoming.Method);
          FTransport.Send(Line, WriteErr);
        end;
      ikMalformed:
        Emit('mcp: malformed message from ' + ServerName,
          Incoming.MalformedReason);
    end;
  until False;
end;

function TMcpClient.Call(const AMethod, AParamsJson: string;
  ATimeoutMs: Integer; out AResultJson: string; out AError: string): Boolean;
var
  Id: TJsonRpcId;
  Line, Err: string;
begin
  AResultJson := '';
  AError := '';
  if FDead or (FTransport = nil) then
  begin
    AError := 'MCP server not available';
    Exit(False);
  end;
  Id := FIdGen.Next;
  Line := TJsonRpcCodec.EncodeRequest(Id, AMethod, AParamsJson);
  if not FTransport.Send(Line, Err) then
  begin
    FDead := True;
    AError := 'MCP write failed: ' + Err;
    Exit(False);
  end;
  Result := WaitResponse(Id, ATimeoutMs, AResultJson, AError);
end;

function TMcpClient.ProtocolOk(const AInitializeResultJson: string;
  out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  V: string;
  I: Integer;
begin
  AError := '';
  Data := nil;
  try
    try
      Data := GetJSON(AInitializeResultJson);
    except
      on E: Exception do
      begin
        AError := 'initialize result is not valid JSON';
        Exit(False);
      end;
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'initialize result is not a JSON object';
      Exit(False);
    end;
    Root := TJSONObject(Data);
    if Root.Find('protocolVersion') = nil then
    begin
      AError := 'initialize result has no protocolVersion';
      Exit(False);
    end;
    V := Root.Find('protocolVersion').AsString;
    for I := Low(SupportedProtocolVersions) to High(SupportedProtocolVersions) do
      if V = SupportedProtocolVersions[I] then
        Exit(True);
    AError := 'unsupported MCP protocol version: ' + V;
    Result := False;
  finally
    Data.Free;
  end;
end;

function TMcpClient.Discover(out AError: string): Boolean;
var
  ResultJson: string;
  Data: TJSONData;
  Root: TJSONObject;
  Tools: TJSONArray;
  Entry: TJSONObject;
  I: Integer;
  Tool: TMcpTool;
  Mapped: string;
  MapErr: string;
begin
  AError := '';
  FTools := nil;
  if not Call('tools/list', '{}', FConfig.ListTimeoutMs, ResultJson, AError) then
    Exit(False);
  Data := nil;
  try
    try
      Data := GetJSON(ResultJson);
    except
      on E: Exception do
      begin
        AError := 'tools/list result is not valid JSON';
        Exit(False);
      end;
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'tools/list result is not a JSON object';
      Exit(False);
    end;
    Root := TJSONObject(Data);
    if not (Root.Find('tools') is TJSONArray) then
      Exit(True);   { no tools is valid }
    Tools := TJSONArray(Root.Find('tools'));
    for I := 0 to Tools.Count - 1 do
    begin
      if Tools.Types[I] <> jtObject then
        Continue;
      Entry := Tools.Objects[I];
      if (Entry.Find('name') = nil) or (Entry.Find('name').JSONType <> jtString) then
        Continue;
      Tool := Default(TMcpTool);
      Tool.ServerName := ServerName;
      Tool.ToolName := Entry.Find('name').AsString;
      Tool.Ref := McpRef(ServerName, Tool.ToolName);
      Tool.Name := McpToolName(ServerName, Tool.ToolName);
      if Entry.Find('description') <> nil then
        Tool.Description := Entry.Find('description').AsString;
      if Entry.Find('inputSchema') <> nil then
      begin
        if not McpSchemaToParams(Entry.Find('inputSchema').AsJSON, Mapped,
          MapErr) then
        begin
          Emit('mcp: rejected tool "' + Tool.ToolName + '" from ' + ServerName,
            MapErr);
          Continue;
        end;
        Tool.ParametersJson := Mapped;
      end
      else
        Tool.ParametersJson := '{"type":"object","properties":{}}';
      SetLength(FTools, Length(FTools) + 1);
      FTools[High(FTools)] := Tool;
    end;
    Result := True;
  finally
    Data.Free;
  end;
end;

function TMcpClient.RegisterTools(out AError: string): Boolean;
var
  I: Integer;
  Taken: TStringList;
  Spec: TToolSpec;
  Handler: TMcpToolHandler;
  UniqueName: string;
begin
  AError := '';
  Taken := TStringList.Create;
  try
    { Names already in use by this client's own specs. }
    for I := 0 to High(FSpecs) do
      Taken.Add(FSpecs[I].Name);
    for I := 0 to High(FTools) do
    begin
      { A tool already registered (e.g. across a Refresh) is left in place. }
      if FRegisteredRefs.IndexOf(FTools[I].Ref) >= 0 then
        Continue;
      UniqueName := McpUniqueToolName(FTools[I].Name, Taken);
      FTools[I].Name := UniqueName;
      Taken.Add(UniqueName);
      FRegisteredRefs.Add(FTools[I].Ref);
      Spec := MakeToolSpec(UniqueName, FTools[I].Description,
        FTools[I].ParametersJson);
      Handler := TMcpToolHandler.Create(Self, FTools[I]);
      SetLength(FHandlers, Length(FHandlers) + 1);
      FHandlers[High(FHandlers)] := Handler;
      SetLength(FSpecs, Length(FSpecs) + 1);
      FSpecs[High(FSpecs)] := Spec;
    end;
    Result := True;
  finally
    Taken.Free;
  end;
end;

function TMcpClient.Specs: TToolSpecArray;
begin
  Result := FSpecs;
end;

function TMcpClient.Find(const AName: string;
  out ATool: TRegisteredTool): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FSpecs) do
    if FSpecs[I].Name = AName then
    begin
      ATool := Default(TRegisteredTool);
      ATool.Spec := FSpecs[I];
      ATool.Handler := FHandlers[I].Handle;
      Exit(True);
    end;
  ATool := Default(TRegisteredTool);
  Result := False;
end;

function TMcpClient.Open(out AError: string): Boolean;
var
  ChildCfg: TStdioChildConfig;
  HttpCfg: THttpTransportConfig;
  HttpT: THttpTransport;
  InitParams, ResultJson, Err: string;
begin
  AError := '';
  if FTransport <> nil then
    Exit(True);
  FDead := False;   // a fresh open clears a previous death
  { A new connection starts a fresh id sequence (ids are per-connection). }
  FIdGen.Free;
  FIdGen := TJsonRpcIdGen.Create;
  if FConfig.Server.Transport = mtHttp then
  begin
    HttpCfg := Default(THttpTransportConfig);
    HttpCfg.URL := FConfig.Server.Url;
    HttpCfg.Headers := Copy(FConfig.Server.Headers, 0,
      Length(FConfig.Server.Headers));
    HttpCfg.ReadTimeoutMs := FConfig.ListTimeoutMs;
    HttpT := THttpTransport.Create(HttpCfg);
    if Assigned(FConfig.TokenSource) then
      HttpT.TokenSource := FConfig.TokenSource;
    FTransport := HttpT;
  end
  else
  begin
    ChildCfg := Default(TStdioChildConfig);
    ChildCfg.Executable := FConfig.Server.Command;
    ChildCfg.Args := Copy(FConfig.Server.Args, 0, Length(FConfig.Server.Args));
    ChildCfg.Env := Copy(FConfig.Server.Env, 0, Length(FConfig.Server.Env));
    ChildCfg.WorkingDir := FConfig.Server.WorkingDir;
    ChildCfg.ReadTimeoutMs := FConfig.ListTimeoutMs;
    FTransport := TStdioTransport.Create(ChildCfg);
  end;
  if not FTransport.Open(Err) then
  begin
    AError := 'open failed: ' + Err;
    Emit('mcp: server "' + ServerName + '" failed to open', Err);
    Close;
    Exit(False);
  end;

  InitParams := '{"protocolVersion":"' + McpProtocolVersion +
    '","capabilities":{},"clientInfo":{"name":"' + FConfig.ClientName +
    '","version":"' + FConfig.ClientVersion + '"}}';
  if not Call('initialize', InitParams, FConfig.ListTimeoutMs, ResultJson,
    AError) then
  begin
    Emit('mcp: server "' + ServerName + '" initialize failed', AError);
    Close;
    Exit(False);
  end;
  if not ProtocolOk(ResultJson, AError) then
  begin
    Emit('mcp: server "' + ServerName + '" refused', AError);
    Close;
    Exit(False);
  end;
  FTransport.Send(TJsonRpcCodec.EncodeNotification(
    'notifications/initialized', ''), Err);

  if not Discover(AError) then
  begin
    Emit('mcp: server "' + ServerName + '" tools/list failed', AError);
    Close;
    Exit(False);
  end;
  Result := RegisterTools(AError);
  if not Result then
    Close;
end;

function TMcpClient.Refresh(out AError: string): Boolean;
var
  NewTools: TMcpToolArray;
  I: Integer;
  Err: string;
begin
  { Re-list, then register only tools whose ref is not already registered. }
  Result := Discover(AError);
  if not Result then
    Exit;
  NewTools := FTools;
  FTools := nil;
  for I := 0 to High(NewTools) do
  begin
    SetLength(FTools, Length(FTools) + 1);
    FTools[High(FTools)] := NewTools[I];
  end;
  RegisterTools(Err);
  Result := True;
end;

function TMcpClient.CallTool(const ATool: TMcpTool;
  const AArgumentsJson: string; out AResult: string; out AError: string): Boolean;
var
  Ask: TApprovalAsk;
  Asks: TApprovalAskArray;
  Batch: TApprovalBatchResult;
  Opt: TApprovalOption;
  Reason, ReasonErr, ParamsJson, CallParams, ResultJson: string;
begin
  AResult := '';
  AError := '';
  if FApproval <> nil then
  begin
    ExtractToolReason(AArgumentsJson, Reason, ReasonErr);
    Ask := Default(TApprovalAsk);
    Ask.Summary := 'MCP ' + ATool.ServerName + ' · ' + ATool.ToolName;
    Ask.Reason := Reason;
    Ask.Subject.Ref := ATool.Ref;
    Ask.Subject.Params := nil;
    Opt := Default(TApprovalOption);
    Opt.Key := 'once';
    Opt.Caption := 'allow once';
    Opt.Persists := False;
    Opt.Rule := DefaultApprovalRule(aeAllow);
    Opt.Rule.Ref := ATool.Ref;
    Opt.Rule.AnyParams := True;
    SetLength(Ask.Options, 1);
    Ask.Options[0] := Opt;
    SetLength(Asks, 1);
    Asks[0] := Ask;
    if not FApproval.Resolve(Asks, Batch) then
    begin
      AError := 'approval error: ' + Batch.Reason;
      Exit(False);
    end;
    if Batch.Denied then
    begin
      AError := 'denied by operator';
      Exit(False);
    end;
  end;
  ParamsJson := StripReason(AArgumentsJson);
  CallParams := '{"name":"' + ATool.ToolName + '","arguments":' + ParamsJson + '}';
  if not Call('tools/call', CallParams, FConfig.CallTimeoutMs, ResultJson,
    AError) then
    Exit(False);
  AResult := McpResultToText(ResultJson);
  if McpResultIsError(ResultJson) then
  begin
    AError := AResult;
    AResult := '';
    Exit(False);
  end;
  Result := True;
end;

procedure TMcpClient.Close;
var
  I: Integer;
begin
  for I := 0 to High(FHandlers) do
    FHandlers[I].Free;
  FHandlers := nil;
  FSpecs := nil;
  FRegisteredRefs.Clear;
  if FTransport <> nil then
  begin
    FTransport.Close;
    FTransport := nil;
  end;
end;

{ --- TMcpManager -------------------------------------------------------- }

constructor TMcpManager.Create(const AConfig: TMcpConfig;
  AApproval: IApprovalService; AOnEvent: TMcpEvent);
var
  I: Integer;
  Cfg: TMcpClientConfig;
begin
  inherited Create;
  FApproval := AApproval;
  FOnEvent := AOnEvent;
  FBackoffInitialMs := McpBackoffInitialMs;
  FBackoffMaxMs := McpBackoffMaxMs;
  SetLength(FRuntimes, Length(AConfig.Servers));
  for I := 0 to High(AConfig.Servers) do
  begin
    FRuntimes[I] := Default(TMcpServerRuntime);
    FRuntimes[I].Name := AConfig.Servers[I].Name;
    FRuntimes[I].Config := AConfig.Servers[I];
    FRuntimes[I].State := mssStopped;
    Cfg := ClientConfigFor(AConfig.Servers[I]);
    FRuntimes[I].Client := TMcpClient.Create(Cfg, FApproval, FOnEvent);
    FRuntimes[I].BackoffMs := FBackoffInitialMs;
  end;
end;

destructor TMcpManager.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TMcpManager.ClientConfigFor(
  const AServer: TMcpServerConfig): TMcpClientConfig;
begin
  Result := Default(TMcpClientConfig);
  Result.Server := AServer;
  Result.ListTimeoutMs := AServer.ListTimeoutMs;
  Result.CallTimeoutMs := AServer.CallTimeoutMs;
  if (AServer.Transport = mtHttp) and Assigned(FTokenSourceFor) then
    Result.TokenSource := FTokenSourceFor(AServer);
end;

function TMcpManager.FindRuntime(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FRuntimes) do
    if FRuntimes[I].Name = AName then
      Exit(I);
  Result := -1;
end;

function TMcpManager.OpenRuntime(AIndex: Integer): Boolean;
var
  Err: string;
begin
  Result := FRuntimes[AIndex].Client.Open(Err);
  if Result then
  begin
    FRuntimes[AIndex].State := mssConnected;
    FRuntimes[AIndex].BackoffMs := FBackoffInitialMs;
    FRuntimes[AIndex].NextAttemptAt := 0;
  end
  else
  begin
    FRuntimes[AIndex].State := mssDead;
    Inc(FRuntimes[AIndex].Attempts);
    FRuntimes[AIndex].NextAttemptAt := NowMs + FRuntimes[AIndex].BackoffMs;
    if FRuntimes[AIndex].BackoffMs < FBackoffMaxMs then
      FRuntimes[AIndex].BackoffMs := FRuntimes[AIndex].BackoffMs * 2;
    if FRuntimes[AIndex].BackoffMs > FBackoffMaxMs then
      FRuntimes[AIndex].BackoffMs := FBackoffMaxMs;
  end;
end;

procedure TMcpManager.CloseRuntime(AIndex: Integer);
begin
  FRuntimes[AIndex].Client.Close;
  FRuntimes[AIndex].State := mssStopped;
end;

function TMcpManager.Open: Boolean;
var
  I: Integer;
  Cfg: TMcpConfig;
begin
  Cfg := Default(TMcpConfig);
  SetLength(Cfg.Servers, Length(FRuntimes));
  for I := 0 to High(FRuntimes) do
    Cfg.Servers[I] := FRuntimes[I].Config;
  Result := Reconcile(Cfg);
end;

function TMcpManager.Reconcile(const AConfig: TMcpConfig): Boolean;
var
  I, J: Integer;
  Name: string;
  CfgServer: TMcpServerConfig;
  Found: Boolean;
  Now: Int64;
begin
  Result := True;
  Now := NowMs;
  { Remove runtimes no longer enabled/configured. }
  for I := High(FRuntimes) downto 0 do
  begin
    Name := FRuntimes[I].Name;
    Found := False;
    for J := 0 to High(AConfig.Servers) do
      if AConfig.Servers[J].Name = Name then
      begin
        Found := True;
        Break;
      end;
    if not Found then
    begin
      if FRuntimes[I].State <> mssStopped then
        CloseRuntime(I);
      FRuntimes[I].Client.Free;
      for J := I to High(FRuntimes) - 1 do
        FRuntimes[J] := FRuntimes[J + 1];
      SetLength(FRuntimes, Length(FRuntimes) - 1);
    end;
  end;
  { Add or reconcile configured servers. }
  for J := 0 to High(AConfig.Servers) do
  begin
    CfgServer := AConfig.Servers[J];
    I := FindRuntime(CfgServer.Name);
    if I < 0 then
    begin
      SetLength(FRuntimes, Length(FRuntimes) + 1);
      I := High(FRuntimes);
      FRuntimes[I] := Default(TMcpServerRuntime);
      FRuntimes[I].Name := CfgServer.Name;
      FRuntimes[I].Config := CfgServer;
      FRuntimes[I].Client := TMcpClient.Create(ClientConfigFor(CfgServer),
        FApproval, FOnEvent);
      FRuntimes[I].BackoffMs := FBackoffInitialMs;
      FRuntimes[I].State := mssStopped;
    end
    else
      FRuntimes[I].Config := CfgServer;
    case FRuntimes[I].State of
      mssConnected:
        if FRuntimes[I].Client.Dead then
        begin
          CloseRuntime(I);
          FRuntimes[I].State := mssDead;
          FRuntimes[I].NextAttemptAt := Now + FRuntimes[I].BackoffMs;
        end;
      mssStopped:
        OpenRuntime(I);
      mssDead:
        if Now >= FRuntimes[I].NextAttemptAt then
        begin
          FRuntimes[I].Client.Close;
          OpenRuntime(I);
        end;
    end;
  end;
end;

function TMcpManager.Specs: TToolSpecArray;
var
  I, K, N: Integer;
  S: TToolSpecArray;
begin
  Result := nil;
  for I := 0 to High(FRuntimes) do
  begin
    S := FRuntimes[I].Client.Specs;
    for K := 0 to High(S) do
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := S[K];
    end;
  end;
end;

function TMcpManager.Find(const AName: string;
  out ATool: TRegisteredTool): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FRuntimes) do
    if FRuntimes[I].Client.Find(AName, ATool) then
      Exit(True);
  ATool := Default(TRegisteredTool);
  Result := False;
end;

procedure TMcpManager.Close;
var
  I: Integer;
begin
  for I := 0 to High(FRuntimes) do
  begin
    FRuntimes[I].Client.Close;
    FRuntimes[I].Client.Free;
  end;
  FRuntimes := nil;
end;

function TMcpManager.Runtimes: TMcpServerRuntimeArray;
begin
  Result := FRuntimes;
end;

{ --- TMcpProvider ------------------------------------------------------- }

constructor TMcpProvider.Create(AManager: TMcpManager;
  AConfigSource: TMcpConfigSource);
begin
  inherited Create;
  FManager := AManager;
  FConfigSource := AConfigSource;
end;

procedure TMcpProvider.Prepare;
begin
  if (FManager <> nil) and Assigned(FConfigSource) then
    FManager.Reconcile(FConfigSource());
end;

function TMcpProvider.Specs: TToolSpecArray;
begin
  if FManager = nil then
    Result := nil
  else
    Result := FManager.Specs;
end;

function TMcpProvider.PromptFragment: string;
begin
  Result := '';   { MCP contributes no prompt }
end;

function TMcpProvider.Find(const AName: string;
  out ATool: TRegisteredTool): Boolean;
begin
  if FManager = nil then
  begin
    ATool := Default(TRegisteredTool);
    Exit(False);
  end;
  Result := FManager.Find(AName, ATool);
end;

end.
