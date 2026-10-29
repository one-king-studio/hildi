unit TestHarnessTurn;
{ fpcunit tests for HildiHarnessTurn: the thread-safe event queue,
  the approval gate that bridges the worker to the UI, and the turn worker that
  maps agent callbacks to turn events. Uses the fake LLM transport; no terminal
  and no real network. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  HildiLLM, HildiAgent, HildiApproval,
  HildiHarnessTurn, HildiHarnessTurnWorker,
  LLMFakes;

type
  { Runs Gate.Ask on its own thread so the main thread can Answer/Cancel. }
  TGateAskThread = class(TThread)
  private
    FGate: TApprovalGate;
    FAsk: TApprovalAsk;
  public
    Choice: TApprovalChoice;
    constructor Create(AGate: TApprovalGate; const AAsk: TApprovalAsk);
    procedure Execute; override;
  end;

  { Pushes ACount events onto a shared queue, to stress concurrent access. }
  TQueuePushThread = class(TThread)
  private
    FQueue: TTurnQueue;
    FCount: Integer;
  public
    constructor Create(AQueue: TTurnQueue; ACount: Integer);
    procedure Execute; override;
  end;

  { Emits one chunk through the observer, then returns a result. }
  TStreamTool = class
  public
    function Handle(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;

  TTurnQueueTest = class(TTestCase)
  published
    procedure TestFifoOrderAndEmpty;
    procedure TestConcurrentPushPop;
    procedure TestControlEventIsNotDropped;
  end;

  TApprovalGateTest = class(TTestCase)
  private
    FQueue: TTurnQueue;
    function WaitForAsk(out AEvent: TTurnEvent): Boolean;
    function MakeAsk: TApprovalAsk;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestAskBlocksUntilAnswer;
    procedure TestTimeoutDenies;
    procedure TestCancelDenies;
    procedure TestStaleAnswerIgnored;
    procedure TestConcurrentAsksAreIndependent;
    procedure TestCancelAllDeniesEveryOutstandingAsk;
  end;

  TTurnWorkerTest = class(TTestCase)
  private
    FFake: TFakeTransport;
    FClient: TLLMClient;
    FStore: TMemoryConversationStore;
    FTools: TToolRegistry;
    FLoop: TAgentLoop;
    FQueue: TTurnQueue;
    function BuildLoop(ARegisterTools: Boolean): TAgentLoop;
    function Drain: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestStreamsDeltasThenDone;
    procedure TestProviderErrorEmitsError;
    procedure TestToolEventsCarryNameReasonOk;
    procedure TestWorkerEmitsToolOutput;
    procedure TestCancelBeforeStart;
  end;

implementation

{ TGateAskThread }

constructor TGateAskThread.Create(AGate: TApprovalGate;
  const AAsk: TApprovalAsk);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FGate := AGate;
  FAsk := AAsk;
end;

procedure TGateAskThread.Execute;
begin
  Choice := FGate.Ask(FAsk);
end;

{ TQueuePushThread }

constructor TQueuePushThread.Create(AQueue: TTurnQueue; ACount: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FQueue := AQueue;
  FCount := ACount;
end;

procedure TQueuePushThread.Execute;
var
  I: Integer;
  Event: TTurnEvent;
begin
  for I := 0 to FCount - 1 do
  begin
    Event := Default(TTurnEvent);
    Event.Kind := teAssistantDelta;
    Event.Text := IntToStr(I);
    FQueue.Push(Event);
  end;
end;

{ TStreamTool }

function TStreamTool.Handle(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
begin
  if AObserver <> nil then
    AObserver.Next('partial output');
  AResult := 'partial output';
  AError := '';
  Result := True;
end;

{ TTurnQueueTest }

procedure TTurnQueueTest.TestFifoOrderAndEmpty;
var
  Queue: TTurnQueue;
  Event: TTurnEvent;
  A, B, C: TTurnEvent;
begin
  Queue := TTurnQueue.Create;
  try
    AssertTrue('empty at first', Queue.IsEmpty);
    AssertFalse('nothing to pop', Queue.Pop(Event));

    A := Default(TTurnEvent);
    A.Kind := teAssistantDelta;
    A.Text := 'a';
    B := Default(TTurnEvent);
    B.Kind := teAssistantDelta;
    B.Text := 'b';
    C := Default(TTurnEvent);
    C.Kind := teAssistantDelta;
    C.Text := 'c';
    Queue.Push(A);
    Queue.Push(B);
    Queue.Push(C);
    AssertFalse('not empty', Queue.IsEmpty);

    AssertTrue(Queue.Pop(Event));
    AssertEquals('first', 'a', Event.Text);
    AssertTrue(Queue.Pop(Event));
    AssertEquals('second', 'b', Event.Text);
    AssertTrue(Queue.Pop(Event));
    AssertEquals('third', 'c', Event.Text);
    AssertFalse('drained', Queue.Pop(Event));
    AssertTrue('empty after drain', Queue.IsEmpty);
  finally
    Queue.Free;
  end;
end;

procedure TTurnQueueTest.TestConcurrentPushPop;
const
  Threads = 4;
  PerThread = 250;
var
  Queue: TTurnQueue;
  Workers: array[0..Threads - 1] of TQueuePushThread;
  I, Seen: Integer;
  Event: TTurnEvent;
begin
  Queue := TTurnQueue.Create;
  try
    for I := 0 to Threads - 1 do
    begin
      Workers[I] := TQueuePushThread.Create(Queue, PerThread);
      Workers[I].Start;
    end;
    for I := 0 to Threads - 1 do
    begin
      Workers[I].WaitFor;
      Workers[I].Free;
    end;
    Seen := 0;
    while Queue.Pop(Event) do
      Inc(Seen);
    AssertEquals('all events', Threads * PerThread, Seen);
  finally
    Queue.Free;
  end;
end;

procedure TTurnQueueTest.TestControlEventIsNotDropped;
var
  Queue: TTurnQueue;
  Streamed, Done, E: TTurnEvent;
  I, Deltas: Integer;
begin
  Queue := TTurnQueue.Create;
  try
    { Fill well past the capacity with streamed output. }
    for I := 1 to 5000 do
    begin
      Streamed := Default(TTurnEvent);
      Streamed.Kind := teToolOutput;
      Streamed.Text := 'x';
      Queue.Push(Streamed);
    end;
    AssertTrue('the bound was hit', Queue.Dropped > 0);
    { A terminal event arrives into a full queue: it must survive, evicting a
      streamed event to make room. }
    Done := Default(TTurnEvent);
    Done.Kind := teDone;
    Queue.Push(Done);
    Deltas := 0;
    while Queue.Pop(E) do
      if E.Kind = teDone then
        Inc(Deltas);
    AssertEquals('the terminal event survived', 1, Deltas);
  finally
    Queue.Free;
  end;
end;

{ TApprovalGateTest }

procedure TApprovalGateTest.SetUp;
begin
  FQueue := TTurnQueue.Create;
end;

procedure TApprovalGateTest.TearDown;
begin
  FQueue.Free;
end;

function TApprovalGateTest.MakeAsk: TApprovalAsk;
var
  Option: TApprovalOption;
begin
  Result := Default(TApprovalAsk);
  Result.Summary := 'Run cat?';
  Result.Subject.Ref := 'run_command:cat';
  Option := Default(TApprovalOption);
  Option.Key := 'once';
  Option.Caption := 'Allow once';
  SetLength(Result.Options, 1);
  Result.Options[0] := Option;
end;

function TApprovalGateTest.WaitForAsk(out AEvent: TTurnEvent): Boolean;
var
  Waited: Integer;
begin
  Waited := 0;
  while Waited < 2000 do
  begin
    if FQueue.Pop(AEvent) then
      Exit(AEvent.Kind = teApprovalAsk);
    Sleep(1);
    Inc(Waited);
  end;
  Result := False;
end;

procedure TApprovalGateTest.TestAskBlocksUntilAnswer;
var
  Gate: TApprovalGate;
  Thread: TGateAskThread;
  Ask: TTurnEvent;
  Choice: TApprovalChoice;
begin
  Gate := TApprovalGate.Create(FQueue);
  try
    Thread := TGateAskThread.Create(Gate, MakeAsk);
    Thread.Start;
    AssertTrue('ask posted', WaitForAsk(Ask));
    AssertEquals('ask summary', 'Run cat?', Ask.Ask.Summary);
    AssertTrue('request id set', Ask.RequestId > 0);

    Choice := Default(TApprovalChoice);
    Choice.Allowed := True;
    Choice.OptionKey := 'once';
    Gate.Answer(Ask.RequestId, Choice);

    Thread.WaitFor;
    AssertTrue('allowed', Thread.Choice.Allowed);
    AssertEquals('option key', 'once', Thread.Choice.OptionKey);
    Thread.Free;
  finally
    Gate.Free;
  end;
end;

procedure TApprovalGateTest.TestTimeoutDenies;
var
  Gate: TApprovalGate;
  Choice: TApprovalChoice;
begin
  Gate := TApprovalGate.Create(FQueue, 30);
  try
    Choice := Gate.Ask(MakeAsk);
    AssertFalse('denied on timeout', Choice.Allowed);
    AssertEquals('no option', '', Choice.OptionKey);
  finally
    Gate.Free;
  end;
end;

procedure TApprovalGateTest.TestCancelDenies;
var
  Gate: TApprovalGate;
  Thread: TGateAskThread;
  Ask: TTurnEvent;
begin
  Gate := TApprovalGate.Create(FQueue);
  try
    Thread := TGateAskThread.Create(Gate, MakeAsk);
    Thread.Start;
    AssertTrue('ask posted', WaitForAsk(Ask));
    Gate.Cancel;
    Thread.WaitFor;
    AssertFalse('denied', Thread.Choice.Allowed);
    Thread.Free;
  finally
    Gate.Free;
  end;
end;

procedure TApprovalGateTest.TestStaleAnswerIgnored;
var
  Gate: TApprovalGate;
  Thread: TGateAskThread;
  Ask: TTurnEvent;
  Stale, Real: TApprovalChoice;
begin
  Gate := TApprovalGate.Create(FQueue);
  try
    Thread := TGateAskThread.Create(Gate, MakeAsk);
    Thread.Start;
    AssertTrue('ask posted', WaitForAsk(Ask));

    Stale := Default(TApprovalChoice);
    Stale.Allowed := False;
    Gate.Answer(Ask.RequestId + 999, Stale);

    Real := Default(TApprovalChoice);
    Real.Allowed := True;
    Real.OptionKey := 'exact';
    Gate.Answer(Ask.RequestId, Real);

    Thread.WaitFor;
    AssertTrue('stale ignored; real applied', Thread.Choice.Allowed);
    AssertEquals('real option', 'exact', Thread.Choice.OptionKey);
    Thread.Free;
  finally
    Gate.Free;
  end;
end;

procedure TApprovalGateTest.TestConcurrentAsksAreIndependent;
var
  Gate: TApprovalGate;
  T1, T2: TGateAskThread;
  Ask: TTurnEvent;
  Choice: TApprovalChoice;
  IdA, IdB: Integer;
  Finished: Integer;
begin
  { Two asks outstanding at once. Answering one must release exactly that one;
    the other stays blocked until it is answered. The asks carry the same
    content, so we track them by id, not by thread - pop order is not the start
    order. }
  Gate := TApprovalGate.Create(FQueue);
  try
    T1 := TGateAskThread.Create(Gate, MakeAsk);
    T2 := TGateAskThread.Create(Gate, MakeAsk);
    T1.Start;
    T2.Start;

    AssertTrue('ask A posted', WaitForAsk(Ask));
    IdA := Ask.RequestId;
    AssertTrue('ask B posted', WaitForAsk(Ask));
    IdB := Ask.RequestId;
    AssertTrue('distinct ids', IdA <> IdB);

    { Answer B only. Exactly one worker must release; the other stays blocked. }
    Choice := Default(TApprovalChoice);
    Choice.Allowed := True;
    Choice.OptionKey := 'once';
    Gate.Answer(IdB, Choice);

    { Give the released worker a moment; then count how many finished. }
    Sleep(50);
    Finished := 0;
    if T1.Finished then
      Inc(Finished);
    if T2.Finished then
      Inc(Finished);
    AssertEquals('exactly one released', 1, Finished);

    { Now answer A (denied): both are released. }
    Choice := Default(TApprovalChoice);
    Gate.Answer(IdA, Choice);
    T1.WaitFor;
    T2.WaitFor;
    { Whichever thread carried B was allowed; the other was denied. Exactly one
      allowed. }
    AssertTrue('exactly one allowed',
      T1.Choice.Allowed xor T2.Choice.Allowed);

    T1.Free;
    T2.Free;
  finally
    Gate.Free;
  end;
end;

procedure TApprovalGateTest.TestCancelAllDeniesEveryOutstandingAsk;
var
  Gate: TApprovalGate;
  T1, T2, T3: TGateAskThread;
  Ask: TTurnEvent;
  I: Integer;
begin
  { CancelAll releases every outstanding ask (a batch's waiting calls). }
  Gate := TApprovalGate.Create(FQueue);
  try
    T1 := TGateAskThread.Create(Gate, MakeAsk);
    T2 := TGateAskThread.Create(Gate, MakeAsk);
    T3 := TGateAskThread.Create(Gate, MakeAsk);
    T1.Start;
    T2.Start;
    T3.Start;
    for I := 1 to 3 do
      AssertTrue('ask posted', WaitForAsk(Ask));

    Gate.CancelAll;
    T1.WaitFor;
    T2.WaitFor;
    T3.WaitFor;
    AssertFalse('all denied', T1.Choice.Allowed or T2.Choice.Allowed or
      T3.Choice.Allowed);

    T1.Free;
    T2.Free;
    T3.Free;
  finally
    Gate.Free;
  end;
end;

{ TTurnWorkerTest }

procedure TTurnWorkerTest.SetUp;
begin
  FQueue := TTurnQueue.Create;
end;

procedure TTurnWorkerTest.TearDown;
begin
  FLoop.Free;
  FTools.Free;
  FStore := nil;
  FClient.Free;
  FFake.Free;
  FQueue.Free;
  FLoop := nil;
  FTools := nil;
  FClient := nil;
  FFake := nil;
end;

function TTurnWorkerTest.BuildLoop(ARegisterTools: Boolean): TAgentLoop;
var
  Cfg: TLLMConfig;
  ACfg: TAgentConfig;
begin
  Cfg := Default(TLLMConfig);
  Cfg.Endpoint := 'https://example.test/v1/chat/completions';
  Cfg.Model := 'm';
  Cfg.ApiKey := 'k';
  Cfg.ConnectTimeoutMs := 1000;
  Cfg.ReadTimeoutMs := 5000;
  FFake := TFakeTransport.Create;
  FClient := TLLMClient.Create(Cfg, FFake);
  FStore := TMemoryConversationStore.Create;
  FTools := TToolRegistry.Create;
  ACfg := Default(TAgentConfig);
  { The retry would delay a failed turn; these tests exercise the event mapping. }
  ACfg.RetryMaxAttempts := -1;
  FLoop := TAgentLoop.Create(FClient, FStore, FTools, ACfg);
  if ARegisterTools then
    RegisterDefaultTools(FTools);
  Result := FLoop;
end;

function TTurnWorkerTest.Drain: string;
var
  Event: TTurnEvent;
begin
  Result := '';
  while FQueue.Pop(Event) do
  begin
    case Event.Kind of
      teAssistantDelta:
        Result := Result + 'T:' + Event.Text + '|';
      teReasoningDelta:
        Result := Result + 'R:' + Event.Text + '|';
      teToolCall:
        Result := Result + 'C:' + Event.ToolName + ':' + Event.ToolReason + '|';
      teToolResult:
        Result := Result + 'X:' + Event.ToolName + ':' +
          BoolToStr(Event.ToolOk, True) + ':' + Event.Text + '|';
      teToolOutput:
        Result := Result + 'O:' + Event.ToolName + ':' + Event.Text + '|';
      teUserMessage:
        Result := Result + 'U:' + Event.Text + '|';
      tePromptQueued:
        Result := Result + 'Q:' + Event.Text + '|';
      teApprovalAsk:
        Result := Result + 'A:' + IntToStr(Event.RequestId) + '|';
      teDone:
        Result := Result + 'D:' + Event.Answer + '|';
      teError:
        Result := Result + 'E:' + IntToStr(Ord(Event.ErrorCode)) + ':' +
          Event.Text + '|';
      teReasoningDone:
        Result := Result + 'RD:' + IntToStr(Event.ElapsedMs) + '|';
    else
      { teSubagent/teSubagentAsk/teAmbient are not produced by the worker. }
      ;
    end;
  end;
end;

procedure TTurnWorkerTest.TestStreamsDeltasThenDone;
var
  Worker: TTurnWorker;
begin
  BuildLoop(False);
  FFake.AddChunk(TextDelta('Hello'));
  FFake.AddChunk(TextDelta(', '));
  FFake.AddChunk(TextDelta('world'));
  FFake.AddChunk(FinishFrame('stop'));
  FFake.AddChunk(DoneFrame);

  Worker := TTurnWorker.Create(FLoop, FQueue, 'hi');
  Worker.Start;
  Worker.WaitFor;
  try
    AssertEquals('stream then done', 'T:Hello|T:, |T:world|D:Hello, world|',
      Drain);
  finally
    Worker.Free;
  end;
end;

procedure TTurnWorkerTest.TestProviderErrorEmitsError;
var
  Worker: TTurnWorker;
begin
  BuildLoop(False);
  FFake.FailNetwork := True;

  Worker := TTurnWorker.Create(FLoop, FQueue, 'hi');
  Worker.Start;
  Worker.WaitFor;
  try
    AssertEquals('network error', 'E:2:network error|', Drain);
  finally
    Worker.Free;
  end;
end;

procedure TTurnWorkerTest.TestToolEventsCarryNameReasonOk;
var
  Worker: TTurnWorker;
  Log: string;
begin
  BuildLoop(True);
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"testing"}'), FinishFrame('tool_calls'),
    DoneFrame]);
  FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);

  Worker := TTurnWorker.Create(FLoop, FQueue, 'time?');
  Worker.Start;
  Worker.WaitFor;
  try
    Log := Drain;
    AssertTrue('tool call with reason',
      Pos('C:get_system_time:testing|', Log) > 0);
    AssertTrue('tool result ok',
      Pos('X:get_system_time:True:', Log) > 0);
    AssertTrue('ends with done',
      Pos('T:done|D:done|', Log) > 0);
  finally
    Worker.Free;
  end;
end;

procedure TTurnWorkerTest.TestWorkerEmitsToolOutput;
var
  Worker: TTurnWorker;
  StreamTool: TStreamTool;
  Spec: TToolSpec;
  Log: string;
  OutputIdx, ResultIdx: Integer;
begin
  BuildLoop(True);
  StreamTool := TStreamTool.Create;
  try
    Spec.Name := 'stream_tool';
    Spec.Description := 'streams output';
    Spec.ParametersJson := '{"type":"object","properties":{}}';
    FTools.Add(Spec, StreamTool.Handle);
    FFake.AddResponse([ToolNameFrame(0, 'call_1', 'stream_tool'),
      ToolArgsFrame(0, '{"reason":"testing"}'), FinishFrame('tool_calls'),
      DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);

    Worker := TTurnWorker.Create(FLoop, FQueue, 'go');
    Worker.Start;
    Worker.WaitFor;
    try
      Log := Drain;
      AssertTrue('streamed chunk',
        Pos('O:stream_tool:partial output|', Log) > 0);
      OutputIdx := Pos('O:stream_tool:', Log);
      ResultIdx := Pos('X:stream_tool:', Log);
      AssertTrue('chunk before result',
        (OutputIdx > 0) and (ResultIdx > OutputIdx));
    finally
      Worker.Free;
    end;
  finally
    StreamTool.Free;
  end;
end;

procedure TTurnWorkerTest.TestCancelBeforeStart;
var
  Worker: TTurnWorker;
begin
  BuildLoop(False);
  Worker := TTurnWorker.Create(FLoop, FQueue, 'hi');
  Worker.RequestCancel;
  Worker.Start;
  Worker.WaitFor;
  try
    { The loop's first boundary check sees the flag, so the turn is cancelled
      before any request is sent (leCancelled = 8). }
    AssertEquals('cancelled', 'E:8:cancelled|', Drain);
  finally
    Worker.Free;
  end;
end;

initialization
  RegisterTest(TTurnQueueTest);
  RegisterTest(TApprovalGateTest);
  RegisterTest(TTurnWorkerTest);

end.
