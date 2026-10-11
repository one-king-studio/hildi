unit hildegard.helper.harness.session;
{ Owns the agent-side object graph for one session: the session view (workspace,
  store, identity, history, metrics) plus the LLM client, the tool registry
  (builtins and gated run_command), the approval service, the turn queue/gate,
  and the agent loop.

  Used by the headless runtime. A UI client uses hildegard.helper.harness.view
  instead, so it links no agent, tools, or conversation store. }

{$mode delphi}{$H+}

interface

uses
  Classes, Contnrs, SysUtils,
  async.base, async.scheduler, async.concurrency,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.skills,
  hildegard.helper.approval,
  hildegard.helper.approval.store, hildegard.helper.command.tool,
  hildegard.helper.files,
  hildegard.helper.session, hildegard.helper.session.store,
  hildegard.helper.store,
  hildegard.helper.recall.tool, hildegard.helper.harness.turn,
  hildegard.helper.harness.view,
  hildegard.helper.mcp.config, hildegard.helper.mcp.client,
  hildegard.helper.mcp.transport, hildegard.helper.mcp.oauth.flow;
type
  { The loop side of one session. Owns a TSessionView for the workspace, store,
    identity, history, and metrics. Not thread-safe except that Queue/Gate are
    safe across the worker/UI boundary. Call Close (or Free) to release
    everything. }
  THarnessSession = class
  private
    FView: TSessionView;
    FConversation: IConversationStore;
    FClient: TLLMClient;
    FTools: TToolRegistry;
    FCommandTool: TCommandTool;
    FFileTool: TFileTool;
    FRecallTool: TRecallTool;
    FMcp: TMcpManager;
    FMcpTokenProviders: TObjectList;
    { The skill registry: the capability layer (manifest + load_skill + decay).
      Empty by default; Lazy_MCP fills it with one skill per MCP server. Held as
      the interface it is handed to the loop as (the owning ref), so it is freed
      by refcount, never by a raw Free. }
    FSkills: TSkillRegistry;
    FSkillsKeep: IToolProvider;
    FLoop: TAgentLoop;
    FQueue: TTurnQueue;
    FGate: TApprovalGate;
    { The shared turn pool: one bounded executor for the session, so turns reuse
      threads instead of spawning and joining a TThread per turn. }
    FTurnPool: IAsyncScheduler;
    FApprovalService: IApprovalService;
    { MCP events (server failure etc.) are recorded as session errors. }
    procedure McpEvent(const AMessage, ADetail: string);
    { At each turn boundary, re-declare the MCP skills from the current config so
      a server added/enabled/removed is picked up without a restart. Lazy: it
      declares, it does not connect. }
    procedure ReconcileMcpSkills;
    { The current effective MCP config from the store, for the provider. }
    function McpConfigSource: TMcpConfig;
    { A token source for a server with a stored OAuth token (or nil). }
    function McpTokenSourceFor(const AServer: TMcpServerConfig): TMcpTokenSource;
    function Init(const AConfig: THarnessSessionConfig; out AError: string):
      Boolean;
  public
    { Opens the session view and builds the tools, approvals, and loop. Returns
      nil with AError on failure. }
    class function Open(const AConfig: THarnessSessionConfig;
      out AError: string): THarnessSession;
    destructor Destroy; override;

    { The client-side view: identity, store, history, and metrics. }
    property View: TSessionView read FView;
    property Loop: TAgentLoop read FLoop;
    property Tools: TToolRegistry read FTools;
    property Queue: TTurnQueue read FQueue;
    property Gate: TApprovalGate read FGate;
    { The shared executor the turn worker runs on. }
    property TurnPool: IAsyncScheduler read FTurnPool;
    { The capability layer: skills load on demand; empty unless Lazy_MCP fills it. }
    property Skills: TSkillRegistry read FSkills;
    { The session's approval service, so the runtime can hand it to the
      delegation tools. }
    property ApprovalService: IApprovalService read FApprovalService;

    { Cancel pending approvals; frees owned objects. Idempotent. }
    procedure Close;
  end;

