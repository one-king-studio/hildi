unit hildegard.helper.harness.turn.worker;
{ TTurnWorker: runs one TAgentLoop.Send and republishes its callbacks as
  TTurnEvents on a TTurnQueue. This is the agent-coupled half of the turn
  boundary; the pure types live in hildegard.helper.harness.turn, so a UI client
  can depend on them without linking the loop.

  The turn runs as a job on an IAsyncScheduler (the Async Core executor), not on
  a dedicated TThread per turn: the caller passes a shared pool (the session's),
  so a session reuses threads across turns instead of creating and joining one
  each time. When no scheduler is passed the worker makes a private one-worker
  executor, so a standalone caller still works. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  async.base, async.scheduler, async.concurrency,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.harness.turn;

type
  { Runs one TAgentLoop.Send on a scheduler and translates its events into
    TTurnEvents on the queue. Owned by the caller; WaitFor (or Free) joins the
    run before the object goes away, because the scheduled job calls back into
    it. }
  TTurnWorker = class
  private
    FLoop: TAgentLoop;
    FQueue: TTurnQueue;
    FScheduler: IAsyncScheduler;
    FSub: ISubscription;
    FDone: TSimpleEvent;
    FUserText: string;
    FCancelled: Boolean;
    FAnswer: string;
    FError: TLLMError;
    FStart: TDateTime;
    FAmbient: Boolean;
    function ElapsedMs: Int64;
    function Cancelled: Boolean;
    procedure Emit(const AEvent: TTurnEvent);
    procedure EmitError(ACode: TLLMErrorCode; const AMessage, ADetail: string;
      ADropped: Boolean = False);
    procedure OnText(const AText: string);
    procedure OnReasoning(const AText: string);
    procedure OnReasoningDone(ADurationMs: Int64);
    procedure OnToolCall(const AId, AName, AArguments, AReason: string);
    procedure OnToolResult(const AId, AName, AResult: string; AOk: Boolean);
    procedure OnToolOutput(const AId, AName, AText: string);
    procedure OnUserQueued(const AText: string);
    { The scheduled job body (runs on a pool thread). }
    procedure RunTurn;
  public
    constructor Create(ALoop: TAgentLoop; AQueue: TTurnQueue;
      const AUserText: string; const AScheduler: IAsyncScheduler = nil);
    { Run an ambient turn: the loop's opening content is a queued ambient
      notification, so no user message is echoed. }
    constructor CreateAmbient(ALoop: TAgentLoop; AQueue: TTurnQueue;
      const AScheduler: IAsyncScheduler = nil);
    destructor Destroy; override;
    { Schedule the turn on the pool. }
    procedure Start;
    { Block until the turn's job has finished. Safe to call after Start. }
    procedure WaitFor;
    { Has the turn's job finished (or never started)? }
    function Finished: Boolean;
    { UI thread. The loop consults the flag between requests, so the turn stops
      at the next boundary; an in-flight stream finishes first. }
    procedure RequestCancel;
    { UI thread. Hand the running loop another prompt; it is injected at the
      next boundary. }
    procedure QueuePrompt(const AText: string);
    property Answer: string read FAnswer;
    property Error: TLLMError read FError;
  end;

implementation

uses
  DateUtils;

constructor TTurnWorker.Create(ALoop: TAgentLoop; AQueue: TTurnQueue;
  const AUserText: string; const AScheduler: IAsyncScheduler);
begin
  inherited Create;
  FLoop := ALoop;
  FQueue := AQueue;
  FUserText := AUserText;
  FAmbient := False;
  FError := Default(TLLMError);
  { A shared pool when given; otherwise a private one-worker executor, so a
    standalone caller (a test) still runs the turn off the calling thread. }
  if AScheduler <> nil then
    FScheduler := AScheduler
  else
    FScheduler := TExecutorScheduler.Create(1);
end;

constructor TTurnWorker.CreateAmbient(ALoop: TAgentLoop; AQueue: TTurnQueue;
  const AScheduler: IAsyncScheduler);
begin
  inherited Create;
  FLoop := ALoop;
  FQueue := AQueue;
  FUserText := '';
  FAmbient := True;
  FError := Default(TLLMError);
  if AScheduler <> nil then
    FScheduler := AScheduler
  else
    FScheduler := TExecutorScheduler.Create(1);
end;

destructor TTurnWorker.Destroy;
begin
  { The scheduled job calls back into this object, so it must not outlive us.
    The job always runs to completion and signals FDone, so this join is safe.
    FDone is nil when Start was never called (nothing to join). }
  if FDone <> nil then
  begin
    FDone.WaitFor(INFINITE);
    FDone.Free;
    FDone := nil;
  end;
  FSub := nil;
  inherited;
end;

procedure TTurnWorker.Start;
begin
  FDone := TSimpleEvent.Create;
  FSub := FScheduler.Schedule(RunTurn, 0);
end;

procedure TTurnWorker.WaitFor;
begin
  if FDone <> nil then
    FDone.WaitFor(INFINITE);
end;

function TTurnWorker.Finished: Boolean;
begin
  Result := (FDone = nil) or (FDone.WaitFor(0) = wrSignaled);
end;

procedure TTurnWorker.RequestCancel;
begin
  FCancelled := True;
end;

procedure TTurnWorker.QueuePrompt(const AText: string);
begin
  FLoop.PromptQueue.Push(AText);
end;

function TTurnWorker.ElapsedMs: Int64;
begin
  Result := MilliSecondsBetween(Now, FStart);
end;

function TTurnWorker.Cancelled: Boolean;
begin
  Result := FCancelled;
end;

procedure TTurnWorker.Emit(const AEvent: TTurnEvent);
begin
  FQueue.Push(AEvent);
end;

procedure TTurnWorker.EmitError(ACode: TLLMErrorCode;
  const AMessage, ADetail: string; ADropped: Boolean);
var
  Event: TTurnEvent;
begin
  Event := Default(TTurnEvent);
  Event.Kind := teError;
  Event.ErrorCode := ACode;
  Event.Text := AMessage;
  Event.Detail := ADetail;
  Event.Dropped := ADropped;
  Event.ElapsedMs := ElapsedMs;
  Emit(Event);
end;

procedure TTurnWorker.OnUserQueued(const AText: string);
var
  Event: TTurnEvent;
begin
  Event := Default(TTurnEvent);
  Event.Kind := tePromptQueued;
  Event.Text := AText;
  Emit(Event);
end;

procedure TTurnWorker.OnText(const AText: string);
var
  Event: TTurnEvent;
begin
  Event := Default(TTurnEvent);
  Event.Kind := teAssistantDelta;
  Event.Text := AText;
  Emit(Event);
end;

procedure TTurnWorker.OnReasoning(const AText: string);
var
  Event: TTurnEvent;
begin
  Event := Default(TTurnEvent);
  Event.Kind := teReasoningDelta;
  Event.Text := AText;
  Emit(Event);
end;

procedure TTurnWorker.OnReasoningDone(ADurationMs: Int64);
var
  Event: TTurnEvent;
begin
  Event := Default(TTurnEvent);
  Event.Kind := teReasoningDone;
  Event.ElapsedMs := ADurationMs;
  Emit(Event);
end;

procedure TTurnWorker.OnToolCall(const AId, AName, AArguments, AReason: string);
var
  Event: TTurnEvent;
begin
  Event := Default(TTurnEvent);
  Event.Kind := teToolCall;
  Event.ToolId := AId;
  Event.ToolName := AName;
  Event.ToolArguments := AArguments;
  Event.ToolReason := AReason;
  Emit(Event);
end;

procedure TTurnWorker.OnToolResult(const AId, AName, AResult: string;
  AOk: Boolean);
var
  Event: TTurnEvent;
begin
  Event := Default(TTurnEvent);
  Event.Kind := teToolResult;
  Event.ToolId := AId;
  Event.ToolName := AName;
  Event.Text := AResult;
  Event.ToolOk := AOk;
  Emit(Event);
end;

procedure TTurnWorker.OnToolOutput(const AId, AName, AText: string);
var
  Event: TTurnEvent;
begin
  Event := Default(TTurnEvent);
  Event.Kind := teToolOutput;
  Event.ToolId := AId;
  Event.ToolName := AName;
  Event.Text := AText;
  Emit(Event);
end;

procedure TTurnWorker.RunTurn;
var
  Events: TAgentEvents;
  Event: TTurnEvent;
  Ok: Boolean;
begin
  FStart := Now;
  try
    Events := Default(TAgentEvents);
    Events.OnText := OnText;
    Events.OnReasoning := OnReasoning;
    Events.OnReasoningDone := OnReasoningDone;
    Events.OnToolCall := OnToolCall;
    Events.OnToolResult := OnToolResult;
    Events.OnToolOutput := OnToolOutput;
    Events.OnUserQueued := OnUserQueued;

    { The loop consults this between requests, so a cancel stops the turn at the
      next boundary and an in-flight stream still finishes. }
    FLoop.CancelCheck := Cancelled;
    try
      try
        if FAmbient then
          Ok := FLoop.SendAmbient(Events, FAnswer, FError)
        else
          Ok := FLoop.Send(FUserText, Events, FAnswer, FError);
        if Ok then
        begin
          Event := Default(TTurnEvent);
          Event.Kind := teDone;
          Event.Answer := FAnswer;
          Event.ElapsedMs := ElapsedMs;
          Emit(Event);
        end
        else
          EmitError(FError.Code, FError.Message, FError.Detail,
            FLoop.LastTurnDropped);
      except
        on E: Exception do
          EmitError(leProvider, E.Message, '');
      end;
    finally
      FLoop.CancelCheck := nil;
    end;
  finally
    { Always signal: the destructor joins on this. }
    FDone.SetEvent;
  end;
end;

end.
