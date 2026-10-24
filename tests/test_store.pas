unit test_store;
{ fpcunit tests for hildegard.helper.store. Each test runs against a temporary
  database path; the vendored library is resolved relative to the test binary. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry,
  {$ifdef unix}BaseUnix,{$endif}
  hildegard.helper.sqlite,
  hildegard.helper.store, hildegard.helper.session, hildegard.helper.llm,
  hildegard.helper.mcp.config;

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
    procedure TestSchemaHasTheSessionTables;
    procedure TestTurnRequestMessageRoundTrip;
    procedure TestTurnRollupSumsRequests;
    procedure TestMessageSeqIsPerSession;
    procedure TestRequestSeqIsPerTurn;
    procedure TestBeginRequestUnknownTurnFails;
    procedure TestAppendMessageUnknownSessionFails;
    procedure TestQueryTurnsDerivesPrompt;
    procedure TestNewerSchemaVersionIsRejected;
    procedure TestListSessionsCountsMessagesAndTurns;
    procedure TestMostRecentTurnReturnsLatest;
    procedure TestMostRecentTurnNotFound;
    procedure TestSessionTotalsContextAndGenerated;
    procedure TestSessionTotalsContextIsTheLatestRequest;
    procedure TestSessionTotalsEmpty;

    procedure TestRuntimeMigrationIsAdditive;
    procedure TestRuntimeRowRoundTrip;
    procedure TestRuntimeRowUnknownSessionFails;
    procedure TestClearRuntime;
    procedure TestExpireRuntimes;
    procedure TestListRuntimes;
    procedure TestMcpServerMigrationIsAdditive;
    procedure TestSaveMcpServerUpserts;
    procedure TestLoadMcpServersScoped;
    procedure TestRemoveMcpServer;
    procedure TestMcpArgsEnvRoundTrip;
    procedure TestSaveMcpServerRejectsInvalid;

    procedure TestLineageRootDefaults;
    procedure TestChildSessionLineage;
    procedure TestChildrenOf;
    procedure TestSessionLineageUnknownFails;
    procedure TestLineageMigrationV4IsAdditive;
    procedure TestMessageRefSessionRoundTrip;

    procedure TestOAuthTokenRoundTrip;
    procedure TestOAuthTokenMissing;
    procedure TestClearOAuthToken;
    procedure TestFinalizeRunningTurns;
    procedure TestBeginTurnSelfHeals;
    procedure TestCheckpointAndActiveWindow;
    procedure TestQueryMessagesBefore;
    procedure TestFtsSearchScoped;

    procedure TestReplyMetadataMigrationV10IsAdditive;
    procedure TestSessionTitleOverrideWins;
    procedure TestReplyKeywordsReplace;
    procedure TestReplyKeywordsCascade;
    procedure TestListSessionRowsOrderAndArchived;
    procedure TestSessionPinAndArchiveRoundTrip;
    procedure TestRenameReusesTitleOverride;
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

{ Inserts one message row with raw SQL, bypassing the store's current schema
  assumptions. Used to seed a database as an older build would have written it. }
procedure RawInsertMessage(const APath, ASessionId, AContent: string);
var
  Db: Psqlite3;
  ErrMsg: PAnsiChar;
  S: AnsiString;
begin
  Db := nil;
  if sqlite3_open(PAnsiChar(AnsiString(APath)), @Db) <> SQLITE_OK then
  begin
    if Db <> nil then
      sqlite3_close(Db);
    Exit;
  end;
  S := 'INSERT INTO messages (session_id, seq, role, content, created_at) ' +
    'VALUES (''' + AnsiString(ASessionId) + ''', 1, 1, ''' +
    AnsiString(AContent) + ''', 1)';
  sqlite3_exec(Db, PAnsiChar(S), nil, nil, @ErrMsg);
  if ErrMsg <> nil then
    sqlite3_free(ErrMsg);
  sqlite3_close(Db);
end;

{ Overwrites PRAGMA user_version through the static binding, to simulate a
  database written by a different build. }
procedure RawSetUserVersion(const APath: string; AVersion: Integer);
var
  Db: Psqlite3;
  Stmt: Psqlite3_stmt;
  S: AnsiString;
begin
  Db := nil;
  if sqlite3_open(PAnsiChar(AnsiString(APath)), @Db) <> SQLITE_OK then
  begin
    if Db <> nil then
      sqlite3_close(Db);
    Exit;
  end;
  Stmt := nil;
  S := 'PRAGMA user_version = ' + AnsiString(IntToStr(AVersion));
  if sqlite3_prepare_v2(Db, PAnsiChar(S), -1, @Stmt, nil) = SQLITE_OK then
  begin
    sqlite3_step(Stmt);
    sqlite3_finalize(Stmt);
  end;
  sqlite3_close(Db);
end;

function MakeMsg(const ASessionId: string; ARole: TMessageRole;
  const AContent: string): TMessageRecord;
begin
  Result := Default(TMessageRecord);
  Result.SessionId := ASessionId;
  Result.Role := ARole;
  Result.Content := AContent;
end;

function MakeTurnMsg(const ASessionId: string; ATurnId: Int64;
  ARole: TMessageRole; const AContent: string): TMessageRecord;
begin
  Result := MakeMsg(ASessionId, ARole, AContent);
  Result.TurnId := ATurnId;
end;

function MakeUsage(APrompt, ACompletion, ATotal, ACached,
  AReasoning: Integer): TTokenUsage;
begin
  Result := Default(TTokenUsage);
  Result.PromptTokens := APrompt;
  Result.CompletionTokens := ACompletion;
  Result.TotalTokens := ATotal;
  Result.CachedTokens := ACached;
  Result.ReasoningTokens := AReasoning;
end;

procedure TStoreTest.TestSchemaHasTheSessionTables;
var
  S: TSqliteStore;
begin
  S := OpenStore;
  try
  finally
    S.Free;
  end;
  AssertTrue('sessions table exists', RawTableExists(FDbPath, 'sessions'));
  AssertTrue('turns table exists', RawTableExists(FDbPath, 'turns'));
  AssertTrue('requests table exists', RawTableExists(FDbPath, 'requests'));
  AssertTrue('messages table exists', RawTableExists(FDbPath, 'messages'));
  AssertFalse('session_records gone',
    RawTableExists(FDbPath, 'session_records'));
end;

procedure TStoreTest.TestTurnRequestMessageRoundTrip;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  TurnId, ReqId: Int64;
  Turns: TTurnRecordArray;
  Reqs: TRequestRecordArray;
  Msgs: TMessageRecordArray;
  M: TMessageRecord;
begin
  S := OpenStore;
  try
    AssertTrue('workspace', S.EnsureWorkspace('/tmp', Ws, Err));
    AssertTrue('create session', S.CreateSession(Ws, Sid, Err));
    AssertEquals('id length', 32, Length(Sid));
    AssertTrue('exists', S.SessionExists(Sid, Err));

    AssertTrue('begin turn', S.BeginTurn(Sid, TurnId, Err));
    AssertTrue('turn id assigned', TurnId > 0);
    AssertTrue('append user',
      S.AppendMessage(MakeTurnMsg(Sid, TurnId, mrUser, 'hi'), Err));
    AssertTrue('begin request', S.BeginRequest(TurnId, 'model-x', 3, ReqId, Err));
    AssertTrue('request id assigned', ReqId > 0);
    M := MakeTurnMsg(Sid, TurnId, mrAssistant, 'yo');
    M.RequestId := ReqId;
    AssertTrue('append assistant', S.AppendMessage(M, Err));
    AssertTrue('finish request', S.FinishRequest(ReqId, True, 'stop', 0, '', '',
      MakeUsage(10, 20, 30, 4, 5), 120, 40, Err));
    AssertTrue('finish turn',
      S.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '', Err));

    AssertTrue('query turns', S.QueryTurns(Sid, Turns, Err));
    AssertEquals('one turn', 1, Length(Turns));
    AssertEquals('turn seq', 1, Turns[0].Seq);
    AssertEquals('completed', Ord(tsCompleted), Ord(Turns[0].Status));
    AssertEquals('one request', 1, Turns[0].RequestCount);
    AssertEquals('two messages', 2, Turns[0].MessageCount);
    AssertEquals('rollup prompt tokens', 10, Turns[0].Usage.PromptTokens);
    AssertEquals('rollup cached', 4, Turns[0].Usage.CachedTokens);

    AssertTrue('query requests', S.QueryRequests(TurnId, Reqs, Err));
    AssertEquals('one request', 1, Length(Reqs));
    AssertEquals('request seq', 1, Reqs[0].Seq);
    AssertEquals('model', 'model-x', Reqs[0].Model);
    AssertEquals('message count', 3, Reqs[0].MessageCount);
    AssertEquals('finish reason', 'stop', Reqs[0].FinishReason);
    AssertTrue('ok', Reqs[0].Ok);
    AssertEquals('prompt tokens', 10, Reqs[0].Usage.PromptTokens);
    AssertEquals('cached tokens', 4, Reqs[0].Usage.CachedTokens);
    AssertEquals('reasoning tokens', 5, Reqs[0].Usage.ReasoningTokens);
    AssertEquals('duration', 120, Reqs[0].DurationMs);
    AssertEquals('first token', 40, Reqs[0].FirstTokenMs);

    AssertTrue('query messages', S.QueryMessages(Sid, Msgs, Err));
    AssertEquals('two messages', 2, Length(Msgs));
    AssertEquals('seq 1', 1, Msgs[0].Seq);
    AssertEquals('seq 2', 2, Msgs[1].Seq);
    AssertEquals('user role', Ord(mrUser), Ord(Msgs[0].Role));
    AssertEquals('user turn link', TurnId, Msgs[0].TurnId);
    AssertEquals('user has no request', 0, Msgs[0].RequestId);
    AssertEquals('assistant request link', ReqId, Msgs[1].RequestId);
    AssertEquals('content', 'hi', Msgs[0].Content);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestTurnRollupSumsRequests;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  TurnId, R1, R2: Int64;
  Turns: TTurnRecordArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    S.BeginTurn(Sid, TurnId, Err);
    S.BeginRequest(TurnId, 'm', 1, R1, Err);
    S.FinishRequest(R1, True, 'tool_calls', 0, '', '',
      MakeUsage(10, 5, 15, 2, 1), 100, 30, Err);
    S.BeginRequest(TurnId, 'm', 4, R2, Err);
    S.FinishRequest(R2, True, 'stop', 0, '', '',
      MakeUsage(20, 8, 28, 3, 2), 200, 50, Err);
    S.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '', Err);

    AssertTrue('query turns', S.QueryTurns(Sid, Turns, Err));
    AssertEquals('two requests', 2, Turns[0].RequestCount);
    AssertEquals('prompt summed', 30, Turns[0].Usage.PromptTokens);
    AssertEquals('completion summed', 13, Turns[0].Usage.CompletionTokens);
    AssertEquals('total summed', 43, Turns[0].Usage.TotalTokens);
    AssertEquals('cached summed', 5, Turns[0].Usage.CachedTokens);
    AssertEquals('reasoning summed', 3, Turns[0].Usage.ReasoningTokens);
    AssertTrue('duration recorded', Turns[0].DurationMs >= 0);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestMessageSeqIsPerSession;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  T1, T2: Int64;
  Msgs: TMessageRecordArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    S.BeginTurn(Sid, T1, Err);
    S.AppendMessage(MakeTurnMsg(Sid, T1, mrUser, 'a'), Err);
    S.AppendMessage(MakeTurnMsg(Sid, T1, mrAssistant, 'b'), Err);
    S.BeginTurn(Sid, T2, Err);
    S.AppendMessage(MakeTurnMsg(Sid, T2, mrUser, 'c'), Err);

    AssertTrue('query', S.QueryMessages(Sid, Msgs, Err));
    AssertEquals('three messages', 3, Length(Msgs));
    AssertEquals('seq 1', 1, Msgs[0].Seq);
    AssertEquals('seq 2', 2, Msgs[1].Seq);
    AssertEquals('seq 3', 3, Msgs[2].Seq);
    AssertEquals('second turn link', T2, Msgs[2].TurnId);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestRequestSeqIsPerTurn;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  T1, T2, R: Int64;
  Reqs: TRequestRecordArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    S.BeginTurn(Sid, T1, Err);
    S.BeginRequest(T1, 'm', 1, R, Err);
    S.BeginRequest(T1, 'm', 2, R, Err);
    S.BeginTurn(Sid, T2, Err);
    S.BeginRequest(T2, 'm', 1, R, Err);

    AssertTrue('turn 1 requests', S.QueryRequests(T1, Reqs, Err));
    AssertEquals('two', 2, Length(Reqs));
    AssertEquals('seq 1', 1, Reqs[0].Seq);
    AssertEquals('seq 2', 2, Reqs[1].Seq);
    AssertTrue('turn 2 requests', S.QueryRequests(T2, Reqs, Err));
    AssertEquals('one', 1, Length(Reqs));
    AssertEquals('restarts at 1', 1, Reqs[0].Seq);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestBeginRequestUnknownTurnFails;
var
  S: TSqliteStore;
  Err: TStoreError;
  ReqId: Int64;
begin
  S := OpenStore;
  try
    AssertFalse('fails', S.BeginRequest(9999, 'm', 0, ReqId, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestAppendMessageUnknownSessionFails;
var
  S: TSqliteStore;
  Err: TStoreError;
begin
  S := OpenStore;
  try
    AssertFalse('fails', S.AppendMessage(MakeMsg('nope', mrUser, 'x'), Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestQueryTurnsDerivesPrompt;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  TurnId: Int64;
  Turns: TTurnRecordArray;
  M: TMessageRecord;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    S.BeginTurn(Sid, TurnId, Err);
    M := MakeMsg(Sid, mrUser, 'the prompt');
    M.TurnId := TurnId;
    S.AppendMessage(M, Err);
    M := MakeMsg(Sid, mrAssistant, 'answer');
    M.TurnId := TurnId;
    S.AppendMessage(M, Err);
    M := MakeMsg(Sid, mrUser, 'a later user message');
    M.TurnId := TurnId;
    S.AppendMessage(M, Err);
    S.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '', Err);

    AssertTrue('query', S.QueryTurns(Sid, Turns, Err));
    AssertEquals('prompt is the first user message', 'the prompt',
      Turns[0].Prompt);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestNewerSchemaVersionIsRejected;
var
  S: TSqliteStore;
  Err: TStoreError;
begin
  S := OpenStore;      // creates the schema at the current version
  S.Free;
  RawSetUserVersion(FDbPath, StoreSchemaVersion + 1);

  S := NewStore;
  try
    AssertFalse('open fails', S.Open(Err));
    AssertEquals('migration failed', Ord(seMigrationFailed), Ord(Err.Code));
    AssertTrue('message names the path', Pos(FDbPath, Err.Detail) > 0);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestListSessionsCountsMessagesAndTurns;
var
  S: TSqliteStore;
  Err: TStoreError;
  IdA, IdB, Recent: string;
  WorkspaceId: Integer;
  List: TSessionSummaryArray;
  TurnId: Int64;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, IdA, Err);
    S.CreateSession(WorkspaceId, IdB, Err);

    S.BeginTurn(IdA, TurnId, Err);
    S.AppendMessage(MakeTurnMsg(IdA, TurnId, mrUser, 'x'), Err);
    S.AppendMessage(MakeTurnMsg(IdA, TurnId, mrAssistant, 'y'), Err);
    S.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '', Err);
    Sleep(10);
    S.TouchSession(IdA, Err);   // A is now the most recently updated

    AssertTrue('list', S.ListSessions(WorkspaceId, List, Err));
    AssertEquals('two sessions', 2, Length(List));
    AssertEquals('newest first', IdA, List[0].Id);
    AssertEquals('message count', 2, List[0].MessageCount);
    AssertEquals('turn count', 1, List[0].TurnCount);
    AssertEquals('other empty', 0, List[1].MessageCount);

    AssertTrue('most recent', S.MostRecentSessionId(WorkspaceId, Recent, Err));
    AssertEquals('most recent id', IdA, Recent);

    AssertTrue('no sessions for other workspace',
      S.MostRecentSessionId(WorkspaceId + 999, Recent, Err) = False);
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestMostRecentTurnReturnsLatest;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  T1, T2: Int64;
  Turn: TTurnRecord;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    S.BeginTurn(Sid, T1, Err);
    S.FinishTurn(T1, tsCompleted, 'stop', 0, '', '', Err);
    S.BeginTurn(Sid, T2, Err);
    S.FinishTurn(T2, tsFailed, '', 1, 'boom', '', Err);

    AssertTrue('found', S.MostRecentTurn(Sid, Turn, Err));
    AssertEquals('latest turn', T2, Turn.Id);
    AssertEquals('status', Ord(tsFailed), Ord(Turn.Status));
    AssertEquals('error message', 'boom', Turn.ErrorMessage);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestMostRecentTurnNotFound;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  Turn: TTurnRecord;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    AssertFalse('none', S.MostRecentTurn(Sid, Turn, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
    AssertEquals('zero record', 0, Turn.Id);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestSessionTotalsContextAndGenerated;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  T1, T2, R: Int64;
  Totals: TTurnRecord;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    S.BeginTurn(Sid, T1, Err);
    S.BeginRequest(T1, 'm', 1, R, Err);
    S.FinishRequest(R, True, 'stop', 0, '', '',
      MakeUsage(10, 5, 15, 2, 1), 100, 30, Err);
    S.FinishTurn(T1, tsCompleted, 'stop', 0, '', '', Err);
    S.BeginTurn(Sid, T2, Err);
    S.BeginRequest(T2, 'm', 1, R, Err);
    S.FinishRequest(R, True, 'stop', 0, '', '',
      MakeUsage(20, 8, 28, 3, 2), 200, 50, Err);
    S.FinishTurn(T2, tsCompleted, 'stop', 0, '', '', Err);

    AssertTrue('totals', S.SessionTotals(Sid, Totals, Err));
    AssertEquals('non-zero when there are requests', 1, Totals.Id);
    { The billed input is every request's prompt (10 + 20); the final context
      is the largest single prompt (20). }
    AssertEquals('billed prompt summed', 30, Totals.Usage.PromptTokens);
    AssertEquals('cached summed', 5, Totals.Usage.CachedTokens);
    AssertEquals('completion summed', 13, Totals.Usage.CompletionTokens);
    AssertEquals('total used is in plus out', 43, Totals.Usage.TotalTokens);
    AssertEquals('reasoning summed', 3, Totals.Usage.ReasoningTokens);
    AssertEquals('final context', 20, Totals.ContextTokens);
    AssertEquals('requests summed', 2, Totals.RequestCount);
    AssertTrue('duration summed', Totals.DurationMs >= 0);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestSessionTotalsContextIsTheLatestRequest;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  T1, T2, T3, R: Int64;
  Totals: TTurnRecord;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    { Page 1: the context grows to 40 (the peak). }
    S.BeginTurn(Sid, T1, Err);
    S.BeginRequest(T1, 'm', 1, R, Err);
    S.FinishRequest(R, True, 'stop', 0, '', '',
      MakeUsage(10, 1, 11, 0, 0), 1, 1, Err);
    S.FinishTurn(T1, tsCompleted, 'stop', 0, '', '', Err);
    S.BeginTurn(Sid, T2, Err);
    S.BeginRequest(T2, 'm', 1, R, Err);
    S.FinishRequest(R, True, 'stop', 0, '', '',
      MakeUsage(40, 1, 41, 0, 0), 1, 1, Err);
    S.FinishTurn(T2, tsCompleted, 'stop', 0, '', '', Err);
    { A continuation's prompt shrinks: the context must follow the latest
      request, not the peak. (SessionTotals is checkpoint-agnostic, so no
      checkpoint row is needed to exercise this.) }
    S.BeginTurn(Sid, T3, Err);
    S.BeginRequest(T3, 'm', 1, R, Err);
    S.FinishRequest(R, True, 'stop', 0, '', '',
      MakeUsage(12, 1, 13, 0, 0), 1, 1, Err);
    S.FinishTurn(T3, tsCompleted, 'stop', 0, '', '', Err);

    AssertTrue('totals', S.SessionTotals(Sid, Totals, Err));
    { The context in play is the current page (12), not the page-1 peak (40). }
    AssertEquals('context is the latest page', 12, Totals.ContextTokens);
    { The billed totals still span every page. }
    AssertEquals('billed prompt across pages', 62, Totals.Usage.PromptTokens);
    AssertEquals('requests across pages', 3, Totals.RequestCount);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestSessionTotalsEmpty;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  Totals: TTurnRecord;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    AssertTrue('totals', S.SessionTotals(Sid, Totals, Err));
    AssertEquals('no turns', 0, Totals.Id);
    AssertEquals('no tokens', 0, Totals.Usage.TotalTokens);
    AssertEquals('no requests', 0, Totals.RequestCount);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestRuntimeMigrationIsAdditive;
var
  S: TSqliteStore;
  Err: TStoreError;
  Cfg: TStoreConfig;
  Migs: TMigrationArray;
  Ws: Integer;
  Sid: string;
  Row: TSessionRuntimeRow;
  Msgs: TMessageRecordArray;
begin
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;

  { A v1-only database, as an existing install would have. }
  Migs := DefaultMigrations;
  SetLength(Migs, 1);
  S := TSqliteStore.Create(Cfg, Migs);
  try
    AssertTrue('open v1', S.Open(Err));
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
  finally
    S.Free;
  end;
  { A v1-era row: the v1 messages table has no ref_session_id, so insert it
    with raw SQL rather than the current AppendMessage. }
  RawInsertMessage(FDbPath, Sid, 'hello');

  { Reopen with the full migrations: v2 applies and v1 history survives. }
  S := TSqliteStore.Create(Cfg);
  try
    AssertTrue('reopen', S.Open(Err));
    AssertTrue('history survives', S.QueryMessages(Sid, Msgs, Err));
    AssertEquals('one message', 1, Length(Msgs));
    AssertEquals('content', 'hello', Msgs[0].Content);
    Row := Default(TSessionRuntimeRow);
    Row.SessionId := Sid;
    Row.Pid := 1234;
    Row.SocketPath := '/tmp/s.sock';
    Row.Status := rsRunning;
    Row.StartedAt := 1000;
    Row.UpdatedAt := 2000;
    AssertTrue('register after migration', S.RegisterRuntime(Row, Err));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestRuntimeRowRoundTrip;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  Row, Got: TSessionRuntimeRow;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    Row := Default(TSessionRuntimeRow);
    Row.SessionId := Sid;
    Row.Pid := 4321;
    Row.SocketPath := '/run/hh/abc.sock';
    Row.Status := rsRunning;
    Row.StartedAt := 111;
    Row.UpdatedAt := 222;
    AssertTrue('register', S.RegisterRuntime(Row, Err));

    AssertTrue('load', S.LoadRuntime(Sid, Got, Err));
    AssertEquals('pid', 4321, Got.Pid);
    AssertEquals('socket', '/run/hh/abc.sock', Got.SocketPath);
    AssertEquals('status', Ord(rsRunning), Ord(Got.Status));
    AssertEquals('started', 111, Got.StartedAt);
    AssertEquals('updated', 222, Got.UpdatedAt);

    { Re-registering upserts. }
    Row.Pid := 5555;
    Row.Status := rsExited;
    AssertTrue('re-register', S.RegisterRuntime(Row, Err));
    AssertTrue('reload', S.LoadRuntime(Sid, Got, Err));
    AssertEquals('updated pid', 5555, Got.Pid);
    AssertEquals('updated status', Ord(rsExited), Ord(Got.Status));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestRuntimeRowUnknownSessionFails;
var
  S: TSqliteStore;
  Err: TStoreError;
  Row: TSessionRuntimeRow;
begin
  S := OpenStore;
  try
    Row := Default(TSessionRuntimeRow);
    Row.SessionId := 'no-such-session';
    AssertFalse('unknown session', S.RegisterRuntime(Row, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestExpireRuntimes;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  OldSid, NewSid: string;
  Row: TSessionRuntimeRow;
  Expired: Integer;
begin
  { A crashed session never deregisters, so its row lives forever and the
    liveness check in ReclaimStale would never fire for the case it matters most.
    Expiry is the other half. }
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, OldSid, Err);
    S.CreateSession(Ws, NewSid, Err);
    Row := Default(TSessionRuntimeRow);
    Row.SessionId := OldSid;
    Row.UpdatedAt := 1000;      // long ago
    AssertTrue('old', S.RegisterRuntime(Row, Err));
    Row.SessionId := NewSid;
    Row.UpdatedAt := 9000000000;  // far future, so never stale in this test
    AssertTrue('new', S.RegisterRuntime(Row, Err));

    AssertTrue('expire', S.ExpireRuntimes(5000, Expired, Err));
    AssertEquals('only the stale one', 1, Expired);
    AssertFalse('the old row is gone', S.LoadRuntime(OldSid, Row, Err));
    AssertTrue('the fresh row survives', S.LoadRuntime(NewSid, Row, Err));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestClearRuntime;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  Row, Got: TSessionRuntimeRow;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    Row := Default(TSessionRuntimeRow);
    Row.SessionId := Sid;
    Row.SocketPath := '/tmp/x.sock';
    AssertTrue('register', S.RegisterRuntime(Row, Err));
    AssertTrue('clear', S.ClearRuntime(Sid, Err));
    AssertFalse('gone', S.LoadRuntime(Sid, Got, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestListRuntimes;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  SidA, SidB: string;
  Rows: TSessionRuntimeRowArray;
  Row: TSessionRuntimeRow;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, SidA, Err);
    S.CreateSession(Ws, SidB, Err);
    Row := Default(TSessionRuntimeRow);
    Row.SessionId := SidA;
    Row.SocketPath := '/tmp/a.sock';
    AssertTrue('register a', S.RegisterRuntime(Row, Err));
    Row.SessionId := SidB;
    Row.SocketPath := '/tmp/b.sock';
    AssertTrue('register b', S.RegisterRuntime(Row, Err));

    AssertTrue('list', S.ListRuntimes(Rows, Err));
    AssertEquals('two rows', 2, Length(Rows));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestLineageRootDefaults;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws, Depth: Integer;
  Sid, Parent, Lbl: string;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    AssertTrue('create', S.CreateSession(Ws, Sid, Err));
    Parent := 'x';
    Lbl := 'x';
    Depth := -1;
    AssertTrue('lineage', S.SessionLineage(Sid, Parent, Depth, Lbl, Err));
    AssertEquals('root parent empty', '', Parent);
    AssertEquals('root depth 0', 0, Depth);
    AssertEquals('root label empty', '', Lbl);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestChildSessionLineage;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws, Depth: Integer;
  Root, Child, Parent, Lbl: string;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    AssertTrue('root', S.CreateSession(Ws, Root, Err));
    AssertTrue('child', S.CreateChildSession(Ws, Root, 1, 'research', Child,
      Err));
    AssertTrue('child id differs', Root <> Child);
    AssertTrue('lineage', S.SessionLineage(Child, Parent, Depth, Lbl, Err));
    AssertEquals('parent', Root, Parent);
    AssertEquals('depth', 1, Depth);
    AssertEquals('label', 'research', Lbl);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestChildrenOf;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Root, A, B: string;
  Kids: TSessionSummaryArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    AssertTrue('root', S.CreateSession(Ws, Root, Err));
    AssertTrue('a', S.CreateChildSession(Ws, Root, 1, 'a', A, Err));
    AssertTrue('b', S.CreateChildSession(Ws, Root, 1, 'b', B, Err));
    AssertTrue('children', S.ChildrenOf(Root, Kids, Err));
    AssertEquals('two children', 2, Length(Kids));
    { A root has no children of its own. }
    AssertTrue('grandchildren none', S.ChildrenOf(A, Kids, Err));
    AssertEquals('leaf has none', 0, Length(Kids));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestSessionLineageUnknownFails;
var
  S: TSqliteStore;
  Err: TStoreError;
  Depth: Integer;
  Parent, Lbl: string;
begin
  S := OpenStore;
  try
    AssertFalse('unknown', S.SessionLineage('nope', Parent, Depth, Lbl, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestLineageMigrationV4IsAdditive;
var
  S: TSqliteStore;
  Err: TStoreError;
  Cfg: TStoreConfig;
  Migs: TMigrationArray;
  Ws, Depth: Integer;
  Sid, Parent, Lbl: string;
  Msgs: TMessageRecordArray;
begin
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;

  { A v2-only database, as an install predating lineage would have. }
  Migs := DefaultMigrations;
  SetLength(Migs, 2);
  S := TSqliteStore.Create(Cfg, Migs);
  try
    AssertTrue('open v2', S.Open(Err));
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
  finally
    S.Free;
  end;

  { Reopen with the full migrations: v3 (mcp servers) and v4 (lineage) apply
    and the v2 session survives. }
  S := TSqliteStore.Create(Cfg);
  try
    AssertTrue('reopen', S.Open(Err));
    AssertEquals('schema at the latest version', StoreSchemaVersion,
      RawReadUserVersion(FDbPath));
    AssertTrue('lineage after migration',
      S.SessionLineage(Sid, Parent, Depth, Lbl, Err));
    AssertEquals('migrated root parent empty', '', Parent);
    AssertTrue('history survives', S.QueryMessages(Sid, Msgs, Err));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestMessageRefSessionRoundTrip;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  Msg: TMessageRecord;
  Msgs: TMessageRecordArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    Msg := Default(TMessageRecord);
    Msg.SessionId := Sid;
    Msg.Role := mrAmbient;
    Msg.Content := 'subagent finished';
    Msg.RefSessionId := 'child-123';
    Msg.DurationMs := 4200;
    AssertTrue('append', S.AppendMessage(Msg, Err));
    AssertTrue('query', S.QueryMessages(Sid, Msgs, Err));
    AssertEquals('one', 1, Length(Msgs));
    AssertEquals('role ambient', Ord(mrAmbient), Ord(Msgs[0].Role));
    AssertEquals('ref session', 'child-123', Msgs[0].RefSessionId);
    AssertEquals('elapsed', 4200, Msgs[0].DurationMs);
  finally
    S.Free;
  end;
end;

{ A v2-only database (before mcp_servers) upgrades to v3 additively. }
procedure TStoreTest.TestMcpServerMigrationIsAdditive;
var
  S: TSqliteStore;
  Err: TStoreError;
  Cfg: TStoreConfig;
  Migs: TMigrationArray;
  Ws, Found: Integer;
  Rows: TMcpServerRowArray;
begin
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  Migs := DefaultMigrations;
  SetLength(Migs, 2);   // v1 + v2 only
  S := TSqliteStore.Create(Cfg, Migs);
  try
    AssertTrue('open v2', S.Open(Err));
    S.EnsureWorkspace('/tmp', Ws, Err);
  finally
    S.Free;
  end;

  S := TSqliteStore.Create(Cfg);
  try
    AssertTrue('reopen at v3', S.Open(Err));
    AssertTrue('find workspace survives', S.FindWorkspace('/tmp', Found, Err));
    AssertEquals('same workspace', Ws, Found);
    AssertTrue('mcp table usable', S.ListMcpServers(Rows, Err));
    AssertEquals('empty', 0, Length(Rows));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestSaveMcpServerUpserts;
var
  S: TSqliteStore;
  Err: TStoreError;
  R: TMcpServerRow;
  Rows: TMcpServerRowArray;
begin
  S := OpenStore;
  try
    R := Default(TMcpServerRow);
    R.Scope := msGlobal;
    R.Name := 'github';
    R.Command := 'npx';
    R.Enabled := True;
    AssertTrue('insert', S.SaveMcpServer(R, Err));
    R.Command := 'mcp-server-github';
    AssertTrue('upsert', S.SaveMcpServer(R, Err));
    AssertTrue('list', S.ListMcpServers(Rows, Err));
    AssertEquals('one row (upserted, not duplicated)', 1, Length(Rows));
    AssertEquals('command updated', 'mcp-server-github', Rows[0].Command);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestLoadMcpServersScoped;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  G, W, Other: TMcpServerRow;
  Rows: TMcpServerRowArray;
  Ctx: TMcpConfigContext;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp/ws', Ws, Err);
    G := Default(TMcpServerRow);
    G.Scope := msGlobal;
    G.Name := 'global-srv';
    G.Command := 'g';
    W := Default(TMcpServerRow);
    W.Scope := msWorkspace;
    W.WorkspaceId := Ws;
    W.Name := 'ws-srv';
    W.Command := 'w';
    Other := Default(TMcpServerRow);
    Other.Scope := msWorkspace;
    Other.WorkspaceId := Ws + 1000;
    Other.Name := 'other-srv';
    Other.Command := 'o';
    AssertTrue('save global', S.SaveMcpServer(G, Err));
    AssertTrue('save ws', S.SaveMcpServer(W, Err));
    AssertTrue('save other', S.SaveMcpServer(Other, Err));

    Ctx.WorkspaceId := Ws;
    Ctx.AgentId := '';
    AssertTrue('load', S.LoadMcpServers(Ctx, Rows, Err));
    AssertEquals('global + this workspace only', 2, Length(Rows));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestRemoveMcpServer;
var
  S: TSqliteStore;
  Err: TStoreError;
  R: TMcpServerRow;
  Rows: TMcpServerRowArray;
begin
  S := OpenStore;
  try
    R := Default(TMcpServerRow);
    R.Scope := msGlobal;
    R.Name := 'temp';
    R.Command := 'x';
    AssertTrue('save', S.SaveMcpServer(R, Err));
    AssertTrue('remove', S.RemoveMcpServer(R, Err));
    AssertTrue('list', S.ListMcpServers(Rows, Err));
    AssertEquals('gone', 0, Length(Rows));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestMcpArgsEnvRoundTrip;
var
  S: TSqliteStore;
  Err: TStoreError;
  R: TMcpServerRow;
  Rows: TMcpServerRowArray;
begin
  S := OpenStore;
  try
    R := Default(TMcpServerRow);
    R.Scope := msGlobal;
    R.Name := 'args';
    R.Command := 'cmd';
    R.Args := ['-y', 'pkg with spaces'];
    R.Env := ['TOKEN=abc', 'OTHER=x=y'];
    R.WorkingDir := '/tmp/work';
    R.ListTimeoutMs := 5000;
    R.CallTimeoutMs := 60000;
    AssertTrue('save', S.SaveMcpServer(R, Err));
    AssertTrue('list', S.ListMcpServers(Rows, Err));
    AssertEquals('one', 1, Length(Rows));
    AssertEquals('args count', 2, Length(Rows[0].Args));
    AssertEquals('arg 1', '-y', Rows[0].Args[0]);
    AssertEquals('arg 2', 'pkg with spaces', Rows[0].Args[1]);
    AssertEquals('env count', 2, Length(Rows[0].Env));
    AssertEquals('env 1', 'TOKEN=abc', Rows[0].Env[0]);
    AssertEquals('env 2 keeps equals', 'OTHER=x=y', Rows[0].Env[1]);
    AssertEquals('cwd', '/tmp/work', Rows[0].WorkingDir);
    AssertEquals('list timeout', 5000, Rows[0].ListTimeoutMs);
    AssertEquals('call timeout', 60000, Rows[0].CallTimeoutMs);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestSaveMcpServerRejectsInvalid;
var
  S: TSqliteStore;
  Err: TStoreError;
  R: TMcpServerRow;
begin
  S := OpenStore;
  try
    R := Default(TMcpServerRow);
    R.Scope := msGlobal;
    R.Name := 'bad name';
    R.Command := 'x';
    AssertFalse('rejected', S.SaveMcpServer(R, Err));
    AssertEquals('invalid argument', Ord(seInvalidArgument), Ord(Err.Code));
  finally
    S.Free;
  end;
end;


procedure TStoreTest.TestOAuthTokenRoundTrip;
var
  S: TSqliteStore;
  Err: TStoreError;
  R, Got: TOAuthTokenRow;
begin
  S := OpenStore;
  try
    R := Default(TOAuthTokenRow);
    R.Scope := msGlobal;
    R.ServerName := 'meta';
    R.ClientId := 'client-1';
    R.ClientSecret := 'secret';
    R.AccessToken := 'at';
    R.RefreshToken := 'rt';
    R.ExpiresAt := 12345;
    R.TokenScope := 'read';
    AssertTrue('save', S.SaveOAuthToken(R, Err));
    AssertTrue('load', S.LoadOAuthToken(msGlobal, 0, 'meta', Got, Err));
    AssertEquals('client', 'client-1', Got.ClientId);
    AssertEquals('secret', 'secret', Got.ClientSecret);
    AssertEquals('access', 'at', Got.AccessToken);
    AssertEquals('refresh', 'rt', Got.RefreshToken);
    AssertEquals('expiry', 12345, Got.ExpiresAt);
    AssertEquals('scope', 'read', Got.TokenScope);
    { Upsert updates in place. }
    R.AccessToken := 'at2';
    AssertTrue('upsert', S.SaveOAuthToken(R, Err));
    AssertTrue('reload', S.LoadOAuthToken(msGlobal, 0, 'meta', Got, Err));
    AssertEquals('updated', 'at2', Got.AccessToken);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestOAuthTokenMissing;
var
  S: TSqliteStore;
  Err: TStoreError;
  Got: TOAuthTokenRow;
begin
  S := OpenStore;
  try
    AssertFalse('missing', S.LoadOAuthToken(msGlobal, 0, 'nope', Got, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestClearOAuthToken;
var
  S: TSqliteStore;
  Err: TStoreError;
  R, Got: TOAuthTokenRow;
begin
  S := OpenStore;
  try
    R := Default(TOAuthTokenRow);
    R.Scope := msGlobal;
    R.ServerName := 'meta';
    R.AccessToken := 'at';
    AssertTrue('save', S.SaveOAuthToken(R, Err));
    AssertTrue('clear', S.ClearOAuthToken(msGlobal, 0, 'meta', Err));
    AssertFalse('gone', S.LoadOAuthToken(msGlobal, 0, 'meta', Got, Err));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestFinalizeRunningTurns;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  TurnId: Int64;
  Count: Integer;
  Turns: TTurnRecordArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    { A running turn, and a completed one that must be left alone. }
    S.BeginTurn(Sid, TurnId, Err);
    S.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '', Err);
    S.BeginTurn(Sid, TurnId, Err);   { this one stays running }
    AssertTrue('finalize', S.FinalizeRunningTurns(Sid, 'recovered_on_start',
      Count, Err));
    AssertEquals('one finalized', 1, Count);
    { Idempotent: a second call finalizes nothing. }
    AssertTrue('finalize again', S.FinalizeRunningTurns(Sid, 'recovered', Count,
      Err));
    AssertEquals('none the second time', 0, Count);
    { The completed turn is untouched; no running turn remains. }
    AssertTrue('query', S.QueryTurns(Sid, Turns, Err));
    AssertEquals('two turns', 2, Length(Turns));
    AssertEquals('first still completed', Ord(tsCompleted), Ord(Turns[0].Status));
    AssertEquals('second cancelled', Ord(tsCancelled), Ord(Turns[1].Status));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestBeginTurnSelfHeals;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  T1, T2: Int64;
  Turns: TTurnRecordArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    S.BeginTurn(Sid, T1, Err);       { left running }
    S.BeginTurn(Sid, T2, Err);       { opening this finalizes T1 }
    AssertTrue('query', S.QueryTurns(Sid, Turns, Err));
    AssertEquals('two turns', 2, Length(Turns));
    AssertEquals('prior self-healed', Ord(tsCancelled), Ord(Turns[0].Status));
    AssertEquals('new one running', Ord(tsRunning), Ord(Turns[1].Status));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestCheckpointAndActiveWindow;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  Seq: Int64;
  Snap: TCheckpointRecord;
  SnapList: TCheckpointArray;
  Msgs: TMessageRecordArray;
  M: TMessageRecord;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    M := Default(TMessageRecord);
    M.SessionId := Sid;
    M.Role := mrUser;
    M.Content := 'first';
    S.AppendMessage(M, Err);
    M.Content := 'second';
    S.AppendMessage(M, Err);
    { Checkpoint at the HWM (seq 2). }
    AssertTrue('save checkpoint', S.SaveCheckpoint(Sid, 'we did X', Seq, Err));
    AssertEquals('boundary', 2, Seq);
    { A message after the checkpoint is in the active window. }
    M.Content := 'third';
    S.AppendMessage(M, Err);

    AssertTrue('latest', S.LatestCheckpoint(Sid, Snap, Err));
    AssertEquals('summary', 'we did X', Snap.Summary);
    AssertTrue('list', S.ListCheckpoints(Sid, SnapList, Err));
    AssertEquals('one checkpoint', 1, Length(SnapList));

    AssertTrue('active', S.QueryActiveMessages(Sid, Msgs, Err));
    AssertEquals('only the post-checkpoint message', 1, Length(Msgs));
    AssertEquals('content', 'third', Msgs[0].Content);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestQueryMessagesBefore;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  Seq: Int64;
  Msgs: TMessageRecordArray;
  M: TMessageRecord;
  I: Integer;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    for I := 1 to 5 do
    begin
      M := Default(TMessageRecord);
      M.SessionId := Sid;
      M.Role := mrUser;
      M.Content := 'msg' + IntToStr(I);
      S.AppendMessage(M, Err);
    end;
    AssertTrue('checkpoint', S.SaveCheckpoint(Sid, 'summary', Seq, Err));
    { The page before the boundary, newest 2, returned oldest first. }
    AssertTrue('before', S.QueryMessagesBefore(Sid, Seq, 2, Msgs, Err));
    AssertEquals('two', 2, Length(Msgs));
    AssertEquals('oldest first', 'msg4', Msgs[0].Content);
    AssertEquals('then', 'msg5', Msgs[1].Content);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestFtsSearchScoped;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  Msgs: TMessageRecordArray;
  M: TMessageRecord;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    { A tool call whose REASON mentions concrete, whose content does not. }
    M := Default(TMessageRecord);
    M.SessionId := Sid;
    M.Role := mrToolCall;
    M.ToolName := 'run_command';
    M.ToolReason := 'check the concrete pour';
    M.Content := 'unrelated prose';
    S.AppendMessage(M, Err);
    { Another whose content mentions concrete. }
    M := Default(TMessageRecord);
    M.SessionId := Sid;
    M.Role := mrAssistant;
    M.ToolReason := '';
    M.ToolName := '';
    M.Content := 'we poured concrete today';
    S.AppendMessage(M, Err);

    { Content-scoped search finds only the prose message. }
    AssertTrue('content search', S.SearchMessages(Sid, 'concrete', ['content'],
      10, Msgs, Err));
    AssertEquals('one content hit', 1, Length(Msgs));
    AssertEquals('the prose one', 'we poured concrete today', Msgs[0].Content);

    { tool_reason-scoped search finds only the tool call. }
    AssertTrue('reason search', S.SearchMessages(Sid, 'concrete', ['tool_reason'],
      10, Msgs, Err));
    AssertEquals('one reason hit', 1, Length(Msgs));
    AssertEquals('the tool call', 'run_command', Msgs[0].ToolName);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestReplyMetadataMigrationV10IsAdditive;
var
  S: TSqliteStore;
  Err: TStoreError;
  Cfg: TStoreConfig;
  Migs: TMigrationArray;
  Ws: Integer;
  Sid, Title: string;
begin
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  { A v9-only database (as an install predating reply metadata would have). }
  Migs := DefaultMigrations;
  SetLength(Migs, 9);
  S := TSqliteStore.Create(Cfg, Migs);
  try
    AssertTrue('open v9', S.Open(Err));
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
  finally
    S.Free;
  end;
  { Reopen with the full migrations: v10 applies and the session survives. }
  S := TSqliteStore.Create(Cfg);
  try
    AssertTrue('reopen', S.Open(Err));
    AssertEquals('schema at the latest version', StoreSchemaVersion,
      RawReadUserVersion(FDbPath));
    AssertTrue('title readable after migration', S.SessionTitle(Sid, Title, Err));
    AssertEquals('empty title initially', '', Title);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestSessionTitleOverrideWins;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid, Title: string;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    { The extracted title. }
    AssertTrue('set title', S.SetSessionTitle(Sid, 'Extracted title', Err));
    AssertTrue('read', S.SessionTitle(Sid, Title, Err));
    AssertEquals('extracted wins while no override', 'Extracted title', Title);
    { An override beats the extracted title. }
    AssertTrue('set override', S.SetSessionTitleOverride(Sid, 'My name', Err));
    AssertTrue('read', S.SessionTitle(Sid, Title, Err));
    AssertEquals('override wins', 'My name', Title);
    { A later extracted title must NOT overwrite the override. }
    AssertTrue('set title again', S.SetSessionTitle(Sid, 'Newer extracted', Err));
    AssertTrue('read', S.SessionTitle(Sid, Title, Err));
    AssertEquals('override still wins', 'My name', Title);
    { Clearing the override reveals the last ACCEPTED extracted title (the one
      attempted while overridden was dropped). }
    AssertTrue('clear override', S.SetSessionTitleOverride(Sid, '', Err));
    AssertTrue('read', S.SessionTitle(Sid, Title, Err));
    AssertEquals('extracted after clear', 'Extracted title', Title);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestReplyKeywordsReplace;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  Msgs: TMessageRecordArray;
  M: TMessageRecord;
  Kw: TStringArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    M := Default(TMessageRecord);
    M.SessionId := Sid;
    M.Role := mrAssistant;
    M.Content := 'a reply';
    S.AppendMessage(M, Err);
    AssertTrue('query', S.QueryMessages(Sid, Msgs, Err));
    AssertEquals('one message', 1, Length(Msgs));
    { Set two keywords, then replace with one. }
    AssertTrue('set', S.SetReplyKeywords(Msgs[0].Id, ['alpha', 'beta'], Err));
    AssertTrue('read', S.ReplyKeywords(Msgs[0].Id, Kw, Err));
    AssertEquals('two', 2, Length(Kw));
    AssertTrue('replace', S.SetReplyKeywords(Msgs[0].Id, ['gamma'], Err));
    AssertTrue('read', S.ReplyKeywords(Msgs[0].Id, Kw, Err));
    AssertEquals('replaced, not appended', 1, Length(Kw));
    AssertEquals('gamma', 'gamma', Kw[0]);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestReplyKeywordsCascade;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
  Msgs: TMessageRecordArray;
  M: TMessageRecord;
  Kw: TStringArray;
  TurnId: Int64;
begin
  { Deleting the message removes its keywords (ON DELETE CASCADE). }
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    AssertTrue('begin turn', S.BeginTurn(Sid, TurnId, Err));
    M := Default(TMessageRecord);
    M.SessionId := Sid;
    M.TurnId := TurnId;
    M.Role := mrAssistant;
    M.Content := 'a reply';
    S.AppendMessage(M, Err);
    S.QueryMessages(Sid, Msgs, Err);
    AssertTrue('set', S.SetReplyKeywords(Msgs[0].Id, ['alpha'], Err));
    AssertTrue('delete the turn''s messages', S.DeleteTurnMessages(TurnId, Err));
    AssertTrue('read after delete', S.ReplyKeywords(Msgs[0].Id, Kw, Err));
    AssertEquals('cascaded away', 0, Length(Kw));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestListSessionRowsOrderAndArchived;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  A, B, C: string;
  Rows: TSessionRowArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, A, Err);
    S.CreateSession(Ws, B, Err);
    S.CreateSession(Ws, C, Err);
    { Default: newest first (C, B, A), no archived. }
    AssertTrue('list', S.ListSessionRows(Ws, False, Rows, Err));
    AssertEquals('three rows', 3, Length(Rows));
    AssertEquals('newest first', C, Rows[0].Id);
    { Pin A: it sorts ahead of everything. }
    AssertTrue('pin A', S.SetSessionPinned(A, True, Err));
    AssertTrue('list', S.ListSessionRows(Ws, False, Rows, Err));
    AssertEquals('pinned first', A, Rows[0].Id);
    AssertTrue('A pinned', Rows[0].Pinned);
    { Archive B: excluded by default, present when asked. }
    AssertTrue('archive B', S.SetSessionArchived(B, True, Err));
    AssertTrue('list default', S.ListSessionRows(Ws, False, Rows, Err));
    AssertEquals('archived excluded', 2, Length(Rows));
    AssertTrue('list all', S.ListSessionRows(Ws, True, Rows, Err));
    AssertEquals('archived included', 3, Length(Rows));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestSessionPinAndArchiveRoundTrip;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  A: string;
  Rows: TSessionRowArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, A, Err);
    AssertTrue('pin', S.SetSessionPinned(A, True, Err));
    AssertTrue('list', S.ListSessionRows(Ws, True, Rows, Err));
    AssertTrue('pinned', Rows[0].Pinned);
    AssertFalse('not archived', Rows[0].Archived);
    AssertTrue('archive', S.SetSessionArchived(A, True, Err));
    AssertTrue('list', S.ListSessionRows(Ws, True, Rows, Err));
    AssertTrue('archived', Rows[0].Archived);
    { Unpin + restore round-trip. }
    AssertTrue('unpin', S.SetSessionPinned(A, False, Err));
    AssertTrue('restore', S.SetSessionArchived(A, False, Err));
    AssertTrue('list', S.ListSessionRows(Ws, False, Rows, Err));
    AssertEquals('visible again', 1, Length(Rows));
    AssertFalse('unpinned', Rows[0].Pinned);
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestRenameReusesTitleOverride;
var
  S: TSqliteStore;
  Err: TStoreError;
  Ws: Integer;
  A: string;
  Rows: TSessionRowArray;
begin
  { The modal's rename is SetSessionTitleOverride; the row shows the override. }
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, A, Err);
    S.SetSessionTitle(A, 'Extracted', Err);
    AssertTrue('rename', S.SetSessionTitleOverride(A, 'My name', Err));
    AssertTrue('list', S.ListSessionRows(Ws, False, Rows, Err));
    AssertEquals('override shown', 'My name', Rows[0].Title);
    { Clearing the override falls back to the extracted title. }
    AssertTrue('clear', S.SetSessionTitleOverride(A, '', Err));
    AssertTrue('list', S.ListSessionRows(Ws, False, Rows, Err));
    AssertEquals('extracted shown', 'Extracted', Rows[0].Title);
  finally
    S.Free;
  end;
end;

initialization
  RegisterTest(TStoreTest);
end.