unit TestAgent;
{ fpcunit tests for HildiAgent, driven by the fake LLM transport. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry, fpjson, jsonparser,
  AsyncScheduler, AsyncConcurrency,
  HildiLLM, HildiAgent, HildiSession,
  LLMFakes;

type
  TTextSink = class
  private
    FText: string;
  public
    procedure OnText(const AText: string);
    property Text: string read FText;
  end;

  { Handler object whose tools fail or raise. }
  TFailTools = class
  public
    function AlwaysFail(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function AlwaysRaise(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;

  { A tool whose call blocks (as one waiting on the approval gate does) until a
    sibling releases it, proving the sibling ran while it was blocked. The block
    has a timeout, so a serial run finishes (and reports the sibling did NOT
    overlap) rather than hanging. }
  TGatedProbe = class
  private
    FLock: TCriticalSection;
    FSlowStarted: TSimpleEvent;
    FRelease: TSimpleEvent;
  public
    SlowFinished: Boolean;
    FastSawSlowInFlight: Boolean;
    constructor Create;
    destructor Destroy; override;
    function Slow(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function Fast(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;

  { A tool that records how many calls are in flight at once and the order they
    finish, so a fan-out can be asserted. Each call blocks on a shared gate
    until AMaxConcurrent calls have arrived, then releases all. }
  TProbeTool = class
  private
    FLock: TCriticalSection;
    FInFlight: Integer;
    FPeak: Integer;
    FArrived: Integer;
    FGate: TSimpleEvent;
    FNeed: Integer;
  public
    Finished: TStringList;
    constructor Create(ANeed: Integer);
    destructor Destroy; override;
    { Records the peak concurrency; returns the call id from the arguments so
      results can be checked in order. }
    function Handle(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    property Peak: Integer read FPeak;
  end;

  { Captures the raw arguments of each successful handler call. }
  TCaptureTool = class
  private
    FCalls: Integer;
    FLastArgs: string;
  public
    function Handle(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    property Calls: Integer read FCalls;
    property LastArgs: string read FLastArgs;
  end;

  { Emits two chunks through the observer, then returns a joined result. }
  TStreamTool = class
  public
    function Handle(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;

  { Records every agent event as a line, to assert on ordering and content. }
  TEventLog = class
  private
    FLog: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnText(const AText: string);
    procedure OnReasoning(const AText: string);
    procedure OnReasoningDone(ADurationMs: Int64);
    procedure OnToolCall(const AId, AName, AArguments, AReason: string);
    procedure OnToolResult(const AId, AName, AResult: string; AOk: Boolean);
    procedure OnToolOutput(const AId, AName, AText: string);
    function Has(const AFragment: string): Boolean;
    function IndexOfFragment(const AFragment: string): Integer;
  end;

  { Sleeps after each stream chunk, so the loop's phase timings are non-zero. }
  TChunkDelay = class
  private
    FMs: Integer;
  public
    constructor Create(AMs: Integer);
    procedure AfterChunk(Sender: TObject);
  end;

  { Wraps an in-memory store and counts appends, to prove the loop uses the
    interface rather than a concrete store. }
  TCountingStore = class(TInterfacedObject, IConversationStore)
  private
    FInner: TMemoryConversationStore;
    FAppends: Integer;
  public
    constructor Create;
    destructor Destroy; override;
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
    property Appends: Integer read FAppends;
  end;

  { Records the audit seam so a test can assert what the loop reported. }
  TRecordingStore = class(TInterfacedObject, IConversationStore)
  private
    FInner: TMemoryConversationStore;
  public
    BeginTurns: Integer;
    BeginRequests: Integer;
    FinishRequests: Integer;
    FinishTurns: Integer;
    LastTurnStatus: TTurnStatus;
    LastRequestModel: string;
    LastRequestMessages: Integer;
    LastOutcome: TRequestOutcome;
    Reasoning: string;
    ReasoningMs: Int64;
    LastError: string;
    LastErrorDetail: string;
    LastTool: TChatMessage;
    LastAssistant: TChatMessage;
    UserAppends: Integer;
    AmbientAppends: Integer;
    LastAmbientRef: string;
    LastAmbientMs: Int64;
    constructor Create;
    destructor Destroy; override;
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

  { Reports cancelled from the Nth check on, for the loop's cancel seam. }
  TCancelAfter = class
  private
    FAfter: Integer;
    FCalls: Integer;
  public
    constructor Create(AAfter: Integer);
    function Check: Boolean;
  end;

  TAgentLoopTest = class(TTestCase)
  private
    FFake: TFakeTransport;
    FClient: TLLMClient;
    FStore: IConversationStore;
    FTools: TToolRegistry;
    FLoop: TAgentLoop;
    FFailTools: TFailTools;
    FRecorder: TRecordingStore;
    FQueuedOnce: Boolean;
    procedure OnAfterChunk(Sender: TObject);
    function BuildLoop(const APrompt: string; AMaxIters: Integer): TAgentLoop;
    function BuildLoopRecording(AMaxContinuations: Integer = 0): TRecordingStore;
    function BuildLoopBudget(ASoft, AHard, AStep,
      AMaxContext: Integer): TRecordingStore;
    function BuildLoopRetry(const APrompt: string;
      AMaxIters, AMaxAttempts: Integer): TAgentLoop;
    function MessageCount(const ABody: string): Integer;
    function RoleAt(const ABody: string; AIndex: Integer): string;
    function ContentAt(const ABody: string; AIndex: Integer): string;
    function ToolCallIdAt(const ABody: string; AIndex: Integer): string;
  protected
    procedure TearDown; override;
  published
    procedure TestSendSingleTurnReturnsAnswer;
    procedure TestTextDeltasAreForwarded;
    procedure TestToolCallIsExecutedAndFedBack;
    procedure TestMultipleToolCallsAllExecuted;
    procedure TestToolResultsFollowAssistantInOrder;
    procedure TestParallelToolCallsRunConcurrently;
    procedure TestParallelToolResultsAreInCallOrder;
    procedure TestMixedBatchKeepsOrderAndSerializesUnsafe;
    procedure TestWithoutAToolPoolCallsAreSerial;
    procedure TestABlockedCallDoesNotHoldUpItsSibling;
    procedure TestUnknownToolReturnsErrorResultAndContinues;
    procedure TestFailingHandlerReturnsErrorResultAndContinues;
    procedure TestRaisingHandlerIsCaughtAndReported;
    procedure TestToolCallLoopAbortsAtTheHardLimit;
    procedure TestSoftLimitRunsAndNudges;
    procedure TestHardLimitLocksDownTheCall;
    procedure TestContextLimitAborts;
    procedure TestLengthFinishReasonReported;
    procedure TestContentFilterFinishReasonReported;
    procedure TestTruncatedResponseContinuesToStop;
    procedure TestContinuationCommitsOneMessage;
    procedure TestContinuationMergesReasoning;
    procedure TestContinuationRequestCarriesPending;
    procedure TestEmptyContentTruncationContinues;
    procedure TestContinuationCapFailsTurn;
    procedure TestContinuationDisabledFailsImmediately;
    procedure TestContinuationHonoursContextGuard;
    procedure TestTruncatedToolCallIsNotExecuted;
    procedure TestTruncatedToolCallGetsPairedNotice;
    procedure TestNonContinuableErrorDiscardsPending;
    procedure TestCommittedToolRoundSurvivesLaterTruncationError;
    procedure TestConversationPersistsAcrossTurns;
    procedure TestSystemPromptIncludedFirst;
    procedure TestStoreIsUsedThroughTheInterface;
    procedure TestDefaultToolsRegistered;
    procedure TestRegistryRemovePresentAndAbsent;
    procedure TestTurnStartHookFiresOnceBeforeRequest;
    procedure TestTurnStartNilIsNoOp;
    procedure TestProviderToolsComposedIntoRequest;
    procedure TestProviderPrepareCalledOncePerTurn;
    procedure TestProviderPromptInjectedRequestOnly;
    procedure TestProviderToolDispatches;
    procedure TestNativeToolTakesPriorityOverProvider;
    procedure TestGetSystemTimeReturnsParseableTime;
    procedure TestEmptyToolNameIsIgnored;
    procedure TestReasoningForwardedThroughEvents;
    procedure TestToolCallEventFiresWithNameAndArgs;
    procedure TestToolResultEventFiresWithResult;
    procedure TestToolResultEventReportsFailure;
    procedure TestToolCallAndResultEventsAreInOrder;
    procedure TestObserverForwardsChunks;
    procedure TestSingleShotToolEmitsNoChunks;
    procedure TestForwardObserverDropsChunksAfterComplete;
    procedure TestV1SendOverloadStillWorks;
    procedure TestQueuedAmbientDrainsAsAmbient;
    procedure TestSendAmbientStartsWithoutUserMessage;
    procedure TestPrewrappedUserMessagesAreNotWrappedAgain;
    { A board notice is transient: it must not become a conversation row. }
    procedure TestABoardNoticeIsNotPersisted;
    { The stable prompt reaches the system message, request-only. Without it the
      skill descriptions would be in no prompt at all, because the per-request
      fragment now carries state only. }
    procedure TestStablePromptReachesTheSystemMessage;
    procedure TestStablePromptIsAbsentWhenUnset;
    { The prompt-cache invariant: a superseded message is byte-identical across
      requests, and the volatile tail only ever rides the newest message. }
    procedure TestSupersededMessageIsByteIdenticalAcrossRequests;
    procedure TestTailRidesOnlyTheNewestMessage;
    procedure TestTailConvergesAcrossTurns;
    procedure TestRetryBackoffIsExponentialAndCapped;
    procedure TestRetryOnNetworkThenSucceed;
    procedure TestRetryExhaustionReportsAttempts;
    procedure TestRetryDisabledWhenNegative;
    procedure TestSendAmbientDrainsQueuedAmbient;
    procedure TestRegistrationAddsRequiredReasonParam;
    procedure TestRegistrationPreservesExistingParams;
    procedure TestRegistrationIsIdempotent;
    procedure TestMalformedSchemaIsIgnored;
    procedure TestExtractReasonAcceptsNonEmpty;
    procedure TestExtractReasonRejectsMissing;
    procedure TestExtractReasonRejectsBlank;
    procedure TestExtractReasonRejectsNonString;
    procedure TestExtractReasonRejectsInvalidJson;
    procedure TestCallWithoutReasonReturnsErrorAndContinues;
    procedure TestHandlerReceivesFullArgumentsIncludingReason;
    procedure TestToolCallEventCarriesReason;
    procedure TestPromptAdvertisesReasonRequired;
    procedure TestSendOpensAndClosesATurn;
    procedure TestSendRecordsRequestOutcome;
    procedure TestSendRecordsReasoning;
    procedure TestLoopRecordsReasoningDuration;
    procedure TestLoopRecordsContentDuration;
    procedure TestLoopReportsReasoningDone;
    procedure TestSendRecordsErrorAndFailedTurn;
    procedure TestToolResultCarriesNameOkAndDuration;
    procedure TestLoopStopsWhenCancelled;
    procedure TestEarlyCancelDropsTheTurn;
    procedure TestLateCancelKeepsTheTurn;
    procedure TestQueuedPromptIsInjected;
    procedure TestQueuedPromptSupersedesAToolCall;
    procedure TestQueuedPromptsStartTheNextTurn;
  end;

implementation

{ TTextSink }

procedure TTextSink.OnText(const AText: string);
begin
  FText := FText + AText;
end;

{ TCaptureTool }

function TCaptureTool.Handle(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
begin
  Inc(FCalls);
  FLastArgs := AArgumentsJson;
  AResult := 'ok';
  AError := '';
  Result := True;
end;

{ TStreamTool }

function TStreamTool.Handle(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
begin
  if AObserver <> nil then
  begin
    AObserver.Next('chunk-1');
    AObserver.Next('chunk-2');
  end;
  AResult := 'chunk-1chunk-2';
  AError := '';
  Result := True;
end;

{ TFailTools }

function TFailTools.AlwaysFail(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
begin
  AResult := '';
  AError := 'boom';
  Result := False;
end;

{ TEventLog }

constructor TEventLog.Create;
begin
  inherited Create;
  FLog := TStringList.Create;
end;

destructor TEventLog.Destroy;
begin
  FLog.Free;
  inherited Destroy;
end;

procedure TEventLog.OnText(const AText: string);
begin
  FLog.Add('text:' + AText);
end;

procedure TEventLog.OnReasoning(const AText: string);
begin
  FLog.Add('reason:' + AText);
end;

procedure TEventLog.OnReasoningDone(ADurationMs: Int64);
begin
  FLog.Add('reasoningdone:' + IntToStr(ADurationMs));
end;

procedure TEventLog.OnToolCall(const AId, AName, AArguments, AReason: string);
begin
  FLog.Add('call:' + AId + ':' + AName + ':' + AArguments + ':' + AReason);
end;

procedure TEventLog.OnToolResult(const AId, AName, AResult: string;
  AOk: Boolean);
begin
  FLog.Add('result:' + AId + ':' + BoolToStr(AOk, True) + ':' + AResult);
end;

procedure TEventLog.OnToolOutput(const AId, AName, AText: string);
begin
  FLog.Add('out:' + AId + ':' + AName + ':' + AText);
end;

function TEventLog.Has(const AFragment: string): Boolean;
begin
  Result := IndexOfFragment(AFragment) >= 0;
end;

function TEventLog.IndexOfFragment(const AFragment: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FLog.Count - 1 do
    if Pos(AFragment, FLog[I]) > 0 then
      Exit(I);
  Result := -1;
end;

{ TChunkDelay }

constructor TChunkDelay.Create(AMs: Integer);
begin
  inherited Create;
  FMs := AMs;
end;

procedure TChunkDelay.AfterChunk(Sender: TObject);
begin
  Sleep(FMs);
end;

function TFailTools.AlwaysRaise(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
begin
  AResult := '';
  AError := '';
  Result := False;
  raise Exception.Create('kaboom');
end;

{ TGatedProbe }

constructor TGatedProbe.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSlowStarted := TSimpleEvent.Create;
  FRelease := TSimpleEvent.Create;
  SlowFinished := False;
  FastSawSlowInFlight := False;
end;

destructor TGatedProbe.Destroy;
begin
  FRelease.Free;
  FSlowStarted.Free;
  FLock.Free;
  inherited Destroy;
end;

function TGatedProbe.Slow(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
begin
  { Announce that the slow call is in flight, then block as an approval wait
    does. The finite timeout means a serial run still completes (with
    FastSawSlowInFlight False) rather than hanging. }
  FSlowStarted.SetEvent;
  FRelease.WaitFor(1000);
  FLock.Acquire;
  try
    SlowFinished := True;
  finally
    FLock.Release;
  end;
  AResult := 'slow done';
  AError := '';
  Result := True;
end;

function TGatedProbe.Fast(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
begin
  { Wait for the slow call to be in flight (a serial loop has already finished
    it by now, so this returns at once with SlowFinished True), then check
    whether it is STILL in flight: that means the fast call ran while the slow
    one was blocked. }
  FSlowStarted.WaitFor(1000);
  FLock.Acquire;
  try
    FastSawSlowInFlight := not SlowFinished;
  finally
    FLock.Release;
  end;
  { Release the slow call so the batch can finish. }
  FRelease.SetEvent;
  AResult := 'fast done';
  AError := '';
  Result := True;
end;

{ TProbeTool }

constructor TProbeTool.Create(ANeed: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FGate := TSimpleEvent.Create;
  FNeed := ANeed;
  FInFlight := 0;
  FPeak := 0;
  FArrived := 0;
  Finished := TStringList.Create;
end;

destructor TProbeTool.Destroy;
begin
  Finished.Free;
  FGate.Free;
  FLock.Free;
  inherited Destroy;
end;

function TProbeTool.Handle(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
begin
  FLock.Acquire;
  try
    Inc(FInFlight);
    if FInFlight > FPeak then
      FPeak := FInFlight;
    Inc(FArrived);
    if FArrived >= FNeed then
      FGate.SetEvent;
  finally
    FLock.Release;
  end;
  { Block until every expected call has arrived, so concurrency is forced: if
    the loop ran the calls serially this would time out (each call waits for a
    sibling that can never start). The timeout is generous for real threads
    (they arrive in microseconds) but bounds the serial case. }
  FGate.WaitFor(500);
  FLock.Acquire;
  try
    Dec(FInFlight);
    Finished.Add(AArgumentsJson);
  finally
    FLock.Release;
  end;
  AResult := 'ok';
  AError := '';
  Result := True;
end;

{ TCountingStore }

constructor TCountingStore.Create;
begin
  inherited Create;
  FInner := TMemoryConversationStore.Create;
end;

destructor TCountingStore.Destroy;
begin
  FInner.Free;
  inherited Destroy;
end;

procedure TCountingStore.Append(const AMessage: TChatMessage);
begin
  Inc(FAppends);
  FInner.Append(AMessage);
end;

function TCountingStore.Messages: TChatMessageArray;
begin
  Result := FInner.Messages;
end;

procedure TCountingStore.Clear;
begin
  FInner.Clear;
end;

procedure TCountingStore.AppendReasoning(const AText: string;
  ADurationMs: Int64);
begin
  FInner.AppendReasoning(AText, ADurationMs);
end;

procedure TCountingStore.AppendError(const AMessage, ADetail: string);
begin
  FInner.AppendError(AMessage, ADetail);
end;

procedure TCountingStore.AppendAmbient(const AText, ARefSessionId, ALabel,
  ASource, AStatus: string; AElapsedMs: Int64);
begin
  FInner.AppendAmbient(AText, ARefSessionId, ALabel, ASource, AStatus, AElapsedMs);
end;

function TCountingStore.BeginTurn: Int64;
begin
  Result := FInner.BeginTurn;
end;

function TCountingStore.BeginRequest(ATurnId: Int64; const AModel: string;
  AMessageCount: Integer): Int64;
begin
  Result := FInner.BeginRequest(ATurnId, AModel, AMessageCount);
end;

procedure TCountingStore.FinishRequest(ARequestId: Int64;
  const AOutcome: TRequestOutcome);
begin
  FInner.FinishRequest(ARequestId, AOutcome);
end;

procedure TCountingStore.FinishTurn(ATurnId: Int64;
  const AOutcome: TTurnOutcome);
begin
  FInner.FinishTurn(ATurnId, AOutcome);
end;

procedure TCountingStore.DropTurnMessages(ATurnId: Int64);
begin
  FInner.DropTurnMessages(ATurnId);
end;

{ TRecordingStore }

constructor TRecordingStore.Create;
begin
  inherited Create;
  FInner := TMemoryConversationStore.Create;
end;

destructor TRecordingStore.Destroy;
begin
  FInner.Free;
  inherited Destroy;
end;

procedure TRecordingStore.Append(const AMessage: TChatMessage);
begin
  if AMessage.Role = crTool then
    LastTool := AMessage
  else if AMessage.Role = crAssistant then
    LastAssistant := AMessage
  else if AMessage.Role = crUser then
    Inc(UserAppends);
  FInner.Append(AMessage);
end;

function TRecordingStore.Messages: TChatMessageArray;
begin
  Result := FInner.Messages;
end;

procedure TRecordingStore.Clear;
begin
  FInner.Clear;
end;

procedure TRecordingStore.AppendReasoning(const AText: string;
  ADurationMs: Int64);
begin
  Reasoning := Reasoning + AText;
  ReasoningMs := ADurationMs;
end;

procedure TRecordingStore.AppendError(const AMessage, ADetail: string);
begin
  LastError := AMessage;
  LastErrorDetail := ADetail;
end;

procedure TRecordingStore.AppendAmbient(const AText, ARefSessionId, ALabel,
  ASource, AStatus: string; AElapsedMs: Int64);
begin
  { Record the ambient as a plain append so Messages reflects it. }
  Inc(AmbientAppends);
  LastAmbientRef := ARefSessionId;
  LastAmbientMs := AElapsedMs;
  FInner.AppendAmbient(AText, ARefSessionId, ALabel, ASource, AStatus, AElapsedMs);
end;

function TRecordingStore.BeginTurn: Int64;
begin
  Inc(BeginTurns);
  Result := 1;
end;

function TRecordingStore.BeginRequest(ATurnId: Int64; const AModel: string;
  AMessageCount: Integer): Int64;
begin
  Inc(BeginRequests);
  LastRequestModel := AModel;
  LastRequestMessages := AMessageCount;
  Result := 1;
end;

procedure TRecordingStore.FinishRequest(ARequestId: Int64;
  const AOutcome: TRequestOutcome);
begin
  Inc(FinishRequests);
  LastOutcome := AOutcome;
end;

procedure TRecordingStore.FinishTurn(ATurnId: Int64;
  const AOutcome: TTurnOutcome);
begin
  Inc(FinishTurns);
  LastTurnStatus := AOutcome.Status;
end;

procedure TRecordingStore.DropTurnMessages(ATurnId: Int64);
begin
  FInner.DropTurnMessages(ATurnId);
end;

{ TCancelAfter }

constructor TCancelAfter.Create(AAfter: Integer);
begin
  inherited Create;
  FAfter := AAfter;
  FCalls := 0;
end;

function TCancelAfter.Check: Boolean;
begin
  Inc(FCalls);
  Result := FCalls > FAfter;
end;

{ TAgentLoopTest }

procedure TAgentLoopTest.TearDown;
begin
  FLoop.Free;
  FTools.Free;
  FStore := nil;
  FRecorder := nil;
  FClient.Free;
  FFake.Free;
  FFailTools.Free;
  FLoop := nil;
  FTools := nil;
  FClient := nil;
  FFake := nil;
  FFailTools := nil;
end;

function TAgentLoopTest.BuildLoop(const APrompt: string;
  AMaxIters: Integer): TAgentLoop;
var
  Cfg: TLLMConfig;
  ACfg: TAgentConfig;
begin
  Cfg.Endpoint := 'https://example.test/v1/chat/completions';
  Cfg.Model := 'm';
  Cfg.ApiKey := 'k';
  Cfg.ConnectTimeoutMs := 1000;
  Cfg.ReadTimeoutMs := 5000;
  FFake := TFakeTransport.Create;
  FClient := TLLMClient.Create(Cfg, FFake);
  FStore := TMemoryConversationStore.Create;
  FTools := TToolRegistry.Create;
  FFailTools := TFailTools.Create;
  ACfg := Default(TAgentConfig);
  ACfg.SystemPrompt := APrompt;
  { Give the budget headroom so most tests never hit an interception. }
  ACfg.SoftToolLimit := AMaxIters;
  ACfg.HardToolLimit := AMaxIters + 1;
  { Retry is exercised by BuildLoopRetry; here it would only add delay. }
  ACfg.RetryMaxAttempts := -1;
  FLoop := TAgentLoop.Create(FClient, FStore, FTools, ACfg);
  Result := FLoop;
end;

function TAgentLoopTest.BuildLoopRetry(const APrompt: string;
  AMaxIters, AMaxAttempts: Integer): TAgentLoop;
var
  Cfg: TLLMConfig;
  ACfg: TAgentConfig;
begin
  Cfg.Endpoint := 'https://example.test/v1/chat/completions';
  Cfg.Model := 'm';
  Cfg.ApiKey := 'k';
  Cfg.ConnectTimeoutMs := 1000;
  Cfg.ReadTimeoutMs := 5000;
  FFake := TFakeTransport.Create;
  FClient := TLLMClient.Create(Cfg, FFake);
  FStore := TMemoryConversationStore.Create;
  FTools := TToolRegistry.Create;
  FFailTools := TFailTools.Create;
  ACfg := Default(TAgentConfig);
  ACfg.SystemPrompt := APrompt;
  ACfg.SoftToolLimit := AMaxIters;
  ACfg.HardToolLimit := AMaxIters + 1;
  ACfg.RetryMaxAttempts := AMaxAttempts;
  { A 1 ms base keeps the backoff out of the test's wall clock. }
  ACfg.RetryBaseMs := 1;
  ACfg.RetryMaxMs := 2;
  ACfg.RetryBudgetMs := 1000;
  FLoop := TAgentLoop.Create(FClient, FStore, FTools, ACfg);
  Result := FLoop;
end;

function TAgentLoopTest.BuildLoopRecording(
  AMaxContinuations: Integer): TRecordingStore;
var
  Cfg: TLLMConfig;
  ACfg: TAgentConfig;
begin
  Cfg.Endpoint := 'https://example.test/v1/chat/completions';
  Cfg.Model := 'm';
  Cfg.ApiKey := 'k';
  Cfg.ConnectTimeoutMs := 1000;
  Cfg.ReadTimeoutMs := 5000;
  FFake := TFakeTransport.Create;
  FClient := TLLMClient.Create(Cfg, FFake);
  FRecorder := TRecordingStore.Create;
  FStore := FRecorder;
  FTools := TToolRegistry.Create;
  RegisterDefaultTools(FTools);
  FFailTools := TFailTools.Create;
  ACfg := Default(TAgentConfig);
  ACfg.SystemPrompt := '';
  ACfg.MaxContinuations := AMaxContinuations;
  FLoop := TAgentLoop.Create(FClient, FStore, FTools, ACfg);
  Result := FRecorder;
end;

function TAgentLoopTest.BuildLoopBudget(ASoft, AHard, AStep,
  AMaxContext: Integer): TRecordingStore;
var
  Cfg: TLLMConfig;
  ACfg: TAgentConfig;
begin
  Cfg.Endpoint := 'https://example.test/v1/chat/completions';
  Cfg.Model := 'm';
  Cfg.ApiKey := 'k';
  Cfg.ConnectTimeoutMs := 1000;
  Cfg.ReadTimeoutMs := 5000;
  FFake := TFakeTransport.Create;
  FClient := TLLMClient.Create(Cfg, FFake);
  FRecorder := TRecordingStore.Create;
  FStore := FRecorder;
  FTools := TToolRegistry.Create;
  RegisterDefaultTools(FTools);
  FFailTools := TFailTools.Create;
  ACfg := Default(TAgentConfig);
  ACfg.SoftToolLimit := ASoft;
  ACfg.HardToolLimit := AHard;
  ACfg.ToolNoticeStep := AStep;
  ACfg.MaxContextTokens := AMaxContext;
  FLoop := TAgentLoop.Create(FClient, FStore, FTools, ACfg);
  Result := FRecorder;
end;

function TAgentLoopTest.MessageCount(const ABody: string): Integer;
var
  Root: TJSONObject;
begin
  Root := TJSONObject(GetJSON(ABody));
  try
    Result := TJSONArray(Root.Find('messages')).Count;
  finally
    Root.Free;
  end;
end;

function TAgentLoopTest.RoleAt(const ABody: string; AIndex: Integer): string;
var
  Root: TJSONObject;
  Msgs: TJSONArray;
begin
  Root := TJSONObject(GetJSON(ABody));
  try
    Msgs := TJSONArray(Root.Find('messages'));
    Result := TJSONObject(Msgs.Items[AIndex]).Get('role', '');
  finally
    Root.Free;
  end;
end;

function TAgentLoopTest.ContentAt(const ABody: string; AIndex: Integer): string;
var
  Root: TJSONObject;
  Msgs: TJSONArray;
begin
  Root := TJSONObject(GetJSON(ABody));
  try
    Msgs := TJSONArray(Root.Find('messages'));
    Result := TJSONObject(Msgs.Items[AIndex]).Get('content', '');
  finally
    Root.Free;
  end;
end;

function TAgentLoopTest.ToolCallIdAt(const ABody: string;
  AIndex: Integer): string;
var
  Root: TJSONObject;
  Msgs: TJSONArray;
begin
  Root := TJSONObject(GetJSON(ABody));
  try
    Msgs := TJSONArray(Root.Find('messages'));
    Result := TJSONObject(Msgs.Items[AIndex]).Get('tool_call_id', '');
  finally
    Root.Free;
  end;
end;

procedure TAgentLoopTest.TestSendSingleTurnReturnsAnswer;
var
  Sink: TTextSink;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  FFake.AddResponse([TextDelta('hi there'), FinishFrame('stop'), DoneFrame]);
  Sink := TTextSink.Create;
  try
    AssertTrue('send ok', FLoop.Send('hello', Sink.OnText, Answer, Err));
    AssertEquals('answer', 'hi there', Answer);
    AssertEquals('one call', 1, FFake.Calls);
  finally
    Sink.Free;
  end;
end;

procedure TAgentLoopTest.TestTextDeltasAreForwarded;
var
  Sink: TTextSink;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  FFake.AddResponse([TextDelta('a'), TextDelta('b'), TextDelta('c'),
    FinishFrame('stop'), DoneFrame]);
  Sink := TTextSink.Create;
  try
    AssertTrue('send ok', FLoop.Send('hi', Sink.OnText, Answer, Err));
    AssertEquals('streamed', 'abc', Sink.Text);
  finally
    Sink.Free;
  end;
end;

procedure TAgentLoopTest.TestToolCallIsExecutedAndFedBack;
var
  Answer: string;
  Err: TLLMError;
  Roles: array[0..2] of string;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('the time is now'), FinishFrame('stop'),
    DoneFrame]);

  AssertTrue('send ok', FLoop.Send('what time is it?', nil, Answer, Err));
  AssertEquals('final answer', 'the time is now', Answer);
  AssertEquals('two provider calls', 2, FFake.Calls);

  Roles[0] := RoleAt(FFake.LastBody, 0);
  Roles[1] := RoleAt(FFake.LastBody, 1);
  Roles[2] := RoleAt(FFake.LastBody, 2);
  AssertEquals('user', 'user', Roles[0]);
  AssertEquals('assistant', 'assistant', Roles[1]);
  AssertEquals('tool', 'tool', Roles[2]);

  AssertEquals('tool_call_id in body', 'call_1',
    ToolCallIdAt(FFake.LastBody, 2));
end;

procedure TAgentLoopTest.TestMultipleToolCallsAllExecuted;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  FFake.AddResponse([
    ToolNameFrame(0, 'call_1', 'get_system_time'),
    ToolNameFrame(1, 'call_2', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"test"}'),
    ToolArgsFrame(1, '{"reason":"test"}'),
    FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('both done'), FinishFrame('stop'), DoneFrame]);

  AssertTrue('send ok', FLoop.Send('twice', nil, Answer, Err));
  AssertEquals('answer', 'both done', Answer);
  AssertEquals('user + assistant + two tool messages', 4,
    MessageCount(FFake.LastBody));
  AssertEquals('first tool id', 'call_1', ToolCallIdAt(FFake.LastBody, 2));
  AssertEquals('second tool id', 'call_2', ToolCallIdAt(FFake.LastBody, 3));
end;

procedure TAgentLoopTest.TestToolResultsFollowAssistantInOrder;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  FFake.AddResponse([
    ToolNameFrame(0, 'a', 'get_system_time'),
    ToolNameFrame(1, 'b', 'get_system_time'),
    FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('assistant', 'assistant', RoleAt(FFake.LastBody, 1));
  AssertEquals('tool a', 'tool', RoleAt(FFake.LastBody, 2));
  AssertEquals('tool b', 'tool', RoleAt(FFake.LastBody, 3));
end;

procedure TAgentLoopTest.TestParallelToolCallsRunConcurrently;
var
  Answer: string;
  Err: TLLMError;
  Spec: TToolSpec;
  Probe: TProbeTool;
  Pool: IAsyncScheduler;
begin
  { Three parallel-safe calls must overlap: the probe blocks each call until all
    three have arrived, so a serial loop would time out (not reach the peak). }
  BuildLoop('', 8);
  Probe := TProbeTool.Create(3);
  Pool := TExecutorScheduler.Create(4, 0);
  try
    Spec := Default(TToolSpec);
    Spec.Name := 'probe';
    Spec.Description := 'concurrency probe';
    Spec.ParametersJson := '{"type":"object","properties":{}}';
    FTools.Add(Spec, Probe.Handle);
    FLoop.ToolPool := Pool;

    FFake.AddResponse([
      ToolNameFrame(0, 'c1', 'probe'),
      ToolNameFrame(1, 'c2', 'probe'),
      ToolNameFrame(2, 'c3', 'probe'),
      ToolArgsFrame(0, '{"reason":"r","id":"c1"}'),
      ToolArgsFrame(1, '{"reason":"r","id":"c2"}'),
      ToolArgsFrame(2, '{"reason":"r","id":"c3"}'),
      FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);

    AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
    AssertTrue('all three ran at once (peak >= 3)', Probe.Peak >= 3);
    AssertEquals('answer', 'done', Answer);
  finally
    Pool := nil;
    Probe.Free;
  end;
end;

procedure TAgentLoopTest.TestParallelToolResultsAreInCallOrder;
var
  Answer: string;
  Err: TLLMError;
  Spec: TToolSpec;
  Probe: TProbeTool;
  Pool: IAsyncScheduler;
begin
  { Completion order is not call order; results must still be paired in call
    order (a1, a2, a3), so the next request reads correctly. }
  BuildLoop('', 8);
  Probe := TProbeTool.Create(3);
  Pool := TExecutorScheduler.Create(4, 0);
  try
    Spec := Default(TToolSpec);
    Spec.Name := 'probe';
    Spec.Description := 'probe';
    Spec.ParametersJson := '{"type":"object","properties":{}}';
    FTools.Add(Spec, Probe.Handle);
    FLoop.ToolPool := Pool;

    FFake.AddResponse([
      ToolNameFrame(0, 'a1', 'probe'),
      ToolNameFrame(1, 'a2', 'probe'),
      ToolNameFrame(2, 'a3', 'probe'),
      ToolArgsFrame(0, '{"reason":"r"}'),
      ToolArgsFrame(1, '{"reason":"r"}'),
      ToolArgsFrame(2, '{"reason":"r"}'),
      FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));

    AssertEquals('first result is a1', 'a1', ToolCallIdAt(FFake.LastBody, 2));
    AssertEquals('second is a2', 'a2', ToolCallIdAt(FFake.LastBody, 3));
    AssertEquals('third is a3', 'a3', ToolCallIdAt(FFake.LastBody, 4));
  finally
    Pool := nil;
    Probe.Free;
  end;
end;

procedure TAgentLoopTest.TestMixedBatchKeepsOrderAndSerializesUnsafe;
var
  Answer: string;
  Err: TLLMError;
  Spec: TToolSpec;
  Probe: TProbeTool;
  Pool: IAsyncScheduler;
begin
  { A not-parallel-safe call between two parallel-safe runs keeps execution
    order: the two safe runs each overlap, but nothing overlaps the unsafe call,
    and the result ids stay in call order. }
  BuildLoop('', 8);
  Probe := TProbeTool.Create(2);
  Pool := TExecutorScheduler.Create(4, 0);
  try
    Spec := Default(TToolSpec);
    Spec.Name := 'probe';
    Spec.Description := 'probe';
    Spec.ParametersJson := '{"type":"object","properties":{}}';
    FTools.Add(Spec, Probe.Handle);
    { A serial tool: never overlaps. }
    Spec.Name := 'serial_probe';
    Spec.SerialOnly := True;   { never overlaps a sibling }
    FTools.Add(Spec, Probe.Handle);
    FLoop.ToolPool := Pool;

    FFake.AddResponse([
      ToolNameFrame(0, 's1', 'probe'),
      ToolNameFrame(1, 's2', 'probe'),
      ToolNameFrame(2, 'x1', 'serial_probe'),
      ToolArgsFrame(0, '{"reason":"r"}'),
      ToolArgsFrame(1, '{"reason":"r"}'),
      ToolArgsFrame(2, '{"reason":"r"}'),
      FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
    AssertEquals('order kept: s1', 's1', ToolCallIdAt(FFake.LastBody, 2));
    AssertEquals('order kept: s2', 's2', ToolCallIdAt(FFake.LastBody, 3));
    AssertEquals('order kept: x1', 'x1', ToolCallIdAt(FFake.LastBody, 4));
  finally
    Pool := nil;
    Probe.Free;
  end;
end;

procedure TAgentLoopTest.TestWithoutAToolPoolCallsAreSerial;
var
  Answer: string;
  Err: TLLMError;
  Spec: TToolSpec;
  Probe: TProbeTool;
begin
  { No pool => the original serial path. The probe's gate needs two arrivals, so
    a serial run times out at 1 (never reaches 2) and the call still returns. }
  BuildLoop('', 8);
  Probe := TProbeTool.Create(2);
  try
    Spec := Default(TToolSpec);
    Spec.Name := 'probe';
    Spec.Description := 'probe';
    Spec.ParametersJson := '{"type":"object","properties":{}}';
    FTools.Add(Spec, Probe.Handle);
    { FLoop.ToolPool stays nil. }

    FFake.AddResponse([
      ToolNameFrame(0, 'a1', 'probe'),
      ToolNameFrame(1, 'a2', 'probe'),
      ToolArgsFrame(0, '{"reason":"r"}'),
      ToolArgsFrame(1, '{"reason":"r"}'),
      FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
    AssertEquals('peak stays 1 without a pool', 1, Probe.Peak);
    AssertEquals('answer', 'done', Answer);
  finally
    Probe.Free;
  end;
end;

procedure TAgentLoopTest.TestABlockedCallDoesNotHoldUpItsSibling;
var
  Answer: string;
  Err: TLLMError;
  SlowSpec, FastSpec: TToolSpec;
  Probe: TGatedProbe;
  Pool: IAsyncScheduler;
begin
  { The requirement: if call #1 is blocked (as one awaiting the approval gate
    is) and call #2 is not, #2 runs while #1 waits. Here 'slow' blocks until
    'fast' releases it, so a serial loop would never overlap (FastSawSlowInFlight
    stays False and the slow call times out at 1s). }
  BuildLoop('', 8);
  Probe := TGatedProbe.Create;
  Pool := TExecutorScheduler.Create(4, 0);
  try
    SlowSpec := Default(TToolSpec);
    SlowSpec.Name := 'slow';
    SlowSpec.Description := 'blocks';
    SlowSpec.ParametersJson := '{"type":"object","properties":{}}';
    FTools.Add(SlowSpec, Probe.Slow);
    FastSpec := Default(TToolSpec);
    FastSpec.Name := 'fast';
    FastSpec.Description := 'quick';
    FastSpec.ParametersJson := '{"type":"object","properties":{}}';
    FTools.Add(FastSpec, Probe.Fast);
    FLoop.ToolPool := Pool;

    FFake.AddResponse([
      ToolNameFrame(0, 'g1', 'slow'),
      ToolNameFrame(1, 'u1', 'fast'),
      ToolArgsFrame(0, '{"reason":"r"}'),
      ToolArgsFrame(1, '{"reason":"r"}'),
      FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
    AssertTrue('the sibling ran while the first was blocked',
      Probe.FastSawSlowInFlight);
    AssertEquals('answer', 'done', Answer);
  finally
    Pool := nil;
    Probe.Free;
  end;
end;

procedure TAgentLoopTest.TestUnknownToolReturnsErrorResultAndContinues;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'no_such_tool'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('recovered'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('answer', 'recovered', Answer);
  AssertTrue('error result present', Pos('unknown tool', FFake.LastBody) > 0);
end;

procedure TAgentLoopTest.TestFailingHandlerReturnsErrorResultAndContinues;
var
  Answer: string;
  Err: TLLMError;
  Spec: TToolSpec;
begin
  BuildLoop('', 8);
  Spec.Name := 'fail_tool';
  Spec.Description := 'always fails';
  Spec.ParametersJson := '{"type":"object","properties":{}}';
  FTools.Add(Spec, FFailTools.AlwaysFail);
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'fail_tool'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('still here'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('answer', 'still here', Answer);
  AssertTrue('failure reported', Pos('failed', FFake.LastBody) > 0);
end;

procedure TAgentLoopTest.TestRaisingHandlerIsCaughtAndReported;
var
  Answer: string;
  Err: TLLMError;
  Spec: TToolSpec;
begin
  BuildLoop('', 8);
  Spec.Name := 'raise_tool';
  Spec.Description := 'raises';
  Spec.ParametersJson := '{"type":"object","properties":{}}';
  FTools.Add(Spec, FFailTools.AlwaysRaise);
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'raise_tool'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('survived'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('answer', 'survived', Answer);
  AssertTrue('exception reported', Pos('kaboom', FFake.LastBody) > 0);
end;

procedure TAgentLoopTest.TestToolCallLoopAbortsAtTheHardLimit;
var
  Answer: string;
  Err: TLLMError;
begin
  { Soft 2, hard 3: the call is intercepted at 2 and 3, and the call after that
    ends the turn as a loop error. }
  BuildLoop('', 2);
  RegisterDefaultTools(FTools);
  { A single response that always asks for a tool call; the fake repeats it. }
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  AssertFalse('aborts', FLoop.Send('loop forever', nil, Answer, Err));
  AssertEquals('loop error', Ord(leLoop), Ord(Err.Code));
  AssertTrue('mentions the loop', Pos('tool call loop', Err.Message) > 0);
end;

procedure TAgentLoopTest.TestSoftLimitRunsAndNudges;
var
  Rec: TRecordingStore;
  Answer: string;
  Err: TLLMError;
begin
  { Soft 1, step 1: the call RUNS - a soft limit is an advisory, not a failure. }
  Rec := BuildLoopBudget(1, 100, 1, 0);
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertTrue('the call was run', Rec.LastTool.ToolOk);
  { The nudge rode the next request's tool response, loop-only (never stored). }
  AssertTrue('a soft notice was delivered as an advisory',
    Pos('<advisory>', FFake.LastBody) > 0);
  AssertTrue('the advisory names the limit',
    Pos('tool call limit notice', FFake.LastBody) > 0);
end;

procedure TAgentLoopTest.TestHardLimitLocksDownTheCall;
var
  Rec: TRecordingStore;
  Answer: string;
  Err: TLLMError;
begin
  { Soft 1, hard 2: round 1 nudges, round 2 locks down; then the model stops. }
  Rec := BuildLoopBudget(1, 2, 5, 0);
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([ToolNameFrame(0, 'call_2', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertTrue('a lockdown notice was returned',
    Pos('no further tool calls', Rec.LastTool.Content) > 0);
end;

procedure TAgentLoopTest.TestContextLimitAborts;
var
  Answer: string;
  Err: TLLMError;
begin
  { The running context (prompt tokens) may not exceed the cap. }
  BuildLoopBudget(100, 200, 5, 10);
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":50,"completion_tokens":1,"total_tokens":51}'),
    FinishFrame('stop'), DoneFrame]);
  AssertFalse('aborts', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('loop error', Ord(leLoop), Ord(Err.Code));
  AssertTrue('mentions the context', Pos('context limit', Err.Message) > 0);
end;

procedure TAgentLoopTest.OnAfterChunk(Sender: TObject);
begin
  if not FQueuedOnce then
  begin
    FQueuedOnce := True;
    FLoop.PromptQueue.Push('more context');
  end;
end;

procedure TAgentLoopTest.TestQueuedPromptIsInjected;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoopRecording;
  FLoop.PromptQueue.Push('more context');
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertTrue('the queued prompt reached the payload',
    Pos('more context', FFake.LastBody) > 0);
end;

procedure TAgentLoopTest.TestQueuedAmbientDrainsAsAmbient;
var
  Rec: TRecordingStore;
  Msgs: TChatMessageArray;
  Answer: string;
  Err: TLLMError;
  I: Integer;
  Found: Boolean;
begin
  Rec := BuildLoopRecording;
  FLoop.PromptQueue.PushAmbient('subagent result', 'child-1', 'research', 'delegate_task', 'completed', 4200);
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  { The ambient reached the payload wrapped as a user message. }
  AssertTrue('wrapped in the payload',
    Pos('<ambient ', FFake.LastBody) > 0);
  AssertTrue('carries the child id',
    Pos('child-1', FFake.LastBody) > 0);
  { It was recorded as an ambient append, not a user append. }
  AssertEquals('ambient append recorded', 1, Rec.AmbientAppends);
  AssertEquals('ref session', 'child-1', Rec.LastAmbientRef);
  AssertEquals('elapsed', 4200, Rec.LastAmbientMs);
  { The memory store degrades the ambient to a plain user message. }
  Msgs := FStore.Messages;
  Found := False;
  for I := 0 to High(Msgs) do
    if Pos('subagent result', Msgs[I].Content) > 0 then
      Found := True;
  AssertTrue('ambient content present in history', Found);
end;

procedure TAgentLoopTest.TestStablePromptReachesTheSystemMessage;
{ The stable prompt (skill descriptions) rides the system message, request-only.
  Without this a skill's description is in no prompt at all: the per-request
  fragment carries state only. }
var
  Answer: string;
  Err: TLLMError;
  Body: string;
  Count, I: Integer;
begin
  BuildLoop('you are a test', 8);
  FLoop.StablePrompt := 'SKILL-DESCRIPTIONS-HERE';
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('hi', nil, Answer, Err));
  Body := FFake.Bodies[0];
  Count := MessageCount(Body);
  AssertTrue('a system message exists', Count > 0);
  AssertEquals('the first message is the system prompt', 'system',
    RoleAt(Body, 0));
  AssertTrue('the stable text is appended to it',
    Pos('SKILL-DESCRIPTIONS-HERE', ContentAt(Body, 0)) > 0);
  { And nowhere else: it must not also ride the user turn, or it would be
    re-sent twice. }
  for I := 1 to Count - 1 do
    AssertTrue('message ' + IntToStr(I) + ' must not repeat it',
      Pos('SKILL-DESCRIPTIONS-HERE', ContentAt(Body, I)) = 0);
end;

procedure TAgentLoopTest.TestStablePromptIsAbsentWhenUnset;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('you are a test', 8);
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('hi', nil, Answer, Err));
  AssertEquals('the system prompt is exactly what was configured', 'system',
    RoleAt(FFake.Bodies[0], 0));
  AssertTrue('no stray separator',
    Pos(#10#10#10, ContentAt(FFake.Bodies[0], 0)) = 0);
end;

procedure TAgentLoopTest.TestABoardNoticeIsNotPersisted;
{ A board notice is TRANSIENT. It rides the tail and is forgotten: if it were
  persisted as an ambient row, ten agents posting on a busy board would leave
  ninety permanent conversation rows riding every later prompt - the cheap signal
  would become the expensive part. }
var
  Answer: string;
  Err: TLLMError;
  Before, After: Integer;
begin
  BuildLoop('', 8);
  Before := Length(FStore.Messages);
  FLoop.PromptQueue.PushBoard('2 new board messages', 2);
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('hi', nil, Answer, Err));
  After := Length(FStore.Messages);
  { The turn appends the user message and the assistant reply: two rows, and
    nothing for the board notice. }
  AssertEquals('only the user turn and the reply were stored', Before + 2,
    After);
  { And no stored row carries the notice text. }
  AssertTrue('the notice is not in the history',
    Pos('2 new board messages', FStore.Messages[High(FStore.Messages)].Content)
      = 0);
end;

procedure TAgentLoopTest.TestPrewrappedUserMessagesAreNotWrappedAgain;
begin
  { The loop wraps the last user turn unless it is already wrapped; a second pass
    would escape the markup and the model would read it as text. An ambient
    notification and a checkpoint handoff are both delivered pre-wrapped. }
  AssertTrue('an ambient notification',
    IsPrewrappedUserMessage('<ambient timestamp="x">'));
  AssertTrue('a checkpoint handoff',
    IsPrewrappedUserMessage('<handoff seq="15924">'));
  AssertFalse('a plain turn', IsPrewrappedUserMessage('fix the modal'));
  AssertFalse('a mid-text mention',
    IsPrewrappedUserMessage('see the <handoff> docs'));
end;

procedure TAgentLoopTest.TestSupersededMessageIsByteIdenticalAcrossRequests;
{ THE prompt-cache invariant. In a multi-round turn the user message stops being
  the newest message once tool results arrive; from that request onward it must
  be byte-identical, or the provider's prefix cache is invalidated at that index
  and everything after it is re-billed at full price.

  Note what is NOT asserted: that call 1's user message equals call 2's. Call 1
  had it as the TAIL, so it carried the context block; call 2 superseded it and
  it reverted to its stable form. That reversion is the design - it is what makes
  the history converge on the stored form. The invariant starts at the moment of
  supersession: from then on the bytes never move.

  This failed before the tail rewrite: the user message carried <now> and
  <usage>, both of which change per request, so it differed on EVERY call,
  including the ones after it was superseded. }
var
  Answer: string;
  Err: TLLMError;
  AtCall2, AtCall3: string;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  { Three requests: round 1 (the user message is the tail), round 2 after the
    first tool result (the user message is now superseded), round 3 after the
    second. Compare the last two. }
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([ToolNameFrame(0, 'call_2', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);

  AssertTrue('send ok', FLoop.Send('what time is it?', nil, Answer, Err));
  AssertTrue('three requests', FFake.Bodies.Count >= 3);

  AtCall2 := ContentAt(FFake.Bodies[1], 0);
  AtCall3 := ContentAt(FFake.Bodies[2], 0);
  AssertEquals('the superseded user message never moves again', AtCall2, AtCall3);
  { And once superseded it is in its stable form: no tail of its own. }
  AssertTrue('it carries no tail', Pos('<guard>', AtCall2) = 0);
  AssertEquals('it is the stored text exactly',
    '<message>what time is it?</message>', AtCall2);
end;

procedure TAgentLoopTest.TestTailRidesOnlyTheNewestMessage;
{ The volatile tail - clock, usage, guard - must appear on exactly one message
  per request: the last. Every earlier message is in its stable form. }
var
  Answer: string;
  Err: TLLMError;
  Body: string;
  Count, I, WithTail: Integer;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);

  AssertTrue('send ok', FLoop.Send('hello', nil, Answer, Err));

  { Inspect the SECOND request: it has a user message, an assistant tool call and
    a tool result, so the tail belongs to the tool result only. }
  Body := FFake.Bodies[1];
  Count := MessageCount(Body);
  AssertTrue('the second request has several messages', Count >= 3);
  WithTail := 0;
  for I := 0 to Count - 1 do
    if Pos('<guard>', ContentAt(Body, I)) > 0 then
      Inc(WithTail);
  AssertEquals('exactly one message carries the tail', 1, WithTail);
  AssertTrue('and it is the last one',
    Pos('<guard>', ContentAt(Body, Count - 1)) > 0);
end;

procedure TAgentLoopTest.TestTailConvergesAcrossTurns;
{ Across turns the sent history must converge on the stored history: turn 1's
  user message is sent WRAPPED as the tail during turn 1, and PLAIN during turn
  2 (because a newer message is then the tail). That reversion is what makes the
  conversation cacheable; it is the opposite of freezing the wrapper in place. }
var
  Answer: string;
  Err: TLLMError;
  Turn1User, Turn2User: string;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  FFake.AddResponse([TextDelta('one'), FinishFrame('stop'), DoneFrame]);
  FFake.AddResponse([TextDelta('two'), FinishFrame('stop'), DoneFrame]);

  AssertTrue('turn 1', FLoop.Send('first question', nil, Answer, Err));
  AssertTrue('turn 2', FLoop.Send('second question', nil, Answer, Err));
  AssertTrue('two calls at least', FFake.Bodies.Count >= 2);

  { In turn 1's request the user message is the tail, so it carries the guard.
    In turn 2's request it is superseded and must be plain. }
  Turn1User := ContentAt(FFake.Bodies[0], 0);
  Turn2User := ContentAt(FFake.Bodies[1], 0);
  AssertTrue('turn 1: the user message carries the tail',
    Pos('<guard>', Turn1User) > 0);
  AssertEquals('turn 2: it is superseded and plain',
    '<message>first question</message>', Turn2User);
end;

procedure TAgentLoopTest.TestRetryBackoffIsExponentialAndCapped;
begin
  AssertEquals('base', 500, RetryBackoffMs(0, 500, 10000));
  AssertEquals('doubles', 1000, RetryBackoffMs(1, 500, 10000));
  AssertEquals('quadruples', 2000, RetryBackoffMs(2, 500, 10000));
  AssertEquals('capped', 10000, RetryBackoffMs(10, 500, 10000));
  AssertEquals('no base, no wait', 0, RetryBackoffMs(3, 0, 10000));
end;

procedure TAgentLoopTest.TestRetryOnNetworkThenSucceed;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoopRetry('', 8, 3);
  FFake.NetworkFailuresLeft := 2;
  FFake.AddResponse([TextDelta('recovered'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('the retry succeeded', 'recovered', Answer);
  AssertEquals('three attempts were made', 3, FFake.Calls);
end;

procedure TAgentLoopTest.TestRetryExhaustionReportsAttempts;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoopRetry('', 8, 2);
  FFake.NetworkFailuresLeft := 99;
  AssertFalse('send fails', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('network code', Ord(leNetwork), Ord(Err.Code));
  AssertEquals('the message counts the attempts',
    'network error after 3 attempts', Err.Message);
  AssertEquals('the cause is carried', 'simulated network failure', Err.Detail);
  AssertEquals('three attempts were made', 3, FFake.Calls);
end;

procedure TAgentLoopTest.TestRetryDisabledWhenNegative;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoopRetry('', 8, -1);
  FFake.NetworkFailuresLeft := 99;
  AssertFalse('send fails', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('one attempt only', 1, FFake.Calls);
  AssertEquals('no attempt count in the message', 'network error', Err.Message);
end;

procedure TAgentLoopTest.TestSendAmbientStartsWithoutUserMessage;
var
  Rec: TRecordingStore;
  Answer: string;
  Err: TLLMError;
  Events: TAgentEvents;
begin
  Rec := BuildLoopRecording;
  FLoop.PromptQueue.PushAmbient('the delegated answer', 'child-9', 'research', 'delegate_task', 'completed', 100);
  FFake.AddResponse([TextDelta('ack'), FinishFrame('stop'), DoneFrame]);
  Events := Default(TAgentEvents);
  AssertTrue('ambient send ok', FLoop.SendAmbient(Events, Answer, Err));
  AssertEquals('no user append for an ambient turn', 0, Rec.UserAppends);
  AssertEquals('one ambient append', 1, Rec.AmbientAppends);
  AssertTrue('the ambient is in the payload',
    Pos('the delegated answer', FFake.LastBody) > 0);
end;

procedure TAgentLoopTest.TestSendAmbientDrainsQueuedAmbient;
var
  Rec: TRecordingStore;
  Answer: string;
  Err: TLLMError;
  Events: TAgentEvents;
begin
  { An ambient turn with nothing queued: the queue is drained (nothing to
    inject) and no user message is appended. The client rejects an empty
    request, so this fails cleanly at the boundary rather than hanging. }
  Rec := BuildLoopRecording;
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  Events := Default(TAgentEvents);
  FLoop.SendAmbient(Events, Answer, Err);
  AssertEquals('no user append', 0, Rec.UserAppends);
  AssertEquals('no ambient append', 0, Rec.AmbientAppends);
end;

procedure TAgentLoopTest.TestQueuedPromptSupersedesAToolCall;
var
  Rec: TRecordingStore;
  Msgs: TChatMessageArray;
  Answer: string;
  Err: TLLMError;
  I: Integer;
  SawTool: Boolean;
begin
  Rec := BuildLoopRecording;
  FQueuedOnce := False;
  FFake.AfterChunk := OnAfterChunk;
  FFake.AddResponse([ToolNameFrame(0, 'c1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"r"}'), FinishFrame('tool_calls'),
    DoneFrame]);
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));

  { The tool call was dropped, not run. }
  Msgs := Rec.Messages;
  SawTool := False;
  for I := 0 to High(Msgs) do
    if Msgs[I].Role = crTool then
      SawTool := True;
  AssertFalse('the tool call was dropped', SawTool);
  { The queued prompt reached the second request. }
  AssertTrue('the queued prompt reached the payload',
    Pos('more context', FFake.LastBody) > 0);
end;

procedure TAgentLoopTest.TestQueuedPromptsStartTheNextTurn;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoopRecording;
  FQueuedOnce := False;
  FFake.AfterChunk := OnAfterChunk;
  FFake.AddResponse([TextDelta('one'), FinishFrame('stop'), DoneFrame]);
  FFake.AddResponse([TextDelta('two'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('the queued prompt started a second turn', 2, FFake.Calls);
  AssertEquals('the last turn answered', 'two', Answer);
end;

procedure TAgentLoopTest.TestEarlyCancelDropsTheTurn;
var
  Rec: TRecordingStore;
  Cancel: TCancelAfter;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  { The fake consults the check between chunks, so the first request is aborted
    mid-stream. }
  Cancel := TCancelAfter.Create(1);
  try
    FLoop.CancelCheck := Cancel.Check;
    FFake.AddResponse([TextDelta('partial'), FinishFrame('stop'), DoneFrame]);
    AssertFalse('send cancelled', FLoop.Send('go', nil, Answer, Err));
    AssertEquals('cancelled', Ord(leCancelled), Ord(Err.Code));
    AssertTrue('the turn was dropped', FLoop.LastTurnDropped);
    AssertEquals('no messages kept', 0, Length(Rec.Messages));
    AssertEquals('turn row still cancelled', Ord(tsCancelled),
      Ord(Rec.LastTurnStatus));
  finally
    Cancel.Free;
  end;
end;

procedure TAgentLoopTest.TestLateCancelKeepsTheTurn;
var
  Rec: TRecordingStore;
  Cancel: TCancelAfter;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  { Fires on the second request's first chunk, after a tool call has committed. }
  Cancel := TCancelAfter.Create(6);
  try
    FLoop.CancelCheck := Cancel.Check;
    FFake.AddResponse([ToolNameFrame(0, 'c1', 'get_system_time'),
      ToolArgsFrame(0, '{"reason":"r"}'), FinishFrame('tool_calls'),
      DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    AssertFalse('send cancelled', FLoop.Send('go', nil, Answer, Err));
    AssertEquals('cancelled', Ord(leCancelled), Ord(Err.Code));
    AssertFalse('the turn was kept', FLoop.LastTurnDropped);
    AssertTrue('messages kept', Length(Rec.Messages) >= 3);
  finally
    Cancel.Free;
  end;
end;

procedure TAgentLoopTest.TestLengthFinishReasonReported;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  { The fake repeats the last response, so every continuation is truncated too
    and the budget runs out. }
  FFake.AddResponse([TextDelta('partial'), FinishFrame('length'), DoneFrame]);
  AssertFalse('fails', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('truncation error', Ord(leTruncated), Ord(Err.Code));
  AssertTrue('mentions truncation', Pos('truncated', Err.Message) > 0);
end;

procedure TAgentLoopTest.TestContentFilterFinishReasonReported;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  FFake.AddResponse([FinishFrame('content_filter'), DoneFrame]);
  AssertFalse('fails', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('provider error', Ord(leProvider), Ord(Err.Code));
end;

procedure TAgentLoopTest.TestTruncatedResponseContinuesToStop;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoopRecording;
  FFake.AddResponse([TextDelta('partial '), FinishFrame('length'), DoneFrame]);
  FFake.AddResponse([TextDelta('answer'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('the fragments are joined', 'partial answer', Answer);
  AssertEquals('two requests', 2, FFake.Calls);
end;

procedure TAgentLoopTest.TestContinuationCommitsOneMessage;
var
  Rec: TRecordingStore;
  Msgs: TChatMessageArray;
  Answer: string;
  Err: TLLMError;
  Assistant, I: Integer;
begin
  Rec := BuildLoopRecording;
  FFake.AddResponse([TextDelta('partial '), FinishFrame('length'), DoneFrame]);
  FFake.AddResponse([TextDelta('answer'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));

  Msgs := Rec.Messages;
  Assistant := 0;
  for I := 0 to High(Msgs) do
  begin
    if Msgs[I].Role = crAssistant then
    begin
      Inc(Assistant);
      AssertEquals('one merged message', 'partial answer', Msgs[I].Content);
    end;
    AssertFalse('the instruction was not persisted',
      Pos(ContinuationInstruction, Msgs[I].Content) > 0);
  end;
  AssertEquals('exactly one assistant message', 1, Assistant);
end;

procedure TAgentLoopTest.TestContinuationMergesReasoning;
var
  Rec: TRecordingStore;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  FFake.AddResponse([ReasoningDelta('think one '), TextDelta('partial '),
    FinishFrame('length'), DoneFrame]);
  FFake.AddResponse([ReasoningDelta('think two'), TextDelta('answer'),
    FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('reasoning is merged once', 'think one think two', Rec.Reasoning);
end;

procedure TAgentLoopTest.TestContinuationRequestCarriesPending;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoopRecording;
  FFake.AddResponse([TextDelta('partial '), FinishFrame('length'), DoneFrame]);
  FFake.AddResponse([TextDelta('answer'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertTrue('the pending fragment is sent', Pos('partial', FFake.LastBody) > 0);
  AssertTrue('the instruction is sent',
    Pos('Continue exactly', FFake.LastBody) > 0);
end;

procedure TAgentLoopTest.TestEmptyContentTruncationContinues;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoopRecording;
  { A reasoning model can spend its whole budget before any content. }
  FFake.AddResponse([FinishFrame('length'), DoneFrame]);
  FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('answer', 'done', Answer);
  AssertEquals('two requests', 2, FFake.Calls);
end;

procedure TAgentLoopTest.TestContinuationCapFailsTurn;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoopRecording(2);
  FFake.AddResponse([TextDelta('a'), FinishFrame('length'), DoneFrame]);
  AssertFalse('fails', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('truncation error', Ord(leTruncated), Ord(Err.Code));
  AssertEquals('the cap plus the original request', 3, FFake.Calls);
end;

procedure TAgentLoopTest.TestContinuationDisabledFailsImmediately;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoopRecording(-1);
  FFake.AddResponse([TextDelta('a'), FinishFrame('length'), DoneFrame]);
  AssertFalse('fails', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('truncation error', Ord(leTruncated), Ord(Err.Code));
  AssertEquals('no continuation request', 1, FFake.Calls);
end;

procedure TAgentLoopTest.TestContinuationHonoursContextGuard;
var
  Answer: string;
  Err: TLLMError;
begin
  { The prompt-token cap is checked before the finish reason, so an over-large
    continuation prompt still fails the turn. }
  BuildLoopBudget(100, 200, 5, 10);
  FFake.AddResponse([TextDelta('a'),
    UsageFrame('{"prompt_tokens":50,"completion_tokens":1,"total_tokens":51}'),
    FinishFrame('length'), DoneFrame]);
  AssertFalse('aborts', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('loop error', Ord(leLoop), Ord(Err.Code));
end;

procedure TAgentLoopTest.TestTruncatedToolCallIsNotExecuted;
var
  Capture: TCaptureTool;
  Spec: TToolSpec;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  Capture := TCaptureTool.Create;
  try
    Spec.Name := 'capture';
    Spec.Description := 'capture the call';
    Spec.ParametersJson := '{"type":"object","properties":{}}';
    FTools.Add(Spec, Capture.Handle);
    { The arguments are cut off mid-JSON. }
    FFake.AddResponse([ToolNameFrame(0, 'c1', 'capture'),
      ToolArgsFrame(0, '{"reason":"r"'), FinishFrame('length'), DoneFrame]);
    FFake.AddResponse([TextDelta('resubmitted'), FinishFrame('stop'),
      DoneFrame]);
    AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
    AssertEquals('the cut-off call never ran', 0, Capture.Calls);
    AssertEquals('the loop continued', 2, FFake.Calls);
  finally
    Capture.Free;
  end;
end;

procedure TAgentLoopTest.TestTruncatedToolCallGetsPairedNotice;
var
  Rec: TRecordingStore;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  FFake.AddResponse([ToolNameFrame(0, 'c1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"r"'), FinishFrame('length'), DoneFrame]);
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('the notice is paired to the call', 'c1', Rec.LastTool.ToolCallId);
  AssertFalse('the notice is a failure result', Rec.LastTool.ToolOk);
  AssertTrue('the notice explains the drop',
    Pos('cut off', Rec.LastTool.Content) > 0);
end;

procedure TAgentLoopTest.TestNonContinuableErrorDiscardsPending;
var
  Rec: TRecordingStore;
  Msgs: TChatMessageArray;
  Answer: string;
  Err: TLLMError;
  I: Integer;
begin
  Rec := BuildLoopRecording;
  FFake.AddResponse([TextDelta('partial'), FinishFrame('length'), DoneFrame]);
  FFake.AddResponse([FinishFrame('content_filter'), DoneFrame]);
  AssertFalse('fails', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('provider error', Ord(leProvider), Ord(Err.Code));

  Msgs := Rec.Messages;
  for I := 0 to High(Msgs) do
    AssertTrue('no fragment was persisted', Msgs[I].Role <> crAssistant);
end;

procedure TAgentLoopTest.TestCommittedToolRoundSurvivesLaterTruncationError;
var
  Rec: TRecordingStore;
  Msgs: TChatMessageArray;
  Answer: string;
  Err: TLLMError;
  I: Integer;
  SawTool: Boolean;
begin
  Rec := BuildLoopRecording;
  FFake.AddResponse([ToolNameFrame(0, 'c1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"r"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('partial'), FinishFrame('length'), DoneFrame]);
  FFake.AddResponse([FinishFrame('content_filter'), DoneFrame]);
  AssertFalse('fails', FLoop.Send('go', nil, Answer, Err));

  Msgs := Rec.Messages;
  SawTool := False;
  for I := 0 to High(Msgs) do
    if Msgs[I].Role = crTool then
      SawTool := True;
  AssertTrue('the committed tool round survives', SawTool);
end;

procedure TAgentLoopTest.TestConversationPersistsAcrossTurns;
var
  Answer: string;
  Err: TLLMError;
  Msgs: TChatMessageArray;
begin
  BuildLoop('', 8);
  FFake.AddResponse([TextDelta('one'), FinishFrame('stop'), DoneFrame]);
  FFake.AddResponse([TextDelta('two'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('turn 1', FLoop.Send('first', nil, Answer, Err));
  AssertEquals('one', 'one', Answer);
  AssertTrue('turn 2', FLoop.Send('second', nil, Answer, Err));
  AssertEquals('two', 'two', Answer);

  Msgs := FStore.Messages;
  AssertEquals('four messages stored', 4, Length(Msgs));
  AssertEquals('u', 'user', RoleAt(FFake.LastBody, 0));
  AssertEquals('second call has prior turn', 3, MessageCount(FFake.LastBody));
end;

procedure TAgentLoopTest.TestSystemPromptIncludedFirst;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('you are a test harness', 8);
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('hi', nil, Answer, Err));
  AssertEquals('system first', 'system', RoleAt(FFake.LastBody, 0));
  AssertTrue('system content present', Pos('you are a test harness',
    FFake.LastBody) > 0);
end;

procedure TAgentLoopTest.TestStoreIsUsedThroughTheInterface;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  CountStore: TCountingStore;
  Store: IConversationStore;
  Tools: TToolRegistry;
  Loop: TAgentLoop;
  Cfg: TLLMConfig;
  ACfg: TAgentConfig;
  Answer: string;
  Err: TLLMError;
begin
  Cfg.Endpoint := 'https://example.test/v1/chat/completions';
  Cfg.Model := 'm';
  Cfg.ApiKey := 'k';
  Fake := TFakeTransport.Create;
  Client := TLLMClient.Create(Cfg, Fake);
  CountStore := TCountingStore.Create;
  Store := CountStore;
  Tools := TToolRegistry.Create;
  ACfg := Default(TAgentConfig);
  ACfg.SystemPrompt := '';
  Loop := TAgentLoop.Create(Client, Store, Tools, ACfg);
  try
    Fake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', Loop.Send('hi', nil, Answer, Err));
    AssertTrue('appended via interface', CountStore.Appends >= 2);
  finally
    Loop.Free;
    Tools.Free;
    Store := nil;
    Client.Free;
    Fake.Free;
  end;
end;

procedure TAgentLoopTest.TestDefaultToolsRegistered;
var
  Tools: TToolRegistry;
  Tool: TRegisteredTool;
  R, E: string;
begin
  Tools := TToolRegistry.Create;
  try
    RegisterDefaultTools(Tools);
    AssertTrue('has at least one tool', Tools.Count >= 1);
    AssertTrue('find get_system_time',
      Tools.Find(BuiltinGetSystemTimeName, Tool));
    AssertTrue('handler runs', Tool.Handler('{}', R, E));
    AssertTrue('returns something', R <> '');
  finally
    Tools.Free;
  end;
end;

procedure TAgentLoopTest.TestRegistryRemovePresentAndAbsent;
var
  Tools: TToolRegistry;
  Spec: TToolSpec;
  Tool: TRegisteredTool;
begin
  Tools := TToolRegistry.Create;
  try
    Spec := Default(TToolSpec);
    Spec.Name := 'a';
    Spec.ParametersJson := '{"type":"object","properties":{}}';
    Tools.Add(Spec, nil);
    Spec.Name := 'b';
    Tools.Add(Spec, nil);
    AssertEquals('two', 2, Tools.Count);
    AssertTrue('remove present', Tools.Remove('a'));
    AssertEquals('one left', 1, Tools.Count);
    AssertFalse('gone', Tools.Find('a', Tool));
    AssertFalse('remove absent', Tools.Remove('a'));
    AssertEquals('unchanged', 1, Tools.Count);
  finally
    Tools.Free;
  end;
end;

type
  { A stub turn provider: one optional tool, an optional prompt fragment. }
  TStubProvider = class(TInterfacedObject, IToolProvider)
  public
    PrepareCalls: Integer;
    ToolName: string;
    Fragment: string;
    Found: Integer;
    procedure Prepare;
    function Specs: TToolSpecArray;
    function PromptFragment: string;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    function Handle(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;

  TStubProvider2 = class(TInterfacedObject, IToolProvider)
  public
    ToolName: string;
    procedure Prepare;
    function Specs: TToolSpecArray;
    function PromptFragment: string;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    function Handle(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;

function TStubProvider.Handle(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver): Boolean;
begin
  AResult := 'stub result';
  AError := '';
  Result := True;
end;

function TStubProvider2.Handle(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver): Boolean;
begin
  AResult := 'stub2 result';
  AError := '';
  Result := True;
end;

procedure TStubProvider.Prepare;
begin
  Inc(PrepareCalls);
end;

function TStubProvider.Specs: TToolSpecArray;
begin
  Result := nil;
  if ToolName = '' then
    Exit;
  SetLength(Result, 1);
  Result[0] := MakeToolSpec(ToolName, 'a stub tool',
    '{"type":"object","properties":{}}');
end;

function TStubProvider.PromptFragment: string;
begin
  Result := Fragment;
end;

function TStubProvider.Find(const AName: string;
  out ATool: TRegisteredTool): Boolean;
begin
  Result := (ToolName <> '') and (AName = ToolName);
  if Result then
  begin
    Inc(Found);
    ATool := Default(TRegisteredTool);
    ATool.Spec := MakeToolSpec(ToolName, 'a stub tool',
      '{"type":"object","properties":{}}');
    ATool.Handler := Handle;
  end;
end;

procedure TStubProvider2.Prepare;
begin
end;

function TStubProvider2.Specs: TToolSpecArray;
begin
  Result := nil;
end;

function TStubProvider2.PromptFragment: string;
begin
  Result := '';
end;

function TStubProvider2.Find(const AName: string;
  out ATool: TRegisteredTool): Boolean;
begin
  Result := (AName = ToolName);
  if Result then
  begin
    ATool := Default(TRegisteredTool);
    ATool.Handler := Handle;
  end;
end;

procedure TAgentLoopTest.TestProviderToolsComposedIntoRequest;
var
  P: TStubProvider;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  P := TStubProvider.Create;
  P.ToolName := 'provider_tool';
  try
    FLoop.AddProvider(P);
    FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', FLoop.Send('hi', nil, Answer, Err));
    AssertTrue('provider tool in request', Pos('provider_tool',
      FFake.LastBody) > 0);
  finally
    P := nil;   { the loop owns it via the provider interface }
  end;
end;

procedure TAgentLoopTest.TestProviderPrepareCalledOncePerTurn;
var
  P: TStubProvider;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  P := TStubProvider.Create;
  try
    FLoop.AddProvider(P);
    FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
    FLoop.Send('hi', nil, Answer, Err);
    AssertEquals('prepared once', 1, P.PrepareCalls);
  finally
    P := nil;   { the loop owns it via the provider interface }
  end;
end;

procedure TAgentLoopTest.TestProviderPromptInjectedRequestOnly;
var
  P: TStubProvider;
  Before, After: Integer;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  P := TStubProvider.Create;
  P.Fragment := 'INJECTED_SKILL_GUIDANCE';
  try
    FLoop.AddProvider(P);
    FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
    Before := Length(FStore.Messages);
    FLoop.Send('hi', nil, Answer, Err);
    AssertTrue('fragment in request', Pos('INJECTED_SKILL_GUIDANCE',
      FFake.LastBody) > 0);
    After := Length(FStore.Messages);
    { The stored conversation must not gain a system fragment: only the user
      message and the assistant reply are added (two, same as without one). }
    AssertEquals('two messages added (user + assistant)', Before + 2, After);
  finally
    P := nil;   { the loop owns it via the provider interface }
  end;
end;

procedure TAgentLoopTest.TestProviderToolDispatches;
var
  P: TStubProvider;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  P := TStubProvider.Create;
  P.ToolName := 'provider_tool';
  try
    FLoop.AddProvider(P);
    FFake.AddResponse([ToolNameFrame(0, 'c1', 'provider_tool'),
      ToolArgsFrame(0, '{"reason":"x"}'), FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
    AssertTrue('provider handler dispatched', P.Found > 0);
  finally
    P := nil;   { the loop owns it via the provider interface }
  end;
end;

procedure TAgentLoopTest.TestNativeToolTakesPriorityOverProvider;
var
  P: TStubProvider;
  Tool: TRegisteredTool;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  P := TStubProvider.Create;
  P.ToolName := 'get_system_time';   { same name as a native tool }
  try
    FLoop.AddProvider(P);
    AssertTrue('resolves', FLoop.ResolveTool('get_system_time', Tool));
    AssertEquals('native spec wins (has a description)',
      'Return the current UTC time as an ISO 8601 timestamp.', Tool.Spec.Description);
  finally
    P := nil;   { the loop owns it via the provider interface }
  end;
end;

type
  { A probe that adds a tool at the turn boundary. }
  TBoundaryProbe = class
  public
    Calls: Integer;
    Tools: TToolRegistry;
    procedure OnBoundary;
  end;

procedure TBoundaryProbe.OnBoundary;
var
  Spec: TToolSpec;
begin
  Inc(Calls);
  Spec := Default(TToolSpec);
  Spec.Name := 'added_at_boundary';
  Spec.ParametersJson := '{"type":"object","properties":{}}';
  Tools.Add(Spec, nil);
end;

procedure TAgentLoopTest.TestTurnStartHookFiresOnceBeforeRequest;
var
  Tools: TToolRegistry;
  Loop: TAgentLoop;
  Cfg: TLLMConfig;
  ACfg: TAgentConfig;
  Fake: TFakeTransport;
  Client: TLLMClient;
  Store: IConversationStore;
  Probe: TBoundaryProbe;
  Answer: string;
  Err: TLLMError;
begin
  Cfg := Default(TLLMConfig);
  Cfg.Endpoint := 'https://example.test/v1/chat/completions';
  Cfg.Model := 'm';
  Cfg.ApiKey := 'k';
  Fake := TFakeTransport.Create;
  Client := TLLMClient.Create(Cfg, Fake);
  Store := TMemoryConversationStore.Create;
  Tools := TToolRegistry.Create;
  ACfg := Default(TAgentConfig);
  ACfg.SystemPrompt := '';
  Loop := TAgentLoop.Create(Client, Store, Tools, ACfg);
  Probe := TBoundaryProbe.Create;
  Probe.Tools := Tools;
  try
    Loop.OnTurnStart := Probe.OnBoundary;
    Fake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', Loop.Send('hi', nil, Answer, Err));
    AssertEquals('fired once', 1, Probe.Calls);
    AssertEquals('tool added at boundary is registered', 1, Tools.Count);
  finally
    Loop.Free;
    Probe.Free;
    Tools.Free;
    Client.Free;
    Fake.Free;
  end;
end;

procedure TAgentLoopTest.TestTurnStartNilIsNoOp;
var
  Tools: TToolRegistry;
  Loop: TAgentLoop;
  Cfg: TLLMConfig;
  ACfg: TAgentConfig;
  Fake: TFakeTransport;
  Client: TLLMClient;
  Store: IConversationStore;
  Answer: string;
  Err: TLLMError;
begin
  Cfg := Default(TLLMConfig);
  Cfg.Endpoint := 'https://example.test/v1/chat/completions';
  Cfg.Model := 'm';
  Cfg.ApiKey := 'k';
  Fake := TFakeTransport.Create;
  Client := TLLMClient.Create(Cfg, Fake);
  Store := TMemoryConversationStore.Create;
  Tools := TToolRegistry.Create;
  ACfg := Default(TAgentConfig);
  ACfg.SystemPrompt := '';
  Loop := TAgentLoop.Create(Client, Store, Tools, ACfg);
  try
    { No OnTurnStart set: Send must not raise. }
    Fake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', Loop.Send('hi', nil, Answer, Err));
  finally
    Loop.Free;
    Tools.Free;
    Client.Free;
    Fake.Free;
  end;
end;

procedure TAgentLoopTest.TestGetSystemTimeReturnsParseableTime;
var
  Tools: TToolRegistry;
  Tool: TRegisteredTool;
  R, E: string;
begin
  Tools := TToolRegistry.Create;
  try
    RegisterDefaultTools(Tools);
    Tools.Find(BuiltinGetSystemTimeName, Tool);
    AssertTrue('handler', Tool.Handler('{}', R, E));
    AssertEquals('iso length', 20, Length(R));
    AssertEquals('date/time separator', 'T', R[11]);
    AssertEquals('utc suffix', 'Z', R[20]);
  finally
    Tools.Free;
  end;
end;

procedure TAgentLoopTest.TestEmptyToolNameIsIgnored;
var
  Tools: TToolRegistry;
  Spec: TToolSpec;
begin
  Tools := TToolRegistry.Create;
  try
    Spec.Name := '';
    Spec.Description := 'nameless';
    Spec.ParametersJson := '{}';
    Tools.Add(Spec, FFailTools.AlwaysFail);
    AssertEquals('ignored', 0, Tools.Count);
  finally
    Tools.Free;
  end;
end;

procedure TAgentLoopTest.TestReasoningForwardedThroughEvents;
var
  Log: TEventLog;
  Events: TAgentEvents;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  Log := TEventLog.Create;
  try
    FFake.AddResponse([ReasoningDelta('let me think'), TextDelta('answer'),
      FinishFrame('stop'), DoneFrame]);
    Events := Default(TAgentEvents);
    Events.OnText := Log.OnText;
    Events.OnReasoning := Log.OnReasoning;
    AssertTrue('send ok', FLoop.Send('hi', Events, Answer, Err));
    AssertTrue('reasoning event', Log.Has('reason:let me think'));
    AssertTrue('text event', Log.Has('text:answer'));
  finally
    Log.Free;
  end;
end;

procedure TAgentLoopTest.TestToolCallEventFiresWithNameAndArgs;
var
  Log: TEventLog;
  Events: TAgentEvents;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  Log := TEventLog.Create;
  try
    FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
      ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    Events := Default(TAgentEvents);
    Events.OnToolCall := Log.OnToolCall;
    Events.OnToolResult := Log.OnToolResult;
    AssertTrue('send ok', FLoop.Send('time?', Events, Answer, Err));
    AssertTrue('call event',
      Log.Has('call:call_1:get_system_time:{"reason":"test"}:test'));
  finally
    Log.Free;
  end;
end;

procedure TAgentLoopTest.TestToolResultEventFiresWithResult;
var
  Log: TEventLog;
  Events: TAgentEvents;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  Log := TEventLog.Create;
  try
    FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
      ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    Events := Default(TAgentEvents);
    Events.OnToolResult := Log.OnToolResult;
    AssertTrue('send ok', FLoop.Send('time?', Events, Answer, Err));
    AssertTrue('result event ok', Log.Has('result:call_1:True'));
  finally
    Log.Free;
  end;
end;

procedure TAgentLoopTest.TestToolResultEventReportsFailure;
var
  Log: TEventLog;
  Events: TAgentEvents;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  Log := TEventLog.Create;
  try
    FFake.AddResponse([ToolNameFrame(0, 'call_1', 'no_such_tool'),
      ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('recovered'), FinishFrame('stop'), DoneFrame]);
    Events := Default(TAgentEvents);
    Events.OnToolResult := Log.OnToolResult;
    AssertTrue('send ok', FLoop.Send('go', Events, Answer, Err));
    AssertTrue('result event failure', Log.Has('result:call_1:False'));
  finally
    Log.Free;
  end;
end;

procedure TAgentLoopTest.TestToolCallAndResultEventsAreInOrder;
var
  Log: TEventLog;
  Events: TAgentEvents;
  Answer: string;
  Err: TLLMError;
  CallIdx, ResultIdx: Integer;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  Log := TEventLog.Create;
  try
    FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
      ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    Events := Default(TAgentEvents);
    Events.OnToolCall := Log.OnToolCall;
    Events.OnToolResult := Log.OnToolResult;
    AssertTrue('send ok', FLoop.Send('time?', Events, Answer, Err));
    CallIdx := Log.IndexOfFragment('call:call_1');
    ResultIdx := Log.IndexOfFragment('result:call_1');
    AssertTrue('call before result', (CallIdx >= 0) and (ResultIdx > CallIdx));
  finally
    Log.Free;
  end;
end;

procedure TAgentLoopTest.TestObserverForwardsChunks;
var
  Log: TEventLog;
  Events: TAgentEvents;
  Answer: string;
  Err: TLLMError;
  Spec: TToolSpec;
  StreamTool: TStreamTool;
begin
  BuildLoop('', 8);
  StreamTool := TStreamTool.Create;
  try
    Spec.Name := 'stream_tool';
    Spec.Description := 'streams output';
    Spec.ParametersJson := '{"type":"object","properties":{}}';
    FTools.Add(Spec, StreamTool.Handle);
    Log := TEventLog.Create;
    try
      FFake.AddResponse([ToolNameFrame(0, 'call_1', 'stream_tool'),
        ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'),
        DoneFrame]);
      FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
      Events := Default(TAgentEvents);
      Events.OnToolOutput := Log.OnToolOutput;
      AssertTrue('send ok', FLoop.Send('go', Events, Answer, Err));
      AssertTrue('first chunk',
        Log.Has('out:call_1:stream_tool:chunk-1'));
      AssertTrue('second chunk',
        Log.Has('out:call_1:stream_tool:chunk-2'));
    finally
      Log.Free;
    end;
  finally
    StreamTool.Free;
  end;
end;

procedure TAgentLoopTest.TestSingleShotToolEmitsNoChunks;
var
  Log: TEventLog;
  Events: TAgentEvents;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  Log := TEventLog.Create;
  try
    FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
      ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'),
      DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    Events := Default(TAgentEvents);
    Events.OnToolOutput := Log.OnToolOutput;
    AssertTrue('send ok', FLoop.Send('go', Events, Answer, Err));
    AssertEquals('no chunks', -1, Log.IndexOfFragment('out:'));
  finally
    Log.Free;
  end;
end;

procedure TAgentLoopTest.TestForwardObserverDropsChunksAfterComplete;
var
  Log: TEventLog;
  Observer: TToolForwardObserver;
begin
  Log := TEventLog.Create;
  try
    Observer := TToolForwardObserver.Create('id_1', 'stream_tool',
      Log.OnToolOutput);
    try
      Observer.Next('before');
      Observer.Complete;
      Observer.Next('after');
    finally
      Observer.Free;
    end;
    AssertTrue('before complete', Log.Has('out:id_1:stream_tool:before'));
    AssertEquals('after complete dropped', -1,
      Log.IndexOfFragment('after'));
  finally
    Log.Free;
  end;
end;

procedure TAgentLoopTest.TestV1SendOverloadStillWorks;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('v1 send', FLoop.Send('hi', nil, Answer, Err));
  AssertEquals('answer', 'ok', Answer);
end;

procedure TAgentLoopTest.TestRegistrationAddsRequiredReasonParam;
var
  Tools: TToolRegistry;
  Spec: TToolSpec;
  Stored: TRegisteredTool;
  Root, Props, ReasonProp: TJSONObject;
  Required: TJSONArray;
  I: Integer;
  HasReason: Boolean;
begin
  Tools := TToolRegistry.Create;
  try
    Spec.Name := 'x';
    Spec.Description := 'd';
    Spec.ParametersJson :=
      '{"type":"object","properties":{"dir":{"type":"string"}},"required":["dir"]}';
    Tools.Add(Spec, FFailTools.AlwaysFail);
    AssertTrue('registered', Tools.Find('x', Stored));
    Root := TJSONObject(GetJSON(Stored.Spec.ParametersJson));
    try
      Props := TJSONObject(Root.Find('properties'));
      AssertTrue('has properties', Props <> nil);
      ReasonProp := TJSONObject(Props.Find(ToolReasonParamName));
      AssertTrue('has reason property', ReasonProp <> nil);
      AssertEquals('reason is string', 'string',
        ReasonProp.Get('type', ''));
      AssertEquals('reason is capped', ToolReasonMaxLength,
        ReasonProp.Get('maxLength', 0));
      Required := TJSONArray(Root.Find('required'));
      HasReason := False;
      for I := 0 to Required.Count - 1 do
        if Required.Strings[I] = ToolReasonParamName then
          HasReason := True;
      AssertTrue('reason required', HasReason);
    finally
      Root.Free;
    end;
  finally
    Tools.Free;
  end;
end;

procedure TAgentLoopTest.TestRegistrationPreservesExistingParams;
var
  Tools: TToolRegistry;
  Spec: TToolSpec;
  Stored: TRegisteredTool;
  Root, Props: TJSONObject;
begin
  Tools := TToolRegistry.Create;
  try
    Spec.Name := 'x';
    Spec.Description := 'd';
    Spec.ParametersJson :=
      '{"type":"object","properties":{"dir":{"type":"string"}},"required":["dir"]}';
    Tools.Add(Spec, FFailTools.AlwaysFail);
    Tools.Find('x', Stored);
    Root := TJSONObject(GetJSON(Stored.Spec.ParametersJson));
    try
      Props := TJSONObject(Root.Find('properties'));
      AssertTrue('dir preserved', Props.Find('dir') <> nil);
    finally
      Root.Free;
    end;
  finally
    Tools.Free;
  end;
end;

procedure TAgentLoopTest.TestRegistrationIsIdempotent;
var
  Tools: TToolRegistry;
  Spec: TToolSpec;
  Stored: TRegisteredTool;
  Root, Props: TJSONObject;
  Required: TJSONArray;
  I, Count: Integer;
begin
  Tools := TToolRegistry.Create;
  try
    Spec.Name := 'x';
    Spec.Description := 'd';
    Spec.ParametersJson :=
      '{"type":"object","properties":{"reason":{"type":"string"}},"required":["reason"]}';
    Tools.Add(Spec, FFailTools.AlwaysFail);
    Tools.Find('x', Stored);
    Root := TJSONObject(GetJSON(Stored.Spec.ParametersJson));
    try
      Props := TJSONObject(Root.Find('properties'));
      AssertTrue('reason property present', Props.Find('reason') <> nil);
      Required := TJSONArray(Root.Find('required'));
      Count := 0;
      for I := 0 to Required.Count - 1 do
        if Required.Strings[I] = ToolReasonParamName then
          Inc(Count);
      AssertEquals('one required reason', 1, Count);
    finally
      Root.Free;
    end;
  finally
    Tools.Free;
  end;
end;

procedure TAgentLoopTest.TestMalformedSchemaIsIgnored;
var
  Tools: TToolRegistry;
  Spec: TToolSpec;
begin
  Tools := TToolRegistry.Create;
  try
    Spec.Name := 'x';
    Spec.Description := 'd';
    Spec.ParametersJson := 'not json';
    Tools.Add(Spec, FFailTools.AlwaysFail);
    AssertEquals('ignored', 0, Tools.Count);
  finally
    Tools.Free;
  end;
end;

procedure TAgentLoopTest.TestExtractReasonAcceptsNonEmpty;
var
  R, E: string;
begin
  AssertTrue('ok', ExtractToolReason('{"reason":"need it"}', R, E));
  AssertEquals('reason', 'need it', R);
end;

procedure TAgentLoopTest.TestExtractReasonRejectsMissing;
var
  R, E: string;
begin
  AssertFalse('missing', ExtractToolReason('{"other":1}', R, E));
  AssertTrue('names reason', Pos('missing required', E) > 0);
end;

procedure TAgentLoopTest.TestExtractReasonRejectsBlank;
var
  R, E: string;
begin
  AssertFalse('blank', ExtractToolReason('{"reason":"   "}', R, E));
  AssertTrue('names reason', Pos('missing required', E) > 0);
end;

procedure TAgentLoopTest.TestExtractReasonRejectsNonString;
var
  R, E: string;
begin
  AssertFalse('non-string', ExtractToolReason('{"reason":42}', R, E));
  AssertTrue('names type', Pos('must be a string', E) > 0);
end;

procedure TAgentLoopTest.TestExtractReasonRejectsInvalidJson;
var
  R, E: string;
begin
  AssertFalse('invalid', ExtractToolReason('{oops', R, E));
  AssertTrue('names json', Pos('invalid arguments JSON', E) > 0);
end;

procedure TAgentLoopTest.TestCallWithoutReasonReturnsErrorAndContinues;
var
  Answer: string;
  Err: TLLMError;
  Spec: TToolSpec;
  Capture: TCaptureTool;
begin
  BuildLoop('', 8);
  Capture := TCaptureTool.Create;
  try
    Spec.Name := 'cap';
    Spec.Description := 'captures';
    Spec.ParametersJson := '{"type":"object","properties":{}}';
    FTools.Add(Spec, Capture.Handle);
    FFake.AddResponse([ToolNameFrame(0, 'call_1', 'cap'),
      ToolArgsFrame(0, '{}'), FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('recovered'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
    AssertEquals('handler not called', 0, Capture.Calls);
    AssertTrue('error names reason',
      Pos('missing required', FFake.LastBody) > 0);
  finally
    Capture.Free;
  end;
end;

procedure TAgentLoopTest.TestHandlerReceivesFullArgumentsIncludingReason;
var
  Answer: string;
  Err: TLLMError;
  Spec: TToolSpec;
  Capture: TCaptureTool;
begin
  BuildLoop('', 8);
  Capture := TCaptureTool.Create;
  try
    Spec.Name := 'cap';
    Spec.Description := 'captures';
    Spec.ParametersJson := '{"type":"object","properties":{}}';
    FTools.Add(Spec, Capture.Handle);
    FFake.AddResponse([ToolNameFrame(0, 'call_1', 'cap'),
      ToolArgsFrame(0, '{"reason":"because","x":1}'),
      FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', FLoop.Send('go', nil, Answer, Err));
    AssertEquals('handler called', 1, Capture.Calls);
    AssertEquals('full args passed', '{"reason":"because","x":1}',
      Capture.LastArgs);
  finally
    Capture.Free;
  end;
end;

procedure TAgentLoopTest.TestToolCallEventCarriesReason;
var
  Log: TEventLog;
  Events: TAgentEvents;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  Log := TEventLog.Create;
  try
    FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
      ToolArgsFrame(0, '{"reason":"why"}'), FinishFrame('tool_calls'),
      DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    Events := Default(TAgentEvents);
    Events.OnToolCall := Log.OnToolCall;
    AssertTrue('send ok', FLoop.Send('time?', Events, Answer, Err));
    AssertTrue('reason in event',
      Log.Has('call:call_1:get_system_time:{"reason":"why"}:why'));
  finally
    Log.Free;
  end;
end;

procedure TAgentLoopTest.TestPromptAdvertisesReasonRequired;
var
  Answer: string;
  Err: TLLMError;
  Root, Call, Fn, Params, Props: TJSONObject;
  ToolsArr, Required: TJSONArray;
  I: Integer;
  HasReason: Boolean;
begin
  BuildLoop('', 8);
  RegisterDefaultTools(FTools);
  FFake.AddResponse([TextDelta('ok'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('hi', nil, Answer, Err));
  Root := TJSONObject(GetJSON(FFake.LastBody));
  try
    ToolsArr := TJSONArray(Root.Find('tools'));
    Call := TJSONObject(ToolsArr.Items[0]);
    Fn := TJSONObject(Call.Find('function'));
    Params := TJSONObject(Fn.Find('parameters'));
    Props := TJSONObject(Params.Find('properties'));
    AssertTrue('reason advertised', Props.Find(ToolReasonParamName) <> nil);
    Required := TJSONArray(Params.Find('required'));
    HasReason := False;
    for I := 0 to Required.Count - 1 do
      if Required.Strings[I] = ToolReasonParamName then
        HasReason := True;
    AssertTrue('reason required', HasReason);
  finally
    Root.Free;
  end;
end;

procedure TAgentLoopTest.TestSendOpensAndClosesATurn;
var
  Rec: TRecordingStore;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  FFake.AddResponse([TextDelta('hi'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('hello', nil, Answer, Err));
  AssertEquals('one turn opened', 1, Rec.BeginTurns);
  AssertEquals('one turn closed', 1, Rec.FinishTurns);
  AssertEquals('completed', Ord(tsCompleted), Ord(Rec.LastTurnStatus));
  AssertEquals('one request opened', 1, Rec.BeginRequests);
  AssertEquals('one request closed', 1, Rec.FinishRequests);
end;

procedure TAgentLoopTest.TestSendRecordsRequestOutcome;
var
  Rec: TRecordingStore;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}'),
    FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('hello', nil, Answer, Err));
  AssertEquals('model recorded', 'm', Rec.LastRequestModel);
  AssertTrue('message count recorded', Rec.LastRequestMessages > 0);
  AssertTrue('outcome ok', Rec.LastOutcome.Ok);
  AssertEquals('finish reason', Ord(frStop), Ord(Rec.LastOutcome.FinishReason));
  AssertEquals('usage total', 7, Rec.LastOutcome.Usage.TotalTokens);
  AssertTrue('duration measured', Rec.LastOutcome.DurationMs >= 0);
end;

procedure TAgentLoopTest.TestSendRecordsReasoning;
var
  Rec: TRecordingStore;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  FFake.AddResponse([ReasoningDelta('let me think'),
    TextDelta('answer'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('hello', nil, Answer, Err));
  AssertEquals('reasoning recorded', 'let me think', Rec.Reasoning);
end;

procedure TAgentLoopTest.TestLoopRecordsReasoningDuration;
var
  Rec: TRecordingStore;
  Delay: TChunkDelay;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  Delay := TChunkDelay.Create(20);
  try
    FFake.AfterChunk := Delay.AfterChunk;
    FFake.AddResponse([ReasoningDelta('think'), TextDelta('answer'),
      FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', FLoop.Send('hi', nil, Answer, Err));
  finally
    Delay.Free;
  end;
  AssertTrue('reasoning timed', Rec.ReasoningMs >= 10);
end;

procedure TAgentLoopTest.TestLoopRecordsContentDuration;
var
  Rec: TRecordingStore;
  Delay: TChunkDelay;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  Delay := TChunkDelay.Create(20);
  try
    FFake.AfterChunk := Delay.AfterChunk;
    FFake.AddResponse([TextDelta('answer'), FinishFrame('stop'), DoneFrame]);
    AssertTrue('send ok', FLoop.Send('hi', nil, Answer, Err));
  finally
    Delay.Free;
  end;
  AssertTrue('content timed', Rec.LastAssistant.DurationMs >= 10);
end;

procedure TAgentLoopTest.TestLoopReportsReasoningDone;
var
  Log: TEventLog;
  Events: TAgentEvents;
  Delay: TChunkDelay;
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  Log := TEventLog.Create;
  Delay := TChunkDelay.Create(20);
  try
    FFake.AfterChunk := Delay.AfterChunk;
    FFake.AddResponse([ReasoningDelta('think'), TextDelta('answer'),
      FinishFrame('stop'), DoneFrame]);
    Events := Default(TAgentEvents);
    Events.OnText := Log.OnText;
    Events.OnReasoning := Log.OnReasoning;
    Events.OnReasoningDone := Log.OnReasoningDone;
    AssertTrue('send ok', FLoop.Send('hi', Events, Answer, Err));
    AssertTrue('reasoning done fired', Log.Has('reasoningdone:'));
    AssertTrue('reasoning done before text',
      Log.IndexOfFragment('reasoningdone:') < Log.IndexOfFragment('text:'));
  finally
    Delay.Free;
    Log.Free;
  end;
end;

procedure TAgentLoopTest.TestSendRecordsErrorAndFailedTurn;
var
  Rec: TRecordingStore;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  FFake.FailNetwork := True;
  AssertFalse('send fails', FLoop.Send('hello', nil, Answer, Err));
  AssertEquals('failed', Ord(tsFailed), Ord(Rec.LastTurnStatus));
  AssertTrue('error recorded', Rec.LastError <> '');
end;

procedure TAgentLoopTest.TestToolResultCarriesNameOkAndDuration;
var
  Rec: TRecordingStore;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
  AssertTrue('send ok', FLoop.Send('time?', nil, Answer, Err));
  AssertEquals('tool role', Ord(crTool), Ord(Rec.LastTool.Role));
  AssertEquals('tool name', 'get_system_time', Rec.LastTool.ToolName);
  AssertTrue('tool ok', Rec.LastTool.ToolOk);
end;

procedure TAgentLoopTest.TestLoopStopsWhenCancelled;
var
  Rec: TRecordingStore;
  Cancel: TCancelAfter;
  Answer: string;
  Err: TLLMError;
begin
  Rec := BuildLoopRecording;
  Cancel := TCancelAfter.Create(1);
  try
    FLoop.CancelCheck := Cancel.Check;
    FFake.AddResponse([ToolNameFrame(0, 'c1', 'get_system_time'),
      ToolArgsFrame(0, '{"reason":"r"}'), FinishFrame('tool_calls'),
      DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    AssertFalse('send cancelled', FLoop.Send('go', nil, Answer, Err));
    AssertEquals('cancelled code', Ord(leCancelled), Ord(Err.Code));
    AssertEquals('only the first request ran', 1, FFake.Calls);
    AssertEquals('turn cancelled', Ord(tsCancelled), Ord(Rec.LastTurnStatus));
    { A cancel is not an error, so no error block is persisted for it. }
    AssertEquals('no error block', '', Rec.LastError);
  finally
    Cancel.Free;
  end;
end;

initialization
  RegisterTest(TAgentLoopTest);
end.
