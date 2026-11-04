unit HildiMCPProvider;
{ MCP servers as a TOOL PROVIDER, not as skills.

  A skill and an MCP server were sharing one record in the skill registry, and
  that sharing forced one decay policy to serve two incompatible needs: a
  skill's body must stay in context for the session, while an MCP connection
  must be lazy and released when idle. Uniform idle decay would have silently
  dropped a prompt-only skill's body; "never decay" would have held every
  connection open forever.

  So they are separate. Each policy is coherent inside its own unit:

  - Skills: a body injected into the conversation, never decayed.
  - MCP (here): no body at all. `load_mcp` opens a server, an idle TTL releases
    it, and a live status line tells the agent what is usable right now.

  This unit IS an IToolProvider, so it needs no second seam. It contributes
  `load_mcp` always, the open servers' tools, a STABLE catalogue (name plus
  curated description) for the system prompt, and a VOLATILE status fragment
  for the request tail.

  The descriptions are OURS, from a curated template keyed on the service name.
  A server's own initialize.instructions is never used: it is a prompt-injection
  surface. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  HildiLLM, HildiAgent,
  HildiMCPClient, HildiMCPConfig;

const
  { The always-present tool that opens a server. }
  LoadMcpToolName = 'load_mcp';
  { Idle time before a connection is released. Short on purpose: the point is
    not to hold a server open for a session that is not using it. }
  DefaultMcpTtlMs = 300000;   // 5 minutes
  McpLoadParametersJson =
    '{"type":"object","properties":{"name":{"type":"string",' +
    '"description":"the MCP server name to open"}},"required":["name"]}';

