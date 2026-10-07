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
  hildegard.helper.tui.approvalmodal,
  hildegard.helper.tui.panel, hildegard.helper.tui.theme,
  hildegard.helper.tui.app, hildegard.helper.harness.turn,
  hildegard.helper.harness.driver, hildegard.helper.harness.view,
  hildegard.helper.harness.stats, hildegard.helper.session;

type
  { Builds the tree and owns the TTuiApp and the current worker. The session is
    owned by the caller and must outlive the app. }
  THarnessApp = class
  private
    FSurface: ISurface;
    FInput: IInputSource;
    FSession: TSessionView;
    FDriver: ISessionDriver;
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
    { The reasoning phase's duration for the live thought block, set by
      teReasoningDone and consumed when the block settles. }
    FThoughtMs: Int64;
    { The submitted prompt and its block, so an early cancel can undo them. }
    FUserPrompt: string;
    FUserBlock: TChatItem;
    function BuildTree: TWidget;
    procedure Submit(const AText: string);
    procedure DrainQueue;
    procedure HandleTurnEvent(const E: TTurnEvent);
    procedure EnqueueAsk(const E: TTurnEvent);
    procedure ShowNextAsk;
    procedure ShowApproval(const E: TTurnEvent);
    procedure OnApprovalChosen(const AChoice: TApprovalChoice);
    procedure CloseModal;
    procedure FinishTurn(AState: TPanelState; const ALabel: string);
    procedure SetState(AKind: TPanelState; const ALabel: string);
    { The compose's primary-action hint, from the run state and the box. }
    procedure UpdateCta;
    { Settle the streaming thinking block into a persisted "Thought" block. }
    procedure FinalizeThinking;
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
    function GetModalActive: Boolean;
    function GetPromptActive: Boolean;
    procedure Quit(Sender: TObject);
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
    function ConversationText: string;
  end;

implementation

const
  { The interaction hints live in the CTA strip, which acts as a context
    toolbar; the status bar is reserved for the workspace and the metrics. }
  { The toolbar hints are blank for now; the compose CTA carries the primary
    action. }
  CtaHints = '';
  { How long the first Escape stays armed before the interrupt prompt expires. }
  InterruptWindowMs = 2000;

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
  public
    constructor Create(AChild: TWidget; AOnQuit, AOnEscape: TNotifyEvent;
      ACanQuit: TQueryEvent);
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

{ TAppShell }

constructor TAppShell.Create(AChild: TWidget; AOnQuit, AOnEscape: TNotifyEvent;
  ACanQuit: TQueryEvent);
begin
  inherited Create(AChild);
  FOnQuit := AOnQuit;
  FOnEscape := AOnEscape;
  FCanQuit := ACanQuit;
end;

function TAppShell.HandleEvent(const E: TInputEvent): Boolean;
begin
  if (E.Kind = ikKey) and (E.Key.Kind = kkChar) and (moCtrl in E.Key.Mods) then
  begin
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
  FApp := TTuiApp.Create(ASurface, AInput, BuildTree);
  FApp.ScreenBg := FTheme.Bg;
  RenderHistory;
  SetState(psReady, 'ready');
  UpdateStats;
end;

destructor THarnessApp.Destroy;
begin
  CancelTurn;
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
begin
  FPanel := TChatPanel.Create(FTheme, 'Hildegard · ' + FSession.Model,
    CtaHints);
  FPanel.Stream.OnToggle := Invalidate;
  FPanel.Stream.OnChange := Invalidate;
  FPanel.Compose.OnSubmit := Submit;
  FPanel.Compose.OnChange := Invalidate;
  { The session id and stats live on the messages panel's top border; the status
    bar keeps the workspace. The toolbar holds the run state and the hints. }
  FStatusText := FSession.WorkspaceRoot;
  FPanel.SetStatus(FStatusText);
  FHintsText := CtaHints;
  FPanel.SetHints(FHintsText);
  UpdateCta;
  Result := TAppShell.Create(FPanel, Quit, HandleEscape, ComposeIsEmpty);
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

procedure THarnessApp.UpdateHeader;
begin
  { Read the persisted session, so a live session and a resumed one show the
    same header. The header carries only the context; the consumption is on the
    status bar. }
  FPanel.SetHeader(Copy(FSession.SessionId, 1, 12),
    FormatContextUsage(FSession.SessionTotals.ContextTokens,
      FSession.MaxContextTokens));
end;

procedure THarnessApp.UpdateStats;
begin
  { The session's consumption sits on the status bar's right; the header carries
    the context. Read the persisted session, so live and resumed match. }
  FStatsText := FormatSessionStats(FSession.SessionTotals);
  FPanel.SetStats(FStatsText);
  UpdateHeader;
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
  History := FSession.History;
  Turns := FSession.Turns;
  Head := 0;
  CurrentTurn := 0;
  ToolBlocks := nil;
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
        { A subagent result. // ponytail: rendered as a plain block here; the
          dedicated ambient renderer lands with Subagent_Sidebar_v1.SPEC.md. }
        if Rec.Content <> '' then
          FPanel.Stream.Add(ckUser, '', Rec.Content);
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
end;

procedure THarnessApp.Submit(const AText: string);
begin
  if FBusy then
  begin
    { A turn is in flight: hand the prompt to the driver, which injects it at
      the runtime's next boundary. }
    if FDriver <> nil then
      FDriver.QueuePrompt(AText);
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
        FAssistant := nil;
        FThought := nil;
      end;
    teToolOutput:
      begin
        if FTool = nil then
          FTool := FPanel.Stream.Add(ckTool, E.ToolName, '');
        { Live shows the tail and auto-expands, so the operator can watch a long
          command; the block settles back to collapsed when the result arrives. }
        FTool.Live := True;
        FTool.AppendText(E.Text);
      end;
    teApprovalAsk:
      EnqueueAsk(E);
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
  if FDriver <> nil then
    FDriver.AnswerAsk(FPendingAskRef, AChoice);
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
  FAssistant := nil;
  FThought := nil;
  SettleOpenTool;
  FUserBlock := nil;
  FPanel.SetComposeActive(True);
  SetState(AState, ALabel);
  UpdateStats;
  SyncBusy;
end;

procedure THarnessApp.DrainQueue;
var
  E: TTurnEvent;
begin
  if FDriver = nil then
    Exit;
  while FDriver.PopEvent(E) do
    HandleTurnEvent(E);
end;

procedure THarnessApp.SyncBusy;
begin
  FApp.Busy := FBusy;
end;

procedure THarnessApp.OnLoop;
begin
  { Drain each iteration, then reflect the resulting busy state so Run picks the
    frame cadence (not the idle wait) while a turn is streaming. }
  CloseModal;
  CheckInterruptWindow;
  DrainQueue;
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

end.
