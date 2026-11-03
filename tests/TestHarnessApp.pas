unit TestHarnessApp;
{ fpcunit tests for HildiHarnessApp: the application wires the
  session, widgets, turn queue, and approval modal together. Runs a real turn
  through the worker over the fake transport against an in-memory surface and a
  scripted input source. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, Generics.Collections,
  HildiLLM, HildiAgent, HildiApproval,
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUIWidgetsChat,
  HildiHarnessTurn, HildiHarnessSession,
  HildiHarnessView,
  HildiHarnessDriver, HildiHarnessDriverLocal,
  HildiHarnessApp,
  HildiHarnessSubagentSpy,
  HildiSessionProtocol, HildiSessionClient,
  HildiStore,
  HildiSession, LLMFakes,
  HildiChangesStore, ChangesTypes, ChangesStore, ChangesText;

type
  { Calls Gate.Ask on its own thread so the app can answer it. }
  TGateAskThread = class(TThread)
  private
    FGate: TApprovalGate;
    FAsk: TApprovalAsk;
  public
    Choice: TApprovalChoice;
    constructor Create(AGate: TApprovalGate; const AAsk: TApprovalAsk);
    procedure Execute; override;
  end;

  { Sleeps after every stream chunk, so a turn stays in flight long enough for
    the test to press Escape at it. }
  TSlowChunks = class
  private
    FMs: Integer;
  public
    constructor Create(AMs: Integer);
    procedure AfterChunk(Sender: TObject);
  end;

  { Fails the next request after the first stream chunk, so a truncated
    response's continuation hits a network error. }
  TFailNetworkAfterChunk = class
  private
    FFake: TFakeTransport;
  public
    constructor Create(AFake: TFakeTransport);
    procedure AfterChunk(Sender: TObject);
  end;

  { Records subagent commands, so the spy's abort/release path is observable
    (the local driver's are no-ops). Everything else is inert. }
  TRecordingDriver = class(TInterfacedObject, ISessionDriver)
  public
    AbortedId: string;
    ReleasedId: string;
    { What the mock claims exists, and which of those are in context. Set by a
      test so the palette's loaded/unloaded marking is observable. }
    Skills: TStringArray;
    LoadedSkills: TStringArray;
    { Which skill detail the app asked for, so a test can assert the request. }
    DetailRequested: string;
    LoadedId: string;
    procedure StartTurn(const AText: string);
    procedure QueuePrompt(const AText: string);
    procedure Interrupt;
    procedure AnswerAsk(const AAskRef: string; const AChoice: TApprovalChoice);
    procedure AbortSubagent(const ASessionId: string);
    procedure ReleaseSubagent(const ASessionId: string);
    procedure Checkpoint;
    procedure Undo(ATurnId: Int64 = 0);
    procedure Redo(ATurnId: Int64 = 0);
    { The mock reports no skills and records load/unload calls, so a test can
      assert the app asked without needing a runtime. }
    procedure SkillKeys(out AKeys: TStringArray);
    procedure SkillLoadedKeys(out AKeys: TStringArray);
    { Records the request; the mock has no skill bodies to hand back. }
    procedure SkillDetail(const AKey: string);
    procedure LoadSkill(const AKey: string);
    procedure UnloadSkill(const AKey: string);
    function PopEvent(out AEvent: TTurnEvent): Boolean;
    function Dropped: Int64;
    procedure Close;
  end;

  THarnessAppTest = class(TTestCase)
  private
    FDir: string;
    FSession: THarnessSession;
    FSurface: TSurfaceMemory;
    FInput: TInputSourceScripted;
    FApp: THarnessApp;
    FFake: TFakeTransport;
    FStorePath: string;
    { The switch-session tests: views and harness sessions opened by the fake
      callback (owned here, freed in TearDown), and the scripted outcome. }
    FSwitchViews: array of TSessionView;
    FSwitchSessions: array of THarnessSession;
    FSwitchResult: Boolean;
    FSwitchErr: string;
    FSwitchCalls: Integer;
    { The spy tests: a scripted spy-open (a detached spy over a caller queue) and
      the queue the test pushes child events onto. }
    FSpyOpens: Integer;
    FSpyQueue: TTurnQueue;
    { The config the app asked the spy factory for, so a test can assert HOW the
      spy was asked to attach (e.g. that it does not request a replay). }
    FSpyConfig: TSessionClientConfig;
    FRecording: TRecordingDriver;
    function OpenStubSpy(const ASessionId: string;
      const AConfig: TSessionClientConfig; out AError: string): TSubagentSpy;
    function SwitchTo(const ASessionId: string; out ASession: TSessionView;
      out ADriver: ISessionDriver; out AError: string): Boolean;
    procedure Build;
    procedure BuildWithStore;
    { A genuinely IDLE app: a store-backed session view with no id and no driver,
      so ConnState is csIdle. BuildWithStore is the opposite - it is fully
      attached - and using it for an "unattached" claim is how
      TestNewIsAbsentWhenUnattached passed while asserting a false premise. }
    procedure BuildIdle;
    function Key(AKind: TKeyKind): TInputEvent;
    function Ch(const AText: string): TInputEvent;
    function Ctrl(const ACh: string): TInputEvent;
    procedure SubmitPrompt(const AText: string);
    function Pump(AMax: Integer): Boolean;
    function MakeAsk: TApprovalAsk;
    function BlockCount: Integer;
    function BlockKind(AIndex: Integer): TChatKind;
    { The workspace path the block's body row AY resolves to, for the file-row
      selection tests. }
    function BlockFileAt(AIndex, AY: Integer): string;
    { Lay a block out as the stream would, so its body origin is known before a
      click can land. }
    procedure ArrangeBlock(AIndex, AWidth: Integer);
    function BlockLabel(AIndex: Integer): string;
    function BlockText(AIndex: Integer): string;
    { The block's layout-build count: increments when its body is re-parsed, so a
      test can prove a frame did NOT re-parse it. }
    function BlockBuilds(AIndex: Integer): Integer;
    function BlockLive(AIndex: Integer): Boolean;
    function FindText(AKind: TChatKind; const ANeedle: string): Boolean;
    function BlockSignature: string;
    function DividerSignature: string;
    function ThoughtLabel: string;
    function AssistantEvent(const AText: string): TTurnEvent;
    function SubagentEvent(const ASubSessionId, ALabel,
      AStatus: string): TTurnEvent;
    function ApprovalEvent(ARequestId: Integer;
      const AAsk: TApprovalAsk): TTurnEvent;
    function Config: THarnessSessionConfig;
    { The lazy-connect hook: attach a local driver to the current app. }
    procedure AttachLocal;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestStreamedTurnRendersAndReenables;
    procedure TestAssistantMetadataIsStrippedAndShown;
    procedure TestAssistantUnterminatedBlockIsNotLost;
    procedure TestAssistantFinalizedAfterTurn;
    procedure TestToolLineAppears;
    procedure TestEmptyToolResultShowsPlaceholder;
    procedure TestAppStreamsToolOutput;
    procedure TestStreamedToolOutputCoalescesOneAppendPerFrame;
    { The live-output trim must not fire every frame. It routes through SetText,
      which re-parses the whole body; with a plain "> MaxLiveChars" test the
      marker prefix kept the body above the limit, so it re-parsed every frame at
      the 10 ms tick -- a 64 KB markdown re-parse 100x/second on the UI thread. }
    procedure TestLongToolOutputIsNotTrimmedEveryFrame;
    procedure TestConcurrentToolOutputRoutesPerCall;
    procedure TestLiveToolBlockIsCapped;
    procedure TestDrainStopsAtTheBudget;
    procedure TestResumeShowsTheResult;
    procedure TestErrorLineAppears;
    procedure TestApprovalModalResolvesGateAsk;
    procedure TestAsksDoNotStack;
    procedure TestOneFramePerStep;
    procedure TestRenderHistoryRestoresToolBlocks;
    procedure TestResumeStripsAStoredMalformedBlock;
    procedure TestTranscriptIsBoundedToTheTail;
    procedure TestFullPagingIsContinuous;
    procedure TestHeaderShowsSessionIdAndContext;
    procedure TestHeaderShowsTheSessionTitle;
    procedure TestHeaderTruncatesALongTitle;
    procedure TestHeaderRendersANonAsciiTitle;
    procedure TestRenamingTheCurrentSessionUpdatesTheHeader;
    { /new mints a session in this workspace and switches to it. }
    procedure TestNewCommandMintsAndSwitchesSession;
    procedure TestNewIsAbsentWhenUnattached;
    procedure TestNewIsOfferedWhenAttached;
    { /checkpoint needs a runtime to draft through, so it appears only once one is
      attached - the same predicate RunCommand's own guard uses. }
    procedure TestCheckpointIsAbsentWhenUnattached;
    procedure TestCheckpointIsOfferedWhenAttached;
    { The POSITIVE half of "only actionable entries": a palette that never offered
      /undo or /redo at all satisfied the absence-only tests. }
    procedure TestTurnCommandsAppearWhenActionable;
    { The tool caption: varied across calls, stable within one, and honest about
      its fallback. Previously only asserted by typing the expected string into
      the panel and checking it echoed. }
    procedure TestToolWaitCaptionVariesAcrossCalls;
    procedure TestToolWaitCaptionIsStableForOneCall;
    procedure TestToolWaitCaptionFallsBackToTheToolName;
    procedure TestToolWaitCaptionReachesTheStatus;
    { Variety proven END TO END, without consulting the composer: two calls with
      the same reason must not produce the same caption on screen. }
    procedure TestTwoCallsInATurnReadDifferently;
    { The caption says what is ACTUALLY happening: the tool's action plus its
      primary argument, not a generic wait. Every existing caption test passes an
      EMPTY ToolArguments, so all of them reach the fallback branch and none of
      them exercises this. }
    procedure TestActivityCaptionNamesTheFile;
    procedure TestActivityCaptionNamesTheCommand;
    procedure TestActivityCaptionSearchesForAPattern;
    procedure TestActivityCaptionClampsALongSubject;
    procedure TestActivityCaptionSurvivesMalformedArguments;
    procedure TestActivityCaptionPrefersTheSubjectOverTheReason;
    procedure TestActivityCaptionDoesNotDoubleUpTheToolName;
    procedure TestActivityCaptionReachesTheStatus;
    procedure TestHeaderReadsNewSessionWithoutAnId;
    { EVERY command RunCommand dispatches must be listed in the palette. RunCommand
      is reachable only through the palette, and with no match the palette declines
      the key and the composer sends the text as a PROMPT - which is how /undo,
      /redo and /revert were unreachable and got sent to the model verbatim. }
    procedure TestEveryDispatchedCommandIsOfferedByThePalette;
    procedure TestTurnCommandsAreAbsentOnAFreshSession;
    procedure TestNoCommandHasAnEmptyName;
    { Escape dismisses the palette and leaves the typed '/' alone, so an ordinary
      prompt may begin with a slash. It must STAY dismissed while the box holds a
      lone '/token', or the list pops back on the next keystroke. }
    procedure TestEscapeDismissesThePaletteSoSlashCanBeAPrompt;
    { The panel marks each skill row, so the operator can see what is already in
      context without opening anything. }
    procedure TestSkillListMarksLoadedUnloaded;
    procedure TestStatusShowsWorkspaceAndConsumption;
    procedure TestStatusSumsTurns;
    procedure TestResumeHeaderMatchesLive;
    procedure TestTurnDividerAfterSuccessfulTurn;
    procedure TestNoDividerAfterFailedTurn;
    { A turn that wrote nothing renders no summary block: an empty summary is
      noise, and its absence already says the tree is untouched. }
    procedure TestNoTurnChangesBlockWhenNothingChanged;
    { The positive path: a turn that DID change files renders the block, with the
      per-file stat lines. Without this, an emitter that returned early on every
      call would leave the suite green. }
    procedure TestTurnSummaryBlockListsTheChangedFiles;
    procedure TestTurnSummaryOmitsAFileWhoseEditsCancelled;
    procedure TestResumeRendersTurnDividers;
    procedure TestThoughtShowsDuration;
    procedure TestCtaHintsAreBlank;
    { The ctrl+d segment is conditional on having subagents at all. }
    procedure TestComposerHintsShowCtrlDOnlyWithSubagents;
    procedure TestCoarseScrollTargetMapsSegments;
    procedure TestShouldTrimHistory;
    procedure TestAgentListTogglesWithCtrlD;
    procedure TestAgentListRendersItsRows;
    { The list moved into the composer's place; keys must still reach it, and
      Enter on a row must open that child's spy. This is the one behaviour I
      shipped without proof. }
    procedure TestAgentListRoutesKeysAndEntersTheSpy;
    { Attaching a spy mid-turn replays the child's turn from the ring, while
      RenderSpyHistory separately loads the same messages from the store. The
      transcript must contain each message ONCE - doubled content is what the
      operator saw right after switching, and it is the suspected cause of the
      crash that followed. }
    procedure TestSpyTranscriptIsNotDoubled;
    procedure TestSpyEnterShowsChildAndIndicator;
    procedure TestSpyCtrlDReturnsToParent;
    { Escape is now a two-step CANCEL, not an exit: the first press arms, the
      second cancels the child. Exit is Ctrl+D's job. }
    procedure TestSpyEscapeArmsWithoutLeaving;
    procedure TestSpySuppressesParentEvents;
    { An approval ask is NOT transcript: dropping it while spying deadlocked the
      child, because auto-deny stands down whenever a client is attached. }
    procedure TestSpyStillShowsAnApprovalAsk;
    { A delegated child must not read as a peer of its parent in the sessions
      list: it follows its parent, indented, at every depth. Pure policy test. }
    procedure TestSessionRowsNestUnderTheirParent;
    { Session lists show PARENT sessions only - the recent list under the mark
      and /sessions alike. Subagents live in the agent list. }
    procedure TestSessionListsHideSubagents;
    procedure TestOrphanChildKeepsItsRow;
    { A session identifies itself as `<label> - <title>` wherever it is shown:
      the label names the agent, the title says what it is doing. }
    procedure TestSessionDisplayNameJoinsLabelAndTitle;
    procedure TestSessionDisplayNameFallsBackToTheShortId;
    procedure TestRenameWritesTheLabelNotTheTitleOverride;
    procedure TestOrphanChildStaysAVisibleRoot;
    procedure TestDetachMakesAChildARoot;
    procedure TestSpyUnknownChildIsAnError;
    procedure TestSpyActionsBarAbortsAndReleases;
    procedure TestThinkingStateDuringATurn;
    procedure TestReasoningSettlesIntoAThoughtBlock;
    procedure TestReadyStateAfterATurn;
    procedure TestErrorStateAfterAFailedTurn;
    procedure TestErrorRollsBackStreamedBlocks;
    procedure TestResumeMatchesLiveAfterTruncationError;
    procedure TestEscapeArmsThenCancels;
    procedure TestEarlyCancelRestoresThePrompt;
    { Undo behaves like a CANCEL: the transcript shrinks and the turn's prompt
      comes back to the composer for editing. That is the primary meaning of
      undo on a conversational turn. }
    procedure TestUndoShrinksTheStreamAndRestoresThePrompt;
    procedure TestSubmitWhileBusyQueuesThePrompt;
    procedure TestPasteInsertsIntoTheCompose;
    procedure TestCtrlCQuitsOnlyWhenComposeIsEmpty;
    procedure TestApprovalDimsTheBackground;
    procedure TestSessionsCommandOpensAndClosesTheModal;
    procedure TestEnterInTheSessionsModalClosesIt;
    { Session switching: Enter opens the selected session. }
    procedure TestSwitchSessionOpensTheTarget;
    procedure TestSwitchToCurrentSessionIsANoOp;
    procedure TestSwitchWhileBusyDetaches;
    procedure TestSwitchFailureKeepsTheSession;
    procedure TestSwitchWithoutAHookIsRefused;
    { TUI Startup: the connect lifecycle. }
    procedure TestNoSessionStartsIdle;
    procedure TestPaintBeforeConnectOrder;
    procedure TestSubmitWhileIdleWithoutHookIsRefused;
    procedure TestIdleSubmitTriggersConnect;
    procedure TestAttachMovesToConnectedAndRendersHistory;
    procedure TestFailConnectShowsErrorAndStaysUsable;
    procedure TestSetConnectPhaseUpdatesTheFrame;
  end;

implementation

constructor TGateAskThread.Create(AGate: TApprovalGate; const AAsk: TApprovalAsk);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FGate := AGate;
  FAsk := AAsk;
end;

procedure TGateAskThread.Execute;
begin
  Choice := FGate.Ask(FAsk);
end;

{ TSlowChunks }

constructor TSlowChunks.Create(AMs: Integer);
begin
  inherited Create;
  FMs := AMs;
end;

procedure TSlowChunks.AfterChunk(Sender: TObject);
begin
  Sleep(FMs);
end;

{ TFailNetworkAfterChunk }

constructor TFailNetworkAfterChunk.Create(AFake: TFakeTransport);
begin
  inherited Create;
  FFake := AFake;
end;

procedure TFailNetworkAfterChunk.AfterChunk(Sender: TObject);
begin
  FFake.FailNetwork := True;
end;

procedure TRecordingDriver.StartTurn(const AText: string);
begin
end;

procedure TRecordingDriver.QueuePrompt(const AText: string);
begin
end;

procedure TRecordingDriver.Interrupt;
begin
end;

procedure TRecordingDriver.AnswerAsk(const AAskRef: string;
  const AChoice: TApprovalChoice);
begin
end;

procedure TRecordingDriver.AbortSubagent(const ASessionId: string);
begin
  AbortedId := ASessionId;
end;

procedure TRecordingDriver.ReleaseSubagent(const ASessionId: string);
begin
  ReleasedId := ASessionId;
end;

procedure TRecordingDriver.Checkpoint;
begin
end;

procedure TRecordingDriver.Undo(ATurnId: Int64);
begin
  { The mock records nothing; it exists so the app can be driven without a
    runtime. A test that needs to observe an undo asserts on the real driver. }
end;

procedure TRecordingDriver.Redo(ATurnId: Int64);
begin
  { Mirrored with Undo: the mock records nothing. }
end;

procedure TRecordingDriver.SkillKeys(out AKeys: TStringArray);
begin
  AKeys := Skills;
end;

procedure TRecordingDriver.SkillLoadedKeys(out AKeys: TStringArray);
begin
  AKeys := LoadedSkills;
end;

procedure TRecordingDriver.SkillDetail(const AKey: string);
begin
  { Records the request. The mock holds no bodies, so no event is pushed - the
    app's request is what a test asserts here. }
  DetailRequested := AKey;
end;

procedure TRecordingDriver.LoadSkill(const AKey: string);
begin
  { Recorded but not acted on: the mock has no registry. }
end;

procedure TRecordingDriver.UnloadSkill(const AKey: string);
begin
end;

function TRecordingDriver.PopEvent(out AEvent: TTurnEvent): Boolean;
begin
  AEvent := Default(TTurnEvent);
  Result := False;
end;

function TRecordingDriver.Dropped: Int64;
begin
  Result := 0;
end;

procedure TRecordingDriver.Close;
begin
end;

{ THarnessAppTest }

procedure THarnessAppTest.SetUp;
begin
  FSwitchResult := False;
  FSwitchErr := '';
  FSwitchCalls := 0;
  FSwitchViews := nil;
  FSwitchSessions := nil;
  FSpyOpens := 0;
  FSpyQueue := nil;
  FRecording := nil;
end;

procedure THarnessAppTest.TearDown;
var
  I: Integer;
begin
  FApp.Free;
  FInput := nil;
  FSurface := nil;
  FSession.Free;
  FFake.Free;
  { The switch callback's opens: free the harness sessions (they own their
    internal views and loops) and the target views. FApp is freed first so the
    drivers referencing them are released. }
  for I := 0 to High(FSwitchSessions) do
    FSwitchSessions[I].Free;
  FSwitchSessions := nil;
  for I := 0 to High(FSwitchViews) do
    FSwitchViews[I].Free;
  FSwitchViews := nil;
  { A spy queue the stub never took (the failure test) is still ours. }
  FSpyQueue.Free;
  FSpyQueue := nil;
  if FStorePath <> '' then
  begin
    DeleteFile(FStorePath);
    DeleteFile(FStorePath + '-wal');
    DeleteFile(FStorePath + '-shm');
  end;
  if DirectoryExists(FDir) then
    RemoveDir(FDir);
end;

function THarnessAppTest.Config: THarnessSessionConfig;
begin
  Result := Default(THarnessSessionConfig);
  Result.WorkspacePath := FDir;
  Result.Transport := FFake;
  { Pin the context limit so the header is deterministic (the environment may
    set HILDI_MAX_CONTEXT_TOKENS). }
  Result.MaxContextTokens := 120000;
  { The retry would delay a failed turn by seconds; the tests exercise the
    failure paths, not the retry. }
  Result.RetryMaxAttempts := -1;
end;

procedure THarnessAppTest.AttachLocal;
begin
  FApp.Attach(FSession.View, LocalDriver(FSession));
end;

function THarnessAppTest.OpenStubSpy(const ASessionId: string;
  const AConfig: TSessionClientConfig; out AError: string): TSubagentSpy;
begin
  { A detached spy over a queue the test owns, so entering spy mode needs no
    live child socket. An unknown id fails, exercising the error path. }
  Inc(FSpyOpens);
  FSpyConfig := AConfig;
  if Copy(ASessionId, 1, 8) = 'no-such-' then
  begin
    AError := 'no runtime for session ' + ASessionId;
    Exit(nil);
  end;
  AError := '';
  Result := TSubagentSpy.CreateStub(ASessionId, FSpyQueue);
  FSpyQueue := nil;   // the spy owns it now
end;

function THarnessAppTest.SwitchTo(const ASessionId: string;
  out ASession: TSessionView; out ADriver: ISessionDriver;
  out AError: string): Boolean;
var
  Cfg: THarnessSessionConfig;
  Err: string;
  H: THarnessSession;
begin
  Inc(FSwitchCalls);
  ASession := nil;
  ADriver := nil;
  AError := '';
  if not FSwitchResult then
  begin
    AError := FSwitchErr;
    Exit(False);
  end;
  { Open the target view from the same store, then a local driver over a harness
    session on it (for its queue). Both are owned here and freed in TearDown. }
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := ASessionId;
  ASession := TSessionView.Open(Cfg, Err);
  if ASession = nil then
  begin
    AError := Err;
    Exit(False);
  end;
  SetLength(FSwitchViews, Length(FSwitchViews) + 1);
  FSwitchViews[High(FSwitchViews)] := ASession;
  H := THarnessSession.Open(Cfg, Err);
  SetLength(FSwitchSessions, Length(FSwitchSessions) + 1);
  FSwitchSessions[High(FSwitchSessions)] := H;
  ADriver := LocalDriver(H);
  Result := True;
end;

procedure THarnessAppTest.Build;
var
  Err: string;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := '';
  FFake := TFakeTransport.Create;
  { Tall enough that the approval modal (which grew a row) leaves a margin to
    dim above it. }
  FSurface := TSurfaceMemory.Create(40, 20);
  FInput := TInputSourceScripted.Create;
  FSession := THarnessSession.Open(Config, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, LocalDriver(FSession));
  FApp.Step;   // initial layout/render
end;

procedure THarnessAppTest.BuildWithStore;
var
  Err: string;
  Cfg: THarnessSessionConfig;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, LocalDriver(FSession));
  FApp.Step;
end;

procedure THarnessAppTest.BuildIdle;
var
  Err: string;
begin
  { No store path (so no session id can be minted) and NO driver: ConnState is
    csIdle, which is the pre-connect state the palette's conditions are about. }
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := '';
  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  FSession := THarnessSession.Open(Config, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, nil);
  FApp.Step;
  AssertEquals('the fixture is idle', Ord(csIdle), Ord(FApp.ConnState));
end;

function THarnessAppTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function THarnessAppTest.Ch(const AText: string): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := UnicodeString(AText);
end;

function THarnessAppTest.Ctrl(const ACh: string): TInputEvent;
begin
  Result := Ch(ACh);
  Result.Key.Mods := [moCtrl];
end;

procedure THarnessAppTest.SubmitPrompt(const AText: string);
var
  I: Integer;
begin
  for I := 1 to Length(AText) do
    FInput.Push(Ch(AText[I]));
  { A plain Enter sends; Shift+Enter adds a newline. }
  FInput.Push(Key(kkEnter));
end;

function THarnessAppTest.Pump(AMax: Integer): Boolean;
var
  I: Integer;
  SawBusy: Boolean;
begin
  Result := False;
  SawBusy := False;
  for I := 1 to AMax do
  begin
    FApp.Step;
    if FApp.Busy then
      SawBusy := True
    else if SawBusy then
      Exit(True);
    Sleep(2);
  end;
end;

function THarnessAppTest.AssistantEvent(const AText: string): TTurnEvent;
begin
  Result := Default(TTurnEvent);
  Result.Kind := teAssistantDelta;
  Result.Text := AText;
end;

function THarnessAppTest.SubagentEvent(const ASubSessionId, ALabel,
  AStatus: string): TTurnEvent;
begin
  Result := Default(TTurnEvent);
  Result.Kind := teSubagent;
  Result.SubSessionId := ASubSessionId;
  Result.SubLabel := ALabel;
  Result.SubStatus := AStatus;
end;

function THarnessAppTest.ApprovalEvent(ARequestId: Integer;
  const AAsk: TApprovalAsk): TTurnEvent;
begin
  Result := Default(TTurnEvent);
  Result.Kind := teApprovalAsk;
  Result.RequestId := ARequestId;
  Result.Ask := AAsk;
end;

function THarnessAppTest.BlockCount: Integer;
begin
  Result := FApp.Panel.Stream.Count;
end;

function THarnessAppTest.BlockKind(AIndex: Integer): TChatKind;
begin
  Result := FApp.Panel.Stream.ItemAt(AIndex).Kind;
end;

function THarnessAppTest.BlockLabel(AIndex: Integer): string;
begin
  Result := FApp.Panel.Stream.ItemAt(AIndex).Label_;
end;

function THarnessAppTest.BlockFileAt(AIndex, AY: Integer): string;
begin
  Result := FApp.Panel.Stream.ItemAt(AIndex).FilePathAtRow(AY);
end;

procedure THarnessAppTest.ArrangeBlock(AIndex, AWidth: Integer);
var
  R: TRect;
  Sz: TSize;
  Item: TChatItem;
begin
  Item := FApp.Panel.Stream.ItemAt(AIndex);
  Item.Materialize;
  Sz := Default(TSize);
  Sz.W := AWidth;
  Sz.H := 200;
  Item.Measure(Sz);
  R := Default(TRect);
  R.X := 0;
  R.Y := 0;
  R.W := AWidth;
  R.H := 20;
  Item.Arrange(R);
end;

function THarnessAppTest.BlockText(AIndex: Integer): string;
begin
  Result := FApp.Panel.Stream.ItemAt(AIndex).Text;
end;

function THarnessAppTest.BlockBuilds(AIndex: Integer): Integer;
begin
  Result := FApp.Panel.Stream.ItemAt(AIndex).LayoutBuilds;
end;

function THarnessAppTest.BlockLive(AIndex: Integer): Boolean;
begin
  Result := FApp.Panel.Stream.ItemAt(AIndex).Live;
end;

function THarnessAppTest.FindText(AKind: TChatKind; const ANeedle: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to BlockCount - 1 do
    if (BlockKind(I) = AKind) and (Pos(ANeedle, BlockText(I)) > 0) then
      Exit(True);
end;

function THarnessAppTest.BlockSignature: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to BlockCount - 1 do
    Result := Result + IntToStr(Ord(BlockKind(I))) + ':' + BlockText(I) + '|';
end;

function THarnessAppTest.DividerSignature: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to BlockCount - 1 do
    if BlockKind(I) = ckTurn then
      Result := Result + BlockText(I) + '|';
end;

function THarnessAppTest.ThoughtLabel: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to BlockCount - 1 do
    if BlockKind(I) = ckThought then
      Exit(BlockLabel(I));
end;

function THarnessAppTest.MakeAsk: TApprovalAsk;
var
  Option: TApprovalOption;
begin
  Result := Default(TApprovalAsk);
  Result.Summary := 'rm -rf build/';
  Result.Subject.Ref := 'run_command:rm';
  SetLength(Result.Options, 2);
  Option := Default(TApprovalOption);
  Option.Key := 'opt1';
  Option.Caption := 'Allow once';
  Result.Options[0] := Option;
  Option.Key := 'opt2';
  Option.Caption := 'Always allow';
  Result.Options[1] := Option;
end;

procedure THarnessAppTest.TestStreamedTurnRendersAndReenables;
begin
  Build;
  FFake.AddChunk(TextDelta('hello '));
  FFake.AddChunk(TextDelta('world'));
  FFake.AddChunk(FinishFrame('stop'));
  FFake.AddChunk(DoneFrame);
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));

  AssertEquals('user bubble plus assistant block', 2, BlockCount);
  AssertTrue('first block is the user bubble', BlockKind(0) = ckUser);
  AssertEquals('prompt echoed', 'hi', BlockText(0));
  AssertTrue('assistant streamed', FindText(ckAssistant, 'hello world'));
  AssertTrue('thinking indicator removed',
    not FindText(ckThinking, 'Thinking'));
  AssertTrue('prompt re-enabled', FApp.PromptActive);
  AssertFalse('not busy', FApp.Busy);
end;

procedure THarnessAppTest.TestAssistantMetadataIsStrippedAndShown;
var
  Y: Integer;
  SawTitle: Boolean;
begin
  { A substantive reply opens with a frontmatter block: the block is metadata -
    stripped from the rendered body and drawn as a title + keyword header. }
  Build;
  FFake.AddChunk(TextDelta('---' + #10));
  FFake.AddChunk(TextDelta('title: Fix the drain' + #10));
  FFake.AddChunk(TextDelta('keywords: [drain, tui]' + #10));
  FFake.AddChunk(TextDelta('---' + #10));
  FFake.AddChunk(TextDelta('The body.'));
  FFake.AddChunk(FinishFrame('stop'));
  FFake.AddChunk(DoneFrame);
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));

  { The rendered body excludes the block entirely. }
  AssertFalse('no frontmatter fence', FindText(ckAssistant, '---'));
  AssertFalse('no title line in the body', FindText(ckAssistant, 'title:'));
  AssertTrue('the body is present', FindText(ckAssistant, 'The body.'));
  { The metadata header is drawn on the surface: the title (accent) appears, so
    the block was extracted rather than lost. }
  FApp.Step;   // render
  SawTitle := False;
  for Y := 0 to FSurface.Height - 1 do
    if Pos('Fix the drain', FSurface.RowText(Y, 0, FSurface.Width)) > 0 then
      SawTitle := True;
  AssertTrue('the title is drawn', SawTitle);
end;

procedure THarnessAppTest.TestAssistantUnterminatedBlockIsNotLost;
var
  Y: Integer;
  SawTitle, SawBody: Boolean;
begin
  { The model forgot the closing `---` but left a blank line: the block is still
    extracted (title drawn, block stripped) and the body is shown. This is the
    bug: previously the whole reply vanished. }
  Build;
  FFake.AddChunk(TextDelta('---' + #10));
  FFake.AddChunk(TextDelta('title: Fix the drain' + #10));
  FFake.AddChunk(TextDelta('keywords: [drain]' + #10));
  FFake.AddChunk(TextDelta(#10));
  FFake.AddChunk(TextDelta('The body after a blank line.'));
  FFake.AddChunk(FinishFrame('stop'));
  FFake.AddChunk(DoneFrame);
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));

  AssertTrue('the body is present',
    FindText(ckAssistant, 'The body after a blank line.'));
  AssertFalse('the block is not in the body', FindText(ckAssistant, 'title:'));
  FApp.Step;   // render
  SawTitle := False;
  SawBody := False;
  for Y := 0 to FSurface.Height - 1 do
  begin
    if Pos('Fix the drain', FSurface.RowText(Y, 0, FSurface.Width)) > 0 then
      SawTitle := True;
    if Pos('The body after a blank line.',
      FSurface.RowText(Y, 0, FSurface.Width)) > 0 then
      SawBody := True;
  end;
  AssertTrue('the title is drawn', SawTitle);
  AssertTrue('the body is drawn', SawBody);
end;

procedure THarnessAppTest.TestAssistantFinalizedAfterTurn;
var
  Y, X, W: Integer;
  SawBacktick, SawText: Boolean;
  Row: UnicodeString;
begin
  Build;
  FFake.AddResponse([TextDelta('see `code`'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));
  { The turn ended, so the assistant block must have been finalized: the open
    tail is parsed, so the raw backticks are gone from the rendered screen (a
    finalised inline-code chip draws the text without the delimiters). }
  W := FSurface.Width;
  SawBacktick := False;
  SawText := False;
  for Y := 0 to FSurface.Height - 1 do
  begin
    Row := FSurface.RowText(Y, 0, W);
    if Pos('`', Row) > 0 then
      SawBacktick := True;
    if Pos('see', Row) > 0 then
      SawText := True;
    for X := 0 to W - 1 do
      if FSurface.CellAt(X, Y).Ch = '`' then
        SawBacktick := True;
  end;
  AssertTrue('the assistant text is drawn', SawText);
  AssertFalse('the last block was finalized (no raw backticks)',
    SawBacktick);
end;

procedure THarnessAppTest.TestReasoningSettlesIntoAThoughtBlock;
var
  I: Integer;
  SawThought: Boolean;
begin
  Build;
  FFake.AddChunk(ReasoningDelta('let me think'));
  FFake.AddChunk(TextDelta('answer'));
  FFake.AddChunk(FinishFrame('stop'));
  FFake.AddChunk(DoneFrame);
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));

  { While it streamed it read as "Thinking..."; once persisted it is a
    "Thought" block. }
  SawThought := False;
  for I := 0 to BlockCount - 1 do
    if (BlockKind(I) = ckThought) and (BlockText(I) = 'let me think') and
      (Pos('Thought', BlockLabel(I)) = 1) then
      SawThought := True;
  AssertTrue('reasoning settled into a Thought block', SawThought);
end;

procedure THarnessAppTest.TestToolLineAppears;
var
  I: Integer;
  ToolSeen: Boolean;
begin
  Build;
  FFake.AddResponse([TextDelta('let me check '),
    ToolNameFrame(0, 'c1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"checking"}'), FinishFrame('tool_calls'),
    DoneFrame]);
  FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('time?');
  AssertTrue('turn finished', Pump(300));

  AssertTrue('assistant text followed', FindText(ckAssistant, 'done'));
  ToolSeen := False;
  for I := 0 to BlockCount - 1 do
    if (BlockKind(I) = ckTool) and (BlockLabel(I) = 'checking') and
      (BlockText(I) <> '') then
      ToolSeen := True;
  AssertTrue('reason is the title, the result is the body', ToolSeen);
  AssertFalse('the raw call is not shown',
    FindText(ckTool, 'get_system_time'));
  AssertFalse('no [ok] prefix', FindText(ckTool, '[ok]'));
  { The text that accompanied the call stays before it; the answer that follows
    the tools is its own block, after them. }
  AssertEquals('four blocks', 4, BlockCount);
  AssertTrue('user first', BlockKind(0) = ckUser);
  AssertTrue('lead-in second', BlockKind(1) = ckAssistant);
  AssertTrue('tool third', BlockKind(2) = ckTool);
  AssertTrue('answer last', BlockKind(3) = ckAssistant);
  AssertEquals('answer text', 'done', BlockText(3));
  AssertEquals('lead-in text', 'let me check ', BlockText(1));
end;

procedure THarnessAppTest.TestEmptyToolResultShowsPlaceholder;
var
  E: TTurnEvent;
begin
  Build;
  { A tool that produced nothing still ran; the block shows a marker. }
  E := Default(TTurnEvent);
  E.Kind := teToolResult;
  E.ToolName := 'file_glob';
  E.Text := '';
  E.ToolOk := True;
  FSession.Queue.Push(E);
  FApp.Step;
  AssertTrue('placeholder shown', FindText(ckTool, '(no output)'));
end;

procedure THarnessAppTest.TestStreamedToolOutputCoalescesOneAppendPerFrame;
var
  Call, Chunk: TTurnEvent;
begin
  Build;
  Call := Default(TTurnEvent);
  Call.Kind := teToolCall;
  Call.ToolId := 'c';
  Call.ToolName := 'run_command';
  Call.ToolReason := 'build';
  FSession.Queue.Push(Call);
  FApp.Step;
  AssertEquals('the tool block starts empty', '', BlockText(BlockCount - 1));
  { Three chunks queued before a single Step: buffered, not appended per chunk. }
  Chunk := Default(TTurnEvent);
  Chunk.Kind := teToolOutput;
  Chunk.ToolId := 'c';
  Chunk.ToolName := 'run_command';
  Chunk.Text := 'x';
  FSession.Queue.Push(Chunk);
  FSession.Queue.Push(Chunk);
  FSession.Queue.Push(Chunk);
  AssertEquals('chunks are buffered until the frame', '',
    BlockText(BlockCount - 1));
  { One frame appends the coalesced burst once. }
  FApp.Step;
  AssertEquals('the coalesced burst landed in one append', 'xxx',
    BlockText(BlockCount - 1));
end;

procedure THarnessAppTest.TestLongToolOutputIsNotTrimmedEveryFrame;
var
  Call, Chunk: TTurnEvent;
  I, BodyLen: Integer;
  Big, Marker: string;
begin
  Build;
  Call := Default(TTurnEvent);
  Call.Kind := teToolCall;
  Call.ToolId := 'c';
  Call.ToolName := 'run_command';
  Call.ToolReason := 'build';
  FSession.Queue.Push(Call);
  FApp.Step;

  { Push past the 64 KB cap so the trim fires once. }
  Big := StringOfChar('x', 70000);
  Chunk := Default(TTurnEvent);
  Chunk.Kind := teToolOutput;
  Chunk.ToolId := 'c';
  Chunk.ToolName := 'run_command';
  Chunk.Text := Big;
  FSession.Queue.Push(Chunk);
  FApp.Step;
  BodyLen := Length(BlockText(BlockCount - 1));
  AssertTrue('the block is capped', BodyLen <= 66000);
  AssertTrue('a trim marker names the loss',
    Pos('trimmed', BlockText(BlockCount - 1)) > 0);

  { The cap is intact, but the trim must not REPEAT on the next frames. After
    trimming to the floor there is headroom, so a few small frames must not
    re-parse the body at all. That repetition -- not the cap -- was the cost:
    SetText re-parses the whole body, at the 10 ms tick.

    The observable is the leading trim marker, not a layout counter: LayoutBuilds
    increments on every Arrange, so it cannot distinguish a re-parse. The marker's
    "N earlier chars trimmed" number changes only when the trim fires again. }
  Marker := Copy(BlockText(BlockCount - 1), 1, 60);
  Chunk.Text := StringOfChar('y', 500);
  for I := 1 to 3 do
  begin
    FSession.Queue.Push(Chunk);
    FApp.Step;
  end;
  AssertEquals('the trim did not re-fire on frames under the cap',
    Marker, Copy(BlockText(BlockCount - 1), 1, 60));
  AssertTrue('the block stays capped', Length(BlockText(BlockCount - 1)) <= 66000);
end;

procedure THarnessAppTest.TestConcurrentToolOutputRoutesPerCall;
var
  CallA, CallB, Chunk: TTurnEvent;
  Idx: Integer;
begin
  { Two calls in one batch (both announced up front, as the parallel loop does),
    then interleaved output. Each call's output must land in ITS block. }
  Build;
  CallA := Default(TTurnEvent);
  CallA.Kind := teToolCall;
  CallA.ToolId := 'callA';
  CallA.ToolName := 'file_read';
  CallA.ToolReason := 'read a';
  CallB := Default(TTurnEvent);
  CallB.Kind := teToolCall;
  CallB.ToolId := 'callB';
  CallB.ToolName := 'file_read';
  CallB.ToolReason := 'read b';
  FSession.Queue.Push(CallA);
  FSession.Queue.Push(CallB);
  FApp.Step;

  { Interleaved chunks: A, B, A, B. }
  Chunk := Default(TTurnEvent);
  Chunk.Kind := teToolOutput;
  Chunk.ToolName := 'file_read';
  Chunk.ToolId := 'callA';
  Chunk.Text := 'a1';
  FSession.Queue.Push(Chunk);
  Chunk.ToolId := 'callB';
  Chunk.Text := 'b1';
  FSession.Queue.Push(Chunk);
  Chunk.ToolId := 'callA';
  Chunk.Text := 'a2';
  FSession.Queue.Push(Chunk);
  Chunk.ToolId := 'callB';
  Chunk.Text := 'b2';
  FSession.Queue.Push(Chunk);
  FApp.Step;

  { Each block holds only its own call's chunks. }
  for Idx := 0 to BlockCount - 1 do
    if BlockLabel(Idx) = 'read a' then
      AssertEquals('block A got only A chunks', 'a1a2', BlockText(Idx))
    else if BlockLabel(Idx) = 'read b' then
      AssertEquals('block B got only B chunks', 'b1b2', BlockText(Idx));
  AssertTrue('A text present', FindText(ckTool, 'a1a2'));
  AssertTrue('B text present', FindText(ckTool, 'b1b2'));
end;

procedure THarnessAppTest.TestLiveToolBlockIsCapped;
var
  Call, Chunk: TTurnEvent;
  I: Integer;
  Body: string;
begin
  Build;
  Call := Default(TTurnEvent);
  Call.Kind := teToolCall;
  Call.ToolId := 'c';
  Call.ToolName := 'run_command';
  Call.ToolReason := 'noisy';
  FSession.Queue.Push(Call);
  { 200 KB of output in one frame: the live block keeps only its tail. }
  Chunk := Default(TTurnEvent);
  Chunk.Kind := teToolOutput;
  Chunk.ToolId := 'c';
  Chunk.ToolName := 'run_command';
  Chunk.Text := StringOfChar('a', 200000);
  FSession.Queue.Push(Chunk);
  FApp.Step;
  Body := BlockText(BlockCount - 1);
  AssertTrue('the block was capped', Length(Body) <= 66000);
  AssertTrue('a trim marker names the loss', Pos('trimmed', Body) > 0);
end;

procedure THarnessAppTest.TestDrainStopsAtTheBudget;
var
  Err: TTurnEvent;
  I: Integer;
begin
  Build;
  { Queue more errors than one frame's drain budget (256). }
  for I := 1 to 300 do
  begin
    Err := Default(TTurnEvent);
    Err.Kind := teError;
    Err.ErrorCode := leNetwork;
    Err.Text := 'boom ' + IntToStr(I);
    FSession.Queue.Push(Err);
  end;
  { One Step drains at most 256, so some remain queued. }
  FApp.Step;
  AssertFalse('the drain stopped at the budget, not the queue end',
    FSession.Queue.IsEmpty);
end;

procedure THarnessAppTest.TestAppStreamsToolOutput;
var
  Call, Chunk, Res: TTurnEvent;
begin
  Build;
  { A tool call opens the block; chunks stream into it and it reads as live. }
  Call := Default(TTurnEvent);
  Call.Kind := teToolCall;
  Call.ToolId := 'call_1';
  Call.ToolName := 'run_command';
  Call.ToolReason := 'building';
  FSession.Queue.Push(Call);

  Chunk := Default(TTurnEvent);
  Chunk.Kind := teToolOutput;
  Chunk.ToolId := 'call_1';
  Chunk.ToolName := 'run_command';
  Chunk.Text := 'compiling ';
  FSession.Queue.Push(Chunk);
  Chunk.Text := 'done';
  FSession.Queue.Push(Chunk);
  FApp.Step;

  AssertTrue('streamed body', FindText(ckTool, 'compiling done'));
  AssertTrue('live while running', BlockLive(BlockCount - 1));
  AssertEquals('reason is the title', 'building', BlockLabel(BlockCount - 1));

  { The authoritative result replaces the streamed body on completion. }
  Res := Default(TTurnEvent);
  Res.Kind := teToolResult;
  Res.ToolId := 'call_1';
  Res.ToolName := 'run_command';
  Res.Text := 'compiling done (exit 0)';
  Res.ToolOk := True;
  FSession.Queue.Push(Res);
  FApp.Step;

  AssertFalse('settled', BlockLive(BlockCount - 1));
  AssertEquals('result replaced the stream', 'compiling done (exit 0)',
    BlockText(BlockCount - 1));
end;

procedure THarnessAppTest.TestResumeShowsTheResult;
var
  Call, Chunk, Res: TTurnEvent;
begin
  Build;
  { Stream a tool to completion, then check the settled body is exactly the
    authoritative result: a resumed view renders the same ledger content, so
    the two must match. }
  Call := Default(TTurnEvent);
  Call.Kind := teToolCall;
  Call.ToolId := 'call_1';
  Call.ToolName := 'run_command';
  Call.ToolReason := 'building';
  FSession.Queue.Push(Call);

  Chunk := Default(TTurnEvent);
  Chunk.Kind := teToolOutput;
  Chunk.ToolId := 'call_1';
  Chunk.ToolName := 'run_command';
  Chunk.Text := 'partial';
  FSession.Queue.Push(Chunk);

  Res := Default(TTurnEvent);
  Res.Kind := teToolResult;
  Res.ToolId := 'call_1';
  Res.ToolName := 'run_command';
  Res.Text := 'the result';
  Res.ToolOk := True;
  FSession.Queue.Push(Res);
  FApp.Step;

  AssertEquals('live final body is the result', 'the result',
    BlockText(BlockCount - 1));
  AssertFalse('not live after settle', BlockLive(BlockCount - 1));
end;

procedure THarnessAppTest.TestErrorLineAppears;
var
  I: Integer;
  ErrSeen: Boolean;
begin
  Build;
  FFake.FailNetwork := True;
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));

  ErrSeen := False;
  for I := 0 to BlockCount - 1 do
    if (BlockKind(I) = ckError) and (BlockText(I) <> '') then
      ErrSeen := True;
  AssertTrue('an error block with text exists', ErrSeen);
  AssertTrue('prompt re-enabled', FApp.PromptActive);
end;

procedure THarnessAppTest.TestApprovalModalResolvesGateAsk;
var
  Thread: TGateAskThread;
  Waited: Integer;
begin
  Build;
  Thread := TGateAskThread.Create(FSession.Gate, MakeAsk);
  Thread.Start;

  Waited := 0;
  while (not FApp.ModalActive) and (Waited < 500) do
  begin
    FApp.Step;
    Sleep(2);
    Inc(Waited);
  end;
  AssertTrue('approval modal shown', FApp.ModalActive);

  FInput.Push(Key(kkDown));
  FInput.Push(Key(kkEnter));
  Waited := 0;
  while (not Thread.Finished) and (Waited < 500) do
  begin
    FApp.Step;
    Sleep(2);
    Inc(Waited);
  end;
  Thread.WaitFor;
  AssertTrue('thread finished', Thread.Finished);
  AssertTrue('allowed', Thread.Choice.Allowed);
  AssertEquals('chosen option', 'opt2', Thread.Choice.OptionKey);
  Thread.Free;
end;

procedure THarnessAppTest.TestAsksDoNotStack;
begin
  Build;
  FSession.Queue.Push(ApprovalEvent(1, MakeAsk));
  FSession.Queue.Push(ApprovalEvent(2, MakeAsk));

  { First drain shows one modal and queues the second. }
  FApp.Step;
  AssertTrue('first modal shown', FApp.ModalActive);

  { Answering the first must surface the second, not pop it. }
  FInput.Push(Key(kkEnter));
  FApp.Step;   { consumes Enter -> chooses the first }
  FApp.Step;   { pops the first and shows the second }
  AssertTrue('second modal shown', FApp.ModalActive);

  FInput.Push(Key(kkEnter));
  FApp.Step;   { chooses the second }
  FApp.Step;   { pops it }
  AssertFalse('no modal left', FApp.ModalActive);
end;

procedure THarnessAppTest.TestOneFramePerStep;
var
  Before: Integer;
begin
  Build;
  Before := FSurface.FlushCount;
  FSession.Queue.Push(AssistantEvent('x'));
  FApp.Step;
  AssertEquals('one flush per step', 1, FSurface.FlushCount - Before);
end;

procedure THarnessAppTest.TestRenderHistoryRestoresToolBlocks;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  Cfg: THarnessSessionConfig;
  WorkspaceId: Integer;
  Sid: string;
  TurnId: Int64;
  Rec: TMessageRecord;
  Err: string;
  SawReasoning, SawTool, SawResult, SawAssistant, SawError: Boolean;
  I: Integer;

  procedure Add(ARole: TMessageRole; const AContent, AToolCallId,
    AToolName, AToolArgs, AToolReason: string; AToolOk: Boolean);
  begin
    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.TurnId := TurnId;
    Rec.Role := ARole;
    Rec.Content := AContent;
    Rec.ToolCallId := AToolCallId;
    Rec.ToolName := AToolName;
    Rec.ToolArguments := AToolArgs;
    Rec.ToolReason := AToolReason;
    Rec.ToolOk := AToolOk;
    Store.AppendMessage(Rec, StoreErr);
  end;

begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';

  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateSession(WorkspaceId, Sid, StoreErr);
    Store.BeginTurn(Sid, TurnId, StoreErr);
    Add(mrUser, 'do it', '', '', '', '', False);
    Add(mrReasoning, 'why not', '', '', '', '', False);
    Add(mrToolCall, '', 'c1', 'run_command', '{"command":"date"}',
      'check the date', False);
    Add(mrTool, 'noon', 'c1', 'run_command', '', '', True);
    Add(mrAssistant, 'done', '', '', '', '', False);
    Add(mrError, 'boom', '', '', 'DNS failed', '', False);
  finally
    Store.Free;
  end;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, LocalDriver(FSession));
  FApp.Step;

  SawReasoning := False;
  SawTool := False;
  SawResult := False;
  SawAssistant := False;
  SawError := False;
  for I := 0 to BlockCount - 1 do
  begin
    if (BlockKind(I) = ckThought) and (Pos('why not', BlockText(I)) > 0) then
      SawReasoning := True;
    if (BlockKind(I) = ckTool) and (BlockLabel(I) = 'check the date') then
      SawTool := True;
    if (BlockKind(I) = ckTool) and (Pos('noon', BlockText(I)) > 0) then
      SawResult := True;
    if (BlockKind(I) = ckAssistant) and (Pos('done', BlockText(I)) > 0) then
      SawAssistant := True;
    if (BlockKind(I) = ckError) and (Pos('boom', BlockText(I)) > 0) then
      SawError := True;
  end;
  AssertTrue('user bubble restored', FindText(ckUser, 'do it'));
  AssertTrue('reasoning block restored', SawReasoning);
  AssertTrue('tool block titled by reason', SawTool);
  AssertTrue('tool result paired into the block', SawResult);
  AssertFalse('the raw call is not restored', FindText(ckTool, 'run_command'));
  AssertTrue('assistant block restored', SawAssistant);
  AssertTrue('error block restored', SawError);
  { The stored detail (in tool_arguments) is shown, so a resumed session reads
    like the live one. }
  AssertTrue('the error detail is restored', FindText(ckError, 'DNS failed'));
end;

procedure THarnessAppTest.TestResumeStripsAStoredMalformedBlock;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  Cfg: THarnessSessionConfig;
  WorkspaceId: Integer;
  Sid: string;
  TurnId: Int64;
  Rec: TMessageRecord;
  Err: string;
  Y: Integer;
  SawTitle: Boolean;
begin
  { A reply stored BEFORE the closing-fence fix - the operator's case: a blank
    line right after the opening `---`, no closing fence. On resume it must
    still be stripped and drawn as a title header, not the raw block. }
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateSession(WorkspaceId, Sid, StoreErr);
    Store.BeginTurn(Sid, TurnId, StoreErr);
    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.TurnId := TurnId;
    Rec.Role := mrAssistant;
    Rec.Content := '---' + #10 + #10 + 'title: This is the Tigle' + #10 +
      'keywords: [test]' + #10 + #10 + 'The rest of the response is here';
    Store.AppendMessage(Rec, StoreErr);
  finally
    Store.Free;
  end;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View,
    LocalDriver(FSession));
  FApp.Step;

  { The block is not drawn as body; the title is; the body is present. }
  AssertFalse('the block is not in the body', FindText(ckAssistant, 'title:'));
  AssertTrue('the body is present',
    FindText(ckAssistant, 'The rest of the response is here'));
  FApp.Step;   // render
  SawTitle := False;
  for Y := 0 to FSurface.Height - 1 do
    if Pos('This is the Tigle', FSurface.RowText(Y, 0, FSurface.Width)) > 0 then
      SawTitle := True;
  AssertTrue('the title is drawn', SawTitle);
end;

procedure THarnessAppTest.TestTranscriptIsBoundedToTheTail;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  Err, Sid: string;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  TurnId: Int64;
  Rec: TMessageRecord;
  Cfg: THarnessSessionConfig;
  I: Integer;
begin
  { Seed more messages than the startup tail, then resume: the transcript is the
    bounded tail, not the whole session. }
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateSession(WorkspaceId, Sid, StoreErr);
    Store.BeginTurn(Sid, TurnId, StoreErr);
    { 500 user messages, far more than StartupTailCount (200). }
    for I := 1 to 500 do
    begin
      Rec := Default(TMessageRecord);
      Rec.SessionId := Sid;
      Rec.TurnId := TurnId;
      Rec.Role := mrUser;
      Rec.Content := 'm' + IntToStr(I);
      Store.AppendMessage(Rec, StoreErr);
    end;
  finally
    Store.Free;
  end;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, LocalDriver(FSession));
  FApp.Step;
  { The whole session is 500 messages; the first frame renders the tail only. }
  AssertTrue('bounded to the tail', BlockCount <= 200);
  AssertTrue('the newest is present', FindText(ckUser, 'm500'));
  AssertFalse('an early message is not loaded', FindText(ckUser, 'm1'));
end;

procedure THarnessAppTest.TestFullPagingIsContinuous;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  Err, Sid: string;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  TurnId: Int64;
  Rec: TMessageRecord;
  Cfg: THarnessSessionConfig;
  I, Guard, Prev, Idx, Seen: Integer;
  Text, Marker: string;
begin
  { Seed a session, resume it, then page to the head. The full window must be
    continuous: every message exactly once, in order (no gap or duplication at a
    page seam). }
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateSession(WorkspaceId, Sid, StoreErr);
    Store.BeginTurn(Sid, TurnId, StoreErr);
    { 450 messages: 3 pages of 200 (the tail + two more), so the seams matter. }
    for I := 1 to 450 do
    begin
      Rec := Default(TMessageRecord);
      Rec.SessionId := Sid;
      Rec.TurnId := TurnId;
      Rec.Role := mrUser;
      Rec.Content := 'm' + IntToStr(I);
      Store.AppendMessage(Rec, StoreErr);
    end;
  finally
    Store.Free;
  end;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, LocalDriver(FSession));
  FApp.Step;
  { Page to the head: drive the stream's need-older handler, stepping so the
    layout applies (and the anchor clears) between pages, until the window stops
    growing (the head guard fires). }
  Guard := 0;
  repeat
    Inc(Guard);
    Prev := FApp.Panel.Stream.ContentHeight;
    FApp.Panel.Stream.OnNeedOlder(FApp.Panel.Stream);
    FApp.Step;   // layout: apply the anchor and settle the new height
  until (Guard >= 10) or (FApp.Panel.Stream.ContentHeight <= Prev);
  { Every seeded message is present exactly once, in ascending order. }
  Text := FApp.ConversationText;
  Prev := 0;
  for I := 1 to 450 do
  begin
    Marker := 'm' + IntToStr(I) + #10;
    Idx := Pos(Marker, Text);
    AssertTrue('message m' + IntToStr(I) + ' present', Idx > 0);
    AssertTrue('message m' + IntToStr(I) + ' in order', Idx > Prev);
    Prev := Idx;
  end;
  { No duplication: 'm1' appears once as a whole block (its text plus the
    newline). A duplicate would place it again after m450. }
  Seen := 0;
  I := 0;
  repeat
    Idx := Pos('m1' + #10, Copy(Text, I + 1, MaxInt));
    if Idx > 0 then
    begin
      Inc(Seen);
      I := I + Idx;
    end;
  until Idx = 0;
  AssertEquals('the first message appears once', 1, Seen);
end;

procedure THarnessAppTest.TestHeaderShowsSessionIdAndContext;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":1200,"completion_tokens":310,' +
      '"total_tokens":1510,"prompt_tokens_details":{"cached_tokens":1100}}'),
    FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));

  { The id prefix is the left border title; the context the right. }
  AssertEquals('session id on the left', ShortSessionId(FSession.View.SessionId),
    FApp.Panel.HeaderLeft);
  AssertTrue('context tokens in the header',
    Pos('1k', FApp.Panel.HeaderRight) > 0);
  { The pinned limit is 120k, so the context bar and percentage are shown. }
  AssertTrue('context percentage in the header',
    Pos('1%', FApp.Panel.HeaderRight) > 0);
  { The consumption is on the status bar, not the header. }
  AssertFalse('no consumption in the header',
    Pos('cached', FApp.Panel.HeaderRight) > 0);
end;

procedure THarnessAppTest.TestHeaderShowsTheSessionTitle;
var
  Err: TStoreError;
begin
  BuildWithStore;
  { No title yet: the id prefix names the header. }
  AssertEquals('id prefix without a title',
    ShortSessionId(FSession.View.SessionId), FApp.Panel.HeaderLeft);

  { An extracted title is shown beside the identifier, which falls back to the
    short session id when there is no label. Set the title directly, then trigger
    a header refresh the way a completed turn does (UpdateStats -> UpdateHeader).
    A no-op status render is not enough, so submit a turn. }
  AssertTrue('set title', FSession.View.Store.SetSessionTitle(
    FSession.View.SessionId, 'Fix the drain', Err));
  FFake.AddResponse([TextDelta('hi'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  AssertEquals('the title is shown beside the id',
    ShortSessionId(FSession.View.SessionId) + ' - Fix the drain',
    FApp.Panel.HeaderLeft);
end;

procedure THarnessAppTest.TestHeaderTruncatesALongTitle;
var
  Err: TStoreError;
  Long: string;
  I: Integer;
begin
  BuildWithStore;
  Long := '';
  for I := 1 to 80 do
    Long := Long + 'x';
  AssertTrue('set a long title', FSession.View.Store.SetSessionTitle(
    FSession.View.SessionId, Long, Err));
  FFake.AddResponse([TextDelta('hi'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  { The header left is bounded, so the context usage stays on the border. The
    surface is 60 wide, so the title is cut well below its 80 characters. }
  AssertTrue('the beginning is kept', Pos('xx', FApp.Panel.HeaderLeft) > 0);
  AssertTrue('the title is truncated', Length(FApp.Panel.HeaderLeft) < 80);
  AssertTrue('the context is still shown', FApp.Panel.HeaderRight <> '');
end;

procedure THarnessAppTest.TestHeaderRendersANonAsciiTitle;
var
  Err: TStoreError;
  Title: string;
begin
  { A non-ASCII title (a UTF-8 em dash) must survive the store and render as the
    real glyph in the header, not '?'. The title is kept SHORT on purpose: the
    header now prefixes the id under the `<label> - <title>` format, so a long
    title gets truncated and the glyph we are testing for would be cut away. }
  BuildWithStore;
  Title := 'drain ' + #$E2#$80#$94 + ' p2';
  AssertTrue('set title', FSession.View.Store.SetSessionTitle(
    FSession.View.SessionId, Title, Err));
  FFake.AddResponse([TextDelta('hi'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  { The em dash must survive; the id prefixes it under the new format. Assert
    against Title itself - naming the string twice is how the previous version
    silently drifted out of sync with the value it set. }
  AssertTrue('the title is in the header: ' + FApp.Panel.HeaderLeft,
    Pos(Title, FApp.Panel.HeaderLeft) > 0);
end;

procedure THarnessAppTest.TestNewCommandMintsAndSwitchesSession;
var
  Before: string;
  Rows: TSessionRowArray;
  Err: TStoreError;
begin
  BuildWithStore;
  FApp.OnSwitchSession := SwitchTo;
  FSwitchResult := True;
  Before := FApp.SessionId;
  FApp.Panel.Palette.OnRun('new');
  FApp.Step;
  { A NEW id, not the same one: /new mints rather than reopening. }
  AssertTrue('a session id exists', FApp.SessionId <> '');
  AssertTrue('it is a different session', FApp.SessionId <> Before);
  { And it is real: the store lists it in this workspace. }
  Rows := nil;
  AssertTrue('it was persisted',
    FSession.View.Store.ListSessionRows(FSession.View.WorkspaceId, False, Rows,
      Err));
  AssertTrue('the store has rows', Length(Rows) >= 1);
end;

procedure THarnessAppTest.TestNewIsAbsentWhenUnattached;
var
  I: Integer;
  Found: Boolean;
begin
  { /new mints a session in the CURRENT workspace, so an unattached TUI has
    nothing to mint into - offering it there invites a command that can only
    report "no store".

    BuildIdle, NOT BuildWithStore: the latter passes a driver, so it is fully
    ATTACHED. The old version used it and passed anyway, because the palette was
    populated inside BuildTree - before the constructor set FConnState - so every
    conditional command was frozen at csIdle. The test asserted a false premise
    and the bug hid it. SyncCommands exposed it. }
  BuildIdle;
  FApp.Panel.Palette.Filter('/new');
  Found := False;
  for I := 0 to FApp.Panel.Palette.VisibleCount - 1 do
    if FApp.Panel.Palette.VisibleAt(I).Name = 'new' then
      Found := True;
  AssertFalse('/new is not offered when unattached', Found);
end;

procedure THarnessAppTest.TestNewIsOfferedWhenAttached;
var
  I: Integer;
  Found: Boolean;
begin
  { The other half of the contract, and the half that had no test: the previous
    suite asserted only that /new was ABSENT when unattached, so a palette that
    never offered /new at all would have passed it. }
  BuildWithStore;
  FApp.Panel.Palette.Filter('/new');
  Found := False;
  for I := 0 to FApp.Panel.Palette.VisibleCount - 1 do
    if FApp.Panel.Palette.VisibleAt(I).Name = 'new' then
      Found := True;
  AssertTrue('/new is offered once there is a workspace', Found);
end;

procedure THarnessAppTest.TestCheckpointIsAbsentWhenUnattached;
var
  I: Integer;
  Name: string;
  Seen: Boolean;
begin
  { /checkpoint drafts through the runtime, so an unattached TUI has nothing to
    checkpoint and RunCommand's own guard refuses it. Offering it there is an
    invitation to a command that can only answer "no session yet". }
  BuildIdle;
  FApp.Panel.Palette.Filter('/');
  Seen := False;
  for I := 0 to FApp.Panel.Palette.VisibleCount - 1 do
  begin
    Name := FApp.Panel.Palette.VisibleAt(I).Name;
    if Name = 'checkpoint' then
      Seen := True;
  end;
  AssertFalse('/checkpoint is not offered before a session exists', Seen);
  { /sessions only reads the store, so it is genuinely available this early -
    which is why the list is not simply empty. }
  AssertTrue('the list is not empty', FApp.Panel.Palette.VisibleCount > 0);
end;

procedure THarnessAppTest.TestCheckpointIsOfferedWhenAttached;
var
  I: Integer;
  Found: Boolean;
begin
  BuildWithStore;
  FApp.Panel.Palette.Filter('/checkpoint');
  Found := False;
  for I := 0 to FApp.Panel.Palette.VisibleCount - 1 do
    if FApp.Panel.Palette.VisibleAt(I).Name = 'checkpoint' then
      Found := True;
  AssertTrue('/checkpoint is offered once a runtime is attached', Found);
end;

procedure THarnessAppTest.TestTurnCommandsAppearWhenActionable;
var
  I: Integer;
  Turns: TTurnRecordArray;
  TurnId: Int64;
  StoreErr: TStoreError;
  Rec: TMessageRecord;
  SawUndo, SawRedo: Boolean;
begin
  { The POSITIVE half of "only actionable entries". Every existing test asserted
    ABSENCE on a fresh session, so a palette that never offered /undo or /redo at
    all would have satisfied the whole suite. }

  { One completed turn makes /undo actionable. }
  BuildWithStore;
  AssertTrue('begin turn',
    FSession.View.Store.BeginTurn(FSession.View.SessionId, TurnId, StoreErr));
  Rec := Default(TMessageRecord);
  Rec.SessionId := FSession.View.SessionId;
  Rec.TurnId := TurnId;
  Rec.Role := mrUser;
  Rec.Content := 'do the thing';
  AssertTrue('message', FSession.View.Store.AppendMessage(Rec, StoreErr));
  AssertTrue('finish',
    FSession.View.Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '',
      StoreErr));

  { Drive a real turn end: FinishTurn rebuilds the palette, which is exactly the
    choke point that was missing (the list used to be rebuilt only on teUndone). }
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(400));

  FApp.Panel.Palette.Filter('/');
  SawUndo := False;
  SawRedo := False;
  for I := 0 to FApp.Panel.Palette.VisibleCount - 1 do
  begin
    if FApp.Panel.Palette.VisibleAt(I).Name = 'undo' then
      SawUndo := True;
    if FApp.Panel.Palette.VisibleAt(I).Name = 'redo' then
      SawRedo := True;
  end;
  AssertTrue('/undo is offered once a turn exists to undo', SawUndo);
  { Nothing has been undone yet, so there is nothing to redo. }
  AssertFalse('/redo waits for an undo', SawRedo);

  { Undo one, and the redo window opens while undo may close. }
  FApp.Panel.Palette.OnRun('undo');
  AssertTrue('the history dialog opened', FApp.ModalActive);
  FInput.Push(Key(kkEnter));
  FApp.Step;
  FApp.Step;

  Turns := FSession.View.Turns;
  { TWO turns, not one: the seeded turn plus the live one just run. Assert that
    exactly one is undone rather than reading Turns[0] - the array's order is the
    store's, not the order the test happened to create things in, and indexing it
    asserted an order this test never established. }
  AssertEquals('both turns remain in the ledger', 2, Length(Turns));
  SawUndo := False;
  for I := 0 to High(Turns) do
    if Turns[I].Status = tsUndone then
      SawUndo := True;
  AssertTrue('one turn is undone', SawUndo);
  FApp.Panel.Palette.Filter('/');
  SawRedo := False;
  for I := 0 to FApp.Panel.Palette.VisibleCount - 1 do
    if FApp.Panel.Palette.VisibleAt(I).Name = 'redo' then
      SawRedo := True;
  AssertTrue('/redo is offered once something is undoable-again', SawRedo);
end;

procedure THarnessAppTest.TestToolWaitCaptionVariesAcrossCalls;
var
  I, Distinct: Integer;
  Seen: array of string;
  Caption: string;

  function IndexOf(const S: string): Integer;
  var J: Integer;
  begin
    for J := 0 to High(Seen) do
      if Seen[J] = S then
        Exit(J);
    Result := -1;
  end;

begin
  { The caption is picked from the CALL ID, so a turn with several tool calls
    does not repeat one phrase. A single fixed string would fail this. }
  SetLength(Seen, 0);
  for I := 1 to 8 do
  begin
    Caption := ToolWaitCaption('call-' + IntToStr(I), 'Find related files');
    if IndexOf(Caption) < 0 then
    begin
      SetLength(Seen, Length(Seen) + 1);
      Seen[High(Seen)] := Caption;
    end;
  end;
  Distinct := Length(Seen);
  AssertTrue('the caption varies across calls, not just once: ' +
    IntToStr(Distinct) + ' distinct', Distinct > 1);
end;

procedure THarnessAppTest.TestToolWaitCaptionIsStableForOneCall;
var
  First, Again: string;
  I: Integer;
begin
  { ONE call, one caption. A tool run states a FACT, so it must not reword itself
    while the tool is still running - the same rule that keeps the reasoning
    rotation off psTool. Deriving the lead from a counter or the clock would fail
    this; deriving it from the call id cannot. }
  First := ToolWaitCaption('call-xyz', 'Run the tests');
  for I := 1 to 5 do
  begin
    Again := ToolWaitCaption('call-xyz', 'Run the tests');
    AssertEquals('the same call always reads the same', First, Again);
  end;
end;

procedure THarnessAppTest.TestToolWaitCaptionFallsBackToTheToolName;
var
  WithReason, WithName: string;
begin
  { No reason on the wire: the caption falls back to the tool NAME rather than
    rendering a lead-in and nothing after it. LowerFirst lowercases only the
    first character, so a camel-case tool name keeps its shape. }
  WithReason := ToolWaitCaption('c1', 'Find related files');
  AssertTrue('the reason is lowercased as the object',
    Pos('find related files', WithReason) > 0);
  WithName := ToolWaitCaption('c1', 'run_command');
  AssertTrue('an already-lowercase name passes through',
    Pos('run_command', WithName) > 0);
  { A proper noun keeps its case after the first character. }
  AssertTrue('only the FIRST character is lowered',
    Pos('gitHub', ToolWaitCaption('c1', 'GitHub')) > 0);
  { Never something for nothing: the caption always carries its object. }
  AssertTrue('the caption is not just a lead-in', Length(WithReason) > 10);
end;

procedure THarnessAppTest.TestToolWaitCaptionReachesTheStatus;
var
  Call: TTurnEvent;
  Expected: string;
begin
  { The end-to-end version of the assertion the suite was missing. The old test
    typed 'Waiting to find related files' straight into the panel and checked the
    panel echoed it, which passes no matter what the app emits. Here the event is
    pushed the way the worker pushes it and the APP's own status is read. }
  Build;
  Call := Default(TTurnEvent);
  Call.Kind := teToolCall;
  Call.ToolId := 'call-42';
  Call.ToolName := 'file_grep';
  Call.ToolReason := 'Find related files';
  FSession.Queue.Push(Call);
  FApp.Step;

  Expected := ToolWaitCaption('call-42', 'Find related files');
  AssertEquals('the status carries the composed caption', Expected,
    FApp.StateText);
  AssertTrue('and it names the decision, not the tool',
    Pos('find related files', FApp.StateText) > 0);
  AssertTrue('the tool name is not what the operator reads',
    Pos('file_grep', FApp.StateText) = 0);
end;

procedure THarnessAppTest.TestTwoCallsInATurnReadDifferently;
var
  CallA, CallB: TTurnEvent;
  CaptionA, CaptionB: string;
begin
  { The operator's actual complaint - "the list is bland" - stated as a property
    of the SCREEN rather than of the composer. Two tool calls carrying the same
    reason must not caption themselves identically, or a long turn reads as one
    phrase repeated. A single fixed prefix fails here. }
  Build;

  CallA := Default(TTurnEvent);
  CallA.Kind := teToolCall;
  CallA.ToolId := 'call-a';
  CallA.ToolName := 'file_grep';
  CallA.ToolReason := 'Find related files';
  FSession.Queue.Push(CallA);
  FApp.Step;
  CaptionA := FApp.StateText;

  CallB := Default(TTurnEvent);
  CallB.Kind := teToolCall;
  CallB.ToolId := 'call-b';
  CallB.ToolName := 'file_read';
  CallB.ToolReason := 'Find related files';
  FSession.Queue.Push(CallB);
  FApp.Step;
  CaptionB := FApp.StateText;

  AssertTrue('the first caption names the decision',
    Pos('find related files', CaptionA) > 0);
  AssertTrue('the second caption names the decision',
    Pos('find related files', CaptionB) > 0);
  { Not every pair can differ - six leads and any hash collide sometimes - but
    two calls in one turn landing on the same phrase all the time is the bland
    behaviour this replaced. Assert the vocabulary is genuinely in use. }
  AssertTrue('two calls do not read identically: "' + CaptionA + '" vs "' +
    CaptionB + '"', CaptionA <> CaptionB);
end;

procedure THarnessAppTest.TestActivityCaptionNamesTheFile;
begin
  { The concrete case the operator asked for: the caption names the file, not a
    generic "Waiting to read". }
  AssertEquals('a read names its path', 'Reading src/hildi.pas',
    ToolActivityCaption('file_read', '{"path":"src/hildi.pas","reason":"x"}',
      'Read the file', 'c1'));
  AssertEquals('an edit names its path', 'Editing src/tui/core.pas',
    ToolActivityCaption('file_edit', '{"path":"src/tui/core.pas"}', '', 'c2'));
  AssertEquals('a write names its path', 'Writing docs/NOTES.md',
    ToolActivityCaption('file_write', '{"path":"docs/NOTES.md"}', '', 'c3'));
  AssertEquals('a listing names its directory', 'Listing src',
    ToolActivityCaption('file_list', '{"path":"src"}', '', 'c4'));
  { No path on a listing is legal (it defaults to the workspace root), and it
    must still say something concrete - a bare "Listing" would be a dangling
    verb, and a generic phrase says nothing. }
  AssertEquals('a bare listing names the root', 'Listing the workspace',
    ToolActivityCaption('file_list', '{"reason":"see the tree"}', '', 'c5'));
end;

procedure THarnessAppTest.TestActivityCaptionNamesTheCommand;
begin
  { A shell command is the case where the reason is least informative: "run the
    tests" tells the operator nothing that `make check` does not. }
  AssertEquals('the command is quoted as written', 'Running make check',
    ToolActivityCaption('run_command', '{"command":"make check"}',
      'Run the tests', 'c1'));
  AssertEquals('a pipeline is clamped, not truncated mid-token',
    'Running git log --oneline -5',
    ToolActivityCaption('run_command',
      '{"command":"git log --oneline -5"}', '', 'c2'));
end;

procedure THarnessAppTest.TestActivityCaptionSearchesForAPattern;
begin
  AssertEquals('a grep names its pattern', 'Searching for TODO',
    ToolActivityCaption('file_grep', '{"pattern":"TODO"}', '', 'c1'));
  AssertEquals('a glob names its pattern', 'Finding files matching **/*.pas',
    ToolActivityCaption('file_glob', '{"pattern":"**/*.pas"}', '', 'c2'));
end;

procedure THarnessAppTest.TestActivityCaptionClampsALongSubject;
var
  Long, Caption: string;
begin
  { A long shell command would push the interaction hints off the row. The END is
    what identifies a path, so the tail is kept.

    Built from single-quoted arguments on purpose: an earlier version embedded raw
    double quotes, which made the arguments invalid JSON, so the clamp was never
    reached and the test passed for the wrong reason - it was exercising the
    fallback, not the clamp. }
  Long := 'git log --oneline --stat --follow --all --graph --decorate -- ' +
    'src/tui/widgets/TUIWidgetsChatPanel.pas';
  Caption := ToolActivityCaption('run_command', '{"command":"' + Long + '"}',
    '', 'c1');
  AssertTrue('the caption is bounded: ' + IntToStr(Length(Caption)),
    Length(Caption) <= 48 + Length('...') + Length('Running '));
  AssertTrue('the tail is kept, not the head: ' + Caption,
    Pos('TUIWidgetsChatPanel.pas', Caption) > 0);
  AssertTrue('it is a clamped subject, not the fallback',
    Pos('Running ', Caption) = 1);
end;

procedure THarnessAppTest.TestActivityCaptionSurvivesMalformedArguments;
var
  Caption: string;
begin
  { Model output is attacker-influenced and frequently truncated mid-call. A
    parse failure must still caption the run - the tool IS running - by falling
    back rather than raising. }
  Caption := ToolActivityCaption('file_read', '{"path":"src/hil',
    'Read the file', 'c1');
  AssertTrue('a truncated call still gets a caption', Caption <> '');
  { It falls through to the reason, because no path could be read. }
  AssertTrue('and falls back to the reason: ' + Caption,
    Pos('read the file', Caption) > 0);

  Caption := ToolActivityCaption('file_read', 'not json at all', '', 'c2');
  AssertTrue('garbage with no reason still gets a caption', Caption <> '');
  AssertTrue('naming the tool, since nothing else is known: ' + Caption,
    Pos('file_read', Caption) > 0);
end;

procedure THarnessAppTest.TestActivityCaptionPrefersTheSubjectOverTheReason;
var
  Caption: string;
begin
  { When the arguments name a concrete subject, the reason is redundant: the file
    IS the answer. This is the deliberate departure from "show the reason". }
  Caption := ToolActivityCaption('file_read',
    '{"path":"src/hildi.pas","reason":"Check the store path"}',
    'Check the store path', 'c1');
  AssertEquals('the subject wins over the reason', 'Reading src/hildi.pas',
    Caption);
  AssertFalse('the reason is not appended',
    Pos('store path', Caption) > 0);
end;

procedure THarnessAppTest.TestActivityCaptionDoesNotDoubleUpTheToolName;
var
  Caption: string;
begin
  { An unknown tool whose reason merely restates its name would read as
    "Waiting to some_mcp_tool", which is worse than the varied generic caption.
    Falls back to the tool name through ToolWaitCaption instead. }
  Caption := ToolActivityCaption('some_mcp_tool', '{}', 'some_mcp_tool', 'c1');
  AssertEquals('no doubled possessive-free echo',
    ToolWaitCaption('c1', 'some_mcp_tool'), Caption);
end;

procedure THarnessAppTest.TestActivityCaptionReachesTheStatus;
var
  Call: TTurnEvent;
begin
  { End to end: the event carries real arguments, and the APP's status names the
    file. The old caption tests all pushed an empty ToolArguments. }
  Build;
  Call := Default(TTurnEvent);
  Call.Kind := teToolCall;
  Call.ToolId := 'call-99';
  Call.ToolName := 'file_read';
  Call.ToolArguments := '{"path":"src/HildiHarnessApp.pas","reason":"inspect"}';
  Call.ToolReason := 'Read the file';
  FSession.Queue.Push(Call);
  FApp.Step;

  AssertEquals('the status names the file', 'Reading src/HildiHarnessApp.pas',
    FApp.StateText);
  AssertFalse('not the vague reason',
    Pos('Read the file', FApp.StateText) > 0);
end;

procedure THarnessAppTest.TestHeaderReadsNewSessionWithoutAnId;
var
  Pairs: array[0..1] of string;
begin
  { No label and no title: the border says "New Session". An empty border reads
    as a broken header rather than an idle one. }
  Pairs[0] := '';
  Pairs[1] := '';
  AssertEquals('the idle header', 'New Session',
    SessionDisplayName('', '', ''));
  { With an id but no label, the SHORT id names the session: SIX characters, not
    the old twelve. Wide enough to tell sessions apart, narrow enough to leave a
    title room in a list. }
  AssertEquals('short id is six chars', '6b30f8',
    SessionDisplayName('', '', '6b30f848217eca30501219f2543c9e33'));
  { <name> - <running title>, which is the whole format. }
  AssertEquals('name and title', '6b30f8 - Doing work',
    SessionDisplayName('', 'Doing work', '6b30f848217eca30501219f2543c9e33'));
  AssertEquals('label wins over id', 'agent-1 - Doing work',
    SessionDisplayName('agent-1', 'Doing work', '6b30f848217eca30501219f2543c9e33'));
  { No title yet: just the name, with no dangling separator. }
  AssertEquals('no title', 'agent-1',
    SessionDisplayName('agent-1', '', '6b30f848217eca30501219f2543c9e33'));
end;

procedure THarnessAppTest.TestRenamingTheCurrentSessionUpdatesTheHeader;
var
  I: Integer;
begin
  BuildWithStore;
  { Rename the current session through the modal's action path. Open the modal,
    then drive a rename: the app refreshes the header when the renamed session is
    the current one. }
  FApp.Panel.Palette.OnRun('sessions');
  FApp.Step;
  AssertTrue('the modal opened', FApp.ModalActive);
  { Ctrl+R starts the inline rename; type a name and submit. Each key needs its
    own Step to be consumed. }
  FInput.Push(Ctrl('r'));
  FInput.Push(Ch('h'));
  FInput.Push(Ch('i'));
  FInput.Push(Key(kkEnter));
  for I := 1 to 8 do
    FApp.Step;
  AssertEquals('the rename reached the header', 'hi', FApp.Panel.HeaderLeft);
end;

procedure THarnessAppTest.TestEveryDispatchedCommandIsOfferedByThePalette;
const
  { Commands offered unconditionally. /redo is deliberately absent: it appears
    only when there is something to redo, and a test asserting it is always there
    would forbid that. }
  Dispatched: array[0..1] of string = ('checkpoint', 'sessions');
var
  I, J: Integer;
  Found: Boolean;
begin
  { The invariant that keeps the bug from coming back. RunCommand is reachable
    ONLY through the palette, and the palette runs only a name it was given: with
    no match it declines the key, the composer takes Enter, and Submit sends the
    text to the provider as a prompt. So a command dispatched in RunCommand but
    missing from the palette is not merely undiscoverable - typing it messages the
    model with "/undo". }
  BuildWithStore;
  for I := 0 to High(Dispatched) do
  begin
    { Filter to the exact name and check the palette actually resolves it. }
    FApp.Panel.Palette.Filter('/' + Dispatched[I]);
    Found := False;
    for J := 0 to FApp.Panel.Palette.VisibleCount - 1 do
      if FApp.Panel.Palette.VisibleAt(J).Name = Dispatched[I] then
        Found := True;
    AssertTrue('/' + Dispatched[I] + ' must be offered by the palette', Found);
  end;
end;

procedure THarnessAppTest.TestTurnCommandsAreAbsentOnAFreshSession;
var
  I: Integer;
  Name: string;
begin
  { Nothing to act on, so nothing offered. An entry that can only open an empty
    list invites the operator to try something that cannot work. }
  BuildWithStore;
  FApp.Panel.Palette.Filter('/');
  for I := 0 to FApp.Panel.Palette.VisibleCount - 1 do
  begin
    Name := FApp.Panel.Palette.VisibleAt(I).Name;
    AssertTrue('/undo is not offered on a fresh session', Name <> 'undo');
    AssertTrue('/redo is not offered on a fresh session', Name <> 'redo');
    AssertTrue('/revert is not offered on a fresh session', Name <> 'revert');
  end;
end;

procedure THarnessAppTest.TestNoCommandHasAnEmptyName;
var
  I: Integer;
begin
  { THE BLANK ROW. The previous implementation pre-sized the array and left
    Name := '' in the slots for commands that were not actionable, so hiding
    /redo produced a visible empty "/" entry instead of a shorter list. }
  BuildWithStore;
  FApp.Panel.Palette.Filter('/');
  AssertTrue('the palette has entries', FApp.Panel.Palette.VisibleCount > 0);
  for I := 0 to FApp.Panel.Palette.VisibleCount - 1 do
    AssertTrue('entry ' + IntToStr(I) + ' has a name',
      FApp.Panel.Palette.VisibleAt(I).Name <> '');
end;

procedure THarnessAppTest.TestEscapeDismissesThePaletteSoSlashCanBeAPrompt;
var
  I: Integer;
begin
  { '/' is a character as well as a command prefix. Escape closes the list and
    must KEEP it closed while the box holds a lone '/token', because the composer
    reports every keystroke and would otherwise reopen it immediately. }
  BuildWithStore;
  FInput.Push(Ch('/'));
  FApp.Step;
  AssertTrue('the palette opened on /', FApp.Panel.PaletteActive);

  FInput.Push(Key(kkEscape));
  FApp.Step;
  AssertFalse('escape dismissed it', FApp.Panel.PaletteActive);

  { Type a further character: still a lone token, so it must not reopen. }
  FInput.Push(Ch('u'));
  FApp.Step;
  AssertFalse('it stays dismissed while the token is still lone',
    FApp.Panel.PaletteActive);

  { Once the text becomes a real prompt, the dismissal is spent and a fresh lone
    '/' opens the palette again. Clearing the box is the honest way to get back
    to a lone token - appending '/' to an existing prompt is NOT lone, and the
    palette is right to stay shut in that case. }
  FInput.Push(Ch(' '));
  FApp.Step;
  FApp.Panel.Compose.Clear;
  FInput.Push(Ch('/'));
  FApp.Step;
  AssertTrue('a new slash opens it again', FApp.Panel.PaletteActive);
end;

procedure THarnessAppTest.TestSkillListMarksLoadedUnloaded;
var
  I: Integer;
  AlphaDesc, BetaDesc, GammaDesc: string;
  SawAlpha, SawBeta, SawGamma: Boolean;
begin
  { The panel has to answer "what is already in the context?" without opening
    anything. One fixed description cannot: an operator would re-load a skill
    that is already there. }
  BuildWithStore;
  FRecording := TRecordingDriver.Create;
  SetLength(FRecording.Skills, 3);
  FRecording.Skills[0] := 'alpha';
  FRecording.Skills[1] := 'beta';
  FRecording.Skills[2] := 'gamma';
  { Two of the three are in context. Not all, and not none: a marking that is
    always the same string would pass an all-loaded or none-loaded case. }
  SetLength(FRecording.LoadedSkills, 2);
  FRecording.LoadedSkills[0] := 'alpha';
  FRecording.LoadedSkills[1] := 'gamma';
  FApp.Attach(FSession.View, FRecording);

  { Drive the real entry point (/skill) rather than the private ShowSkillList, so
    this covers the command wiring too. }
  FApp.Panel.Palette.OnRun('skill');

  SawAlpha := False;
  SawBeta := False;
  SawGamma := False;
  AlphaDesc := '';
  BetaDesc := '';
  GammaDesc := '';
  for I := 0 to FApp.Panel.Palette.VisibleCount - 1 do
  begin
    if FApp.Panel.Palette.VisibleAt(I).Name = 'alpha' then
    begin
      SawAlpha := True;
      AlphaDesc := FApp.Panel.Palette.VisibleAt(I).Description;
    end
    else if FApp.Panel.Palette.VisibleAt(I).Name = 'beta' then
    begin
      SawBeta := True;
      BetaDesc := FApp.Panel.Palette.VisibleAt(I).Description;
    end
    else if FApp.Panel.Palette.VisibleAt(I).Name = 'gamma' then
    begin
      SawGamma := True;
      GammaDesc := FApp.Panel.Palette.VisibleAt(I).Description;
    end;
  end;

  AssertTrue('alpha listed', SawAlpha);
  AssertTrue('beta listed', SawBeta);
  AssertTrue('gamma listed', SawGamma);
  AssertEquals('a loaded skill says so', 'loaded', AlphaDesc);
  AssertEquals('an unloaded skill invites a load', 'load this skill', BetaDesc);
  AssertEquals('and it is per row, not one shared string', 'loaded', GammaDesc);
end;

procedure THarnessAppTest.TestResumeHeaderMatchesLive;
var
  Live, Sid: string;
  Cfg: THarnessSessionConfig;
  Err: string;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":1200,"completion_tokens":310,' +
      '"total_tokens":1510,"prompt_tokens_details":{"cached_tokens":1100}}'),
    FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  Live := FApp.Panel.HeaderLeft + '|' + FApp.Panel.HeaderRight;
  AssertTrue('live header present', FApp.Panel.HeaderRight <> '');
  Sid := FSession.View.SessionId;

  { Drop the live app but keep the store, then resume the same session. }
  FApp.Free;
  FApp := nil;
  FInput := nil;
  FSurface := nil;
  FSession.Free;
  FSession := nil;
  FFake.Free;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, LocalDriver(FSession));
  FApp.Step;

  AssertEquals('resumed header identical to live', Live,
    FApp.Panel.HeaderLeft + '|' + FApp.Panel.HeaderRight);
end;

procedure THarnessAppTest.TestStatusSumsTurns;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('one'),
    UsageFrame('{"prompt_tokens":1000,"completion_tokens":100,' +
      '"total_tokens":1100}'), FinishFrame('stop'), DoneFrame]);
  FFake.AddResponse([TextDelta('two'),
    UsageFrame('{"prompt_tokens":2000,"completion_tokens":200,' +
      '"total_tokens":2200}'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('a');
  AssertTrue('first turn finished', Pump(300));
  SubmitPrompt('b');
  AssertTrue('second turn finished', Pump(300));

  { The status bar's consumption sums both turns: 3k in, 300 out, 2 req. }
  AssertTrue('input summed', Pos('3k in', FApp.StatsText) > 0);
  AssertTrue('output summed', Pos('300 out', FApp.StatsText) > 0);
  AssertTrue('two requests', Pos('2 req', FApp.StatsText) > 0);
end;

procedure THarnessAppTest.TestStatusShowsWorkspaceAndConsumption;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":1200,"completion_tokens":310,' +
      '"total_tokens":1510,"prompt_tokens_details":{"cached_tokens":1100}}'),
    FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));

  { The workspace stays on the left; the consumption is on the right. }
  AssertEquals('workspace on the left', FDir, FApp.StatusText);
  AssertTrue('input in the consumption', Pos('1k in', FApp.StatsText) > 0);
  AssertTrue('output in the consumption', Pos('310 out', FApp.StatsText) > 0);
  AssertTrue('cache in the consumption',
    Pos('92% cached', FApp.StatsText) > 0);
end;

procedure THarnessAppTest.TestTurnDividerAfterSuccessfulTurn;
var
  I: Integer;
  Saw: Boolean;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":1200,"completion_tokens":310,' +
      '"total_tokens":1510,"prompt_tokens_details":{"cached_tokens":1100}}'),
    FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));

  Saw := False;
  for I := 0 to BlockCount - 1 do
    if (BlockKind(I) = ckTurn) and (Pos('1k in', BlockText(I)) > 0) then
      Saw := True;
  AssertTrue('a divider carries the loop stats', Saw);
end;

procedure THarnessAppTest.TestNoDividerAfterFailedTurn;
var
  I: Integer;
begin
  Build;
  FFake.FailNetwork := True;
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));
  for I := 0 to BlockCount - 1 do
    AssertFalse('no divider for a failed loop', BlockKind(I) = ckTurn);
end;

procedure THarnessAppTest.TestNoTurnChangesBlockWhenNothingChanged;
var
  I: Integer;
begin
  { A turn that wrote no files renders NO summary block. An empty block would be
    noise on every conversational turn, and its absence already says the tree is
    untouched. }
  BuildWithStore;
  FFake.AddResponse([TextDelta('hi'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  for I := 0 to BlockCount - 1 do
    AssertFalse('no summary block when nothing changed',
      BlockKind(I) = ckTurnChanges);
end;

procedure THarnessAppTest.TestTurnSummaryBlockListsTheChangedFiles;
var
  I, Found: Integer;
  Text: string;

  { Seed one net change row for the turn the app is about to run. The recorder
    would normally write these at the turn boundary; seeding them directly keeps
    this test about the BLOCK (does it render? does it name the files?) rather
    than about capture, which has its own tests. }
  procedure SeedNet(const APath: string; ABefore, AAfter: string);
  var
    Changes: IChangeStore;
    R: TChangeRecord;
    Id: Integer;
    Err, Patch: string;
    Capped: Boolean;
  begin
    Err := '';
    Changes := TSqliteChangeStore.Create(FSession.View.Store);
    R := Default(TChangeRecord);
    R.WorkspaceId := FSession.View.WorkspaceId;
    R.SessionId := FSession.View.SessionId;
    R.TurnId := 1;
    R.Path := APath;
    R.Kind := ckModified;
    R.IsNet := True;
    R.BeforeHash := 'h:' + ABefore;
    R.AfterHash := 'h:' + AAfter;
    Patch := DiffText(ABefore, AAfter, DefaultPatchCapBytes, Capped);
    R.Patch := Patch;
    R.PatchBytes := Length(Patch);
    R.Capped := Capped;
    AssertTrue('seeded: ' + Err, Changes.Append(R, Id, Err));
  end;

begin
  { The positive path. Only the NEGATIVE case was covered, so an emitter that
    returned early on every call would have left the suite green. }
  BuildWithStore;
  SeedNet('src/a.pas', 'one' + LineEnding + 'two' + LineEnding,
    'one' + LineEnding + 'TWO' + LineEnding + 'three' + LineEnding);
  SeedNet('build/out.txt', '', 'x' + LineEnding);
  FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('do it');
  AssertTrue('turn finished', Pump(300));

  Text := '';
  for I := 0 to BlockCount - 1 do
    if BlockKind(I) = ckTurnChanges then
      Text := BlockText(I);
  AssertTrue('a summary block was rendered', Text <> '');
  AssertTrue('it names the modified file: ' + Text, Pos('src/a.pas', Text) > 0);
  AssertTrue('and its counts: ' + Text, Pos('+2', Text) > 0);
  AssertTrue('and the removal: ' + Text, Pos('-1', Text) > 0);
  AssertTrue('it names the created file too', Pos('build/out.txt', Text) > 0);

  { And the block knows WHICH file each row is, in the same order the lines were
    rendered - otherwise a click opens the neighbour's diff. The two orders are
    computed separately (rendering sorts, selection sorts), so this is the test
    that keeps them from drifting. }
  AssertTrue('read back the block', I >= 0);
  Found := -1;
  for I := 0 to BlockCount - 1 do
    if BlockKind(I) = ckTurnChanges then
      Found := I;
  AssertTrue('a block exists', Found >= 0);
  { Arrange it first: FBodyTop is recorded when the body is laid out, which is
    what the stream does before a click can land. Asserting without arranging
    would test an unrendered block, not the operator's. }
  ArrangeBlock(Found, 60);
  AssertEquals('row 1 is the alphabetically first path', 'build/out.txt',
    BlockFileAt(Found, 1));
  AssertEquals('row 2 is the second', 'src/a.pas', BlockFileAt(Found, 2));
end;

procedure THarnessAppTest.TestTurnSummaryOmitsAFileWhoseEditsCancelled;
var
  I: Integer;

  procedure SeedNet(const APath, ATwiceEndsSame: string);
  var
    Changes: IChangeStore;
    R: TChangeRecord;
    Id: Integer;
    Err: string;
  begin
    Err := '';
    Changes := TSqliteChangeStore.Create(FSession.View.Store);
    R := Default(TChangeRecord);
    R.WorkspaceId := FSession.View.WorkspaceId;
    R.SessionId := FSession.View.SessionId;
    R.TurnId := 1;
    R.Path := APath;
    R.Kind := ckModified;
    R.IsNet := True;
    { The fold's output for a file edited and reverted: both ends identical, so
      no patch. This is the payoff of the net fold, asserted end to end. }
    R.BeforeHash := 'h:' + ATwiceEndsSame;
    R.AfterHash := 'h:' + ATwiceEndsSame;
    AssertTrue('seeded: ' + Err, Changes.Append(R, Id, Err));
  end;

begin
  BuildWithStore;
  SeedNet('src/cancelled.pas', 'orig' + LineEnding);
  FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('do it');
  AssertTrue('turn finished', Pump(300));
  for I := 0 to BlockCount - 1 do
  begin
    AssertFalse('the cancelled file is not listed',
      Pos('cancelled.pas', BlockText(I)) > 0);
  end;
end;

procedure THarnessAppTest.TestResumeRendersTurnDividers;
var
  Live, Sid: string;
  Cfg: THarnessSessionConfig;
  Err: string;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":1200,"completion_tokens":310,' +
      '"total_tokens":1510,"prompt_tokens_details":{"cached_tokens":1100}}'),
    FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  Live := DividerSignature;
  AssertTrue('a live divider exists', Live <> '');
  Sid := FSession.View.SessionId;

  FApp.Free;
  FApp := nil;
  FInput := nil;
  FSurface := nil;
  FSession.Free;
  FSession := nil;
  FFake.Free;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, LocalDriver(FSession));
  FApp.Step;

  AssertEquals('resumed dividers identical to live', Live, DividerSignature);
end;

procedure THarnessAppTest.TestThoughtShowsDuration;
var
  Delay: TSlowChunks;
  Live, Sid: string;
  Cfg: THarnessSessionConfig;
  Err: string;
begin
  BuildWithStore;
  Delay := TSlowChunks.Create(20);
  try
    FFake.AfterChunk := Delay.AfterChunk;
    FFake.AddResponse([ReasoningDelta('think'), TextDelta('answer'),
      FinishFrame('stop'), DoneFrame]);
    SubmitPrompt('hi');
    AssertTrue('turn finished', Pump(400));
  finally
    Delay.Free;
  end;
  Live := ThoughtLabel;
  AssertTrue('thought shows its duration', Pos('Thought for ', Live) > 0);
  Sid := FSession.View.SessionId;

  FApp.Free;
  FApp := nil;
  FInput := nil;
  FSurface := nil;
  FSession.Free;
  FSession := nil;
  FFake.Free;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, LocalDriver(FSession));
  FApp.Step;

  AssertEquals('resumed thought label identical', Live, ThoughtLabel);
end;

procedure THarnessAppTest.TestCtaHintsAreBlank;
begin
  Build;
  { No subagents in this session, so the ctrl+d segment is ABSENT: a hint for a
    key that could only open an empty list is noise. The policy itself is pinned
    separately by TestComposerHintsShowCtrlDOnlyWithSubagents. }
  AssertEquals('hints without subagents', 'shift+enter newline',
    FApp.HintsText);
  AssertFalse('hints are not in the status bar',
    Pos('newline', FApp.StatusText) > 0);
end;

procedure THarnessAppTest.TestComposerHintsShowCtrlDOnlyWithSubagents;
begin
  { The conditional, as a pure function - so the rule is testable without
    building an app and a store. }
  AssertFalse('no ctrl+d when there are no subagents: ' +
    ComposerHints(False), Pos('ctrl+d', ComposerHints(False)) > 0);
  AssertTrue('ctrl+d offered when there are subagents: ' +
    ComposerHints(True), Pos('ctrl+d subagents', ComposerHints(True)) > 0);
  AssertTrue('the base hints survive both ways',
    Pos('shift+enter newline', ComposerHints(True)) > 0);
end;

procedure THarnessAppTest.TestCoarseScrollTargetMapsSegments;
begin
  { The scrubber has one segment per page (the checkpoint count from the store);
    a segment maps to a 0-based message index. Segment 0 is the oldest, the last
    segment the newest. }
  AssertEquals('first segment is the oldest', 0,
    CoarseScrollTarget(0, 3, 100));
  AssertEquals('last segment is the newest', 99,
    CoarseScrollTarget(2, 3, 100));
  AssertEquals('middle segment', 49, CoarseScrollTarget(1, 3, 100));
  { Edge cases: a single message, a single page (the bar is not drawn for one
    page, so its target is the top). }
  AssertEquals('one message', 0, CoarseScrollTarget(0, 3, 1));
  AssertEquals('one page -> top', 0, CoarseScrollTarget(0, 1, 43));
end;

procedure THarnessAppTest.TestShouldTrimHistory;
begin
  { Trim only when older pages are loaded, the operator has been idle past the
    window, AND the viewport is at the bottom.

    ALastScrollMs must be a REAL timestamp here. The old version passed 0
    everywhere, and 0 meant "never scrolled" - which on a machine whose uptime
    exceeds TrimIdleMs made the trim fire instantly and unload pages the operator
    was still reading. The test could not catch that because it only ever used
    the sentinel. }
  AssertFalse('no older pages: no trim',
    ShouldTrimHistory(0, 100000, 1000, 500, 500));
  AssertFalse('recent scroll: no trim',
    ShouldTrimHistory(2, 5000, 1000, 500, 500));
  AssertFalse('scrolled up (not at the bottom): no trim',
    ShouldTrimHistory(2, 100000, 1000, 100, 500));
  AssertTrue('idle + at the bottom: trim',
    ShouldTrimHistory(2, 100000, 1000, 500, 500));
  AssertTrue('within 2 rows of the bottom still trims',
    ShouldTrimHistory(2, 100000, 1000, 498, 500));
  { Never scrolled is not the same as idle - it is no evidence either way, and
    trimming on it unloads pages nobody has finished reading. }
  AssertFalse('never scrolled: never trim',
    ShouldTrimHistory(2, 100000, 0, 500, 500));
end;

procedure THarnessAppTest.TestThinkingStateDuringATurn;
var
  I: Integer;
  Seen: Boolean;
begin
  Build;
  FFake.AddChunk(TextDelta('hi'));
  FFake.AddChunk(FinishFrame('stop'));
  FFake.AddChunk(DoneFrame);
  SubmitPrompt('hello');
  Seen := False;
  for I := 1 to 300 do
  begin
    FApp.Step;
    if FApp.Busy then
    begin
      Seen := True;
      AssertEquals('thinking while busy', 'Thinking', FApp.StateText);
      Break;
    end;
    Sleep(2);
  end;
  AssertTrue('the turn started', Seen);
end;

procedure THarnessAppTest.TestReadyStateAfterATurn;
begin
  Build;
  FFake.AddResponse([TextDelta('hi'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  AssertEquals('ready state', 'Ready', FApp.StateText);
end;

procedure THarnessAppTest.TestErrorStateAfterAFailedTurn;
begin
  Build;
  FFake.FailNetwork := True;
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));
  AssertEquals('error state', 'Error', FApp.StateText);
end;

procedure THarnessAppTest.TestErrorRollsBackStreamedBlocks;
var
  Fail: TFailNetworkAfterChunk;
begin
  Build;
  Fail := TFailNetworkAfterChunk.Create(FFake);
  try
    { The first response streams a fragment and is truncated; the continuation
      then hits a network error, so the pending response is discarded. }
    FFake.AfterChunk := Fail.AfterChunk;
    FFake.AddResponse([TextDelta('partial answer'), FinishFrame('length'),
      DoneFrame]);
    SubmitPrompt('hi');
    AssertTrue('turn finished', Pump(300));
  finally
    FFake.AfterChunk := nil;
    Fail.Free;
  end;

  AssertFalse('the streamed fragment was rolled back',
    FindText(ckAssistant, 'partial answer'));
  AssertTrue('an error block exists', FindText(ckError, 'network error'));
  { The cause is shown, not just the generic message. }
  AssertTrue('the cause is shown', FindText(ckError, 'simulated network failure'));
  AssertTrue('prompt re-enabled', FApp.PromptActive);
end;

procedure THarnessAppTest.TestResumeMatchesLiveAfterTruncationError;
var
  Live, Sid: string;
  Cfg: THarnessSessionConfig;
  Err: string;
begin
  BuildWithStore;
  { A truncated fragment that the next request cannot complete. }
  FFake.AddResponse([TextDelta('partial answer'), FinishFrame('length'),
    DoneFrame]);
  FFake.AddResponse([FinishFrame('content_filter'), DoneFrame]);
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));
  AssertFalse('no fragment live', FindText(ckAssistant, 'partial answer'));
  Live := BlockSignature;
  Sid := FSession.View.SessionId;

  { Drop the live app but keep the store, then resume the same session. }
  FApp.Free;
  FApp := nil;
  FInput := nil;
  FSurface := nil;
  FSession.Free;
  FSession := nil;
  FFake.Free;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, LocalDriver(FSession));
  FApp.Step;

  AssertEquals('resumed blocks identical to live', Live, BlockSignature);
end;

procedure THarnessAppTest.TestEscapeArmsThenCancels;
var
  Slow: TSlowChunks;
  I: Integer;
begin
  Build;
  Slow := TSlowChunks.Create(80);
  try
    FFake.AfterChunk := Slow.AfterChunk;
    { Two requests, so the loop reaches a boundary where the cancel is seen. }
    FFake.AddResponse([TextDelta('working'),
      ToolNameFrame(0, 'c1', 'get_system_time'),
      ToolArgsFrame(0, '{"reason":"r"}'),
      FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    SubmitPrompt('hello');
    for I := 1 to 300 do
    begin
      FApp.Step;
      if FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertTrue('turn in flight', FApp.Busy);

    FInput.Push(Key(kkEscape));
    FApp.Step;
    AssertTrue('first escape arms', FApp.InterruptArmed);
    AssertEquals('prompt shown', 'Press Esc again to cancel', FApp.StateText);

    FInput.Push(Key(kkEscape));
    FApp.Step;
    AssertFalse('second escape disarms', FApp.InterruptArmed);
    AssertEquals('cancelling', 'Cancelling', FApp.StateText);

    { The cancel is seen at the worker's next loop boundary; wait for idle. }
    for I := 1 to 600 do
    begin
      FApp.Step;
      if not FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertEquals('cancelled state', 'Cancelled', FApp.StateText);
  finally
    Slow.Free;
  end;
end;

procedure THarnessAppTest.TestEarlyCancelRestoresThePrompt;
var
  Slow: TSlowChunks;
  I: Integer;
begin
  Build;
  Slow := TSlowChunks.Create(80);
  try
    FFake.AfterChunk := Slow.AfterChunk;
    FFake.AddResponse([TextDelta('working'), FinishFrame('stop'), DoneFrame]);
    SubmitPrompt('hello');
    for I := 1 to 300 do
    begin
      FApp.Step;
      if FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertTrue('turn in flight', FApp.Busy);

    FInput.Push(Key(kkEscape));
    FApp.Step;
    FInput.Push(Key(kkEscape));
    FApp.Step;
    for I := 1 to 800 do
    begin
      FApp.Step;
      if not FApp.Busy then
        Break;
      Sleep(2);
    end;

    AssertEquals('cancelled', 'Cancelled', FApp.StateText);
    AssertEquals('the prompt came back', 'hello',
      string(FApp.Panel.Compose.Text));
    AssertEquals('the aborted turn left no block', 0, BlockCount);
  finally
    Slow.Free;
  end;
end;

procedure THarnessAppTest.TestUndoShrinksTheStreamAndRestoresThePrompt;
var
  Turns: TTurnRecordArray;
  TurnId: Int64;
  StoreErr: TStoreError;
  Rec: TMessageRecord;
begin
  { The cancel behaviour, end to end: a completed conversational turn is in the
    stream, undo runs, and the stream loses it while its prompt returns to the
    composer for editing. }
  BuildWithStore;
  { Seed one completed turn with a user message and NO file change: the
    conversational case that undo used to refuse outright. }
  AssertTrue('begin turn',
    FSession.View.Store.BeginTurn(FSession.View.SessionId, TurnId, StoreErr));
  Rec := Default(TMessageRecord);
  Rec.SessionId := FSession.View.SessionId;
  Rec.TurnId := TurnId;
  Rec.Role := mrUser;
  Rec.Content := 'do the thing';
  AssertTrue('message', FSession.View.Store.AppendMessage(Rec, StoreErr));
  AssertTrue('finish',
    FSession.View.Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '',
      StoreErr));

  { The undo goes through the real local driver, so this exercises the event the
    app acts on rather than calling the handler directly. }
  FApp.Panel.Compose.Clear;
  FApp.Panel.Palette.OnRun('undo');
  AssertTrue('the history dialog opened', FApp.ModalActive);

  { Choose the seeded turn. The dialog reports it; the app performs the undo and
    drains teUndone on the next Step. }
  FInput.Push(Key(kkEnter));
  FApp.Step;
  FApp.Step;

  Turns := FSession.View.Turns;
  AssertEquals('one turn still in the ledger', 1, Length(Turns));
  AssertEquals('but it is undone', Ord(tsUndone), Ord(Turns[0].Status));

  { The prompt is back in the composer, which is the point of the change. }
  AssertEquals('the prompt came back', 'do the thing',
    string(FApp.Panel.Compose.Text));
end;

procedure THarnessAppTest.TestSubmitWhileBusyQueuesThePrompt;
var
  Slow: TSlowChunks;
  I: Integer;
begin
  Build;
  Slow := TSlowChunks.Create(80);
  try
    FFake.AfterChunk := Slow.AfterChunk;
    FFake.AddResponse([TextDelta('one'), FinishFrame('stop'), DoneFrame]);
    FFake.AddResponse([TextDelta('two'), FinishFrame('stop'), DoneFrame]);
    SubmitPrompt('first');
    for I := 1 to 300 do
    begin
      FApp.Step;
      if FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertTrue('turn in flight', FApp.Busy);

    { A second submit while busy is queued, not dropped. }
    SubmitPrompt('second');
    for I := 1 to 1200 do
    begin
      FApp.Step;
      if not FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertEquals('the queued prompt started the next turn', 2, FFake.Calls);
    AssertTrue('the queued prompt is in the transcript',
      FindText(ckUser, 'second'));
  finally
    Slow.Free;
  end;
end;

procedure THarnessAppTest.TestPasteInsertsIntoTheCompose;
var
  E: TInputEvent;
begin
  Build;
  E := Default(TInputEvent);
  E.Kind := ikPaste;
  E.Text := 'pasted' + #10 + 'text';
  FInput.Push(E);
  FApp.Step;

  AssertEquals('pasted text inserted whole', 'pasted' + #10 + 'text',
    string(FApp.Panel.Compose.Text));
  AssertFalse('a paste never submits', FApp.Busy);
end;

procedure THarnessAppTest.TestCtrlCQuitsOnlyWhenComposeIsEmpty;
begin
  Build;
  FInput.Push(Ch('h'));
  FInput.Push(Ch('i'));
  FApp.Step;
  FApp.Step;
  AssertEquals('compose has text', 'hi', string(FApp.Panel.Compose.Text));

  FInput.Push(Ctrl('c'));
  AssertTrue('ctrl+c with text does not quit', FApp.Step);
  AssertEquals('compose cleared', '', string(FApp.Panel.Compose.Text));

  FInput.Push(Ctrl('c'));
  AssertFalse('ctrl+c on an empty compose quits', FApp.Step);
end;

procedure THarnessAppTest.TestApprovalDimsTheBackground;
begin
  Build;
  FSession.Queue.Push(ApprovalEvent(1, MakeAsk));
  FApp.Step;   // drain the ask -> show the modal
  FApp.Step;   // render it
  AssertTrue('modal shown', FApp.ModalActive);
  { A cell above the modal (the panel's top border) is dimmed. }
  AssertTrue('the background is dimmed',
    sfDim in FSurface.CellAt(20, 0).Attr.Style);
end;

procedure THarnessAppTest.TestSessionsCommandOpensAndClosesTheModal;
begin
  BuildWithStore;
  AssertFalse('no modal initially', FApp.ModalActive);
  { Run /sessions via the palette's command hook. }
  FApp.Panel.Palette.OnRun('sessions');
  FApp.Step;   // render the plane
  AssertTrue('the sessions modal opened', FApp.ModalActive);
  { Escape closes it. }
  FInput.Push(Key(kkEscape));
  FApp.Step;
  FApp.Step;
  AssertFalse('the modal closed', FApp.ModalActive);
end;

procedure THarnessAppTest.TestEnterInTheSessionsModalClosesIt;
begin
  { The selected row is the current session (the only one), so Enter activates it
    and the no-op switch closes the modal on the next Step. This exercises the
    OnActivate wiring end to end. }
  BuildWithStore;
  FApp.Panel.Palette.OnRun('sessions');
  FApp.Step;
  AssertTrue('the modal opened', FApp.ModalActive);
  FInput.Push(Key(kkEnter));
  FApp.Step;
  FApp.Step;
  AssertFalse('Enter closed the modal', FApp.ModalActive);
end;

procedure THarnessAppTest.TestSwitchSessionOpensTheTarget;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  Cfg: THarnessSessionConfig;
  WorkspaceId: Integer;
  SidA, SidB: string;
  TurnId: Int64;
  Rec: TMessageRecord;
  Err: string;
begin
  { Seed two sessions; A is empty, B carries a marker message. }
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateSession(WorkspaceId, SidA, StoreErr);
    Store.CreateSession(WorkspaceId, SidB, StoreErr);
    Store.BeginTurn(SidB, TurnId, StoreErr);
    Rec := Default(TMessageRecord);
    Rec.SessionId := SidB;
    Rec.TurnId := TurnId;
    Rec.Role := mrUser;
    Rec.Content := 'the other session marker';
    Store.AppendMessage(Rec, StoreErr);
  finally
    Store.Free;
  end;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := SidA;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, LocalDriver(FSession));
  FApp.Step;

  AssertEquals('starts on A', SidA, FApp.SessionId);
  AssertFalse('A has no marker', FindText(ckUser, 'the other session marker'));

  FApp.OnSwitchSession := SwitchTo;
  FSwitchResult := True;
  FApp.SwitchSession(SidB);

  AssertEquals('switched to B', SidB, FApp.SessionId);
  AssertTrue('B transcript is shown',
    FindText(ckUser, 'the other session marker'));
end;

procedure THarnessAppTest.TestSwitchToCurrentSessionIsANoOp;
var
  Before: string;
begin
  BuildWithStore;
  FApp.OnSwitchSession := SwitchTo;
  FSwitchResult := True;
  Before := FApp.SessionId;
  FApp.SwitchSession(Before);
  AssertEquals('no callback for the current session', 0, FSwitchCalls);
  AssertEquals('still on the same session', Before, FApp.SessionId);
end;

procedure THarnessAppTest.TestSwitchWhileBusyDetaches;
var
  Slow: TSlowChunks;
  I: Integer;
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  SidB: string;
begin
  { A switch during a live turn detaches from the old turn (the runtime keeps it
    running) and opens the target, rather than refusing. }
  BuildWithStore;
  { A second session to switch to. }
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateSession(WorkspaceId, SidB, StoreErr);
  finally
    Store.Free;
  end;

  Slow := TSlowChunks.Create(80);
  try
    FFake.AfterChunk := Slow.AfterChunk;
    FFake.AddResponse([TextDelta('one'), FinishFrame('stop'), DoneFrame]);
    SubmitPrompt('go');
    for I := 1 to 300 do
    begin
      FApp.Step;
      if FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertTrue('turn in flight', FApp.Busy);

    FApp.OnSwitchSession := SwitchTo;
    FSwitchResult := True;
    FApp.SwitchSession(SidB);
    AssertEquals('the switch ran', 1, FSwitchCalls);
    AssertEquals('switched to the target', SidB, FApp.SessionId);
    AssertFalse('the busy state is cleared by the detach', FApp.Busy);
    AssertFalse('no refusal', FindText(ckError, 'before switching'));
  finally
    Slow.Free;
    FFake.AfterChunk := nil;
  end;
end;

procedure THarnessAppTest.TestSwitchFailureKeepsTheSession;
var
  Before: string;
begin
  BuildWithStore;
  Before := FApp.SessionId;
  FApp.OnSwitchSession := SwitchTo;
  FSwitchResult := False;
  FSwitchErr := 'boom';
  FApp.SwitchSession('a-target');
  AssertEquals('the callback ran', 1, FSwitchCalls);
  AssertTrue('the error is shown',
    FindText(ckError, 'could not open session: boom'));
  AssertEquals('the current session is kept', Before, FApp.SessionId);
end;

procedure THarnessAppTest.TestSwitchWithoutAHookIsRefused;
begin
  BuildWithStore;
  FApp.SwitchSession('a-target');
  AssertTrue('the refusal is shown', FindText(ckError, 'cannot switch sessions'));
end;

procedure THarnessAppTest.TestAgentListTogglesWithCtrlD;
begin
  Build;
  AssertFalse('hidden by default', FApp.AgentListVisible);
  FInput.Push(Ctrl('d'));
  Pump(4);
  AssertTrue('shown after ctrl+d', FApp.AgentListVisible);
  FInput.Push(Ctrl('d'));
  Pump(4);
  AssertFalse('hidden again', FApp.AgentListVisible);
end;

procedure THarnessAppTest.TestAgentListRendersItsRows;
var
  Y: Integer;
  Found: Boolean;
begin
  { The regression this guards: the agent list was created and toggled but never
    drawn. With a roster entry, Ctrl+D must put the child's label on the
    surface. }
  Build;
  FSession.Queue.Push(SubagentEvent('child-1', 'scan the tree', 'running'));
  FApp.Step;   { the roster entry is applied }
  FInput.Push(Ctrl('d'));
  FApp.Step;
  FApp.Step;

  Found := False;
  for Y := 0 to FSurface.Height - 1 do
    if Pos('scan the tree', FSurface.RowText(Y, 0, FSurface.Width)) > 0 then
      Found := True;
  AssertTrue('the agent-list row is rendered', Found);
end;

procedure THarnessAppTest.TestAgentListRoutesKeysAndEntersTheSpy;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  ChildId: string;
begin
  { The list now sits in the composer's place rather than floating over the
    transcript. What must still hold is that keys REACH it and Enter opens that
    child's spy - the routing depends on the overlay, not on the list itself, so
    a green TAgentList unit test proves nothing about it.

    A child session has to exist for the spy to open, so this needs a store. }
  BuildWithStore;
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateChildSession(WorkspaceId, FSession.View.SessionId, 1, 'child',
      ChildId, StoreErr);
  finally
    Store.Free;
  end;

  FApp.OnSpyFactory := OpenStubSpy;
  FSpyQueue := TTurnQueue.Create;

  { Put the child in the roster, then open the list. }
  FSession.Queue.Push(SubagentEvent(ChildId, 'scan the tree', 'running'));
  FApp.Step;
  FInput.Push(Ctrl('d'));
  FApp.Step;
  FApp.Step;
  AssertTrue('the list is up', FApp.AgentListVisible);

  { Keys must reach the list through the overlay while it is visible. Down is
    handled by TAgentList; if routing were broken this would be swallowed and the
    selection would never move. }
  FInput.Push(Key(kkDown));
  FApp.Step;

  { Enter opens that child's spy. }
  FInput.Push(Key(kkEnter));
  FApp.Step;
  FApp.Step;
  AssertEquals('enter opened the child spy', ChildId, FApp.SpiedSessionId);
end;

procedure THarnessAppTest.TestSpyTranscriptIsNotDoubled;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  ChildId: string;
begin
  { The bug the operator hit: right after switching to a child, messages appeared
    twice and then vanished on scroll-down, and it eventually crashed.

    Two sources fill the same transcript: RenderSpyHistory reads the child's
    messages from the store, and the spy's attach REPLAYED the live turn from the
    runtime ring (FromSeq = 0 means "the whole live turn"). Nothing
    deduplicated them.

    The fix is that the app asks for NO replay, so the store is the single source
    for history while LIVE events still stream in. That decision is what this
    pins - asserting the transcript contents would only re-test RenderSpyHistory,
    which was never wrong. }
  BuildWithStore;
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateChildSession(WorkspaceId, FSession.View.SessionId, 1, 'child',
      ChildId, StoreErr);
  finally
    Store.Free;
  end;

  FApp.OnSpyFactory := OpenStubSpy;
  FSpyQueue := TTurnQueue.Create;
  FApp.ShowSpy(ChildId);
  FApp.Step;

  { The app must attach past the end of the replay ring. FromSeq = 0 is the
    documented "replay the whole live turn" sentinel, and it is exactly what
    doubled the transcript. }
  AssertTrue('the spy attaches without a replay: FromSeq=' +
    IntToStr(FSpyConfig.FromSeq), FSpyConfig.FromSeq > 0);
  AssertTrue('and past any seq the ring can hold',
    FSpyConfig.FromSeq > 1000000000);
  AssertEquals('the spy is still observe-only', Ord(srObserve),
    Ord(FSpyConfig.Role));
end;

procedure THarnessAppTest.TestSpyEnterShowsChildAndIndicator;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  ChildId: string;
  TurnId: Int64;
  Rec: TMessageRecord;
begin
  { A child session with a message in the store, and a roster entry so the
    agent list has a row. Entering it shows the child's transcript and the header
    indicator. }
  BuildWithStore;
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateChildSession(WorkspaceId, FSession.View.SessionId, 1, 'child', ChildId,
      StoreErr);
    Store.BeginTurn(ChildId, TurnId, StoreErr);
    Rec := Default(TMessageRecord);
    Rec.SessionId := ChildId;
    Rec.TurnId := TurnId;
    Rec.Role := mrAssistant;
    Rec.Content := 'the child did the thing';
    Store.AppendMessage(Rec, StoreErr);
  finally
    Store.Free;
  end;

  FApp.OnSpyFactory := OpenStubSpy;
  FSpyQueue := TTurnQueue.Create;
  FApp.ShowSpy(ChildId);
  FApp.Step;

  AssertEquals('spying on the child', ChildId, FApp.SpiedSessionId);
  AssertTrue('the child transcript is shown',
    FindText(ckAssistant, 'the child did the thing'));
  AssertTrue('the header names the child',
    Pos('spying', FApp.Panel.HeaderLeft) > 0);
end;

procedure THarnessAppTest.TestSpyCtrlDReturnsToParent;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  ChildId: string;
  Before: string;
begin
  BuildWithStore;
  Before := FApp.SessionId;
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateChildSession(WorkspaceId, FSession.View.SessionId, 1, 'child', ChildId,
      StoreErr);
  finally
    Store.Free;
  end;

  FApp.OnSpyFactory := OpenStubSpy;
  FSpyQueue := TTurnQueue.Create;
  FApp.ShowSpy(ChildId);
  FApp.Step;
  AssertEquals('in spy mode', ChildId, FApp.SpiedSessionId);

  { Ctrl+D is the way back. It leaves the spy rather than toggling the list, so
    the key that got you into a child also gets you out. }
  FInput.Push(Ctrl('d'));
  FApp.Step;
  FApp.Step;
  AssertEquals('left the spy', '', FApp.SpiedSessionId);
  AssertEquals('still on the parent', Before, FApp.SessionId);
end;

procedure THarnessAppTest.TestSpyEscapeArmsWithoutLeaving;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  ChildId: string;
begin
  { The regression this guards: Escape used to leave the spy directly. Now it is
    a two-step cancel, so ONE press must arm and stay - a single Escape must not
    kill the child, and must not exit either. }
  BuildWithStore;
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateChildSession(WorkspaceId, FSession.View.SessionId, 1, 'child',
      ChildId, StoreErr);
  finally
    Store.Free;
  end;

  FApp.OnSpyFactory := OpenStubSpy;
  FSpyQueue := TTurnQueue.Create;
  FApp.ShowSpy(ChildId);
  FApp.Step;

  FInput.Push(Key(kkEscape));
  FApp.Step;
  FApp.Step;

  AssertEquals('one escape does not leave the spy', ChildId,
    FApp.SpiedSessionId);
end;

procedure THarnessAppTest.TestSpySuppressesParentEvents;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  ChildId: string;
  E: TTurnEvent;
begin
  { While spying, a parent event is consumed but not drawn. }
  BuildWithStore;
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateChildSession(WorkspaceId, FSession.View.SessionId, 1, 'child', ChildId,
      StoreErr);
  finally
    Store.Free;
  end;

  FApp.OnSpyFactory := OpenStubSpy;
  FSpyQueue := TTurnQueue.Create;
  FApp.ShowSpy(ChildId);
  FApp.Step;

  { A parent event on the parent's driver (the fake queue the app drains). }
  E := AssistantEvent('parent noise');
  FSession.Queue.Push(E);
  FApp.Step;

  AssertFalse('the parent event is not drawn',
    FindText(ckAssistant, 'parent noise'));
end;

procedure THarnessAppTest.TestSpyStillShowsAnApprovalAsk;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  ChildId: string;
  Ask: TApprovalAsk;
begin
  { The bug this guards: while spying, the pump dropped every parent event,
    approval asks included. An ask is a blocking demand for operator action, not
    a transcript entry - and the supervisor stops auto-denying whenever a client
    is attached, so a dropped ask could never be answered by anyone. The child
    hung forever. }
  BuildWithStore;
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateChildSession(WorkspaceId, FSession.View.SessionId, 1, 'child',
      ChildId, StoreErr);
  finally
    Store.Free;
  end;

  FApp.OnSpyFactory := OpenStubSpy;
  FSpyQueue := TTurnQueue.Create;
  FApp.ShowSpy(ChildId);
  FApp.Step;
  AssertFalse('no modal on entering the spy', FApp.ModalActive);

  Ask := Default(TApprovalAsk);
  Ask.Summary := 'run_command';
  FSession.Queue.Push(ApprovalEvent(1, Ask));
  FApp.Step;

  AssertTrue('an ask still opens its modal while spying', FApp.ModalActive);
end;

{ A row with no title worth reading, only identity and lineage. }
function RowOf(const AId, AParent, ATitle: string; ADepth: Integer): TSessionRow;
begin
  Result := Default(TSessionRow);
  Result.Id := AId;
  Result.ParentSessionId := AParent;
  Result.Title := ATitle;
  Result.Depth := ADepth;
end;

procedure THarnessAppTest.TestSessionRowsNestUnderTheirParent;
var
  Rows: TSessionRowArray;
begin
  { The bug this guards: every session was listed flat, so a delegated child read
    as a PEER of the session that spawned it. A child must follow its parent and
    be visually marked as nested. }
  SetLength(Rows, 3);
  Rows[0] := RowOf('child-1', 'root-1', 'do the thing', 1);
  Rows[1] := RowOf('root-1', '', 'parent work', 0);
  Rows[2] := RowOf('root-2', '', 'other work', 0);

  OrderByLineage(Rows);

  AssertEquals('child follows its parent', 'root-1', Rows[0].Id);
  AssertEquals('child is next', 'child-1', Rows[1].Id);
  AssertTrue('other root still present', Rows[2].Id <> '');
  { The child's title carries a nesting marker; the parent's does not. }
  AssertEquals('parent title untouched', 'parent work', Rows[0].Title);
  AssertTrue('child is marked as nested: ' + Rows[1].Title,
    Pos('do the thing', Rows[1].Title) > 0);
  AssertTrue('child is indented', Rows[1].Title <> 'do the thing');
end;

procedure THarnessAppTest.TestSessionListsHideSubagents;
var
  Rows: TSessionRowArray;
  I: Integer;
  Found: Boolean;
begin
  { A child whose parent IS listed is a subagent: reachable through the agent
    list, so it must not appear in a session list as if the operator had started
    it. }
  SetLength(Rows, 3);
  Rows[0] := RowOf('root-1', '', 'parent work', 0);
  Rows[1] := RowOf('child-1', 'root-1', 'delegated work', 1);
  Rows[2] := RowOf('root-2', '', 'other work', 0);

  FilterParentsOnly(Rows);

  AssertEquals('two rows remain', 2, Length(Rows));
  AssertEquals('the first root stays', 'root-1', Rows[0].Id);
  AssertEquals('the second root stays', 'root-2', Rows[1].Id);
  { And the child is NOT among them - asserted by scanning, not by index, so the
    check cannot pass on a lucky ordering. }
  Found := False;
  for I := 0 to High(Rows) do
    if Rows[I].Id = 'child-1' then
      Found := True;
  AssertFalse('the subagent row is gone', Found);
end;

procedure THarnessAppTest.TestOrphanChildKeepsItsRow;
var
  Rows: TSessionRowArray;
begin
  { AN ORPHAN is a child whose parent is not in the list - archived, or outside
    the paging window. It is still a real, resumable session, so hiding it would
    make it unreachable. The rule is "no VISIBLE parent", not "never had one". }
  SetLength(Rows, 2);
  Rows[0] := RowOf('orphan-1', 'gone-parent', 'still mine', 1);
  Rows[1] := RowOf('root-1', '', 'parent work', 0);

  FilterParentsOnly(Rows);

  AssertEquals('both rows remain', 2, Length(Rows));
  AssertEquals('the orphan survives', 'orphan-1', Rows[0].Id);
  AssertEquals('and the root', 'root-1', Rows[1].Id);
end;

procedure THarnessAppTest.TestSessionDisplayNameJoinsLabelAndTitle;
begin
  { A session is an agent: what identifies it is the operator's name for it PLUS
    what it is currently doing. Either alone loses half the answer. }
  AssertEquals('label and title', 'docs - fix the parser',
    SessionDisplayName('docs', 'fix the parser', 'abcdef0123456789abcdef'));
end;

procedure THarnessAppTest.TestSessionDisplayNameFallsBackToTheShortId;
begin
  { No label: the short id identifies it. No title: no dangling separator. }
  AssertEquals('short id and title', 'abcdef - doing the thing',
    SessionDisplayName('', 'doing the thing', 'abcdef0123456789abcdef'));
  AssertEquals('label only, no separator', 'docs',
    SessionDisplayName('docs', '', 'abcdef0123456789abcdef'));
  { Neither label nor title still yields something identifiable. }
  AssertEquals('id alone', 'abcdef',
    SessionDisplayName('', '', 'abcdef0123456789abcdef'));
end;

procedure THarnessAppTest.TestRenameWritesTheLabelNotTheTitleOverride;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  ChildId, Parent, Lbl, Title: string;
  Depth: Integer;
begin
  { Rename moved from title_override to label: the label names the agent and
    must survive a later extracted title, whereas the override SHADOWED the
    title. After a rename, both must be readable, and the title must be free to
    keep tracking the turn. }
  BuildWithStore;
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateChildSession(WorkspaceId, FSession.View.SessionId, 1, 'child',
      ChildId, StoreErr);

    AssertTrue('set label', Store.SetSessionLabel(ChildId, 'my-agent', StoreErr));
    AssertTrue('lineage label',
      Store.SessionLineage(ChildId, Parent, Depth, Lbl, StoreErr));
    AssertEquals('label stored', 'my-agent', Lbl);

    { The extracted title is independent of the label - it is NOT shadowed. }
    AssertTrue('set title', Store.SetSessionTitle(ChildId, 'a turn title',
      StoreErr));
    AssertTrue('title readable', Store.SessionTitle(ChildId, Title, StoreErr));
    AssertEquals('title tracked separately', 'a turn title', Title);
    AssertTrue('label still there',
      Store.SessionLineage(ChildId, Parent, Depth, Lbl, StoreErr));
    AssertEquals('label unchanged by a title', 'my-agent', Lbl);

    { And the display joins them. }
    AssertEquals('joined', 'my-agent - a turn title',
      SessionDisplayName(Lbl, Title, ChildId));
  finally
    Store.Free;
  end;
end;

procedure THarnessAppTest.TestOrphanChildStaysAVisibleRoot;
var
  Rows: TSessionRowArray;
begin
  { A child whose parent is absent from the list (archived, or filtered) must
    still appear, flat. Dropping it would hide a live session entirely. }
  SetLength(Rows, 2);
  Rows[0] := RowOf('orphan', 'not-in-list', 'orphaned child', 1);
  Rows[1] := RowOf('root-1', '', 'parent work', 0);

  OrderByLineage(Rows);

  AssertEquals('both rows survive', 2, Length(Rows));
  AssertTrue('the orphan is present',
    (Rows[0].Id = 'orphan') or (Rows[1].Id = 'orphan'));
  AssertTrue('the root is present',
    (Rows[0].Id = 'root-1') or (Rows[1].Id = 'root-1'));
end;

procedure THarnessAppTest.TestDetachMakesAChildARoot;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId, Rows3: Integer;
  ChildId, Parent, Lbl: string;
  Depth: Integer;
  Rows: TSessionRowArray;
  I: Integer;
  Found: Boolean;
begin
  { Promoting a child clears its lineage, so afterwards it is an ordinary session
    and lists as a root. This is the store half of "no silent takeover". }
  BuildWithStore;
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateChildSession(WorkspaceId, FSession.View.SessionId, 1, 'child',
      ChildId, StoreErr);

    AssertTrue('lineage before',
      Store.SessionLineage(ChildId, Parent, Depth, Lbl, StoreErr));
    AssertTrue('has a parent', Parent <> '');

    AssertTrue('detach', Store.DetachSession(ChildId, StoreErr));

    AssertTrue('lineage after',
      Store.SessionLineage(ChildId, Parent, Depth, Lbl, StoreErr));
    AssertEquals('no parent', '', Parent);
    AssertEquals('depth reset', 0, Depth);

    { And it now lists as a root. }
    AssertTrue('list', Store.ListSessionRows(WorkspaceId, True, Rows, StoreErr));
    Found := False;
    for I := 0 to High(Rows) do
      if (Rows[I].Id = ChildId) and (Rows[I].ParentSessionId = '') then
        Found := True;
    AssertTrue('the promoted child lists as a root', Found);
    Rows3 := 0;
    AssertEquals('sanity', 0, Rows3);
  finally
    Store.Free;
  end;
end;

procedure THarnessAppTest.TestSpyUnknownChildIsAnError;
begin
  { An unreachable child shows an error and leaves the parent view in place. }
  BuildWithStore;
  FApp.OnSpyFactory := OpenStubSpy;
  FSpyQueue := TTurnQueue.Create;
  FApp.ShowSpy('no-such-child');
  FApp.Step;
  AssertEquals('not in spy mode', '', FApp.SpiedSessionId);
  AssertTrue('the error is shown', FindText(ckError, 'could not open'));
end;

procedure THarnessAppTest.TestSpyActionsBarAbortsAndReleases;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  WorkspaceId: Integer;
  ChildId: string;
begin
  { In subagent mode the CTAs live in the WARM list box, not a separate teal
    actions bar: switching to that bar was what put the composer back on screen
    and made the mode look like it had ended. The keys are still a/r/p, read by
    the list, and routed through the same handler as the old bar so the takeover
    notice cannot diverge between them. }
  BuildWithStore;
  StoreCfg := Default(TStoreConfig);
  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateChildSession(WorkspaceId, FSession.View.SessionId, 1, 'child',
      ChildId, StoreErr);
  finally
    Store.Free;
  end;

  FRecording := TRecordingDriver.Create;
  FApp.Attach(FSession.View, FRecording);

  FApp.OnSpyFactory := OpenStubSpy;
  FSpyQueue := TTurnQueue.Create;
  FApp.ShowSpy(ChildId);
  FApp.Step;

  { The old assertion was that the actions bar replaced the compose. The point
    now is the opposite: the list stays up and there is no actions bar. }
  AssertTrue('the list stays up while spying', FApp.AgentListVisible);
  AssertFalse('no separate actions bar', FApp.Panel.ActionsMode);

  { The CTAs are CHORDED (ctrl+a/r/p). A bare letter must NOT trigger them: that
    was the accident this change removes - one stray 'a' aborting a child that is
    mid-work. Both halves are asserted, because "the chord works" and "the bare
    key does nothing" are different properties. }
  FInput.Push(Ch('a'));
  FApp.Step;
  AssertEquals('a bare letter does NOT abort', '', FRecording.AbortedId);

  FInput.Push(Ctrl('a'));
  FApp.Step;
  AssertEquals('ctrl+a aborts', ChildId, FRecording.AbortedId);

  FInput.Push(Ctrl('r'));
  FApp.Step;
  AssertEquals('ctrl+r releases', ChildId, FRecording.ReleasedId);
end;

{ TUI Startup: the connect lifecycle. }

procedure THarnessAppTest.TestNoSessionStartsIdle;
var
  Err: string;
begin
  { No session (an in-memory view has no id) and no driver: the app is idle, not
    connecting - it waits for the first prompt and creates nothing. }
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := '';
  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(40, 20);
  FInput := TInputSourceScripted.Create;
  FSession := THarnessSession.Open(Config, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  AssertFalse('no session id', FSession.View.HasSession);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, nil);
  AssertEquals('idle', Ord(csIdle), Ord(FApp.ConnState));
  { The idle frame is drawn by the panel's EMPTY STATE now (logo + first-run
    hints), not by a stream block: a notice block made the stream non-empty and
    suppressed the mark it was competing with. Assert the property that matters -
    nothing was added to the conversation - and that the state is ready. }
  AssertEquals('no conversation blocks on a fresh session', 0, BlockCount);
  { The state is asserted where it is observable: the panel's own suite pins
    psReady drawing a check, and TestEmptyTranscriptDrawsTheLogo pins the mark.
    Reaching into a private field from here would test the accessor, not the
    screen. }
end;

procedure THarnessAppTest.TestPaintBeforeConnectOrder;
var
  Err: string;
  FramesBefore: Integer;
begin
  { The composition root's order: surface + input + app (nil driver) paints a
    frame BEFORE any connect. The app is constructed and renders a frame while
    still idle; only Attach (the connect) moves it to connected. }
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := '';
  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(40, 20);
  FInput := TInputSourceScripted.Create;
  FSession := THarnessSession.Open(Config, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  { Construct with no driver: a frame exists, and no connect has happened. }
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, nil);
  FApp.Step;   // the first frame
  FramesBefore := BlockCount;
  { Same reason: nothing is SEEDED into the transcript before connecting. }
  AssertEquals('no conversation blocks before any connect', 0, FramesBefore);
  AssertEquals('still not connected', Ord(csIdle), Ord(FApp.ConnState));
  { Only now connect. }
  FApp.Attach(FSession.View, LocalDriver(FSession));
  AssertEquals('connected after Attach', Ord(csConnected), Ord(FApp.ConnState));
end;

procedure THarnessAppTest.TestSubmitWhileIdleWithoutHookIsRefused;
var
  Err: string;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := '';
  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(40, 20);
  FInput := TInputSourceScripted.Create;
  FSession := THarnessSession.Open(Config, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, nil);
  FApp.Step;
  { Idle with no connect hook: submitting must not raise; it is refused. }
  SubmitPrompt('hello');
  Pump(20);
  AssertTrue('refused', FindText(ckError, 'no session; cannot send'));
  AssertEquals('still idle', Ord(csIdle), Ord(FApp.ConnState));
end;

procedure THarnessAppTest.TestIdleSubmitTriggersConnect;
var
  Err: string;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := '';
  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(40, 20);
  FInput := TInputSourceScripted.Create;
  FSession := THarnessSession.Open(Config, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, nil);
  FApp.Step;
  { Wire the lazy hook to attach a driver, as the composition root does. The
    hook fires on the first submit and Attach flushes the held prompt. }
  FApp.OnNeedConnect := AttachLocal;
  FFake.AddChunk(TextDelta('ok'));
  FFake.AddChunk(FinishFrame('stop'));
  FFake.AddChunk(DoneFrame);
  SubmitPrompt('hi');
  Pump(300);
  AssertEquals('connected after the submit',
    Ord(csConnected), Ord(FApp.ConnState));
  AssertTrue('the prompt ran', FindText(ckAssistant, 'ok'));
end;

procedure THarnessAppTest.TestAttachMovesToConnectedAndRendersHistory;
var
  Err: string;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := '';
  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(40, 20);
  FInput := TInputSourceScripted.Create;
  FSession := THarnessSession.Open(Config, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, nil);
  AssertEquals('idle first', Ord(csIdle), Ord(FApp.ConnState));
  { Attach the driver: the app moves to connected and the idle frame is replaced
    by the (empty) transcript. }
  FApp.Attach(FSession.View, LocalDriver(FSession));
  AssertEquals('connected', Ord(csConnected), Ord(FApp.ConnState));
  AssertFalse('no idle frame', FindText(ckThinking, 'type a prompt'));
end;

procedure THarnessAppTest.TestFailConnectShowsErrorAndStaysUsable;
var
  Err: string;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := '';
  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(40, 20);
  FInput := TInputSourceScripted.Create;
  FSession := THarnessSession.Open(Config, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, nil);
  FApp.FailConnect('runtime did not start in time');
  AssertEquals('failed', Ord(csFailed), Ord(FApp.ConnState));
  AssertTrue('the error is shown',
    FindText(ckError, 'runtime did not start in time'));
  { The app stays usable: a quit still stops the loop. }
  FInput.Push(Ctrl('c'));
  AssertFalse('still steppable (quit is handled)', FApp.Step);
end;

procedure THarnessAppTest.TestSetConnectPhaseUpdatesTheFrame;
var
  Err: string;
  Cfg: THarnessSessionConfig;
begin
  { A connecting state needs a session that already has an id: open a store so
    the view creates one, then pass a nil driver. }
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(40, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  AssertTrue('has a session id', FSession.View.HasSession);
  FApp := THarnessApp.Create(FSurface, FInput, FSession.View, nil);
  AssertEquals('connecting', Ord(csConnecting), Ord(FApp.ConnState));
  FApp.SetConnectPhase('loading history');
  AssertTrue('the phase is shown', FindText(ckThinking, 'loading history'));
  AssertFalse('the old label is gone', FindText(ckThinking, 'connecting'));
end;

initialization
  RegisterTest(THarnessAppTest);
  Randomize;

end.