const
  { The instruction that turns the current conversation into a checkpoint. The
    checkpoint is an ordinary turn: the runtime queues this as an ambient message
    and runs an ambient turn; the assistant's reply is the document. }
  CheckpointInstruction =
    'Write a checkpoint document so another agent can continue this work with no ' +
    'other context. Be concise but complete. Cover, as headed sections: ' +
    '(1) Objective - what we are doing and why; ' +
    '(2) Decisions - each decision and its rationale; ' +
    '(3) State - what is done, in progress, and uncommitted; ' +
    '(4) Gotchas - pitfalls, constraints, and things that bit us; ' +
    '(5) Open threads - what to do next. Write it as the document itself, ' +
    'not as commentary about it.';

implementation

destructor THarnessSession.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure THarnessSession.Close;
begin
  FLoop.Free;
  FLoop := nil;
  FMcp.Free;
  FMcp := nil;
  FMcpTokenProviders.Free;
  FMcpTokenProviders := nil;
  { The registry is freed by refcount: the loop's ref is gone (FLoop.Free above);
    drop our owning ref last. Never Free it directly (double-free). }
  FSkills := nil;
  FSkillsKeep := nil;
  FCommandTool.Free;
  FCommandTool := nil;
  FFileTool.Free;
  FFileTool := nil;
  FRecallTool.Free;
  FRecallTool := nil;
  FTools.Free;
  FTools := nil;
  FClient.Free;
  FClient := nil;
  FConversation := nil;
  FView.Free;
  FView := nil;
  FGate.Free;
  FGate := nil;
  FQueue.Free;
  FQueue := nil;
  FTurnPool := nil;
end;

class function THarnessSession.Open(const AConfig: THarnessSessionConfig;
  out AError: string): THarnessSession;
var
  Session: THarnessSession;
begin
  Result := nil;
  AError := '';
  Session := THarnessSession.Create;
  try
    if not Session.Init(AConfig, AError) then
    begin
      Session.Free;
      Exit(nil);
    end;
  except
    on E: Exception do
    begin
      Session.Free;
      AError := E.Message;
      Exit(nil);
    end;
  end;
  Result := Session;
end;

procedure THarnessSession.McpEvent(const AMessage, ADetail: string);
begin
  if FConversation <> nil then
    FConversation.AppendError(AMessage, ADetail);
end;

function THarnessSession.McpTokenSourceFor(
  const AServer: TMcpServerConfig): TMcpTokenSource;
var
  Row: TOAuthTokenRow;
  StoreErr: TStoreError;
  Provider: TOAuthTokenProvider;
begin
  Result := nil;
  if (AServer.Transport <> mtHttp) or (FView = nil) or (FView.Store = nil) then
    Exit;
  if not FView.Store.LoadOAuthToken(AServer.Scope, FView.WorkspaceId,
    AServer.Name, Row, StoreErr) then
    Exit;   { no stored token: fall back to static headers / none }
  Provider := TOAuthTokenProvider.Create(FView.Store, AServer.Scope,
    FView.WorkspaceId, AServer.Name, AServer.Url);
  FMcpTokenProviders.Add(Provider);
  Result := Provider.GetToken;
end;

function THarnessSession.McpConfigSource: TMcpConfig;
var
  Ctx: TMcpConfigContext;
  Rows: TMcpServerRowArray;
  StoreErr: TStoreError;
begin
  Result := Default(TMcpConfig);
  if (FView = nil) or (FView.Store = nil) then
    Exit;
  Ctx := Default(TMcpConfigContext);
  Ctx.WorkspaceId := FView.WorkspaceId;
  Result.Context := Ctx;
  Rows := nil;
  if FView.Store.LoadMcpServers(Ctx, Rows, StoreErr) then
    Result.Servers := ResolveMcpConfig(Rows, Ctx);
end;

procedure THarnessSession.ReconcileMcpSkills;
var
  Cfg: TMcpConfig;
  I, J: Integer;
  Key: string;
  Present: Boolean;
  Keys: TStringArray;
begin
  if (FSkills = nil) or (FMcp = nil) then
    Exit;
  Cfg := McpConfigSource;
  { Reconcile the manager's runtime set from the config first (lazy: it adds or
    drops runtimes but does not connect). This is what lets a server added after
    open be loadable. }
  FMcp.Reconcile(Cfg);
  { Remove MCP skills whose server is gone or disabled. }
  Keys := FSkills.Keys;
  for I := 0 to High(Keys) do
  begin
    Key := Keys[I];
    if Copy(Key, 1, 4) <> 'mcp_' then
      Continue;
    Present := False;
    for J := 0 to High(Cfg.Servers) do
      if McpSkillKey(Cfg.Servers[J].Name) = Key then
      begin
        Present := True;
        Break;
      end;
    if not Present then
      FSkills.Remove(Key);
  end;
  { Declare/replace a skill per configured server (no connect). }
  RegisterMcpSkills(FSkills, Cfg, FMcp);
end;

function THarnessSession.Init(const AConfig: THarnessSessionConfig;
  out AError: string): Boolean;
var
  EnvValue: string;
  LlmConfig: TLLMConfig;
  ApprovalStore: IApprovalStore;
  ApprovalService: IApprovalService;
  ApprovalCtx: TApprovalContext;
  ToolConfig: TCommandToolConfig;
  FileConfig: TFileToolConfig;
  AgentConfig: TAgentConfig;
  Conv: TSqliteConversationStore;
  McpCfg: TMcpConfig;
  Cap: Integer;
