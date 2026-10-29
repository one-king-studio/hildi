unit hildi.harness.driver.local;
{ The in-process driver: runs the loop over a session's queue/gate via
  TTurnWorker, the original pre-headless path. Kept for tests and demos. It
  links the agent, so UI clients use hildi.harness.driver (the remote
  driver) instead. }

{$mode delphi}{$H+}

interface

uses
  hildi.approval, hildi.harness.turn,
  hildi.harness.driver, hildi.harness.session,
  hildi.session,
  hildi.store;

{ The in-process driver over a session that has a built loop. }
function LocalDriver(ASession: THarnessSession): ISessionDriver;

implementation

uses
  SysUtils,
  hildi.harness.turn.worker;

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
    procedure Undo(ATurnId: Int64 = 0);
    { Redo what an undo took away, oldest first. ATurnId 0 means the oldest
      undone turn. }
    procedure Redo(ATurnId: Int64 = 0);
    procedure Checkpoint;
    function PopEvent(out AEvent: TTurnEvent): Boolean;
    function Dropped: Int64;
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
  FWorker := TTurnWorker.Create(FSession.Loop, FSession.Queue, AText,
    FSession.TurnPool);
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
  { Release any tool call blocked in the approval gate, so the interrupt is not
    held up until the approval timeout. }
  if FSession <> nil then
    FSession.Gate.Cancel;
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
  FWorker := TTurnWorker.CreateAmbient(FSession.Loop, FSession.Queue,
    FSession.TurnPool);
  FWorker.Start;
end;

procedure TLocalDriver.Undo(ATurnId: Int64);
var
  E: TTurnEvent;
  Detail: string;
  Id: Int64;
begin
  { In-process, the session is right here, so this acts directly rather than
    sending a command. Same rules as the runtime handler: refuse a busy turn, and
    surface UndoTurn's refusal reason as an error event so the operator sees WHY
    rather than a silent no-op. }
  if (FWorker <> nil) and (not FWorker.Finished) then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'undo refused: a turn is in progress';
    FSession.Queue.Push(E);
    Exit;
  end;
  Id := ATurnId;
  if Id <= 0 then
  begin
    if FSession.View.LastTurn.Status = tsCompleted then
      Id := FSession.View.LastTurn.Id;
  end;
  if Id <= 0 then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'undo refused: no completed turn to undo';
    FSession.Queue.Push(E);
    Exit;
  end;
  if not FSession.UndoTurn(Id, Detail) then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'undo refused: ' + Detail;
    FSession.Queue.Push(E);
  end
  else
  begin
    { Tell the app the transcript moved, so it rebuilds the stream and hands the
      prompt back to the composer - the cancel behaviour. The runtime broadcasts
      ekUndone for remote clients; without this the in-process path would undo
      the store and leave the screen unchanged, which is exactly the "undo did
      nothing" the operator reported. }
    E := Default(TTurnEvent);
    E.Kind := teUndone;
    E.ElapsedMs := Id;
    FSession.Queue.Push(E);
  end;
end;

procedure TLocalDriver.Redo(ATurnId: Int64);
var
  E: TTurnEvent;
  Detail: string;
  Id: Int64;
begin
  { The mirror of Undo, with the same two refusals for the same reasons. }
  if (FWorker <> nil) and (not FWorker.Finished) then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'redo refused: a turn is in progress';
    FSession.Queue.Push(E);
    Exit;
  end;
  Id := ATurnId;
  if Id <= 0 then
    { The oldest REDOABLE turn: undone and above the redo floor. Resolved by the
      session so this and the runtime cannot disagree - picking the oldest
      undone turn without the floor would select one a later prompt abandoned. }
    Id := FSession.OldestRedoableTurn;
  if Id <= 0 then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'redo refused: nothing is undone';
    FSession.Queue.Push(E);
    Exit;
  end;
  if not FSession.RedoTurn(Id, Detail) then
  begin
    E := Default(TTurnEvent);
    E.Kind := teError;
    E.Text := 'redo refused: ' + Detail;
    FSession.Queue.Push(E);
  end;
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

function TLocalDriver.Dropped: Int64;
begin
  Result := FSession.Queue.Dropped;
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
