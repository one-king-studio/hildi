unit hildegard.helper.harness.turn;
{ The thread boundary between the agent and the UI.

  TAgentLoop.Send is synchronous and streams through callbacks. TTurnWorker runs
  one Send on a worker thread and republishes its callbacks as TTurnEvents on a
  thread-safe TTurnQueue, which the UI drains each frame. Approval prompts are
  bridged the other way by TApprovalGate: the worker blocks in Ask while the UI
  answers from its own thread.

  Nothing here knows about widgets, and nothing here links a terminal. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval;

type
  TTurnEventKind = (
    teUserMessage,      // the submitted prompt, echoed back
    teAssistantDelta,   // a chunk of assistant text
    teReasoningDelta,   // a chunk of reasoning text (display-only)
    teToolCall,         // a tool call was dispatched
    teToolResult,       // a tool returned
    teApprovalAsk,      // the worker is blocked awaiting an answer
    teDone,             // the turn completed successfully
    teError             // the turn failed
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
    Ask: TApprovalAsk;         // teApprovalAsk
    ErrorCode: TLLMErrorCode;  // teError
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
    function ElapsedMs: Int64;
    function Cancelled: Boolean;
    procedure Emit(const AEvent: TTurnEvent);
    procedure EmitError(ACode: TLLMErrorCode; const AMessage, ADetail: string);
    procedure OnText(const AText: string);
    procedure OnReasoning(const AText: string);
    procedure OnToolCall(const AId, AName, AArguments, AReason: string);
    procedure OnToolResult(const AId, AName, AResult: string; AOk: Boolean);
  protected
    procedure Execute; override;
  public
    constructor Create(ALoop: TAgentLoop; AQueue: TTurnQueue;
      const AUserText: string);
    { UI thread. The loop consults the flag between requests, so the turn stops
      at the next boundary; an in-flight stream finishes first. }
    procedure RequestCancel;
    property Answer: string read FAnswer;
    property Error: TLLMError read FError;
  end;

implementation

uses
  DateUtils;

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

{ TTurnWorker }

constructor TTurnWorker.Create(ALoop: TAgentLoop; AQueue: TTurnQueue;
  const AUserText: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLoop := ALoop;
  FQueue := AQueue;
  FUserText := AUserText;
  FError := Default(TLLMError);
end;

procedure TTurnWorker.RequestCancel;
begin
  FCancelled := True;
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
  const AMessage, ADetail: string);
var
  Event: TTurnEvent;
begin
  Event := Default(TTurnEvent);
  Event.Kind := teError;
  Event.ErrorCode := ACode;
  Event.Text := AMessage;
  Event.Detail := ADetail;
  Event.ElapsedMs := ElapsedMs;
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

procedure TTurnWorker.Execute;
var
  Events: TAgentEvents;
  Event: TTurnEvent;
begin
  FStart := Now;
  Events := Default(TAgentEvents);
  Events.OnText := OnText;
  Events.OnReasoning := OnReasoning;
  Events.OnToolCall := OnToolCall;
  Events.OnToolResult := OnToolResult;

  { The loop consults this between requests, so a cancel stops the turn at the
    next boundary and an in-flight stream still finishes. }
  FLoop.CancelCheck := Cancelled;
  try
    try
      if FLoop.Send(FUserText, Events, FAnswer, FError) then
      begin
        Event := Default(TTurnEvent);
        Event.Kind := teDone;
        Event.Answer := FAnswer;
        Event.ElapsedMs := ElapsedMs;
        Emit(Event);
      end
      else
        EmitError(FError.Code, FError.Message, FError.Detail);
    except
      on E: Exception do
        EmitError(leProvider, E.Message, '');
    end;
  finally
    FLoop.CancelCheck := nil;
  end;
end;

end.
