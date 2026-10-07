unit hildegard.helper.harness.turn.worker;
{ TTurnWorker: runs one TAgentLoop.Send on a worker thread and republishes its
  callbacks as TTurnEvents on a TTurnQueue. This is the agent-coupled half of
  the turn boundary; the pure types live in hildegard.helper.harness.turn, so a
  UI client can depend on them without linking the loop. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.harness.turn;

type
  { Runs one TAgentLoop.Send on a worker thread, translating its events into
    TTurnEvents on the queue. Owned by the app; always joined before freeing
    (TThread.Destroy waits for the thread). }
  TTurnWorker = class(TThread)
  private
    FLoop: TAgentLoop;
    FQueue: TTurnQueue;
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
  protected
    procedure Execute; override;
  public
    constructor Create(ALoop: TAgentLoop; AQueue: TTurnQueue;
      const AUserText: string);
    { Run an ambient turn: the loop's opening content is a queued ambient
      notification, so no user message is echoed. }
    constructor CreateAmbient(ALoop: TAgentLoop; AQueue: TTurnQueue);
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
  const AUserText: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLoop := ALoop;
  FQueue := AQueue;
  FUserText := AUserText;
  FAmbient := False;
  FError := Default(TLLMError);
end;

constructor TTurnWorker.CreateAmbient(ALoop: TAgentLoop; AQueue: TTurnQueue);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLoop := ALoop;
  FQueue := AQueue;
  FUserText := '';
  FAmbient := True;
  FError := Default(TLLMError);
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

procedure TTurnWorker.Execute;
var
  Events: TAgentEvents;
  Event: TTurnEvent;
  Ok: Boolean;
begin
  FStart := Now;
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
end;

end.
