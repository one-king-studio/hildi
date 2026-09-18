unit test_store;
{ fpcunit tests for hildegard.helper.store. Each test runs against a temporary
  database path; the vendored library is resolved relative to the test binary. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry,
  {$ifdef unix}BaseUnix,{$endif}
  sqldb, sqlite3conn, sqldblib,
  hildegard.helper.store;

type
  { Enqueues a batch of requests from a thread. }
  TEnqueueThread = class(TThread)
  private
    FStore: TSqliteStore;
    FPrefix: string;
    FCount: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AStore: TSqliteStore; const APrefix: string; ACount: Integer);
  end;

  { Claims requests until the queue is empty, recording ids thread-safely. }
  TClaimThread = class(TThread)
  private
    FStore: TSqliteStore;
    FLock: TCriticalSection;
    FIds: TStringList;
  protected
    procedure Execute; override;
  public
    constructor Create(AStore: TSqliteStore; ALock: TCriticalSection;
      AIds: TStringList);
  end;

  TStoreTest = class(TTestCase)
  private
    FDir: string;
    FDbPath: string;
    function NewStore: TSqliteStore;
    function OpenStore: TSqliteStore;
    function CountUnique(const AList: TStrings): Integer;
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
    procedure TestLibraryPathResolutionPrefersExplicit;
    procedure TestStoreWorksWithVendoredLibrary;

    procedure TestOperationsBeforeOpenReturnNotOpen;
    procedure TestSaveLoadClearCredentialsRoundTrip;
    procedure TestLoadCredentialsMissingReturnsNotFound;
    procedure TestCredentialsPersistAcrossReopen;

    procedure TestEnqueueThenClaimReturnsRequest;
    procedure TestClaimEmptyQueueReturnsNotFound;
    procedure TestFinishMarksTerminalAndIsNotReclaimable;
    procedure TestFinishRejectsNonTerminalStatus;
    procedure TestDuplicateRequestIdRejected;
    procedure TestQueryByStatusAndPagination;
    procedure TestRequestHistoryPersistsAcrossReopen;

    procedure TestSettingSetGetOverwriteDelete;
    procedure TestSettingMissingReturnsNotFound;
    procedure TestParameterizedValuesWithQuotesRoundTrip;

    procedure TestFailedMigrationRollsBackAndKeepsVersion;
    procedure TestClaimIsAtomicAcrossThreads;
    procedure TestConcurrentOperationsDoNotCorruptOrDeadlock;
  end;

implementation

const
  TestLibPath = '';   // resolve relative to the test binary (build/bin -> build/lib)

