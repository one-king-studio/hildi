unit test_harness_app;
{ fpcunit tests for hildegard.helper.harness.app: the application wires the
  session, widgets, turn queue, and approval modal together. Runs a real turn
  through the worker over the fake transport against an in-memory surface and a
  scripted input source. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, Generics.Collections,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  tui.base, tui.input,
  tui.surface, tui.widget,
  tui.widgets.chat,
  hildegard.helper.harness.turn, hildegard.helper.harness.session,
  hildegard.helper.harness.view,
  hildegard.helper.harness.driver, hildegard.helper.harness.driver.local,
  hildegard.helper.harness.app,
  hildegard.helper.harness.subagent.spy,
  hildegard.helper.session.protocol, hildegard.helper.session.client,
  hildegard.helper.store,
  hildegard.helper.session, llm_fakes,
  hildegard.helper.changes.store, changes.types, changes.store, changes.text;

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
    procedure StartTurn(const AText: string);
    procedure QueuePrompt(const AText: string);
    procedure Interrupt;
    procedure AnswerAsk(const AAskRef: string; const AChoice: TApprovalChoice);
    procedure AbortSubagent(const ASessionId: string);
    procedure ReleaseSubagent(const ASessionId: string);
    procedure Checkpoint;
    procedure Undo(ATurnId: Int64 = 0);
    procedure Redo(ATurnId: Int64 = 0);
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
    FRecording: TRecordingDriver;
    function OpenStubSpy(const ASessionId: string;
      const AConfig: TSessionClientConfig; out AError: string): TSubagentSpy;
    function SwitchTo(const ASessionId: string; out ASession: TSessionView;
      out ADriver: ISessionDriver; out AError: string): Boolean;
    procedure Build;
    procedure BuildWithStore;
    function Key(AKind: TKeyKind): TInputEvent;
    function Ch(const AText: string): TInputEvent;
    function Ctrl(const ACh: string): TInputEvent;
    procedure SubmitPrompt(const AText: string);
    function Pump(AMax: Integer): Boolean;
    function MakeAsk: TApprovalAsk;
    function BlockCount: Integer;
    function BlockKind(AIndex: Integer): TChatKind;
    function BlockLabel(AIndex: Integer): string;
    function BlockText(AIndex: Integer): string;
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
    { EVERY command RunCommand dispatches must be listed in the palette. RunCommand
      is reachable only through the palette, and with no match the palette declines
      the key and the composer sends the text as a PROMPT - which is how /undo,
      /redo and /revert were unreachable and got sent to the model verbatim. }
    procedure TestEveryDispatchedCommandIsOfferedByThePalette;
    { Escape dismisses the palette and leaves the typed '/' alone, so an ordinary
      prompt may begin with a slash. It must STAY dismissed while the box holds a
      lone '/token', or the list pops back on the next keystroke. }
    procedure TestEscapeDismissesThePaletteSoSlashCanBeAPrompt;
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
    procedure TestCoarseScrollTargetMapsSegments;
    procedure TestShouldTrimHistory;
    procedure TestSidebarTogglesWithCtrlD;
    procedure TestSidebarRendersItsRows;
    { The list moved into the composer's place; keys must still reach it, and
      Enter on a row must open that child's spy. This is the one behaviour I
      shipped without proof. }
    procedure TestSidebarRoutesKeysAndEntersTheSpy;
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
    set HILDEGARD_MAX_CONTEXT_TOKENS). }
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

