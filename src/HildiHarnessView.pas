unit HildiHarnessView;
{ A read-only view of one session: the workspace, the optional SQLite store, the
  session identity, and its history and metrics. No loop, no LLM client, and no
  tools, so a UI client can depend on it without linking the agent. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  HildiLLM, HildiWorkspace, HildiStore,
  HildiSession;

type
  THarnessSessionConfig = record
    WorkspacePath: string;        // '' => process working directory
    StorePath: string;            // '' => in-memory, no persistence
    SessionId: string;            // '' => create new (store) or ephemeral
    Resume: Boolean;              // SessionId = '' => most recent; else exists
    { Defer creating the session until EnsureSession is called. When set and
      SessionId = '' and not Resume, Init opens the workspace and store but
      creates no session row, so a launcher can paint before committing to a
      session. EnsureSession then creates it on demand. }
    LazySession: Boolean;
    Model: string;                // '' => resolved from env/.env
    Endpoint: string;             // '' => resolved from env/.env
    { Bytes a tool result may contribute to the prompt; 0 => default, negative
      => uncapped. Loop-only: the view ignores it. }
    ToolResultCap: Integer;
    { Overrides the loop's context guard; 0 => HILDI_MAX_CONTEXT_TOKENS,
      else the default. The limit is a model property, so it is overridable
      until it can be pulled from the model API. }
    MaxContextTokens: Integer;
    { Loop-only: the system prompt override. The view ignores it. }
    SystemPrompt: string;
    { Loop-only: transient-failure retry attempts (0 => the loop default,
      negative => disabled). The view ignores it. }
    RetryMaxAttempts: Integer;
    { The session whose approval scope this session resolves against. A subagent
      sets this to its lineage root (the parent), so approvals are lineage-wide:
      a grant made for one child is in force for the parent and every sibling.
      '' => the session's own id. }
    ApprovalRootSessionId: string;
    { How long a client has to answer an approval ask before it is auto-denied;
      0 => wait indefinitely (a connected client owns the timeout, not the
      session). Loop-only. }
    ApprovalTimeoutMs: Integer;
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
    { True once a session id exists (eager, resumed, or created lazily). }
    function HasSession: Boolean;
    { Create the session if one is not yet set (the lazy path); a no-op when a
      session already exists, when there is no store, or when the id was named.
      False + AError on a store failure. }
    function EnsureSession(out AError: string): Boolean;
    { The store's workspace row id; 0 when there is no store. }
    property WorkspaceId: Integer read FWorkspaceId;
    property WorkspaceRoot: string read FWorkspaceRoot;
    { The model the session is configured with, for the UI. }
    property Model: string read FModel;
    { The context guard in effect: the config, else `HILDI_MAX_CONTEXT_TOKENS`,
      else the default. }
    property MaxContextTokens: Integer read FMaxContextTokens;
    property Store: TSqliteStore read FStore;   // nil when unconfigured

    { Prior message blocks, read from the store on demand (empty for a new
      session or an unconfigured store). }
    function History: TMessageRecordArray;

    { The last AMax messages of the active window (oldest first), for the first
      frame. Bounded, so the first paint does not read the whole session. }
    function HistoryTail(AMax: Integer): TMessageRecordArray;
    { The page strictly before ABeforeSeq: the last AMax messages with
      seq < ABeforeSeq (oldest first). Empty when nothing precedes it. }
    function HistoryPage(ABeforeSeq: Int64; AMax: Integer): TMessageRecordArray;
    { The session's total message count, for the virtual scroll extent. 0 for an
      ephemeral or empty session. }
    function MessageCount: Integer;

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
  HildiEnv;

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

function TSessionView.HasSession: Boolean;
begin
  Result := FSessionId <> '';
end;

function TSessionView.EnsureSession(out AError: string): Boolean;
var
  StoreErr: TStoreError;
begin
  AError := '';
  { Nothing to do when a session already exists, or there is no store to create
    one in (an ephemeral, in-memory session needs no id). }
  if FSessionId <> '' then
    Exit(True);
  if FStore = nil then
    Exit(True);
  if not FStore.CreateSession(FWorkspaceId, FSessionId, StoreErr) then
  begin
    AError := 'could not create session: ' + StoreErr.Message;
    Exit(False);
  end;
  Result := True;
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
    Path := GetEnvironmentVariable('HILDI_WORKSPACE');
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
    EnvValue := GetEnvironmentVariable('HILDI_MAX_CONTEXT_TOKENS');
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
      else if not AConfig.LazySession then
      begin
        { Eager (the default): create the session now. Lazy: defer to
          EnsureSession, so a launcher paints before committing. }
        if not FStore.CreateSession(WorkspaceId, FSessionId, StoreErr) then
        begin
          AError := 'could not create session: ' + StoreErr.Message;
          Exit;
        end;
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
    FStore.QueryActiveMessages(FSessionId, Result, Err);
end;

function TSessionView.HistoryTail(AMax: Integer): TMessageRecordArray;
var
  Err: TStoreError;
begin
  Result := nil;
  if (FStore <> nil) and (FSessionId <> '') then
    FStore.QueryActiveMessagesTail(FSessionId, AMax, Result, Err);
end;

function TSessionView.HistoryPage(ABeforeSeq: Int64;
  AMax: Integer): TMessageRecordArray;
var
  Err: TStoreError;
begin
  Result := nil;
  if (FStore <> nil) and (FSessionId <> '') then
    FStore.QueryMessagesBefore(FSessionId, ABeforeSeq - 1, AMax, Result, Err);
end;

function TSessionView.MessageCount: Integer;
var
  Err: TStoreError;
begin
  Result := 0;
  if (FStore <> nil) and (FSessionId <> '') then
    FStore.MessageCount(FSessionId, Result, Err);
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
