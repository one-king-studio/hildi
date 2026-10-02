unit hildegard.helper.store;
{ Embedded SQLite persistence for the helper, built directly on the static
  hildegard.helper.sqlite binding (no SQLDB, no runtime library loading). Owns
  one database file and exposes typed operations for credentials, settings,
  workspaces, approvals, and sessions/ledger. SQL, schema, migrations, and
  thread serialization stay behind this unit.

  Implementation notes:
    * One connection is serialized by one critical section (single store per
      process). SQLite is opened with the default thread mode.
    * WAL and foreign_keys are set with PRAGMA statements after opening; there
      is no SQLDB implicit transaction to fight. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  hildegard.helper.sqlite, hildegard.helper.approval, hildegard.helper.llm,
  hildegard.helper.session;

type
  { Stable error codes. seOk is success. }
  TStoreErrorCode = (
    seOk,
    seCannotOpen,
    seNotOpen,
    seMigrationFailed,
    seNotFound,
    seConstraint,
    seInvalidArgument,
    seError
  );

  TStoreError = record
    Code: TStoreErrorCode;
    Message: string;
    Detail: string;
  end;

  TStoreConfig = record
    DatabasePath: string;
    BusyTimeoutMs: Integer;
  end;

  TDeviceCredentials = record
    DeviceId: string;
    Token: string;
    Endpoint: string;
    AccountId: string;
  end;

  TMigration = record
    Version: Integer;
    Name: string;
    Statements: array of string;
  end;

  TMigrationArray = array of TMigration;

  TSqliteStore = class
  private
    FConfig: TStoreConfig;
    FLock: TCriticalSection;
    FDb: Psqlite3;
    FOpen: Boolean;
    FMigrations: TMigrationArray;
    function Fail(out AError: TStoreError; ACode: TStoreErrorCode;
      const AMessage, ADetail: string): Boolean;
    function EnsureOpen(out AError: TStoreError): Boolean;
    function DoExec(const ASQL: string; out AError: TStoreError): Boolean;
    function ApplyMigrations(out AError: TStoreError): Boolean;
    function ReadUserVersion(out AVersion: Integer;
      out AError: TStoreError): Boolean;
    function DbErrorText: string;
  public
    constructor Create(const AConfig: TStoreConfig); overload;
    constructor Create(const AConfig: TStoreConfig;
      const AMigrations: TMigrationArray); overload;
    destructor Destroy; override;

    function Open(out AError: TStoreError): Boolean;
    procedure Close;
    function IsOpen: Boolean;

    function SaveCredentials(const AValue: TDeviceCredentials;
      out AError: TStoreError): Boolean;
    function LoadCredentials(out AValue: TDeviceCredentials;
      out AError: TStoreError): Boolean;
    function ClearCredentials(out AError: TStoreError): Boolean;

    function SetSetting(const AKey, AValue: string;
      out AError: TStoreError): Boolean;
    function GetSetting(const AKey: string; out AValue: string;
      out AError: TStoreError): Boolean;
    function DeleteSetting(const AKey: string;
      out AError: TStoreError): Boolean;

    { Returns the id for a canonical workspace path, inserting it if new. }
    function EnsureWorkspace(const APath: string; out AId: Integer;
      out AError: TStoreError): Boolean;
    { Looks up a workspace by canonical path; seNotFound if absent. }
    function FindWorkspace(const APath: string; out AId: Integer;
      out AError: TStoreError): Boolean;

    { Approval rules relevant to a context (global + workspace + session). }
    function LoadApprovals(const AContext: TApprovalContext;
      out ARules: TApprovalRuleArray; out AError: TStoreError): Boolean;
    { Inserts a rule, ignoring an exact duplicate. }
    function SaveApproval(const ARule: TApprovalRule;
      out AError: TStoreError): Boolean;
    function RemoveApproval(const ARule: TApprovalRule;
      out AError: TStoreError): Boolean;

    { Creates a session bound to a workspace and returns its 32-hex id. }
    function CreateSession(AWorkspaceId: Integer; out AId: string;
      out AError: TStoreError): Boolean;
    function SessionExists(const AId: string;
      out AError: TStoreError): Boolean;
    function TouchSession(const AId: string;
      out AError: TStoreError): Boolean;
    { Sessions for a workspace, newest updated first. }
    function ListSessions(AWorkspaceId: Integer;
      out AList: TSessionSummaryArray; out AError: TStoreError): Boolean;
    { The most recently updated session for a workspace; seNotFound if none. }
    function MostRecentSessionId(AWorkspaceId: Integer; out AId: string;
      out AError: TStoreError): Boolean;

    { Opens a turn (loop) for a session, assigning its per-session sequence. }
    function BeginTurn(const ASessionId: string; out ATurnId: Int64;
      out AError: TStoreError): Boolean;
    { Closes a turn and rolls its requests' metrics up onto it. }
    function FinishTurn(ATurnId: Int64; AStatus: TTurnStatus;
      const AFinishReason: string; AErrorCode: Integer;
      const AErrorMessage, AErrorDetail: string;
      out AError: TStoreError): Boolean;
    function QueryTurns(const ASessionId: string; out ATurns: TTurnRecordArray;
      out AError: TStoreError): Boolean;

    { Opens an LLM request within a turn, assigning its per-turn sequence. }
    function BeginRequest(ATurnId: Int64; const AModel: string;
      AMessageCount: Integer; out ARequestId: Int64;
      out AError: TStoreError): Boolean;
    function FinishRequest(ARequestId: Int64; AOk: Boolean;
      const AFinishReason: string; AErrorCode: Integer;
      const AErrorMessage, AErrorDetail: string; const AUsage: TTokenUsage;
      ADurationMs, AFirstTokenMs: Int64; out AError: TStoreError): Boolean;
    function QueryRequests(ATurnId: Int64; out ARequests: TRequestRecordArray;
      out AError: TStoreError): Boolean;

    { Appends one history block, assigning its per-session sequence. }
    function AppendMessage(const AMessage: TMessageRecord;
      out AError: TStoreError): Boolean;
    function QueryMessages(const ASessionId: string;
      out AMessages: TMessageRecordArray; out AError: TStoreError): Boolean;
  end;

function StoreSchemaVersion: Integer;
function DefaultMigrations: TMigrationArray;

implementation

uses
  {$ifdef unix}BaseUnix,{$endif}
  fpjson, jsonparser;

const
  DefaultBusyTimeoutMs = 5000;

function NowMs: Int64;
begin
  Result := Trunc((Now - EncodeDate(1970, 1, 1)) * MSecsPerDay);
end;

function OkError: TStoreError;
begin
  Result.Code := seOk;
  Result.Message := '';
  Result.Detail := '';
end;

function AsUtf8(const AValue: string): AnsiString;
begin
  Result := AnsiString(AValue);
end;

{ --- migrations --------------------------------------------------------- }

function DefaultMigrations: TMigrationArray;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0].Version := 1;
  Result[0].Name := 'session history';
  Result[0].Statements := [
    'CREATE TABLE credentials (' +
      'id INTEGER PRIMARY KEY CHECK (id = 1), ' +
      'device_id TEXT NOT NULL, ' +
      'token TEXT NOT NULL, ' +
      'endpoint TEXT NOT NULL, ' +
      'account_id TEXT NOT NULL)',
    'CREATE TABLE settings (' +
      'key TEXT PRIMARY KEY, ' +
      'value TEXT NOT NULL)',
    'CREATE TABLE workspaces (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'path TEXT NOT NULL UNIQUE, ' +
      'created_at INTEGER NOT NULL)',
    'CREATE TABLE approvals (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'effect INTEGER NOT NULL, ' +
      'scope INTEGER NOT NULL, ' +
      'workspace_id INTEGER NOT NULL DEFAULT 0, ' +
      'session_id TEXT NOT NULL DEFAULT '''', ' +
      'ref TEXT NOT NULL, ' +
      'params TEXT NOT NULL DEFAULT ''[]'', ' +
      'any_params INTEGER NOT NULL DEFAULT 0, ' +
      'created_at INTEGER NOT NULL, ' +
      'UNIQUE (effect, scope, workspace_id, session_id, ref, params, ' +
      'any_params))',
    'CREATE INDEX idx_approvals_scope ON approvals (scope, workspace_id, ' +
      'session_id)',
    'CREATE TABLE sessions (' +
      'id TEXT PRIMARY KEY, ' +
      'workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ' +
      'ON DELETE CASCADE, ' +
      'created_at INTEGER NOT NULL, ' +
      'updated_at INTEGER NOT NULL)',
    'CREATE TABLE turns (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, ' +
      'seq INTEGER NOT NULL, ' +
      'status INTEGER NOT NULL, ' +
      'finish_reason TEXT NOT NULL DEFAULT '''', ' +
      'error_code INTEGER NOT NULL DEFAULT 0, ' +
      'error_message TEXT NOT NULL DEFAULT '''', ' +
      'error_detail TEXT NOT NULL DEFAULT '''', ' +
      'request_count INTEGER NOT NULL DEFAULT 0, ' +
      'message_count INTEGER NOT NULL DEFAULT 0, ' +
      'prompt_tokens INTEGER NOT NULL DEFAULT 0, ' +
      'completion_tokens INTEGER NOT NULL DEFAULT 0, ' +
      'total_tokens INTEGER NOT NULL DEFAULT 0, ' +
      'cached_tokens INTEGER NOT NULL DEFAULT 0, ' +
      'reasoning_tokens INTEGER NOT NULL DEFAULT 0, ' +
      'created_at INTEGER NOT NULL, ' +
      'finished_at INTEGER NOT NULL DEFAULT 0, ' +
      'duration_ms INTEGER NOT NULL DEFAULT 0, ' +
      'UNIQUE (session_id, seq))',
    'CREATE INDEX idx_turns_session ON turns (session_id, seq)',
    'CREATE TABLE requests (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'turn_id INTEGER NOT NULL REFERENCES turns(id) ON DELETE CASCADE, ' +
      'seq INTEGER NOT NULL, ' +
      'model TEXT NOT NULL DEFAULT '''', ' +
      'message_count INTEGER NOT NULL DEFAULT 0, ' +
      'finish_reason TEXT NOT NULL DEFAULT '''', ' +
      'ok INTEGER NOT NULL DEFAULT 0, ' +
      'error_code INTEGER NOT NULL DEFAULT 0, ' +
      'error_message TEXT NOT NULL DEFAULT '''', ' +
      'error_detail TEXT NOT NULL DEFAULT '''', ' +
      'prompt_tokens INTEGER NOT NULL DEFAULT 0, ' +
      'completion_tokens INTEGER NOT NULL DEFAULT 0, ' +
      'total_tokens INTEGER NOT NULL DEFAULT 0, ' +
      'cached_tokens INTEGER NOT NULL DEFAULT 0, ' +
      'reasoning_tokens INTEGER NOT NULL DEFAULT 0, ' +
      'created_at INTEGER NOT NULL, ' +
      'finished_at INTEGER NOT NULL DEFAULT 0, ' +
      'duration_ms INTEGER NOT NULL DEFAULT 0, ' +
      'first_token_ms INTEGER NOT NULL DEFAULT 0, ' +
      'UNIQUE (turn_id, seq))',
    'CREATE INDEX idx_requests_turn ON requests (turn_id, seq)',
    'CREATE TABLE messages (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, ' +
      'turn_id INTEGER REFERENCES turns(id) ON DELETE CASCADE, ' +
      'request_id INTEGER REFERENCES requests(id) ON DELETE CASCADE, ' +
      'seq INTEGER NOT NULL, ' +
      'role INTEGER NOT NULL, ' +
      'content TEXT NOT NULL DEFAULT '''', ' +
      'tool_call_id TEXT NOT NULL DEFAULT '''', ' +
      'tool_name TEXT NOT NULL DEFAULT '''', ' +
      'tool_arguments TEXT NOT NULL DEFAULT '''', ' +
      'tool_reason TEXT NOT NULL DEFAULT '''', ' +
      'tool_ok INTEGER NOT NULL DEFAULT 0, ' +
      'created_at INTEGER NOT NULL, ' +
      'duration_ms INTEGER NOT NULL DEFAULT 0, ' +
      'UNIQUE (session_id, seq))',
    'CREATE INDEX idx_messages_session ON messages (session_id, seq)',
    'CREATE INDEX idx_messages_turn ON messages (turn_id, seq)',
    'CREATE INDEX idx_messages_request ON messages (request_id)'
  ];
end;

function StoreSchemaVersion: Integer;
var
  M: TMigrationArray;
  I: Integer;
begin
  M := DefaultMigrations;
  Result := 0;
  for I := 0 to High(M) do
    if M[I].Version > Result then
      Result := M[I].Version;
end;

{ --- statement helper --------------------------------------------------- }

type
  TStmt = class
  private
    FStmt: Psqlite3_stmt;
  public
    constructor Create(ADb: Psqlite3; const ASQL: string);
    destructor Destroy; override;
    function Valid: Boolean;
    procedure BindText(AIndex: Integer; const AValue: string);
    procedure BindInt(AIndex: Integer; AValue: Integer);
    procedure BindInt64(AIndex: Integer; AValue: Int64);
    function Step: Integer;
    function ColText(AIndex: Integer): string;
    function ColInt(AIndex: Integer): Integer;
    function ColInt64(AIndex: Integer): Int64;
  end;

constructor TStmt.Create(ADb: Psqlite3; const ASQL: string);
begin
  inherited Create;
  FStmt := nil;
  if sqlite3_prepare_v2(ADb, PAnsiChar(AsUtf8(ASQL)), -1, @FStmt, nil) <>
    SQLITE_OK then
    FStmt := nil;
end;

destructor TStmt.Destroy;
begin
  if FStmt <> nil then
    sqlite3_finalize(FStmt);
  inherited Destroy;
end;

function TStmt.Valid: Boolean;
begin
  Result := FStmt <> nil;
end;

procedure TStmt.BindText(AIndex: Integer; const AValue: string);
var
  S: AnsiString;
begin
  S := AsUtf8(AValue);
  sqlite3_bind_text(FStmt, AIndex, PAnsiChar(S), Length(S), SQLiteTransient);
end;

procedure TStmt.BindInt(AIndex: Integer; AValue: Integer);
begin
  sqlite3_bind_int(FStmt, AIndex, AValue);
end;

procedure TStmt.BindInt64(AIndex: Integer; AValue: Int64);
begin
  sqlite3_bind_int64(FStmt, AIndex, AValue);
end;

function TStmt.Step: Integer;
begin
  Result := sqlite3_step(FStmt);
end;

function TStmt.ColText(AIndex: Integer): string;
var
  P: PAnsiChar;
begin
  P := sqlite3_column_text(FStmt, AIndex);
  if P = nil then
    Result := ''
  else
    Result := string(AnsiString(P));
end;

function TStmt.ColInt(AIndex: Integer): Integer;
begin
  Result := sqlite3_column_int(FStmt, AIndex);
end;

function TStmt.ColInt64(AIndex: Integer): Int64;
begin
  Result := sqlite3_column_int64(FStmt, AIndex);
end;

{ --- TSqliteStore ------------------------------------------------------- }

constructor TSqliteStore.Create(const AConfig: TStoreConfig);
begin
  Create(AConfig, DefaultMigrations);
end;

constructor TSqliteStore.Create(const AConfig: TStoreConfig;
  const AMigrations: TMigrationArray);
begin
  inherited Create;
  FConfig := AConfig;
  FMigrations := AMigrations;
  FLock := TCriticalSection.Create;
  FDb := nil;
  FOpen := False;
end;

destructor TSqliteStore.Destroy;
begin
  Close;
  FLock.Free;
  inherited Destroy;
end;

function TSqliteStore.Fail(out AError: TStoreError; ACode: TStoreErrorCode;
  const AMessage, ADetail: string): Boolean;
begin
  AError.Code := ACode;
  AError.Message := AMessage;
  AError.Detail := ADetail;
  Result := False;
end;

function TSqliteStore.DbErrorText: string;
begin
  if FDb = nil then
    Result := 'no database'
  else
    Result := string(AnsiString(sqlite3_errmsg(FDb)));
end;

function TSqliteStore.DoExec(const ASQL: string; out AError: TStoreError): Boolean;
var
  ErrMsg: PAnsiChar;
  Rc: Integer;
begin
  AError := OkError;
  ErrMsg := nil;
  Rc := sqlite3_exec(FDb, PAnsiChar(AsUtf8(ASQL)), nil, nil, @ErrMsg);
  if Rc <> SQLITE_OK then
  begin
    if ErrMsg <> nil then
    begin
      Result := Fail(AError, seError, 'statement failed',
        string(AnsiString(ErrMsg)));
      sqlite3_free(ErrMsg);
    end
    else
      Result := Fail(AError, seError, 'statement failed', DbErrorText);
    Exit(False);
  end;
  Result := True;
end;

function TSqliteStore.EnsureOpen(out AError: TStoreError): Boolean;
begin
  AError := OkError;
  if not FOpen then
    Exit(Fail(AError, seNotOpen, 'store is not open', ''));
  Result := True;
end;

function TSqliteStore.ReadUserVersion(out AVersion: Integer;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  AVersion := 0;
  Stmt := TStmt.Create(FDb, 'PRAGMA user_version');
  try
    if not Stmt.Valid then
      Exit(Fail(AError, seError, 'could not read schema version',
        DbErrorText));
    if Stmt.Step = SQLITE_ROW then
      AVersion := Stmt.ColInt(0);
    Result := True;
  finally
    Stmt.Free;
  end;
end;

function TSqliteStore.ApplyMigrations(out AError: TStoreError): Boolean;
var
  I, J, Cur, V: Integer;
  Migration: TMigration;
begin
  AError := OkError;
  if not ReadUserVersion(Cur, AError) then
    Exit(False);

  { A database written by a newer build cannot be understood; refuse it rather
    than misbehave against a schema we do not know. This is a full reset, so a
    database from an older (pre-reset) build is also rejected, because its
    version is higher than the single fresh migration. }
  V := 0;
  for I := 0 to High(FMigrations) do
    if FMigrations[I].Version > V then
      V := FMigrations[I].Version;
  if Cur > V then
    Exit(Fail(AError, seMigrationFailed,
      'database schema is newer than this build',
      'found v' + IntToStr(Cur) + ', this build expects v' + IntToStr(V) +
      '; delete ' + FConfig.DatabasePath + ' and retry'));

  for I := 0 to High(FMigrations) do
  begin
    Migration := FMigrations[I];
    if Migration.Version <= Cur then
      Continue;

    if not DoExec('BEGIN', AError) then
      Exit(False);
    try
      for J := 0 to High(Migration.Statements) do
        if not DoExec(Migration.Statements[J], AError) then
        begin
          DoExec('ROLLBACK', AError);
          AError.Code := seMigrationFailed;
          AError.Message := 'migration failed: ' + Migration.Name;
          Exit(False);
        end;
      V := Migration.Version;
      if not DoExec('PRAGMA user_version=' + IntToStr(V), AError) then
      begin
        DoExec('ROLLBACK', AError);
        Exit(False);
      end;
      if not DoExec('COMMIT', AError) then
        Exit(False);
    except
      on E: Exception do
      begin
        DoExec('ROLLBACK', AError);
        Exit(Fail(AError, seMigrationFailed,
          'migration failed: ' + Migration.Name, E.Message));
      end;
    end;
  end;
  Result := True;
end;

{$ifdef unix}
procedure ChmodOwnerOnly(const APath: string);
begin
  if FileExists(APath) then
    fpChmod(APath, &600);
end;
{$else}
procedure ChmodOwnerOnly(const APath: string);
begin
end;
{$endif}

function TSqliteStore.Open(out AError: TStoreError): Boolean;
var
  Rc: Integer;
  ExecErr: TStoreError;
  Busy: Integer;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if FOpen then
      Exit(True);
    if FConfig.DatabasePath = '' then
      Exit(Fail(AError, seInvalidArgument, 'DatabasePath is required', ''));

    FDb := nil;
    Rc := sqlite3_open(PAnsiChar(AsUtf8(FConfig.DatabasePath)), @FDb);
    if Rc <> SQLITE_OK then
    begin
      Result := Fail(AError, seCannotOpen, 'could not open database',
        DbErrorText);
      if FDb <> nil then
      begin
        sqlite3_close(FDb);
        FDb := nil;
      end;
      Exit(False);
    end;

    Busy := FConfig.BusyTimeoutMs;
    if Busy <= 0 then
      Busy := DefaultBusyTimeoutMs;
    sqlite3_busy_timeout(FDb, Busy);

    { Set pragmas outside any transaction; ignore a failed WAL (best effort). }
    DoExec('PRAGMA journal_mode=WAL', ExecErr);
    DoExec('PRAGMA foreign_keys=ON', ExecErr);
    ChmodOwnerOnly(FConfig.DatabasePath);

    if not ApplyMigrations(AError) then
    begin
      sqlite3_close(FDb);
      FDb := nil;
      Exit(False);
    end;

    FOpen := True;
    Result := True;
  finally
    FLock.Release;
  end;
end;

procedure TSqliteStore.Close;
begin
  FLock.Acquire;
  try
    if FDb <> nil then
    begin
      sqlite3_close(FDb);
      FDb := nil;
    end;
    FOpen := False;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.IsOpen: Boolean;
begin
  FLock.Acquire;
  try
    Result := FOpen;
  finally
    FLock.Release;
  end;
end;

{ --- credentials -------------------------------------------------------- }

function TSqliteStore.SaveCredentials(const AValue: TDeviceCredentials;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if AValue.DeviceId = '' then
      Exit(Fail(AError, seInvalidArgument, 'DeviceId is required', ''));
    Stmt := TStmt.Create(FDb,
      'INSERT INTO credentials (id, device_id, token, endpoint, account_id) ' +
      'VALUES (1, ?, ?, ?, ?) ' +
      'ON CONFLICT(id) DO UPDATE SET device_id = excluded.device_id, ' +
      'token = excluded.token, endpoint = excluded.endpoint, ' +
      'account_id = excluded.account_id');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not save credentials', DbErrorText));
      Stmt.BindText(1, AValue.DeviceId);
      Stmt.BindText(2, AValue.Token);
      Stmt.BindText(3, AValue.Endpoint);
      Stmt.BindText(4, AValue.AccountId);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not save credentials', DbErrorText));
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.LoadCredentials(out AValue: TDeviceCredentials;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  AValue := Default(TDeviceCredentials);
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Stmt := TStmt.Create(FDb,
      'SELECT device_id, token, endpoint, account_id FROM credentials ' +
      'WHERE id = 1');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not load credentials', DbErrorText));
      if Stmt.Step <> SQLITE_ROW then
        Exit(Fail(AError, seNotFound, 'credentials not found', ''));
      AValue.DeviceId := Stmt.ColText(0);
      AValue.Token := Stmt.ColText(1);
      AValue.Endpoint := Stmt.ColText(2);
      AValue.AccountId := Stmt.ColText(3);
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.ClearCredentials(out AError: TStoreError): Boolean;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Result := DoExec('DELETE FROM credentials', AError);
  finally
    FLock.Release;
  end;
end;

{ --- settings ----------------------------------------------------------- }

function TSqliteStore.SetSetting(const AKey, AValue: string;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if AKey = '' then
      Exit(Fail(AError, seInvalidArgument, 'setting key is required', ''));
    Stmt := TStmt.Create(FDb,
      'INSERT INTO settings (key, value) VALUES (?, ?) ' +
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not save setting', DbErrorText));
      Stmt.BindText(1, AKey);
      Stmt.BindText(2, AValue);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not save setting', DbErrorText));
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.GetSetting(const AKey: string; out AValue: string;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  AValue := '';
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if AKey = '' then
      Exit(Fail(AError, seInvalidArgument, 'setting key is required', ''));
    Stmt := TStmt.Create(FDb, 'SELECT value FROM settings WHERE key = ?');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not read setting', DbErrorText));
      Stmt.BindText(1, AKey);
      if Stmt.Step <> SQLITE_ROW then
        Exit(Fail(AError, seNotFound, 'setting not found', AKey));
      AValue := Stmt.ColText(0);
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.DeleteSetting(const AKey: string;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if AKey = '' then
      Exit(Fail(AError, seInvalidArgument, 'setting key is required', ''));
    Stmt := TStmt.Create(FDb, 'DELETE FROM settings WHERE key = ?');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not delete setting', DbErrorText));
      Stmt.BindText(1, AKey);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not delete setting', DbErrorText));
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

{ --- workspaces --------------------------------------------------------- }

function TSqliteStore.FindWorkspace(const APath: string; out AId: Integer;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  AId := 0;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if APath = '' then
      Exit(Fail(AError, seInvalidArgument, 'workspace path is required', ''));
    Stmt := TStmt.Create(FDb, 'SELECT id FROM workspaces WHERE path = ?');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not find workspace', DbErrorText));
      Stmt.BindText(1, APath);
      if Stmt.Step <> SQLITE_ROW then
        Exit(Fail(AError, seNotFound, 'workspace not found', APath));
      AId := Stmt.ColInt(0);
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.EnsureWorkspace(const APath: string; out AId: Integer;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  AId := 0;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if APath = '' then
      Exit(Fail(AError, seInvalidArgument, 'workspace path is required', ''));

    Stmt := TStmt.Create(FDb, 'SELECT id FROM workspaces WHERE path = ?');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not find workspace', DbErrorText));
      Stmt.BindText(1, APath);
      if Stmt.Step = SQLITE_ROW then
      begin
        AId := Stmt.ColInt(0);
        Exit(True);
      end;
    finally
      Stmt.Free;
    end;

    Stmt := TStmt.Create(FDb,
      'INSERT INTO workspaces (path, created_at) VALUES (?, ?)');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not create workspace', DbErrorText));
      Stmt.BindText(1, APath);
      Stmt.BindInt64(2, NowMs);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not create workspace', DbErrorText));
    finally
      Stmt.Free;
    end;

    Stmt := TStmt.Create(FDb, 'SELECT id FROM workspaces WHERE path = ?');
    try
      Stmt.BindText(1, APath);
      if Stmt.Step <> SQLITE_ROW then
        Exit(Fail(AError, seError, 'workspace missing after insert', APath));
      AId := Stmt.ColInt(0);
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

{ --- approvals ---------------------------------------------------------- }

function EncodeApprovalParams(const AParams: TApprovalParams): string;
var
  Arr: TJSONArray;
  I: Integer;
begin
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(AParams) do
      Arr.Add(AParams[I]);
    Result := Arr.AsJSON;
  finally
    Arr.Free;
  end;
end;

function DecodeApprovalParams(const AJson: string;
  out AParams: TApprovalParams): Boolean;
var
  Data: TJSONData;
  Arr: TJSONArray;
  I: Integer;
begin
  AParams := nil;
  Data := nil;
  try
    try
      Data := GetJSON(AJson);
    except
      Exit(False);
    end;
    if not (Data is TJSONArray) then
      Exit(False);
    Arr := TJSONArray(Data);
    SetLength(AParams, Arr.Count);
    for I := 0 to Arr.Count - 1 do
      AParams[I] := Arr.Strings[I];
    Result := True;
  finally
    Data.Free;
  end;
end;

function TSqliteStore.LoadApprovals(const AContext: TApprovalContext;
  out ARules: TApprovalRuleArray; out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
  N: Integer;
  Rule: TApprovalRule;
begin
  AError := OkError;
  ARules := nil;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Stmt := TStmt.Create(FDb,
      'SELECT effect, scope, workspace_id, session_id, ref, params, ' +
      'any_params FROM approvals ' +
      'WHERE scope = 0 OR (scope = 1 AND workspace_id = ?) ' +
      'OR (scope = 2 AND session_id = ? AND ? <> '''')');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not load approvals', DbErrorText));
      Stmt.BindInt(1, AContext.WorkspaceId);
      Stmt.BindText(2, AContext.SessionId);
      Stmt.BindText(3, AContext.SessionId);
      N := 0;
      while Stmt.Step = SQLITE_ROW do
      begin
        Rule := Default(TApprovalRule);
        Rule.Effect := TApprovalEffect(Stmt.ColInt(0));
        Rule.Scope := TApprovalScope(Stmt.ColInt(1));
        Rule.WorkspaceId := Stmt.ColInt(2);
        Rule.SessionId := Stmt.ColText(3);
        Rule.Ref := Stmt.ColText(4);
        DecodeApprovalParams(Stmt.ColText(5), Rule.Params);
        Rule.AnyParams := Stmt.ColInt(6) <> 0;
        SetLength(ARules, N + 1);
        ARules[N] := Rule;
        Inc(N);
      end;
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.SaveApproval(const ARule: TApprovalRule;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if ARule.Ref = '' then
      Exit(Fail(AError, seInvalidArgument, 'approval ref is required', ''));
    Stmt := TStmt.Create(FDb,
      'INSERT OR IGNORE INTO approvals ' +
      '(effect, scope, workspace_id, session_id, ref, params, any_params, ' +
      'created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not save approval', DbErrorText));
      Stmt.BindInt(1, Ord(ARule.Effect));
      Stmt.BindInt(2, Ord(ARule.Scope));
      Stmt.BindInt(3, ARule.WorkspaceId);
      Stmt.BindText(4, ARule.SessionId);
      Stmt.BindText(5, ARule.Ref);
      Stmt.BindText(6, EncodeApprovalParams(ARule.Params));
      Stmt.BindInt(7, Ord(ARule.AnyParams));
      Stmt.BindInt64(8, NowMs);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not save approval', DbErrorText));
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.RemoveApproval(const ARule: TApprovalRule;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Stmt := TStmt.Create(FDb,
      'DELETE FROM approvals WHERE effect = ? AND scope = ? AND ' +
      'workspace_id = ? AND session_id = ? AND ref = ? AND params = ? AND ' +
      'any_params = ?');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not remove approval', DbErrorText));
      Stmt.BindInt(1, Ord(ARule.Effect));
      Stmt.BindInt(2, Ord(ARule.Scope));
      Stmt.BindInt(3, ARule.WorkspaceId);
      Stmt.BindText(4, ARule.SessionId);
      Stmt.BindText(5, ARule.Ref);
      Stmt.BindText(6, EncodeApprovalParams(ARule.Params));
      Stmt.BindInt(7, Ord(ARule.AnyParams));
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not remove approval', DbErrorText));
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

{ --- sessions and ledger ------------------------------------------------ }

function TSqliteStore.CreateSession(AWorkspaceId: Integer; out AId: string;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  AId := '';
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if AWorkspaceId < 0 then
      Exit(Fail(AError, seInvalidArgument, 'workspace id is required', ''));
    AId := NewSessionId;
    Stmt := TStmt.Create(FDb,
      'INSERT INTO sessions (id, workspace_id, created_at, updated_at) ' +
      'VALUES (?, ?, ?, ?)');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not create session', DbErrorText));
      Stmt.BindText(1, AId);
      Stmt.BindInt(2, AWorkspaceId);
      Stmt.BindInt64(3, NowMs);
      Stmt.BindInt64(4, NowMs);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not create session', DbErrorText));
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.SessionExists(const AId: string;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  Result := False;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Stmt := TStmt.Create(FDb, 'SELECT 1 FROM sessions WHERE id = ?');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not check session', DbErrorText));
      Stmt.BindText(1, AId);
      Result := Stmt.Step = SQLITE_ROW;
    finally
      Stmt.Free;
    end;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.TouchSession(const AId: string;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Stmt := TStmt.Create(FDb,
      'UPDATE sessions SET updated_at = ? WHERE id = ?');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not touch session', DbErrorText));
      Stmt.BindInt64(1, NowMs);
      Stmt.BindText(2, AId);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not touch session', DbErrorText));
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.BeginTurn(const ASessionId: string; out ATurnId: Int64;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  ATurnId := 0;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if ASessionId = '' then
      Exit(Fail(AError, seInvalidArgument, 'session id is required', ''));
    if not SessionExists(ASessionId, AError) then
    begin
      AError.Code := seNotFound;
      AError.Message := 'session not found';
      AError.Detail := ASessionId;
      Exit(False);
    end;
    Stmt := TStmt.Create(FDb,
      'INSERT INTO turns (session_id, seq, status, created_at) VALUES (' +
      '?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM turns WHERE session_id = ?), ' +
      '?, ?)');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not begin turn', DbErrorText));
      Stmt.BindText(1, ASessionId);
      Stmt.BindText(2, ASessionId);
      Stmt.BindInt(3, Ord(tsRunning));
      Stmt.BindInt64(4, NowMs);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not begin turn', DbErrorText));
    finally
      Stmt.Free;
    end;
    ATurnId := sqlite3_last_insert_rowid(FDb);
    TouchSession(ASessionId, AError);
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.FinishTurn(ATurnId: Int64; AStatus: TTurnStatus;
  const AFinishReason: string; AErrorCode: Integer;
  const AErrorMessage, AErrorDetail: string;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if ATurnId <= 0 then
      Exit(Fail(AError, seInvalidArgument, 'turn id is required', ''));
    { Roll the requests' metrics up in the same statement that closes the turn. }
    Stmt := TStmt.Create(FDb,
      'UPDATE turns SET status = ?, finish_reason = ?, error_code = ?, ' +
      'error_message = ?, error_detail = ?, finished_at = ?, ' +
      'duration_ms = ? - created_at, ' +
      'request_count = (SELECT COUNT(*) FROM requests r ' +
        'WHERE r.turn_id = turns.id), ' +
      'message_count = (SELECT COUNT(*) FROM messages m ' +
        'WHERE m.turn_id = turns.id), ' +
      'prompt_tokens = (SELECT COALESCE(SUM(r.prompt_tokens), 0) ' +
        'FROM requests r WHERE r.turn_id = turns.id), ' +
      'completion_tokens = (SELECT COALESCE(SUM(r.completion_tokens), 0) ' +
        'FROM requests r WHERE r.turn_id = turns.id), ' +
      'total_tokens = (SELECT COALESCE(SUM(r.total_tokens), 0) ' +
        'FROM requests r WHERE r.turn_id = turns.id), ' +
      'cached_tokens = (SELECT COALESCE(SUM(r.cached_tokens), 0) ' +
        'FROM requests r WHERE r.turn_id = turns.id), ' +
      'reasoning_tokens = (SELECT COALESCE(SUM(r.reasoning_tokens), 0) ' +
        'FROM requests r WHERE r.turn_id = turns.id) ' +
      'WHERE id = ?');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not finish turn', DbErrorText));
      Stmt.BindInt(1, Ord(AStatus));
      Stmt.BindText(2, AFinishReason);
      Stmt.BindInt(3, AErrorCode);
      Stmt.BindText(4, AErrorMessage);
      Stmt.BindText(5, AErrorDetail);
      Stmt.BindInt64(6, NowMs);
      Stmt.BindInt64(7, NowMs);
      Stmt.BindInt64(8, ATurnId);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not finish turn', DbErrorText));
      if sqlite3_changes(FDb) = 0 then
        Exit(Fail(AError, seNotFound, 'turn not found', IntToStr(ATurnId)));
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.QueryTurns(const ASessionId: string;
  out ATurns: TTurnRecordArray; out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
  N: Integer;
  Rec: TTurnRecord;
begin
  AError := OkError;
  ATurns := nil;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Stmt := TStmt.Create(FDb,
      'SELECT t.id, t.session_id, t.seq, t.status, t.finish_reason, ' +
      't.error_code, t.error_message, t.error_detail, t.request_count, ' +
      't.message_count, t.prompt_tokens, t.completion_tokens, t.total_tokens, ' +
      't.cached_tokens, t.reasoning_tokens, t.created_at, t.finished_at, ' +
      't.duration_ms, ' +
      'COALESCE((SELECT m.content FROM messages m WHERE m.turn_id = t.id ' +
        'AND m.role = 1 ORDER BY m.seq LIMIT 1), '''') ' +
      'FROM turns t WHERE t.session_id = ? ORDER BY t.seq');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not query turns', DbErrorText));
      Stmt.BindText(1, ASessionId);
      N := 0;
      while Stmt.Step = SQLITE_ROW do
      begin
        Rec := Default(TTurnRecord);
        Rec.Id := Stmt.ColInt64(0);
        Rec.SessionId := Stmt.ColText(1);
        Rec.Seq := Stmt.ColInt64(2);
        Rec.Status := TTurnStatus(Stmt.ColInt(3));
        Rec.FinishReason := Stmt.ColText(4);
        Rec.ErrorCode := Stmt.ColInt(5);
        Rec.ErrorMessage := Stmt.ColText(6);
        Rec.ErrorDetail := Stmt.ColText(7);
        Rec.RequestCount := Stmt.ColInt(8);
        Rec.MessageCount := Stmt.ColInt(9);
        Rec.Usage.PromptTokens := Stmt.ColInt(10);
        Rec.Usage.CompletionTokens := Stmt.ColInt(11);
        Rec.Usage.TotalTokens := Stmt.ColInt(12);
        Rec.Usage.CachedTokens := Stmt.ColInt(13);
        Rec.Usage.ReasoningTokens := Stmt.ColInt(14);
        Rec.CreatedAtMs := Stmt.ColInt64(15);
        Rec.FinishedAtMs := Stmt.ColInt64(16);
        Rec.DurationMs := Stmt.ColInt64(17);
        Rec.Prompt := Stmt.ColText(18);
        SetLength(ATurns, N + 1);
        ATurns[N] := Rec;
        Inc(N);
      end;
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.BeginRequest(ATurnId: Int64; const AModel: string;
  AMessageCount: Integer; out ARequestId: Int64;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  ARequestId := 0;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if ATurnId <= 0 then
      Exit(Fail(AError, seInvalidArgument, 'turn id is required', ''));
    Stmt := TStmt.Create(FDb, 'SELECT 1 FROM turns WHERE id = ?');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not check turn', DbErrorText));
      Stmt.BindInt64(1, ATurnId);
      if Stmt.Step <> SQLITE_ROW then
        Exit(Fail(AError, seNotFound, 'turn not found', IntToStr(ATurnId)));
    finally
      Stmt.Free;
    end;
    Stmt := TStmt.Create(FDb,
      'INSERT INTO requests (turn_id, seq, model, message_count, created_at) ' +
      'VALUES (?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM requests ' +
      'WHERE turn_id = ?), ?, ?, ?)');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not begin request', DbErrorText));
      Stmt.BindInt64(1, ATurnId);
      Stmt.BindInt64(2, ATurnId);
      Stmt.BindText(3, AModel);
      Stmt.BindInt(4, AMessageCount);
      Stmt.BindInt64(5, NowMs);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not begin request', DbErrorText));
    finally
      Stmt.Free;
    end;
    ARequestId := sqlite3_last_insert_rowid(FDb);
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.FinishRequest(ARequestId: Int64; AOk: Boolean;
  const AFinishReason: string; AErrorCode: Integer;
  const AErrorMessage, AErrorDetail: string; const AUsage: TTokenUsage;
  ADurationMs, AFirstTokenMs: Int64; out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if ARequestId <= 0 then
      Exit(Fail(AError, seInvalidArgument, 'request id is required', ''));
    Stmt := TStmt.Create(FDb,
      'UPDATE requests SET ok = ?, finish_reason = ?, error_code = ?, ' +
      'error_message = ?, error_detail = ?, prompt_tokens = ?, ' +
      'completion_tokens = ?, total_tokens = ?, cached_tokens = ?, ' +
      'reasoning_tokens = ?, finished_at = ?, duration_ms = ?, ' +
      'first_token_ms = ? WHERE id = ?');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not finish request', DbErrorText));
      Stmt.BindInt(1, Ord(AOk));
      Stmt.BindText(2, AFinishReason);
      Stmt.BindInt(3, AErrorCode);
      Stmt.BindText(4, AErrorMessage);
      Stmt.BindText(5, AErrorDetail);
      Stmt.BindInt(6, AUsage.PromptTokens);
      Stmt.BindInt(7, AUsage.CompletionTokens);
      Stmt.BindInt(8, AUsage.TotalTokens);
      Stmt.BindInt(9, AUsage.CachedTokens);
      Stmt.BindInt(10, AUsage.ReasoningTokens);
      Stmt.BindInt64(11, NowMs);
      Stmt.BindInt64(12, ADurationMs);
      Stmt.BindInt64(13, AFirstTokenMs);
      Stmt.BindInt64(14, ARequestId);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not finish request', DbErrorText));
      if sqlite3_changes(FDb) = 0 then
        Exit(Fail(AError, seNotFound, 'request not found',
          IntToStr(ARequestId)));
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.QueryRequests(ATurnId: Int64;
  out ARequests: TRequestRecordArray; out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
  N: Integer;
  Rec: TRequestRecord;
begin
  AError := OkError;
  ARequests := nil;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Stmt := TStmt.Create(FDb,
      'SELECT id, turn_id, seq, model, message_count, finish_reason, ok, ' +
      'error_code, error_message, error_detail, prompt_tokens, ' +
      'completion_tokens, total_tokens, cached_tokens, reasoning_tokens, ' +
      'created_at, finished_at, duration_ms, first_token_ms ' +
      'FROM requests WHERE turn_id = ? ORDER BY seq');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not query requests', DbErrorText));
      Stmt.BindInt64(1, ATurnId);
      N := 0;
      while Stmt.Step = SQLITE_ROW do
      begin
        Rec := Default(TRequestRecord);
        Rec.Id := Stmt.ColInt64(0);
        Rec.TurnId := Stmt.ColInt64(1);
        Rec.Seq := Stmt.ColInt64(2);
        Rec.Model := Stmt.ColText(3);
        Rec.MessageCount := Stmt.ColInt(4);
        Rec.FinishReason := Stmt.ColText(5);
        Rec.Ok := Stmt.ColInt(6) <> 0;
        Rec.ErrorCode := Stmt.ColInt(7);
        Rec.ErrorMessage := Stmt.ColText(8);
        Rec.ErrorDetail := Stmt.ColText(9);
        Rec.Usage.PromptTokens := Stmt.ColInt(10);
        Rec.Usage.CompletionTokens := Stmt.ColInt(11);
        Rec.Usage.TotalTokens := Stmt.ColInt(12);
        Rec.Usage.CachedTokens := Stmt.ColInt(13);
        Rec.Usage.ReasoningTokens := Stmt.ColInt(14);
        Rec.CreatedAtMs := Stmt.ColInt64(15);
        Rec.FinishedAtMs := Stmt.ColInt64(16);
        Rec.DurationMs := Stmt.ColInt64(17);
        Rec.FirstTokenMs := Stmt.ColInt64(18);
        SetLength(ARequests, N + 1);
        ARequests[N] := Rec;
        Inc(N);
      end;
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.AppendMessage(const AMessage: TMessageRecord;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if AMessage.SessionId = '' then
      Exit(Fail(AError, seInvalidArgument, 'session id is required', ''));
    if not SessionExists(AMessage.SessionId, AError) then
    begin
      AError.Code := seNotFound;
      AError.Message := 'session not found';
      AError.Detail := AMessage.SessionId;
      Exit(False);
    end;
    { A zero turn/request id means "none"; store NULL so the foreign key holds. }
    Stmt := TStmt.Create(FDb,
      'INSERT INTO messages (session_id, turn_id, request_id, seq, role, ' +
      'content, tool_call_id, tool_name, tool_arguments, tool_reason, ' +
      'tool_ok, created_at, duration_ms) VALUES (?, NULLIF(?, 0), ' +
      'NULLIF(?, 0), (SELECT COALESCE(MAX(seq), 0) + 1 FROM messages ' +
      'WHERE session_id = ?), ?, ?, ?, ?, ?, ?, ?, ?, ?)');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not append message', DbErrorText));
      Stmt.BindText(1, AMessage.SessionId);
      Stmt.BindInt64(2, AMessage.TurnId);
      Stmt.BindInt64(3, AMessage.RequestId);
      Stmt.BindText(4, AMessage.SessionId);
      Stmt.BindInt(5, Ord(AMessage.Role));
      Stmt.BindText(6, AMessage.Content);
      Stmt.BindText(7, AMessage.ToolCallId);
      Stmt.BindText(8, AMessage.ToolName);
      Stmt.BindText(9, AMessage.ToolArguments);
      Stmt.BindText(10, AMessage.ToolReason);
      Stmt.BindInt(11, Ord(AMessage.ToolOk));
      Stmt.BindInt64(12, NowMs);
      Stmt.BindInt64(13, AMessage.DurationMs);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not append message', DbErrorText));
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.QueryMessages(const ASessionId: string;
  out AMessages: TMessageRecordArray; out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
  N: Integer;
  Rec: TMessageRecord;
begin
  AError := OkError;
  AMessages := nil;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Stmt := TStmt.Create(FDb,
      'SELECT id, session_id, turn_id, request_id, seq, role, content, ' +
      'tool_call_id, tool_name, tool_arguments, tool_reason, tool_ok, ' +
      'created_at, duration_ms FROM messages WHERE session_id = ? ' +
      'ORDER BY seq');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not query messages', DbErrorText));
      Stmt.BindText(1, ASessionId);
      N := 0;
      while Stmt.Step = SQLITE_ROW do
      begin
        Rec := Default(TMessageRecord);
        Rec.Id := Stmt.ColInt64(0);
        Rec.SessionId := Stmt.ColText(1);
        Rec.TurnId := Stmt.ColInt64(2);
        Rec.RequestId := Stmt.ColInt64(3);
        Rec.Seq := Stmt.ColInt64(4);
        Rec.Role := TMessageRole(Stmt.ColInt(5));
        Rec.Content := Stmt.ColText(6);
        Rec.ToolCallId := Stmt.ColText(7);
        Rec.ToolName := Stmt.ColText(8);
        Rec.ToolArguments := Stmt.ColText(9);
        Rec.ToolReason := Stmt.ColText(10);
        Rec.ToolOk := Stmt.ColInt(11) <> 0;
        Rec.CreatedAtMs := Stmt.ColInt64(12);
        Rec.DurationMs := Stmt.ColInt64(13);
        SetLength(AMessages, N + 1);
        AMessages[N] := Rec;
        Inc(N);
      end;
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.ListSessions(AWorkspaceId: Integer;
  out AList: TSessionSummaryArray; out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
  N: Integer;
  Item: TSessionSummary;
begin
  AError := OkError;
  AList := nil;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Stmt := TStmt.Create(FDb,
      'SELECT s.id, s.created_at, s.updated_at, ' +
      '(SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id), ' +
      '(SELECT COUNT(*) FROM turns t WHERE t.session_id = s.id) ' +
      'FROM sessions s WHERE s.workspace_id = ? ' +
      'ORDER BY s.updated_at DESC, s.rowid DESC');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not list sessions', DbErrorText));
      Stmt.BindInt(1, AWorkspaceId);
      N := 0;
      while Stmt.Step = SQLITE_ROW do
      begin
        Item := Default(TSessionSummary);
        Item.Id := Stmt.ColText(0);
        Item.CreatedAtMs := Stmt.ColInt64(1);
        Item.UpdatedAtMs := Stmt.ColInt64(2);
        Item.MessageCount := Stmt.ColInt(3);
        Item.TurnCount := Stmt.ColInt(4);
        SetLength(AList, N + 1);
        AList[N] := Item;
        Inc(N);
      end;
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.MostRecentSessionId(AWorkspaceId: Integer;
  out AId: string; out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  AId := '';
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Stmt := TStmt.Create(FDb,
      'SELECT id FROM sessions WHERE workspace_id = ? ' +
      'ORDER BY updated_at DESC, rowid DESC LIMIT 1');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not find recent session',
          DbErrorText));
      Stmt.BindInt(1, AWorkspaceId);
      if Stmt.Step <> SQLITE_ROW then
        Exit(Fail(AError, seNotFound, 'no session for workspace', ''));
      AId := Stmt.ColText(0);
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

end.
