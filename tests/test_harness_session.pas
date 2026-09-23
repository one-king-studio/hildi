unit test_harness_session;
{ fpcunit tests for hildegard.helper.harness.session: bootstrap in memory and
  against a store, resume, and failure modes. Uses the fake LLM transport and a
  temporary workspace/store. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, Generics.Collections,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.session,
  hildegard.helper.store, hildegard.helper.workspace,
  hildegard.helper.harness.session, llm_fakes;

type
  THarnessSessionTest = class(TTestCase)
  private
    FDir: string;
    FStorePath: string;
    FTransports: TObjectList<TFakeTransport>;
    function Config(const AStorePath, ASessionId: string;
      AResume: Boolean): THarnessSessionConfig;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestInMemoryBuildsLoopAndTools;
    procedure TestStoreCreatesSessionAndHistoryRoundTrips;
    procedure TestResumeUnknownSessionFails;
    procedure TestMissingWorkspaceFails;
  end;

implementation

procedure THarnessSessionTest.SetUp;
begin
  FTransports := TObjectList<TFakeTransport>.Create(True);
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-session-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
end;

procedure THarnessSessionTest.TearDown;
begin
  FTransports.Free;
  if FileExists(FStorePath) then
    DeleteFile(FStorePath);
  if DirectoryExists(FDir) then
    RemoveDir(FDir);
end;

function THarnessSessionTest.Config(const AStorePath, ASessionId: string;
  AResume: Boolean): THarnessSessionConfig;
begin
  Result := Default(THarnessSessionConfig);
  Result.WorkspacePath := FDir;
  Result.StorePath := AStorePath;
  Result.SessionId := ASessionId;
  Result.Resume := AResume;
  Result.Transport := TFakeTransport.Create;
  FTransports.Add(TFakeTransport(Result.Transport));
end;

procedure THarnessSessionTest.TestInMemoryBuildsLoopAndTools;
var
  Session: THarnessSession;
  Err: string;
begin
  Session := THarnessSession.Open(Config('', '', False), Err);
  try
    AssertTrue('opened: ' + Err, Session <> nil);
    AssertTrue('loop built', Session.Loop <> nil);
    AssertTrue('store is nil', Session.Store = nil);
    AssertEquals('ephemeral session id', '', Session.SessionId);
    AssertEquals('workspace root', FDir, Session.WorkspaceRoot);
    { builtins (get_system_time) plus run_command }
    AssertTrue('tools registered', Session.Tools.Count >= 2);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestStoreCreatesSessionAndHistoryRoundTrips;
var
  Session: THarnessSession;
  Err, Sid: string;
  StoreErr: TStoreError;
  Rec: TSessionRecord;
  History: TChatMessageArray;
begin
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertTrue('store opened', Session.Store <> nil);
    AssertEquals('session id is 32 hex', 32, Length(Session.SessionId));
    Sid := Session.SessionId;

    Rec := Default(TSessionRecord);
    Rec.SessionId := Sid;
    Rec.Kind := srkUserMessage;
    Rec.Content := 'hello from a previous run';
    AssertTrue('append record',
      Session.Store.AppendSessionRecord(Rec, StoreErr));
  finally
    Session.Free;
  end;

  Session := THarnessSession.Open(Config(FStorePath, Sid, True), Err);
  AssertTrue('reopened: ' + Err, Session <> nil);
  try
    History := Session.History;
    AssertEquals('history restored', 1, Length(History));
    AssertEquals('history content', 'hello from a previous run',
      History[0].Content);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestResumeUnknownSessionFails;
var
  Session: THarnessSession;
  Err: string;
begin
  Session := THarnessSession.Open(
    Config(FStorePath, '00000000000000000000000000000000', True), Err);
  AssertTrue('not opened', Session = nil);
  AssertTrue('error mentions unknown', Pos('unknown session', Err) > 0);
end;

procedure THarnessSessionTest.TestMissingWorkspaceFails;
var
  Cfg: THarnessSessionConfig;
  Session: THarnessSession;
  Err: string;
begin
  Cfg := Config('', '', False);
  Cfg.WorkspacePath := IncludeTrailingPathDelimiter(FDir) + 'does-not-exist';
  Session := THarnessSession.Open(Cfg, Err);
  AssertTrue('not opened', Session = nil);
  AssertTrue('error set', Err <> '');
end;

initialization
  RegisterTest(THarnessSessionTest);

  Randomize;
end.
