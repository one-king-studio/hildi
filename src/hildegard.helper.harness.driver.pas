unit hildegard.helper.harness.driver;
{ The seam between the TUI app and where its turns come from.

  TLocalDriver runs the loop in-process (the original TTurnWorker over the
  session's queue/gate). TRemoteDriver drives a TSessionClient: it sends
  commands and maps the wire events back onto TTurnEvents, so the app's
  rendering is unchanged. Both deliver events on a thread-safe TTurnQueue the
  UI drains - no callback touches a widget off the UI thread.

  The remote driver reconnects on demand, so a runtime that idle-exited or
  crashed does not wedge the TUI. }

{$mode delphi}{$H+}

interface

uses
  Classes, SyncObjs,
  hildegard.helper.llm, hildegard.helper.approval,
  hildegard.helper.harness.turn, hildegard.helper.harness.session,
  hildegard.helper.session.protocol, hildegard.helper.session.runtime;

type
  ISessionDriver = interface
    { Start a new turn. }
    procedure StartTurn(const AText: string);
    { Inject a prompt into the running turn (the runtime queues it). }
    procedure QueuePrompt(const AText: string);
    { Ask for the live turn to be cancelled. }
    procedure Interrupt;
    { Resolve a pending approval ask by its reference. }
    procedure AnswerAsk(const AAskRef: string; const AChoice: TApprovalChoice);
    { UI thread: pop the next event, if any. }
    function PopEvent(out AEvent: TTurnEvent): Boolean;
    { Release the connection and join any thread. Idempotent. }
    procedure Close;
  end;

{ The in-process driver over a session that has a built loop. }
function LocalDriver(ASession: THarnessSession): ISessionDriver;
{ The remote driver over a headless runtime. Connects (spawns if needed) now;
  returns nil with AError on failure. }
function RemoteDriver(const AConfig: TSessionClientConfig;
  out AError: string): ISessionDriver;

implementation

uses
  SysUtils;

{ --- TLocalDriver ------------------------------------------------------- }

type
  TLocalDriver = class(TInterfacedObject, ISessionDriver)
  private
    FSession: THarnessSession;
    FWorker: TTurnWorker;
  public
    constructor Create(ASession: THarnessSession);
    procedure StartTurn(const AText: string);
    procedure QueuePrompt(const AText: string);
    procedure Interrupt;
    procedure AnswerAsk(const AAskRef: string; const AChoice: TApprovalChoice);
    function PopEvent(out AEvent: TTurnEvent): Boolean;
    procedure Close;
  end;

constructor TLocalDriver.Create(ASession: THarnessSession);
begin
  inherited Create;
  FSession := ASession;
end;

procedure TLocalDriver.StartTurn(const AText: string);
var
  E: TTurnEvent;
begin
  { Echo the prompt as the first event, so the app handles it the same way as
    the remote path. }
  E := Default(TTurnEvent);
  E.Kind := teUserMessage;
  E.Text := AText;
  FSession.Queue.Push(E);
  FWorker := TTurnWorker.Create(FSession.Loop, FSession.Queue, AText);
  FWorker.Start;
end;

procedure TLocalDriver.QueuePrompt(const AText: string);
begin
  if FWorker <> nil then
    FWorker.QueuePrompt(AText);
end;

procedure TLocalDriver.Interrupt;
begin
  if FWorker <> nil then
    FWorker.RequestCancel;
end;

procedure TLocalDriver.AnswerAsk(const AAskRef: string;
  const AChoice: TApprovalChoice);
begin
  FSession.Gate.Answer(StrToIntDef(AAskRef, 0), AChoice);
end;

function TLocalDriver.PopEvent(out AEvent: TTurnEvent): Boolean;
begin
  Result := FSession.Queue.Pop(AEvent);
  if not Result then
    Exit;
  { Normalise onto the remote vocabulary: a queued prompt is a user message,
    and an approval ask carries its reference. }
  if AEvent.Kind = tePromptQueued then
    AEvent.Kind := teUserMessage;
  if AEvent.Kind = teApprovalAsk then
    AEvent.AskRef := IntToStr(AEvent.RequestId);
end;

procedure TLocalDriver.Close;
begin
  if FSession = nil then
    Exit;
  FSession.Gate.Cancel;
  if FWorker <> nil then
  begin
    if not FWorker.Finished then
      FWorker.WaitFor;
    FWorker.Free;
    FWorker := nil;
  end;
end;

{ --- TRemoteDriver ------------------------------------------------------ }

type
  { Maps wire events onto the app's TTurnEvents and pushes them onto the shared
    queue. Runs on the client's reader thread. }
  TRemoteSink = class(TInterfacedObject, ISessionSink)
  private
    FQueue: TTurnQueue;
  public
    Detached: Boolean;
    DetachedReason: string;
    constructor Create(AQueue: TTurnQueue);
    procedure OnHello(const AHello: TSessionHello);
    procedure OnAttached(const AAttached: TSessionAttached);
    procedure OnEvent(const AEvent: TSessionEvent);
    procedure OnDetached(const AReason: string);
    procedure OnError(const ACode, AMessage: string);
  end;

  TRemoteDriver = class(TInterfacedObject, ISessionDriver)
  private
    FConfig: TSessionClientConfig;
    FQueue: TTurnQueue;
    FSink: TRemoteSink;
    FSinkRef: ISessionSink;
    FClient: TSessionClient;
    FNextId: Integer;
    FClosed: Boolean;
    function EnsureClient(out AError: string): Boolean;
    procedure SendCommand(AKind: TSessionCommandKind; const AText,
      AAskRef: string; const AChoice: TApprovalChoice);
    procedure PushError(const AText: string);
  public
    constructor Create(const AConfig: TSessionClientConfig);
    destructor Destroy; override;
    procedure StartTurn(const AText: string);
    procedure QueuePrompt(const AText: string);
    procedure Interrupt;
    procedure AnswerAsk(const AAskRef: string; const AChoice: TApprovalChoice);
    function PopEvent(out AEvent: TTurnEvent): Boolean;
    procedure Close;
  end;

constructor TRemoteSink.Create(AQueue: TTurnQueue);
begin
  inherited Create;
  FQueue := AQueue;
end;

procedure TRemoteSink.OnHello(const AHello: TSessionHello);
begin
end;

procedure TRemoteSink.OnAttached(const AAttached: TSessionAttached);
begin
end;

procedure TRemoteSink.OnEvent(const AEvent: TSessionEvent);
var
  E: TTurnEvent;
begin
  E := Default(TTurnEvent);
  case AEvent.Kind of
    ekUserMessage:
      begin
        E.Kind := teUserMessage;
        E.Text := AEvent.Text;
      end;
    ekAssistantDelta:
      begin
        E.Kind := teAssistantDelta;
        E.Text := AEvent.Text;
      end;
    ekReasoningDelta:
      begin
        E.Kind := teReasoningDelta;
        E.Text := AEvent.Text;
      end;
    ekToolCall:
      begin
        E.Kind := teToolCall;
        E.ToolId := AEvent.ToolId;
        E.ToolName := AEvent.ToolName;
        E.ToolArguments := AEvent.ToolArguments;
        E.ToolReason := AEvent.ToolReason;
      end;
    ekToolResult:
      begin
        E.Kind := teToolResult;
        E.ToolId := AEvent.ToolId;
        E.ToolName := AEvent.ToolName;
        E.Text := AEvent.Text;
        E.ToolOk := AEvent.ToolOk;
      end;
    ekApprovalRequest:
      begin
        E.Kind := teApprovalAsk;
        E.AskRef := AEvent.AskId;
        E.Ask := AEvent.Ask;
      end;
    ekTurnFinished:
      begin
        E.Kind := teDone;
        E.ElapsedMs := AEvent.ElapsedMs;
      end;
    ekError:
      begin
        E.Kind := teError;
        E.ErrorCode := SessionErrorCodeFromWire(AEvent.ErrorCode);
        E.Text := AEvent.Text;
        E.Detail := AEvent.Detail;
        E.Dropped := AEvent.Dropped;
      end;
  else
    { loop_started, turn_started, approval_resolved, drive_*, gap, loop_exited:
      nothing for the UI to render; a gap is resynced from the ledger. Do NOT
      push E here: its default Kind is teUserMessage (ord 0), which the app
      would render as a blank user block. }
    Exit;
  end;
  FQueue.Push(E);
end;

procedure TRemoteSink.OnDetached(const AReason: string);
var
  E: TTurnEvent;
begin
  Detached := True;
  DetachedReason := AReason;
  E := Default(TTurnEvent);
  E.Kind := teError;
  E.ErrorCode := leNetwork;
  E.Text := 'detached: ' + AReason;
  FQueue.Push(E);
end;

procedure TRemoteSink.OnError(const ACode, AMessage: string);
var
  E: TTurnEvent;
begin
  E := Default(TTurnEvent);
  E.Kind := teError;
  E.ErrorCode := SessionErrorCodeFromWire(ACode);
  E.Text := AMessage;
  E.Detail := ACode;
  FQueue.Push(E);
end;

constructor TRemoteDriver.Create(const AConfig: TSessionClientConfig);
begin
  inherited Create;
  FConfig := AConfig;
  FQueue := TTurnQueue.Create;
  FSink := TRemoteSink.Create(FQueue);
  FSinkRef := FSink;
  FNextId := 0;
  FClosed := False;
end;

destructor TRemoteDriver.Destroy;
begin
  Close;
  FSinkRef := nil;
  FSink := nil;
  FQueue.Free;
  inherited Destroy;
end;

function TRemoteDriver.EnsureClient(out AError: string): Boolean;
var
  Err: string;
begin
  Result := False;
  AError := '';
  if FClosed then
    Exit;
  if (FClient <> nil) and (not FSink.Detached) then
    Exit(True);
  FreeAndNil(FClient);
  FSink.Detached := False;
  FClient := TSessionClient.Open(FConfig, FSinkRef, Err);
  if FClient = nil then
  begin
    AError := Err;
    Exit(False);
  end;
  Result := True;
end;

procedure TRemoteDriver.PushError(const AText: string);
var
  E: TTurnEvent;
begin
  E := Default(TTurnEvent);
  E.Kind := teError;
  E.ErrorCode := leNetwork;
  E.Text := AText;
  FQueue.Push(E);
end;

procedure TRemoteDriver.SendCommand(AKind: TSessionCommandKind;
  const AText, AAskRef: string; const AChoice: TApprovalChoice);
var
  Cmd: TSessionCommand;
  Err: string;
begin
  if not EnsureClient(Err) then
  begin
    PushError(Err);
    Exit;
  end;
  Inc(FNextId);
  Cmd := Default(TSessionCommand);
  Cmd.Kind := AKind;
  Cmd.Id := 't' + IntToStr(FNextId);
  Cmd.Text := AText;
  Cmd.AskId := AAskRef;
  Cmd.Choice := AChoice;
  if not FClient.Send(Cmd) then
  begin
    FSink.Detached := True;
    PushError('could not send to the runtime');
  end;
end;

procedure TRemoteDriver.StartTurn(const AText: string);
begin
  SendCommand(scPrompt, AText, '', Default(TApprovalChoice));
end;

procedure TRemoteDriver.QueuePrompt(const AText: string);
begin
  { The runtime queues a prompt that arrives mid-turn. }
  SendCommand(scPrompt, AText, '', Default(TApprovalChoice));
end;

procedure TRemoteDriver.Interrupt;
begin
  SendCommand(scInterrupt, '', '', Default(TApprovalChoice));
end;

procedure TRemoteDriver.AnswerAsk(const AAskRef: string;
  const AChoice: TApprovalChoice);
begin
  SendCommand(scApprove, '', AAskRef, AChoice);
end;

function TRemoteDriver.PopEvent(out AEvent: TTurnEvent): Boolean;
begin
  Result := FQueue.Pop(AEvent);
end;

procedure TRemoteDriver.Close;
begin
  if FClosed then
    Exit;
  FClosed := True;
  FreeAndNil(FClient);
end;

{ --- factories ---------------------------------------------------------- }

function LocalDriver(ASession: THarnessSession): ISessionDriver;
begin
  Result := TLocalDriver.Create(ASession);
end;

function RemoteDriver(const AConfig: TSessionClientConfig;
  out AError: string): ISessionDriver;
var
  D: TRemoteDriver;
begin
  Result := nil;
  AError := '';
  D := TRemoteDriver.Create(AConfig);
  if not D.EnsureClient(AError) then
  begin
    D.Free;
    Exit(nil);
  end;
  Result := D;
end;

end.
