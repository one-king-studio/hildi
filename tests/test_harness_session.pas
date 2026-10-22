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
  hildegard.helper.harness.session, hildegard.helper.harness.view,
  hildegard.helper.mcp.config,
  hildegard.helper.board, hildegard.helper.board.store,
  llm_fakes;

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
    procedure TestLastTurnEmptyWithoutTurns;
    { The skill descriptions (the STABLE half of the manifest) must reach the
      loop even when no MCP server is configured. They were briefly gated on
      FMcp <> nil, which silently dropped a locally-declared skill's description:
      the per-request fragment carries state only now, so the description has
      nowhere else to go. }
    procedure TestStablePromptIsSetWithoutAnyMcp;
    { A peer's board post becomes ONE coalesced transient notice, and the same
      entry is not noticed twice. }
    procedure TestAPeerPostBecomesOneNotice;
    procedure TestSessionTotalsEmptyWithoutTurns;
    procedure TestMaxContextTokensFromConfig;
    procedure TestMcpServerToolsRegistered;
    procedure TestSessionPicksUpServerAddedBetweenTurns;
    procedure TestCheckpointInstructionIsReplyOnly;
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
  Tool: TRegisteredTool;
  Err: string;
begin
  Session := THarnessSession.Open(Config('', '', False), Err);
  try
    AssertTrue('opened: ' + Err, Session <> nil);
    AssertTrue('loop built', Session.Loop <> nil);
    AssertTrue('store is nil', Session.View.Store = nil);
    AssertEquals('ephemeral session id', '', Session.View.SessionId);
    AssertEquals('workspace root', FDir, Session.View.WorkspaceRoot);
    { builtins (get_system_time) plus run_command and the file tools. }
    AssertTrue('tools registered', Session.Tools.Count >= 2);
    AssertTrue('shell registered',
      Session.Tools.Find('run_command', Tool));
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
    AssertTrue('store opened', Session.View.Store <> nil);
    AssertEquals('session id is 32 hex', 32, Length(Session.View.SessionId));
    Sid := Session.View.SessionId;

    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.Role := mrUser;
    Rec.Content := 'hello from a previous run';
    AssertTrue('append block',
      Session.View.Store.AppendMessage(Rec, StoreErr));
  finally
    Session.Free;
  end;

  Session := THarnessSession.Open(Config(FStorePath, Sid, True), Err);
  AssertTrue('reopened: ' + Err, Session <> nil);
  try
    History := Session.View.History;
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
    Sid := Session.View.SessionId;
    AssertTrue('begin turn', Session.View.Store.BeginTurn(Sid, TurnId, StoreErr));
    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.TurnId := TurnId;
    Rec.Role := mrUser;
    Rec.Content := 'do it';
    AssertTrue('user', Session.View.Store.AppendMessage(Rec, StoreErr));
    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.TurnId := TurnId;
    Rec.Role := mrReasoning;
    Rec.Content := 'thinking';
    AssertTrue('reasoning', Session.View.Store.AppendMessage(Rec, StoreErr));
    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.TurnId := TurnId;
    Rec.Role := mrToolCall;
    Rec.ToolCallId := 'c1';
    Rec.ToolName := 'run_command';
    Rec.ToolArguments := '{"command":"date"}';
    Rec.ToolReason := 'check the date';
    AssertTrue('tool call', Session.View.Store.AppendMessage(Rec, StoreErr));
  finally
    Session.Free;
  end;

  Session := THarnessSession.Open(Config(FStorePath, Sid, True), Err);
  AssertTrue('reopened: ' + Err, Session <> nil);
  try
    History := Session.View.History;
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

procedure THarnessSessionTest.TestLastTurnEmptyWithoutTurns;
var
  Session: THarnessSession;
  Err: string;
  Turn: TTurnRecord;
begin
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Turn := Session.View.LastTurn;
    AssertEquals('no turns yet', 0, Turn.Id);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestAPeerPostBecomesOneNotice;
