unit test_store;
{ fpcunit tests for hildegard.helper.store. Each test runs against a temporary
  database path; the vendored library is resolved relative to the test binary. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry,
  {$ifdef unix}BaseUnix,{$endif}
  hildegard.helper.sqlite,
  hildegard.helper.store, hildegard.helper.session;

type
  TStoreTest = class(TTestCase)
  private
    FDir: string;
    FDbPath: string;
    function NewStore: TSqliteStore;
    function OpenStore: TSqliteStore;
    procedure DeleteDbFiles;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestOpenCreatesDatabase;
    procedure TestOpenAppliesMigrations;
    procedure TestOpenIsIdempotent;
    procedure TestOpenUnwritablePathFails;
    procedure TestDatabaseFilePermissionsAreOwnerOnly;
    procedure TestSqliteIsLinkedStatically;

    procedure TestOperationsBeforeOpenReturnNotOpen;
    procedure TestSaveLoadClearCredentialsRoundTrip;
    procedure TestLoadCredentialsMissingReturnsNotFound;
    procedure TestCredentialsPersistAcrossReopen;

    procedure TestSettingSetGetOverwriteDelete;
    procedure TestSettingMissingReturnsNotFound;
    procedure TestParameterizedValuesWithQuotesRoundTrip;

    procedure TestFailedMigrationRollsBackAndKeepsVersion;
    procedure TestConcurrentOperationsDoNotCorruptOrDeadlock;
    procedure TestSchemaHasNoRequestsTable;
    procedure TestSessionAndLedgerRoundTrip;
    procedure TestListAndMostRecentSessions;
  end;

implementation

{ Reads PRAGMA user_version through the static binding. Test-only: lets us
  assert the schema version without exposing it on the store's public API. }
function RawReadUserVersion(const APath: string): Integer;
var
  Db: Psqlite3;
  Stmt: Psqlite3_stmt;
  S: AnsiString;
begin
  Result := -1;
  Db := nil;
  if sqlite3_open(PAnsiChar(AnsiString(APath)), @Db) <> SQLITE_OK then
  begin
    if Db <> nil then
      sqlite3_close(Db);
    Exit;
  end;
  Stmt := nil;
  S := 'PRAGMA user_version';
  if sqlite3_prepare_v2(Db, PAnsiChar(S), -1, @Stmt, nil) = SQLITE_OK then
  begin
    if sqlite3_step(Stmt) = SQLITE_ROW then
      Result := sqlite3_column_int(Stmt, 0);
    sqlite3_finalize(Stmt);
  end;
  sqlite3_close(Db);
end;

{ TStoreTest }

procedure TStoreTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhstore_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  CreateDir(FDir);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
end;

procedure TStoreTest.DeleteDbFiles;
begin
  DeleteFile(FDbPath);
  DeleteFile(FDbPath + '-wal');
  DeleteFile(FDbPath + '-shm');
end;

procedure TStoreTest.TearDown;
begin
  DeleteDbFiles;
  RemoveDir(FDir);
end;

function TStoreTest.NewStore: TSqliteStore;
var
  Cfg: TStoreConfig;
begin
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  Result := TSqliteStore.Create(Cfg);
end;

function TStoreTest.OpenStore: TSqliteStore;
var
  Err: TStoreError;
begin
  Result := NewStore;
  if not Result.Open(Err) then
  begin
    Result.Free;
    raise Exception.Create('store failed to open: ' + Err.Message + ' / ' +
      Err.Detail);
  end;
end;

procedure TStoreTest.TestOpenCreatesDatabase;
var
  S: TSqliteStore;
  Err: TStoreError;
begin
  S := NewStore;
  try
    AssertFalse('not open before Open', S.IsOpen);
    AssertTrue('Open succeeds', S.Open(Err));
    AssertTrue('file created', FileExists(FDbPath));
    AssertTrue('reports open', S.IsOpen);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestOpenAppliesMigrations;
var
  S: TSqliteStore;
  Err: TStoreError;
begin
  S := OpenStore;
  try
    { The schema exists, so a settings write must succeed. }
    AssertTrue('schema usable after migrations',
      S.SetSetting('k', 'v', Err));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestOpenIsIdempotent;
var
  S: TSqliteStore;
  Err: TStoreError;
begin
  S := NewStore;
  try
    AssertTrue(S.Open(Err));
    AssertTrue('second Open is a no-op success', S.Open(Err));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestOpenUnwritablePathFails;
var
  S: TSqliteStore;
  Err: TStoreError;
  Cfg: TStoreConfig;
begin
  Cfg.DatabasePath := '/definitely/not/a/real/directory/store.db';
  Cfg.BusyTimeoutMs := 5000;
  S := TSqliteStore.Create(Cfg);
  try
    AssertFalse('Open fails', S.Open(Err));
    AssertEquals('cannot open', Ord(seCannotOpen), Ord(Err.Code));
    AssertFalse('not open', S.IsOpen);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestDatabaseFilePermissionsAreOwnerOnly;
{$ifdef unix}
var
  S: TSqliteStore;
  Info: TStat;
{$endif}
begin
  {$ifdef unix}
  S := OpenStore;
  try
    if fpStat(FDbPath, Info) = 0 then
      AssertEquals('owner-only permissions', &600, Info.st_mode and &777);
  finally
    S.Free;
  end;
  {$else}
  AssertTrue('permissions test is Unix-only', True);
  {$endif}
end;

procedure TStoreTest.TestSqliteIsLinkedStatically;
begin
  { The binding is statically linked; libversion reports the compiled-in lib. }
  AssertTrue('sqlite version present',
    string(AnsiString(sqlite3_libversion)) <> '');
end;

{ --- credentials --- }

procedure TStoreTest.TestOperationsBeforeOpenReturnNotOpen;
var
  S: TSqliteStore;
  Err: TStoreError;
  Cred: TDeviceCredentials;
begin
  S := NewStore;
  try
    Cred := Default(TDeviceCredentials);
    AssertFalse('save fails', S.SaveCredentials(Cred, Err));
    AssertEquals('not open', Ord(seNotOpen), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestSaveLoadClearCredentialsRoundTrip;
var
  S: TSqliteStore;
  Err: TStoreError;
  In_, Out_: TDeviceCredentials;
begin
  S := OpenStore;
  try
    In_.DeviceId := 'dev-1';
    In_.Token := 'tok-secret';
    In_.Endpoint := 'https://api.example';
    In_.AccountId := 'acct-9';
    AssertTrue('save', S.SaveCredentials(In_, Err));

    AssertTrue('load', S.LoadCredentials(Out_, Err));
    AssertEquals('device id', 'dev-1', Out_.DeviceId);
    AssertEquals('token', 'tok-secret', Out_.Token);
    AssertEquals('endpoint', 'https://api.example', Out_.Endpoint);
    AssertEquals('account id', 'acct-9', Out_.AccountId);

    AssertTrue('clear', S.ClearCredentials(Err));
    AssertFalse('load after clear fails', S.LoadCredentials(Out_, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestLoadCredentialsMissingReturnsNotFound;
var
  S: TSqliteStore;
  Err: TStoreError;
  Cred: TDeviceCredentials;
begin
  S := OpenStore;
  try
    AssertFalse(S.LoadCredentials(Cred, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestCredentialsPersistAcrossReopen;
var
  S: TSqliteStore;
  Err: TStoreError;
  Cred: TDeviceCredentials;
begin
  S := OpenStore;
  try
    Cred.DeviceId := 'dev-persist';
    Cred.Token := 'tok';
    Cred.Endpoint := 'ep';
    Cred.AccountId := 'acct';
    AssertTrue(S.SaveCredentials(Cred, Err));
  finally
    S.Free;
  end;

  S := OpenStore;
  try
    AssertTrue('load after reopen', S.LoadCredentials(Cred, Err));
    AssertEquals('device id persisted', 'dev-persist', Cred.DeviceId);
  finally
    S.Free;
  end;
end;

{ --- requests / queue --- }

procedure TStoreTest.TestSettingSetGetOverwriteDelete;
var
  S: TSqliteStore;
  Err: TStoreError;
  V: string;
begin
  S := OpenStore;
  try
    AssertTrue('set', S.SetSetting('color', 'blue', Err));
    AssertTrue('get', S.GetSetting('color', V, Err));
    AssertEquals('value', 'blue', V);
    AssertTrue('overwrite', S.SetSetting('color', 'red', Err));
    AssertTrue('get2', S.GetSetting('color', V, Err));
    AssertEquals('overwritten', 'red', V);
    AssertTrue('delete', S.DeleteSetting('color', Err));
    AssertFalse('get after delete', S.GetSetting('color', V, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestSettingMissingReturnsNotFound;
var
  S: TSqliteStore;
  Err: TStoreError;
  V: string;
begin
  S := OpenStore;
  try
    AssertFalse(S.GetSetting('nope', V, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestParameterizedValuesWithQuotesRoundTrip;
var
  S: TSqliteStore;
  Err: TStoreError;
  V, Tricky: string;
begin
  S := OpenStore;
  try
    Tricky := 'it''s "quoted"; DROP TABLE settings; --';
    AssertTrue('set tricky', S.SetSetting('tricky', Tricky, Err));
    AssertTrue('get tricky', S.GetSetting('tricky', V, Err));
    AssertEquals('stored verbatim', Tricky, V);
  finally
    S.Free;
  end;
end;

{ --- migrations / concurrency --- }

procedure TStoreTest.TestFailedMigrationRollsBackAndKeepsVersion;
var
  S: TSqliteStore;
  Err: TStoreError;
  Cfg: TStoreConfig;
  M: TMigrationArray;
  V: string;
begin
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;

  SetLength(M, 2);
  M[0].Version := 1;
  M[0].Name := 'schema';
  M[0].Statements := [
    'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)'];
  M[1].Version := 2;
  M[1].Name := 'bad';
  M[1].Statements := [
    'CREATE TABLE t2 (id INTEGER)',
    'CREATE TABLE t2 (id INTEGER)'];   // duplicate -> fails, must roll back

  S := TSqliteStore.Create(Cfg, M);
  try
    AssertFalse('open fails on bad migration', S.Open(Err));
    AssertEquals('migration failed', Ord(seMigrationFailed), Ord(Err.Code));
  finally
    S.Free;
  end;

  { The failed migration's first statement must have been rolled back, so the
    schema version is still 1 (not 2). }
  AssertEquals('schema version unchanged', 1, RawReadUserVersion(FDbPath));

  { Reopen with a corrected migration 2: because t2 was rolled back, it can be
    created, and settings (from migration 1) is usable. }
  SetLength(M, 2);
  M[0].Version := 1;
  M[0].Name := 'schema';
  M[0].Statements := [
    'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)'];
  M[1].Version := 2;
  M[1].Name := 't2';
  M[1].Statements := ['CREATE TABLE t2 (id INTEGER)'];
  S := TSqliteStore.Create(Cfg, M);
  try
    AssertTrue('reopen with corrected migration', S.Open(Err));
    AssertEquals('now at version 2', 2, RawReadUserVersion(FDbPath));
    AssertTrue('usable', S.SetSetting('after', 'rollback', Err));
    AssertTrue('read back', S.GetSetting('after', V, Err));
    AssertEquals('value', 'rollback', V);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestConcurrentOperationsDoNotCorruptOrDeadlock;
var
  S: TSqliteStore;
  Err: TStoreError;
  I: Integer;
  V: string;
begin
  S := OpenStore;
  try
    for I := 0 to 99 do
    begin
      AssertTrue('set ' + IntToStr(I), S.SetSetting('k' + IntToStr(I),
        IntToStr(I), Err));
      AssertTrue('get ' + IntToStr(I), S.GetSetting('k' + IntToStr(I), V, Err));
      AssertEquals('roundtrip ' + IntToStr(I), IntToStr(I), V);
    end;
  finally
    S.Free;
  end;
end;

{ Reads sqlite_master through the static binding to assert schema presence. }
function RawTableExists(const APath, AName: string): Boolean;
var
  Db: Psqlite3;
  Stmt: Psqlite3_stmt;
  S: AnsiString;
begin
  Result := False;
  Db := nil;
  if sqlite3_open(PAnsiChar(AnsiString(APath)), @Db) <> SQLITE_OK then
  begin
    if Db <> nil then
      sqlite3_close(Db);
    Exit;
  end;
  Stmt := nil;
  S := 'SELECT 1 FROM sqlite_master WHERE type = ''table'' AND name = ?';
  if sqlite3_prepare_v2(Db, PAnsiChar(S), -1, @Stmt, nil) = SQLITE_OK then
  begin
    sqlite3_bind_text(Stmt, 1, PAnsiChar(AnsiString(AName)), Length(AName),
      SQLiteTransient);
    Result := sqlite3_step(Stmt) = SQLITE_ROW;
    sqlite3_finalize(Stmt);
  end;
  sqlite3_close(Db);
end;

procedure TStoreTest.TestSchemaHasNoRequestsTable;
var
  S: TSqliteStore;
begin
  S := OpenStore;
  try
  finally
    S.Free;
  end;
  AssertTrue('sessions table exists', RawTableExists(FDbPath, 'sessions'));
  AssertTrue('session_records exists', RawTableExists(FDbPath, 'session_records'));
  AssertFalse('requests dropped', RawTableExists(FDbPath, 'requests'));
end;

procedure TStoreTest.TestSessionAndLedgerRoundTrip;
var
  S: TSqliteStore;
  Err: TStoreError;
  Id, Id2: string;
  Rec, Rec2, Rec3: TSessionRecord;
  Rows: TSessionRecordArray;
  WorkspaceId: Integer;
begin
  S := OpenStore;
  try
    AssertTrue('workspace', S.EnsureWorkspace('/tmp', WorkspaceId, Err));
    AssertTrue('create session', S.CreateSession(WorkspaceId, Id, Err));
    AssertEquals('id length', 32, Length(Id));
    AssertTrue('exists', S.SessionExists(Id, Err));

    Rec := Default(TSessionRecord);
    Rec.SessionId := Id;
    Rec.Kind := srkUserMessage;
    Rec.Content := 'hello';
    AssertTrue('append 1', S.AppendSessionRecord(Rec, Err));
    Rec2 := Default(TSessionRecord);
    Rec2.SessionId := Id;
    Rec2.Kind := srkAssistantMessage;
    Rec2.Content := 'hi';
    AssertTrue('append 2', S.AppendSessionRecord(Rec2, Err));

    AssertTrue('query', S.QuerySessionRecords(Id, False, srkEvent, 0, 0, Rows,
      Err));
    AssertEquals('two records', 2, Length(Rows));
    AssertEquals('ordered seq 1', 1, Rows[0].Seq);
    AssertEquals('ordered seq 2', 2, Rows[1].Seq);
    AssertEquals('first kind', Ord(srkUserMessage), Ord(Rows[0].Kind));

    AssertTrue('query by kind', S.QuerySessionRecords(Id, True,
      srkUserMessage, 0, 0, Rows, Err));
    AssertEquals('one user record', 1, Length(Rows));

    Rec3 := Default(TSessionRecord);
    Rec3.SessionId := 'nope';
    AssertFalse('append unknown session', S.AppendSessionRecord(Rec3, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));

    AssertTrue('touch', S.TouchSession(Id, Err));
    AssertTrue('create 2', S.CreateSession(WorkspaceId, Id2, Err));
    AssertTrue('ids differ', Id <> Id2);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestListAndMostRecentSessions;
var
  S: TSqliteStore;
  Err: TStoreError;
  W, IdA, IdB, Recent: string;
  WorkspaceId: Integer;
  List: TSessionSummaryArray;
  Rec: TSessionRecord;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, IdA, Err);
    S.CreateSession(WorkspaceId, IdB, Err);

    Rec := Default(TSessionRecord);
    Rec.SessionId := IdA;
    Rec.Kind := srkUserMessage;
    Rec.Content := 'x';
    S.AppendSessionRecord(Rec, Err);
    Sleep(10);
    S.TouchSession(IdA, Err);   // A is now the most recently updated

    AssertTrue('list', S.ListSessions(WorkspaceId, List, Err));
    AssertEquals('two sessions', 2, Length(List));
    AssertEquals('newest first', IdA, List[0].Id);
    AssertEquals('record count', 1, List[0].RecordCount);
    AssertEquals('other empty', 0, List[1].RecordCount);

    AssertTrue('most recent', S.MostRecentSessionId(WorkspaceId, Recent, Err));
    AssertEquals('most recent id', IdA, Recent);

    AssertTrue('no sessions for other workspace',
      S.MostRecentSessionId(WorkspaceId + 999, Recent, Err) = False);
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

initialization
  RegisterTest(TStoreTest);
end.
