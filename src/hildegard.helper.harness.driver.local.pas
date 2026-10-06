unit hildegard.helper.harness.driver.local;
{ The in-process driver: runs the loop over a session's queue/gate via
  TTurnWorker, the original pre-headless path. Kept for tests and demos. It
  links the agent, so UI clients use hildegard.helper.harness.driver (the remote
  driver) instead. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.approval, hildegard.helper.harness.turn,
  hildegard.helper.harness.driver, hildegard.helper.harness.session;

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

function LocalDriver(ASession: THarnessSession): ISessionDriver;
begin
  Result := TLocalDriver.Create(ASession);
end;

end.
