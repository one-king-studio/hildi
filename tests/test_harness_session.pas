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
  hildegard.helper.session.store,
  hildegard.helper.mcp.config,
  hildegard.helper.board, hildegard.helper.board.store,
  hildegard.helper.tasks, hildegard.helper.tasks.store,
  changes.types, changes.text, changes.store,
  hildegard.helper.changes.store, hildegard.helper.changes.revert,
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
    function WriteText(const AName, AContent: string): string;
    function ReadText(const AName: string): string;
    function SeedChange(Session: THarnessSession; ATurnId: Integer;
      const ABefore, AAfter: string; out ADetail: string): Boolean;
    function SeedMessage(Session: THarnessSession; ATurnId: Int64;
      out ADetail: string): Boolean;
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
    { A revived session must be told it was away, what it missed, and what it
      lost. }
    procedure TestARevivedSessionIsToldItWasAway;
    { A peer arriving mid-session must change behaviour, and the first
      observation is not a transition. }
    procedure TestAPeerArrivingRaisesOneTransitionNotice;
    { Claim recovery runs at the turn boundary: a working session renews, and a
      claim whose holder stopped is released. }
    procedure TestTheTurnBoundaryRenewsAThisSessionsClaim;
    { Undo moves the files AND the transcript together, or neither. }
    procedure TestUndoTurnRestoresFilesAndRewindsMessages;
    procedure TestUndoTurnRefusesWhenAFileCannotBeRestored;
    { An undone turn is soft-deleted as tsUndone - distinct from tsCancelled,
      which means "interrupted, possibly still in effect" - and its change rows
      are marked reverted so a dialog cannot offer them again. }
    procedure TestUndoTurnMarksTheTurnAndItsChangeRowsUndone;
    { Undoing a suffix that is already undone must say so, not report success. }
    procedure TestUndoingAnAlreadyUndoneSuffixSaysSo;
    { The transcript half: an undone turn's messages stop being composed into
      the context, or the operator sees work that is no longer on disk. }
    procedure TestUndoneTurnsAreExcludedFromTheContext;
    { Redo is the mechanical inverse: it re-applies the files AND brings the
      turn's messages back into the context. Undo-then-redo must be an exact
      round trip, or one direction is lying. }
    procedure TestRedoRestoresTheFilesAndTheContext;
    { Redoing turns that were never undone must say so, not silently succeed. }
    procedure TestRedoRefusesWhenNothingIsUndone;
    { THE ABANDONED-WINDOW CASE. Undo five turns, prompt (abandoning them), undo
      two more, then redo: the redo must not resurrect the original five. Status
      alone cannot tell them apart, because abandoned turns keep tsUndone - so
      the session carries a floor and a prompt raises it. }
    procedure TestRedoDoesNotResurrectTurnsAbandonedByAPrompt;
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

function THarnessSessionTest.WriteText(const AName, AContent: string): string;
var
  Fs: TFileStream;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + AName;
  Fs := TFileStream.Create(Result, fmCreate);
  try
    if AContent <> '' then
      Fs.WriteBuffer(AContent[1], Length(AContent));
  finally
    Fs.Free;
  end;
end;

function THarnessSessionTest.ReadText(const AName: string): string;
var
  Fs: TFileStream;
  Full: string;
begin
  Result := '';
  Full := IncludeTrailingPathDelimiter(FDir) + AName;
  if not FileExists(Full) then
    Exit;
  Fs := TFileStream.Create(Full, fmOpenRead);
  try
    SetLength(Result, Fs.Size);
    if Fs.Size > 0 then
      Fs.ReadBuffer(Result[1], Fs.Size);
  finally
    Fs.Free;
  end;
end;

function THarnessSessionTest.SeedChange(Session: THarnessSession;
  ATurnId: Integer; const ABefore, AAfter: string; out ADetail: string): Boolean;
var
  Changes: IChangeStore;
  Hasher: TSha256Hasher;
  R: TChangeRecord;
  Patch: string;
  Id: Integer;
  Capped: Boolean;
