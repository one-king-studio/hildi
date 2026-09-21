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
  hildegard.helper.sqlite, hildegard.helper.approval, hildegard.helper.session;

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
    { Appends a ledger record, assigning its per-session sequence. }
    function AppendSessionRecord(const ARecord: TSessionRecord;
      out AError: TStoreError): Boolean;
    function QuerySessionRecords(const ASessionId: string; AUseKind: Boolean;
      AKind: TSessionRecordKind; ALimit, AOffset: Integer;
      out ARecords: TSessionRecordArray; out AError: TStoreError): Boolean;
    { Sessions for a workspace, newest updated first. }
    function ListSessions(AWorkspaceId: Integer;
      out AList: TSessionSummaryArray; out AError: TStoreError): Boolean;
    { The most recently updated session for a workspace; seNotFound if none. }
    function MostRecentSessionId(AWorkspaceId: Integer; out AId: string;
      out AError: TStoreError): Boolean;
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
  SetLength(Result, 4);
  Result[0].Version := 1;
  Result[0].Name := 'initial schema';
  Result[0].Statements := [
    'CREATE TABLE credentials (' +
      'id INTEGER PRIMARY KEY CHECK (id = 1), ' +
      'device_id TEXT NOT NULL, ' +
      'token TEXT NOT NULL, ' +
      'endpoint TEXT NOT NULL, ' +
      'account_id TEXT NOT NULL)',
    'CREATE TABLE settings (' +
      'key TEXT PRIMARY KEY, ' +
      'value TEXT NOT NULL)'
  ];

  Result[1].Version := 2;
  Result[1].Name := 'workspaces';
  Result[1].Statements := [
    'CREATE TABLE workspaces (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'path TEXT NOT NULL UNIQUE, ' +
      'created_at INTEGER NOT NULL)'
  ];

  Result[2].Version := 3;
  Result[2].Name := 'approvals';
  Result[2].Statements := [
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
      'session_id)'
  ];

  Result[3].Version := 4;
  Result[3].Name := 'sessions and ledger';
  Result[3].Statements := [
    'CREATE TABLE sessions (' +
      'id TEXT PRIMARY KEY, ' +
      'workspace_id INTEGER NOT NULL, ' +
      'created_at INTEGER NOT NULL, ' +
      'updated_at INTEGER NOT NULL)',
    'CREATE TABLE session_records (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'session_id TEXT NOT NULL, ' +
      'seq INTEGER NOT NULL, ' +
      'kind INTEGER NOT NULL, ' +
      'content TEXT NOT NULL DEFAULT '''', ' +
      'data TEXT NOT NULL DEFAULT '''', ' +
      'created_at INTEGER NOT NULL)',
    'CREATE INDEX idx_session_records ON session_records (session_id, seq)',
    'DROP TABLE IF EXISTS requests'
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

function TSqliteStore.AppendSessionRecord(const ARecord: TSessionRecord;
  out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if ARecord.SessionId = '' then
      Exit(Fail(AError, seInvalidArgument, 'session id is required', ''));

    if not SessionExists(ARecord.SessionId, AError) then
    begin
      AError.Code := seNotFound;
      AError.Message := 'session not found';
      AError.Detail := ARecord.SessionId;
      Exit(False);
    end;

    Stmt := TStmt.Create(FDb,
      'INSERT INTO session_records (session_id, seq, kind, content, data, ' +
      'created_at) VALUES (?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM ' +
      'session_records WHERE session_id = ?), ?, ?, ?, ?)');
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not append record', DbErrorText));
      Stmt.BindText(1, ARecord.SessionId);
      Stmt.BindText(2, ARecord.SessionId);
      Stmt.BindInt(3, Ord(ARecord.Kind));
      Stmt.BindText(4, ARecord.Content);
      Stmt.BindText(5, ARecord.DataJson);
      Stmt.BindInt64(6, NowMs);
      if Stmt.Step <> SQLITE_DONE then
        Exit(Fail(AError, seError, 'could not append record', DbErrorText));
    finally
      Stmt.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.QuerySessionRecords(const ASessionId: string;
  AUseKind: Boolean; AKind: TSessionRecordKind; ALimit, AOffset: Integer;
  out ARecords: TSessionRecordArray; out AError: TStoreError): Boolean;
var
  Stmt: TStmt;
  SQL: string;
  N, NextIndex: Integer;
  Rec: TSessionRecord;
begin
  AError := OkError;
  ARecords := nil;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    SQL := 'SELECT id, session_id, seq, kind, content, data, created_at ' +
      'FROM session_records WHERE session_id = ?';
    if AUseKind then
      SQL := SQL + ' AND kind = ?';
    SQL := SQL + ' ORDER BY seq LIMIT ? OFFSET ?';
    Stmt := TStmt.Create(FDb, SQL);
    try
      if not Stmt.Valid then
        Exit(Fail(AError, seError, 'could not query records', DbErrorText));
      NextIndex := 1;
      Stmt.BindText(NextIndex, ASessionId);
      Inc(NextIndex);
      if AUseKind then
      begin
        Stmt.BindInt(NextIndex, Ord(AKind));
        Inc(NextIndex);
      end;
      if ALimit > 0 then
        Stmt.BindInt(NextIndex, ALimit)
      else
        Stmt.BindInt(NextIndex, -1);   // SQLite: negative LIMIT means no limit
      Inc(NextIndex);
      Stmt.BindInt(NextIndex, AOffset);
      N := 0;
      while Stmt.Step = SQLITE_ROW do
      begin
        Rec := Default(TSessionRecord);
        Rec.Id := Stmt.ColInt64(0);
        Rec.SessionId := Stmt.ColText(1);
        Rec.Seq := Stmt.ColInt64(2);
        Rec.Kind := TSessionRecordKind(Stmt.ColInt(3));
        Rec.Content := Stmt.ColText(4);
        Rec.DataJson := Stmt.ColText(5);
        Rec.CreatedAtMs := Stmt.ColInt64(6);
        SetLength(ARecords, N + 1);
        ARecords[N] := Rec;
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
      'SELECT s.id, s.created_at, s.updated_at, COUNT(r.id) AS n ' +
      'FROM sessions s LEFT JOIN session_records r ON r.session_id = s.id ' +
      'WHERE s.workspace_id = ? GROUP BY s.id ' +
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
        Item.RecordCount := Stmt.ColInt(3);
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
