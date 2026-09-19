unit hildegard.helper.store;
{ Embedded SQLite persistence for the helper. Owns one database file and exposes
  typed operations for device credentials, request history / durable queue, and
  key/value settings. SQL, schema, migrations, and thread serialization stay
  behind this unit.

  Implementation notes:
    * SQLDB's TSQLite3Connection is not thread-safe, so one connection is
      serialized by one critical section.
    * PRAGMA journal_mode=WAL cannot be set through SQLDB (it wraps statements
      in a transaction); it is applied to the raw file before SQLDB connects and
      persists in the database header.
    * PRAGMA foreign_keys is set at connect time via TSQLite3Connection.Params.
    * The vendored libsqlite3 is loaded once per process; Close does not unload
      it (SQLDB shares one set of function pointers). ponytail: single store per
      process; revisit if multiple stores with different libraries are needed. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, sqldb, sqlite3conn, sqldblib,
  hildegard.helper.approval;

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
    LibraryPath: string;
    BusyTimeoutMs: Integer;
  end;

  TDeviceCredentials = record
    DeviceId: string;
    Token: string;
    Endpoint: string;
    AccountId: string;
  end;

  TRequestStatus = (rsPending, rsClaimed, rsCompleted, rsFailed, rsCancelled);

  TStoredRequest = record
    Id: string;
    Kind: string;
    Payload: string;
    Status: TRequestStatus;
    ExitCode: Integer;
    Result: string;
    CreatedAtMs: Int64;
    UpdatedAtMs: Int64;
  end;

  TStoredRequestArray = array of TStoredRequest;

  TRequestQuery = record
    UseStatus: Boolean;
    Status: TRequestStatus;
    Limit: Integer;
    Offset: Integer;
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
    FLoader: TSQLDBLibraryLoader;
    FConn: TSQLite3Connection;
    FTx: TSQLTransaction;
    FOpen: Boolean;
    FInitialized: Boolean;
    FMigrations: TMigrationArray;
    function Fail(out AError: TStoreError; ACode: TStoreErrorCode;
      const AMessage, ADetail: string): Boolean;
    function EnsureOpen(out AError: TStoreError): Boolean;
    function ApplyMigrations(out AError: TStoreError): Boolean;
    function ReadUserVersion(out AVersion: Integer;
      out AError: TStoreError): Boolean;
    function ExecInTransaction(const ASQL: string;
      out AError: TStoreError): Boolean;
    function ReadOneRequest(AQuery: TSQLQuery;
      out AValue: TStoredRequest; out AError: TStoreError): Boolean;
    procedure InitLibrary(const ALibraryPath: string);
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

    function EnqueueRequest(const AValue: TStoredRequest;
      out AError: TStoreError): Boolean;
    function ClaimNextPending(out AValue: TStoredRequest;
      out AError: TStoreError): Boolean;
    function FinishRequest(const AId: string; AStatus: TRequestStatus;
      AExitCode: Integer; const AResult: string;
      out AError: TStoreError): Boolean;
    function GetRequest(const AId: string; out AValue: TStoredRequest;
      out AError: TStoreError): Boolean;
    function QueryRequests(const AQuery: TRequestQuery;
      out AList: TStoredRequestArray; out AError: TStoreError): Boolean;

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
  end;

function ResolveLibraryPath(const AExplicit: string): string;
function StoreSchemaVersion: Integer;
function DefaultMigrations: TMigrationArray;

implementation

uses
  {$ifdef unix}BaseUnix,{$endif}
  sqlite3dyn, fpjson, jsonparser;

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

{ --- migrations --------------------------------------------------------- }

function DefaultMigrations: TMigrationArray;
begin
  Result := nil;
  SetLength(Result, 2);
  Result[0].Version := 1;
  Result[0].Name := 'initial schema';
  Result[0].Statements := [
    'CREATE TABLE credentials (' +
      'id INTEGER PRIMARY KEY CHECK (id = 1), ' +
      'device_id TEXT NOT NULL, ' +
      'token TEXT NOT NULL, ' +
      'endpoint TEXT NOT NULL, ' +
      'account_id TEXT NOT NULL)',
    'CREATE TABLE requests (' +
      'id TEXT PRIMARY KEY, ' +
      'kind TEXT NOT NULL, ' +
      'payload TEXT NOT NULL, ' +
      'status INTEGER NOT NULL, ' +
      'exit_code INTEGER NOT NULL DEFAULT 0, ' +
      'result TEXT NOT NULL DEFAULT '''', ' +
      'created_at INTEGER NOT NULL, ' +
      'updated_at INTEGER NOT NULL)',
    'CREATE INDEX idx_requests_status ON requests (status, created_at)',
    'CREATE INDEX idx_requests_created ON requests (created_at)',
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

  SetLength(Result, 3);
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

function ResolveLibraryPath(const AExplicit: string): string;
const
  {$ifdef darwin}
  LibName = 'libsqlite3.dylib';
  {$else}
  LibName = 'libsqlite3.so';
  {$endif}
var
  Env: string;
  ExeDir, Candidate: string;
begin
  if AExplicit <> '' then
    Exit(AExplicit);

  Env := GetEnvironmentVariable('HILDEGARD_SQLITE_LIB');
  if (Env <> '') and FileExists(Env) then
    Exit(Env);

  ExeDir := ExtractFileDir(ParamStr(0));
  Candidate := IncludeTrailingPathDelimiter(ExeDir) + LibName;
  if FileExists(Candidate) then
    Exit(Candidate);

  Candidate := IncludeTrailingPathDelimiter(ExeDir) + '..' + PathDelim +
    'lib' + PathDelim + LibName;
  if FileExists(Candidate) then
    Exit(ExpandFileName(Candidate));

  Result := '';
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
  FOpen := False;
  FInitialized := False;
end;

destructor TSqliteStore.Destroy;
begin
  Close;
  FLoader.Free;
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

procedure TSqliteStore.InitLibrary(const ALibraryPath: string);
begin
  if FInitialized then
    Exit;
  FLoader := TSQLDBLibraryLoader.Create(nil);
  FLoader.ConnectionType := 'SQLite3';
  if ALibraryPath <> '' then
    FLoader.LibraryName := ALibraryPath;
  FLoader.LoadLibrary;
  FInitialized := True;
end;

{$ifdef unix}
procedure ChmodOwnerOnly(const APath: string);
begin
  if FileExists(APath) then
    fpChmod(APath, &600);
end;

procedure PresetWal(const APath: string);
var
  Db: psqlite3;
  Rc: Integer;
begin
  Db := nil;
  Rc := sqlite3_open(PAnsiChar(AnsiString(APath)), @Db);
  if Rc <> 0 then
  begin
    if Db <> nil then
      sqlite3_close(Db);
    Exit;
  end;
  try
    sqlite3_exec(Db, 'PRAGMA journal_mode=WAL', nil, nil, nil);
  finally
    sqlite3_close(Db);
  end;
end;
{$else}
procedure ChmodOwnerOnly(const APath: string);
begin
end;

procedure PresetWal(const APath: string);
begin
end;
{$endif}

function TSqliteStore.Open(out AError: TStoreError): Boolean;
var
  LibPath: string;
  Ver: Integer;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if FOpen then
      Exit(True);
    if FConfig.DatabasePath = '' then
      Exit(Fail(AError, seInvalidArgument, 'DatabasePath is required', ''));

    LibPath := ResolveLibraryPath(FConfig.LibraryPath);

    try
      InitLibrary(LibPath);
    except
      on E: Exception do
        Exit(Fail(AError, seCannotOpen,
          'failed to load SQLite library', LibPath + ': ' + E.Message));
    end;

    try
      PresetWal(FConfig.DatabasePath);
    except
      on E: Exception do
        Exit(Fail(AError, seCannotOpen,
          'failed to initialize database file', E.Message));
    end;

    try
      FConn := TSQLite3Connection.Create(nil);
      FTx := TSQLTransaction.Create(nil);
      FConn.DatabaseName := FConfig.DatabasePath;
      FConn.Params.Add('foreign_keys=ON');
      FConn.Transaction := FTx;
      FConn.Open;
      if FConfig.BusyTimeoutMs > 0 then
        FConn.ExecuteDirect('PRAGMA busy_timeout=' +
          IntToStr(FConfig.BusyTimeoutMs))
      else
        FConn.ExecuteDirect('PRAGMA busy_timeout=' +
          IntToStr(DefaultBusyTimeoutMs));
    except
      on E: Exception do
      begin
        FreeAndNil(FConn);
        FreeAndNil(FTx);
        Exit(Fail(AError, seCannotOpen, 'failed to open database',
          FConfig.DatabasePath + ': ' + E.Message));
      end;
    end;

    if not ReadUserVersion(Ver, AError) then
    begin
      FConn.Close;
      FreeAndNil(FConn);
      FreeAndNil(FTx);
      Exit(False);
    end;

    if not ApplyMigrations(AError) then
    begin
      FConn.Close;
      FreeAndNil(FConn);
      FreeAndNil(FTx);
      Exit(False);
    end;

    ChmodOwnerOnly(FConfig.DatabasePath);
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
    if FConn <> nil then
    begin
      if FTx <> nil then
        FTx.Active := False;   // avoid closing inside an open transaction
      FConn.Close;
      FreeAndNil(FConn);
      FreeAndNil(FTx);
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
  Q: TSQLQuery;
begin
  Result := True;
  AVersion := 0;
  AError := OkError;
  Q := TSQLQuery.Create(nil);
  try
    Q.DataBase := FConn;
    Q.Transaction := FTx;
    Q.SQL.Text := 'PRAGMA user_version';
    try
      Q.Open;
      AVersion := Q.Fields[0].AsInteger;
      Q.Close;
    except
      on E: Exception do
        Exit(Fail(AError, seCannotOpen, 'cannot read schema version',
          E.Message));
    end;
  finally
    Q.Free;
  end;
end;

function TSqliteStore.ExecInTransaction(const ASQL: string;
  out AError: TStoreError): Boolean;
begin
  Result := True;
  AError := OkError;
  try
    if not FTx.Active then
      FTx.StartTransaction;
    FConn.ExecuteDirect(ASQL, FTx);
  except
    on E: Exception do
      Exit(Fail(AError, seError, 'statement failed', E.Message));
  end;
end;

function TSqliteStore.ApplyMigrations(out AError: TStoreError): Boolean;
var
  I, J, Cur: Integer;
  V: Integer;
  Migration: TMigration;
begin
  Result := True;
  AError := OkError;
  if not ReadUserVersion(Cur, AError) then
    Exit(False);

  for I := 0 to High(FMigrations) do
  begin
    Migration := FMigrations[I];
    if Migration.Version <= Cur then
      Continue;

    try
      if FTx.Active then
        FTx.Rollback;
      for J := 0 to High(Migration.Statements) do
        FConn.ExecuteDirect(Migration.Statements[J], FTx);
      V := Migration.Version;
      FConn.ExecuteDirect('PRAGMA user_version=' + IntToStr(V), FTx);
      FTx.Commit;
    except
      on E: Exception do
      begin
        if FTx.Active then
          FTx.Rollback;
        Exit(Fail(AError, seMigrationFailed,
          'migration failed: ' + Migration.Name, E.Message));
      end;
    end;
  end;
end;

function TSqliteStore.SaveCredentials(const AValue: TDeviceCredentials;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if AValue.DeviceId = '' then
      Exit(Fail(AError, seInvalidArgument, 'DeviceId is required', ''));
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text :=
        'INSERT INTO credentials (id, device_id, token, endpoint, account_id) ' +
        'VALUES (1, :device_id, :token, :endpoint, :account_id) ' +
        'ON CONFLICT(id) DO UPDATE SET device_id = excluded.device_id, ' +
        'token = excluded.token, endpoint = excluded.endpoint, ' +
        'account_id = excluded.account_id';
      Q.ParamByName('device_id').AsString := AValue.DeviceId;
      Q.ParamByName('token').AsString := AValue.Token;
      Q.ParamByName('endpoint').AsString := AValue.Endpoint;
      Q.ParamByName('account_id').AsString := AValue.AccountId;
      try
        Q.ExecSQL;
        FTx.Commit;
      except
        on E: Exception do
        begin
          if FTx.Active then
            FTx.Rollback;
          Exit(Fail(AError, seError, 'could not save credentials', E.Message));
        end;
      end;
    finally
      Q.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.LoadCredentials(out AValue: TDeviceCredentials;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text :=
        'SELECT device_id, token, endpoint, account_id ' +
        'FROM credentials WHERE id = 1';
      try
        Q.Open;
        if not Q.EOF then
        begin
          AValue.DeviceId := Q.Fields[0].AsString;
          AValue.Token := Q.Fields[1].AsString;
          AValue.Endpoint := Q.Fields[2].AsString;
          AValue.AccountId := Q.Fields[3].AsString;
          Result := True;
        end
        else
          Result := Fail(AError, seNotFound, 'no credentials stored', '');
        Q.Close;
      except
        on E: Exception do
          Exit(Fail(AError, seError, 'could not load credentials', E.Message));
      end;
    finally
      Q.Free;
    end;
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
    if not ExecInTransaction('DELETE FROM credentials', AError) then
    begin
      if FTx.Active then
        FTx.Rollback;
      Exit(False);
    end;
    try
      FTx.Commit;
    except
      on E: Exception do
        Exit(Fail(AError, seError, 'could not clear credentials', E.Message));
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.EnqueueRequest(const AValue: TStoredRequest;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
  Exists: Boolean;
  Created, Updated: Int64;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if AValue.Id = '' then
      Exit(Fail(AError, seInvalidArgument, 'request id is required', ''));
    if AValue.Kind = '' then
      Exit(Fail(AError, seInvalidArgument, 'request kind is required', ''));

    Created := AValue.CreatedAtMs;
    Updated := AValue.UpdatedAtMs;
    if Created = 0 then
      Created := NowMs;
    if Updated = 0 then
      Updated := Created;
    if (Created < 0) or (Updated < 0) then
      Exit(Fail(AError, seInvalidArgument, 'timestamps must not be negative', ''));

    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text := 'SELECT 1 FROM requests WHERE id = :id';
      Q.ParamByName('id').AsString := AValue.Id;
      Q.Open;
      Exists := not Q.EOF;
      Q.Close;
      if Exists then
        Exit(Fail(AError, seConstraint, 'request id already exists',
          AValue.Id));

      Q.SQL.Text :=
        'INSERT INTO requests ' +
        '(id, kind, payload, status, exit_code, result, created_at, updated_at) ' +
        'VALUES (:id, :kind, :payload, :status, :exit_code, :result, ' +
        ':created_at, :updated_at)';
      Q.ParamByName('id').AsString := AValue.Id;
      Q.ParamByName('kind').AsString := AValue.Kind;
      Q.ParamByName('payload').AsString := AValue.Payload;
      Q.ParamByName('status').AsInteger := Ord(rsPending);
      Q.ParamByName('exit_code').AsInteger := 0;
      Q.ParamByName('result').AsString := '';
      Q.ParamByName('created_at').AsLargeInt := Created;
      Q.ParamByName('updated_at').AsLargeInt := Updated;
      try
        Q.ExecSQL;
        FTx.Commit;
      except
        on E: Exception do
        begin
          if FTx.Active then
            FTx.Rollback;
          Exit(Fail(AError, seError, 'could not enqueue request', E.Message));
        end;
      end;
    finally
      Q.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.ReadOneRequest(AQuery: TSQLQuery;
  out AValue: TStoredRequest; out AError: TStoreError): Boolean;
begin
  Result := True;
  AError := OkError;
  if AQuery.EOF then
    Exit(False);
  AValue.Id := AQuery.FieldByName('id').AsString;
  AValue.Kind := AQuery.FieldByName('kind').AsString;
  AValue.Payload := AQuery.FieldByName('payload').AsString;
  AValue.Status := TRequestStatus(AQuery.FieldByName('status').AsInteger);
  AValue.ExitCode := AQuery.FieldByName('exit_code').AsInteger;
  AValue.Result := AQuery.FieldByName('result').AsString;
  AValue.CreatedAtMs := AQuery.FieldByName('created_at').AsLargeInt;
  AValue.UpdatedAtMs := AQuery.FieldByName('updated_at').AsLargeInt;
end;

function TSqliteStore.ClaimNextPending(out AValue: TStoredRequest;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
  Claimed: Int64;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      try
        Q.SQL.Text :=
          'SELECT * FROM requests WHERE status = :st ' +
          'ORDER BY created_at, id LIMIT 1';
        Q.ParamByName('st').AsInteger := Ord(rsPending);
        Q.Open;
        if Q.EOF then
        begin
          Q.Close;
          if FTx.Active then
            FTx.Commit;
          Exit(Fail(AError, seNotFound, 'no pending requests', ''));
        end;
        ReadOneRequest(Q, AValue, AError);
        Q.Close;

        Claimed := NowMs;
        Q.SQL.Text :=
          'UPDATE requests SET status = :claimed, updated_at = :now ' +
          'WHERE id = :id AND status = :pending';
        Q.ParamByName('claimed').AsInteger := Ord(rsClaimed);
        Q.ParamByName('now').AsLargeInt := Claimed;
        Q.ParamByName('id').AsString := AValue.Id;
        Q.ParamByName('pending').AsInteger := Ord(rsPending);
        Q.ExecSQL;
        if Q.RowsAffected <> 1 then
        begin
          FTx.Rollback;
          Exit(Fail(AError, seError, 'claim lost a race', AValue.Id));
        end;
        FTx.Commit;
        AValue.Status := rsClaimed;
        AValue.UpdatedAtMs := Claimed;
      except
        on E: Exception do
        begin
          if FTx.Active then
            FTx.Rollback;
          Exit(Fail(AError, seError, 'could not claim request', E.Message));
        end;
      end;
    finally
      Q.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.FinishRequest(const AId: string; AStatus: TRequestStatus;
  AExitCode: Integer; const AResult: string;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
  Exists: Boolean;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if not (AStatus in [rsCompleted, rsFailed, rsCancelled]) then
      Exit(Fail(AError, seInvalidArgument, 'not a terminal status', ''));
    if AId = '' then
      Exit(Fail(AError, seInvalidArgument, 'request id is required', ''));

    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      try
        Q.SQL.Text :=
          'UPDATE requests SET status = :st, exit_code = :ec, result = :res, ' +
          'updated_at = :now WHERE id = :id AND status IN (:pending, :claimed)';
        Q.ParamByName('st').AsInteger := Ord(AStatus);
        Q.ParamByName('ec').AsInteger := AExitCode;
        Q.ParamByName('res').AsString := AResult;
        Q.ParamByName('now').AsLargeInt := NowMs;
        Q.ParamByName('id').AsString := AId;
        Q.ParamByName('pending').AsInteger := Ord(rsPending);
        Q.ParamByName('claimed').AsInteger := Ord(rsClaimed);
        Q.ExecSQL;
        if Q.RowsAffected = 1 then
        begin
          FTx.Commit;
          Exit(True);
        end;

        FTx.Rollback;
        Q.SQL.Text := 'SELECT 1 FROM requests WHERE id = :id';
        Q.ParamByName('id').AsString := AId;
        Q.Open;
        Exists := not Q.EOF;
        Q.Close;
        if Exists then
          Exit(Fail(AError, seConstraint, 'request is already terminal', AId))
        else
          Exit(Fail(AError, seNotFound, 'no such request', AId));
      except
        on E: Exception do
        begin
          if FTx.Active then
            FTx.Rollback;
          Exit(Fail(AError, seError, 'could not finish request', E.Message));
        end;
      end;
    finally
      Q.Free;
    end;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.GetRequest(const AId: string; out AValue: TStoredRequest;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text := 'SELECT * FROM requests WHERE id = :id';
      Q.ParamByName('id').AsString := AId;
      try
        Q.Open;
        if Q.EOF then
          Result := Fail(AError, seNotFound, 'no such request', AId)
        else
          Result := ReadOneRequest(Q, AValue, AError);
        Q.Close;
      except
        on E: Exception do
          Exit(Fail(AError, seError, 'could not read request', E.Message));
      end;
    finally
      Q.Free;
    end;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.QueryRequests(const AQuery: TRequestQuery;
  out AList: TStoredRequestArray; out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
  Sql: string;
  Count: Integer;
  Item: TStoredRequest;
begin
  AError := OkError;
  SetLength(AList, 0);
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Sql := 'SELECT * FROM requests';
      if AQuery.UseStatus then
        Sql := Sql + ' WHERE status = :st';
      Sql := Sql + ' ORDER BY created_at, id';
      if AQuery.Limit > 0 then
      begin
        Sql := Sql + ' LIMIT :lim';
        if AQuery.Offset > 0 then
          Sql := Sql + ' OFFSET :off';
      end;
      Q.SQL.Text := Sql;
      if AQuery.UseStatus then
        Q.ParamByName('st').AsInteger := Ord(AQuery.Status);
      if AQuery.Limit > 0 then
      begin
        Q.ParamByName('lim').AsInteger := AQuery.Limit;
        if AQuery.Offset > 0 then
          Q.ParamByName('off').AsInteger := AQuery.Offset;
      end;
      try
        Q.Open;
        Count := 0;
        while not Q.EOF do
        begin
          ReadOneRequest(Q, Item, AError);
          SetLength(AList, Count + 1);
          AList[Count] := Item;
          Inc(Count);
          Q.Next;
        end;
        Q.Close;
        Result := True;
      except
        on E: Exception do
          Exit(Fail(AError, seError, 'could not query requests', E.Message));
      end;
    finally
      Q.Free;
    end;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.SetSetting(const AKey, AValue: string;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if AKey = '' then
      Exit(Fail(AError, seInvalidArgument, 'setting key is required', ''));
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text :=
        'INSERT INTO settings (key, value) VALUES (:k, :v) ' +
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value';
      Q.ParamByName('k').AsString := AKey;
      Q.ParamByName('v').AsString := AValue;
      try
        Q.ExecSQL;
        FTx.Commit;
      except
        on E: Exception do
        begin
          if FTx.Active then
            FTx.Rollback;
          Exit(Fail(AError, seError, 'could not set setting', E.Message));
        end;
      end;
    finally
      Q.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.GetSetting(const AKey: string; out AValue: string;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
begin
  AError := OkError;
  AValue := '';
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text := 'SELECT value FROM settings WHERE key = :k';
      Q.ParamByName('k').AsString := AKey;
      try
        Q.Open;
        if Q.EOF then
          Result := Fail(AError, seNotFound, 'no such setting', AKey)
        else
        begin
          AValue := Q.Fields[0].AsString;
          Result := True;
        end;
        Q.Close;
      except
        on E: Exception do
          Exit(Fail(AError, seError, 'could not read setting', E.Message));
      end;
    finally
      Q.Free;
    end;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.DeleteSetting(const AKey: string;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if AKey = '' then
      Exit(Fail(AError, seInvalidArgument, 'setting key is required', ''));
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text := 'DELETE FROM settings WHERE key = :k';
      Q.ParamByName('k').AsString := AKey;
      try
        Q.ExecSQL;
        FTx.Commit;
      except
        on E: Exception do
        begin
          if FTx.Active then
            FTx.Rollback;
          Exit(Fail(AError, seError, 'could not delete setting', E.Message));
        end;
      end;
    finally
      Q.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.FindWorkspace(const APath: string; out AId: Integer;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
begin
  AError := OkError;
  AId := 0;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if APath = '' then
      Exit(Fail(AError, seInvalidArgument, 'workspace path is required', ''));
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text := 'SELECT id FROM workspaces WHERE path = :p';
      Q.ParamByName('p').AsString := APath;
      Q.Open;
      if Q.EOF then
        Exit(Fail(AError, seNotFound, 'workspace not found', APath));
      AId := Q.FieldByName('id').AsInteger;
      Q.Close;
    finally
      Q.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.EnsureWorkspace(const APath: string; out AId: Integer;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
begin
  AError := OkError;
  AId := 0;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if APath = '' then
      Exit(Fail(AError, seInvalidArgument, 'workspace path is required', ''));

    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text := 'SELECT id FROM workspaces WHERE path = :p';
      Q.ParamByName('p').AsString := APath;
      Q.Open;
      if not Q.EOF then
      begin
        AId := Q.FieldByName('id').AsInteger;
        Q.Close;
        Exit(True);
      end;
      Q.Close;

      Q.SQL.Text :=
        'INSERT INTO workspaces (path, created_at) VALUES (:p, :t)';
      Q.ParamByName('p').AsString := APath;
      Q.ParamByName('t').AsLargeInt := NowMs;
      try
        Q.ExecSQL;
        FTx.Commit;
      except
        on E: Exception do
        begin
          if FTx.Active then
            FTx.Rollback;
          Exit(Fail(AError, seError, 'could not create workspace', E.Message));
        end;
      end;

      Q.SQL.Text := 'SELECT id FROM workspaces WHERE path = :p';
      Q.ParamByName('p').AsString := APath;
      Q.Open;
      if Q.EOF then
        Exit(Fail(AError, seError, 'workspace missing after insert', APath));
      AId := Q.FieldByName('id').AsInteger;
      Q.Close;
    finally
      Q.Free;
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
  Q: TSQLQuery;
  N: Integer;
  Rule: TApprovalRule;
begin
  AError := OkError;
  ARules := nil;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text :=
        'SELECT effect, scope, workspace_id, session_id, ref, params, ' +
        'any_params FROM approvals ' +
        'WHERE scope = 0 ' +
        'OR (scope = 1 AND workspace_id = :w) ' +
        'OR (scope = 2 AND session_id = :s AND :s <> '''')';
      Q.ParamByName('w').AsInteger := AContext.WorkspaceId;
      Q.ParamByName('s').AsString := AContext.SessionId;
      Q.Open;
      N := 0;
      while not Q.EOF do
      begin
        Rule := Default(TApprovalRule);
        Rule.Effect := TApprovalEffect(Q.FieldByName('effect').AsInteger);
        Rule.Scope := TApprovalScope(Q.FieldByName('scope').AsInteger);
        Rule.WorkspaceId := Q.FieldByName('workspace_id').AsInteger;
        Rule.SessionId := Q.FieldByName('session_id').AsString;
        Rule.Ref := Q.FieldByName('ref').AsString;
        DecodeApprovalParams(Q.FieldByName('params').AsString, Rule.Params);
        Rule.AnyParams := Q.FieldByName('any_params').AsInteger <> 0;
        SetLength(ARules, N + 1);
        ARules[N] := Rule;
        Inc(N);
        Q.Next;
      end;
      Q.Close;
    finally
      Q.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.SaveApproval(const ARule: TApprovalRule;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    if ARule.Ref = '' then
      Exit(Fail(AError, seInvalidArgument, 'approval ref is required', ''));
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text :=
        'INSERT OR IGNORE INTO approvals ' +
        '(effect, scope, workspace_id, session_id, ref, params, any_params, ' +
        'created_at) VALUES (:e, :sc, :w, :s, :r, :p, :a, :t)';
      Q.ParamByName('e').AsInteger := Ord(ARule.Effect);
      Q.ParamByName('sc').AsInteger := Ord(ARule.Scope);
      Q.ParamByName('w').AsInteger := ARule.WorkspaceId;
      Q.ParamByName('s').AsString := ARule.SessionId;
      Q.ParamByName('r').AsString := ARule.Ref;
      Q.ParamByName('p').AsString := EncodeApprovalParams(ARule.Params);
      Q.ParamByName('a').AsInteger := Ord(ARule.AnyParams);
      Q.ParamByName('t').AsLargeInt := NowMs;
      try
        Q.ExecSQL;
        FTx.Commit;
      except
        on E: Exception do
        begin
          if FTx.Active then
            FTx.Rollback;
          Exit(Fail(AError, seError, 'could not save approval', E.Message));
        end;
      end;
    finally
      Q.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TSqliteStore.RemoveApproval(const ARule: TApprovalRule;
  out AError: TStoreError): Boolean;
var
  Q: TSQLQuery;
begin
  AError := OkError;
  FLock.Acquire;
  try
    if not EnsureOpen(AError) then
      Exit(False);
    Q := TSQLQuery.Create(nil);
    try
      Q.DataBase := FConn;
      Q.Transaction := FTx;
      Q.SQL.Text :=
        'DELETE FROM approvals WHERE effect = :e AND scope = :sc AND ' +
        'workspace_id = :w AND session_id = :s AND ref = :r AND ' +
        'params = :p AND any_params = :a';
      Q.ParamByName('e').AsInteger := Ord(ARule.Effect);
      Q.ParamByName('sc').AsInteger := Ord(ARule.Scope);
      Q.ParamByName('w').AsInteger := ARule.WorkspaceId;
      Q.ParamByName('s').AsString := ARule.SessionId;
      Q.ParamByName('r').AsString := ARule.Ref;
      Q.ParamByName('p').AsString := EncodeApprovalParams(ARule.Params);
      Q.ParamByName('a').AsInteger := Ord(ARule.AnyParams);
      try
        Q.ExecSQL;
        FTx.Commit;
      except
        on E: Exception do
        begin
          if FTx.Active then
            FTx.Rollback;
          Exit(Fail(AError, seError, 'could not remove approval', E.Message));
        end;
      end;
    finally
      Q.Free;
    end;
    Result := True;
  finally
    FLock.Release;
  end;
end;

end.
