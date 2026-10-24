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
  hildegard.helper.tasks, hildegard.helper.tasks.store,
  hildegard.helper.tasks.tools, hildegard.helper.sqlite,
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
    { The task list's tools and its stable prose, in a real session. }
    procedure TestTaskToolsRegisteredWithStore;
    procedure TestTheCoordinationTextRidesTheSystemPrompt;
    { Claim recovery runs at the turn boundary: a working session renews, and a
      claim whose holder stopped is released. }
    procedure TestTheTurnBoundaryRenewsAThisSessionsClaim;
    procedure TestTheTurnBoundaryReclaimsADeadSessionsClaim;
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

procedure THarnessSessionTest.TestTaskToolsRegisteredWithStore;
var
  Session: THarnessSession;
  Err, Result2: string;
  Tool: TRegisteredTool;
begin
  { The task list is wired beside the file tools, so a real session advertises
    it. Without this the store layer is dead code - the exact failure mode this
    repo keeps finding. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertTrue('task_list registered',
      Session.Tools.Find(TaskListTool, Tool));
    AssertTrue('task_add registered', Session.Tools.Find(TaskAddTool, Tool));
    AssertTrue('task_claim registered',
      Session.Tools.Find(TaskClaimTool, Tool));
    AssertTrue('task_update registered',
      Session.Tools.Find(TaskUpdateTool, Tool));
    AssertTrue('task_edit registered', Session.Tools.Find(TaskEditTool, Tool));
    AssertTrue('task_moderate registered',
      Session.Tools.Find(TaskModerateTool, Tool));
    { Registered AND runnable: a handler that exists but cannot reach a store is
      the failure the registration check alone would miss. Re-fetch the ADD tool:
      `Tool` currently holds the last Find. }
    AssertTrue('find add', Session.Tools.Find(TaskAddTool, Tool));
    AssertTrue('add runs', Tool.Handler('{"title":"wired up","reason":"t"}',
      Result2, Err, nil));
    AssertTrue('and says what it made: ' + Result2, Pos('wired up', Result2) > 0);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestTheTurnBoundaryRenewsAThisSessionsClaim;
var
  Session: THarnessSession;
  Tasks: ITaskStore;
  Card: TTaskCard;
  Prev: TTaskCard;
  Found, Claimed: Boolean;
  Err: string;
  Id, Renewed: Integer;
  Now2: Int64;
  Row: TSessionRuntimeRow;
  SE: TStoreError;
begin
  { The wiring test, and it has to go through the BOUNDARY rather than the store:
    RenewClaims is tested directly in test_tasks_store, so calling it here would
    prove nothing about whether NoteTurnOpened invokes it. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    { Liveness is now the authority: a claim whose holder has no runtime row is
      reclaimed immediately. This test is about RENEWAL, so the holding session
      must be present for renewal to be what gets measured. }
    Row := Default(TSessionRuntimeRow);
    Row.SessionId := Session.View.SessionId;
    Row.Pid := 1;
    Row.SocketPath := '/tmp/x';
    Row.StartedAt := Round((Now - EncodeDate(1970, 1, 1)) * 86400);
    Row.UpdatedAt := Row.StartedAt;
    AssertTrue('runtime row', Session.View.Store.RegisterRuntime(Row, SE));
    Tasks := TSqliteTaskStore.Create(Session.View.Store);
    Card := Default(TTaskCard);
    Card.WorkspaceId := Session.View.WorkspaceId;
    Card.Title := 'held by the live session';
    Card.CreatedAt := Round((Now - EncodeDate(1970, 1, 1)) * 86400);
    AssertTrue('add', Tasks.Add(Card, Id, Err));
    Prev := Default(TTaskCard);
    AssertTrue('claim', Tasks.Claim(Session.View.WorkspaceId, Id,
      Session.View.SessionId, Prev, Claimed, Found, Err));
    AssertTrue('claimed', Claimed);
    { Backdate past any plausible lease, so only a renewal can save it. }
    AssertEquals('backdate', SQLITE_OK, sqlite3_exec(Session.View.Store.Db,
      PAnsiChar(AnsiString('UPDATE task_cards SET claimed_at = claimed_at - ' +
        '86400 WHERE id = ' + IntToStr(Id))), nil, nil, nil));

    { Fire the turn boundary the way the loop does. }
    AssertTrue('the loop hooks the boundary',
      Assigned(Session.Loop.OnTurnOpened));
    Session.Loop.OnTurnOpened(1);

    AssertTrue('get', Tasks.Get(Session.View.WorkspaceId, Id, Card, Found, Err));
    AssertTrue('found', Found);
    AssertEquals('still ours - a working agent must not look dead',
      Ord(tsClaimed), Ord(Card.Status));
    Now2 := Round((Now - EncodeDate(1970, 1, 1)) * 86400);
    AssertTrue('and the clock moved: ' + IntToStr(Now2 - Card.ClaimedAt),
      (Now2 - Card.ClaimedAt) <= 60);
  finally
    Tasks := nil;
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestTheTurnBoundaryReclaimsADeadSessionsClaim;
var
  Session: THarnessSession;
  Tasks: ITaskStore;
  Card: TTaskCard;
  Prev: TTaskCard;
  Found, Claimed: Boolean;
  Err: string;
  Id: Integer;
begin
  { The other half, and the one that closes the original gap: a session that
    stopped holding a card must not keep it past the lease. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Tasks := TSqliteTaskStore.Create(Session.View.Store);
    Card := Default(TTaskCard);
    Card.WorkspaceId := Session.View.WorkspaceId;
    Card.Title := 'held by a session that stopped';
    Card.CreatedAt := Round((Now - EncodeDate(1970, 1, 1)) * 86400);
    AssertTrue('add', Tasks.Add(Card, Id, Err));
    Prev := Default(TTaskCard);
    AssertTrue('claim as a dead session', Tasks.Claim(
      Session.View.WorkspaceId, Id, 'sess-dead', Prev, Claimed, Found, Err));
    AssertTrue('claimed', Claimed);
    AssertEquals('backdate past the lease', SQLITE_OK,
      sqlite3_exec(Session.View.Store.Db, PAnsiChar(AnsiString(
        'UPDATE task_cards SET claimed_at = claimed_at - 86400 WHERE id = ' +
        IntToStr(Id))), nil, nil, nil));

    Session.Loop.OnTurnOpened(1);

    AssertTrue('get', Tasks.Get(Session.View.WorkspaceId, Id, Card, Found, Err));
    AssertTrue('found', Found);
    AssertEquals('released back to open', Ord(tsOpen), Ord(Card.Status));
    AssertEquals('and unheld', '', Card.ClaimedBy);
    AssertTrue('the note says who had it: ' + Card.DoneNote,
      Pos('sess-dead', Card.DoneNote) > 0);
  finally
    Tasks := nil;
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestTheCoordinationTextRidesTheSystemPrompt;
var
  Session: THarnessSession;
  Err, P: string;
begin
  { The <tasks> element is data only, so the explanation must reach the system
    prompt - the stable half, where it caches - exactly as the board's does. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertTrue('the loop is built', Session.Loop <> nil);
    P := Session.Loop.StablePrompt;
    AssertTrue('the task list is explained: ' + P, Pos('task_claim', P) > 0);
    AssertTrue('and the board too', Pos('board_post', P) > 0);
    { One block carries both plus the protocol rules and the detected mode, so
      the answer to "am I alone?" is stated once, not twice. }
    AssertTrue('the protocol is stated', Pos('Claim before you change', P) > 0);
  finally
    Session.Free;
  end;
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
    { The stable prompt is never empty now: the shell guidance rides it
      unconditionally, because a session with no store can still run composed
      commands and must be told which ones stay in the gated tier. }
    AssertTrue('the shell guidance is present',
      Pos('Prefer the built-in shell', Session.Loop.StablePrompt) > 0);
    AssertTrue('and names commands',
      Pos('grep', Session.Loop.StablePrompt) > 0);
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
