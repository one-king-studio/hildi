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
    FChild: TStdioChild;
    FIdGen: TJsonRpcIdGen;
    FTools: TMcpToolArray;
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
    function RegisterTools(ATools: TToolRegistry; out AError: string): Boolean;
  public
    constructor Create(const AConfig: TMcpClientConfig;
      AApproval: IApprovalService; AOnEvent: TMcpEvent);
    destructor Destroy; override;

    { Spawn, handshake, list, and register into ATools. False + AError (and no
      registration) when the server is unusable. }
    function Open(ATools: TToolRegistry; out AError: string): Boolean;

    { Re-run tools/list and register newly-appearing tools (existing names are
      left in place). }
    function Refresh(ATools: TToolRegistry; out AError: string): Boolean;

    { The tools/call path for one tool: approval ask, strip reason, call, map. }
    function CallTool(const ATool: TMcpTool; const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;

    { Close the child. Idempotent. }
    procedure Close;

    property ServerName: string read GetServerName;
    property Tools: TMcpToolArray read FTools;
  end;

  { Spawns every configured server, registers every tool, tears them all down. }
  TMcpManager = class
  private
    FConfig: TMcpConfig;
    FApproval: IApprovalService;
    FOnEvent: TMcpEvent;
    FClients: array of TMcpClient;
  public
    constructor Create(const AConfig: TMcpConfig;
      AApproval: IApprovalService; AOnEvent: TMcpEvent);
    destructor Destroy; override;
    { Open every configured server; failures are skipped (logged). True when
      the manager itself is valid. }
    function Open(ATools: TToolRegistry): Boolean;
    procedure Close;
    function Servers: TMcpServerArray;
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
  SupportedProtocolVersions: array[0..2] of string =
    ('2024-11-05', '2025-03-26', '2025-06-18');

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
  Reason: TStdioReadResult;
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
    if not FChild.ReadLine(Line, Remaining, Reason) then
    begin
      case Reason of
        srTimeout: AError := 'timed out waiting for MCP response';
        srEof: begin FDead := True; AError := 'MCP server exited'; end;
        srTooLong: AError := 'MCP server sent an over-long line';
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
          FChild.WriteLine(Line, WriteErr);
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
  if FDead or (FChild = nil) then
  begin
    AError := 'MCP server not available';
    Exit(False);
  end;
  Id := FIdGen.Next;
  Line := TJsonRpcCodec.EncodeRequest(Id, AMethod, AParamsJson);
  if not FChild.WriteLine(Line, Err) then
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

function TMcpClient.RegisterTools(ATools: TToolRegistry;
  out AError: string): Boolean;
var
  I: Integer;
  Taken: TStringList;
  Specs: TToolSpecArray;
  Spec: TToolSpec;
  Handler: TMcpToolHandler;
  UniqueName: string;
begin
  AError := '';
  Taken := TStringList.Create;
  try
    Specs := ATools.Specs;
    for I := 0 to High(Specs) do
      Taken.Add(Specs[I].Name);
    for I := 0 to High(FTools) do
    begin
      { A tool already registered (e.g. across a Refresh) is left in place. }
      if FRegisteredRefs.IndexOf(FTools[I].Ref) >= 0 then
        Continue;
      UniqueName := McpUniqueToolName(FTools[I].Name, Taken);
      FTools[I].Name := UniqueName;
      Taken.Add(UniqueName);
      FRegisteredRefs.Add(FTools[I].Ref);
      Spec := Default(TToolSpec);
      Spec.Name := UniqueName;
      Spec.Description := FTools[I].Description;
      Spec.ParametersJson := FTools[I].ParametersJson;
      Handler := TMcpToolHandler.Create(Self, FTools[I]);
      SetLength(FHandlers, Length(FHandlers) + 1);
      FHandlers[High(FHandlers)] := Handler;
      ATools.Add(Spec, Handler.Handle);
    end;
    Result := True;
  finally
    Taken.Free;
  end;
end;

function TMcpClient.Open(ATools: TToolRegistry; out AError: string): Boolean;
var
  ChildCfg: TStdioChildConfig;
  InitParams, ResultJson, Err: string;
begin
  AError := '';
  if FChild <> nil then
    Exit(True);
  ChildCfg := Default(TStdioChildConfig);
  ChildCfg.Executable := FConfig.Server.Command;
  ChildCfg.Args := Copy(FConfig.Server.Args, 0, Length(FConfig.Server.Args));
  ChildCfg.Env := Copy(FConfig.Server.Env, 0, Length(FConfig.Server.Env));
  ChildCfg.WorkingDir := FConfig.Server.WorkingDir;
  ChildCfg.ReadTimeoutMs := FConfig.ListTimeoutMs;
  FChild := TStdioChild.Create(ChildCfg);
  if not FChild.Start(Err) then
  begin
    AError := 'spawn failed: ' + Err;
    Emit('mcp: server "' + ServerName + '" failed to spawn', Err);
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
  FChild.WriteLine(TJsonRpcCodec.EncodeNotification(
    'notifications/initialized', ''), Err);

  if not Discover(AError) then
  begin
    Emit('mcp: server "' + ServerName + '" tools/list failed', AError);
    Close;
    Exit(False);
  end;
  Result := RegisterTools(ATools, AError);
  if not Result then
    Close;
end;

function TMcpClient.Refresh(ATools: TToolRegistry; out AError: string): Boolean;
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
  RegisterTools(ATools, Err);
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
  if FChild <> nil then
  begin
    FChild.Close;
    FreeAndNil(FChild);
  end;
end;

{ --- TMcpManager -------------------------------------------------------- }

constructor TMcpManager.Create(const AConfig: TMcpConfig;
  AApproval: IApprovalService; AOnEvent: TMcpEvent);
begin
  inherited Create;
  FConfig := AConfig;
  FApproval := AApproval;
  FOnEvent := AOnEvent;
end;

destructor TMcpManager.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TMcpManager.Open(ATools: TToolRegistry): Boolean;
var
  I: Integer;
  Cfg: TMcpClientConfig;
  Client: TMcpClient;
  Err: string;
begin
  Result := True;
  for I := 0 to High(FConfig.Servers) do
  begin
    Cfg := Default(TMcpClientConfig);
    Cfg.Server := FConfig.Servers[I];
    Cfg.ListTimeoutMs := FConfig.Servers[I].ListTimeoutMs;
    Cfg.CallTimeoutMs := FConfig.Servers[I].CallTimeoutMs;
    Client := TMcpClient.Create(Cfg, FApproval, FOnEvent);
    if Client.Open(ATools, Err) then
    begin
      SetLength(FClients, Length(FClients) + 1);
      FClients[High(FClients)] := Client;
    end
    else
    begin
      if Assigned(FOnEvent) then
        FOnEvent('mcp: server "' + FConfig.Servers[I].Name + '" unavailable',
          Err);
      Client.Free;
    end;
  end;
end;

procedure TMcpManager.Close;
var
  I: Integer;
begin
  for I := 0 to High(FClients) do
    FClients[I].Free;
  FClients := nil;
end;

function TMcpManager.Servers: TMcpServerArray;
begin
  Result := FConfig.Servers;
end;

end.