function THarnessAppTest.BlockText(AIndex: Integer): string;
begin
  Result := FApp.Panel.Stream.ItemAt(AIndex).Text;
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
  AssertEquals('session id on the left', Copy(FSession.View.SessionId, 1, 12),
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
    Copy(FSession.View.SessionId, 1, 12), FApp.Panel.HeaderLeft);

  { An extracted title is shown instead of the id. Set it directly, then trigger
    a header refresh the way a completed turn does (UpdateStats -> UpdateHeader).
    A no-op status render is not enough, so submit a turn. }
  AssertTrue('set title', FSession.View.Store.SetSessionTitle(
    FSession.View.SessionId, 'Fix the drain', Err));
  FFake.AddResponse([TextDelta('hi'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  AssertEquals('the title names the header', 'Fix the drain',
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
    real glyph in the header, not '?'. }
  BuildWithStore;
  Title := 'Fix the drain ' + #$E2#$80#$94 + ' phase 2';
  AssertTrue('set title', FSession.View.Store.SetSessionTitle(
    FSession.View.SessionId, Title, Err));
  FFake.AddResponse([TextDelta('hi'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  AssertEquals('the title is in the header', Title, FApp.Panel.HeaderLeft);
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
  Dispatched: array[0..4] of string =
    ('checkpoint', 'sessions', 'undo', 'redo', 'revert');
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
  I: Integer;
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
  { The toolbar carries the subagent toggle hint. }
  AssertEquals('hints', 'shift+enter newline · ctrl+d subagents',
    FApp.HintsText);
  AssertFalse('hints are not in the status bar',
    Pos('newline', FApp.StatusText) > 0);
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
    window, AND the viewport is at the bottom. }
  AssertFalse('no older pages: no trim', ShouldTrimHistory(0, 100000, 0, 500, 500));
  AssertFalse('recent scroll: no trim', ShouldTrimHistory(2, 5000, 0, 500, 500));
  AssertFalse('scrolled up (not at the bottom): no trim',
    ShouldTrimHistory(2, 100000, 0, 100, 500));
  AssertTrue('idle + at the bottom: trim',
    ShouldTrimHistory(2, 100000, 0, 500, 500));
  AssertTrue('within 2 rows of the bottom still trims',
    ShouldTrimHistory(2, 100000, 0, 498, 500));
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
      AssertEquals('thinking while busy', 'thinking', FApp.StateText);
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
  AssertEquals('ready state', 'ready', FApp.StateText);
end;

procedure THarnessAppTest.TestErrorStateAfterAFailedTurn;
begin
  Build;
  FFake.FailNetwork := True;
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));
  AssertEquals('error state', 'error', FApp.StateText);
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
    AssertEquals('prompt shown', 'press esc again to cancel', FApp.StateText);

    FInput.Push(Key(kkEscape));
    FApp.Step;
    AssertFalse('second escape disarms', FApp.InterruptArmed);
    AssertEquals('cancelling', 'cancelling', FApp.StateText);

    { The cancel is seen at the worker's next loop boundary; wait for idle. }
    for I := 1 to 600 do
    begin
      FApp.Step;
      if not FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertEquals('cancelled state', 'cancelled', FApp.StateText);
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

    AssertEquals('cancelled', 'cancelled', FApp.StateText);
    AssertEquals('the prompt came back', 'hello',
      string(FApp.Panel.Compose.Text));
    AssertEquals('the aborted turn left no block', 0, BlockCount);
  finally
    Slow.Free;
  end;
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

procedure THarnessAppTest.TestSidebarTogglesWithCtrlD;
begin
  Build;
  AssertFalse('hidden by default', FApp.SidebarVisible);
  FInput.Push(Ctrl('d'));
  Pump(4);
  AssertTrue('shown after ctrl+d', FApp.SidebarVisible);
  FInput.Push(Ctrl('d'));
  Pump(4);
  AssertFalse('hidden again', FApp.SidebarVisible);
end;

procedure THarnessAppTest.TestSidebarRendersItsRows;
var
  Y: Integer;
  Found: Boolean;
begin
  { The regression this guards: the sidebar was created and toggled but never
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
  AssertTrue('the sidebar row is rendered', Found);
end;

procedure THarnessAppTest.TestSidebarRoutesKeysAndEntersTheSpy;
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
    a green TSidebar unit test proves nothing about it.

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
  AssertTrue('the list is up', FApp.SidebarVisible);

  { Keys must reach the list through the overlay while it is visible. Down is
    handled by TSidebar; if routing were broken this would be swallowed and the
    selection would never move. }
  FInput.Push(Key(kkDown));
  FApp.Step;

  { Enter opens that child's spy. }
  FInput.Push(Key(kkEnter));
  FApp.Step;
  FApp.Step;
  AssertEquals('enter opened the child spy', ChildId, FApp.SpiedSessionId);
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
    sidebar has a row. Entering it shows the child's transcript and the header
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
  { In spy mode the compose gives way to the actions bar; pressing 'a' aborts and
    'r' releases the child through the driver. }
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

  { A driver that records the subagent commands (the local one is a no-op). }
  FRecording := TRecordingDriver.Create;
  FApp.Attach(FSession.View, FRecording);

  FApp.OnSpyFactory := OpenStubSpy;
  FSpyQueue := TTurnQueue.Create;
  FApp.ShowSpy(ChildId);
  FApp.Step;

  AssertTrue('the actions bar replaces the compose', FApp.Panel.ActionsMode);

  FInput.Push(Ch('a'));
  FApp.Step;
  AssertEquals('abort reached the driver', ChildId, FRecording.AbortedId);

  FInput.Push(Ch('r'));
  FApp.Step;
  AssertEquals('release reached the driver', ChildId, FRecording.ReleasedId);
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
  AssertTrue('an idle frame is drawn', BlockCount >= 1);
  AssertTrue('it invites a prompt',
    FindText(ckThinking, 'type a prompt to start'));
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
  AssertTrue('a frame is on screen before any connect', FramesBefore >= 1);
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
