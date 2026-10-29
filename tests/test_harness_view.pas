unit test_harness_view;
{ fpcunit tests for hildi.harness.view: the client-side session handle
  that opens a workspace/store/session and reads history and metrics, with no
  loop, LLM client, or tools. The "no agent" property is asserted by the split
  boundary test (tests/test_split.pas). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildi.store, hildi.session,
  hildi.harness.view;

type
  THarnessViewTest = class(TTestCase)
  private
    FDir: string;
    FStorePath: string;
    function Config(const AStorePath: string): THarnessSessionConfig;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestInMemoryViewHasNoStore;
    procedure TestStoreViewCreatesSession;
    procedure TestHistoryReadsOnDemand;
    procedure TestHistoryTailIsBounded;
    procedure TestHistoryPageReturnsEarlierRows;
    procedure TestMaxContextTokensOverride;
    procedure TestLazySessionDefersCreation;
    procedure TestEnsureSessionCreatesOnDemand;
  end;

implementation

procedure THarnessViewTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-view-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
end;

procedure THarnessViewTest.TearDown;
begin
  DeleteFile(FStorePath);
  RemoveDir(FDir);
end;

function THarnessViewTest.Config(const AStorePath: string): THarnessSessionConfig;
begin
  Result := Default(THarnessSessionConfig);
  Result.WorkspacePath := FDir;
  Result.StorePath := AStorePath;
end;

procedure THarnessViewTest.TestInMemoryViewHasNoStore;
var
  View: TSessionView;
  Err: string;
begin
  View := TSessionView.Open(Config(''), Err);
  try
    AssertNotNull('view opens: ' + Err, View);
    AssertTrue('no store', View.Store = nil);
    AssertEquals('ephemeral id', '', View.SessionId);
    AssertEquals('workspace root', FDir, View.WorkspaceRoot);
    AssertEquals('no history', 0, Length(View.History));
  finally
    View.Free;
  end;
end;

procedure THarnessViewTest.TestStoreViewCreatesSession;
var
  View: TSessionView;
  Err: string;
begin
  View := TSessionView.Open(Config(FStorePath), Err);
  try
    AssertNotNull('view opens: ' + Err, View);
    AssertTrue('store opened', View.Store <> nil);
    AssertEquals('session id is 32 hex', 32, Length(View.SessionId));
  finally
    View.Free;
  end;
end;

procedure THarnessViewTest.TestHistoryReadsOnDemand;
var
  View: TSessionView;
  Err: string;
  StoreErr: TStoreError;
  Rec: TMessageRecord;
  Sid: string;
  History: TMessageRecordArray;
begin
  View := TSessionView.Open(Config(FStorePath), Err);
  try
    AssertNotNull('view opens: ' + Err, View);
    Sid := View.SessionId;
    AssertEquals('history starts empty', 0, Length(View.History));
    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.Role := mrUser;
    Rec.Content := 'hello';
    AssertTrue('append', View.Store.AppendMessage(Rec, StoreErr));
    { A second read sees the new row: History is not a stale cache. }
    History := View.History;
    AssertEquals('one message', 1, Length(History));
    AssertEquals('content', 'hello', History[0].Content);
  finally
    View.Free;
  end;
end;

procedure THarnessViewTest.TestHistoryTailIsBounded;
var
  View: TSessionView;
  Err: string;
  StoreErr: TStoreError;
  Rec: TMessageRecord;
  Sid: string;
  I: Integer;
  Tail: TMessageRecordArray;
begin
  View := TSessionView.Open(Config(FStorePath), Err);
  try
    AssertNotNull('view opens: ' + Err, View);
    Sid := View.SessionId;
    for I := 1 to 10 do
    begin
      Rec := Default(TMessageRecord);
      Rec.SessionId := Sid;
      Rec.Role := mrUser;
      Rec.Content := 'm' + IntToStr(I);
      AssertTrue('append', View.Store.AppendMessage(Rec, StoreErr));
    end;
    { The tail returns the LAST 3, oldest first. }
    Tail := View.HistoryTail(3);
    AssertEquals('bounded to 3', 3, Length(Tail));
    AssertEquals('oldest of the tail', 'm8', Tail[0].Content);
    AssertEquals('newest of the tail', 'm10', Tail[2].Content);
    { A limit larger than the session returns all of them. }
    AssertEquals('all when smaller', 10, Length(View.HistoryTail(50)));
  finally
    View.Free;
  end;
end;

procedure THarnessViewTest.TestHistoryPageReturnsEarlierRows;
var
  View: TSessionView;
  Err: string;
  StoreErr: TStoreError;
  Rec: TMessageRecord;
  Sid: string;
  I: Integer;
  Page: TMessageRecordArray;
begin
  View := TSessionView.Open(Config(FStorePath), Err);
  try
    AssertNotNull('view opens: ' + Err, View);
    Sid := View.SessionId;
    for I := 1 to 10 do
    begin
      Rec := Default(TMessageRecord);
      Rec.SessionId := Sid;
      Rec.Role := mrUser;
      Rec.Content := 'm' + IntToStr(I);
      AssertTrue('append', View.Store.AppendMessage(Rec, StoreErr));
    end;
    { The page strictly before seq 5: m1..m4 (oldest first). }
    Page := View.HistoryPage(5, 20);
    AssertEquals('four rows before', 4, Length(Page));
    AssertEquals('oldest', 'm1', Page[0].Content);
    AssertEquals('newest', 'm4', Page[3].Content);
    { At the head: an empty page, not an error. }
    AssertEquals('empty at the head', 0, Length(View.HistoryPage(1, 20)));
  finally
    View.Free;
  end;
end;

procedure THarnessViewTest.TestMaxContextTokensOverride;
var
  View: TSessionView;
  Err: string;
  Cfg: THarnessSessionConfig;
begin
  Cfg := Config('');
  Cfg.MaxContextTokens := 1000000;
  View := TSessionView.Open(Cfg, Err);
  try
    AssertNotNull('view opens: ' + Err, View);
    AssertEquals('override applied', 1000000, View.MaxContextTokens);
  finally
    View.Free;
  end;
end;

procedure THarnessViewTest.TestLazySessionDefersCreation;
var
  View: TSessionView;
  Err: string;
  Cfg: THarnessSessionConfig;
begin
  { Lazy: opening the view must NOT create a session row. }
  Cfg := Config(FStorePath);
  Cfg.LazySession := True;
  View := TSessionView.Open(Cfg, Err);
  try
    AssertNotNull('view opens: ' + Err, View);
    AssertFalse('no session yet', View.HasSession);
    AssertEquals('empty id', '', View.SessionId);
    AssertTrue('the store is open', View.Store <> nil);
  finally
    View.Free;
  end;
end;

procedure THarnessViewTest.TestEnsureSessionCreatesOnDemand;
var
  View: TSessionView;
  Err: string;
  Cfg: THarnessSessionConfig;
begin
  Cfg := Config(FStorePath);
  Cfg.LazySession := True;
  View := TSessionView.Open(Cfg, Err);
  try
    AssertNotNull('view opens: ' + Err, View);
    AssertTrue('create on demand', View.EnsureSession(Err));
    AssertTrue('now has a session', View.HasSession);
    AssertTrue('a real id', View.SessionId <> '');
    { Idempotent: a second call keeps the same id. }
    AssertTrue('idempotent', View.EnsureSession(Err));
  finally
    View.Free;
  end;
end;

initialization
  RegisterTest(THarnessViewTest);
end.