type
  TMcpProvider = class(TInterfacedObject, IToolProvider)
  private
    FManager: TMcpManager;
    FNames: TStringArray;         // configured server names, in order
    FDescriptions: TStringArray;  // curated, parallel to FNames
    FWhenToUse: TStringArray;     // curated, parallel to FNames
    FOpen: array of Boolean;      // parallel to FNames
    FLastUsedMs: array of Int64;  // parallel to FNames
    FTtlMs: Int64;
    function IndexOf(const AName: string): Integer;
    function LoadSpec: TToolSpec;
    function HandleLoad(const AArgumentsJson: string;
      out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function NowMs: Int64;
  public
    { The config's servers are declared immediately and none is connected. }
    constructor Create(AManager: TMcpManager; const AConfig: TMcpConfig);
    { Re-declare after a config change: releases servers that are gone. }
    procedure Reconcile(const AConfig: TMcpConfig);

    { The STABLE half: name plus curated description, for the system prompt. }
    function StableText: string;
    { The VOLATILE half: open/closed per server, for the request tail. }
    function StatusText: string;
    { The configured names, in order. }
    function Names: TStringArray;
    { Which servers are open right now. }
    function OpenNames: TStringArray;
    { One server's TRANSPORT state, from the manager's live set. False when the
      name is not in the manager at all, which the caller must render as UNKNOWN
      rather than "down" - the two are different claims. Returns the manager's
      own state type, not a wire type: mapping to the wire is the protocol's job,
      so this unit does not import it. }
    function TransportStateOf(const AName: string;
      out AState: TMcpServerState): Boolean;
    { Drop one server's transport and open it again. Refreshes auth through the
      existing OAuth path. Touches the TRANSPORT only, never FOpen: reconnecting
      is not loading, so it must not change what the model can use. }
    function Reconnect(const AName: string; out AError: string): Boolean;

    { IToolProvider }
    procedure Prepare;
    function Specs: TToolSpecArray;
    function PromptFragment: string;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;

    property TtlMs: Int64 read FTtlMs write FTtlMs;
  end;

implementation

uses
  fpjson, jsonparser;

constructor TMcpProvider.Create(AManager: TMcpManager;
  const AConfig: TMcpConfig);
begin
  inherited Create;
  FManager := AManager;
  FTtlMs := DefaultMcpTtlMs;
  Reconcile(AConfig);
end;

procedure TMcpProvider.Reconcile(const AConfig: TMcpConfig);
var
  I: Integer;
  Desc, When: string;
begin
  { Release any server that is open now: the config is being replaced wholesale,
    and a connection to a server that no longer exists should not survive it. }
  for I := 0 to High(FNames) do
    if FOpen[I] and (FManager <> nil) then
      FManager.CloseServer(FNames[I]);

  FNames := nil;
  FDescriptions := nil;
  FWhenToUse := nil;
  FOpen := nil;
  FLastUsedMs := nil;

  for I := 0 to High(AConfig.Servers) do
  begin
    SetLength(FNames, Length(FNames) + 1);
    SetLength(FDescriptions, Length(FDescriptions) + 1);
    SetLength(FWhenToUse, Length(FWhenToUse) + 1);
    SetLength(FOpen, Length(FOpen) + 1);
    SetLength(FLastUsedMs, Length(FLastUsedMs) + 1);
    FNames[High(FNames)] := AConfig.Servers[I].Name;
    { From the record. A server with no stored description simply has none: the
      manifest then carries the name alone, which is honest. No table may supply
      a description a record did not choose. }
    FDescriptions[High(FDescriptions)] := AConfig.Servers[I].Description;
    FWhenToUse[High(FWhenToUse)] := '';
    FOpen[High(FOpen)] := False;
    FLastUsedMs[High(FLastUsedMs)] := 0;
  end;
end;

function TMcpProvider.IndexOf(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FNames) do
    if FNames[I] = AName then
      Exit(I);
  Result := -1;
end;

function TMcpProvider.NowMs: Int64;
begin
  Result := Int64(GetTickCount64);
end;

function TMcpProvider.Names: TStringArray;
begin
  Result := Copy(FNames, 0, Length(FNames));
end;

function TMcpProvider.OpenNames: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(FNames) do
    if FOpen[I] then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := FNames[I];
    end;
end;

function TMcpProvider.TransportStateOf(const AName: string;
  out AState: TMcpServerState): Boolean;
var
  Rs: TMcpServerRuntimeArray;
  I: Integer;
begin
  AState := mssStopped;
  Result := False;
  if FManager = nil then
    Exit;
  Rs := FManager.Runtimes;
  for I := 0 to High(Rs) do
    if SameText(Rs[I].Name, AName) then
    begin
      AState := Rs[I].State;
      Exit(True);
    end;
end;

function TMcpProvider.Reconnect(const AName: string; out AError: string): Boolean;
var
  I: Integer;
begin
  AError := '';
  I := IndexOf(AName);
  if I < 0 then
  begin
    AError := 'unknown MCP server: ' + AName;
    Exit(False);
  end;
  if FManager = nil then
  begin
    AError := 'no MCP manager';
    Exit(False);
  end;
  { Close then open: the close drops a dead transport (and its tools) so the open
    starts clean, which is what makes an expired OAuth token refresh rather than
    reuse a broken connection. FOpen is deliberately NOT set here - reconnecting
    a transport must not change whether the server is loaded into context. }
  FManager.CloseServer(AName);
  Result := FManager.OpenServer(AName, AError);
  if Result then
    FLastUsedMs[I] := NowMs
  else
    AError := 'reconnect failed: ' + AError;
end;

function TMcpProvider.LoadSpec: TToolSpec;
begin
  Result := MakeToolSpec(LoadMcpToolName,
    'Open an MCP server by name so its tools become available. Servers open on ' +
    'demand and close again when idle; the status line shows which are open.',
    McpLoadParametersJson);
end;

function TMcpProvider.HandleLoad(const AArgumentsJson: string;
  out AResult, AError: string; AObserver: TToolObserver): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Name: string;
  I: Integer;
begin
  AResult := '';
  AError := '';
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      AError := 'arguments are not valid JSON';
      Exit(False);
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit(False);
    end;
    Root := TJSONObject(Data);
    if (Root.Find('name') = nil) or (Root.Find('name').JSONType <> jtString) then
    begin
      AError := 'name is required';
      Exit(False);
    end;
    Name := Root.Find('name').AsString;
    I := IndexOf(Name);
    if I < 0 then
    begin
      AError := 'unknown MCP server: ' + Name;
      Exit(False);
    end;
    if FManager = nil then
    begin
      AError := 'no MCP manager';
      Exit(False);
    end;
    if not FManager.OpenServer(Name, AError) then
    begin
      AError := 'open failed: ' + AError;
      Exit(False);
    end;
    FOpen[I] := True;
    FLastUsedMs[I] := NowMs;
    AResult := 'opened ' + Name + '; its tools are now available';
    Result := True;
  finally
    Data.Free;
  end;
end;

procedure TMcpProvider.Prepare;
var
  I: Integer;
  Now: Int64;
begin
  { Decay at the turn boundary. This is the policy that deliberately does NOT
    apply to a skill body, which is why the two are separate units. }
  Now := NowMs;
  for I := 0 to High(FNames) do
    if FOpen[I] and (Now - FLastUsedMs[I] > FTtlMs) then
    begin
      if FManager <> nil then
        FManager.CloseServer(FNames[I]);
      FOpen[I] := False;
    end;
end;

function TMcpProvider.Specs: TToolSpecArray;
var
  I, K: Integer;
  Sub: TToolSpecArray;
begin
  Result := nil;
  { No servers configured: contribute nothing, so a session without MCP is
    byte-identical to one that never had this provider. }
  if Length(FNames) = 0 then
    Exit;
  SetLength(Result, 1);
  Result[0] := LoadSpec;
  if FManager = nil then
    Exit;
  for I := 0 to High(FNames) do
  begin
    if not FOpen[I] then
      Continue;
    Sub := FManager.ServerSpecs(FNames[I]);
    for K := 0 to High(Sub) do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Sub[K];
    end;
  end;
end;

function TMcpProvider.StableText: string;
var
  I: Integer;
begin
  { The catalogue: stable for the session, so it belongs in the system prompt
    rather than riding every request. }
  Result := '';
  for I := 0 to High(FNames) do
  begin
    if Result = '' then
      Result := 'MCP servers you can open with load_mcp:' + LineEnding;
    { The description is OPTIONAL - a record may carry none, and an older row
      predates the column entirely. Rendering "name: " with a bare colon reads
      as a truncated line, so an undescribed server is just its name. }
    if FDescriptions[I] <> '' then
      Result := Result + '- ' + FNames[I] + ': ' + FDescriptions[I]
    else
      Result := Result + '- ' + FNames[I];
    if FWhenToUse[I] <> '' then
      Result := Result + ' ' + FWhenToUse[I];
    Result := Result + LineEnding;
  end;
end;

function TMcpProvider.StatusText: string;
var
  I: Integer;
  State, Lines: string;
begin
  { The VOLATILE half, and the only part that changes per request: what the
    agent can use RIGHT NOW. This replaces the state line MCP servers used to
    get from the skill manifest. }
  Lines := '';
  for I := 0 to High(FNames) do
  begin
    if FOpen[I] then
      State := 'open'
    else
      State := 'closed';
    Lines := Lines + '<mcp name="' + FNames[I] + '" state="' + State + '"/>' +
      LineEnding;
  end;
  if Lines = '' then
    Result := ''
  else
    Result := '<mcp_servers>' + LineEnding + Lines + '</mcp_servers>';
end;

function TMcpProvider.PromptFragment: string;
begin
  if Length(FNames) = 0 then
    Exit('');
  Result := StatusText;
end;

function TMcpProvider.Find(const AName: string;
  out ATool: TRegisteredTool): Boolean;
var
  I, K: Integer;
  Specs: TToolSpecArray;
begin
  ATool := Default(TRegisteredTool);
  if AName = LoadMcpToolName then
  begin
    ATool.Spec := LoadSpec;
    ATool.Handler := HandleLoad;
    Exit(True);
  end;
  if FManager = nil then
    Exit(False);
  Result := FManager.Find(AName, ATool);
  if not Result then
    Exit;
  { A use resets the idle timer of the server that OWNS the tool, so the
    connection the work depends on is the one kept alive. The owner is found by
    asking each open server for its specs - the manager resolves across every
    server it knows, so the name alone does not say who owns it. }
  for I := 0 to High(FNames) do
    if FOpen[I] then
    begin
      Specs := FManager.ServerSpecs(FNames[I]);
      for K := 0 to High(Specs) do
        if Specs[K].Name = AName then
        begin
          FLastUsedMs[I] := NowMs;
          Exit;
        end;
    end;
end;

end.
