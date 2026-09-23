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
  hildegard.helper.tui.text, hildegard.helper.tui.conversation,
  hildegard.helper.tui.prompt, hildegard.helper.tui.approvalmodal,
  hildegard.helper.tui.app, hildegard.helper.harness.turn,
  hildegard.helper.harness.session;

type
  { Builds the tree and owns the TTuiApp and the current worker. The session is
    owned by the caller and must outlive the app. }
  THarnessApp = class
  private
    FSurface: ISurface;
    FInput: IInputSource;
    FSession: THarnessSession;
    FApp: TTuiApp;
    FConversation: TConversationView;
    FStatus: TTextBlock;
    FPrompt: TPromptLine;
    FWorker: TTurnWorker;
    FBusy: Boolean;
    FModal: TApprovalModal;
    FPendingRequest: Integer;
    FCloseModal: Boolean;
    function BuildTree: TWidget;
    procedure Submit(const AText: string);
    procedure DrainQueue;
    procedure HandleTurnEvent(const E: TTurnEvent);
    procedure ShowApproval(const E: TTurnEvent);
    procedure OnApprovalChosen(const AChoice: TApprovalChoice);
    procedure CloseModal;
    procedure FinishTurn;
    procedure SetStatus(const AText: string; AFg: Byte);
    procedure AppendLine(const AText: string; const AAttr: TAttr);
    procedure RenderHistory;
    function AssistantAttr: TAttr;
    function GetModalActive: Boolean;
    function GetPromptActive: Boolean;
    procedure Quit(Sender: TObject);
  public
    constructor Create(const ASurface: ISurface; const AInput: IInputSource;
      ASession: THarnessSession);
    destructor Destroy; override;

    { One iteration: drain the queue, resolve any answered approval modal, then
      run TTuiApp.Step. Returns False once stopped. }
    function Step: Boolean;
    procedure Run;
    procedure Stop;

    { Quit mid-turn: deny pending approvals, join the worker, restore state. }
    procedure CancelTurn;

    property Busy: Boolean read FBusy;
    property PromptActive: Boolean read GetPromptActive;
    property ModalActive: Boolean read GetModalActive;
    function ConversationText: string;
  end;

implementation

const
  ClUser = 81;
  ClAssistant = 252;
  ClReasoning = 244;
  ClTool = 215;
  ClError = 203;
  ClStatus = 244;

function Attr(AFg: Byte; AStyle: TStyle = []): TAttr;
begin
  Result := DefaultAttr;
  Result.Fg := AFg;
  Result.Style := AStyle;
end;

type
  { Wraps the root so global quit keys (Ctrl-C/Ctrl-D) are handled before the
    prompt, which otherwise consumes every printable character. }
  TAppShell = class(TWidget)
  private
    FChild: TWidget;
    FOnQuit: TNotifyEvent;
  public
    constructor Create(AChild: TWidget; AOnQuit: TNotifyEvent);
    destructor Destroy; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
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

{ TAppShell }

constructor TAppShell.Create(AChild: TWidget; AOnQuit: TNotifyEvent);
begin
  inherited Create;
  FChild := AChild;
  FOnQuit := AOnQuit;
end;

destructor TAppShell.Destroy;
begin
  FChild.Free;
  inherited Destroy;
end;

function TAppShell.Measure(const AAvail: TSize): TSize;
begin
  Result := FChild.Measure(AAvail);
end;

procedure TAppShell.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  FChild.Arrange(ABounds);
end;

procedure TAppShell.Render(const S: ISurface);
begin
  FChild.Render(S);
end;

function TAppShell.HandleEvent(const E: TInputEvent): Boolean;
begin
  if (E.Kind = ikKey) and (E.Key.Kind = kkChar) and (moCtrl in E.Key.Mods) and
    ((E.Key.Ch = 'c') or (E.Key.Ch = 'd')) then
  begin
    if Assigned(FOnQuit) then
      FOnQuit(Self);
    Exit(True);
  end;
  Result := FChild.HandleEvent(E);
end;

constructor THarnessApp.Create(const ASurface: ISurface; const AInput: IInputSource;
  ASession: THarnessSession);
begin
  inherited Create;
  FSurface := ASurface;
  FInput := AInput;
  FSession := ASession;
  FApp := TTuiApp.Create(ASurface, AInput, BuildTree);
  RenderHistory;
  AppendLine('workspace: ' + FSession.WorkspaceRoot, Attr(ClStatus));
  if FSession.SessionId <> '' then
    AppendLine('session: ' + FSession.SessionId, Attr(ClStatus))
  else
    AppendLine('session: (in memory; no store)', Attr(ClStatus, [sfDim]));
  AppendLine('', Attr(ClStatus));
  SetStatus('ready  [Enter] send  [q/Ctrl-C] quit', ClStatus);
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
var
  Root: TContainer;
begin
  Root := TContainer.Create([Fill(1)], [Fill(1), Fixed(1), Fixed(1)]);
  FConversation := TConversationView.Create;
  FStatus := TTextBlock.Create([], wmNone);
  FPrompt := TPromptLine.Create('> ');
  FPrompt.OnSubmit := Submit;
  Root.Add(FConversation, 0, 0);
  Root.Add(FStatus, 0, 1);
  Root.Add(FPrompt, 0, 2);
  Result := TAppShell.Create(Root, Quit);
