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
  Classes, SysUtils,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.approval.store, hildegard.helper.command.tool,
  hildegard.helper.files,
  hildegard.helper.session, hildegard.helper.session.store,
  hildegard.helper.recall.tool, hildegard.helper.harness.turn,
  hildegard.helper.harness.view;

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
    FLoop: TAgentLoop;
    FQueue: TTurnQueue;
    FGate: TApprovalGate;
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

    { Cancel pending approvals; frees owned objects. Idempotent. }
    procedure Close;
  end;

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
  FGate := TApprovalGate.Create(FQueue);

  ApprovalCtx.WorkspaceId := FView.WorkspaceId;
  ApprovalCtx.SessionId := FView.SessionId;
  ApprovalService := TApprovalService.Create(ApprovalStore, FGate.Prompt,
    ApprovalCtx);
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
  Result := True;
end;

end.
