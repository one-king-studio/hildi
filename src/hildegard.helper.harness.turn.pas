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
    teToolOutput        // a streamed chunk of a tool's output
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
  end;

  { A thread-safe FIFO. Push from the worker thread, Pop from the UI thread.
    Unbounded; a turn's output bounds its size in practice. The backing array is
    released once fully drained, so memory does not grow across turns. }
  TTurnQueue = class
  private
    FLock: TCriticalSection;
    FItems: array of TTurnEvent;
    FHead: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(const AEvent: TTurnEvent);
    function Pop(out AEvent: TTurnEvent): Boolean;
    function IsEmpty: Boolean;
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

implementation

{ TTurnQueue }

constructor TTurnQueue.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FHead := 0;
end;

destructor TTurnQueue.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TTurnQueue.Push(const AEvent: TTurnEvent);
begin
  FLock.Acquire;
  try
    SetLength(FItems, Length(FItems) + 1);
    FItems[High(FItems)] := AEvent;
  finally
    FLock.Release;
  end;
end;

function TTurnQueue.Pop(out AEvent: TTurnEvent): Boolean;
begin
  FLock.Acquire;
  try
    Result := FHead < Length(FItems);
    if not Result then
      Exit;
    AEvent := FItems[FHead];
    Inc(FHead);
    if FHead >= Length(FItems) then
    begin
      FItems := nil;
      FHead := 0;
    end;
  finally
    FLock.Release;
  end;
end;

function TTurnQueue.IsEmpty: Boolean;
begin
  FLock.Acquire;
  try
    Result := FHead >= Length(FItems);
  finally
    FLock.Release;
  end;
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
