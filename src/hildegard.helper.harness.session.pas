unit hildegard.helper.harness.session;
{ Owns the agent-side object graph for one TUI run: workspace, optional SQLite
  store, conversation store, LLM client, tool registry (builtins plus gated
  run_command), approval service, the turn queue/gate, and the agent loop. This
  is the same bootstrap examples/agent_cli.pas performs, extracted so the CLI and
  the TUI do not drift. It knows nothing about widgets or terminals. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.approval.store, hildegard.helper.command.tool,
  hildegard.helper.files,
  hildegard.helper.workspace, hildegard.helper.store,
  hildegard.helper.session.store, hildegard.helper.harness.turn;

type
  THarnessSessionConfig = record
    WorkspacePath: string;        // '' => process working directory
    StorePath: string;            // '' => in-memory, no persistence
    SessionId: string;            // '' => create new (store) or ephemeral
    Resume: Boolean;              // SessionId = '' => most recent; else exists
    Model: string;                // '' => resolved from env/.env
    Endpoint: string;             // '' => resolved from env/.env
    SystemPrompt: string;         // '' => env HILDEGARD_SYSTEM_PROMPT, else default
    MaxToolIterations: Integer;   // 0 => DefaultMaxToolIterations
    { Optional test seam: when set, the client uses this transport instead of
      the real HTTP transport. }
    Transport: TLLMTransport;
  end;

  { Not thread-safe except that Queue/Gate are safe across the worker/UI
    boundary. Call Close (or Free) to release everything. }
  THarnessSession = class
  private
    FWorkspace: TWorkspace;
    FStore: TSqliteStore;
    FConversation: IConversationStore;
    FClient: TLLMClient;
    FTools: TToolRegistry;
    FCommandTool: TCommandTool;
    FFileTool: TFileTool;
    FLoop: TAgentLoop;
    FQueue: TTurnQueue;
    FGate: TApprovalGate;
    FSessionId: string;
    FWorkspaceRoot: string;
    FHistory: TChatMessageArray;
    function Init(const AConfig: THarnessSessionConfig; out AError: string):
      Boolean;
  public
    { Resolves config, opens the workspace and optional store, ensures the
      workspace and session, builds the tools/approvals/loop. Returns nil with
      AError on failure. }
    class function Open(const AConfig: THarnessSessionConfig;
      out AError: string): THarnessSession;
    destructor Destroy; override;

    property Loop: TAgentLoop read FLoop;
    property Tools: TToolRegistry read FTools;
    property Queue: TTurnQueue read FQueue;
    property Gate: TApprovalGate read FGate;
    property SessionId: string read FSessionId;
    property WorkspaceRoot: string read FWorkspaceRoot;
    property Store: TSqliteStore read FStore;   // nil when unconfigured

    { Prior messages for the initial render (empty for a new session). }
    function History: TChatMessageArray;

    { Cancel pending approvals; frees owned objects. Idempotent. }
    procedure Close;
  end;

implementation

uses
  hildegard.helper.env;

const
  DefaultStoreBusyTimeoutMs = 5000;

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
  FTools.Free;
  FTools := nil;
  FClient.Free;
  FClient := nil;
  FConversation := nil;
  FStore.Free;
  FStore := nil;
  FWorkspace.Free;
  FWorkspace := nil;
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
  Path, Err: string;
  LlmConfig: TLLMConfig;
  StoreConfig: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  ApprovalStore: IApprovalStore;
  ApprovalService: IApprovalService;
  ApprovalCtx: TApprovalContext;
  ToolConfig: TCommandToolConfig;
  FileConfig: TFileToolConfig;
  AgentConfig: TAgentConfig;
begin
  Result := False;
  LoadDotEnvFile('.env');            // optional; shell env wins

  Path := AConfig.WorkspacePath;
  if Path = '' then
    Path := GetEnvironmentVariable('HILDEGARD_WORKSPACE');
  FWorkspace := TWorkspace.Open(Path, Err);
  if FWorkspace = nil then
  begin
    AError := 'workspace: ' + Err;
    Exit;
  end;
  FWorkspaceRoot := FWorkspace.Root;

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
  FStore := nil;
  WorkspaceId := 0;
  FSessionId := AConfig.SessionId;
  if AConfig.StorePath <> '' then
  begin
    ForceDirectories(ExtractFileDir(AConfig.StorePath));
    StoreConfig := Default(TStoreConfig);
    StoreConfig.DatabasePath := AConfig.StorePath;
    StoreConfig.BusyTimeoutMs := DefaultStoreBusyTimeoutMs;
    FStore := TSqliteStore.Create(StoreConfig);
    if not FStore.Open(StoreErr) then
    begin
      AError := 'could not open store: ' + StoreErr.Message;
      Exit;
    end;
    if not FStore.EnsureWorkspace(FWorkspaceRoot, WorkspaceId, StoreErr) then
    begin
      AError := 'workspace: ' + StoreErr.Message;
      Exit;
    end;
    if FSessionId = '' then
    begin
      if AConfig.Resume then
      begin
        if not FStore.MostRecentSessionId(WorkspaceId, FSessionId, StoreErr) then
        begin
          AError := 'no session to resume for ' + FWorkspaceRoot;
          Exit;
        end;
      end
      else if not FStore.CreateSession(WorkspaceId, FSessionId, StoreErr) then
      begin
        AError := 'could not create session: ' + StoreErr.Message;
        Exit;
      end;
    end
    else if not FStore.SessionExists(FSessionId, StoreErr) then
    begin
      AError := 'unknown session: ' + FSessionId;
      Exit;
    end;
    ApprovalStore := TStoreApprovalStore.Create(FStore);
    FConversation := TSqliteConversationStore.Create(FStore, FSessionId, 0);
  end
  else
  begin
    ApprovalStore := TMemoryApprovalStore.Create;
    FConversation := TMemoryConversationStore.Create;
  end;

  FHistory := FConversation.Messages;
  FQueue := TTurnQueue.Create;
  FGate := TApprovalGate.Create(FQueue);

  ApprovalCtx.WorkspaceId := WorkspaceId;
  ApprovalCtx.SessionId := FSessionId;
  ApprovalService := TApprovalService.Create(ApprovalStore, FGate.Prompt,
    ApprovalCtx);
  ToolConfig := Default(TCommandToolConfig);
  ToolConfig.Shell := DefaultShellProfile;
  ToolConfig.DefaultCwd := FWorkspaceRoot;
  FCommandTool := TCommandTool.Create(ToolConfig, ApprovalService);
  FCommandTool.Register(FTools);

  FileConfig := Default(TFileToolConfig);
  FileConfig.Root := FWorkspaceRoot;
  FFileTool := TFileTool.Create(FileConfig, ApprovalService);
  FFileTool.Register(FTools);

  AgentConfig := Default(TAgentConfig);
  AgentConfig.SystemPrompt := AConfig.SystemPrompt;
  if AgentConfig.SystemPrompt = '' then
    AgentConfig.SystemPrompt := GetEnvironmentVariable('HILDEGARD_SYSTEM_PROMPT');
  if AgentConfig.SystemPrompt = '' then
    AgentConfig.SystemPrompt := DefaultSystemPrompt;
  AgentConfig.MaxToolIterations := AConfig.MaxToolIterations;
  if AgentConfig.MaxToolIterations <= 0 then
    AgentConfig.MaxToolIterations := DefaultMaxToolIterations;

  FLoop := TAgentLoop.Create(FClient, FConversation, FTools, AgentConfig);
  Result := True;
end;

function THarnessSession.History: TChatMessageArray;
begin
  Result := FHistory;
end;

end.
