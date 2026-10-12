unit hildegard.helper.harness.app;
{ The Harness UI application: it builds the widget tree (conversation, status,
  prompt), drains the turn queue each Step, routes approval asks to a modal, and
  runs one worker per submitted prompt. It is the only unit besides the example
  that knows both the harness layer and the widgets; it does not link a terminal.

  The UI thread never blocks on the worker except during teardown. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  hildegard.helper.llm, hildegard.helper.approval,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.chat,
  hildegard.helper.tui.compose, hildegard.helper.tui.chatpanel,
  hildegard.helper.tui.palette,
  hildegard.helper.tui.approvalmodal,
  hildegard.helper.tui.panel, hildegard.helper.tui.theme,
  hildegard.helper.tui.app, hildegard.helper.harness.turn,
  hildegard.helper.harness.driver, hildegard.helper.harness.view,
  hildegard.helper.store,
  hildegard.helper.harness.stats, hildegard.helper.session,
  hildegard.helper.harness.subagent, hildegard.helper.harness.subagent.spy,
  hildegard.helper.tui.sidebar, hildegard.helper.tui.list,
  hildegard.helper.session.protocol, hildegard.helper.session.client;

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
    { A prompt submitted while idle, held until Attach delivers the driver. }
    FPendingSubmit: string;
    FApp: TTuiApp;
    FTheme: TTheme;
    FPanel: TChatPanel;
    FBusy: Boolean;
    FModal: TApprovalModal;
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
    FThought: TChatItem;
    FTool: TChatItem;
    { Streamed tool output is buffered and appended once per frame, so a chatty
      command costs one layout, not one per chunk. Flushed by FlushToolOutput. }
    FPendingToolOutput: string;
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
    procedure Submit(const AText: string);
    procedure DrainQueue;
    procedure FlushToolOutput;
    procedure HandleTurnEvent(const E: TTurnEvent);
    procedure EnqueueAsk(const E: TTurnEvent);
    procedure ShowNextAsk;
    procedure ShowApproval(const E: TTurnEvent);
    procedure OnApprovalChosen(const AChoice: TApprovalChoice);
    procedure CloseModal;
    { Subagents: feed the roster, toggle/show the sidebar, spy on a child. }
    procedure HandleSubagentEvent(const E: TTurnEvent);
    { Show a queued prompt (a violet 'Queued' box) at the end of the stream. }
    procedure ShowQueued(const AText: string);
    procedure ToggleSidebar(Sender: TObject);
    procedure LayoutSidebar;
    procedure OnSidebarSelect(const ASessionId: string);
    procedure ShowSpy(const ASessionId: string);
    procedure LeaveSpy;
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

    property ConnState: TConnState read GetConnState;
    { The lazy-start hook: called on the first submit when idle. }
    property OnNeedConnect: TConnectEvent read FOnNeedConnect
      write FOnNeedConnect;

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
  { A fresh tail: the window has not reached the head yet. }
  FAtHead := False;
  FOlderPages := 0;
  { Replace the connecting/idle frame with the transcript. }
  FPanel.Stream.Clear;
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
  Result := Shell;
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
  SetLength(Result, 2);
  Result[0].Name := 'checkpoint';
  Result[0].Description := 'create a checkpoint for this session';
  Result[1].Name := 'cp';
  Result[1].Description := 'create a checkpoint for this session';
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
  { While connecting or failed, commands have no driver; refuse cleanly. }
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
  Context: string;
begin
  { Read the persisted session, so a live session and a resumed one show the
    same header. The header carries only the context; the consumption is on the
    status bar. }
  Context := FormatContextUsage(FSession.SessionTotals.ContextTokens,
    FSession.MaxContextTokens);
  FPanel.SetHeader(Copy(FSession.SessionId, 1, 12), Context);
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
    { The checkpoint document is the segment's opening block: an ambient box
      whose title carries the label (the ambient render pads it with a leading
      space). No separate "— checkpoint —" marker is drawn: the box itself is
      the boundary, and it immediately follows the archived page. }
    FPanel.Stream.Add(ckAmbient, 'checkpoint', Checkpoint.Summary);
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
          calls), so do not draw an empty bubble. }
        if Rec.Content <> '' then
          FPanel.Stream.Add(ckAssistant, '', Rec.Content);
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
        FPanel.Stream.Add(ckError, '', Rec.Content);
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
  FTool := nil;
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
begin
  if FAssistant <> nil then
  begin
    FAssistant.Finalize;
    FAssistant := nil;
  end;
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
begin
  FlushToolOutput;
  if FTool <> nil then
  begin
    FTool.Live := False;
    if FTool.Text = '' then
      FTool.SetText('(no result)');
  end;
  FTool := nil;
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
          FAssistant := FPanel.Stream.Add(ckAssistant, '', '');
        FAssistant.AppendText(E.Text);
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
          still in flight. }
        SetState(psTool, 'running ' + E.ToolName);
        { The reason is the block's title, so collapsed tool lines read as the
          story of the agent's decisions. The raw call is not shown: the result
          is the body, visible when the block is expanded. }
        if E.ToolReason <> '' then
          FTool := FPanel.Stream.Add(ckTool, E.ToolReason, '')
        else
          FTool := FPanel.Stream.Add(ckTool, E.ToolName, '');
        FTool.Expanded := False;
      end;
    teToolResult:
      begin
        FlushToolOutput;
        if FTool <> nil then
        begin
          AppendToolResult(FTool, E.Text);
          FTool := nil;
        end
        else
        begin
          FTool := FPanel.Stream.Add(ckTool, E.ToolName, '');
          AppendToolResult(FTool, E.Text);
          FTool := nil;
        end;
        { The tools are done, so the next deltas belong to the following message:
          start fresh blocks, after the tool lines. The turn is still in flight,
          so the state returns to thinking. }
        SetState(psThinking, 'thinking');
        FinalizeAssistant;
        FThought := nil;
      end;
    teToolOutput:
      begin
        if FTool = nil then
          FTool := FPanel.Stream.Add(ckTool, E.ToolName, '');
        { Live shows the tail and auto-expands, so the operator can watch a long
          command; the block settles back to collapsed when the result arrives.
          The text is buffered and appended once per frame (FlushToolOutput). }
        FTool.Live := True;
        FPendingToolOutput := FPendingToolOutput + E.Text;
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
        { A successful loop ends with its metrics. }
        AddTurnDivider;
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
        AppendError(E.Text);
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
  Text: string;
  Excess: Integer;
begin
  if FPendingToolOutput = '' then
    Exit;
  if FTool <> nil then
  begin
    FTool.AppendText(FPendingToolOutput);
    Text := FTool.Text;
    if Length(Text) > MaxLiveChars then
    begin
      Excess := Length(Text) - MaxLiveChars;
      FTool.SetText('[' + IntToStr(Excess) + ' earlier chars trimmed]' + #10 +
        Copy(Text, Excess + 1, MaxLiveChars));
    end;
  end;
  FPendingToolOutput := '';
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
  end;
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
  FSpy := TSubagentSpy.Open(ASessionId, Cfg, Err);
  if FSpy = nil then
    Exit;
  FSpyId := ASessionId;
  FSidebar.Visible := False;
  FPanel.SetComposeActive(False);
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
    FPanel.SetComposeActive(True);
  end;
  if FSidebarShown then
    FSidebar.Visible := True;
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
