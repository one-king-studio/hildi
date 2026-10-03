unit test_agent;
{ fpcunit tests for hildegard.helper.agent, driven by the fake LLM transport. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, jsonparser,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.session,
  llm_fakes;

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
      out AResult: string; out AError: string): Boolean;
    function AlwaysRaise(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
  end;

  { Captures the raw arguments of each successful handler call. }
  TCaptureTool = class
  private
    FCalls: Integer;
    FLastArgs: string;
  public
    function Handle(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    property Calls: Integer read FCalls;
    property LastArgs: string read FLastArgs;
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
    procedure OnToolCall(const AId, AName, AArguments, AReason: string);
    procedure OnToolResult(const AId, AName, AResult: string; AOk: Boolean);
    function Has(const AFragment: string): Boolean;
    function IndexOfFragment(const AFragment: string): Integer;
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
    procedure AppendReasoning(const AText: string);
    procedure AppendError(const AMessage, ADetail: string);
    function BeginTurn: Int64;
    function BeginRequest(ATurnId: Int64; const AModel: string;
      AMessageCount: Integer): Int64;
    procedure FinishRequest(ARequestId: Int64; const AOutcome: TRequestOutcome);
    procedure FinishTurn(ATurnId: Int64; const AOutcome: TTurnOutcome);
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
    LastError: string;
    LastErrorDetail: string;
    LastTool: TChatMessage;
    constructor Create;
    destructor Destroy; override;
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    procedure Clear;
    procedure AppendReasoning(const AText: string);
    procedure AppendError(const AMessage, ADetail: string);
    function BeginTurn: Int64;
    function BeginRequest(ATurnId: Int64; const AModel: string;
      AMessageCount: Integer): Int64;
    procedure FinishRequest(ARequestId: Int64; const AOutcome: TRequestOutcome);
    procedure FinishTurn(ATurnId: Int64; const AOutcome: TTurnOutcome);
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
    function BuildLoop(const APrompt: string; AMaxIters: Integer): TAgentLoop;
    function BuildLoopRecording: TRecordingStore;
    function MessageCount(const ABody: string): Integer;
    function RoleAt(const ABody: string; AIndex: Integer): string;
    function ToolCallIdAt(const ABody: string; AIndex: Integer): string;
  protected
    procedure TearDown; override;
  published
    procedure TestSendSingleTurnReturnsAnswer;
    procedure TestTextDeltasAreForwarded;
    procedure TestToolCallIsExecutedAndFedBack;
    procedure TestMultipleToolCallsAllExecuted;
    procedure TestToolResultsFollowAssistantInOrder;
    procedure TestUnknownToolReturnsErrorResultAndContinues;
    procedure TestFailingHandlerReturnsErrorResultAndContinues;
    procedure TestRaisingHandlerIsCaughtAndReported;
    procedure TestMaxToolIterationsAborts;
    procedure TestLengthFinishReasonReported;
    procedure TestContentFilterFinishReasonReported;
    procedure TestConversationPersistsAcrossTurns;
    procedure TestSystemPromptIncludedFirst;
    procedure TestStoreIsUsedThroughTheInterface;
    procedure TestDefaultToolsRegistered;
    procedure TestGetSystemTimeReturnsParseableTime;
    procedure TestEmptyToolNameIsIgnored;
    procedure TestReasoningForwardedThroughEvents;
    procedure TestToolCallEventFiresWithNameAndArgs;
    procedure TestToolResultEventFiresWithResult;
    procedure TestToolResultEventReportsFailure;
    procedure TestToolCallAndResultEventsAreInOrder;
    procedure TestV1SendOverloadStillWorks;
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
    procedure TestSendRecordsErrorAndFailedTurn;
    procedure TestToolResultCarriesNameOkAndDuration;
    procedure TestLoopStopsWhenCancelled;
  end;

implementation

{ TTextSink }

procedure TTextSink.OnText(const AText: string);
begin
  FText := FText + AText;
end;

{ TCaptureTool }

function TCaptureTool.Handle(const AArgumentsJson: string;
  out AResult: string; out AError: string): Boolean;
begin
  Inc(FCalls);
  FLastArgs := AArgumentsJson;
  AResult := 'ok';
  AError := '';
  Result := True;
end;

{ TFailTools }

function TFailTools.AlwaysFail(const AArgumentsJson: string;
  out AResult: string; out AError: string): Boolean;
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

procedure TEventLog.OnToolCall(const AId, AName, AArguments, AReason: string);
begin
  FLog.Add('call:' + AId + ':' + AName + ':' + AArguments + ':' + AReason);
end;

procedure TEventLog.OnToolResult(const AId, AName, AResult: string;
  AOk: Boolean);
begin
  FLog.Add('result:' + AId + ':' + BoolToStr(AOk, True) + ':' + AResult);
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

function TFailTools.AlwaysRaise(const AArgumentsJson: string;
  out AResult: string; out AError: string): Boolean;
begin
  AResult := '';
  AError := '';
  Result := False;
  raise Exception.Create('kaboom');
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

procedure TCountingStore.AppendReasoning(const AText: string);
begin
  FInner.AppendReasoning(AText);
end;

procedure TCountingStore.AppendError(const AMessage, ADetail: string);
begin
  FInner.AppendError(AMessage, ADetail);
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
    LastTool := AMessage;
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

procedure TRecordingStore.AppendReasoning(const AText: string);
begin
  Reasoning := Reasoning + AText;
end;

procedure TRecordingStore.AppendError(const AMessage, ADetail: string);
begin
  LastError := AMessage;
  LastErrorDetail := ADetail;
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
  ACfg.SystemPrompt := APrompt;
  ACfg.MaxToolIterations := AMaxIters;
  FLoop := TAgentLoop.Create(FClient, FStore, FTools, ACfg);
  Result := FLoop;
end;

function TAgentLoopTest.BuildLoopRecording: TRecordingStore;
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
  ACfg.SystemPrompt := '';
  ACfg.MaxToolIterations := 8;
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

procedure TAgentLoopTest.TestMaxToolIterationsAborts;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 2);
  RegisterDefaultTools(FTools);
  { A single response that always asks for a tool call; the fake repeats it. }
  FFake.AddResponse([ToolNameFrame(0, 'call_1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"test"}'), FinishFrame('tool_calls'), DoneFrame]);
  AssertFalse('aborts', FLoop.Send('loop forever', nil, Answer, Err));
  AssertEquals('provider error', Ord(leProvider), Ord(Err.Code));
  AssertTrue('mentions limit', Pos('iteration limit', Err.Message) > 0);
end;

procedure TAgentLoopTest.TestLengthFinishReasonReported;
var
  Answer: string;
  Err: TLLMError;
begin
  BuildLoop('', 8);
  FFake.AddResponse([TextDelta('partial'), FinishFrame('length'), DoneFrame]);
  AssertFalse('fails', FLoop.Send('go', nil, Answer, Err));
  AssertEquals('provider error', Ord(leProvider), Ord(Err.Code));
  AssertTrue('mentions length', Pos('length', Err.Message) > 0);
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
  ACfg.SystemPrompt := '';
  ACfg.MaxToolIterations := 8;
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
