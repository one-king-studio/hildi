unit HildiHarnessDriver;
{ The client-side driver seam: ISessionDriver and TRemoteDriver, which drives a
  TSessionClient. It sends commands and maps the wire events back onto
  TTurnEvents on a thread-safe TTurnQueue the UI drains - no callback touches a
  widget off the UI thread. The remote driver reconnects on demand, so a runtime
  that idle-exited or crashed does not wedge the TUI.

  The in-process driver (TLocalDriver), which runs the loop over a session's
  queue/gate, lives in HildiHarnessDriverLocal so this unit links
  no agent. }

{$mode delphi}{$H+}

interface

uses
  Classes, SyncObjs,
  HildiLLM, HildiApproval,
  HildiHarnessTurn,
  HildiSessionProtocol, HildiSessionClient;

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
    { Abort a subagent by its session id. }
    procedure AbortSubagent(const ASessionId: string);
    { Release a subagent by its session id (detach without aborting). }
    procedure ReleaseSubagent(const ASessionId: string);
    { Context checkpoint: ask the runtime to draft and commit a checkpoint. }
    { Undo a turn: the runtime reverts its files and rewinds its transcript.
      ATurnId 0 means the newest completed turn. }
    procedure Undo(ATurnId: Int64 = 0);
    { Redo a turn: re-apply what an undo took away, oldest first. ATurnId 0
      means the oldest undone turn. }
    procedure Redo(ATurnId: Int64 = 0);
    procedure Checkpoint;
    { UI thread: pop the next event, if any. }
    function PopEvent(out AEvent: TTurnEvent): Boolean;
    { How many streamed events have been dropped to honour the mailbox bound. }
    function Dropped: Int64;
    { Release the connection and join any thread. Idempotent. }
    procedure Close;
  end;

{ The remote driver over a headless runtime. Connects (spawns if needed) now;
  returns nil with AError on failure. }
function RemoteDriver(const AConfig: TSessionClientConfig;
  out AError: string): ISessionDriver;

{ Map one wire event onto a TTurnEvent. Returns False when there is nothing for
  the UI to render (loop_started, turn_started, approval_resolved, drive_*,
  gap, loop_exited). Shared by the remote driver and the subagent spy. }
function MapSessionEvent(const AEvent: TSessionEvent; out E: TTurnEvent): Boolean;

implementation

uses
  SysUtils;

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
      AAskRef: string; const AChoice: TApprovalChoice;
      const ASessionId: string; ATurnId: Int64 = 0);
    procedure PushError(const AText: string);
  public
    constructor Create(const AConfig: TSessionClientConfig);
    destructor Destroy; override;
    procedure StartTurn(const AText: string);
    procedure QueuePrompt(const AText: string);
    procedure Interrupt;
    procedure AnswerAsk(const AAskRef: string; const AChoice: TApprovalChoice);
    procedure AbortSubagent(const ASessionId: string);
    procedure ReleaseSubagent(const ASessionId: string);
    { Undo a turn: the runtime reverts its files and rewinds its transcript.
      ATurnId 0 means the newest completed turn. }
    procedure Undo(ATurnId: Int64 = 0);
    { Redo a turn: re-apply what an undo took away, oldest first. ATurnId 0
      means the oldest undone turn. }
    procedure Redo(ATurnId: Int64 = 0);
    procedure Checkpoint;
    function PopEvent(out AEvent: TTurnEvent): Boolean;
    function Dropped: Int64;
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
  if MapSessionEvent(AEvent, E) then
    FQueue.Push(E);
end;

function MapSessionEvent(const AEvent: TSessionEvent;
  out E: TTurnEvent): Boolean;