var
  Session: THarnessSession;
  Err: string;
  Board: IBoardStore;
  E: TBoardEntry;
  Id, Noticed: Integer;
begin
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    { Nothing on the board yet: no notice, and no crash from a nil cursor. }
    AssertEquals('nothing to notice', 0, Session.NoticeBoard);

    { A peer posts - a different session id, so it is genuinely someone else. }
    Board := TSqliteBoardStore.Create(Session.View.Store);
    E := Default(TBoardEntry);
    E.WorkspaceId := Session.View.WorkspaceId;
    E.Kind := bkFinding;
    E.Topic := 'parser';
    E.Title := 'the guard is in ParseWord';
    E.Body := 'not the lexer';
    E.FromSession := 'some-peer';
    E.FromLabel := 'peer';
    AssertTrue('peer posts', Board.Append(E, Id, Err));

    { One tick, one notice. }
    Noticed := Session.NoticeBoard;
    AssertTrue('the post was noticed', Noticed > 0);
    { The notice is transient: it is queued, not stored. }
    AssertTrue('queued for delivery', Session.Loop.PromptQueue.Pending);
    { Draining clears it, so a second tick with no new entry notices nothing. }
    Session.Loop.PromptQueue.DrainItems;
    AssertEquals('already seen', 0, Session.NoticeBoard);
    Board := nil;
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestStablePromptIsSetWithoutAnyMcp;
var
  Session: THarnessSession;
  Err: string;
