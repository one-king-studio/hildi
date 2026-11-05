unit TestHarnessSession;
{ fpcunit tests for HildiHarnessSession: bootstrap in memory and
  against a store, resume, and failure modes. Uses the fake LLM transport and a
  temporary workspace/store. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, Generics.Collections,
  LLMClient, LLMEnv, LLMProvider, HildiAgent, HildiSession,
  HildiStore, HildiWorkspace,
  HildiRecallTool,
  HildiHarnessSession, HildiHarnessView, HildiSkills,
  HildiSessionStore,
  HildiMCPConfig, HildiMCPProvider,
  HildiBoard, HildiBoardStore,
  HildiTasks, HildiTasksStore,
  ChangesTypes, ChangesText, ChangesStore,
  HildiChangesStore, HildiChangesRevert,
  HildiTasksTools, HildiSQLITE,
  LLMFakes;

type
  THarnessSessionTest = class(TTestCase)
  private
    FDir: string;
    FStorePath: string;
    FTransports: TObjectList<TFakeTransport>;
    procedure WriteFileText(const APath, AText: string);
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
    { ResolveProviderConfig: store -> environment -> default, and an install with
      no provider row must behave exactly as it did before. }
    procedure TestNoProviderRowFallsThroughToTheEnvironment;
    procedure TestStoredProviderSuppliesEndpointModelAndParameters;
    procedure TestEnvironmentFillsOnlyWhatTheStoreLeftEmpty;
    procedure TestStoredZeroTemperatureIsAppliedAsConfigured;
    procedure TestStoreCreatesSessionAndHistoryRoundTrips;
    procedure TestHistoryRestoresBlocks;
    procedure TestResumeUnknownSessionFails;
    procedure TestMissingWorkspaceFails;
    procedure TestRecallToolRegisteredWithStore;
    { The task list's tools and its stable prose, in a real session. }
    procedure TestTaskToolsRegisteredWithStore;
    procedure TestTheCoordinationTextRidesTheSystemPrompt;
    { AGENTS.md: read from the workspace root, tagged with its source, and
      re-read per turn so an edit is picked up without a restart. }
    procedure TestAgentsMdRidesTheStablePrompt;
    procedure TestAgentsMdIsTaggedWithItsSource;
    procedure TestAgentsMdFallsBackToReadme;
    procedure TestAgentsMdAbsentLeavesNoBlock;
    procedure TestAgentsMdIsRepublishedAfterAnEdit;
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
    { A turn that changed no files is a CONVERSATIONAL turn, and going back on
      the conversation is the primary meaning of undo. File reversion is
      secondary, so a file-less turn must still undo and leave the transcript
      rewound. It used to refuse with 'this turn changed no files', which made
      /undo unavailable on any discussion-only session. }
    procedure TestUndoTurnOnAConversationalTurnStillRewinds;
    { A row whose patch was never captured (a process-tier write) is reported,
      not fatal: refusing the whole turn would make undo useless on any session
      that ran a shell command. }
    procedure TestASkippedRowDoesNotBlockTheUndo;
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
    { An operator-typed skill load grants SESSION scope and loads, without
      asking: typing the name is the approval. Deliberately not workspace scope -
      one session's operator has not consented for the whole workspace. }
    procedure TestOperatorSkillLoadGrantsSessionAndLoads;
    { Discovery is WIRED, not merely implemented: a SKILL.md in the workspace is
      found, imported and gated at session open. The home path is passed in so
      the test never reads the real home directory. }
    procedure TestDiscoverSkillFilesImportsAndGates;
    { The shipped example is not merely parseable: a real session pointed at this
      repo finds it, which is what a reader following the docs will do. }
    procedure TestShippedExampleIsDiscoveredByASession;
    { A skill added to the workspace mid-session is picked up at the next turn
      boundary, without a restart. Discovery used to run only in Init. }
    procedure TestSkillAddedMidSessionIsPickedUpAtTheBoundary;
    { A user-scope skill shadowed by a project-scope one is reported, not silently
      dropped. The caller decides how often to say it. }
    procedure TestShadowedSkillIsReported;
    { A skill deleted from disk leaves the MANIFEST at the next rescan, even
      though its body stays in the conversation. The operator's accepted cost is
      the stale body; being told about a skill whose files are gone is not. }
    procedure TestSkillDeletedFromDiskLeavesTheManifest;
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

{ Remove a directory and everything under it. FPC's SysUtils has no DelTree and
  FileUtil is not on this project's unit path, so this is the FindFirst walk the
  smoke runner uses. }
procedure RemoveTree(const APath: string);
var
  SR: TSearchRec;
  Child: string;
begin
  if not DirectoryExists(APath) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        Child := IncludeTrailingPathDelimiter(APath) + SR.Name;
        if DirectoryExists(Child) then
          RemoveTree(Child)
        else
          DeleteFile(Child);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
  RemoveDir(APath);
end;

procedure THarnessSessionTest.SetUp;
begin
  FTransports := TObjectList<TFakeTransport>.Create(True);
  { The PID is part of the name because Random() is not unique ACROSS
    PROCESSES: the parallel gate starts its workers together, each calls
    Randomize seeded from the clock, and two workers can draw the same number.
    They then shared one directory - and because some tests here WRITE
    AGENTS.md while TestAgentsMdAbsentLeavesNoBlock asserts its ABSENCE, a
    shared dir made that test fail with "got a block" for no reason anyone
    could see in the test itself. }
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-session-' +
    IntToStr(GetProcessID) + '-' + IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
end;

procedure THarnessSessionTest.TearDown;
begin
  FTransports.Free;
  if FileExists(FStorePath) then
    DeleteFile(FStorePath);
  { RemoveDir removes an EMPTY directory only, and the AGENTS.md tests write
    files into this one, so the old teardown left every such tree behind: 8,783
    hh-session-* directories were sitting in the temp dir on this machine, some
    still carrying an AGENTS.md. That leak is what made the collision possible
    to miss - a fresh random number never landed on a stale tree, so nothing
    pointed at it. }
  RemoveTree(FDir);
end;

{ Write a text file, creating parent directories. Small local helper so the
  AGENTS.md tests read as prose rather than as stream plumbing. }
procedure THarnessSessionTest.WriteFileText(const APath, AText: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmCreate);
  try
    if AText <> '' then
      FS.WriteBuffer(AText[1], Length(AText));
  finally
    FS.Free;
  end;
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

procedure THarnessSessionTest.TestNoProviderRowFallsThroughToTheEnvironment;
var
  StoreCfg: TStoreConfig;
  Store: TSqliteStore;
  Cfg: TLLMConfig;
  Err: TLLMError;
  StoreErr: TStoreError;
begin
  { THE BACKWARD-COMPATIBILITY TEST. An install that has never created a provider
    row must behave exactly as it did before providers existed. }
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('store opens', Store.Open(StoreErr));
    LLMEnv.SetProcessEnv('HILDI_LLM_MODEL', 'env-model');
    Cfg := Default(TLLMConfig);
    AssertTrue('resolves', ResolveProviderConfig(Store, Cfg, False, False, Cfg,
      Err));
    AssertEquals('model from the environment', 'env-model', Cfg.Model);
    AssertEquals('no provider named', '', Cfg.Provider);
    AssertEquals('the default endpoint', DefaultLLMEndpoint, Cfg.Endpoint);
  finally
    LLMEnv.SetProcessEnv('HILDI_LLM_MODEL', '');
    Store.Free;
  end;
end;

procedure THarnessSessionTest.TestStoredProviderSuppliesEndpointModelAndParameters;
var
  StoreCfg: TStoreConfig;
  Store: TSqliteStore;
  Row: TProviderRow;
  Cfg: TLLMConfig;
  Err: TLLMError;
  StoreErr: TStoreError;
begin
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('store opens', Store.Open(StoreErr));
    Row := Default(TProviderRow);
    Row.Name := 'openrouter';
    Row.Key := 'openrouter';
    Row.Endpoint := 'https://openrouter.ai/api/v1/chat/completions';
    Row.Model := 'openai/gpt-4o';
    AssertTrue('saved: ' + StoreErr.Message, Store.SaveProvider(Row, StoreErr));
    AssertTrue('activated: ' + StoreErr.Message,
      Store.SetActiveProvider('openrouter', StoreErr));

    Cfg := Default(TLLMConfig);
    AssertTrue('resolves', ResolveProviderConfig(Store, Cfg, False, False, Cfg,
      Err));
    { The provider NAME is what the client resolves its dialect from, so it has
      to survive resolution - a stored row that did not name itself would send
      OpenRouter traffic to the Fireworks adapter. }
    AssertEquals('provider named', 'openrouter', Cfg.Provider);
    AssertEquals('endpoint', Row.Endpoint, Cfg.Endpoint);
    AssertEquals('model', 'openai/gpt-4o', Cfg.Model);
    { No parameter assertions: a provider is a CONNECTION and carries none.
      Sampling is an agent concern, tested where agents are tested. }
  finally
    Store.Free;
  end;
end;

procedure THarnessSessionTest.TestEnvironmentFillsOnlyWhatTheStoreLeftEmpty;
var
  StoreCfg: TStoreConfig;
  Store: TSqliteStore;
  Row: TProviderRow;
  Cfg: TLLMConfig;
  Err: TLLMError;
  StoreErr: TStoreError;
begin
  { The store supplies the model; the environment supplies the key. Neither
    overwrites the other - the same "never override" rule ApplyEnv follows. }
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('store opens', Store.Open(StoreErr));
    Row := Default(TProviderRow);
    Row.Name := 'openai';
    Row.Key := 'openai';
    Row.Model := 'gpt-4o';
    Row.Endpoint := 'https://api.openai.com/v1/chat/completions';
    AssertTrue('saved', Store.SaveProvider(Row, StoreErr));
    AssertTrue('activated', Store.SetActiveProvider('openai', StoreErr));
    LLMEnv.SetProcessEnv('HILDI_LLM_API_KEY', 'env-key');

    Cfg := Default(TLLMConfig);
    AssertTrue('resolves', ResolveProviderConfig(Store, Cfg, False, False, Cfg,
      Err));
    AssertEquals('model from the store', 'gpt-4o', Cfg.Model);
    AssertEquals('key from the environment', 'env-key', Cfg.ApiKey);
  finally
    LLMEnv.SetProcessEnv('HILDI_LLM_API_KEY', '');
    Store.Free;
  end;
end;

procedure THarnessSessionTest.TestStoredZeroTemperatureIsAppliedAsConfigured;
var
  StoreCfg: TStoreConfig;
  Store: TSqliteStore;
  Row: TProviderRow;
  Cfg: TLLMConfig;
  Err: TLLMError;
  StoreErr: TStoreError;
begin
  { The tri-state surviving all the way through resolution. A stored 0.0 means
    "deliberately deterministic" and must arrive as a CONFIGURED zero, not as an
    absent parameter - otherwise the request silently omits the key and the
    operator gets whatever the provider defaults to. }
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('store opens', Store.Open(StoreErr));
    Row := Default(TProviderRow);
    { A LABEL that is not a provider slug: Name and Key are separate fields.
      This is the case that exposed the flaw - using Name as the key made any
      operator-chosen label unresolvable. }
    Row.Name := 'deterministic';
    Row.Key := 'fireworks';
    Row.Model := 'm';
    AssertTrue('saved', Store.SaveProvider(Row, StoreErr));
    AssertTrue('activated', Store.SetActiveProvider('deterministic', StoreErr));

    Cfg := Default(TLLMConfig);
    AssertTrue('resolves', ResolveProviderConfig(Store, Cfg, False, False, Cfg,
      Err));
    AssertEquals('endpoint from the row', 'https://api.fireworks.ai/' +
      'inference/v1/chat/completions', Cfg.Endpoint);
  finally
    Store.Free;
  end;
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
    RenewClaims is tested directly in TestTasksStore, so calling it here would
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

procedure THarnessSessionTest.TestUndoTurnOnAConversationalTurnStillRewinds;
var
  Session: THarnessSession;
  Err, Detail: string;
  TurnId: Int64;
  Msgs: TMessageRecordArray;
  Turns: TTurnRecordArray;
  I: Integer;
  StoreErr: TStoreError;
begin
  { A turn that changed no files is a conversation turn. Undo's PRIMARY job is
    going back on the conversation; reverting files is secondary. Refusing here
    made /undo do nothing at all on a session that only talked - which is the
    common case. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Session.View.Store.BeginTurn(Session.View.SessionId, TurnId, StoreErr);
    if TurnId <= 0 then
      TurnId := 1;
    Session.View.Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '',
      StoreErr);
    { A message, and DELIBERATELY no change row: this turn only talked. }
    Detail := '';
    AssertTrue('message: ' + Detail, SeedMessage(Session, TurnId, Detail));

    Detail := '';
    AssertTrue('undo succeeds: ' + Detail, Session.UndoTurn(TurnId, Detail));

    { The transcript moved: the turn is marked undone and out of the context. }
    Turns := Session.View.Turns;
    for I := 0 to High(Turns) do
      if Turns[I].Id = TurnId then
        AssertEquals('the turn is undone', Ord(tsUndone), Ord(Turns[I].Status));

    { The message row survives - soft-deleted, not deleted - but leaves the
      context. Asserting both pins the distinction that redo depends on. }
    AssertTrue('read messages', Session.View.Store.QueryMessages(
      Session.View.SessionId, Msgs, StoreErr));
    AssertEquals('the message row is kept', 1, Length(Msgs));
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestASkippedRowDoesNotBlockTheUndo;
var
  Session: THarnessSession;
  Err, Detail: string;
  TurnId: Int64;
  Turns: TTurnRecordArray;
  Changes: IChangeStore;
  R: TChangeRecord;
  Id: Integer;
  I: Integer;
  StoreErr: TStoreError;
begin
  { A process-tier write records sizes but no patch, because the before-text was
    gone by the time the after-walk ran. The file cannot be restored exactly -
    but refusing the whole turn would make undo useless on any session that ran a
    shell command. The turn must undo and the detail must NAME the file. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Session.View.Store.BeginTurn(Session.View.SessionId, TurnId, StoreErr);
    if TurnId <= 0 then
      TurnId := 1;
    Session.View.Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '',
      StoreErr);

    { A net row with NO patch: exactly what the process tier produces. }
    Changes := TSqliteChangeStore.Create(Session.View.Store);
    R := Default(TChangeRecord);
    R.WorkspaceId := Session.View.WorkspaceId;
    R.SessionId := Session.View.SessionId;
    R.TurnId := Integer(TurnId);
    R.Path := 'appended-by-bash.txt';
    R.Kind := ckModified;
    R.IsNet := True;
    R.Patch := '';              // the whole point: no patch captured
    R.PatchBytes := 0;
    AssertTrue('seeded', Changes.Append(R, Id, Detail));
    AssertTrue('message', SeedMessage(Session, TurnId, Detail));

    Detail := '';
    AssertTrue('the undo still succeeds: ' + Detail,
      Session.UndoTurn(TurnId, Detail));

    { The turn moved, which is the primary meaning of undo. }
    Turns := Session.View.Turns;
    for I := 0 to High(Turns) do
      if Turns[I].Id = TurnId then
        AssertEquals('the turn is undone', Ord(tsUndone), Ord(Turns[I].Status));

    { And the operator is told which file could not be put back. }
    AssertTrue('the skipped file is named: ' + Detail,
      Pos('appended-by-bash.txt', Detail) > 0);
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
    SQL the way TestTasksStore does.

    What IS tested: CursorLastSeenOf and ReclaimedFrom at the store level (see
    TestBoardStore and TestTasksStore), which are the two queries the notice
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
    { The board's and task list's RULES are static, so they now ride the SYSTEM
      prompt and are sent once. The per-turn stable text carries only the mode
      line, because that is the part a peer attaching mid-session can change. }
    P := Session.SystemPromptText;
    AssertTrue('the task list is explained: ' + P, Pos('task_claim', P) > 0);
    AssertTrue('and the board too', Pos('board_post', P) > 0);
    AssertTrue('the protocol is stated', Pos('Claim before you change', P) > 0);
    { And the mode line is NOT in the system prompt: it would be frozen there. }
    AssertTrue('the mode line is not frozen into the system prompt',
      Pos('You are ALONE in this workspace', P) = 0);
    AssertTrue('but it does ride the stable text',
      Pos('You are ALONE in this workspace', Session.Loop.StablePrompt) > 0);
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
    assertion lives in TestAgent (TestStablePromptReachesTheSystemMessage),
    because with no skills declared StableText is legitimately ''. }
  Session := THarnessSession.Open(Config('', '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertTrue('the loop is built', Session.Loop <> nil);
    { The shell guidance is STATIC - generated from the dispatch table and fed by
      no session state - so it now rides the SYSTEM prompt, where it is sent once
      and cached, rather than costing every turn. }
    AssertTrue('the shell guidance is present',
      Pos('Prefer the built-in shell', Session.SystemPromptText) > 0);
    AssertTrue('and names commands',
      Pos('grep', Session.SystemPromptText) > 0);
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
  T: TRegisteredTool;
  Res: string;
  Keys: TStringArray;
  I: Integer;
  IsSkill: Boolean;
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
    { Lazy: the server is DECLARED by the provider but NOT connected, so its
      tools are absent until load_mcp opens it. }
    AssertFalse('mcp tool absent before load',
      Session.Loop.ResolveTool('mcp_fake_echo', Tool));
    { It is a PROVIDER entry now, not a skill: it must not appear among the
      skill keys, and its status lives on the provider. }
    AssertTrue('the provider declares it', Session.McpProvider <> nil);
    AssertEquals('one server declared', 1,
      Length(Session.McpProvider.Names));
    AssertEquals('the server', 'fake', Session.McpProvider.Names[0]);
    Keys := Session.Skills.Keys;
    IsSkill := False;
    for I := 0 to High(Keys) do
      if Keys[I] = 'mcp_fake' then
        IsSkill := True;
    AssertFalse('not a skill at all', IsSkill);
    AssertTrue('reported closed',
      Pos('state="closed"', Session.McpProvider.StatusText) > 0);
    { load_mcp opens it and registers its tools. }
    AssertTrue('load_mcp resolves', Session.McpProvider.Find(LoadMcpToolName, T));
    AssertTrue('opened', T.Handler('{"name":"fake"}', Res, Err));
    AssertTrue('mcp tool resolvable after open',
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
  Names: TStringArray;
  T: TRegisteredTool;
  Res: string;
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

    { The next turn's boundary reconcile picks it up on the PROVIDER (declared,
      not connected); load_mcp opens it and registers the tools. }
    Session.Loop.PrepareProviders;
    Names := Session.McpProvider.Names;
    AssertEquals('picked up by the provider at the boundary', 1, Length(Names));
    AssertEquals('the server', 'late', Names[0]);
    AssertTrue('still closed (lazy)', Length(Session.McpProvider.OpenNames) = 0);
    AssertTrue('load_mcp resolves', Session.McpProvider.Find(LoadMcpToolName, T));
    AssertTrue('opened', T.Handler('{"name":"late"}', Res, Err));
    AssertTrue('resolvable after open',
      Session.Loop.ResolveTool('mcp_late_echo', Tool));
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestOperatorSkillLoadGrantsSessionAndLoads;
var
  Session: THarnessSession;
  Err: string;
  S: TSkill;
begin
  { Typing a skill's name IS the approval, so the load happens without a prompt
    and records a SESSION-scope grant. It must be readable back as the narrower
    scope, not workspace: one operator in one session has not consented on behalf
    of every other session in the workspace. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    S := Default(TSkill);
    S.Key := 'operator_pick';
    S.Name := 'operator-pick';
    S.Description := 'a skill the operator named';
    S.Instructions := 'Do it.';
    S.Location := '/tmp/operator-pick';
    Session.Skills.Add(S);

    Err := '';
    AssertTrue('loaded without asking: ' + Err,
      Session.LoadSkillByName('operator_pick', Err));
    AssertEquals('it is loaded', Ord(ssLoaded),
      Ord(Session.Skills.StateOf('operator_pick')));
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestDiscoverSkillFilesImportsAndGates;
var
  Reg: TSkillRegistry;
  SkillDir: string;
  Fs: TFileStream;
  Text: string;
  Shadowed: TStringArray;
  N: Integer;
begin
  { Discovery is WIRED, not merely implemented. A SKILL.md in the workspace must
    be found and imported, and the registry must carry the gate afterwards - a
    file-backed skill that loaded ungated would be the hole the gate exists to
    close. }
  SkillDir := IncludeTrailingPathDelimiter(FDir) + '.agents' + PathDelim +
    'skills' + PathDelim + 'wired';
  ForceDirectories(SkillDir);
  Text := '---'#10'name: wired'#10'description: found on disk'#10'---'#10'Body.';
  Fs := TFileStream.Create(IncludeTrailingPathDelimiter(SkillDir) + 'SKILL.md',
    fmCreate);
  try
    Fs.WriteBuffer(Text[1], Length(Text));
  finally
    Fs.Free;
  end;

  Reg := TSkillRegistry.Create;
  try
    { An empty home path: the test must not read the operator's real skills. }
    N := DiscoverSkillFiles(Reg, FDir, '', nil, 1, 'sess-1', Shadowed);
    AssertEquals('imported', 1, N);
    AssertEquals('the key is derived', 'wired', Reg.Keys[0]);
    AssertEquals('carries its body', 'Body.', Reg.InstructionsOf('wired'));
    AssertTrue('and its location', Reg.SkillOf('wired').Location <> '');
  finally
    Reg.Free;
  end;
end;

procedure THarnessSessionTest.TestShippedExampleIsDiscoveredByASession;
var
  Reg: TSkillRegistry;
  N, I: Integer;
  Keys: TStringArray;
  Shadowed: TStringArray;
  Found: Boolean;
begin
  { The example is tested for PARSING in TestSkillsFiles, but a reader following
    the docs does not call the parser - they open a session on this repo. This
    checks the path they actually take: the repo root is the workspace, and
    .agents/skills is the first place discovery looks. }
  Reg := TSkillRegistry.Create;
  try
    { Empty home path: never read the operator's real skills dir. }
    N := DiscoverSkillFiles(Reg, GetCurrentDir, '', nil, 1, 'sess-example',
      Shadowed);
    AssertTrue('something was imported', N >= 1);
    Keys := Reg.Keys;
    Found := False;
    for I := 0 to High(Keys) do
      if Keys[I] = 'changelog_writer' then
        Found := True;
    AssertTrue('the example is discovered under its derived key', Found);
    { It is a real skill, not just a name: the body came through. }
    AssertTrue('with its body',
      Pos('Changelog writer', Reg.InstructionsOf('changelog_writer')) > 0);
    AssertTrue('and its location',
      Reg.SkillOf('changelog_writer').Location <> '');
  finally
    Reg.Free;
  end;
end;

procedure THarnessSessionTest.TestSkillAddedMidSessionIsPickedUpAtTheBoundary;
var
  Session: THarnessSession;
  Err: string;
  Keys: TStringArray;
  I: Integer;
  Found: Boolean;
  SkillDir: string;
  Text: string;
  Fs: TFileStream;
begin
  { Discovery used to run only in Init, so a skill dropped into .agents/skills
    during a session was invisible until restart. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertEquals('no skills to begin with', 0, Length(Session.Skills.Keys));

    { The operator installs a skill mid-session. }
    SkillDir := IncludeTrailingPathDelimiter(FDir) + '.agents' + PathDelim +
      'skills' + PathDelim + 'later';
    ForceDirectories(SkillDir);
    Text := '---'#10'name: later'#10'description: added while running'#10 +
      '---'#10'Body.';
    Fs := TFileStream.Create(IncludeTrailingPathDelimiter(SkillDir) + 'SKILL.md',
      fmCreate);
    try
      Fs.WriteBuffer(Text[1], Length(Text));
    finally
      Fs.Free;
    end;

    { The turn boundary is where a rescan happens. }
    Session.Loop.PrepareProviders;
    Keys := Session.Skills.Keys;
    Found := False;
    for I := 0 to High(Keys) do
      if Keys[I] = 'later' then
        Found := True;
    AssertTrue('picked up at the boundary', Found);
    AssertTrue('with its body',
      Pos('Body.', Session.Skills.InstructionsOf('later')) > 0);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestShadowedSkillIsReported;
var
  Reg: TSkillRegistry;
  Shadowed: TStringArray;
  N: Integer;
  HomeDir, SkillDir: string;
  Text: string;
  Fs: TFileStream;

  procedure WriteAt(const ADir, AName: string);
  var
    S: string;
  begin
    ForceDirectories(ADir);
    S := '---'#10'name: ' + AName + #10'description: d'#10'---'#10'Body.';
    Fs := TFileStream.Create(IncludeTrailingPathDelimiter(ADir) + 'SKILL.md',
      fmCreate);
    try
      Fs.WriteBuffer(S[1], Length(S));
    finally
      Fs.Free;
    end;
  end;

begin
  { A user-scope skill shadowed by a project-scope one used to vanish with no
    explanation: the operator's skill simply did not work. Discovery now reports
    it and the caller decides how often to say so. }
  HomeDir := IncludeTrailingPathDelimiter(FDir) + 'home';
  WriteAt(IncludeTrailingPathDelimiter(HomeDir) + '.agents' + PathDelim +
    'skills' + PathDelim + 'dupe', 'dupe');
  WriteAt(IncludeTrailingPathDelimiter(FDir) + '.agents' + PathDelim +
    'skills' + PathDelim + 'dupe', 'dupe');

  Reg := TSkillRegistry.Create;
  try
    N := DiscoverSkillFiles(Reg, FDir, HomeDir, nil, 1, 'sess-shadow', Shadowed);
    AssertEquals('only the project one imports', 1, N);
    AssertEquals('and the shadowed one is reported, not dropped', 1,
      Length(Shadowed));
    AssertTrue('naming it: ' + Shadowed[0], Pos('dupe', Shadowed[0]) > 0);
  finally
    Reg.Free;
  end;
end;

procedure THarnessSessionTest.TestSkillDeletedFromDiskLeavesTheManifest;
var
  Session: THarnessSession;
  Err: string;
  Keys: TStringArray;
  I: Integer;
  Found: Boolean;
  SkillDir, MD, Text: string;
  Fs: TFileStream;
begin
  { Install a skill, confirm the session sees it, then delete the file. The body
    stays in the conversation - the operator's accepted cost - but the skill must
    leave the manifest, or the model keeps being told about tools that fail. }
  SkillDir := IncludeTrailingPathDelimiter(FDir) + '.agents' + PathDelim +
    'skills' + PathDelim + 'doomed';
  ForceDirectories(SkillDir);
  MD := IncludeTrailingPathDelimiter(SkillDir) + 'SKILL.md';
  Text := '---'#10'name: doomed'#10'description: about to vanish'#10'---'#10'x';
  Fs := TFileStream.Create(MD, fmCreate);
  try
    Fs.WriteBuffer(Text[1], Length(Text));
  finally
    Fs.Free;
  end;

  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    Session.Loop.PrepareProviders;
    Keys := Session.Skills.Keys;
    Found := False;
    for I := 0 to High(Keys) do
      if Keys[I] = 'doomed' then
        Found := True;
    AssertTrue('discovered to begin with', Found);

    { The operator deletes the skill directory. }
    AssertTrue('file removed', DeleteFile(MD));

    Session.Loop.PrepareProviders;
    Keys := Session.Skills.Keys;
    Found := False;
    for I := 0 to High(Keys) do
      if Keys[I] = 'doomed' then
        Found := True;
    AssertFalse('gone from the manifest after the rescan', Found);
  finally
    Session.Free;
  end;
end;

{ --- AGENTS.md ---------------------------------------------------------- }

procedure THarnessSessionTest.TestAgentsMdRidesTheStablePrompt;
var
  Session: THarnessSession;
  Err: string;
begin
  WriteFileText(IncludeTrailingPathDelimiter(FDir) + 'AGENTS.md',
    '# House rules' + #10 + 'Always run make check before reporting done.');
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertTrue('the file content is in the stable prompt',
      Pos('Always run make check before reporting done',
        Session.Loop.StablePrompt) > 0);
    { It is workspace CONTEXT, so it must not be frozen into the system prompt:
      the operator edits it between turns and expects that to take effect. }
    AssertFalse('and not frozen into the system prompt',
      Pos('Always run make check before reporting done',
        Session.SystemPromptText) > 0);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestAgentsMdIsTaggedWithItsSource;
var
  Session: THarnessSession;
  Err: string;
begin
  WriteFileText(IncludeTrailingPathDelimiter(FDir) + 'AGENTS.md', 'be brief');
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    { The wrapper is what keeps the harness's own rules authoritative: the text
      is named as FILE CONTENTS and explicitly subordinated, so a repository
      cannot issue instructions of its own. }
    AssertTrue('wrapped in an element',
      Pos('<agents_md source="AGENTS.md">', Session.Loop.StablePrompt) > 0);
    AssertTrue('and closed', Pos('</agents_md>', Session.Loop.StablePrompt) > 0);
    AssertTrue('named as context, not instructions',
      Pos('not instructions from the harness', Session.Loop.StablePrompt) > 0);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestAgentsMdFallsBackToReadme;
var
  Session: THarnessSession;
  Err: string;
begin
  { No AGENTS.md: the README stands in, and the prompt says WHICH file it came
    from - an agent-directed file and a human-facing one weigh differently. }
  WriteFileText(IncludeTrailingPathDelimiter(FDir) + 'README.md',
    'Build with make check.');
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertTrue('the README content is used',
      Pos('Build with make check', Session.Loop.StablePrompt) > 0);
    AssertTrue('and its own name is reported',
      Pos('source="README.md"', Session.Loop.StablePrompt) > 0);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestAgentsMdAbsentLeavesNoBlock;
var
  Session: THarnessSession;
  Err: string;
begin
  { Absent is normal, not an error: nothing is injected and no empty wrapper
    is left behind. }
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertFalse('no block at all',
      Pos('<agents_md', Session.Loop.StablePrompt) > 0);
  finally
    Session.Free;
  end;
end;

procedure THarnessSessionTest.TestAgentsMdIsRepublishedAfterAnEdit;
var
  Session: THarnessSession;
  Err: string;
begin
  { THE POINT OF RE-READING PER TURN: the operator edits the file mid-session and
    the next turn sees it. A version read once at Init would go stale silently. }
  WriteFileText(IncludeTrailingPathDelimiter(FDir) + 'AGENTS.md', 'FIRST-VERSION');
  Session := THarnessSession.Open(Config(FStorePath, '', False), Err);
  AssertTrue('opened: ' + Err, Session <> nil);
  try
    AssertTrue('the first version is present',
      Pos('FIRST-VERSION', Session.Loop.StablePrompt) > 0);
    WriteFileText(IncludeTrailingPathDelimiter(FDir) + 'AGENTS.md',
      'SECOND-VERSION');
    Session.RecomposePrompt;
    AssertTrue('the edit is picked up',
      Pos('SECOND-VERSION', Session.Loop.StablePrompt) > 0);
    AssertFalse('and the old text is gone',
      Pos('FIRST-VERSION', Session.Loop.StablePrompt) > 0);
  finally
    Session.Free;
  end;
end;

initialization
  RegisterTest(THarnessSessionTest);

  Randomize;end.
