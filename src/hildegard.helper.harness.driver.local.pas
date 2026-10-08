unit hildegard.helper.harness.driver.local;
{ The in-process driver: runs the loop over a session's queue/gate via
  TTurnWorker, the original pre-headless path. Kept for tests and demos. It
  links the agent, so UI clients use hildegard.helper.harness.driver (the remote
  driver) instead. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.approval, hildegard.helper.harness.turn,
  hildegard.helper.harness.driver, hildegard.helper.harness.session,
  hildegard.helper.store;

{ The in-process driver over a session that has a built loop. }
function LocalDriver(ASession: THarnessSession): ISessionDriver;

implementation

uses
  SysUtils,
  hildegard.helper.harness.turn.worker;

type
  TLocalDriver = class(TInterfacedObject, ISessionDriver)
  private
    FSession: THarnessSession;
    FWorker: TTurnWorker;
    { The turn in flight is a checkpoint turn: on completion the driver records a
      checkpoint from the assistant's reply. }
    FCheckpointTurn: Boolean;
  public
    constructor Create(ASession: THarnessSession);
    procedure StartTurn(const AText: string);
    procedure QueuePrompt(const AText: string);
    procedure Interrupt;
    procedure AnswerAsk(const AAskRef: string; const AChoice: TApprovalChoice);
    procedure AbortSubagent(const ASessionId: string);
    procedure ReleaseSubagent(const ASessionId: string);
    procedure Checkpoint;
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
  { The previous turn's worker has finished (the app only starts a turn when it
    is not busy), but it may still be unwinding after emitting teDone; join and
    free it before replacing it, or it leaks. }
  if FWorker <> nil then
  begin
    if not FWorker.Finished then
      FWorker.WaitFor;
    FWorker.Free;
    FWorker := nil;
  end;
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

procedure TLocalDriver.AbortSubagent(const ASessionId: string);
begin
  { The in-process local driver has no runtime supervisor; subagents are a
    runtime feature. }
end;

procedure TLocalDriver.ReleaseSubagent(const ASessionId: string);
begin
end;

procedure TLocalDriver.Checkpoint;
var
  E: TTurnEvent;
begin
  { The checkpoint is an ordinary (ambient) turn, exactly as over the wire: the
    summarization instruction is queued as an ambient message and the assistant's
    reply is the document. The checkpoint is recorded when the turn completes
    (see PopEvent). }
  if FWorker <> nil then
  begin
    if not FWorker.Finished then
      FWorker.WaitFor;
    FWorker.Free;
    FWorker := nil;
  end;
  if FSession.View.Store = nil then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'checkpoint needs a store';
    FSession.Queue.Push(E);
    Exit;
  end;
  FSession.Loop.PromptQueue.PushAmbient(CheckpointInstruction, '',
    'checkpoint', 'checkpoint', 'running', 0);
  FCheckpointTurn := True;
  FWorker := TTurnWorker.CreateAmbient(FSession.Loop, FSession.Queue);
  FWorker.Start;
end;

function TLocalDriver.PopEvent(out AEvent: TTurnEvent): Boolean;
var
  Seq: Int64;
  StoreErr: TStoreError;
  E: TTurnEvent;
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
  { A completed checkpoint turn: record the checkpoint at the boundary from the
    assistant's reply, then surface it. }
  if FCheckpointTurn and (AEvent.Kind in [teDone, teError]) then
  begin
    FCheckpointTurn := False;
    if (AEvent.Kind = teDone) and (FSession.View.Store <> nil) and
      FSession.View.Store.SaveCheckpoint(FSession.View.SessionId, AEvent.Answer,
        Seq, StoreErr) then
    begin
      E := Default(TTurnEvent);
      E.Kind := teCheckpointCommitted;
      E.ElapsedMs := Seq;
      FSession.Queue.Push(E);
    end;
  end;
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

function LocalDriver(ASession: THarnessSession): ISessionDriver;
begin
  Result := TLocalDriver.Create(ASession);
end;

end.