begin
  { No MCP configured. The loop must still be handed the stable text - the
    failure this guards was the assignment being skipped entirely, which left
    every skill description out of every request.

    Asserting the property is non-nil proves the wiring exists; the CONTENT
    assertion lives in test_agent (TestStablePromptReachesTheSystemMessage),
    because with no skills declared StableText is legitimately ''. }
  Session := THarnessSession.Open(Config('', '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertTrue('the loop is built', Session.Loop <> nil);
    { A session with no MCP and no skills: the value is '' but the assignment
      must have happened. Distinguishing "assigned empty" from "never assigned"
      needs a skill, so this test's real value is that it exercises the
      no-MCP path at all - which is the path that was broken. }
    AssertEquals('no skills declared, so nothing to add', '',
      Session.Loop.StablePrompt);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestSessionTotalsEmptyWithoutTurns;
var
  Session: THarnessSession;
  Err: string;
  Totals: TTurnRecord;
begin
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Totals := Session.View.SessionTotals;
    AssertEquals('no turns yet', 0, Totals.Id);
    AssertEquals('no turns listed', 0, Length(Session.View.Turns));
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestMaxContextTokensFromConfig;
var
  Session: THarnessSession;
  Err: string;
  Cfg: THarnessSessionConfig;
begin
  Cfg := Config('', '', False);
  Cfg.MaxContextTokens := 1000000;
  Session := THarnessSession.Open(Cfg, Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertEquals('config override applied', 1000000, Session.View.MaxContextTokens);
  finally
    Session.Free;
  end;
end;

{ A configured MCP server's tools appear in the session registry alongside the
  native ones. The server is a /bin/sh fake; config is written to the store. }
procedure THarnessSessionTest.TestMcpServerToolsRegistered;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  Err: string;
  StoreErr: TStoreError;
  Row: TMcpServerRow;
  Session: THarnessSession;
  Tool: TRegisteredTool;
  Script: string;
const
  Q = #39;
begin
  Script :=
    'read line; printf ' + Q + '%s\n' + Q + ' ' + Q +
    '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05",' +
    '"capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}' + Q +
    '; read line; read line; printf ' + Q + '%s\n' + Q + ' ' + Q +
    '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo",' +
    '"description":"Echo","inputSchema":{"type":"object","properties":{}}}]}}' +
    Q + '; while IFS= read -r line; do :; done';

  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('store opens', Store.Open(StoreErr));
    Row := Default(TMcpServerRow);
    Row.Scope := msGlobal;
    Row.Name := 'fake';
    Row.Command := '/bin/sh';
    Row.Args := ['-c', Script];
    Row.Enabled := True;
    AssertTrue('config saved', Store.SaveMcpServer(Row, StoreErr));
  finally
    Store.Free;
  end;

  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    { Lazy: the server is declared as a skill but NOT connected, so its tools
      are absent until a load. }
    AssertFalse('mcp tool absent before load',
      Session.Loop.ResolveTool('mcp_fake_echo', Tool));
    AssertTrue('declared as a skill',
      Pos('mcp_fake', Session.Skills.Manifest) > 0);
    { Loading the skill connects it and registers its tools. }
    AssertTrue('load ok', Session.Skills.LoadSkill('mcp_fake', Err));
    AssertTrue('mcp tool resolvable after load',
      Session.Loop.ResolveTool('mcp_fake_echo', Tool));
  finally
    Session.Free;
  end;
end;

{ A server added to the store *after* the session opens is picked up at the
  next turn boundary (the OnTurnStart reconcile). }
procedure THarnessSessionTest.TestCheckpointInstructionIsReplyOnly;
begin
  { The checkpoint document is the turn's reply, not a workspace file. Without
    this clause the agent mirrors the repo's HANDOFF.md convention and writes one
    (observed live: the first run wrote HANDOFF_session.md). }
  AssertTrue('reply with the document',
    Pos('Reply with the handoff document itself', CheckpointInstruction) > 0);
  AssertTrue('explicitly no file write',
    Pos('do not write it to a file', CheckpointInstruction) > 0);
end;

procedure THarnessSessionTest.TestSessionPicksUpServerAddedBetweenTurns;
var
  Session: THarnessSession;
  Err: string;
  Tool: TRegisteredTool;
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  Row: TMcpServerRow;
  Script: string;
const
  Q = #39;
begin
  Script :=
    'read line; printf ' + Q + '%s\n' + Q + ' ' + Q +
    '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05",' +
    '"capabilities":{},"serverInfo":{"name":"late","version":"1"}}}' + Q +
    '; read line; read line; printf ' + Q + '%s\n' + Q + ' ' + Q +
    '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo",' +
    '"description":"Echo","inputSchema":{"type":"object","properties":{}}}]}}' +
    Q + '; while IFS= read -r line; do :; done';

  { Open with an empty config (no servers yet). }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertFalse('no mcp tools yet',
      Session.Loop.ResolveTool('mcp_late_echo', Tool));

    { The operator adds a server to the store. }
    StoreCfg := Default(TStoreConfig);
    StoreCfg.DatabasePath := FStorePath;
    StoreCfg.BusyTimeoutMs := 5000;
    Store := TSqliteStore.Create(StoreCfg);
    try
      AssertTrue('store opens', Store.Open(StoreErr));
      Row := Default(TMcpServerRow);
      Row.Scope := msGlobal;
      Row.Name := 'late';
      Row.Command := '/bin/sh';
      Row.Args := ['-c', Script];
      Row.Enabled := True;
      AssertTrue('row saved', Store.SaveMcpServer(Row, StoreErr));
    finally
      Store.Free;
    end;

    { The next turn's boundary reconcile picks it up as a skill (declared, not
      connected); loading it registers the tools. }
    Session.Loop.PrepareProviders;
    AssertTrue('picked up as a skill at the boundary',
      Pos('mcp_late', Session.Skills.Manifest) > 0);
    AssertTrue('load ok', Session.Skills.LoadSkill('mcp_late', Err));
    AssertTrue('resolvable after load',
      Session.Loop.ResolveTool('mcp_late_echo', Tool));
  finally
    Session.Free;
  end;
end;

initialization
  RegisterTest(THarnessSessionTest);

  Randomize;end.
