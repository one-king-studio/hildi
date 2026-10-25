unit hildegard.helper.harness.app;
{ The Harness UI application: it builds the widget tree (conversation, status,
  prompt), drains the turn queue each Step, routes approval asks to a modal, and
  runs one worker per submitted prompt. It is the only unit besides the example
  that knows both the harness layer and the widgets; it does not link a terminal.

  The UI thread never blocks on the worker except during teardown. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Generics.Collections,
  hildegard.helper.llm, hildegard.helper.approval,
  tui.base, tui.input,
  tui.surface, tui.widget,
  tui.widgets.text, tui.widgets.chat,
  tui.widgets.compose, tui.widgets.chatpanel,
  tui.widgets.palette,
  tui.widgets.approvalmodal,
  tui.widgets.panel, tui.theme,
  tui.app, hildegard.helper.harness.turn,
  hildegard.helper.harness.driver, hildegard.helper.harness.view,
  hildegard.helper.store,
  hildegard.helper.harness.stats, hildegard.helper.session,
  hildegard.helper.replymeta,
  tui.widgets.sessionsmodal,
  tui.widgets.actions,
  hildegard.helper.harness.subagent, hildegard.helper.harness.subagent.spy,
  tui.widgets.sidebar, tui.widgets.list,
  hildegard.helper.session.protocol, hildegard.helper.session.client,
  hildegard.helper.changes.store, changes.types, changes.store, changes.summary,
  hildegard.helper.utf8;

type
  { Where the app is in the startup sequence. csIdle waits for the first prompt
    (no session/runtime yet); csConnecting draws a frame while a connect is in
    progress; csConnected is the normal live state; csFailed shows an in-app
    error and stays usable. }
  TConnState = (csIdle, csConnecting, csConnected, csFailed);

  { Fired when the app is idle (no session/runtime) and the operator submits the
    first prompt: the composition root creates the session, spawns the runtime,
    and calls Attach (or FailConnect). Set by the launcher that wants a lazy
    start; when unset, an idle app cannot send. }
  TConnectEvent = procedure of object;

  { Opens a different session for the app: returns its view and driver, or False
    + AError. The callback retains ownership of both (the app holds references
    only). Wired by the composition root, which can spawn a runtime. }
  TSwitchSessionEvent = function(const ASessionId: string;
    out ASession: TSessionView; out ADriver: ISessionDriver;
    out AError: string): Boolean of object;

  { Opens a spy over a child session. Defaults to TSubagentSpy.Open; overridable
    so a test can enter spy mode without a live child socket. }
  TSpyFactoryEvent = function(const ASessionId: string;
    const AConfig: TSessionClientConfig; out AError: string): TSubagentSpy
    of object;

  { Builds the tree and owns the TTuiApp and the current worker. The session is
    owned by the caller and must outlive the app. }
  THarnessApp = class
  private
    FSurface: ISurface;
    FInput: IInputSource;
    FSession: TSessionView;
    FDriver: ISessionDriver;
    { The startup lifecycle. While csConnecting there is no driver; the app draws
      a connecting frame and refuses commands. Attach moves to csConnected;
      FailConnect to csFailed (an in-app error, still quittable). }
    FConnState: TConnState;
    FConnectPhase: string;
    FConnectError: string;
    FOnNeedConnect: TConnectEvent;
    { Open a different session (the /sessions modal's Enter): the composition
      root's hook. Unset => switching is refused with a status line. }
    FOnSwitchSession: TSwitchSessionEvent;
    { Opens a spy over a child session; nil => TSubagentSpy.Open. }
    FSpyFactory: TSpyFactoryEvent;
    { A prompt submitted while idle, held until Attach delivers the driver. }
    FPendingSubmit: string;
    FApp: TTuiApp;
    FTheme: TTheme;
    FPanel: TChatPanel;
    FBusy: Boolean;
    FModal: TApprovalModal;
    { The /sessions modal (nil when closed) and its wrap. }
    FSessionsModal: TSessionsModal;
    FSessionsShown: Boolean;
    { A deferred close: the modal's Enter is dispatched from inside the modal, so
      popping the plane there would free the widget mid-dispatch. The swap runs
      inline; the pop waits for the next Step/OnLoop. }
    FCloseSessions: Boolean;
    FPendingAskRef: string;
    FCloseModal: Boolean;
    FAskQueue: array of TTurnEvent;
    FStatusText: string;
    FStatsText: string;
    FHintsText: string;
    FStateLabel: string;
    FInterruptPending: Boolean;
    FInterruptAt: Int64;
    { The blocks of the turn in flight, so deltas land in the right one. }
    FAssistant: TChatItem;
    { The assistant reply's raw text and the streaming frontmatter suppressor,
      so a leading block is withheld from the display until it closes (the body
      then renders normally). }
    FAssistantRaw: string;
    FAssistantSupp: TFrontMatterSuppressor;
    FThought: TChatItem;
    { Live tool blocks keyed by tool-call id, so a parallel batch's streamed
      output lands in the right block. Non-owning: the stream owns the items. }
    FToolBlocks: TDictionary<string, TChatItem>;
    { Streamed tool output buffered per call and appended once per frame, so a
      chatty command costs one layout, not one per chunk. Flushed by
      FlushToolOutput. }
    FToolPending: TDictionary<string, string>;
    { The reasoning phase's duration for the live thought block, set by
      teReasoningDone and consumed when the block settles. }
    FThoughtMs: Int64;
    { The submitted prompt and its block, so an early cancel can undo them. }
    FUserPrompt: string;
    FUserBlock: TChatItem;
    { Subagents: the roster (fed from ekSubagent), the sidebar plane, and — in
      spy mode — the spied child and its observer. }
    FRoster: TSubagentRoster;
    FSidebar: TSidebar;
    FSidebarShown: Boolean;
    FSpy: TSubagentSpy;
    FSpyId: string;
    FAskRefIsChild: Boolean;
    { Back-pagination: how many archived pages are shown above the boundary. The
      scroll anchor is held by the stream itself (PreserveAnchor), so the visible
      content does not shift when a page is prepended. }
    FOlderPages: Integer;
    { True once the window has reached the head of the session: no older page
      exists, so the scroll-to-top trigger must not fire again (no endless
      "loading older messages"). Reset when the window is rebuilt from a fresh
      tail. }
    FAtHead: Boolean;
    { The 0-based index of the first message the window currently holds (0 when
      the whole session is loaded), so the coarse scrubber can map a session
      fraction to a row within the loaded window. }
    FWindowStart: Integer;
    { Passive trim: the monotonic ms of the last scroll. When the operator has
      not scrolled for TrimIdleMs and the viewport is at the bottom, older loaded
      pages are unloaded so a long session's memory stays bounded. }
    FLastScrollMs: Int64;
    { The left-border paginator (coarse scroll) drag: the last hit row. }
    FPageDragging: Boolean;
    FPageDragRow: Integer;
    FPageCount: Integer;
    { The checkpoint's ambient block, so the app can find the page boundary (the
      block sits exactly at the boundary between the archived and current pages).
      Nil when there is no checkpoint. }
    FCheckpointBlock: TChatItem;
    { Queued prompts shown as 'Queued' boxes at the end of the stream, removed
      when they are injected as a real user turn. }
    FQueuedBlocks: array of TChatItem;
    { The driver's dropped-event count at the last check, so the app warns the
      operator once when streamed output was dropped (the mailbox bound). }
    FLastDropped: Int64;
    function BuildTree: TWidget;
    function GetSessionId: string;
    procedure ResetWindow;
    procedure Submit(const AText: string);
    procedure DrainQueue;
    procedure FlushToolOutput;
    procedure HandleTurnEvent(const E: TTurnEvent);
    procedure EnqueueAsk(const E: TTurnEvent);
    procedure ShowNextAsk;
    procedure ShowApproval(const E: TTurnEvent);
    procedure OnApprovalChosen(const AChoice: TApprovalChoice);
    procedure CloseModal;
    { The /sessions modal: open it (load the rows), refresh after an action, and
      close it. }
    procedure ShowSessions;
    procedure RefreshSessions;
    procedure CloseSessions;
    procedure OnSessionAction(const ASessionId: string; AAction: TSessionAction);
    procedure OnSessionRename(const ASessionId, ANewTitle: string);
    { Reconcile the app's modal state with the plane state: pop a requested close,
      and clear FSessionsModal when the plane is gone (an unhandled Escape pops
      it in TTuiApp). Called each Step/OnLoop, like CloseModal. }
    procedure SyncSessionsModal;
    { Subagents: feed the roster, toggle/show the sidebar, spy on a child. }
    procedure HandleSubagentEvent(const E: TTurnEvent);
    { Show a queued prompt (a violet 'Queued' box) at the end of the stream. }
    procedure ShowQueued(const AText: string);
    procedure ToggleSidebar(Sender: TObject);
    procedure LayoutSidebar;
    procedure OnSidebarSelect(const ASessionId: string);
    procedure LeaveSpy;
    { The spied child's display name: its roster label, else its id prefix. }
    function SpyLabel: string;
    { Render the child's transcript tail into the panel (the spy view). }
    procedure RenderSpyHistory(const ASessionId: string);
    { The spy's CTA actions bar (abort / release / leave). }
    procedure SetupSpyActions;
    procedure OnSpyAction(AIndex: Integer);
    procedure DrainSpy;
    procedure SendSubagentCommand(AKind: TSessionCommandKind;
      const ASessionId: string);
    function SidebarShown: Boolean;
    function SpyId: string;
    procedure FinishTurn(AState: TPanelState; const ALabel: string);
    procedure SetState(AKind: TPanelState; const ALabel: string);
    { The compose's primary-action hint, from the run state and the box. }
    procedure UpdateCta;
    { Settle the streaming thinking block into a persisted "Thought" block. }
    procedure FinalizeThinking;
    { End the streamed assistant body: the open markdown tail becomes the final
      block, so the last block is parsed and styled like the rest. Called
      wherever the live assistant block stops growing. }
    procedure FinalizeAssistant;
    { Append a tool result to its block; no leading gap when the block has no
      body yet. The result speaks for itself (a tool adds its own call context
      when that helps), so no [ok]/[failed] prefix is added. }
    procedure AppendToolResult(ABlock: TChatItem; const AText: string);
    { A tool call whose result never arrived (interrupted, or a crash on resume)
      still gets an acknowledgement, so no tool block is ever blank. }
    procedure SettleOpenTool;
    { End a completed loop with its metrics; a zero/absent turn draws nothing. }
    procedure AddTurnDivider;
    { The turn summary: what this turn wrote, as one block under the divider.
      Reads the NET rows only, so a file edited twice shows its net change and a
      file edited then reverted shows nothing at all. }
    procedure AddTurnChanges(ATurnId: Int64);
    { Add a stored assistant reply to the stream: strip a leading frontmatter
      block and draw it as the title/keyword header (a resume path, so a
      previously-stored malformed block is still cleaned up). }
    procedure AddAssistantBlock(const AContent: string);
    { Put text at the front of the compose box, keeping whatever is typed. }
    procedure PrependCompose(const AText: string);
    { Undo the current turn's UI after an early cancel and restore the prompt. }
    procedure RollBackEarlyCancel;
    { Drop the in-flight assistant/thinking blocks of a pending response that was
      never persisted, so the live view matches a resumed session. }
    procedure RollBackPendingResponse;
    { Show a user prompt (the turn's own, or a queued one that superseded the
      response that was streaming), dropping the response it superseded. }
    procedure HandleUserMessage(const AText: string);
    { The messages panel's top border: the session id (left) and the session
      stats (right). }
    procedure UpdateHeader;
    procedure UpdateStats;
    procedure HandleEscape(Sender: TObject);
    function ComposeIsEmpty: Boolean;
    procedure InterruptTurn;
    procedure CheckInterruptWindow;
    procedure AppendError(const AText: string);
    procedure RenderHistory;
    procedure SyncBusy;
    procedure OnLoop;
    procedure Invalidate(Sender: TObject);
    { The transcript reached the top: prepend the next archived page. }
    procedure NeedOlderHistory(Sender: TObject);
    { Passive trim: unload the older loaded pages once the operator has been away
      from them (see TrimIdleMs), so a long session stays bounded. }
    procedure TrimHistory;
    { The left-border paginator: a press or drag scrolls to that page. }
    function PageScrub(const E: TInputEvent): Boolean;
    { The view scrolled: recompute which page the viewport is on. }
    procedure StreamScrolled(Sender: TObject);
    { The continuation page: one more than the session's checkpoint count. }
    function PageNumber: Integer;
    { The compose changed: show/hide and filter the command palette. }
    procedure ComposeChanged(Sender: TObject);
    { Run a command from the palette. }
    procedure RunCommand(const AName: string);
    function DefaultCommands: TCommandArray;
    function GetModalActive: Boolean;
    function GetPromptActive: Boolean;
    procedure Quit(Sender: TObject);
    { Draw the frame for the current connect state (connecting / failed). }
    procedure RenderConnState;
    function GetConnState: TConnState;
  public
    constructor Create(const ASurface: ISurface; const AInput: IInputSource;
      ASession: TSessionView; ADriver: ISessionDriver;
      AMode: TThemeMode = tmAuto; ALightDetected: Boolean = False);
    destructor Destroy; override;

    { One iteration: drain the queue, resolve any answered approval modal, then
      run TTuiApp.Step. Returns False once stopped. }
    function Step: Boolean;
    { Clock-driven loop: wait on input, drain the queue each iteration, and render
      on the frame cadence while a turn is in flight. }
    procedure Run(ACheckStop: TStopCheck = nil);
    procedure Stop;

    { Quit mid-turn: deny pending approvals, join the worker, restore state. }
    procedure CancelTurn;

    { Hand the app its session and driver after the connect succeeded; moves
      csConnecting -> csConnected and renders the transcript tail. }
    procedure Attach(const ASession: TSessionView; const ADriver: ISessionDriver);
    { Report a failed connect; moves to csFailed and shows AError. }
    procedure FailConnect(const AError: string);
    { Enter the idle state: no session/runtime yet, waiting for the first prompt.
      The launcher sets OnNeedConnect so a submit can trigger the connect. }
    procedure BeginIdle;
    { A phase label for the connecting frame (e.g. 'connecting', 'loading
      history'), so the wait is honest. }
    procedure SetConnectPhase(const APhase: string);
    { Enter on a /sessions row: open that session. Refuses when busy, when there
      is no hook, or when the hook fails. The swap happens inline; the modal is
      popped on the next Step (it is the caller). }
    procedure SwitchSession(const ASessionId: string);
    { Enter spy mode on a child session: rebuild the panel to show the child's
      transcript and its live stream, mark the header, and hide the composer.
      Escape leaves. Public so the composition root and tests can drive it. }
    procedure ShowSpy(const ASessionId: string);

    property ConnState: TConnState read GetConnState;
    { The lazy-start hook: called on the first submit when idle. }
    property OnNeedConnect: TConnectEvent read FOnNeedConnect
      write FOnNeedConnect;
    { The open-a-session hook (the /sessions modal's Enter). }
    property OnSwitchSession: TSwitchSessionEvent read FOnSwitchSession
      write FOnSwitchSession;
    { The spy-open hook; unset uses TSubagentSpy.Open. }
    property OnSpyFactory: TSpyFactoryEvent read FSpyFactory write FSpyFactory;
    { The active session's id, '' when there is none (an idle lazy app). }
    property SessionId: string read GetSessionId;

    property Busy: Boolean read FBusy;
    property PromptActive: Boolean read GetPromptActive;
    property ModalActive: Boolean read GetModalActive;
    { The stream, for tests: block count, kinds and text. }
    property Panel: TChatPanel read FPanel;
    { The status bar's left part (the workspace). }
    property StatusText: string read FStatusText;
    { The status bar's right part (the latest turn's metrics). }
    property StatsText: string read FStatsText;
    { The toolbar's left part: the run state's label. }
    property StateText: string read FStateLabel;
    { The toolbar's right part: the interaction hints. }
    property HintsText: string read FHintsText;
    { True once the first Escape has armed the interrupt. }
    property InterruptArmed: Boolean read FInterruptPending;
    { Whether the subagent sidebar is shown. }
    property SidebarVisible: Boolean read SidebarShown;
    { The spied child's session id, '' when not spying. }
    property SpiedSessionId: string read SpyId;
    function ConversationText: string;
  end;

{ The coarse-scroll target: the message index (0-based, oldest = 0) a scrubber
  segment points to in a session of AMessageCount messages. Segment 0 is the
  oldest, ASegCount-1 the newest. Pure, so the mapping is testable without the
  widgets. }
function CoarseScrollTarget(ASeg, ASegCount, AMessageCount: Integer): Integer;

{ Whether the passive trim should run: older pages are loaded, the operator has
  not scrolled for ATickMs since ALastScrollMs, and the viewport is at the
  bottom (AScrollY >= AMaxScroll - 2). Pure, so the policy is testable. }
function ShouldTrimHistory(AOlderPages: Integer; ANowMs, ALastScrollMs: Int64;
  AScrollY, AMaxScroll: Integer): Boolean;

implementation

const
  { How many files a collapsed turn summary names before it tails off. }
  TurnSummaryMaxFiles = 8;

  { The interaction hints live in the CTA strip, which acts as a context
    toolbar; the status bar is reserved for the workspace and the metrics. }
  { The toolbar hints, right-aligned above the composer. }
  CtaHints = 'shift+enter newline · ctrl+b subagents';
  { How long the first Escape stays armed before the interrupt prompt expires. }
  InterruptWindowMs = 2000;
  { The first frame loads at most this many messages of the active window (the
    tail). Older messages load on scroll-up (the window), so the first paint is
    bounded by the window, not the session. }
  StartupTailCount = 200;
  { A back-pagination page size, in messages. }
  HistoryPageSize = 200;
  { Passive trim: after this long without a scroll, unload the older pages that
    the operator has left behind, so a long session's TUI memory stays bounded.
    Only trims when the viewport is at the bottom (the operator is not reading
    the older region). }
  TrimIdleMs = 30000;

type
  { A yes/no query, e.g. "may I quit?". }
  TQueryEvent = function: Boolean of object;

  { Wraps the root so global keys (Ctrl-C/Ctrl-D quit, Escape interrupts) are
    handled before the prompt, which otherwise consumes every printable
    character. Ctrl-C is refused while the compose holds text, so it can never
    discard typed input. Extends TSingleChild so Advance/Animating reach the
    tree. }
  TAppShell = class(TSingleChild)
  private
    FOnQuit: TNotifyEvent;
    FOnEscape: TNotifyEvent;
    FCanQuit: TQueryEvent;
    FOnToggleSidebar: TNotifyEvent;
  public
    constructor Create(AChild: TWidget; AOnQuit, AOnEscape: TNotifyEvent;
      ACanQuit: TQueryEvent);
    procedure SetSidebarToggle(AHandler: TNotifyEvent);
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  { Composites the floating sidebar over the app: the base (the chat panel) is
    drawn first, the sidebar on top when it is visible. Input goes to the sidebar
    while it is shown (it is the focused overlay); otherwise to the base. Extends
    TSingleChild so the base's Advance/Animating reach the app loop. }
  TSidebarOverlay = class(TSingleChild)
  private
    FSidebar: TWidget;
  public
    constructor Create(AChild, ASidebar: TWidget);
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

function RoleLabel(ARole: TChatRole): string;
begin
  case ARole of
    crUser:
      Result := '> ';
    crTool:
      Result := '[tool result] ';
    crSystem:
      Result := '[system] ';
  else
    Result := '';
  end;
end;

function CoarseScrollTarget(ASeg, ASegCount, AMessageCount: Integer): Integer;
begin
  { The coarse scrubber has one segment per page (the checkpoint count, read
    from the store). This maps a segment to a 0-based message index in a session
    of AMessageCount messages: segment 0 is the oldest message, ASegCount-1 the
    newest. The counts are exact (the store), so no row-height estimate is
    needed. Pure, so the mapping is unit-testable. }
  Result := 0;
  if AMessageCount <= 1 then
    Exit;
  if ASeg <= 0 then
    Exit(0);
  if (ASegCount <= 1) or (ASeg >= ASegCount - 1) then
    Exit(AMessageCount - 1);
  Result := (ASeg * (AMessageCount - 1)) div (ASegCount - 1);
end;

function ShouldTrimHistory(AOlderPages: Integer; ANowMs, ALastScrollMs: Int64;
  AScrollY, AMaxScroll: Integer): Boolean;
begin
  Result := (AOlderPages > 0) and
    (ANowMs - ALastScrollMs >= TrimIdleMs) and
    (AScrollY >= AMaxScroll - 2);
end;

{ TAppShell }

constructor TAppShell.Create(AChild: TWidget; AOnQuit, AOnEscape: TNotifyEvent;
  ACanQuit: TQueryEvent);
begin
  inherited Create(AChild);
  FOnQuit := AOnQuit;
  FOnEscape := AOnEscape;
  FCanQuit := ACanQuit;
end;

procedure TAppShell.SetSidebarToggle(AHandler: TNotifyEvent);
begin
  FOnToggleSidebar := AHandler;
end;

function TAppShell.HandleEvent(const E: TInputEvent): Boolean;
begin
  if (E.Kind = ikKey) and (E.Key.Kind = kkChar) and (moCtrl in E.Key.Mods) then
  begin
    if (E.Key.Ch = 'b') or (E.Key.Ch = 'B') then
    begin
      if Assigned(FOnToggleSidebar) then
        FOnToggleSidebar(Self);
      Exit(True);
    end;
    if (E.Key.Ch = 'c') or (E.Key.Ch = 'C') then
    begin
      { Ctrl-C clears a non-empty compose; only an empty one quits. }
      if Assigned(FCanQuit) and not FCanQuit() then
      begin
        inherited HandleEvent(E);
        Exit(True);
      end;
      if Assigned(FOnQuit) then
        FOnQuit(Self);
      Exit(True);
    end;
    if (E.Key.Ch = 'd') or (E.Key.Ch = 'D') then
    begin
      if Assigned(FOnQuit) then
        FOnQuit(Self);
      Exit(True);
    end;
  end;
  if (E.Kind = ikKey) and (E.Key.Kind = kkEscape) then
  begin
    if Assigned(FOnEscape) then
      FOnEscape(Self);
    Exit(True);
  end;
  Result := inherited HandleEvent(E);
end;

{ TSidebarOverlay }

constructor TSidebarOverlay.Create(AChild, ASidebar: TWidget);
begin
  inherited Create(AChild);
  FSidebar := ASidebar;
end;

procedure TSidebarOverlay.Render(const S: ISurface);
begin
  inherited Render(S);
  if (FSidebar <> nil) and FSidebar.Visible then
    FSidebar.Render(S);
end;

function TSidebarOverlay.HandleEvent(const E: TInputEvent): Boolean;
begin
  { While the sidebar is shown it is the focused overlay, but global keys
    (Ctrl+B/Ctrl+C, Escape) still fall through to the base shell. }
  if (FSidebar <> nil) and FSidebar.Visible and FSidebar.HandleEvent(E) then
    Exit(True);
  Result := inherited HandleEvent(E);
end;

constructor THarnessApp.Create(const ASurface: ISurface; const AInput: IInputSource;
  ASession: TSessionView; ADriver: ISessionDriver; AMode: TThemeMode;
  ALightDetected: Boolean);
begin
  inherited Create;
  FSurface := ASurface;
  FInput := AInput;
  FSession := ASession;
  FDriver := ADriver;
  FTheme := SelectTheme(AMode, ALightDetected);
  FRoster := TSubagentRoster.Create;
  FToolBlocks := TDictionary<string, TChatItem>.Create;
  FToolPending := TDictionary<string, string>.Create;
  FApp := TTuiApp.Create(ASurface, AInput, BuildTree);
  FApp.InputHook := PageScrub;
  FApp.ScreenBg := FTheme.Bg;
  { With no driver: if there is a session (named/resumed) we are connecting and
    wait for Attach; if there is no session, the app is idle and waits for the
    first prompt (the launcher wires OnNeedConnect). With a driver it is live
    from the first frame (the old behaviour). }
  if FDriver <> nil then
  begin
    FConnState := csConnected;
    RenderHistory;
    SetState(psReady, 'ready');
    UpdateStats;
  end
  else if (FSession <> nil) and FSession.HasSession then
  begin
    FConnState := csConnecting;
    FConnectPhase := 'connecting';
    RenderConnState;
  end
  else
  begin
    FConnState := csIdle;
    RenderConnState;
  end;
end;

function THarnessApp.GetConnState: TConnState;
begin
  Result := FConnState;
end;

procedure THarnessApp.SetConnectPhase(const APhase: string);
begin
  if FConnState <> csConnecting then
    Exit;
  FConnectPhase := APhase;
  RenderConnState;
end;

procedure THarnessApp.RenderConnState;
begin
  { Replace the stream with the state's frame. While connecting the panel is
    otherwise empty, so this is the first frame the operator sees. }
  FPanel.Stream.Clear;
  case FConnState of
    csIdle:
      begin
        FPanel.Stream.Add(ckThinking, '',
          'type a prompt to start a session');
        SetState(psReady, 'idle');
      end;
    csConnecting:
      begin
        FPanel.Stream.Add(ckThinking, '', FConnectPhase + '…');
        SetState(psThinking, FConnectPhase);
      end;
    csFailed:
      begin
        FPanel.Stream.Add(ckError, '',
          'connection failed: ' + FConnectError);
        SetState(psError, 'failed');
      end;
  else
    ;
  end;
  FApp.Invalidate;
end;

procedure THarnessApp.Attach(const ASession: TSessionView;
  const ADriver: ISessionDriver);
var
  Pending: string;
begin
  FSession := ASession;
  FDriver := ADriver;
  FConnState := csConnected;
  { A fresh window for this session: no older pages, not at head, no stale live
    blocks. Shared with SwitchSession, which rebuilds the transcript the same
    way. }
  ResetWindow;
  RenderHistory;
  SetState(psReady, 'ready');
  UpdateStats;
  { Flush a prompt submitted while idle: it is the prompt the operator typed to
    trigger this connect. }
  Pending := FPendingSubmit;
  FPendingSubmit := '';
  if Pending <> '' then
    Submit(Pending);
end;

procedure THarnessApp.ResetWindow;
begin
  { Replace the transcript with a fresh window for the active session. }
  FAtHead := False;
  FOlderPages := 0;
  FWindowStart := 0;
  FAssistant := nil;
  FAssistantRaw := '';
  FAssistantSupp := Default(TFrontMatterSuppressor);
  FThought := nil;
  FThoughtMs := 0;
  FToolBlocks.Clear;
  FToolPending.Clear;
  FCheckpointBlock := nil;
  FQueuedBlocks := nil;
  FUserBlock := nil;
  FPanel.Stream.Clear;
end;

function THarnessApp.GetSessionId: string;
begin
  if FSession <> nil then
    Result := FSession.SessionId
  else
    Result := '';
end;

procedure THarnessApp.SwitchSession(const ASessionId: string);
var
  NewSession: TSessionView;
  NewDriver: ISessionDriver;
  Err: string;
begin
  if ASessionId = '' then
    Exit;
  { Activating the current session is a no-op beyond closing the modal. }
  if (FSession <> nil) and (ASessionId = FSession.SessionId) then
  begin
    if FSessionsShown then
      FCloseSessions := True;
    Exit;
  end;
  { A turn in flight does not block the switch: closing the old driver DETACHES
    from its runtime (which keeps the turn running and persists it), so switching
    away loses only the live view, not the work. The new session starts fresh. }
  NewSession := nil;
  NewDriver := nil;
  if not Assigned(FOnSwitchSession) then
  begin
    AppendError('this build cannot switch sessions');
    Exit;
  end;
  if not FOnSwitchSession(ASessionId, NewSession, NewDriver, Err) then
  begin
    AppendError('could not open session: ' + Err);
    Exit;
  end;
  { Swap the active session and driver. The callback retains ownership of both,
    so the app holds references only; it closes the old driver (detaching from
    the old runtime, whose turn keeps running) before adopting the new one.
    CancelTurn also clears the busy state, since the old turn is no longer ours
    to show. }
  CancelTurn;
  FSession := NewSession;
  FDriver := NewDriver;
  FConnState := csConnected;
  ResetWindow;
  RenderHistory;
  SetState(psReady, 'ready');
  UpdateStats;
  { The modal raised this from inside its own event dispatch, so pop it on the
    next Step rather than freeing it mid-dispatch. }
  if FSessionsShown then
    FCloseSessions := True;
end;

procedure THarnessApp.BeginIdle;
begin
  { No session/runtime yet: the operator can quit without any side effect. }
  FConnState := csIdle;
  RenderConnState;
end;

procedure THarnessApp.FailConnect(const AError: string);
begin
  FConnState := csFailed;
  FConnectError := AError;
  RenderConnState;
end;

destructor THarnessApp.Destroy;
begin
  CancelTurn;
  FSpy.Free;
  FSidebar.Free;
  FRoster.Free;
  FToolBlocks.Free;
  FToolPending.Free;
  FApp.Free;
  inherited Destroy;
end;

procedure THarnessApp.CancelTurn;
begin
  { Releasing the driver detaches from the runtime (which keeps the turn) or, on
    the local driver, cancels and joins the worker. }
  if FDriver <> nil then
    FDriver.Close;
  FBusy := False;
end;

function THarnessApp.BuildTree: TWidget;
var
  Shell: TAppShell;
  Title: string;
begin
  { While connecting there may be no session yet; use a placeholder title and an
    empty status until Attach supplies them. }
  if FSession <> nil then
    Title := 'Hildegard · ' + FSession.Model
  else
    Title := 'Hildegard';
  FPanel := TChatPanel.Create(FTheme, Title, CtaHints);
  FPanel.Stream.OnToggle := Invalidate;
  FPanel.Stream.OnChange := Invalidate;
  FPanel.Stream.OnNeedOlder := NeedOlderHistory;
  FPanel.Stream.OnScroll := StreamScrolled;
  FPanel.Compose.OnSubmit := Submit;
  FPanel.Compose.OnChange := ComposeChanged;
  { The command palette: registered commands, shown when the compose starts
    with '/'. }
  FPanel.Palette.SetCommands(DefaultCommands);
  FPanel.Palette.OnRun := RunCommand;
  { The session id and stats live on the messages panel's top border; the status
    bar keeps the workspace. The toolbar holds the run state and the hints. }
  FStatusText := FSession.WorkspaceRoot;
  FPanel.SetStatus(FStatusText);
  FHintsText := CtaHints;
  FPanel.SetHints(FHintsText);
  UpdateCta;
  FSidebar := TSidebar.Create(FTheme, FRoster);
  FSidebar.OnSelect := OnSidebarSelect;
  FSidebar.Visible := False;
  Shell := TAppShell.Create(FPanel, Quit, HandleEscape, ComposeIsEmpty);
  Shell.SetSidebarToggle(ToggleSidebar);
  Result := TSidebarOverlay.Create(Shell, FSidebar);
end;

procedure THarnessApp.Quit(Sender: TObject);
begin
  FApp.Stop;
end;

procedure THarnessApp.Invalidate(Sender: TObject);
begin
  UpdateCta;
  FApp.Invalidate;
end;

{ The registered commands. The palette is the entry point; commands are not
  keybindings. }
function THarnessApp.DefaultCommands: TCommandArray;
begin
  { Two entries so the command is discoverable however it is typed: the
    palette's filter is a prefix match, so '/c' shows both and either runs the
    same checkpoint turn. }
  Result := nil;
  SetLength(Result, 3);
  Result[0].Name := 'checkpoint';
  Result[0].Description := 'create a checkpoint for this session';
  Result[1].Name := 'cp';
  Result[1].Description := 'create a checkpoint for this session';
  Result[2].Name := 'sessions';
  Result[2].Description := 'list and manage this workspace''s sessions';
end;

procedure THarnessApp.ComposeChanged(Sender: TObject);
var
  Text: string;
begin
  UpdateCta;
  Text := string(FPanel.Compose.Text);
  { The palette shows while the box holds a lone '/command' token. }
  if (Text <> '') and (Text[1] = '/') and (Pos(' ', Text) = 0) and
    (Pos(#10, Text) = 0) then
  begin
    FPanel.Palette.Filter(Text);
    FPanel.SetPaletteActive(True);
  end
  else
    FPanel.SetPaletteActive(False);
  FApp.Invalidate;
end;

procedure THarnessApp.RunCommand(const AName: string);
begin
  FPanel.SetPaletteActive(False);
  FPanel.Compose.Clear;
  { /sessions reads the store, not the runtime, so it works while connecting. }
  if (AName = 'sessions') or (AName = 'ss') then
  begin
    ShowSessions;
    Exit;
  end;
  { While connecting or failed, other commands have no driver; refuse cleanly. }
  if FConnState <> csConnected then
  begin
    AppendError('not connected yet');
    Exit;
  end;
  if (AName = 'checkpoint') and (FDriver <> nil) then
  begin
    { The runtime drafts synchronously; show the state now so the operator sees
      the checkpoint is in progress (and not a silent freeze). }
    SetState(psThinking, 'checkpointing');
    FBusy := True;
    SyncBusy;
    FDriver.Checkpoint;
  end;
  FApp.Invalidate;
end;

procedure THarnessApp.AppendError(const AText: string);
begin
  FPanel.Stream.Add(ckError, '', AText);
  FApp.Invalidate;
end;

procedure THarnessApp.SetState(AKind: TPanelState; const ALabel: string);
begin
  { The state is context, so it lives at the left of the CTA toolbar; the hints
    are at its right and the status bar keeps the workspace and the metrics. }
  FStateLabel := ALabel;
  FPanel.SetState(AKind, ALabel);
  UpdateCta;
  FApp.Invalidate;
end;

procedure THarnessApp.UpdateCta;
begin
  if not ComposeIsEmpty then
    FPanel.SetCta(ckSend)
  else if FBusy then
    FPanel.SetCta(ckCancel)
  else
    FPanel.SetCta(ckNone);
end;

function THarnessApp.PageNumber: Integer;
var
  Snaps: TCheckpointArray;
  Err: TStoreError;
begin
  { A checkpoint starts a new page; the session begins on page 1. }
  Result := 1;
  if (FSession.Store <> nil) and
    FSession.Store.ListCheckpoints(FSession.SessionId, Snaps, Err) then
    Result := Length(Snaps) + 1;
end;

procedure THarnessApp.UpdateHeader;
var
  Context, Title, Left: string;
  StoreErr: TStoreError;
  MaxW: Integer;
begin
  { Read the persisted session, so a live session and a resumed one show the
    same header. The header carries only the context; the consumption is on the
    status bar. }
  Context := FormatContextUsage(FSession.SessionTotals.ContextTokens,
    FSession.MaxContextTokens);
  { The session's title (the operator's override, else the model's extracted one)
    names the header when present; a session without one shows the id prefix, so
    an unnamed session is still identifiable. }
  Left := '';
  if (FSession.Store <> nil) and
    FSession.Store.SessionTitle(FSession.SessionId, Title, StoreErr) and
    (Title <> '') then
    Left := Title;
  if Left = '' then
    Left := Copy(FSession.SessionId, 1, 12);
  { Keep the title within the border: reserve room for the right-aligned context
    (and the corners), so a long title cannot push the usage off the border.
    TruncateTitle returns a UnicodeString; encode it to a UTF-8 `string`
    explicitly, because the RTL's implicit UnicodeString->string conversion is
    lossy here (it writes '?' for non-ASCII). }
  MaxW := FSurface.Width - 30;
  if MaxW < 8 then
    MaxW := 8;
  FPanel.SetHeader(UTF8Encode(TruncateTitle(UnicodeString(Left), MaxW)), Context);
  { A continuation session runs on pages (one per checkpoint): the messages
    panel's left border is the gauge, the current page heavy, and a click on it
    scrolls (the coarse scroll; the right scrollbar is the fine one). }
  FPageCount := PageNumber;
  FPanel.SetPage(FPageCount, FPageCount - 1);
end;

procedure THarnessApp.UpdateStats;
var
  Context: Int64;
begin
  { The session's consumption sits on the status bar's right; the header carries
    the context. Read the persisted session, so live and resumed match. }
  FStatsText := FormatSessionStats(FSession.SessionTotals);
  FPanel.SetStats(FStatsText);
  UpdateHeader;
  { The checkpoint nudge: advisory only. }
  Context := FSession.SessionTotals.ContextTokens;
  if CheckpointNudgeNeeded(Context, FSession.MaxContextTokens) then
    FHintsText := CtaHints + ' · /checkpoint to continue'
  else
    FHintsText := CtaHints;
  FPanel.SetHints(FHintsText);
  FApp.Invalidate;
end;

function THarnessApp.ComposeIsEmpty: Boolean;
begin
  Result := FPanel.Compose.Text = '';
end;

procedure THarnessApp.HandleEscape(Sender: TObject);
begin
  { Escape closes the /sessions modal first. }
  if FSessionsShown then
  begin
    CloseSessions;
    Exit;
  end;
  { Then dismisses the subagent sidebar. }
  if FSidebarShown then
  begin
    ToggleSidebar(Sender);
    Exit;
  end;
  { Then leaves the subagent spy (never a dead end). }
  if FSpyId <> '' then
  begin
    LeaveSpy;
    Exit;
  end;
  if not FBusy then
    Exit;
  if FInterruptPending then
  begin
    FInterruptPending := False;
    InterruptTurn;
  end
  else
  begin
    { Arm the interrupt; a second Escape within the window cancels the turn. }
    FInterruptPending := True;
    FInterruptAt := GetTickCount64;
    SetState(psInterrupt, 'press esc again to cancel');
  end;
end;

procedure THarnessApp.InterruptTurn;
begin
  if FDriver <> nil then
  begin
    FDriver.Interrupt;
    SetState(psThinking, 'cancelling');
  end;
end;

procedure THarnessApp.CheckInterruptWindow;
begin
  if not FInterruptPending then
    Exit;
  if GetTickCount64 - FInterruptAt < InterruptWindowMs then
    Exit;
  FInterruptPending := False;
  if FBusy then
    SetState(psThinking, 'thinking');
end;

procedure THarnessApp.RenderHistory;
var
  History: TMessageRecordArray;
  Turns: TTurnRecordArray;
  Checkpoint: TCheckpointRecord;
  Archived: TMessageRecordArray;
  StoreErr: TStoreError;
  I, Head, CurrentTurn: Integer;
  Rec: TMessageRecord;
  ToolBlocks: array of TChatItem;
  Block: TChatItem;

  { The divider a completed turn leaves after its messages; nothing for a turn
    that failed, was cancelled, or is unknown. }
  procedure DrawTurnDivider(const ATurns: TTurnRecordArray; ATurnId: Int64);
  var
    J: Integer;
  begin
    for J := 0 to High(ATurns) do
      if (ATurns[J].Id = ATurnId) and (ATurns[J].Status = tsCompleted) then
      begin
        FPanel.Stream.Add(ckTurn, '', FormatTurnStats(ATurns[J]));
        Exit;
      end;
  end;

begin
  { A bounded tail, not the whole session: the first frame is O(window), and the
    window grows as the operator scrolls up (FOlderPages). Ephemeral/no-store
    sessions have no history. }
  if FSession <> nil then
    History := FSession.HistoryTail(StartupTailCount +
      FOlderPages * HistoryPageSize)
  else
    History := nil;
  { The window's start index in the whole session, for the coarse scrubber: the
    session's message count minus what is loaded (0 when all is loaded). }
  if FSession <> nil then
    FWindowStart := FSession.MessageCount - Length(History)
  else
    FWindowStart := 0;
  if FWindowStart < 0 then
    FWindowStart := 0;
  Turns := FSession.Turns;
  Head := 0;
  CurrentTurn := 0;
  ToolBlocks := nil;
  { The active window starts at the latest checkpoint. Render the archived prefix
    (back-pagination), the boundary marker, then the document as the segment's
    opening block, so the operator sees what the agent was briefed with. }
  Checkpoint := Default(TCheckpointRecord);
  FCheckpointBlock := nil;
  if (FSession.Store <> nil) and
    FSession.Store.LatestCheckpoint(FSession.SessionId, Checkpoint, StoreErr) then
  begin
    if FOlderPages > 0 then
    begin
      Archived := nil;
      if FSession.Store.QueryMessagesBefore(FSession.SessionId, Checkpoint.Seq,
        FOlderPages * 20, Archived, StoreErr) then
        for I := 0 to High(Archived) do
          FPanel.Stream.Add(ckAssistant, '', Archived[I].Content);
    end;
    { The checkpoint document is the segment's opening block: a handoff box
      whose title carries the label (the box render pads it with a leading
      space). No separate "— checkpoint —" marker is drawn: the box itself is
      the boundary, and it immediately follows the archived page. The kind is
      its own so a distinct handoff presentation can fork from the ambient one. }
    FPanel.Stream.Add(ckHandoff, 'checkpoint', Checkpoint.Summary);
    FCheckpointBlock := FPanel.Stream.Last;
  end;
  for I := 0 to High(History) do
  begin
    Rec := History[I];
    { Messages are grouped by turn in order, so a change of turn means the
      previous one ended: draw its divider before the next turn's first block. }
    if Rec.TurnId <> CurrentTurn then
    begin
      if CurrentTurn <> 0 then
        DrawTurnDivider(Turns, CurrentTurn);
      CurrentTurn := Rec.TurnId;
    end;
    case Rec.Role of
      mrUser:
        { A user row is never empty in practice; skip one that is rather than
          draw a blank block. }
        if Rec.Content <> '' then
          FPanel.Stream.Add(ckUser, '', Rec.Content);
      mrAssistant:
        { An intermediate assistant row can be empty (it only carried tool
          calls), so do not draw an empty bubble. A substantive reply's leading
          frontmatter is stripped and drawn as the title/keyword header. }
        AddAssistantBlock(Rec.Content);
      mrReasoning:
        FPanel.Stream.Add(ckThought, FormatThoughtLabel(Rec.DurationMs),
          Rec.Content);
      mrToolCall:
        begin
          { The reason is the title; the raw call is not shown, so a resumed
            session matches the live one. }
          if Rec.ToolReason <> '' then
            Block := FPanel.Stream.Add(ckTool, Rec.ToolReason, '')
          else
            Block := FPanel.Stream.Add(ckTool, Rec.ToolName, '');
          Block.Expanded := False;
          SetLength(ToolBlocks, Length(ToolBlocks) + 1);
          ToolBlocks[High(ToolBlocks)] := Block;
        end;
      mrTool:
        { Results follow their calls in order; pair them, and fall back to a
          standalone block when the call was trimmed from the history. }
        if Head <= High(ToolBlocks) then
        begin
          Block := ToolBlocks[Head];
          Inc(Head);
          AppendToolResult(Block, Rec.Content);
        end
        else
          FPanel.Stream.Add(ckTool, Rec.ToolName, Rec.Content);
      mrError:
        { The detail is stored in the tool_arguments column (see the store's
          AppendError); show it, so a resumed session reads like the live one. }
        FPanel.Stream.Add(ckError, '', ErrorText(Rec.Content, Rec.ToolArguments));
      mrSystem:
        { The system prompt is never drawn live, so it is not drawn on resume
          either; live and resume stay identical. }
        ;
      mrAmbient:
        { A subagent result: a user-style box with a violet border, titled with
          the task label and status. }
        if Rec.Content <> '' then
          FPanel.Stream.Add(ckAmbient, Rec.LabelText + ' · ' + Rec.Status,
            Rec.Content);
    end;
  end;
  { The final turn's divider. }
  if CurrentTurn <> 0 then
    DrawTurnDivider(Turns, CurrentTurn);
  { A tool call whose result was never recorded (a crash mid-tool) still gets an
    acknowledgement, so no tool block is blank. }
  for I := Head to High(ToolBlocks) do
    if ToolBlocks[I].Text = '' then
      ToolBlocks[I].SetText('(no result)');
  { A full rebuild (first load, a resume, or a checkpoint reload) shows the
    newest content; a back-pagination prepend restores its anchor in the
    stream's Arrange instead. }
  if not FPanel.Stream.AnchorPending then
    FPanel.Stream.FollowBottom;
end;

procedure THarnessApp.Submit(const AText: string);
begin
  { Idle: no session/runtime yet. The first prompt triggers the connect via the
    launcher's hook; the prompt is remembered and submitted once connected. }
  if FConnState = csIdle then
  begin
    if Assigned(FOnNeedConnect) then
    begin
      FPendingSubmit := AText;
      FOnNeedConnect();
    end
    else
      AppendError('no session; cannot send');
    Exit;
  end;
  { While connecting or failed there is no driver to submit to; refuse cleanly. }
  if FConnState <> csConnected then
  begin
    AppendError('not connected yet');
    Exit;
  end;
  if FBusy then
  begin
    { A turn is in flight: hand the prompt to the driver, which injects it at
      the runtime's next boundary, and show it as a 'Queued' box now. }
    if FDriver <> nil then
      FDriver.QueuePrompt(AText);
    ShowQueued(AText);
    Exit;
  end;
  FUserPrompt := AText;
  FUserBlock := nil;
  { The compose stays active while a turn runs, so the operator can type the
    next prompt to inject mid-flight. The user block is added when the prompt is
    echoed (teUserMessage), so live and replayed turns render identically. }
  FBusy := True;
  SyncBusy;
  SetState(psThinking, 'thinking');
  FAssistant := nil;
  FThought := nil;
  FlushToolOutput;
  FToolBlocks.Clear;
  FToolPending.Clear;
  if FDriver <> nil then
    FDriver.StartTurn(AText);
end;

procedure THarnessApp.FinalizeThinking;
begin
  if (FThought <> nil) and FThought.Live then
  begin
    { The reasoning has finished streaming; it is about to be persisted, so it
      becomes a normal, collapsed thought block carrying its duration. }
    FThought.Live := False;
    FThought.Label_ := FormatThoughtLabel(FThoughtMs);
    FThought.Expanded := False;
    FThought := nil;
  end;
  FThoughtMs := 0;
end;

procedure THarnessApp.FinalizeAssistant;
var
  Meta: TReplyMeta;
  Tail: string;
begin
  if FAssistant <> nil then
  begin
    { Flush anything the suppressor still withheld: a block that never closed
      (no fence, no blank line) is not frontmatter, so its bytes are body and
      must be shown. Without this, an unterminated block left the reply blank. }
    if FlushFrontMatter(FAssistantSupp, Tail) and (Tail <> '') then
      FAssistant.AppendText(Tail);
    FAssistant.Finalize;
    { The reply's frontmatter is metadata: strip it from the displayed body and
      draw the title/keyword header instead. The block was already withheld
      while streaming; this also covers a reply that streamed without one. }
    Meta := ExtractReplyMeta(FAssistantRaw);
    if Meta.HasMeta then
    begin
      FAssistant.SetText(Meta.Body);
      FAssistant.SetMeta(Meta.Title, Meta.Keywords);
    end;
    FAssistant := nil;
  end;
  FAssistantRaw := '';
end;

procedure THarnessApp.AddTurnDivider;
var
  Turn: TTurnRecord;
  Stats: string;
begin
  { Only a completed loop ends with a divider, matching the restore; a failed or
    cancelled turn (and a store-less session, whose zero record is tsRunning)
    draws none. }
  Turn := FSession.LastTurn;
  if Turn.Status <> tsCompleted then
    Exit;
  Stats := FormatTurnStats(Turn);
  if Stats <> '' then
    FPanel.Stream.Add(ckTurn, '', Stats);
end;

procedure THarnessApp.AddTurnChanges(ATurnId: Int64);
var
  Changes: IChangeStore;
  Rows: TChangeRecordArray;
  Summary: TTurnChangeSummary;
  Lines: TStringArray;
  Block: TChatItem;
  Text: string;
  Err: string;
  I: Integer;
begin
  { Nothing to read without a store, and a zero turn id is not a turn. }
  if (FSession.Store = nil) or (ATurnId = 0) then
    Exit;
  Changes := TSqliteChangeStore.Create(FSession.Store);
  if not Changes.ForTurn(FSession.WorkspaceId, Integer(ATurnId), Rows, Err) then
    Exit;
  Summary := SummarizeTurn(Rows);
  { A turn that changed nothing renders NO block: an empty summary is noise, and
    its absence already says the tree is untouched. }
  Lines := SummaryLines(Summary, TurnSummaryMaxFiles);
  if Length(Lines) = 0 then
    Exit;
  Text := '';
  for I := 0 to High(Lines) do
  begin
    if I > 0 then
      Text := Text + LineEnding;
    Text := Text + Lines[I];
  end;
  { One collapsed block: the stat lines are visible, the per-file diffs open on
    demand. It rides the stream after the divider, so a resumed session shows it
    in the same place from the same rows. }
  Block := FPanel.Stream.Add(ckTurnChanges, 'turn changes', Text);
  Block.Expanded := False;
end;

procedure THarnessApp.AddAssistantBlock(const AContent: string);
var
  Meta: TReplyMeta;
  Block: TChatItem;
begin
  if AContent = '' then
    Exit;
  { A stored reply may open with a frontmatter block (from before the model
    learned to close it, or a malformed one). Extract it here too, so a resumed
    session renders the same as the live one: the block is stripped and drawn as
    the title/keyword header. }
  Meta := ExtractReplyMeta(AContent);
  if Meta.HasMeta then
  begin
    Block := FPanel.Stream.Add(ckAssistant, '', Meta.Body);
    Block.SetMeta(Meta.Title, Meta.Keywords);
  end
  else
    FPanel.Stream.Add(ckAssistant, '', AContent);
end;

procedure THarnessApp.AppendToolResult(ABlock: TChatItem; const AText: string);
var
  Text: string;
begin
  { A tool that produced nothing still ran; show a marker rather than a blank. }
  Text := AText;
  if Text = '' then
    Text := '(no output)';
  if ABlock.Live then
  begin
    { The block streamed live; settle it and replace the streamed body with the
      authoritative result, so the live view and a resumed view match. }
    ABlock.Live := False;
    ABlock.SetText(Text);
  end
  else if ABlock.Text = '' then
    ABlock.SetText(Text)
  else
    ABlock.AppendText(#10 + #10 + Text);
end;

procedure THarnessApp.SettleOpenTool;
var
  Pair: TPair<string, TChatItem>;
begin
  FlushToolOutput;
  for Pair in FToolBlocks do
  begin
    Pair.Value.Live := False;
    if Pair.Value.Text = '' then
      Pair.Value.SetText('(no result)');
  end;
  FToolBlocks.Clear;
end;

procedure THarnessApp.PrependCompose(const AText: string);
var
  Existing: UnicodeString;
begin
  if AText = '' then
    Exit;
  Existing := FPanel.Compose.Edit.Text;
  if Existing = '' then
    FPanel.Compose.Edit.SetText(UnicodeString(AText))
  else
    FPanel.Compose.Edit.SetText(UnicodeString(AText) + #10 + Existing);
end;

procedure THarnessApp.RollBackEarlyCancel;
begin
  if FAssistant <> nil then
  begin
    FPanel.Stream.Remove(FAssistant);
    FAssistant := nil;
  end;
  if FThought <> nil then
  begin
    FPanel.Stream.Remove(FThought);
    FThought := nil;
  end;
  if FUserBlock <> nil then
  begin
    FPanel.Stream.Remove(FUserBlock);
    FUserBlock := nil;
  end;
  PrependCompose(FUserPrompt);
  FApp.Invalidate;
end;

procedure THarnessApp.RollBackPendingResponse;
begin
  { The pending response was streamed but never persisted (it was truncated and
    then failed, or superseded). Removing its blocks keeps the live view equal
    to a resumed session. Committed tool rounds are not touched. }
  if FAssistant <> nil then
  begin
    FPanel.Stream.Remove(FAssistant);
    FAssistant := nil;
  end;
  if FThought <> nil then
  begin
    FPanel.Stream.Remove(FThought);
    FThought := nil;
  end;
  FApp.Invalidate;
end;

procedure THarnessApp.HandleUserMessage(const AText: string);
var
  Block: TChatItem;
  I: Integer;
begin
  { An empty user message carries no information (and a mis-mapped event can
    produce one); never draw a blank user block. }
  if AText = '' then
    Exit;
  { A queued prompt supersedes whatever was streaming: drop those blocks and
    show the prompt as the next user turn. }
  if FAssistant <> nil then
  begin
    FPanel.Stream.Remove(FAssistant);
    FAssistant := nil;
  end;
  if FThought <> nil then
  begin
    FPanel.Stream.Remove(FThought);
    FThought := nil;
  end;
  SettleOpenTool;
  { A queued box is superseded by the real user turn; drop the oldest. }
  if Length(FQueuedBlocks) > 0 then
  begin
    FPanel.Stream.Remove(FQueuedBlocks[0]);
    for I := 1 to High(FQueuedBlocks) do
      FQueuedBlocks[I - 1] := FQueuedBlocks[I];
    SetLength(FQueuedBlocks, Length(FQueuedBlocks) - 1);
  end;
  Block := FPanel.Stream.Add(ckUser, '', AText);
  { The turn's first user message is the one an early cancel restores; a queued
    prompt leaves the first block in place. }  if FUserBlock = nil then
    FUserBlock := Block;
  FApp.Invalidate;
end;

procedure THarnessApp.HandleTurnEvent(const E: TTurnEvent);
var
  Suppressed: string;
  Block: TChatItem;
  Pending: string;
begin
  { Anything that is not more reasoning (or the reasoning-end marker, which
    carries its duration) means the reasoning stream has ended. }
  if not (E.Kind in [teReasoningDelta, teReasoningDone]) then
    FinalizeThinking;
  case E.Kind of
    teUserMessage:
      HandleUserMessage(E.Text);
    teAssistantDelta:
      begin
        if FAssistant = nil then
        begin
          FAssistant := FPanel.Stream.Add(ckAssistant, '', '');
          FAssistantRaw := '';
          FAssistantSupp := Default(TFrontMatterSuppressor);
        end;
        { Accumulate the raw reply; suppress a leading frontmatter block so its
          bytes are not shown as they stream. }
        FAssistantRaw := FAssistantRaw + E.Text;
        SuppressFrontMatter(FAssistantSupp, E.Text, Suppressed);
        if Suppressed <> '' then
          FAssistant.AppendText(Suppressed);
      end;
    teReasoningDelta:
      begin
        if FThought = nil then
        begin
          FThought := FPanel.Stream.Add(ckThought, 'Thinking...', '');
          FThought.Live := True;
        end;
        FThought.AppendText(E.Text);
      end;
    teReasoningDone:
      { The reasoning phase ended; settle the thought block with its duration
        when the next event arrives. }
      FThoughtMs := E.ElapsedMs;
    teToolCall:
      begin
        { A tool is running; the sparkle keeps animating because the turn is
          still in flight. Blocks are keyed by call id, so a parallel batch's
          calls each get their own block, created here in call order. }
        SetState(psTool, 'running ' + E.ToolName);
        { The reason is the block's title, so collapsed tool lines read as the
          story of the agent's decisions. The raw call is not shown: the result
          is the body, visible when the block is expanded. }
        if E.ToolReason <> '' then
          FToolBlocks.AddOrSetValue(E.ToolId,
            FPanel.Stream.Add(ckTool, E.ToolReason, ''))
        else
          FToolBlocks.AddOrSetValue(E.ToolId,
            FPanel.Stream.Add(ckTool, E.ToolName, ''));
        FToolBlocks[E.ToolId].Expanded := False;
      end;
    teToolResult:
      begin
        FlushToolOutput;
        if FToolBlocks.TryGetValue(E.ToolId, Block) then
        begin
          { The ok flag is already on the wire; use it so a failed call is
            visibly an error and not just text that happens to say so. }
          Block.Failed := not E.ToolOk;
          AppendToolResult(Block, E.Text);
          FToolBlocks.Remove(E.ToolId);
        end
        else
        begin
          Block := FPanel.Stream.Add(ckTool, E.ToolName, '');
          Block.Failed := not E.ToolOk;
          AppendToolResult(Block, E.Text);
        end;
        FToolPending.Remove(E.ToolId);
        { The tools are done, so the next deltas belong to the following message:
          start fresh blocks, after the tool lines. The turn is still in flight,
          so the state returns to thinking. }
        SetState(psThinking, 'thinking');
        FinalizeAssistant;
        FThought := nil;
      end;
    teToolOutput:
      begin
        { Live shows the tail and auto-expands, so the operator can watch a long
          command; the block settles back to collapsed when the result arrives.
          The text is buffered per call and appended once per frame
          (FlushToolOutput), so parallel calls do not interleave. }
        if not FToolBlocks.TryGetValue(E.ToolId, Block) then
        begin
          Block := FPanel.Stream.Add(ckTool, E.ToolName, '');
          FToolBlocks.AddOrSetValue(E.ToolId, Block);
        end;
        Block.Live := True;
        { Append to the call's buffer; the getter is strict, so read it safely
          (a missing key would raise rather than yield ''). }
        if FToolPending.TryGetValue(E.ToolId, Pending) then
          FToolPending[E.ToolId] := Pending + E.Text
        else
          FToolPending.AddOrSetValue(E.ToolId, E.Text);
      end;
    teApprovalAsk:
      begin
        FAskRefIsChild := False;
        EnqueueAsk(E);
      end;
    teSubagent, teSubagentAsk, teAmbient:
      HandleSubagentEvent(E);
    teCheckpointCommitted:
      begin
        { A checkpoint was recorded: the active window is now the document plus
          everything after the boundary. Rebuild the transcript from it. }
        FPanel.Stream.Clear;
        RenderHistory;
        FApp.Invalidate;
      end;
    teDone:
      begin
        { A successful loop ends with its metrics, then its change summary. The
          summary is a block under the divider, and is absent entirely when the
          turn wrote nothing - an empty summary would be noise. }
        AddTurnDivider;
        if FSession.LastTurn.Status = tsCompleted then
          AddTurnChanges(FSession.LastTurn.Id);
        FinishTurn(psReady, 'ready');
      end;
    teError:
      if E.ErrorCode = leCancelled then
      begin
        { A user interrupt is not an error; do not draw an error block. An
          early cancel also drops the prompt from the transcript and gives it
          back to the operator. }
        if E.Dropped then
          RollBackEarlyCancel;
        FinishTurn(psReady, 'cancelled');
      end
      else
      begin
        { The pending response was dropped by the loop, so drop its blocks here
          too, then show the error. }
        RollBackPendingResponse;
        AppendError(ErrorText(E.Text, E.Detail));
        FinishTurn(psError, 'error');
      end;
  else
    ;
  end;
end;

procedure THarnessApp.EnqueueAsk(const E: TTurnEvent);
begin
  { One modal at a time. A batch (a compound run_command, or the next tool call)
    can queue several asks; show them in order as each is answered. }
  if FApp.ModalActive then
  begin
    SetLength(FAskQueue, Length(FAskQueue) + 1);
    FAskQueue[High(FAskQueue)] := E;
    Exit;
  end;
  ShowApproval(E);
end;

procedure THarnessApp.ShowNextAsk;
var
  E: TTurnEvent;
  I: Integer;
begin
  if Length(FAskQueue) = 0 then
    Exit;
  E := FAskQueue[0];
  for I := 1 to High(FAskQueue) do
    FAskQueue[I - 1] := FAskQueue[I];
  SetLength(FAskQueue, Length(FAskQueue) - 1);
  ShowApproval(E);
end;

procedure THarnessApp.ShowApproval(const E: TTurnEvent);
var
  Wrap: TContainer;
  R: TRect;
begin
  FModal := TApprovalModal.Create(E.Ask, FTheme);
  FModal.OnChoose := OnApprovalChosen;
  FPendingAskRef := E.AskRef;
  Wrap := TContainer.Create([Fill(1), Auto, Fill(1)], [Fill(1), Auto, Fill(1)]);
  Wrap.Add(FModal, 1, 1);
  R := Default(TRect);
  R.W := FSurface.Width;
  R.H := FSurface.Height;
  Wrap.Arrange(R);
  FApp.PushPlane(TPlane.Create(Wrap, True, True));
  SetState(psApproval, 'approval needed');
end;

procedure THarnessApp.OnApprovalChosen(const AChoice: TApprovalChoice);
begin
  { A child's ask is answered with the namespaced ref (<child>/<ask>); the
    runtime routes it down to the child. A parent's own ask answers the gate. }
  if FDriver <> nil then
    FDriver.AnswerAsk(FPendingAskRef, AChoice);
  FAskRefIsChild := False;
  { Defer popping: we are inside the modal's own event handler. }
  FCloseModal := True;
end;

procedure THarnessApp.CloseModal;
begin
  if not FCloseModal then
    Exit;
  if FApp.ModalActive then
    FApp.PopPlane;
  FModal := nil;
  FCloseModal := False;
  { The turn resumes once the ask is answered. }
  if FBusy then
    SetState(psThinking, 'thinking');
  ShowNextAsk;
end;

procedure THarnessApp.RefreshSessions;
var
  Rows: TSessionRowArray;
  StoreErr: TStoreError;
begin
  if (FSessionsModal = nil) or (FSession = nil) or (FSession.Store = nil) then
    Exit;
  if FSession.Store.ListSessionRows(FSession.WorkspaceId,
    FSessionsModal.ShowArchived, Rows, StoreErr) then
    FSessionsModal.SetRows(Rows);
end;

procedure THarnessApp.ShowSessions;
var
  Wrap: TContainer;
  R: TRect;
begin
  if (FSession = nil) or (FSession.Store = nil) then
  begin
    AppendError('no store; /sessions needs a session store');
    Exit;
  end;
  FSessionsModal := TSessionsModal.Create(FTheme);
  FSessionsModal.SetCurrent(FSession.SessionId);
  FSessionsModal.OnAction := OnSessionAction;
  FSessionsModal.OnRename := OnSessionRename;
  { Enter opens the selected session (SwitchSession closes the modal on swap). }
  FSessionsModal.OnActivate := SwitchSession;
  RefreshSessions;
  Wrap := TContainer.Create([Fill(1), Auto, Fill(1)], [Fill(1), Auto, Fill(1)]);
  Wrap.Add(FSessionsModal, 1, 1);
  R := Default(TRect);
  R.W := FSurface.Width;
  R.H := FSurface.Height;
  Wrap.Arrange(R);
  FApp.PushPlane(TPlane.Create(Wrap, True, True));
  FSessionsShown := True;
  SetState(psReady, 'sessions');
end;

procedure THarnessApp.CloseSessions;
begin
  if not FSessionsShown then
    Exit;
  if FApp.ModalActive then
    FApp.PopPlane;
  FSessionsModal := nil;
  FSessionsShown := False;
  SetState(psReady, 'ready');
end;

procedure THarnessApp.SyncSessionsModal;
begin
  if FCloseSessions then
  begin
    { A deferred close (Enter, or the modal's own Escape): the caller is not
      dispatching, so it is safe to pop now. }
    FCloseSessions := False;
    CloseSessions;
    Exit;
  end;
  { An unhandled key (Escape) pops the plane in TTuiApp without telling the app;
    clear the dangling widget and the shown flag so the state does not lie. }
  if FSessionsShown and (not FApp.ModalActive) then
  begin
    FSessionsModal := nil;
    FSessionsShown := False;
    SetState(psReady, 'ready');
  end;
end;

procedure THarnessApp.OnSessionAction(const ASessionId: string;
  AAction: TSessionAction);
var
  Err: TStoreError;
  I: Integer;
  Rows: TSessionRowArray;
  Pinned, Archived: Boolean;
begin
  if (FSession = nil) or (FSession.Store = nil) or (ASessionId = '') then
    Exit;
  { Find the row's current flags, then toggle. }
  Pinned := False;
  Archived := False;
  if FSession.Store.ListSessionRows(FSession.WorkspaceId, True, Rows, Err) then
    for I := 0 to High(Rows) do
      if Rows[I].Id = ASessionId then
      begin
        Pinned := Rows[I].Pinned;
        Archived := Rows[I].Archived;
        Break;
      end;
  case AAction of
    saTogglePin:
      FSession.Store.SetSessionPinned(ASessionId, not Pinned, Err);
    saToggleArchive:
      FSession.Store.SetSessionArchived(ASessionId, not Archived, Err);
  else
    ;
  end;
  RefreshSessions;
  FApp.Invalidate;
end;

procedure THarnessApp.OnSessionRename(const ASessionId, ANewTitle: string);
var
  Err: TStoreError;
begin
  if (FSession = nil) or (FSession.Store = nil) or (ASessionId = '') then
    Exit;
  { An empty title clears the override (back to the extracted title). }
  FSession.Store.SetSessionTitleOverride(ASessionId, ANewTitle, Err);
  { A rename of the current session renames the header too. }
  if (FSession <> nil) and (ASessionId = FSession.SessionId) then
    UpdateHeader;
  RefreshSessions;
  FApp.Invalidate;
end;

procedure THarnessApp.FinishTurn(AState: TPanelState; const ALabel: string);
begin
  FBusy := False;
  FInterruptPending := False;
  FinalizeAssistant;
  FThought := nil;
  SettleOpenTool;
  FUserBlock := nil;
  FPanel.SetComposeActive(True);
  SetState(AState, ALabel);
  UpdateStats;
  SyncBusy;
end;

procedure THarnessApp.DrainQueue;
const
  { A per-frame budget: drain at most this many events, then return so the loop
    can render and poll input. An unbounded drain starves both when a producer
    streams faster than the UI consumes. }
  DrainBudget = 256;
var
  E: TTurnEvent;
  I: Integer;
begin
  if FDriver = nil then
    Exit;
  for I := 0 to DrainBudget - 1 do
  begin
    if not FDriver.PopEvent(E) then
      Break;
    { While spying, the parent's events are consumed but not drawn: its turn
      keeps running and is persisted, and its transcript is rebuilt on leave. Only
      the state (busy / roster) is updated, so the two streams never interleave. }
    if FSpyId <> '' then
    begin
      case E.Kind of
        teDone, teError:
          FBusy := False;
        teSubagent:
          HandleSubagentEvent(E);
      else
        ;
      end;
    end
    else
      HandleTurnEvent(E);
  end;
  { Surface a dropped-output warning once, the first frame the bound was hit. }
  if (FLastDropped = 0) and (FDriver.Dropped > 0) then
    AppendError('streamed output was dropped: the UI could not keep up ' +
      '(the tool output above is incomplete)');
  FLastDropped := FDriver.Dropped;
end;

procedure THarnessApp.FlushToolOutput;
const
  { The live block keeps only its tail; a huge command must not grow it without
    limit. Older text is trimmed, with a marker naming how much went. }
  MaxLiveChars = 65536;
var
  Pair: TPair<string, string>;
  Block: TChatItem;
  Text: string;
  Excess: Integer;
begin
  if FToolPending.Count = 0 then
    Exit;
  for Pair in FToolPending do
  begin
    if (Pair.Value = '') or
      (not FToolBlocks.TryGetValue(Pair.Key, Block)) then
      Continue;
    Block.AppendText(Pair.Value);
    Text := Block.Text;
    if Length(Text) > MaxLiveChars then
    begin
      Excess := Length(Text) - MaxLiveChars;
      Block.SetText('[' + IntToStr(Excess) + ' earlier chars trimmed]' + #10 +
        Utf8From(Text, Excess));
    end;
  end;
  FToolPending.Clear;
end;

procedure THarnessApp.SyncBusy;
begin
  FApp.Busy := FBusy;
end;

procedure THarnessApp.NeedOlderHistory(Sender: TObject);
begin
  { At the head already: nothing older exists; do not re-fire (no endless
    "loading older messages"). }
  if FAtHead then
    Exit;
  { Prepend one more page, holding the scroll so the visible content stays put
    (the stream applies the anchor on its next layout). }
  FPanel.Stream.PreserveAnchor;
  Inc(FOlderPages);
  FPanel.Stream.Clear;
  RenderHistory;
  { RenderHistory sets FWindowStart to the window's start index in the session;
    0 means the window now holds everything, so the head is reached. (Content
    height is stale until the next layout, so it is not the signal.) }
  if FWindowStart <= 0 then
    FAtHead := True;
  FApp.Invalidate;
end;

procedure THarnessApp.TrimHistory;
begin
  { Unload older loaded pages once the operator has not scrolled for TrimIdleMs
    and is at the bottom (not reading the older region). This keeps a long
    session's TUI memory bounded: the pages scrolled past are released. The
    viewport is not moved (it is at the bottom; dropping content above it leaves
    the visible rows unchanged). }
  if FOlderPages <= 0 then
    Exit;
  if FBusy then
    Exit;                       { a turn is streaming; do not churn the stream }
  if not ShouldTrimHistory(FOlderPages, GetTickCount64, FLastScrollMs,
    FPanel.Stream.ScrollOffset, FPanel.Stream.MaxScroll) then
    Exit;
  { Drop every older page: back to the tail window. }
  FOlderPages := 0;
  FAtHead := False;
  FPanel.Stream.Clear;
  RenderHistory;
  FApp.Invalidate;
end;

function THarnessApp.PageScrub(const E: TInputEvent): Boolean;
var
  B: TRect;
  H, I, Seg, Target, SessionIndex: Integer;
begin
  { The left border of the messages panel is a coarse scrollbar: one segment per
    page, the current page heavy. A press or drag on it scrolls to that segment's
    fraction of the content; the last segment reaches the end. }
  Result := False;
  if (E.Kind <> ikMouse) or (FPageCount < 2) then
    Exit;
  if FPageDragging then
  begin
    if E.Mouse.Button = mbNone then
    begin
      FPageDragging := False;
      Exit(True);
    end;
    FPageDragRow := E.Mouse.Y;
  end
  else
  begin
    if E.Mouse.Button <> mbLeft then
      Exit;
    B := FPanel.MessagesBounds;
    if (B.W < 2) or (B.H < 2) or (E.Mouse.X <> B.X) or
      (E.Mouse.Y <= B.Y) or (E.Mouse.Y >= B.Y + B.H - 1) then
      Exit;
    FPageDragging := True;
    FPageDragRow := E.Mouse.Y;
  end;
  B := FPanel.MessagesBounds;
  H := B.H - 2;
  if H < 1 then
    H := 1;
  I := FPageDragRow - (B.Y + 1);
  if I < 0 then
    I := 0;
  if I >= H then
    I := H - 1;
  Seg := (I * FPageCount) div H;
  if Seg > FPageCount - 1 then
    Seg := FPageCount - 1;
  { The segment points to a message index in the whole session (real counts from
    the store, not an estimate). If that is older than the loaded window, grow
    the window to cover it first (a coarse jump loads); then scroll within. }
  SessionIndex := CoarseScrollTarget(Seg, FPageCount, FSession.MessageCount);
  while (not FAtHead) and (FWindowStart > SessionIndex) and
    (FOlderPages * HistoryPageSize < FSession.MessageCount) do
  begin
    FPanel.Stream.PreserveAnchor;
    Inc(FOlderPages);
    FPanel.Stream.Clear;
    RenderHistory;
    if FWindowStart = 0 then
      FAtHead := True;
  end;
  { Within the loaded window: the fraction of the way from its start to the
    session's end. ScrollY = 0 is the window top, MaxScroll the bottom. }
  Target := 0;
  if FSession.MessageCount > 1 then
    Target := (FPanel.Stream.MaxScroll * (SessionIndex - FWindowStart)) div
      (FSession.MessageCount - 1 - FWindowStart);
  if Target < 0 then
    Target := 0;
  if Target > FPanel.Stream.MaxScroll then
    Target := FPanel.Stream.MaxScroll;
  FPanel.Stream.ScrollTo(Target);
  FPanel.SetPageIndex(Seg);
  FApp.Invalidate;
  Result := True;
end;

procedure THarnessApp.StreamScrolled(Sender: TObject);
var
  Boundary: Integer;
  BoundaryPage: Integer;
begin
  { The active page is discrete: it changes only when the viewport crosses the
    checkpoint boundary. Above the boundary is the archived (earlier) page; at or
    below it is the current page. }
  FLastScrollMs := GetTickCount64;
  if FPageCount < 2 then
    Exit;
  if FCheckpointBlock = nil then
  begin
    FPanel.SetPageIndex(FPageCount - 1);
    Exit;
  end;
  Boundary := FPanel.Stream.OffsetOf(FCheckpointBlock);
  if Boundary < 0 then
    Exit;
  { The page the boundary sits on: pageCount - 1 pages are archived before it,
    the boundary is the start of the current page. }
  BoundaryPage := FPageCount - 1;
  if FPanel.Stream.ScrollOffset < Boundary then
    FPanel.SetPageIndex(BoundaryPage - 1)
  else
    FPanel.SetPageIndex(BoundaryPage);
end;

procedure THarnessApp.OnLoop;
begin
  { Drain each iteration, then reflect the resulting busy state so Run picks the
    frame cadence (not the idle wait) while a turn is streaming. }
  CloseModal;
  SyncSessionsModal;
  CheckInterruptWindow;
  DrainQueue;
  FlushToolOutput;
  TrimHistory;
  SyncBusy;
  { The caret is steady while the terminal is unfocused (DECSET 1004). }
  FPanel.Compose.Edit.Blinking := FApp.TerminalFocused;
end;

function THarnessApp.Step: Boolean;
begin
  { Pop an answered modal (and show the next queued ask) before draining, so a
    fresh ask is never stacked on top of one still being answered. }
  CloseModal;
  SyncSessionsModal;
  CheckInterruptWindow;
  DrainQueue;
  FlushToolOutput;
  DrainSpy;
  Result := FApp.Step;
end;

procedure THarnessApp.Run(ACheckStop: TStopCheck);
begin
  FApp.Run(ACheckStop, OnLoop);
end;

procedure THarnessApp.Stop;
begin
  FApp.Stop;
end;

function THarnessApp.GetModalActive: Boolean;
begin
  Result := FApp.ModalActive;
end;

function THarnessApp.GetPromptActive: Boolean;
begin
  Result := FPanel.Compose.Edit.Active;
end;

function THarnessApp.ConversationText: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FPanel.Stream.Count - 1 do
    Result := Result + FPanel.Stream.ItemAt(I).Text + #10;
end;

{ --- subagents ---------------------------------------------------------- }

procedure THarnessApp.ShowQueued(const AText: string);
var
  Block: TChatItem;
begin
  Block := FPanel.Stream.Add(ckQueued, 'Queued', AText);
  SetLength(FQueuedBlocks, Length(FQueuedBlocks) + 1);
  FQueuedBlocks[High(FQueuedBlocks)] := Block;
  FApp.Invalidate;
end;

procedure THarnessApp.HandleSubagentEvent(const E: TTurnEvent);
begin
  case E.Kind of
    teSubagent:
      begin
        FRoster.Apply(E.SubSessionId, E.SubLabel, E.SubStatus,
          Int64(GetTickCount64));
        if FSidebarShown then
          FSidebar.Refresh;
      end;
    teAmbient:
      { The ambient result, shown live as a violet box (title = label ·
        status). }
      if E.Text <> '' then
      begin
        FPanel.Stream.Add(ckAmbient, E.SubLabel + ' · ' + E.SubStatus, E.Text);
        FApp.Invalidate;
      end;
    teSubagentAsk:
      begin
        FAskRefIsChild := True;
        EnqueueAsk(E);
      end;
  else
    ;
  end;
end;

function THarnessApp.SidebarShown: Boolean;
begin
  Result := FSidebarShown;
end;

function THarnessApp.SpyId: string;
begin
  Result := FSpyId;
end;

procedure THarnessApp.ToggleSidebar(Sender: TObject);
begin
  FSidebarShown := not FSidebarShown;
  FSidebar.Visible := FSidebarShown;
  if FSidebarShown then
  begin
    FSidebar.Refresh;
    LayoutSidebar;
  end
  else
    FApp.Invalidate;
end;

procedure THarnessApp.LayoutSidebar;
var
  R: TRect;
  W: Integer;
  Avail: TSize;
begin
  if not FSidebarShown then
    Exit;
  Avail := Default(TSize);
  Avail.W := FSurface.Width;
  Avail.H := FSurface.Height;
  R := Default(TRect);
  R.X := 2;
  R.Y := 2;
  W := FSidebar.Measure(Avail).W + 2;
  if W < 16 then
    W := 16;
  if W > FSurface.Width - 4 then
    W := FSurface.Width - 4;
  R.W := W;
  R.H := FRoster.Count + 2;
  if R.H < 3 then
    R.H := 3;
  if R.H > FSurface.Height - 4 then
    R.H := FSurface.Height - 4;
  FSidebar.Arrange(R);
end;

procedure THarnessApp.OnSidebarSelect(const ASessionId: string);
begin
  ShowSpy(ASessionId);
end;

procedure THarnessApp.ShowSpy(const ASessionId: string);
var
  Cfg: TSessionClientConfig;
  Err: string;
begin
  LeaveSpy;
  Cfg := Default(TSessionClientConfig);
  Cfg.WorkspacePath := FSession.WorkspaceRoot;
  Cfg.Spawn := False;
  Cfg.Role := srObserve;
  if Assigned(FSpyFactory) then
    FSpy := FSpyFactory(ASessionId, Cfg, Err)
  else
    FSpy := TSubagentSpy.Open(ASessionId, Cfg, Err);
  if FSpy = nil then
  begin
    AppendError('could not open the child session: ' + Err);
    Exit;
  end;
  FSpyId := ASessionId;
  { The spy takes over the panel; the sidebar is hidden AND its shown flag
    cleared, so Escape leaves the spy rather than re-showing the sidebar. }
  FSidebarShown := False;
  FSidebar.Visible := False;
  FPanel.SetComposeActive(False);
  { The compose gives way to a CTA actions bar (abort/release/leave). }
  SetupSpyActions;
  { Rebuild the panel to show the child's transcript (history tail, then its live
    stream), and mark the header so the operator knows whose session this is. }
  ResetWindow;
  RenderSpyHistory(ASessionId);
  FPanel.SetHeader(
    UTF8Encode(TruncateTitle(UnicodeString('spying · ' + SpyLabel), 40)), '');
end;

procedure THarnessApp.SetupSpyActions;
var
  Hints: TActionHintArray;
begin
  SetLength(Hints, 3);
  Hints[0].Key := 'a';
  Hints[0].Action := ' abort';
  Hints[1].Key := 'r';
  Hints[1].Action := ' release';
  Hints[2].Key := 'esc';
  Hints[2].Action := ' leave';
  FPanel.Actions.SetHints(Hints);
  FPanel.Actions.Label_ := 'subagent';
  FPanel.Actions.OnAction := OnSpyAction;
  FPanel.SetActionsMode(True);
end;

procedure THarnessApp.OnSpyAction(AIndex: Integer);
begin
  { Index matches SetupSpyActions: 0 abort, 1 release, 2 leave (esc is the global
    handler's, so it never reaches here). }
  case AIndex of
    0:
      begin
        SendSubagentCommand(scAbortSubagent, FSpyId);
        SetState(psReady, 'subagent aborted');
      end;
    1:
      begin
        SendSubagentCommand(scReleaseSubagent, FSpyId);
        SetState(psReady, 'subagent released');
      end;
  else
    ;
  end;
end;

function THarnessApp.SpyLabel: string;
var
  I: Integer;
  Entries: TSubagentEntryArray;
begin
  { The child's label from the roster when known, else its id prefix. }
  Result := '';
  Entries := FRoster.Entries;
  for I := 0 to High(Entries) do
    if Entries[I].SessionId = FSpyId then
    begin
      Result := Entries[I].LabelText;
      Break;
    end;
  if Result = '' then
    Result := Copy(FSpyId, 1, 12);
end;

procedure THarnessApp.RenderSpyHistory(const ASessionId: string);
var
  History: TMessageRecordArray;
  StoreErr: TStoreError;
  I: Integer;
  Rec: TMessageRecord;
begin
  { The child's transcript: a bounded tail from the store (a child has no
    checkpoints in v1). The live stream is appended by DrainSpy. }
  History := nil;
  if (FSession <> nil) and (FSession.Store <> nil) then
    FSession.Store.QueryActiveMessagesTail(ASessionId, StartupTailCount,
      History, StoreErr);
  for I := 0 to High(History) do
  begin
    Rec := History[I];
    case Rec.Role of
      mrUser:
        if Rec.Content <> '' then
          FPanel.Stream.Add(ckUser, '', Rec.Content);
      mrAssistant:
        AddAssistantBlock(Rec.Content);
      mrReasoning:
        FPanel.Stream.Add(ckThought, FormatThoughtLabel(Rec.DurationMs),
          Rec.Content);
      mrToolCall:
        FPanel.Stream.Add(ckTool, Rec.ToolReason, '');
      mrTool:
        FPanel.Stream.Add(ckTool, Rec.ToolName, Rec.Content);
      mrError:
        FPanel.Stream.Add(ckError, '', Rec.Content);
      mrAmbient:
        if Rec.Content <> '' then
          FPanel.Stream.Add(ckAmbient, Rec.LabelText + ' · ' + Rec.Status,
            Rec.Content);
    else
      ;
    end;
  end;
  FPanel.Stream.FollowBottom;
end;

procedure THarnessApp.LeaveSpy;
begin
  if FSpy <> nil then
  begin
    FSpy.Close;
    FSpy.Free;
    FSpy := nil;
  end;
  if FSpyId <> '' then
  begin
    FSpyId := '';
    FPanel.SetActionsMode(False);
    FPanel.SetComposeActive(True);
    UpdateCta;
    { Restore the parent's transcript (the child's view replaced it) and header. }
    ResetWindow;
    RenderHistory;
    UpdateStats;
    { Re-show the sidebar the operator used to pick the child. }
    FSidebarShown := True;
    FSidebar.Visible := True;
    FSidebar.Refresh;
    LayoutSidebar;
  end;
  FApp.Invalidate;
end;

procedure THarnessApp.DrainSpy;
var
  E: TTurnEvent;
begin
  if FSpy = nil then
    Exit;
  while FSpy.PopEvent(E) do
    HandleTurnEvent(E);
end;

procedure THarnessApp.SendSubagentCommand(AKind: TSessionCommandKind;
  const ASessionId: string);
begin
  if FDriver = nil then
    Exit;
  if AKind = scAbortSubagent then
    FDriver.AbortSubagent(ASessionId)
  else if AKind = scReleaseSubagent then
    FDriver.ReleaseSubagent(ASessionId);
end;

end.
