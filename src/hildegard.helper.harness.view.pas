unit hildegard.helper.harness.view;
{ A read-only view of one session: the workspace, the optional SQLite store, the
  session identity, and its history and metrics. No loop, no LLM client, and no
  tools, so a UI client can depend on it without linking the agent. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  hildegard.helper.llm, hildegard.helper.workspace, hildegard.helper.store,
  hildegard.helper.session;

type
  THarnessSessionConfig = record
    WorkspacePath: string;        // '' => process working directory
    StorePath: string;            // '' => in-memory, no persistence
    SessionId: string;            // '' => create new (store) or ephemeral
    Resume: Boolean;              // SessionId = '' => most recent; else exists
    Model: string;                // '' => resolved from env/.env
    Endpoint: string;             // '' => resolved from env/.env
    { Bytes a tool result may contribute to the prompt; 0 => default, negative
      => uncapped. Loop-only: the view ignores it. }
    ToolResultCap: Integer;
    { Overrides the loop's context guard; 0 => HILDEGARD_MAX_CONTEXT_TOKENS,
      else the default. The limit is a model property, so it is overridable
      until it can be pulled from the model API. }
    MaxContextTokens: Integer;
    { Loop-only: the system prompt override. The view ignores it. }
    SystemPrompt: string;
    { Loop-only test seam: when set, the loop's client uses this transport. }
    Transport: TLLMTransport;
  end;

  { A session's workspace, store, identity, history, and metrics. Not
    thread-safe; call Close (or Free) to release everything. }
  TSessionView = class
  private
    FWorkspace: TWorkspace;
    FStore: TSqliteStore;
    FSessionId: string;
    FWorkspaceId: Integer;
    FWorkspaceRoot: string;
    FModel: string;
    FMaxContextTokens: Integer;
    function Init(const AConfig: THarnessSessionConfig; out AError: string):
      Boolean;
  public
    { Resolves config, opens the workspace and optional store, and ensures the
      workspace and session. Returns nil with AError on failure. }
    class function Open(const AConfig: THarnessSessionConfig;
      out AError: string): TSessionView;
    destructor Destroy; override;

    property SessionId: string read FSessionId;
    { The store's workspace row id; 0 when there is no store. }
    property WorkspaceId: Integer read FWorkspaceId;
    property WorkspaceRoot: string read FWorkspaceRoot;
    { The model the session is configured with, for the UI. }
    property Model: string read FModel;
    { The context guard in effect: the config, else `HILDEGARD_MAX_CONTEXT_TOKENS`,
      else the default. }
    property MaxContextTokens: Integer read FMaxContextTokens;
    property Store: TSqliteStore read FStore;   // nil when unconfigured

    { Prior message blocks, read from the store on demand (empty for a new
      session or an unconfigured store). }
    function History: TMessageRecordArray;

    { The latest turn's metrics for the status bar; a zero record when the
      session has no store or no turns. }
    function LastTurn: TTurnRecord;

    { The session's cumulative metrics over every turn; a zero record when the
      session has no store. }
    function SessionTotals: TTurnRecord;

    { Every turn, ordered, for restoring the per-loop dividers; empty when the
      session has no store. }
    function Turns: TTurnRecordArray;

    { Frees owned objects. Idempotent. }
    procedure Close;
  end;

implementation

uses
  hildegard.helper.env;

const
  DefaultStoreBusyTimeoutMs = 5000;

destructor TSessionView.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TSessionView.Close;
begin
  FStore.Free;
  FStore := nil;
  FWorkspace.Free;
  FWorkspace := nil;
end;

class function TSessionView.Open(const AConfig: THarnessSessionConfig;
  out AError: string): TSessionView;
var
  View: TSessionView;
begin
  Result := nil;
  AError := '';
  View := TSessionView.Create;
  try
    if not View.Init(AConfig, AError) then
    begin
      View.Free;
      Exit(nil);
    end;
  except
    on E: Exception do
    begin
      View.Free;
      AError := E.Message;
      Exit(nil);
    end;
  end;
  Result := View;
end;

function TSessionView.Init(const AConfig: THarnessSessionConfig;
  out AError: string): Boolean;
var
  Path, Err, EnvValue: string;
  LlmConfig: TLLMConfig;
  StoreConfig: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
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
  FModel := AConfig.Model;
  { The context guard is a model property the app does not know yet: the config,
    else an env var, else the default, until the model API supplies it. }
  FMaxContextTokens := AConfig.MaxContextTokens;
  if FMaxContextTokens = 0 then
  begin
    EnvValue := GetEnvironmentVariable('HILDEGARD_MAX_CONTEXT_TOKENS');
    if EnvValue <> '' then
      FMaxContextTokens := StrToIntDef(EnvValue, 0);
  end;
  if FMaxContextTokens = 0 then
    FMaxContextTokens := DefaultMaxContextTokens;

  { Resolve the model name for display only; the loop builds the real client. }
  LlmConfig := Default(TLLMConfig);
  LlmConfig := ResolveLLMConfig(LlmConfig);
  if AConfig.Model <> '' then
    LlmConfig.Model := AConfig.Model;
  if AConfig.Endpoint <> '' then
    LlmConfig.Endpoint := AConfig.Endpoint;
  if FModel = '' then
    FModel := LlmConfig.Model;

  { A store enables persistence and durable approvals; without one, the session
    is ephemeral and nothing is written. }
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
    FWorkspaceId := WorkspaceId;
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
  end;
  Result := True;
end;

function TSessionView.History: TMessageRecordArray;
var
  Err: TStoreError;
begin
  Result := nil;
  if (FStore <> nil) and (FSessionId <> '') then
    FStore.QueryMessages(FSessionId, Result, Err);
end;

function TSessionView.LastTurn: TTurnRecord;
var
  Err: TStoreError;
begin
  Result := Default(TTurnRecord);
  if (FStore <> nil) and (FSessionId <> '') then
    FStore.MostRecentTurn(FSessionId, Result, Err);
end;

function TSessionView.SessionTotals: TTurnRecord;
var
  Err: TStoreError;
begin
  Result := Default(TTurnRecord);
  if (FStore <> nil) and (FSessionId <> '') then
    FStore.SessionTotals(FSessionId, Result, Err);
end;

function TSessionView.Turns: TTurnRecordArray;
var
  Err: TStoreError;
begin
  Result := nil;
  if (FStore <> nil) and (FSessionId <> '') then
    FStore.QueryTurns(FSessionId, Result, Err);
end;

end.
