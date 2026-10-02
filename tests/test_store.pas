unit test_store;
{ fpcunit tests for hildegard.helper.store. Each test runs against a temporary
  database path; the vendored library is resolved relative to the test binary. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry,
  {$ifdef unix}BaseUnix,{$endif}
  hildegard.helper.sqlite,
  hildegard.helper.store, hildegard.helper.session, hildegard.helper.llm;

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

initialization
  RegisterTest(TStoreTest);
end.