begin
  Result := True;
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
    ekReasoningDone:
      begin
        E.Kind := teReasoningDone;
        E.ElapsedMs := AEvent.ElapsedMs;
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
    ekToolOutput:
      begin
        E.Kind := teToolOutput;
        E.ToolId := AEvent.ToolId;
        E.ToolName := AEvent.ToolName;
        E.Text := AEvent.Text;
      end;
    ekApprovalRequest:
      begin
        E.Kind := teApprovalAsk;
        E.AskRef := AEvent.AskId;
        E.Ask := AEvent.Ask;
      end;
    ekTurnFinished:
      begin
        { The runtime also emits turn_finished after an error (with
          finish_reason 'error'); the error event already settled the turn, so
          do not report it as a clean done — that would flip a failed turn back
          to ready and end it with a divider. }
        if AEvent.FinishReason = 'error' then
          Exit(False);
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
    ekSubagent:
      begin
        E.Kind := teSubagent;
        E.SubSessionId := AEvent.SubSessionId;
        E.SubLabel := AEvent.Text;
        E.SubStatus := AEvent.SubStatus;
      end;
    ekSubagentAsk:
      begin
        E.Kind := teSubagentAsk;
        E.SubSessionId := AEvent.SubSessionId;
        E.AskRef := AEvent.AskId;
        E.Ask := AEvent.Ask;
      end;
    ekAmbient:
      begin
        E.Kind := teAmbient;
        E.SubSessionId := AEvent.SubSessionId;
        E.Text := AEvent.Text;
        E.ElapsedMs := AEvent.ElapsedMs;
      end;
    ekCheckpointCommitted:
      begin
        E.Kind := teCheckpointCommitted;
        E.ElapsedMs := AEvent.TurnSeq;   { the checkpoint boundary seq }
      end;
    ekUndone:
      begin
        E.Kind := teUndone;
        E.ElapsedMs := AEvent.TurnSeq;   { the turn moved to }
      end;
  else
    { loop_started, turn_started, approval_resolved, drive_*, gap, loop_exited:
      nothing for the UI to render; a gap is resynced from the ledger. Do NOT
      push E here: its default Kind is teUserMessage (ord 0), which the app
      would render as a blank user block. }
    Exit(False);
  end;
  Result := True;
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
  const AText, AAskRef: string; const AChoice: TApprovalChoice;
  const ASessionId: string; ATurnId: Int64);
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
  Cmd.SessionId := ASessionId;
  Cmd.TurnId := ATurnId;
  if not FClient.Send(Cmd) then
  begin
    FSink.Detached := True;
    PushError('could not send to the runtime');
  end;
end;

procedure TRemoteDriver.StartTurn(const AText: string);
begin
  SendCommand(scPrompt, AText, '', Default(TApprovalChoice), '');
end;

procedure TRemoteDriver.QueuePrompt(const AText: string);
begin
  { The runtime queues a prompt that arrives mid-turn. }
  SendCommand(scPrompt, AText, '', Default(TApprovalChoice), '');
end;

procedure TRemoteDriver.Interrupt;
begin
  SendCommand(scInterrupt, '', '', Default(TApprovalChoice), '');
end;

procedure TRemoteDriver.AnswerAsk(const AAskRef: string;
  const AChoice: TApprovalChoice);
begin
  SendCommand(scApprove, '', AAskRef, AChoice, '');
end;

procedure TRemoteDriver.AbortSubagent(const ASessionId: string);
begin
  SendCommand(scAbortSubagent, '', '', Default(TApprovalChoice), ASessionId);
end;

procedure TRemoteDriver.ReleaseSubagent(const ASessionId: string);
begin
  SendCommand(scReleaseSubagent, '', '', Default(TApprovalChoice), ASessionId);
end;

procedure TRemoteDriver.Checkpoint;
begin
  { One action: the runtime drafts the checkpoint and records the checkpoint. }
  SendCommand(scCheckpoint, '', '', Default(TApprovalChoice), '');
end;

procedure TRemoteDriver.Undo(ATurnId: Int64);
begin
  { One action: the runtime reverts the turn's files and rewinds its transcript. }
  SendCommand(scUndo, '', '', Default(TApprovalChoice), '', ATurnId);
end;

procedure TRemoteDriver.Redo(ATurnId: Int64);
begin
  { One action: the runtime re-applies the undone turns from ATurnId forward. }
  SendCommand(scRedo, '', '', Default(TApprovalChoice), '', ATurnId);
end;

function TRemoteDriver.PopEvent(out AEvent: TTurnEvent): Boolean;
begin
  Result := FQueue.Pop(AEvent);
end;

function TRemoteDriver.Dropped: Int64;
begin
  Result := FQueue.Dropped;
end;

procedure TRemoteDriver.Close;
begin
  if FClosed then
    Exit;
  FClosed := True;
  FreeAndNil(FClient);
end;

{ --- factories ---------------------------------------------------------- }

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
