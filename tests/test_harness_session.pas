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
  hildegard.helper.recall.tool,
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
    procedure TestHistoryRestoresBlocks;
    procedure TestResumeUnknownSessionFails;
    procedure TestMissingWorkspaceFails;
    procedure TestRecallToolRegisteredWithStore;
    procedure TestRecallToolAbsentWithoutStore;
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
  Rec: TMessageRecord;
  History: TMessageRecordArray;
begin
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertTrue('store opened', Session.Store <> nil);
    AssertEquals('session id is 32 hex', 32, Length(Session.SessionId));
    Sid := Session.SessionId;

    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.Role := mrUser;
    Rec.Content := 'hello from a previous run';
    AssertTrue('append block',
      Session.Store.AppendMessage(Rec, StoreErr));
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

procedure THarnessSessionTest.TestHistoryRestoresBlocks;
var
  Session: THarnessSession;
  Err, Sid: string;
  StoreErr: TStoreError;
  TurnId: Int64;
  Rec: TMessageRecord;
  History: TMessageRecordArray;
begin
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Sid := Session.SessionId;
    AssertTrue('begin turn', Session.Store.BeginTurn(Sid, TurnId, StoreErr));
    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.TurnId := TurnId;
    Rec.Role := mrUser;
    Rec.Content := 'do it';
    AssertTrue('user', Session.Store.AppendMessage(Rec, StoreErr));
    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.TurnId := TurnId;
    Rec.Role := mrReasoning;
    Rec.Content := 'thinking';
    AssertTrue('reasoning', Session.Store.AppendMessage(Rec, StoreErr));
    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.TurnId := TurnId;
    Rec.Role := mrToolCall;
    Rec.ToolCallId := 'c1';
    Rec.ToolName := 'run_command';
    Rec.ToolArguments := '{"command":"date"}';
    Rec.ToolReason := 'check the date';
    AssertTrue('tool call', Session.Store.AppendMessage(Rec, StoreErr));
  finally
    Session.Free;
  end;

  Session := THarnessSession.Open(Config(FStorePath, Sid, True), Err);
  AssertTrue('reopened: ' + Err, Session <> nil);
  try
    History := Session.History;
    AssertEquals('three blocks', 3, Length(History));
    AssertEquals('user', Ord(mrUser), Ord(History[0].Role));
    AssertEquals('reasoning', Ord(mrReasoning), Ord(History[1].Role));
    AssertEquals('tool call', Ord(mrToolCall), Ord(History[2].Role));
    AssertEquals('reason restored', 'check the date', History[2].ToolReason);
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

procedure THarnessSessionTest.TestRecallToolRegisteredWithStore;
var
  Session: THarnessSession;
  Err: string;
  Tool: TRegisteredTool;
begin
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertTrue('recall tool registered',
      Session.Tools.Find(RecallToolName, Tool));
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestRecallToolAbsentWithoutStore;
var
  Session: THarnessSession;
  Err: string;
  Tool: TRegisteredTool;
begin
  Session := THarnessSession.Open(Config('', '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertFalse('no artifacts without a store, so no recall tool',
      Session.Tools.Find(RecallToolName, Tool));
  finally
    Session.Free;
  end;
end;

initialization
  RegisterTest(THarnessSessionTest);

  Randomize;
end.