begin
  Result := False;

  { The view loads .env, opens the workspace/store, and resolves the session. }
  FView := TSessionView.Open(AConfig, AError);
  if FView = nil then
    Exit;

  Cap := ResolveToolResultCap(AConfig.ToolResultCap);

  LlmConfig := Default(TLLMConfig);
  LlmConfig := ResolveLLMConfig(LlmConfig);
  if AConfig.Model <> '' then
    LlmConfig.Model := AConfig.Model;
  if AConfig.Endpoint <> '' then
    LlmConfig.Endpoint := AConfig.Endpoint;
  FClient := TLLMClient.Create(LlmConfig, AConfig.Transport);

  FTools := TToolRegistry.Create;
  RegisterDefaultTools(FTools);

  { A store enables persistence and durable approvals; without one, approvals
    are session-only (in memory) and nothing is written. }
  if FView.Store <> nil then
  begin
    ApprovalStore := TStoreApprovalStore.Create(FView.Store);
    Conv := TSqliteConversationStore.Create(FView.Store, FView.SessionId, 0);
    Conv.ToolResultCap := Cap;
    FConversation := Conv;
  end
  else
  begin
    ApprovalStore := TMemoryApprovalStore.Create;
    FConversation := TMemoryConversationStore.Create;
  end;

  FQueue := TTurnQueue.Create;
  { The shared turn pool. Two workers so a turn blocked on an approval (or on
    the provider) never starves the next turn, and so a cancel of one turn can
    be processed while another runs. }
  FTurnPool := TExecutorScheduler.Create(2);
  { Bound the approval wait: an approval no client answers within the timeout is
    denied, so a disconnected driver never blocks the turn forever. }
  FGate := TApprovalGate.Create(FQueue, DefaultApprovalTimeoutMs);

  ApprovalCtx.WorkspaceId := FView.WorkspaceId;
  { A subagent resolves approvals against its lineage root, so the whole
    lineage shares one session scope. }
  if AConfig.ApprovalRootSessionId <> '' then
    ApprovalCtx.SessionId := AConfig.ApprovalRootSessionId
  else
    ApprovalCtx.SessionId := FView.SessionId;
  ApprovalService := TApprovalService.Create(ApprovalStore, FGate.Prompt,
    ApprovalCtx);
  FApprovalService := ApprovalService;
  ToolConfig := Default(TCommandToolConfig);
  ToolConfig.Shell := DefaultShellProfile;
  ToolConfig.DefaultCwd := FView.WorkspaceRoot;
  { Optional cap on the model's run_command timeout (ms); unset = the model
    defines its own. }
  EnvValue := GetEnvironmentVariable('HILDEGARD_COMMAND_TIMEOUT_MS');
  if EnvValue <> '' then
    ToolConfig.MaxTimeoutMs := StrToInt64Def(EnvValue, 0);
  FCommandTool := TCommandTool.Create(ToolConfig, ApprovalService);
  FCommandTool.Register(FTools);

  FileConfig := Default(TFileToolConfig);
  FileConfig.Root := FView.WorkspaceRoot;
  FFileTool := TFileTool.Create(FileConfig, ApprovalService);
  FFileTool.Register(FTools);

  { The recall tool reads stored artifacts; without a store there are none. }
  if FView.Store <> nil then
  begin
    FRecallTool := TRecallTool.Create(FView.Store, FView.SessionId, Cap);
    FRecallTool.Register(FTools);
  end;

  { MCP servers: effective config comes from the store (scoped), resolved for
    this workspace. The manager is created LAZY (no connect on startup), so the
    runtime's socket binds without touching a server; each enabled server becomes
    a skill, and a load_skill connects it. Only with a store; without one there
    is nowhere to read config from. }
  if FView.Store <> nil then
  begin
    McpCfg := McpConfigSource;
    FMcpTokenProviders := TObjectList.Create(True);
    FMcp := TMcpManager.Create(McpCfg, ApprovalService, McpEvent,
      McpTokenSourceFor);
    FMcp.Lazy := True;
  end;

  AgentConfig := Default(TAgentConfig);
  AgentConfig.SystemPrompt := AConfig.SystemPrompt;
  if AgentConfig.SystemPrompt = '' then
    AgentConfig.SystemPrompt := GetEnvironmentVariable('HILDEGARD_SYSTEM_PROMPT');
  if AgentConfig.SystemPrompt = '' then
    AgentConfig.SystemPrompt := DefaultSystemPrompt;
  { The tool-call budget keeps its agent default; the context cap comes from the
    view (which resolved the config, env, or the default). }
  AgentConfig.MaxContextTokens := FView.MaxContextTokens;

  FLoop := TAgentLoop.Create(FClient, FConversation, FTools, AgentConfig);
  { The skill registry is the capability layer; register it as the provider. Its
    load_skill is offered once any skill is declared. Empty by default. }
  FSkills := TSkillRegistry.Create;
  FSkillsKeep := FSkills;   // owning interface ref
  FLoop.AddProvider(FSkillsKeep);
  { Lazy MCP: each configured server is a skill (declared, not connected). A
    load_skill connects it. Re-declared at each turn boundary so an add/enable/
    remove is picked up without a restart. }
  if FMcp <> nil then
  begin
    ReconcileMcpSkills;
    FLoop.OnTurnStart := ReconcileMcpSkills;
  end;
  Result := True;
end;

end.