{ Reads PRAGMA user_version through a direct SQLDB connection. Test-only: lets
  us assert the schema version without exposing it on the store's public API. }
function RawReadUserVersion(const APath: string): Integer;
var
  Loader: TSQLDBLibraryLoader;
  Conn: TSQLite3Connection;
  Tx: TSQLTransaction;
  Q: TSQLQuery;
begin
  Result := -1;
  Loader := TSQLDBLibraryLoader.Create(nil);
  Conn := TSQLite3Connection.Create(nil);
  Tx := TSQLTransaction.Create(nil);
  Q := TSQLQuery.Create(nil);
  try
    Loader.ConnectionType := 'SQLite3';
    Loader.LibraryName := ResolveLibraryPath('');
    Loader.LoadLibrary;
    Conn.DatabaseName := APath;
    Conn.Transaction := Tx;
    Conn.Open;
    Q.DataBase := Conn;
    Q.Transaction := Tx;
    Q.SQL.Text := 'PRAGMA user_version';
    Q.Open;
    Result := Q.Fields[0].AsInteger;
    Q.Close;
    Conn.Close;
  finally
    Q.Free;
    Tx.Free;
    Conn.Free;
    Loader.Free;
  end;
end;

{ TEnqueueThread }

constructor TEnqueueThread.Create(AStore: TSqliteStore; const APrefix: string;
  ACount: Integer);
begin
  inherited Create(True);
  FStore := AStore;
  FPrefix := APrefix;
  FCount := ACount;
  FreeOnTerminate := False;
end;

procedure TEnqueueThread.Execute;
var
  I: Integer;
  Req: TStoredRequest;
  Err: TStoreError;
begin
  for I := 0 to FCount - 1 do
  begin
    Req := Default(TStoredRequest);
    Req.Id := FPrefix + IntToStr(I);
    Req.Kind := 'shell';
    Req.Payload := '{}';
    FStore.EnqueueRequest(Req, Err);
  end;
end;

{ TClaimThread }

constructor TClaimThread.Create(AStore: TSqliteStore; ALock: TCriticalSection;
  AIds: TStringList);
begin
  inherited Create(True);
  FStore := AStore;
  FLock := ALock;
  FIds := AIds;
  FreeOnTerminate := False;
end;

procedure TClaimThread.Execute;
var
  Req: TStoredRequest;
  Err: TStoreError;
begin
  while FStore.ClaimNextPending(Req, Err) do
  begin
    FLock.Acquire;
    try
      FIds.Add(Req.Id);
    finally
      FLock.Release;
    end;
  end;
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
  Cfg.LibraryPath := TestLibPath;
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

function TStoreTest.CountUnique(const AList: TStrings): Integer;
var
  I: Integer;
  Seen: TStringList;
begin
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.Duplicates := dupIgnore;
    for I := 0 to AList.Count - 1 do
      Seen.Add(AList[I]);
    Result := Seen.Count;
  finally
    Seen.Free;
  end;
end;

{ --- open / migrations --- }

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
  Cfg.LibraryPath := TestLibPath;
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

procedure TStoreTest.TestLibraryPathResolutionPrefersExplicit;
begin
  AssertEquals('explicit wins', '/custom/libsqlite3',
    ResolveLibraryPath('/custom/libsqlite3'));
end;

procedure TStoreTest.TestStoreWorksWithVendoredLibrary;
var
  Resolved: string;
begin
  Resolved := ResolveLibraryPath('');
  AssertTrue('resolved a library path', Resolved <> '');
  AssertTrue('resolved library exists: ' + Resolved, FileExists(Resolved));
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

procedure TStoreTest.TestEnqueueThenClaimReturnsRequest;
var
  S: TSqliteStore;
  Err: TStoreError;
  Req, Claimed: TStoredRequest;
begin
  S := OpenStore;
  try
    Req := Default(TStoredRequest);
    Req.Id := 'r1';
    Req.Kind := 'shell';
    Req.Payload := '{"cmd":"date"}';
    AssertTrue('enqueue', S.EnqueueRequest(Req, Err));

    AssertTrue('claim', S.ClaimNextPending(Claimed, Err));
    AssertEquals('id', 'r1', Claimed.Id);
    AssertEquals('kind', 'shell', Claimed.Kind);
    AssertEquals('payload', '{"cmd":"date"}', Claimed.Payload);
    AssertEquals('claimed status', Ord(rsClaimed), Ord(Claimed.Status));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestClaimEmptyQueueReturnsNotFound;
var
  S: TSqliteStore;
  Err: TStoreError;
  Claimed: TStoredRequest;
begin
  S := OpenStore;
  try
    AssertFalse(S.ClaimNextPending(Claimed, Err));
    AssertEquals('not found', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestFinishMarksTerminalAndIsNotReclaimable;
var
  S: TSqliteStore;
  Err: TStoreError;
  Req, Claimed, Got: TStoredRequest;
begin
  S := OpenStore;
  try
    Req := Default(TStoredRequest);
    Req.Id := 'r-fin';
    Req.Kind := 'shell';
    Req.Payload := '{}';
    S.EnqueueRequest(Req, Err);
    S.ClaimNextPending(Claimed, Err);
    AssertTrue('finish', S.FinishRequest('r-fin', rsCompleted, 0, 'done', Err));
    AssertTrue('get', S.GetRequest('r-fin', Got, Err));
    AssertEquals('completed', Ord(rsCompleted), Ord(Got.Status));
    AssertEquals('result', 'done', Got.Result);
    AssertFalse('nothing left to claim', S.ClaimNextPending(Claimed, Err));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestFinishRejectsNonTerminalStatus;
var
  S: TSqliteStore;
  Err: TStoreError;
  Req: TStoredRequest;
begin
  S := OpenStore;
  try
    Req := Default(TStoredRequest);
    Req.Id := 'r-nonterm';
    Req.Kind := 'shell';
    Req.Payload := '{}';
    S.EnqueueRequest(Req, Err);
    AssertFalse('pending is not terminal',
      S.FinishRequest('r-nonterm', rsPending, 0, '', Err));
    AssertEquals('invalid argument', Ord(seInvalidArgument), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestDuplicateRequestIdRejected;
var
  S: TSqliteStore;
  Err: TStoreError;
  Req: TStoredRequest;
begin
  S := OpenStore;
  try
    Req := Default(TStoredRequest);
    Req.Id := 'dup';
    Req.Kind := 'shell';
    Req.Payload := '{}';
    AssertTrue('first', S.EnqueueRequest(Req, Err));
    AssertFalse('second rejected', S.EnqueueRequest(Req, Err));
    AssertEquals('constraint', Ord(seConstraint), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestQueryByStatusAndPagination;
var
  S: TSqliteStore;
  Err: TStoreError;
  Req: TStoredRequest;
  Q: TRequestQuery;
  List: TStoredRequestArray;
  I: Integer;
begin
  S := OpenStore;
  try
    for I := 0 to 4 do
    begin
      Req := Default(TStoredRequest);
      Req.Id := 'q' + IntToStr(I);
      Req.Kind := 'shell';
      Req.Payload := '{}';
      Req.CreatedAtMs := 1000 + I;
      S.EnqueueRequest(Req, Err);
    end;

    Q.UseStatus := False;
    Q.Limit := 2;
    Q.Offset := 0;
    AssertTrue('query page 1', S.QueryRequests(Q, List, Err));
    AssertEquals('page size', 2, Length(List));
    AssertEquals('ordered', 'q0', List[0].Id);

    Q.UseStatus := False;
    Q.Limit := 2;
    Q.Offset := 2;
    AssertTrue('query page 2', S.QueryRequests(Q, List, Err));
    AssertEquals('page 2 size', 2, Length(List));
    AssertEquals('ordered offset', 'q2', List[0].Id);

    Q.UseStatus := True;
    Q.Status := rsPending;
    Q.Limit := 0;
    Q.Offset := 0;
    AssertTrue('all pending', S.QueryRequests(Q, List, Err));
    AssertEquals('all five pending', 5, Length(List));
  finally
    S.Free;
  end;
end;

procedure TStoreTest.TestRequestHistoryPersistsAcrossReopen;
var
  S: TSqliteStore;
  Err: TStoreError;
  Req, Got: TStoredRequest;
begin
  S := OpenStore;
  try
    Req := Default(TStoredRequest);
    Req.Id := 'persist-req';
    Req.Kind := 'script';
    Req.Payload := '{"x":1}';
    S.EnqueueRequest(Req, Err);
  finally
    S.Free;
  end;

  S := OpenStore;
  try
    AssertTrue('get after reopen', S.GetRequest('persist-req', Got, Err));
    AssertEquals('kind persisted', 'script', Got.Kind);
  finally
    S.Free;
  end;
end;

{ --- settings --- }

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
  Cfg.LibraryPath := TestLibPath;
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

procedure TStoreTest.TestClaimIsAtomicAcrossThreads;
var
  S: TSqliteStore;
  Err: TStoreError;
  Enq: array[0..3] of TEnqueueThread;
  Clm: array[0..3] of TClaimThread;
  Lock: TCriticalSection;
  Ids: TStringList;
  I: Integer;
begin
  S := OpenStore;
  Lock := TCriticalSection.Create;
  Ids := TStringList.Create;
  try
    for I := 0 to 3 do
    begin
      Enq[I] := TEnqueueThread.Create(S, 'w' + IntToStr(I) + '_', 5);
      Enq[I].Start;
    end;
    for I := 0 to 3 do
    begin
      Enq[I].WaitFor;
      Enq[I].Free;
    end;

    for I := 0 to 3 do
    begin
      Clm[I] := TClaimThread.Create(S, Lock, Ids);
      Clm[I].Start;
    end;
    for I := 0 to 3 do
    begin
      Clm[I].WaitFor;
      Clm[I].Free;
    end;

    AssertEquals('all claimed', 20, Ids.Count);
    AssertEquals('no duplicate claims', 20, CountUnique(Ids));
  finally
    Ids.Free;
    Lock.Free;
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

initialization
  RegisterTest(TStoreTest);
end.