end;

procedure THarnessApp.Quit(Sender: TObject);
begin
  FApp.Stop;
end;

function THarnessApp.AssistantAttr: TAttr;
begin
  Result := Attr(ClAssistant);
end;

procedure THarnessApp.AppendLine(const AText: string; const AAttr: TAttr);
begin
  FConversation.Append(UnicodeString(AText + #10), AAttr);
  FApp.Invalidate;
end;

procedure THarnessApp.SetStatus(const AText: string; AFg: Byte);
begin
  FStatus.SetText(AText, Attr(AFg));
  FApp.Invalidate;
end;

procedure THarnessApp.RenderHistory;
var
  History: TChatMessageArray;
  I: Integer;
  Msg: TChatMessage;
  A: TAttr;
begin
  History := FSession.History;
  for I := 0 to High(History) do
  begin
    Msg := History[I];
    case Msg.Role of
      crUser:
        A := Attr(ClUser, [sfBold]);
      crTool:
        A := Attr(ClTool);
      crSystem:
        A := Attr(ClReasoning, [sfDim]);
    else
      A := AssistantAttr;
    end;
    AppendLine(RoleLabel(Msg.Role) + Msg.Content, A);
  end;
end;

procedure THarnessApp.Submit(const AText: string);
begin
  if FBusy then
    Exit;
  AppendLine('> ' + AText, Attr(ClUser, [sfBold]));
  FPrompt.Active := False;
  FBusy := True;
  SetStatus('thinking...', ClStatus);
  FWorker := TTurnWorker.Create(FSession.Loop, FSession.Queue, AText);
  FWorker.Start;
end;

procedure THarnessApp.HandleTurnEvent(const E: TTurnEvent);
begin
  case E.Kind of
    teAssistantDelta:
      begin
        FConversation.Append(UnicodeString(E.Text), AssistantAttr);
        FApp.Invalidate;
      end;
    teReasoningDelta:
      begin
        FConversation.Append(UnicodeString(E.Text), Attr(ClReasoning, [sfDim]));
        FApp.Invalidate;
      end;
    teToolCall:
      begin
        AppendLine(#10 + '[tool] ' + E.ToolName + '  (' + E.ToolReason + ')',
          Attr(ClTool, [sfBold]));
        if E.ToolArguments <> '' then
          AppendLine('  ' + E.ToolArguments, Attr(ClReasoning));
      end;
    teToolResult:
      begin
        if E.ToolOk then
          AppendLine('[result] ' + E.ToolName + ': ok', Attr(ClTool))
        else
          AppendLine('[result] ' + E.ToolName + ': failed', Attr(ClError));
        if E.Text <> '' then
          AppendLine('  ' + E.Text, Attr(ClReasoning, [sfDim]));
      end;
    teApprovalAsk:
      ShowApproval(E);
    teDone:
      begin
        AppendLine('', AssistantAttr);
        FinishTurn;
      end;
    teError:
      begin
        AppendLine('[error] ' + E.Text, Attr(ClError, [sfBold]));
        FinishTurn;
      end;
  else
    ;
  end;
end;

procedure THarnessApp.ShowApproval(const E: TTurnEvent);
var
  Wrap: TContainer;
  R: TRect;
begin
  FModal := TApprovalModal.Create(E.Ask);
  FModal.OnChoose := OnApprovalChosen;
  FPendingRequest := E.RequestId;
  Wrap := TContainer.Create([Fill(1), Auto, Fill(1)], [Fill(1), Auto, Fill(1)]);
  Wrap.Add(FModal, 1, 1);
  R := Default(TRect);
  R.W := FSurface.Width;
  R.H := FSurface.Height;
  Wrap.Arrange(R);
  FApp.PushPlane(TPlane.Create(Wrap, True, True));
  SetStatus('approval needed', ClTool);
end;

procedure THarnessApp.OnApprovalChosen(const AChoice: TApprovalChoice);
begin
  FSession.Gate.Answer(FPendingRequest, AChoice);
  { Defer popping: we are inside the modal's own event handler. }
  FCloseModal := True;
end;

procedure THarnessApp.CloseModal;
begin
  if FCloseModal then
  begin
    FApp.PopPlane;
    FModal := nil;
    FCloseModal := False;
  end;
end;

procedure THarnessApp.FinishTurn;
begin
  if FWorker <> nil then
  begin
    if not FWorker.Finished then
      FWorker.WaitFor;
    FWorker.Free;
    FWorker := nil;
  end;
  FBusy := False;
  FPrompt.Active := True;
  SetStatus('ready', ClStatus);
end;

procedure THarnessApp.DrainQueue;
var
  E: TTurnEvent;
begin
  while FSession.Queue.Pop(E) do
    HandleTurnEvent(E);
end;

function THarnessApp.Step: Boolean;
begin
  DrainQueue;
  CloseModal;
  Result := FApp.Step;
end;

procedure THarnessApp.Run;
begin
  while Step do
    Sleep(1);
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
  Result := FPrompt.Active;
end;

function THarnessApp.ConversationText: string;
begin
  Result := string(FConversation.Text);
end;

end.