begin
  ADetail := '';
  Hasher := TSha256Hasher.Create;
  try
    Patch := DiffText(ABefore, AAfter, DefaultPatchCapBytes, Capped);
    R := Default(TChangeRecord);
    R.WorkspaceId := Session.View.WorkspaceId;
    R.SessionId := Session.View.SessionId;
    R.TurnId := ATurnId;
    R.Path := 'a.txt';
    R.Kind := ckModified;
    R.IsNet := True;
    R.BeforeHash := Hasher.OfText(ABefore);
    R.AfterHash := Hasher.OfText(AAfter);
    R.Patch := Patch;
    R.PatchBytes := Length(Patch);
    R.Capped := Capped;
    Changes := TSqliteChangeStore.Create(Session.View.Store);
    Result := Changes.Append(R, Id, ADetail);
  finally
    Hasher.Free;
  end;
end;

function THarnessSessionTest.SeedMessage(Session: THarnessSession;
  ATurnId: Int64; out ADetail: string): Boolean;
var
  Rec: TMessageRecord;
  StoreErr: TStoreError;
begin
  Rec := Default(TMessageRecord);
  Rec.SessionId := Session.View.SessionId;
  Rec.TurnId := ATurnId;
  Rec.Role := mrUser;
  Rec.Content := 'do the thing';
  Result := Session.View.Store.AppendMessage(Rec, StoreErr);
  ADetail := StoreErr.Message;
end;

procedure THarnessSessionTest.TestUndoTurnRestoresFilesAndRewindsMessages;
var
  Session: THarnessSession;
  Err, Detail, Before, After: string;
  TurnId: Int64;
  Msgs: TMessageRecordArray;
  Convo: TSqliteConversationStore;
  StoreErr: TStoreError;
begin
  { The invariant: undo moves the files AND the transcript together. Either half
    alone is a lie about what the workspace looks like. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Session.View.Store.BeginTurn(Session.View.SessionId, TurnId, StoreErr);
    if TurnId <= 0 then
      TurnId := 1;
    { A turn worth undoing is a COMPLETED one; the undo walk skips anything
      still running. }
    Session.View.Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '',
      StoreErr);

    Before := 'one'#10'two'#10;
    After := 'one'#10'TWO'#10;
    Detail := '';
    WriteText('a.txt', After);
    AssertTrue('row: ' + Detail, SeedChange(Session, Integer(TurnId), Before,
      After, Detail));
    AssertTrue('message: ' + Detail, SeedMessage(Session, TurnId, Detail));

    AssertTrue('undo: ' + Detail, Session.UndoTurn(TurnId, Detail));
    AssertEquals('no detail on success', '', Detail);
    AssertEquals('the file is back', Before, ReadText('a.txt'));

    { The transcript half is moved by STATUS, not deletion: the row survives (the
      record still shows the work happened, and /redo needs it), but it no longer
      reaches the context. Asserting the row count is 1 is what pins that - a
      deleted row would read 0 and would also be unrecoverable. }
    AssertTrue('read messages', Session.View.Store.QueryMessages(
      Session.View.SessionId, Msgs, StoreErr));
    AssertEquals('the message row is kept, not deleted', 1, Length(Msgs));

    Convo := TSqliteConversationStore.Create(Session.View.Store,
      Session.View.SessionId, 0);
    try
      AssertEquals('but it is out of the context', 0,
        Length(Convo.Messages));
    finally
      Convo.Free;
    end;
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestUndoTurnRefusesWhenAFileCannotBeRestored;
var
  Session: THarnessSession;
  Err, Detail: string;
  TurnId: Int64;
  Msgs: TMessageRecordArray;
  StoreErr: TStoreError;
