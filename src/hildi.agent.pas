unit hildi.agent;
{ Single-threaded agent loop. Owns the conversation, injects tools, drives the
  LLM client, executes the tool calls the model requests, feeds the results
  back, and re-queries until a proper stop reason or a bounded iteration limit.
  Conversations live behind IConversationStore (in-memory today; SQLite later). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  async.base, async.scheduler,
  hildi.llm, hildi.session,
  hildi.ambient, hildi.wrap;

type
  { The outcome of one LLM request, for the audit/metrics seam. }
  TRequestOutcome = record
    Ok: Boolean;
    FinishReason: TFinishReason;
    RawFinishReason: string;
    ErrorCode: TLLMErrorCode;
    ErrorMessage: string;
    ErrorDetail: string;
    Usage: TTokenUsage;
    DurationMs: Int64;
    FirstTokenMs: Int64;
  end;

  { The outcome of one turn (loop), for the audit/metrics seam. }
  TTurnOutcome = record
    Status: TTurnStatus;
    FinishReason: string;
    ErrorCode: TLLMErrorCode;
    ErrorMessage: string;
    ErrorDetail: string;
  end;

  { Consulted at each loop boundary; True stops the turn as cancelled. }
  TAgentCancelCheck = function: Boolean of object;

  { Invoked once at the start of a turn, on the loop's thread, before the first
    request. The owner may mutate the tool registry here; the loop snapshots the
    registry per request, so a boundary mutation is race-free. }
  TAgentBoundaryEvent = procedure of object;

  { Fires once per turn, right after the turn row is opened, with its id. The
    change log needs it: a change is attributed to a turn, and the turn's id is
    only known here. }
  TAgentTurnEvent = procedure(ATurnId: Int64) of object;

  { The loop's persistence seam: the conversation it replays, the display-only
    blocks it produces, and the turn/request audit. An implementation that does
    not persist (in-memory) ignores the audit calls and returns 0 for the ids. }
  IConversationStore = interface
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    procedure Clear;
    { Display-only blocks: persisted for restore, never sent to the provider.
      ADurationMs is the wall time the reasoning streamed (0 when unknown). }
    procedure AppendReasoning(const AText: string; ADurationMs: Int64);
    procedure AppendError(const AMessage, ADetail: string);
    { An ambient (async task result) notification. Delivered to the provider as
      a user message wrapped by hildi.ambient; persisted as its own
      kind (mrAmbient) with the task's id, label, source, status, and elapsed. }
    procedure AppendAmbient(const AText, ARefSessionId, ALabel, ASource,
      AStatus: string; AElapsedMs: Int64);
    { Turn/request audit. BeginTurn opens a loop; the user prompt is appended
      separately, linked to the open turn. Ids are 0 when not persisted. }
    function BeginTurn: Int64;
    function BeginRequest(ATurnId: Int64; const AModel: string;
      AMessageCount: Integer): Int64;
    procedure FinishRequest(ARequestId: Int64; const AOutcome: TRequestOutcome);
    procedure FinishTurn(ATurnId: Int64; const AOutcome: TTurnOutcome);
    { Drop every message the open turn appended, keeping the turn row. An early
      cancel leaves no trace. }
    procedure DropTurnMessages(ATurnId: Int64);
  end;

  TMemoryConversationStore = class(TInterfacedObject, IConversationStore)
  private
    FItems: TChatMessageArray;
    FTurnMark: Integer;
  public
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    procedure Clear;
    procedure AppendReasoning(const AText: string; ADurationMs: Int64);
    procedure AppendError(const AMessage, ADetail: string);
    procedure AppendAmbient(const AText, ARefSessionId, ALabel, ASource,
      AStatus: string; AElapsedMs: Int64);
    function BeginTurn: Int64;
    function BeginRequest(ATurnId: Int64; const AModel: string;
      AMessageCount: Integer): Int64;
    procedure FinishRequest(ARequestId: Int64; const AOutcome: TRequestOutcome);
    procedure FinishTurn(ATurnId: Int64; const AOutcome: TTurnOutcome);
    procedure DropTurnMessages(ATurnId: Int64);
  end;

  { A tool's output observer, RxJS-shaped. A streaming tool calls Next for each
    chunk (flushed immediately) and then returns its result; Complete ends the
    stream. A single-shot tool never calls Next. Next may fire on another
    thread (e.g. the process runner's), so an implementation must be
    thread-safe. }
  TToolObserver = class
  public
    procedure Next(const AText: string); virtual; abstract;
    procedure Complete; virtual; abstract;
    { The provider's id for the call this observer belongs to, or '' when the
      observer is not per-call. A tool that reports side effects needs it to say
      WHICH call produced them - without it, two concurrent calls cannot be told
      apart and an attribution would be a guess. }
    function ToolCallId: string; virtual;
  end;

  { Fires for each streamed chunk of a tool's output. }
  TToolOutputEvent = procedure(const AId, AName, AText: string) of object;

  { Forwards a tool's chunks to a caller's OnToolOutput, capturing the call's
    id and name. Chunks may arrive on the process runner's thread. Once Complete
    is called, later chunks are dropped. }
  TToolForwardObserver = class(TToolObserver)
  private
    FId, FName: string;
    FOnOutput: TToolOutputEvent;
    FDone: Boolean;
  public
    constructor Create(const AId, AName: string; AOnOutput: TToolOutputEvent);
    procedure Next(const AText: string); override;
    procedure Complete; override;
    function ToolCallId: string; override;
  end;

  { Receives the raw JSON arguments string and an output observer, and returns a
    text result. On failure returns False with AError set; the loop turns that
    into an error tool result. }
  TToolHandler = function(const AArgumentsJson: string;
    out AResult: string; out AError: string;
    AObserver: TToolObserver = nil): Boolean of object;

  { Fires before dispatch. AReason is the model's stated reason for the call, or
    '' when the arguments had none or it was invalid. }
  TToolCallEvent = procedure(const AId, AName, AArguments, AReason: string)
    of object;
  TToolResultEvent = procedure(const AId, AName, AResult: string;
    AOk: Boolean) of object;
  { A queued prompt was injected into the running loop. }
  TUserQueuedEvent = procedure(const AText: string) of object;
  { An ambient (async task result) notification was injected into the running
    loop. ARefSessionId, ALabel, ASource, and AStatus identify the producing
    task and its outcome. }
  TAmbientEvent = procedure(const AText, ARefSessionId, ALabel, ASource,
    AStatus: string; AElapsedMs: Int64) of object;
  { The reasoning phase of a response ended; ADurationMs is how long it
    streamed. Fired just before the first content delta, so the UI can settle a
    live thought block with its duration. }
  TReasoningDoneEvent = procedure(ADurationMs: Int64) of object;

  TAgentEvents = record
    OnText: TLLMTextEvent;
    OnReasoning: TLLMReasoningEvent;
    OnReasoningDone: TReasoningDoneEvent;
    OnToolCall: TToolCallEvent;
    OnToolResult: TToolResultEvent;
    OnToolOutput: TToolOutputEvent;
    OnUserQueued: TUserQueuedEvent;
    OnAmbient: TAmbientEvent;
  end;

  TPromptArray = array of string;

  { A queued prompt is either operator text, an ambient subagent result, or a
    board notice. A board notice is TRANSIENT: it is delivered in the tail and
    never persisted, because ten agents posting would otherwise leave 90
    permanent conversation rows that ride every later prompt. }
  TPromptKind = (pkUser, pkAmbient, pkBoard);

  TPromptItem = record
    Kind: TPromptKind;
    Text: string;
    RefSessionId: string;   // pkAmbient: the task id
    LabelText: string;      // pkAmbient: the task's human label
    Source: string;         // pkAmbient: the producing tool
    Status: string;         // pkAmbient: completed/failed/aborted/gone
    ElapsedMs: Int64;       // pkAmbient: the task duration
    Count: Integer;         // pkBoard: how many entries the notice coalesces
  end;

  TPromptItemArray = array of TPromptItem;

  { Prompts the operator injects into a running turn, drained at loop
    boundaries. Safe to Push from the UI thread while the worker drains it. }
  TPromptQueue = class
  private
    FLock: TCriticalSection;
    FItems: TPromptItemArray;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(const AText: string);
    { Queue an ambient (async task result) notification. }
    procedure PushAmbient(const AText, ARefSessionId, ALabel, ASource,
      AStatus: string; AElapsedMs: Int64);
    { Queue a board notice. Transient: delivered in the tail, never persisted.
      ACount coalesces several entries into one notice so ten agents posting is
      O(agents x ticks), not O(agents x entries). }
    procedure PushBoard(const AText: string; ACount: Integer);
    { Remove and return every queued item, in order. }
    function DrainItems: TPromptItemArray;
    { The queued operator prompts only, in order (ambients excluded). }
    function Drain: TPromptArray;
    function Pending: Boolean;
  end;

  TRegisteredTool = record
    Spec: TToolSpec;
    Handler: TToolHandler;
  end;

  TToolRegistry = class
  private
    FTools: array of TRegisteredTool;
  public
    { A spec with an empty Name is ignored (see the spec's pinned behaviour). }
    procedure Add(const ASpec: TToolSpec; AHandler: TToolHandler);
    { Remove a tool by name. True when it was present. Absent is a no-op. }
    function Remove(const AName: string): Boolean;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    function Specs: TToolSpecArray;
    function Count: Integer;
  end;

  { A per-turn source of tools and prompt. Prepare is called once at turn start
    on the loop's thread; Specs/PromptFragment/Find are read while assembling the
    request. Implementations need not be thread-safe (loop thread only). }
  IToolProvider = interface
    { Reconcile or activate; called once per turn, in registration order. }
    procedure Prepare;
    { The tools currently offered (already reason-augmented specs). }
    function Specs: TToolSpecArray;
    { A request-only prompt fragment, or '' for none. Never persisted. }
    function PromptFragment: string;
    { Resolve a called tool name to a handler; first provider to return True
      wins. }
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
  end;

  TAgentConfig = record
    SystemPrompt: string;
    { The workspace root, so the user turn's <context> can state it and the model
      grounds shell paths instead of guessing one (it has guessed /workspace).
      Empty when unknown. }
    WorkspaceRoot: string;
    { Tool-call budget for one turn. From SoftToolLimit the model is nudged
      every ToolNoticeStep calls (the call is intercepted and it must resubmit);
      at HardToolLimit it is locked down; one call past that ends the turn as a
      loop error. 0 fields take the defaults below. }
    SoftToolLimit: Integer;
    HardToolLimit: Integer;
    ToolNoticeStep: Integer;
    { Fail the turn once the running context (the latest request's prompt
      tokens) exceeds this. 0 takes the default; negative disables. }
    MaxContextTokens: Integer;
    { Followup requests allowed for one truncated response before the turn fails
      with leTruncated. 0 takes the default; negative disables continuation. }
    MaxContinuations: Integer;
    { Transient-failure retry (a network failure, a 429, a 5xx): attempts beyond
      the first, the base backoff, its cap, and the total wait budget. 0 fields
      take the defaults; a negative RetryMaxAttempts disables retry. }
    RetryMaxAttempts: Integer;
    RetryBaseMs: Integer;
    RetryMaxMs: Integer;
    RetryBudgetMs: Integer;
  end;

  TAgentLoop = class
  private
    FClient: TLLMClient;
    FStore: IConversationStore;
    FTools: TToolRegistry;
    FConfig: TAgentConfig;
    { The last request's prompt tokens, so the user-message wrapper can show the
      model its context headroom. Zero until the first request returns. }
    FLastPromptTokens: Integer;
    { A loop-only advisory to ride the next tool response (a soft-limit nudge).
      Never persisted. }
    FPendingAdvisory: string;
    { STABLE prompt text from providers (the skill descriptions). Appended to the
      system message on the way out - request-only, never persisted - so it is
      byte-stable across requests and the prefix cache survives. }
    FStablePrompt: string;
    FCancel: TAgentCancelCheck;
    FOnTurnStart: TAgentBoundaryEvent;
    FOnTurnOpened: TAgentTurnEvent;
    FOnTurnFinished: TAgentTurnEvent;
    FProviders: array of IToolProvider;
    FPromptQueue: TPromptQueue;
    FLastTurnDropped: Boolean;
    { The turn in flight is an ambient turn: its opening content is a queued
      ambient notification, so no user message is appended. }
    FAmbientTurn: Boolean;
    { The executor for parallel tool calls. Nil => tools run serially (the
      original behaviour). The session sets a pool SEPARATE from the turn pool,
      because the turn occupies a turn-pool worker while its tools run. }
    FToolPool: IAsyncScheduler;
    { The response in flight is timed so the reasoning and content phases can be
      persisted per block: the first reasoning delta, the first content delta,
      and the resulting durations. }
    FTimedEvents: TAgentEvents;
    FReasonStartMs, FContentStartMs: Int64;
    FReasoningMs, FContentMs: Int64;
    { The callbacks handed to the client; they timestamp the phases and forward
      to the caller's events. }
    procedure OnTimedReasoning(const AText: string);
    procedure OnTimedText(const AText: string);
    { Build the request. When AContinuing, overlay the pending assistant text
      and the continuation instruction; both are request-only and never
      persisted. }
    function BuildRequest(const APendingContent: string;
      AContinuing: Boolean): TChatRequest;
    procedure ExecuteToolCalls(const ACalls: TChatToolCallArray;
      const AEvents: TAgentEvents; out AAllOk: Boolean);
    { The per-call pipeline: validate the reason, resolve the tool, run the
      handler (which resolves approval internally), forward output. Emits no
      events; the caller emits OnToolCall up front and OnToolResult after the
      join. Safe to run on a pool worker. }
    procedure RunOneCall(const ACall: TChatToolCall;
      const AEvents: TAgentEvents; out AResult: string; out AOk: Boolean;
      out ADurMs: Int64);
    { Emit OnToolResult and append the result to the store, in call order. }
    procedure FinishCall(const ACall: TChatToolCall; const AText: string;
      AOk: Boolean; ADurMs: Int64; const AEvents: TAgentEvents);
    { Whether AName may run concurrently with its parallel-safe siblings. }
    function IsParallelSafe(const AName: string): Boolean;
    { Answer each call with a notice instead of running the tool, so the
      assistant's tool_calls stay paired with results. }
    procedure InterceptToolCalls(const ACalls: TChatToolCallArray;
      const ANotice: string; const AEvents: TAgentEvents);
    { Wait ADelayMs, polling the cancel check so an operator interrupt stops a
      backoff wait; True when cancelled. }
    function SleepCancellable(ADelayMs: Integer): Boolean;
  public
    { Resolve a called name against the base registry, then providers. }
    function ResolveTool(const AName: string;
      out ATool: TRegisteredTool): Boolean;
    { Append every queued prompt as a user message and tell the UI. }
    procedure DrainQueued(const AEvents: TAgentEvents);
    function FinishError(const AResult: TChatResult): TLLMError;
    function DoSend(const AUserText: string; const AEvents: TAgentEvents;
      out AAnswer: string; out AError: TLLMError): Boolean;
  public
    constructor Create(AClient: TLLMClient; AStore: IConversationStore;
      ATools: TToolRegistry; const AConfig: TAgentConfig);
    destructor Destroy; override;
    function Send(const AUserText: string; AOnText: TLLMTextEvent;
      out AAnswer: string; out AError: TLLMError): Boolean; overload;
    function Send(const AUserText: string; const AEvents: TAgentEvents;
      out AAnswer: string; out AError: TLLMError): Boolean; overload;
    { Run a turn whose opening content is already queued as an ambient
      notification: no user message is appended; the queue is drained at the
      first loop boundary. }
    function SendAmbient(const AEvents: TAgentEvents;
      out AAnswer: string; out AError: TLLMError): Boolean;
    { Consulted at each loop boundary (before building a request); True closes
      the turn as cancelled. Never breaks a tool batch part-way. }
    property CancelCheck: TAgentCancelCheck read FCancel write FCancel;
    { Invoked once at the start of each turn, on the loop's thread, before the
      first request. Nil = no-op. The owner may mutate the tool registry here. }
    property OnTurnStart: TAgentBoundaryEvent read FOnTurnStart write FOnTurnStart;
    { Fires once per turn with the turn's id, right after its row opens. The
      change log attributes each change to a turn, and this is where the id is
      known. }
    property OnTurnOpened: TAgentTurnEvent read FOnTurnOpened
      write FOnTurnOpened;
    { Fires when a turn reaches a terminal state, after FinishTurn and before
      the next turn may open. The change recorder folds a turn here, so the
      summary is complete when the turn ends rather than a turn late. }
    property OnTurnFinished: TAgentTurnEvent read FOnTurnFinished
      write FOnTurnFinished;
    { Register a per-turn tool/prompt contributor. Prepare fires at each turn
      start; its Specs join the request's tool list; its Find resolves calls. }
    procedure AddProvider(const AProvider: IToolProvider);
    { Run the turn boundary: the OnTurnStart hook, then each provider's Prepare
      (a provider that raises is skipped). Called by Send before the first
      request; public so a host may trigger it explicitly. }
    procedure PrepareProviders;
    { Prompts the operator injects into a running turn. }
    property PromptQueue: TPromptQueue read FPromptQueue;
    { STABLE prompt text appended to the system message on the way out. Set once
      per session from the providers' stable fragments; never persisted. }
    property StablePrompt: string read FStablePrompt write FStablePrompt;
    { The executor for parallel tool calls. Nil => serial. Set by the session to
      a pool separate from the turn pool (the turn occupies a turn-pool worker
      while its tools run). }
    property ToolPool: IAsyncScheduler read FToolPool write FToolPool;
    { True when the last turn was cancelled before any response was committed,
      so its messages were dropped. }
    property LastTurnDropped: Boolean read FLastTurnDropped;
  end;

procedure RegisterDefaultTools(ATools: TToolRegistry);

{ Build a spec with the required `reason` parameter ensured, for providers that
  bypass the registry's Add. }
function MakeToolSpec(const AName, ADescription,
  AParametersJson: string): TToolSpec;

{ Required, non-empty, human-readable reason every tool call must carry. }
function ExtractToolReason(const AArgumentsJson: string;
  out AReason: string; out AError: string): Boolean;

{ Whether a user-role message is already wrapped by the loop - an ambient
  notification, or a checkpoint handoff - and so must not be wrapped again: a
  second pass would escape its tags and the model would read the markup instead
  of the context. }
function IsPrewrappedUserMessage(const AContent: string): Boolean;

{ The backoff ceiling before the next attempt: exponential from ABaseMs, capped
  at AMaxMs. The loop applies full jitter within [0, result], so a retry never
  waits longer than this and a burst does not synchronise. }
function RetryBackoffMs(AAttempt, ABaseMs, AMaxMs: Integer): Integer;

const
  { Tool-call budget: nudge from 30, lock down at 50, and end the turn on the
    next call after that. }
  DefaultSoftToolLimit = 30;
  DefaultHardToolLimit = 50;
  DefaultToolNoticeStep = 5;
  { Followup requests allowed for one truncated response. }
  DefaultMaxContinuations = 3;
  { Transient-failure retry: attempts beyond the first, the base backoff, its
    cap, and the total wait budget. }
  DefaultRetryMaxAttempts = 3;
  DefaultRetryBaseMs = 500;
  DefaultRetryMaxMs = 10000;
  DefaultRetryBudgetMs = 30000;
  { The user message that asks the model to resume a truncated response. It
    exists only in the continuation request: never persisted, never drawn. }
  ContinuationInstruction =
    'Continue exactly from where you stopped. Do not repeat the previous text. ' +
    'Finish the answer in the same language and format.';
  { The paired tool result that answers a call dropped because the response was
    cut off mid-call. }
  TruncatedToolNotice =
    'your tool call was cut off before it completed and was not run. ' +
    'Resubmit it; if its arguments are large, split them across smaller calls.';
  BuiltinGetSystemTimeName = 'get_system_time';
  ToolReasonParamName = 'reason';
  { The reason becomes a block title, so keep it a short label; the schema
    advertises this cap and the dialog truncates further on a narrow terminal. }
  ToolReasonMaxLength = 120;
  DefaultSystemPrompt =
    'You are a helpful assistant running inside hildi. ' +
    'Use the provided tools when they help answer the user.' + LineEnding +
    LineEnding + UserInstructions;

implementation

uses
  DateUtils, fpjson, jsonparser;

type
  { Loop-private: the response accumulated across continuation requests. It is
    not persisted until a proper stop; on error it is discarded. }
  TPendingResponse = record
    Content: string;
    Reasoning: string;
    ReasoningMs: Int64;
    ContentMs: Int64;
  end;

  { Owns the built-in tool handlers. A singleton because TToolHandler is an
    "of object" method pointer that must outlive the registry. }
  TBuiltinTools = class
  public
    function GetSystemTime(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;

  { The shared state for one fan-out: the results (indexed by call) and the
    countdown the join waits on. Owned by ExecuteToolCalls for the run. }
  TToolBatchState = class
  private
    FLock: TCriticalSection;
    FRemaining: Integer;
    FDone: TSimpleEvent;
  public
    Results: array of string;
    Oks: array of Boolean;
    Durs: array of Int64;
    constructor Create(ACount: Integer);
    destructor Destroy; override;
    { A job finished: store its result and count down; the last one signals. }
    procedure Complete(AIndex: Integer; const AResult: string; AOk: Boolean;
      ADurMs: Int64);
    { Block until every job has completed. }
    procedure Wait;
  end;

  { One parallel-safe call's unit of work: the closure the executor runs. It
    writes the result into the batch's shared array and counts down the join. }
  TToolCallJob = class
  private
    FLoop: TAgentLoop;
    FCall: TChatToolCall;
    FEvents: TAgentEvents;
    FBatch: TToolBatchState;
    FIndex: Integer;
  public
    constructor Create(ALoop: TAgentLoop; const ACall: TChatToolCall;
      const AEvents: TAgentEvents; ABatch: TToolBatchState; AIndex: Integer);
    procedure Run;
  end;

var
  BuiltinTools: TBuiltinTools;

function AgentError(ACode: TLLMErrorCode;
  const AMessage, ADetail: string): TLLMError;
begin
  Result.Code := ACode;
  Result.Message := AMessage;
  Result.Detail := ADetail;
end;

function AgentOk: TLLMError;
begin
  Result := AgentError(leOk, '', '');
end;

{ --- TBuiltinTools ------------------------------------------------------ }

function TBuiltinTools.GetSystemTime(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
begin
  AResult := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now));
  AError := '';
  Result := True;
end;

{ --- TToolObserver ------------------------------------------------------- }

function TToolObserver.ToolCallId: string;
begin
  { Not every observer is per-call: a single-shot tool may be given none at all.
    An override supplies the id when the call is known. }
  Result := '';
end;

{ --- TToolForwardObserver ----------------------------------------------- }

constructor TToolForwardObserver.Create(const AId, AName: string;
  AOnOutput: TToolOutputEvent);
begin
  inherited Create;
  FId := AId;
  FName := AName;
  FOnOutput := AOnOutput;
  FDone := False;
end;

procedure TToolForwardObserver.Next(const AText: string);
begin
  if FDone or (AText = '') then
    Exit;
  if Assigned(FOnOutput) then
    FOnOutput(FId, FName, AText);
end;

procedure TToolForwardObserver.Complete;
begin
  FDone := True;
end;

function TToolForwardObserver.ToolCallId: string;
begin
  Result := FId;
end;

{ --- TToolBatchState ---------------------------------------------------- }

constructor TToolBatchState.Create(ACount: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FDone := TSimpleEvent.Create;
  FRemaining := ACount;
  SetLength(Results, ACount);
  SetLength(Oks, ACount);
  SetLength(Durs, ACount);
  { A zero-count batch is already done. }
  if ACount = 0 then
    FDone.SetEvent;
end;

destructor TToolBatchState.Destroy;
begin
  FDone.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TToolBatchState.Complete(AIndex: Integer; const AResult: string;
  AOk: Boolean; ADurMs: Int64);
begin
  FLock.Acquire;
  try
    Results[AIndex] := AResult;
    Oks[AIndex] := AOk;
    Durs[AIndex] := ADurMs;
    Dec(FRemaining);
    if FRemaining = 0 then
      FDone.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TToolBatchState.Wait;
begin
  FDone.WaitFor(INFINITE);
end;

{ --- TToolCallJob ------------------------------------------------------- }

constructor TToolCallJob.Create(ALoop: TAgentLoop; const ACall: TChatToolCall;
  const AEvents: TAgentEvents; ABatch: TToolBatchState; AIndex: Integer);
begin
  inherited Create;
  FLoop := ALoop;
  FCall := ACall;
  FEvents := AEvents;
  FBatch := ABatch;
  FIndex := AIndex;
end;

procedure TToolCallJob.Run;
var
  ResultText: string;
  Ok: Boolean;
  DurMs: Int64;
begin
  FLoop.RunOneCall(FCall, FEvents, ResultText, Ok, DurMs);
  FBatch.Complete(FIndex, ResultText, Ok, DurMs);
end;

procedure RegisterDefaultTools(ATools: TToolRegistry);
var
  Spec: TToolSpec;
begin
  Spec := Default(TToolSpec);
  Spec.Name := BuiltinGetSystemTimeName;
  Spec.Description := 'Return the current UTC time as an ISO 8601 timestamp.';
  Spec.ParametersJson := '{"type":"object","properties":{},"required":[]}';
  ATools.Add(Spec, BuiltinTools.GetSystemTime);
end;

{ --- tool reason -------------------------------------------------------- }

function ExtractToolReason(const AArgumentsJson: string;
  out AReason: string; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Value: TJSONData;
begin
  AReason := '';
  AError := '';
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      on E: Exception do
      begin
        AError := 'invalid arguments JSON';
        Exit(False);
      end;
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'missing required "' + ToolReasonParamName + '"';
      Exit(False);
    end;
    Root := TJSONObject(Data);
    Value := Root.Find(ToolReasonParamName);
    if Value = nil then
    begin
      AError := 'missing required "' + ToolReasonParamName + '"';
      Exit(False);
    end;
    if Value.JSONType <> jtString then
    begin
      AError := '"' + ToolReasonParamName + '" must be a string';
      Exit(False);
    end;
    AReason := Trim(Value.AsString);
    if AReason = '' then
    begin
      AError := 'missing required "' + ToolReasonParamName + '"';
      Exit(False);
    end;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ Guarantees the advertised parameter schema declares a required string `reason`.
  Idempotent: an existing `reason` property/required entry is left as-is.
  Returns False if the schema is not a JSON object, so Add can reject the spec. }
function AugmentReasonParam(const AParamsJson: string;
  out AOut: string): Boolean;
var
  Data: TJSONData;
  Root, Props, ReasonProp: TJSONObject;
  Required: TJSONArray;
  Existing: TJSONData;
  I: Integer;
  HasReason: Boolean;
begin
  AOut := AParamsJson;
  Data := nil;
  try
    try
      Data := GetJSON(AParamsJson);
    except
      Exit(False);
    end;
    if not (Data is TJSONObject) then
      Exit(False);
    Root := TJSONObject(Data);

    Existing := Root.Find('properties');
    if Existing is TJSONObject then
      Props := TJSONObject(Existing)
    else
    begin
      if Existing <> nil then
        Root.Delete('properties');
      Props := TJSONObject.Create;
      Root.Add('properties', Props);
    end;

    Existing := Props.Find(ToolReasonParamName);
    if not (Existing is TJSONObject) then
    begin
      if Existing <> nil then
        Props.Delete(ToolReasonParamName);
      ReasonProp := TJSONObject.Create;
      ReasonProp.Add('type', 'string');
      Props.Add(ToolReasonParamName, ReasonProp);
    end
    else
      ReasonProp := TJSONObject(Existing);
    ReasonProp.Delete('maxLength');
    ReasonProp.Add('maxLength', ToolReasonMaxLength);

    Existing := Root.Find('required');
    if Existing is TJSONArray then
      Required := TJSONArray(Existing)
    else
    begin
      if Existing <> nil then
        Root.Delete('required');
      Required := TJSONArray.Create;
      Root.Add('required', Required);
    end;

    HasReason := False;
    for I := 0 to Required.Count - 1 do
      if Required.Strings[I] = ToolReasonParamName then
        HasReason := True;
    if not HasReason then
      Required.Add(ToolReasonParamName);

    AOut := Root.AsJSON;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ --- TMemoryConversationStore ------------------------------------------- }

procedure TMemoryConversationStore.Append(const AMessage: TChatMessage);
var
  N: Integer;
begin
  N := Length(FItems);
  SetLength(FItems, N + 1);
  FItems[N] := AMessage;
end;

function TMemoryConversationStore.Messages: TChatMessageArray;
begin
  Result := Copy(FItems, 0, Length(FItems));
end;

procedure TMemoryConversationStore.Clear;
begin
  FItems := nil;
end;

procedure TMemoryConversationStore.AppendReasoning(const AText: string;
  ADurationMs: Int64);
begin
  // in-memory: display blocks are not kept
end;

procedure TMemoryConversationStore.AppendError(const AMessage, ADetail: string);
begin
  // in-memory: display blocks are not kept
end;

procedure TMemoryConversationStore.AppendAmbient(const AText, ARefSessionId,
  ALabel, ASource, AStatus: string; AElapsedMs: Int64);
var
  Msg: TChatMessage;
begin
  { No store: degrade the ambient to a plain user message so the model still
    sees the result. The dedicated ambient record is store-only. }
  Msg := Default(TChatMessage);
  Msg.Role := crUser;
  Msg.Content := FormatAmbient(AText, ARefSessionId, ALabel, ASource, AStatus,
    AElapsedMs);
  Append(Msg);
end;

function TMemoryConversationStore.BeginTurn: Int64;
begin
  FTurnMark := Length(FItems);
  Result := 0;
end;

function TMemoryConversationStore.BeginRequest(ATurnId: Int64;
  const AModel: string; AMessageCount: Integer): Int64;
begin
  Result := 0;
end;

procedure TMemoryConversationStore.FinishRequest(ARequestId: Int64;
  const AOutcome: TRequestOutcome);
begin
  // no-op
end;

procedure TMemoryConversationStore.FinishTurn(ATurnId: Int64;
  const AOutcome: TTurnOutcome);
begin
  // no-op
end;

procedure TMemoryConversationStore.DropTurnMessages(ATurnId: Int64);
begin
  SetLength(FItems, FTurnMark);
end;

{ --- TPromptQueue ------------------------------------------------------- }

constructor TPromptQueue.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := nil;
end;

destructor TPromptQueue.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TPromptQueue.Push(const AText: string);
var
  Item: TPromptItem;
begin
  if Trim(AText) = '' then
    Exit;
  Item := Default(TPromptItem);
  Item.Kind := pkUser;
  Item.Text := AText;
  FLock.Acquire;
  try
    SetLength(FItems, Length(FItems) + 1);
    FItems[High(FItems)] := Item;
  finally
    FLock.Release;
  end;
end;

procedure TPromptQueue.PushBoard(const AText: string; ACount: Integer);
var
  Item: TPromptItem;
begin
  if AText = '' then
    Exit;
  Item := Default(TPromptItem);
  Item.Kind := pkBoard;
  Item.Text := AText;
  Item.Count := ACount;
  FLock.Acquire;
  try
    SetLength(FItems, Length(FItems) + 1);
    FItems[High(FItems)] := Item;
  finally
    FLock.Release;
  end;
end;

procedure TPromptQueue.PushAmbient(const AText, ARefSessionId, ALabel, ASource,
  AStatus: string; AElapsedMs: Int64);
var
  Item: TPromptItem;
begin
  if AText = '' then
    Exit;
  Item := Default(TPromptItem);
  Item.Kind := pkAmbient;
  Item.Text := AText;
  Item.RefSessionId := ARefSessionId;
  Item.LabelText := ALabel;
  Item.Source := ASource;
  Item.Status := AStatus;
  Item.ElapsedMs := AElapsedMs;
  FLock.Acquire;
  try
    SetLength(FItems, Length(FItems) + 1);
    FItems[High(FItems)] := Item;
  finally
    FLock.Release;
  end;
end;

function TPromptQueue.DrainItems: TPromptItemArray;
begin
  FLock.Acquire;
  try
    Result := FItems;
    FItems := nil;
  finally
    FLock.Release;
  end;
end;

function TPromptQueue.Drain: TPromptArray;
var
  Items: TPromptItemArray;
  I: Integer;
begin
  Result := nil;
  Items := DrainItems;
  for I := 0 to High(Items) do
    if Items[I].Kind = pkUser then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Items[I].Text;
    end;
end;

function TPromptQueue.Pending: Boolean;
begin
  FLock.Acquire;
  try
    Result := Length(FItems) > 0;
  finally
    FLock.Release;
  end;
end;

{ --- TToolRegistry ------------------------------------------------------ }

procedure TToolRegistry.Add(const ASpec: TToolSpec; AHandler: TToolHandler);
var
  N: Integer;
  Augmented: string;
  Stored: TToolSpec;
begin
  if ASpec.Name = '' then
    Exit;
  { Every advertised tool must require a reason; a malformed schema is rejected,
    like an empty name, rather than advertised as broken JSON. }
  if not AugmentReasonParam(ASpec.ParametersJson, Augmented) then
    Exit;
  Stored := ASpec;
  Stored.ParametersJson := Augmented;
  N := Length(FTools);
  SetLength(FTools, N + 1);
  FTools[N].Spec := Stored;
  FTools[N].Handler := AHandler;
end;

function TToolRegistry.Find(const AName: string;
  out ATool: TRegisteredTool): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FTools) do
    if FTools[I].Spec.Name = AName then
    begin
      ATool := FTools[I];
      Exit(True);
    end;
  ATool := Default(TRegisteredTool);
  Result := False;
end;

function TToolRegistry.Remove(const AName: string): Boolean;
var
  I, J: Integer;
begin
  Result := False;
  for I := 0 to High(FTools) do
    if FTools[I].Spec.Name = AName then
    begin
      for J := I to High(FTools) - 1 do
        FTools[J] := FTools[J + 1];
      SetLength(FTools, Length(FTools) - 1);
      Exit(True);
    end;
end;

function TToolRegistry.Specs: TToolSpecArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(FTools));
  for I := 0 to High(FTools) do
    Result[I] := FTools[I].Spec;
end;

function TToolRegistry.Count: Integer;
begin
  Result := Length(FTools);
end;

{ Builds a spec with the required `reason` parameter ensured, for providers that
  bypass the registry's Add. }
function MakeToolSpec(const AName, ADescription,
  AParametersJson: string): TToolSpec;
var
  Augmented: string;
begin
  Result := Default(TToolSpec);
  Result.Name := AName;
  Result.Description := ADescription;
  if AugmentReasonParam(AParametersJson, Augmented) then
    Result.ParametersJson := Augmented
  else
    Result.ParametersJson := AParametersJson;
end;

{ --- TAgentLoop --------------------------------------------------------- }

constructor TAgentLoop.Create(AClient: TLLMClient; AStore: IConversationStore;
  ATools: TToolRegistry; const AConfig: TAgentConfig);
begin
  inherited Create;
  FClient := AClient;
  FStore := AStore;
  FTools := ATools;
  FConfig := AConfig;
  FPromptQueue := TPromptQueue.Create;
  FLastTurnDropped := False;
  if FConfig.SoftToolLimit <= 0 then
    FConfig.SoftToolLimit := DefaultSoftToolLimit;
  if FConfig.HardToolLimit <= 0 then
    FConfig.HardToolLimit := DefaultHardToolLimit;
  if FConfig.ToolNoticeStep <= 0 then
    FConfig.ToolNoticeStep := DefaultToolNoticeStep;
  if FConfig.MaxContextTokens = 0 then
    FConfig.MaxContextTokens := DefaultMaxContextTokens;
  if FConfig.MaxContinuations = 0 then
    FConfig.MaxContinuations := DefaultMaxContinuations;
  if FConfig.RetryBaseMs <= 0 then
    FConfig.RetryBaseMs := DefaultRetryBaseMs;
  if FConfig.RetryMaxMs <= 0 then
    FConfig.RetryMaxMs := DefaultRetryMaxMs;
  if FConfig.RetryBudgetMs <= 0 then
    FConfig.RetryBudgetMs := DefaultRetryBudgetMs;
  { RetryMaxAttempts: 0 takes the default; a negative value disables retry. }
  if FConfig.RetryMaxAttempts = 0 then
    FConfig.RetryMaxAttempts := DefaultRetryMaxAttempts;
end;

destructor TAgentLoop.Destroy;
begin
  FPromptQueue.Free;
  inherited Destroy;
end;

procedure TAgentLoop.OnTimedReasoning(const AText: string);
begin
  if FReasonStartMs = 0 then
    FReasonStartMs := Int64(GetTickCount64);
  if Assigned(FTimedEvents.OnReasoning) then
    FTimedEvents.OnReasoning(AText);
end;

procedure TAgentLoop.OnTimedText(const AText: string);
begin
  { The first content delta ends the reasoning phase; report its duration just
    before the text so the UI settles the thought block first. }
  if FContentStartMs = 0 then
  begin
    FContentStartMs := Int64(GetTickCount64);
    if FReasonStartMs > 0 then
    begin
      FReasoningMs := FContentStartMs - FReasonStartMs;
      if Assigned(FTimedEvents.OnReasoningDone) then
        FTimedEvents.OnReasoningDone(FReasoningMs);
    end;
  end;
  if Assigned(FTimedEvents.OnText) then
    FTimedEvents.OnText(AText);
end;

function IsPrewrappedUserMessage(const AContent: string): Boolean;
begin
  Result := (Pos('<ambient', AContent) = 1) or (Pos('<handoff', AContent) = 1);
end;

function RetryBackoffMs(AAttempt, ABaseMs, AMaxMs: Integer): Integer;
var
  I: Integer;
begin
  Result := ABaseMs;
  if Result <= 0 then
    Exit(0);
  for I := 1 to AAttempt do
  begin
    { Stop at the cap, and never overflow before reaching it. }
    if ((AMaxMs > 0) and (Result >= AMaxMs)) or
       (Result > (MaxInt div 2)) then
    begin
      Result := AMaxMs;
      Exit;
    end;
    Result := Result * 2;
  end;
  if (AMaxMs > 0) and (Result > AMaxMs) then
    Result := AMaxMs;
  if Result < 0 then
    Result := 0;
end;

function TAgentLoop.BuildRequest(const APendingContent: string;
  AContinuing: Boolean): TChatRequest;
var
  N: Integer;
  Msg: TChatMessage;
  I, K: Integer;
  Specs: TToolSpecArray;
  Fragment: string;
  Context: string;
begin
  Result := Default(TChatRequest);
  Result.Messages := FStore.Messages;
  { Dynamic context from the providers (the skills manifest, ...) and the
    prompt-injection guard ride the current user turn. Built here, on the way
    out, and never persisted - nothing but the loop knows the wrapper exists.
    Injecting the manifest as a standalone system message made it read as a
    message with no user message mid-turn. }
  Context := '';
  for I := 0 to High(FProviders) do
  begin
    try
      Fragment := FProviders[I].PromptFragment;
    except
      on E: Exception do
        Fragment := '';
    end;
    if Fragment = '' then
      Continue;
    if Context <> '' then
      Context := Context + LineEnding;
    Context := Context + Fragment;
  end;
  { STABLE FORM: every message's bytes are a deterministic function of its
    stored content. No clock, no usage, no context - that is what keeps the
    provider's prefix cache alive across the requests of a turn. A message
    already sent is never rewritten. }
  for I := 0 to High(Result.Messages) do
    if (Result.Messages[I].Role = crUser) and
      (not IsPrewrappedUserMessage(Result.Messages[I].Content)) then
      Result.Messages[I].Content := FormatUserMessage(
        Result.Messages[I].Content);
  { The providers' STABLE text (skill descriptions) rides the system message:
    request-only, never persisted, and byte-identical across requests so it is
    cached. The volatile activation state stays in the tail below. }
  if FStablePrompt <> '' then
    for I := 0 to High(Result.Messages) do
      if Result.Messages[I].Role = crSystem then
      begin
        Result.Messages[I].Content := Result.Messages[I].Content + LineEnding +
          LineEnding + FStablePrompt;
        Break;
      end;

  { The VOLATILE TAIL goes on the last message, whatever its role, and that is
    decided AFTER the continuation block below has appended its messages - so
    a cut-off notice is the tail when it is the newest thing. }
  if AContinuing then
  begin
    { The pending fragment and the instruction are request-only: neither is
      appended to the store, so the committed history stays one assistant
      message. An empty fragment (a reasoning-only truncation) is not sent. }
    if APendingContent <> '' then
    begin
      Msg := Default(TChatMessage);
      Msg.Role := crAssistant;
      Msg.Content := APendingContent;
      N := Length(Result.Messages);
      SetLength(Result.Messages, N + 1);
      Result.Messages[N] := Msg;
    end;
    Msg := Default(TChatMessage);
    Msg.Role := crUser;
    Msg.Content := ContinuationInstruction;
    N := Length(Result.Messages);
    SetLength(Result.Messages, N + 1);
    Result.Messages[N] := Msg;
  end;

  { The VOLATILE TAIL: appended to the LAST message of the request, whatever
    its role - the user turn at the start of a turn, each new tool result as
    the turn proceeds, and a queued prompt or continuation notice when those
    become the newest message. The previous tail reverts to its stable form for
    free, because the store never held it, so the sent history converges to the
    stored history and the prefix stays byte-stable. See
    docs/research/prompt-cache-and-injection.md. }
  if Length(Result.Messages) > 0 then
  begin
    N := High(Result.Messages);
    { A pre-wrapped ambient/handoff message carries its own static wrapper; give
      it no tail, so it stays byte-identical and cache-safe. }
    if not IsPrewrappedUserMessage(Result.Messages[N].Content) then
      Result.Messages[N].Content := Result.Messages[N].Content +
        LineEnding + FormatTail(Context, NowUtcMs, FLastPromptTokens,
          FConfig.MaxContextTokens, FConfig.WorkspaceRoot, FPendingAdvisory);
  end;
  { The advisory rode the tail it was just given, so it is delivered once. }
  FPendingAdvisory := '';
  if FTools <> nil then
    Result.Tools := FTools.Specs;
  { Append provider tools (registration order). }
  for I := 0 to High(FProviders) do
  begin
    try
      Specs := FProviders[I].Specs;
    except
      on E: Exception do
        Specs := nil;
    end;
    for K := 0 to High(Specs) do
    begin
      N := Length(Result.Tools);
      SetLength(Result.Tools, N + 1);
      Result.Tools[N] := Specs[K];
    end;
  end;
end;

function TAgentLoop.ResolveTool(const AName: string;
  out ATool: TRegisteredTool): Boolean;
var
  I: Integer;
begin
  if (FTools <> nil) and FTools.Find(AName, ATool) then
    Exit(True);
  for I := 0 to High(FProviders) do
    try
      if FProviders[I].Find(AName, ATool) then
        Exit(True);
    except
      on E: Exception do ;   { a broken provider is skipped }
    end;
  ATool := Default(TRegisteredTool);
  Result := False;
end;

procedure TAgentLoop.AddProvider(const AProvider: IToolProvider);
var
  N: Integer;
begin
  if AProvider = nil then
    Exit;
  N := Length(FProviders);
  SetLength(FProviders, N + 1);
  FProviders[N] := AProvider;
end;

procedure TAgentLoop.PrepareProviders;
var
  I: Integer;
begin
  if Assigned(FOnTurnStart) then
    FOnTurnStart();
  for I := 0 to High(FProviders) do
    try
      FProviders[I].Prepare;
    except
      on E: Exception do ;   { a broken provider never wedges the loop }
    end;
end;

procedure TAgentLoop.ExecuteToolCalls(const ACalls: TChatToolCallArray;
  const AEvents: TAgentEvents; out AAllOk: Boolean);
var
  I, K, N, RunEnd, Count: Integer;
  Reason, ReasonError, ResultText: string;
  HandlerOk: Boolean;
  DurMs: Int64;
  Batch: TToolBatchState;
  Jobs: array of TToolCallJob;
  Subs: array of ISubscription;
begin
  AAllOk := True;
  N := Length(ACalls);
  if N = 0 then
    Exit;

  { Emit every call up front, in call order, so the UI creates the tool blocks
    in order regardless of completion order. }
  for I := 0 to N - 1 do
    if Assigned(AEvents.OnToolCall) then
    begin
      Reason := '';
      ExtractToolReason(ACalls[I].Arguments, Reason, ReasonError);
      AEvents.OnToolCall(ACalls[I].Id, ACalls[I].Name, ACalls[I].Arguments,
        Reason);
    end;

  I := 0;
  while I < N do
  begin
    { A run of consecutive parallel-safe calls runs concurrently; anything else
      runs serially, in order. Execution order is preserved (a [write, read]
      batch does not reorder), and a not-parallel-safe tool never overlaps. }
    if (FToolPool <> nil) and IsParallelSafe(ACalls[I].Name) then
    begin
      RunEnd := I;
      while (RunEnd < N) and IsParallelSafe(ACalls[RunEnd].Name) do
        Inc(RunEnd);
    end
    else
      RunEnd := I + 1;
    Count := RunEnd - I;

    if Count > 1 then
    begin
      { Fan out the run: schedule every call, then join. The results land in
        the batch array by index, so they are emitted in call order below. }
      Batch := TToolBatchState.Create(Count);
      SetLength(Jobs, Count);
      SetLength(Subs, Count);
      try
        for K := 0 to Count - 1 do
        begin
          Jobs[K] := TToolCallJob.Create(Self, ACalls[I + K], AEvents, Batch,
            K);
          Subs[K] := FToolPool.Schedule(Jobs[K].Run, 0);
        end;
        Batch.Wait;
        for K := 0 to Count - 1 do
        begin
          ResultText := Batch.Results[K];
          HandlerOk := Batch.Oks[K];
          DurMs := Batch.Durs[K];
          if not HandlerOk then
            AAllOk := False;
          FinishCall(ACalls[I + K], ResultText, HandlerOk, DurMs, AEvents);
        end;
      finally
        for K := 0 to High(Jobs) do
          Jobs[K].Free;
        Batch.Free;
      end;
    end
    else
    begin
      { A single parallel-safe call, or a not-parallel-safe one: run it here,
        on the loop's own thread, as before. }
      for K := I to RunEnd - 1 do
      begin
        RunOneCall(ACalls[K], AEvents, ResultText, HandlerOk, DurMs);
        if not HandlerOk then
          AAllOk := False;
        FinishCall(ACalls[K], ResultText, HandlerOk, DurMs, AEvents);
      end;
    end;

    I := RunEnd;
  end;
end;

function TAgentLoop.IsParallelSafe(const AName: string): Boolean;
var
  Tool: TRegisteredTool;
begin
  { A batch is the model's intent to run the calls together, so a tool is
    parallel-safe unless it declares itself SerialOnly. }
  Result := ResolveTool(AName, Tool) and (not Tool.Spec.SerialOnly);
end;

procedure TAgentLoop.RunOneCall(const ACall: TChatToolCall;
  const AEvents: TAgentEvents; out AResult: string; out AOk: Boolean;
  out ADurMs: Int64);
var
  Tool: TRegisteredTool;
  Reason, ReasonError, HandlerError: string;
  ReasonOk: Boolean;
  StartMs: Int64;
  Observer: TToolForwardObserver;
begin
  AResult := '';
  AOk := False;
  StartMs := GetTickCount64;
  Reason := '';
  ReasonOk := ExtractToolReason(ACall.Arguments, Reason, ReasonError);
  if not ReasonOk then
    AResult := 'error: tool "' + ACall.Name + '" ' + ReasonError
  else if (FTools = nil) or not ResolveTool(ACall.Name, Tool) then
    AResult := 'error: unknown tool "' + ACall.Name + '"'
  else
  begin
    HandlerError := '';
    { A per-call observer forwards the tool's chunks to the caller's event. }
    Observer := TToolForwardObserver.Create(ACall.Id, ACall.Name,
      AEvents.OnToolOutput);
    try
      try
        AOk := Tool.Handler(ACall.Arguments, AResult, HandlerError, Observer);
      except
        on E: Exception do
        begin
          AOk := False;
          HandlerError := E.Message;
        end;
      end;
    finally
      Observer.Complete;
      Observer.Free;
    end;
    if not AOk then
    begin
      { A tool that reported its own failure text keeps it: a tool knows what it
        was asked to do, and `run_command` renders the failing command as a
        transcript. Only a silent failure gets the generic wrapper. }
      if AResult = '' then
        AResult := 'error: tool "' + ACall.Name + '" failed: ' + HandlerError;
    end;
  end;
  ADurMs := Int64(GetTickCount64 - StartMs);
end;

procedure TAgentLoop.FinishCall(const ACall: TChatToolCall; const AText: string;
  AOk: Boolean; ADurMs: Int64; const AEvents: TAgentEvents);
var
  Msg: TChatMessage;
begin
  Msg := Default(TChatMessage);
  Msg.Role := crTool;
  Msg.ToolCallId := ACall.Id;
  Msg.Content := AText;
  Msg.ToolName := ACall.Name;
  Msg.ToolOk := AOk;
  Msg.DurationMs := ADurMs;
  { Append BEFORE emitting: a listener may need to resolve this row (the change
    recorder anchors a call's changes to it), and an event that fires before the
    row exists would find nothing. }
  FStore.Append(Msg);
  if Assigned(AEvents.OnToolResult) then
    AEvents.OnToolResult(ACall.Id, ACall.Name, AText, AOk);
end;

function ToolSoftNotice(ARound, AHard: Integer): string;
begin
  Result := Format('tool call limit notice: %d tool calls have been made this ' +
    'turn (hard limit %d). You may continue; keep going only if the calls are ' +
    'still needed.', [ARound, AHard]);
end;

function ToolHardNotice(ARound: Integer): string;
begin
  Result := Format('tool call limit reached (%d): no further tool calls are ' +
    'permitted. Answer the user with what you have; another tool call will ' +
    'end the turn with an error.', [ARound]);
end;

function ToolLoopNotice: string;
begin
  Result := 'tool call loop: the turn ended because the model kept calling ' +
    'tools past the hard limit.';
end;

procedure TAgentLoop.InterceptToolCalls(const ACalls: TChatToolCallArray;
  const ANotice: string; const AEvents: TAgentEvents);
var
  I: Integer;
  Reason, ReasonError: string;
  Msg: TChatMessage;
begin
  for I := 0 to High(ACalls) do
  begin
    Reason := '';
    ExtractToolReason(ACalls[I].Arguments, Reason, ReasonError);
    if Assigned(AEvents.OnToolCall) then
      AEvents.OnToolCall(ACalls[I].Id, ACalls[I].Name, ACalls[I].Arguments,
        Reason);
    if Assigned(AEvents.OnToolResult) then
      AEvents.OnToolResult(ACalls[I].Id, ACalls[I].Name, ANotice, False);
    Msg := Default(TChatMessage);
    Msg.Role := crTool;
    Msg.ToolCallId := ACalls[I].Id;
    Msg.Content := ANotice;
    Msg.ToolName := ACalls[I].Name;
    Msg.ToolOk := False;
    FStore.Append(Msg);
  end;
end;

function TAgentLoop.FinishError(const AResult: TChatResult): TLLMError;
begin
  if AResult.FinishReason = frLength then
    Result := AgentError(leProvider, 'response truncated (length)',
      AResult.RawFinishReason)
  else if AResult.FinishReason = frContentFilter then
    Result := AgentError(leProvider, 'response blocked (content_filter)',
      AResult.RawFinishReason)
  else
    Result := AgentError(leProvider, 'unexpected finish reason',
      AResult.RawFinishReason);
end;

function TAgentLoop.Send(const AUserText: string; AOnText: TLLMTextEvent;
  out AAnswer: string; out AError: TLLMError): Boolean;
var
  Events: TAgentEvents;
begin
  Events := Default(TAgentEvents);
  Events.OnText := AOnText;
  Result := DoSend(AUserText, Events, AAnswer, AError);
end;

function TAgentLoop.Send(const AUserText: string; const AEvents: TAgentEvents;
  out AAnswer: string; out AError: TLLMError): Boolean;
begin
  FAmbientTurn := False;
  Result := DoSend(AUserText, AEvents, AAnswer, AError);
end;

function TAgentLoop.SendAmbient(const AEvents: TAgentEvents;
  out AAnswer: string; out AError: TLLMError): Boolean;
begin
  FAmbientTurn := True;
  Result := DoSend('', AEvents, AAnswer, AError);
end;

procedure TAgentLoop.DrainQueued(const AEvents: TAgentEvents);
var
  Items: TPromptItemArray;
  I: Integer;
  Msg: TChatMessage;
begin
  Items := FPromptQueue.DrainItems;
  for I := 0 to High(Items) do
  begin
    if Items[I].Kind = pkBoard then
    begin
      { TRANSIENT by design: nothing is persisted and no message is appended. The
        notice rides the tail and is forgotten, so ten agents posting do not
        leave ninety permanent conversation rows. }
      Continue;
    end;
    if Items[I].Kind = pkAmbient then
    begin
      FStore.AppendAmbient(Items[I].Text, Items[I].RefSessionId,
        Items[I].LabelText, Items[I].Source, Items[I].Status,
        Items[I].ElapsedMs);
      if Assigned(AEvents.OnAmbient) then
        AEvents.OnAmbient(Items[I].Text, Items[I].RefSessionId,
          Items[I].LabelText, Items[I].Source, Items[I].Status,
          Items[I].ElapsedMs);
    end
    else
    begin
      Msg := Default(TChatMessage);
      Msg.Role := crUser;
      Msg.Content := Items[I].Text;
      FStore.Append(Msg);
      if Assigned(AEvents.OnUserQueued) then
        AEvents.OnUserQueued(Items[I].Text);
    end;
  end;
end;

function TAgentLoop.SleepCancellable(ADelayMs: Integer): Boolean;
const
  { How often a backoff wait polls the cancel check. }
  PollMs = 50;
var
  Waited, Slice: Integer;
begin
  Waited := 0;
  while Waited < ADelayMs do
  begin
    if Assigned(FCancel) and FCancel() then
      Exit(True);
    Slice := ADelayMs - Waited;
    if Slice > PollMs then
      Slice := PollMs;
    Sleep(Slice);
    Inc(Waited, Slice);
  end;
  Result := Assigned(FCancel) and FCancel();
end;

function TAgentLoop.DoSend(const AUserText: string; const AEvents: TAgentEvents;
  out AAnswer: string; out AError: TLLMError): Boolean;
var
  Rounds, Continuations: Integer;
  Request: TChatRequest;
  ChatResult: TChatResult;
  UserMsg, SystemMsg: TChatMessage;
  AllOk, Committed, Stop, TruncatedRound: Boolean;
  Pending: TPendingResponse;
  TurnId, RequestId: Int64;
  StartMs, EndMs: Int64;
  Outcome: TRequestOutcome;
  TurnOutcome: TTurnOutcome;
  Attempt, RetryWaitedMs, Delay: Integer;
  Ok: Boolean;

  procedure FailTurn(ACode: TLLMErrorCode; const AMessage, ADetail,
    AFinishReason: string);
  begin
    AError := AgentError(ACode, AMessage, ADetail);
    { A user interrupt is not an error. The turn row records the cancelled
      status, and the live UI draws no error block, so persisting one would make
      a resumed session differ from what streamed. }
    if ACode <> leCancelled then
      FStore.AppendError(AMessage, ADetail);
    TurnOutcome := Default(TTurnOutcome);
    TurnOutcome.Status := tsFailed;
    if ACode = leCancelled then
      TurnOutcome.Status := tsCancelled;
    TurnOutcome.FinishReason := AFinishReason;
    TurnOutcome.ErrorCode := ACode;
    TurnOutcome.ErrorMessage := AMessage;
    TurnOutcome.ErrorDetail := ADetail;
    FStore.FinishTurn(TurnId, TurnOutcome);
  end;

  { Persist the pending response merged with the terminal response as one
    reasoning block and one assistant message. Until now the pending was
    request-only and is dropped on any error instead of committed. }
  procedure CommitResponse(const APending: TPendingResponse);
  var
    Msg: TChatMessage;
  begin
    FStore.AppendReasoning(APending.Reasoning + ChatResult.ReasoningContent,
      APending.ReasoningMs + FReasoningMs);
    Msg := ChatResult.Message;
    Msg.Content := APending.Content + ChatResult.Message.Content;
    Msg.DurationMs := APending.ContentMs + FContentMs;
    FStore.Append(Msg);
  end;

begin
  AAnswer := '';
  AError := AgentOk;
  FLastTurnDropped := False;
  Committed := False;

  { The turn boundary: the owner may reconcile its tool surface here, before the
    first request. The registry is snapshotted per request, so mutating it now is
    race-free. }
  PrepareProviders;

  if (FStore.Messages = nil) and (FConfig.SystemPrompt <> '') then
  begin
    SystemMsg := Default(TChatMessage);
    SystemMsg.Role := crSystem;
    SystemMsg.Content := FConfig.SystemPrompt;
    FStore.Append(SystemMsg);
  end;

  { Open the loop before appending the prompt, so the prompt is linked to it. }
  TurnId := FStore.BeginTurn;
  { Announce the turn id: the change log attributes every change to a turn, and
    this is the only place that id is known. }
  if Assigned(FOnTurnOpened) then
    FOnTurnOpened(TurnId);

  { An ambient turn's opening content is the queued ambient notification, so no
    user message is appended; the first boundary drains it. }
  if not FAmbientTurn then
  begin
    UserMsg := Default(TChatMessage);
    UserMsg.Role := crUser;
    UserMsg.Content := AUserText;
    FStore.Append(UserMsg);
  end;

  Rounds := 0;
  while True do
  begin
    { A cancel between requests stops the loop; a tool batch is never broken
      part-way, so its calls and results stay paired. }
    if Assigned(FCancel) and FCancel() then
    begin
      { Nothing committed this turn: drop the prompt so it leaves no trace. }
      if not Committed then
      begin
        FStore.DropTurnMessages(TurnId);
        FLastTurnDropped := True;
      end;
      FailTurn(leCancelled, 'cancelled', '', '');
      Exit(False);
    end;

    { Inject any queued prompts before the next request. }
    DrainQueued(AEvents);

    { One response, possibly spanning several continuation requests. Nothing is
      persisted until a proper stop; a truncated response is continued and a
      truncated tool call is answered with a notice. }
    Pending := Default(TPendingResponse);
    Continuations := 0;
    Stop := False;
    TruncatedRound := False;
    repeat
      Request := BuildRequest(Pending.Content, Continuations > 0);

      { One request, retried on a transient failure (a network error, a 429, a
        5xx) up to the budget. A retry is attempted only while the attempt
        produced no output: a partial stream cannot be rolled back without a
        retry signal, so a mid-stream failure keeps the fail-and-drop path. }
      Attempt := 0;
      RetryWaitedMs := 0;
      repeat
        RequestId := FStore.BeginRequest(TurnId, FClient.Model,
          Length(Request.Messages));
        StartMs := GetTickCount64;
        Outcome := Default(TRequestOutcome);
        { Time the response's phases; the timed callbacks forward to AEvents. }
        FTimedEvents := AEvents;
        FReasonStartMs := 0;
        FContentStartMs := 0;
        FReasoningMs := 0;
        FContentMs := 0;

        { The client consults the same check mid-stream, so a cancel aborts the
          request itself rather than waiting for the provider to finish. }
        FClient.CancelCheck := FCancel;
        Ok := FClient.Complete(Request, OnTimedText, OnTimedReasoning,
          ChatResult, AError);
        if Ok then
          Break;

        Outcome.Ok := False;
        Outcome.ErrorCode := AError.Code;
        Outcome.ErrorMessage := AError.Message;
        Outcome.ErrorDetail := AError.Detail;
        Outcome.DurationMs := Int64(GetTickCount64 - StartMs);
        FStore.FinishRequest(RequestId, Outcome);

        if AError.Code = leCancelled then
          Break;
        if (not IsRetryable(AError)) or (Attempt >= FConfig.RetryMaxAttempts) then
          Break;
        if (FReasonStartMs <> 0) or (FContentStartMs <> 0) then
          Break;   { partial output: do not retry }

        Delay := Random(RetryBackoffMs(Attempt, FConfig.RetryBaseMs,
          FConfig.RetryMaxMs) + 1);
        if RetryWaitedMs + Delay > FConfig.RetryBudgetMs then
          Delay := FConfig.RetryBudgetMs - RetryWaitedMs;
        if Delay < 0 then
          Delay := 0;
        if (Delay > 0) and SleepCancellable(Delay) then
        begin
          { The operator interrupted during the wait: report a cancel. }
          AError := AgentError(leCancelled, 'cancelled', '');
          Break;
        end;
        Inc(RetryWaitedMs, Delay);
        Inc(Attempt);
      until False;

      if not Ok then
      begin
        if (AError.Code = leCancelled) and (not Committed) then
        begin
          FStore.DropTurnMessages(TurnId);
          FLastTurnDropped := True;
        end;
        if Attempt > 0 then
          FailTurn(AError.Code,
            AError.Message + ' after ' + IntToStr(Attempt + 1) + ' attempts',
            AError.Detail, '')
        else
          FailTurn(AError.Code, AError.Message, AError.Detail, '');
        Exit(False);
      end;

      { Close the phases: reasoning when content starts (or here, when the
        response was reasoning-only), content at the request's end. }
      EndMs := Int64(GetTickCount64);
      if (FReasonStartMs > 0) and (FContentStartMs = 0) then
      begin
        FReasoningMs := EndMs - FReasonStartMs;
        if Assigned(FTimedEvents.OnReasoningDone) then
          FTimedEvents.OnReasoningDone(FReasoningMs);
      end;
      if FContentStartMs > 0 then
        FContentMs := EndMs - FContentStartMs
      else
        FContentMs := 0;

      Outcome.Ok := True;
      Outcome.FinishReason := ChatResult.FinishReason;
      Outcome.RawFinishReason := ChatResult.RawFinishReason;
      Outcome.Usage := ChatResult.Usage;
      FLastPromptTokens := ChatResult.Usage.PromptTokens;
      Outcome.FirstTokenMs := ChatResult.FirstTokenMs;
      Outcome.DurationMs := Int64(GetTickCount64 - StartMs);
      FStore.FinishRequest(RequestId, Outcome);

      { Guard the running context: the next request would only be larger. }
      if (FConfig.MaxContextTokens > 0) and
        (ChatResult.Usage.PromptTokens > FConfig.MaxContextTokens) then
      begin
        FailTurn(leLoop, 'context limit reached',
          Format('%d prompt tokens (limit %d)',
          [ChatResult.Usage.PromptTokens, FConfig.MaxContextTokens]),
          ChatResult.RawFinishReason);
        Exit(False);
      end;

      if ChatResult.FinishReason = frLength then
      begin
        if Length(ChatResult.Message.ToolCalls) = 0 then
        begin
          { A text truncation: keep the fragment and ask for the rest. }
          if Continuations >= FConfig.MaxContinuations then
          begin
            FailTurn(leTruncated, 'response truncated (length)',
              Format('%d continuations (limit %d)',
              [Continuations, FConfig.MaxContinuations]),
              ChatResult.RawFinishReason);
            Exit(False);
          end;
          Pending.Content := Pending.Content + ChatResult.Message.Content;
          Pending.Reasoning := Pending.Reasoning + ChatResult.ReasoningContent;
          Pending.ReasoningMs := Pending.ReasoningMs + FReasoningMs;
          Pending.ContentMs := Pending.ContentMs + FContentMs;
          Inc(Continuations);
          Continue;
        end;
        { A cut-off tool call cannot be continued: fall through to the tool
          round, where its calls are answered with a notice instead of run. }
        TruncatedRound := True;
        Break;
      end;

      if ChatResult.FinishReason = frStop then
      begin
        Stop := True;
        Break;
      end;

      if ChatResult.FinishReason <> frToolCalls then
      begin
        AError := FinishError(ChatResult);
        FailTurn(AError.Code, AError.Message, AError.Detail,
          ChatResult.RawFinishReason);
        Exit(False);
      end;

      Break;
    until False;

    if Stop then
    begin
      CommitResponse(Pending);
      AAnswer := Pending.Content + ChatResult.Message.Content;
      TurnOutcome := Default(TTurnOutcome);
      TurnOutcome.Status := tsCompleted;
      TurnOutcome.FinishReason := ChatResult.RawFinishReason;
      FStore.FinishTurn(TurnId, TurnOutcome);
      { The turn is terminal here, so this is where a consumer folds it. Emitted
        after FinishTurn and before a queued prompt may open the next turn, so
        the summary is complete when the turn ends rather than a turn late. }
      if Assigned(FOnTurnFinished) then
        FOnTurnFinished(TurnId);
      { Prompts queued before the stop start the next turn immediately. }
      if FPromptQueue.Pending then
      begin
        TurnId := FStore.BeginTurn;
        Committed := False;
        Rounds := 0;
        Continue;
      end;
      Exit(True);
    end;

    { A tool round: a proper tool call, or a truncated one whose calls are
      answered with a notice instead of run. }
    Inc(Rounds);
    { A queued prompt supersedes the tool call: keep no response for it and
      inject the queued prompts instead, so the model reconsiders with the
      new context. }
    if (Rounds <= FConfig.HardToolLimit) and FPromptQueue.Pending then
    begin
      DrainQueued(AEvents);
      Continue;
    end;
    CommitResponse(Pending);
    Committed := True;
    { One call past the hard limit: the model was already told to stop, so it
      is now a loop error. }
    if Rounds > FConfig.HardToolLimit then
    begin
      InterceptToolCalls(ChatResult.Message.ToolCalls, ToolLoopNotice,
        AEvents);
      FailTurn(leLoop, 'tool call loop',
        Format('%d tool calls (hard limit %d)',
        [Rounds, FConfig.HardToolLimit]), ChatResult.RawFinishReason);
      Exit(False);
    end;
    { Lockdown at the hard limit, then a nudge every ToolNoticeStep calls from
      the soft limit. An intercepted call is not run; the model must resubmit
      it to proceed. A call cut off by truncation is always intercepted. }
    if Rounds = FConfig.HardToolLimit then
      InterceptToolCalls(ChatResult.Message.ToolCalls,
        ToolHardNotice(Rounds), AEvents)
    else if TruncatedRound then
      InterceptToolCalls(ChatResult.Message.ToolCalls,
        TruncatedToolNotice, AEvents)
    else
    begin
      { A soft-limit nudge is an advisory, not a failure: run the calls and let
        the nudge ride the response's <context>. Only the hard limit intercepts
        (and it is the absolute ceiling - the one limit that blocks). }
      if (Rounds >= FConfig.SoftToolLimit) and
        ((Rounds - FConfig.SoftToolLimit) mod FConfig.ToolNoticeStep = 0) then
        FPendingAdvisory := ToolSoftNotice(Rounds, FConfig.HardToolLimit);
      ExecuteToolCalls(ChatResult.Message.ToolCalls, AEvents, AllOk);
    end;
    Continue;
  end;
end;

initialization
  BuiltinTools := TBuiltinTools.Create;

finalization
  BuiltinTools.Free;

end.
