unit hildegard.helper.harness.turn;
{ The thread-boundary types between the agent and the UI: TTurnEvent, the
  thread-safe TTurnQueue, and TApprovalGate.

  TAgentLoop.Send is synchronous and streams through callbacks; TTurnWorker (in
  hildegard.helper.harness.turn.worker) runs one Send on a worker thread and
  republishes its callbacks as TTurnEvents on the queue, which the UI drains
  each frame. Approval prompts are bridged the other way by TApprovalGate: the
  worker blocks in Ask while the UI answers from its own thread.

  Nothing here knows about widgets or the agent, so a UI client can depend on
  these types without linking the loop. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  async.queue,
  hildegard.helper.llm, hildegard.helper.approval;

type
  TTurnEventKind = (
    teUserMessage,      // the submitted prompt, echoed back
    teAssistantDelta,   // a chunk of assistant text
    teReasoningDelta,   // a chunk of reasoning text (display-only)
    teToolCall,         // a tool call was dispatched
    teToolResult,       // a tool returned
    tePromptQueued,     // a queued prompt was injected into the loop
    teApprovalAsk,      // the worker is blocked awaiting an answer
    teDone,             // the turn completed successfully
    teError,            // the turn failed
    teReasoningDone,    // the reasoning phase ended (ElapsedMs = its duration)
    teToolOutput,       // a streamed chunk of a tool's output
    { Subagent events, appended last so stored ordinals are unchanged:
      teSubagent is a roster update; teSubagentAsk is a child's approval ask
      relayed up; teAmbient is a delivered async-task result. }
    teSubagent, teSubagentAsk, teAmbient,
    { Context checkpoint: a checkpoint was recorded (ElapsedMs carries its boundary
      seq). Appended last so stored ordinals are unchanged. }
    teCheckpointCommitted
  );

  TTurnEvent = record
    Kind: TTurnEventKind;
    Text: string;              // message/delta/result text; error message
    Answer: string;            // final assistant text (teDone)
    Detail: string;            // error detail
    ToolId: string;
    ToolName: string;
    ToolArguments: string;     // raw JSON arguments
    ToolReason: string;        // the model's reason ('' when absent/invalid)
    ToolOk: Boolean;           // teToolResult
    RequestId: Integer;        // teApprovalAsk; 0 otherwise
    AskRef: string;            // teApprovalAsk: the reference to answer by
    Ask: TApprovalAsk;         // teApprovalAsk
    ErrorCode: TLLMErrorCode;  // teError
    Dropped: Boolean;          // teError: an early cancel dropped the turn
    ElapsedMs: Int64;          // teDone/teError
    { Subagent events: the child session, its label, and its status; teAmbient
      also carries the task's source. }
    SubSessionId: string;
    SubLabel: string;
    SubStatus: string;
    SubSource: string;
  end;

  { A thread-safe, BOUNDED FIFO. Push from the worker thread, Pop from the UI
    thread. Bounded so a fast producer cannot starve the consumer: on overflow
    the oldest event is dropped and counted (async.queue's TBoundedQueue).

    Control events (teDone, teError, teApprovalAsk, teCheckpointCommitted,
    teSubagentAsk) are never dropped: if the queue is full when one arrives, the
    oldest STREAMING event (teToolOutput, else any non-control event) is dropped
    to make room. A dropped control event would hang the UI (a lost teDone) or
    wedge a turn (a lost approval ask), so the streamed backlog yields instead. }
  TTurnQueue = class
  private
    FItems: TBoundedQueue<TTurnEvent>;
    function GetDropped: Int64;
    function IsControl(const AEvent: TTurnEvent): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(const AEvent: TTurnEvent);
    function Pop(out AEvent: TTurnEvent): Boolean;
    function IsEmpty: Boolean;
    property Dropped: Int64 read GetDropped;
  end;

  { Bridges the worker's approval prompt to the UI thread. The worker's Ask
    blocks until the UI Answers or Cancels (or ATimeoutMs elapses); the UI
    thread never blocks. At most one ask is pending at a time. }
  TApprovalGate = class
  private
    FQueue: TTurnQueue;
    FTimeoutMs: Integer;
    FLock: TCriticalSection;
    FEvent: TSimpleEvent;
    FRequestId: Integer;
    FNextId: Integer;
    FPending: Boolean;
    FChoice: TApprovalChoice;
  public
    constructor Create(AQueue: TTurnQueue; ATimeoutMs: Integer = 0);
    destructor Destroy; override;

    { Worker thread. Posts teApprovalAsk (with a fresh RequestId) and waits for
      Answer/Cancel, or until ATimeoutMs elapses (then denies). }
    function Ask(const AAsk: TApprovalAsk): TApprovalChoice;

    { TApprovalPrompt-compatible; passes through to Ask. }
    function Prompt(const AAsk: TApprovalAsk): TApprovalChoice;

    { UI thread. Resolve the pending ask and unblock the worker. Ignored when
      ARequestId is not the pending ask. }
    procedure Answer(ARequestId: Integer; const AChoice: TApprovalChoice);

    { UI thread. Deny any pending ask and unblock the worker (used on quit). }
    procedure Cancel;
  end;

const
  { The default approval wait: past it an unanswered ask is denied and the loop
    proceeds, so a disconnected driver never blocks the turn forever. }
  DefaultApprovalTimeoutMs = 300000;

  { The mailbox bound. On overflow the oldest event is dropped, so a streaming
    tool cannot grow the queue without limit. }
  TurnQueueCapacity = 4096;

implementation

{ TTurnQueue }

constructor TTurnQueue.Create;
begin
  inherited Create;
  FItems := TBoundedQueue<TTurnEvent>.Create(TurnQueueCapacity);
end;

destructor TTurnQueue.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TTurnQueue.Push(const AEvent: TTurnEvent);
begin
  { A control event is never dropped: make room for it by evicting the oldest
    streamed event when the queue is full. A streamed event yields via the
    queue's own drop-oldest. }
  if IsControl(AEvent) and (FItems.Count = FItems.Capacity) then
    FItems.DropOldest;
  FItems.Push(AEvent);
end;

function TTurnQueue.IsControl(const AEvent: TTurnEvent): Boolean;
begin
  Result := AEvent.Kind in [teDone, teError, teApprovalAsk,
    teCheckpointCommitted, teSubagentAsk];
end;

function TTurnQueue.Pop(out AEvent: TTurnEvent): Boolean;
begin
  Result := FItems.TryPop(AEvent);
end;

function TTurnQueue.IsEmpty: Boolean;
begin
  Result := FItems.IsEmpty;
end;

function TTurnQueue.GetDropped: Int64;
begin
  Result := FItems.Dropped;
end;

{ TApprovalGate }

constructor TApprovalGate.Create(AQueue: TTurnQueue; ATimeoutMs: Integer);
begin
  inherited Create;
  FQueue := AQueue;
  FTimeoutMs := ATimeoutMs;
  FLock := TCriticalSection.Create;
  FEvent := TSimpleEvent.Create;
  FRequestId := 0;
  FNextId := 0;
  FPending := False;
end;

destructor TApprovalGate.Destroy;
begin
  FEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

function TApprovalGate.Ask(const AAsk: TApprovalAsk): TApprovalChoice;
var
  Event: TTurnEvent;
  WaitRes: TWaitResult;
begin
  FEvent.ResetEvent;
  FLock.Acquire;
  try
    Inc(FNextId);
    FRequestId := FNextId;
    FPending := True;
    FChoice := Default(TApprovalChoice);
  finally
    FLock.Release;
  end;

  Event := Default(TTurnEvent);
  Event.Kind := teApprovalAsk;
  Event.RequestId := FRequestId;
  Event.Ask := AAsk;
  FQueue.Push(Event);

  if FTimeoutMs > 0 then
    WaitRes := FEvent.WaitFor(FTimeoutMs)
  else
    WaitRes := FEvent.WaitFor(INFINITE);

  FLock.Acquire;
  try
    if WaitRes = wrTimeout then
      FChoice := Default(TApprovalChoice);   // deny
    FPending := False;
    Result := FChoice;
  finally
    FLock.Release;
  end;
end;

function TApprovalGate.Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
begin
  Result := Ask(AAsk);
end;

procedure TApprovalGate.Answer(ARequestId: Integer;
  const AChoice: TApprovalChoice);
begin
  FLock.Acquire;
  try
    if FPending and (ARequestId = FRequestId) then
    begin
      FChoice := AChoice;
      FEvent.SetEvent;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TApprovalGate.Cancel;
begin
  FLock.Acquire;
  try
    if FPending then
    begin
      FChoice := Default(TApprovalChoice);
      FEvent.SetEvent;
    end;
  finally
    FLock.Release;
  end;
end;

end.