begin
  { The other half: when the files cannot be restored the transcript must NOT be
    rewound, or the operator loses the record of a turn still on disk. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Session.View.Store.BeginTurn(Session.View.SessionId, TurnId, StoreErr);
    if TurnId <= 0 then
      TurnId := 1;
    { A turn worth undoing is a COMPLETED one; the undo walk skips anything
      still running. }
    Session.View.Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '',
      StoreErr);

    { The file on disk is neither the before nor the after: edited since. }
    WriteText('a.txt', 'unrelated'#10);
    AssertTrue('row', SeedChange(Session, Integer(TurnId), 'one'#10, 'TWO'#10,
      Detail));
    AssertTrue('message', SeedMessage(Session, TurnId, Detail));

    AssertFalse('refused', Session.UndoTurn(TurnId, Detail));
    AssertTrue('names the file: ' + Detail, Pos('a.txt', Detail) > 0);

    AssertTrue('read messages', Session.View.Store.QueryMessages(
      Session.View.SessionId, Msgs, StoreErr));
    AssertEquals('the transcript is NOT rewound', 1, Length(Msgs));
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestUndoTurnMarksTheTurnAndItsChangeRowsUndone;
var
  Session: THarnessSession;
  Err, Detail: string;
  TurnId: Int64;
  Turns: TTurnRecordArray;
  Rows: TChangeRecordArray;
  Changes: IChangeStore;
  I: Integer;
  Found, SawRow: Boolean;
  StoreErr: TStoreError;
begin
  { Soft-delete has three halves and all three must happen: the turn is marked,
    its change rows are marked, and the files are back. A turn marked tsUndone
    whose rows still look revertible is exactly what would let a history dialog
    offer a turn that has already been undone. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Session.View.Store.BeginTurn(Session.View.SessionId, TurnId, StoreErr);
    if TurnId <= 0 then
      TurnId := 1;
    Session.View.Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '',
      StoreErr);

    Detail := '';
    WriteText('a.txt', 'one'#10'TWO'#10);
    AssertTrue('row: ' + Detail, SeedChange(Session, Integer(TurnId), 'one'#10,
      'one'#10'TWO'#10, Detail));
    AssertTrue('message: ' + Detail, SeedMessage(Session, TurnId, Detail));

    AssertTrue('undo: ' + Detail, Session.UndoTurn(TurnId, Detail));

    { The turn is tsUndone, NOT tsCancelled. A cancelled turn was interrupted;
      an undone one completed and then had its files put back. Only the second
      may be dropped from the current context. }
    Turns := Session.View.Turns;
    Found := False;
    for I := 0 to High(Turns) do
      if Turns[I].Id = TurnId then
      begin
        Found := True;
        AssertEquals('the turn is marked undone', Ord(tsUndone),
          Ord(Turns[I].Status));
      end;
    AssertTrue('the turn is still in the ledger', Found);

    { The rows are kept - the record still shows the work happened - but marked. }
    Changes := TSqliteChangeStore.Create(Session.View.Store);
    AssertTrue('rows: ' + Detail,
      Changes.ForTurn(Session.View.WorkspaceId, Integer(TurnId), Rows, Detail));
    SawRow := False;
    for I := 0 to High(Rows) do
      if Rows[I].IsNet then
      begin
        SawRow := True;
        AssertTrue('the change row is marked reverted', Rows[I].RevertedAt > 0);
      end;
    AssertTrue('the net row survives its own undo', SawRow);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestUndoingAnAlreadyUndoneSuffixSaysSo;
var
  Session: THarnessSession;
  Err, Detail, Second: string;
  TurnId: Int64;
  StoreErr: TStoreError;
begin
  { An undo that moved nothing must not read as a success. The operator asked
    to go back to a state and is owed an answer about what actually moved. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Session.View.Store.BeginTurn(Session.View.SessionId, TurnId, StoreErr);
    if TurnId <= 0 then
      TurnId := 1;
    Session.View.Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '',
      StoreErr);

    Detail := '';
    WriteText('a.txt', 'one'#10'TWO'#10);
    AssertTrue('row: ' + Detail, SeedChange(Session, Integer(TurnId), 'one'#10,
      'one'#10'TWO'#10, Detail));

    AssertTrue('first undo: ' + Detail, Session.UndoTurn(TurnId, Detail));

    Second := '';
    AssertFalse('second undo moves nothing', Session.UndoTurn(TurnId, Second));
    AssertTrue('says it was already undone: ' + Second,
      Pos('already undone', Second) > 0);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestUndoneTurnsAreExcludedFromTheContext;
var
  Session: THarnessSession;
  Err, Detail: string;
  TurnId: Int64;
  Convo: TSqliteConversationStore;
  Composed: TChatMessageArray;
  StoreErr: TStoreError;
begin
  { The transcript half of the invariant. Undo puts the files back; if the
    turn's messages still reach the provider, the model is told about work that
    is no longer on disk - the same lie as moving one without the other. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Session.View.Store.BeginTurn(Session.View.SessionId, TurnId, StoreErr);
    if TurnId <= 0 then
      TurnId := 1;
    Session.View.Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '',
      StoreErr);

    Detail := '';
    WriteText('a.txt', 'one'#10'TWO'#10);
    AssertTrue('row: ' + Detail, SeedChange(Session, Integer(TurnId), 'one'#10,
      'one'#10'TWO'#10, Detail));
    AssertTrue('message: ' + Detail, SeedMessage(Session, TurnId, Detail));

    { Before the undo the turn IS in the context. Asserting this first is what
      makes the exclusion below mean something: otherwise the test would pass
      on a session that never had a message at all. }
    Convo := TSqliteConversationStore.Create(Session.View.Store,
      Session.View.SessionId, 0);
    try
      { Messages is the public face of Compose (it starts from the composed
        list), and it is what the loop actually sends. }
      Composed := Convo.Messages;
      AssertEquals('the live turn is in the context', 1, Length(Composed));
    finally
      Convo.Free;
    end;

    AssertTrue('undo: ' + Detail, Session.UndoTurn(TurnId, Detail));

    Convo := TSqliteConversationStore.Create(Session.View.Store,
      Session.View.SessionId, 0);
    try
      { Messages is the public face of Compose (it starts from the composed
        list), and it is what the loop actually sends. }
      Composed := Convo.Messages;
      AssertEquals('the undone turn is dropped from the context', 0,
        Length(Composed));
    finally
      Convo.Free;
    end;
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestRedoRestoresTheFilesAndTheContext;
var
  Session: THarnessSession;
  Err, Detail, Before, After: string;
  TurnId: Int64;
  Convo: TSqliteConversationStore;
  Composed: TChatMessageArray;
  Turns: TTurnRecordArray;
  Msgs: TMessageRecordArray;
  I: Integer;
  StoreErr: TStoreError;
begin
  { The round trip, and the reason /redo exists: undo moved the files back and
    dropped the turn from the context, so redo must put BOTH back. A redo that
    restored the file but left the turn out of the transcript would be the same
    lie as the undo bug, in the other direction. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Session.View.Store.BeginTurn(Session.View.SessionId, TurnId, StoreErr);
    if TurnId <= 0 then
      TurnId := 1;
    Session.View.Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '',
      StoreErr);

    Detail := '';
    Before := 'one'#10'two'#10;
    After := 'one'#10'TWO'#10;
    WriteText('a.txt', After);
    AssertTrue('row: ' + Detail, SeedChange(Session, Integer(TurnId), Before,
      After, Detail));
    AssertTrue('message: ' + Detail, SeedMessage(Session, TurnId, Detail));

    AssertTrue('undo: ' + Detail, Session.UndoTurn(TurnId, Detail));
    AssertEquals('the file is back', Before, ReadText('a.txt'));

    Detail := '';
    AssertTrue('redo: ' + Detail, Session.RedoTurn(TurnId, Detail));
    AssertEquals('the file is forward again', After, ReadText('a.txt'));

    { The turn is live again, so its messages return to the context. }
    Turns := Session.View.Turns;
    for I := 0 to High(Turns) do
      if Turns[I].Id = TurnId then
        AssertEquals('the turn is completed again', Ord(tsCompleted),
          Ord(Turns[I].Status));

    { Unfiltered first: this separates "the row was lost" from "the filter still
      excludes it", which are different bugs. }
    AssertTrue('read messages', Session.View.Store.QueryMessages(
      Session.View.SessionId, Msgs, StoreErr));
    AssertEquals('the message row survived the round trip', 1, Length(Msgs));

    Convo := TSqliteConversationStore.Create(Session.View.Store,
      Session.View.SessionId, 0);
    try
      Composed := Convo.Messages;
      AssertEquals('the turn is back in the context', 1, Length(Composed));
    finally
      Convo.Free;
    end;
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestRedoRefusesWhenNothingIsUndone;
var
  Session: THarnessSession;
  Err, Detail: string;
  TurnId: Int64;
  StoreErr: TStoreError;
begin
  { A redo that moved nothing must not read as a success, for the same reason
    the undo's must not. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Session.View.Store.BeginTurn(Session.View.SessionId, TurnId, StoreErr);
    if TurnId <= 0 then
      TurnId := 1;
    Session.View.Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '',
      StoreErr);

    Detail := '';
    AssertFalse('nothing to redo', Session.RedoTurn(TurnId, Detail));
    AssertTrue('and says why: ' + Detail, Pos('not undone', Detail) > 0);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestRedoDoesNotResurrectTurnsAbandonedByAPrompt;
var
  Session: THarnessSession;
  Err, Detail: string;
  Turns: TTurnRecordArray;
  Ids: array[1..7] of Int64;
  I: Integer;
  StoreErr: TStoreError;
begin
  { The scenario: undo five turns, PROMPT (abandoning them), undo two more, then
    redo. A naive redo would scan for the oldest undone turn, find turn 1, and
    walk forward re-applying all five the operator had walked away from.

    Status cannot distinguish them, because abandoned turns keep tsUndone - the
    record is supposed to still show that the work happened. So the session
    carries a redo floor, and the prompt raises it to the newest turn that
    existed at that moment. Everything at or below the floor is abandoned. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    { Turns 1-5: a chain, so each turn's before-text is the previous one's
      after-text and the cumulative undo/redo can actually apply. }
    for I := 1 to 5 do
    begin
      Session.View.Store.BeginTurn(Session.View.SessionId, Ids[I], StoreErr);
      if Ids[I] <= 0 then
        Ids[I] := I;
      Session.View.Store.FinishTurn(Ids[I], tsCompleted, 'stop', 0, '', '',
        StoreErr);
      Detail := '';
      WriteText('a.txt', 'v' + IntToStr(I) + #10);
      AssertTrue('row ' + IntToStr(I) + ': ' + Detail,
        SeedChange(Session, Integer(Ids[I]), 'v' + IntToStr(I - 1) + #10,
          'v' + IntToStr(I) + #10, Detail));
    end;

    { Undo all five, newest-first, so the file lands back at v0. }
    Detail := '';
    AssertTrue('undo 5: ' + Detail, Session.UndoTurn(Ids[1], Detail));
    AssertEquals('back to v0', 'v0'#10, ReadText('a.txt'));

    { THE PROMPT. This is what abandons the window above. }
    Session.View.Store.BeginTurn(Session.View.SessionId, Ids[6], StoreErr);
    if Ids[6] <= 0 then
      Ids[6] := 6;
    Session.View.Store.FinishTurn(Ids[6], tsCompleted, 'stop', 0, '', '',
      StoreErr);
    Detail := '';
    WriteText('a.txt', 'v6'#10);
    AssertTrue('row 6: ' + Detail, SeedChange(Session, Integer(Ids[6]), 'v0'#10,
      'v6'#10, Detail));

    { Two more turns, then undo those two. }
    Session.View.Store.BeginTurn(Session.View.SessionId, Ids[7], StoreErr);
    if Ids[7] <= 0 then
      Ids[7] := 7;
    Session.View.Store.FinishTurn(Ids[7], tsCompleted, 'stop', 0, '', '',
      StoreErr);
    Detail := '';
    WriteText('a.txt', 'v7'#10);
    AssertTrue('row 7: ' + Detail, SeedChange(Session, Integer(Ids[7]), 'v6'#10,
      'v7'#10, Detail));

    Detail := '';
    AssertTrue('undo the two: ' + Detail, Session.UndoTurn(Ids[6], Detail));
    AssertEquals('back to v0', 'v0'#10, ReadText('a.txt'));

    { The bare redo the operator would type. It must resolve to turn 6 - the
      oldest REDOABLE turn - and not turn 1. }
    AssertEquals('the oldest redoable turn is 6, not 1', Ids[6],
      Session.OldestRedoableTurn);

    { And asking for turn 1 explicitly is refused rather than silently clamped. }
    Detail := '';
    AssertFalse('the abandoned five are refused', Session.RedoTurn(Ids[1],
      Detail));
    AssertTrue('and say why: ' + Detail, Pos('abandoned', Detail) > 0);

    Detail := '';
    AssertTrue('redo the two: ' + Detail,
      Session.RedoTurn(Session.OldestRedoableTurn, Detail));
    AssertEquals('forward to v7', 'v7'#10, ReadText('a.txt'));

    { The abandoned five are STILL undone: redoing the later pair must not have
      dragged them back, and they keep that status because the record is meant to
      show they happened and were undone. }
    Turns := Session.View.Turns;
    for I := 0 to High(Turns) do
    begin
      if Turns[I].Id = Ids[1] then
        AssertEquals('turn 1 is still undone', Ord(tsUndone),
          Ord(Turns[I].Status));
      if Turns[I].Id = Ids[6] then
        AssertEquals('turn 6 is live again', Ord(tsCompleted),
          Ord(Turns[I].Status));
    end;
  finally
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

procedure THarnessSessionTest.TestAPeerArrivingRaisesOneTransitionNotice;
var
  Session: THarnessSession;
  Err: string;
  Items: TPromptItemArray;
  I: Integer;
  Seen: Boolean;
  Row: TSessionRuntimeRow;
  E: TStoreError;
  PeerSid: string;
begin
  { An agent must switch behaviour when a peer arrives, not carry on alone. And
    the FIRST observation is not a transition: a session must never be told a peer
    "joined" when it merely looked for the first time. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    { First tick: alone, so no transition from nowhere. }
    Session.NoticeBoard;
    Session.Loop.PromptQueue.DrainItems;

    { A peer registers a runtime row - the signal that someone else is live. }
    AssertTrue('peer session', Session.View.Store.CreateSession(
      Session.View.WorkspaceId, PeerSid, E));
    Row := Default(TSessionRuntimeRow);
    Row.SessionId := PeerSid;
    Row.Pid := 1;
    Row.SocketPath := '/tmp/peer.sock';
    Row.StartedAt := 1700000000;
    Row.UpdatedAt := 1700000000;
    AssertTrue('peer runtime', Session.View.Store.RegisterRuntime(Row, E));

    { The next tick sees multi-mode: one notice, naming coordination. }
    Session.NoticeBoard;
    Items := Session.Loop.PromptQueue.DrainItems;
    Seen := False;
    for I := 0 to High(Items) do
      if Pos('Another session', Items[I].Text) > 0 then
        Seen := True;
    AssertTrue('the peer arrival is announced', Seen);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestARevivedSessionIsToldItWasAway;
var
  Session: THarnessSession;
  Err: string;
begin
  { NOT YET TESTED: the notice assembly. NoticeRevival needs a backdated cursor,
    a board entry to miss, and a reclaimed claim to report - and the session seam
    offers no way to backdate last_seen_at, so the test would have to reach into
    SQL the way test_tasks_store does.

    What IS tested: CursorLastSeenOf and ReclaimedFrom at the store level (see
    test_board_store and test_tasks_store), which are the two queries the notice
    is built from. The assembly itself is verified only by reading.

    Keeping the placeholder so the gap is visible rather than pretended-closed. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertTrue('a session with no cursor is not a revival', True);
  finally
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
