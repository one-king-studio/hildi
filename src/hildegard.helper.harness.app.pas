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
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.chat,
  hildegard.helper.tui.compose, hildegard.helper.tui.chatpanel,
  hildegard.helper.tui.approvalmodal,
  hildegard.helper.tui.panel, hildegard.helper.tui.theme,
  hildegard.helper.tui.app, hildegard.helper.harness.turn,
  hildegard.helper.harness.session, hildegard.helper.harness.stats,
  hildegard.helper.session;

type
  { Builds the tree and owns the TTuiApp and the current worker. The session is
    owned by the caller and must outlive the app. }
  THarnessApp = class
  private
    FSurface: ISurface;
    FInput: IInputSource;
    FSession: THarnessSession;
    FApp: TTuiApp;
    FTheme: TTheme;
    FPanel: TChatPanel;
    FWorker: TTurnWorker;
    FBusy: Boolean;
    FModal: TApprovalModal;
    FPendingRequest: Integer;
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
    { Put text at the front of the compose box, keeping whatever is typed. }
    procedure PrependCompose(const AText: string);
    { Undo the current turn's UI after an early cancel and restore the prompt. }
    procedure RollBackEarlyCancel;
    { Drop the in-flight assistant/thinking blocks of a pending response that was
      never persisted, so the live view matches a resumed session. }
    procedure RollBackPendingResponse;
    { Show a prompt the loop injected, dropping the response it superseded. }
    procedure HandleQueuedPrompt(const AText: string);
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
      ASession: THarnessSession; AMode: TThemeMode = tmAuto;
      ALightDetected: Boolean = False);
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
  ASession: THarnessSession; AMode: TThemeMode; ALightDetected: Boolean);
begin
  inherited Create;
  FSurface := ASurface;
  FInput := AInput;
  FSession := ASession;
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
  if FWorker <> nil then
  begin
    FSession.Gate.Cancel;
    if not FWorker.Finished then
      FWorker.WaitFor;
    FWorker.Free;
    FWorker := nil;
  end;
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
  { The status bar is two parts: the workspace on the left, the metrics on the
    right. The toolbar holds the run state and the hints. }
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

procedure THarnessApp.UpdateStats;
begin
  { Read the persisted turn, so a live turn and a resumed one show the same
    line. }
  FStatsText := FormatTurnStats(FSession.LastTurn);
  FPanel.SetStats(FStatsText);
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
  if FWorker <> nil then
  begin
    FWorker.RequestCancel;
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
  I, Head: Integer;
  Rec: TMessageRecord;
  ToolBlocks: array of TChatItem;
  Block: TChatItem;
begin
  History := FSession.History;
  Head := 0;
  ToolBlocks := nil;
  for I := 0 to High(History) do
  begin
    Rec := History[I];
    case Rec.Role of
      mrUser:
        FPanel.Stream.Add(ckUser, '', Rec.Content);
      mrAssistant:
        { An intermediate assistant row can be empty (it only carried tool
          calls), so do not draw an empty bubble. }
        if Rec.Content <> '' then
          FPanel.Stream.Add(ckAssistant, '', Rec.Content);
      mrReasoning:
        FPanel.Stream.Add(ckThought, 'Thought', Rec.Content);
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
    end;
  end;
end;

procedure THarnessApp.Submit(const AText: string);
begin
  if FBusy then
  begin
    { A turn is in flight: hand the prompt to the running loop, which injects
      it at its next boundary. }
    if FWorker <> nil then
      FWorker.QueuePrompt(AText);
    Exit;
  end;
  FUserPrompt := AText;
  FUserBlock := FPanel.Stream.Add(ckUser, '', AText);
  { The compose stays active while a turn runs, so the operator can type the
    next prompt to inject mid-flight. }
  FBusy := True;
  SyncBusy;
  SetState(psThinking, 'thinking');
  FAssistant := nil;
  FThought := nil;
  FTool := nil;
  FWorker := TTurnWorker.Create(FSession.Loop, FSession.Queue, AText);
  FWorker.Start;
end;

procedure THarnessApp.FinalizeThinking;
begin
  if (FThought = nil) or (not FThought.Live) then
    Exit;
  { The reasoning has finished streaming; it is about to be persisted, so it
    becomes a normal, collapsed "Thought" block. }
  FThought.Live := False;
  FThought.Label_ := 'Thought';
  FThought.Expanded := False;
  FThought := nil;
end;

procedure THarnessApp.AppendToolResult(ABlock: TChatItem; const AText: string);
begin
  if ABlock.Text = '' then
    ABlock.SetText(AText)
  else
    ABlock.AppendText(#10 + #10 + AText);
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

procedure THarnessApp.HandleQueuedPrompt(const AText: string);
begin
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
  FTool := nil;
  FPanel.Stream.Add(ckUser, '', AText);
  FApp.Invalidate;
end;

procedure THarnessApp.HandleTurnEvent(const E: TTurnEvent);
begin
  { A queued prompt supersedes the response that was streaming; handle it before
    anything settles that response. }
  if E.Kind = tePromptQueued then
  begin
    HandleQueuedPrompt(E.Text);
    Exit;
  end;
  { Anything that is not more reasoning means the reasoning stream has ended. }
  if E.Kind <> teReasoningDelta then
    FinalizeThinking;
  case E.Kind of
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
    teApprovalAsk:
      EnqueueAsk(E);
    teDone:
      FinishTurn(psReady, 'ready');
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
  FPendingRequest := E.RequestId;
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
  FSession.Gate.Answer(FPendingRequest, AChoice);
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
  if FWorker <> nil then
  begin
    if not FWorker.Finished then
      FWorker.WaitFor;
    FWorker.Free;
    FWorker := nil;
  end;
  FBusy := False;
  FInterruptPending := False;
  FAssistant := nil;
  FThought := nil;
  FTool := nil;
  FPanel.SetComposeActive(True);
  SetState(AState, ALabel);
  UpdateStats;
  SyncBusy;
end;

procedure THarnessApp.DrainQueue;
var
  E: TTurnEvent;
begin
  while FSession.Queue.Pop(E) do
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
