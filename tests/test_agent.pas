unit test_agent;
{ fpcunit tests for hildegard.helper.agent, driven by the fake LLM transport. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, jsonparser,
  hildegard.helper.llm, hildegard.helper.agent, llm_fakes;

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

  { Records every agent event as a line, to assert on ordering and content. }
  TEventLog = class
  private
    FLog: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnText(const AText: string);
    procedure OnReasoning(const AText: string);
    procedure OnToolCall(const AId, AName, AArguments: string);
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
    property Appends: Integer read FAppends;
  end;

  TAgentLoopTest = class(TTestCase)
  private
    FFake: TFakeTransport;
    FClient: TLLMClient;
    FStore: IConversationStore;
    FTools: TToolRegistry;
    FLoop: TAgentLoop;
    FFailTools: TFailTools;
    function BuildLoop(const APrompt: string; AMaxIters: Integer): TAgentLoop;
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
  end;

implementation

{ TTextSink }

procedure TTextSink.OnText(const AText: string);
begin
  FText := FText + AText;
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

procedure TEventLog.OnToolCall(const AId, AName, AArguments: string);
begin
  FLog.Add('call:' + AId + ':' + AName + ':' + AArguments);
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

{ TAgentLoopTest }

procedure TAgentLoopTest.TearDown;
begin
  FLoop.Free;
  FTools.Free;
  FStore := nil;
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
    ToolArgsFrame(0, '{}'), FinishFrame('tool_calls'), DoneFrame]);
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
    ToolArgsFrame(0, '{}'),
    ToolArgsFrame(1, '{}'),
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
    ToolArgsFrame(0, '{}'), FinishFrame('tool_calls'), DoneFrame]);
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
    ToolArgsFrame(0, '{}'), FinishFrame('tool_calls'), DoneFrame]);
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
    ToolArgsFrame(0, '{}'), FinishFrame('tool_calls'), DoneFrame]);
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
    ToolArgsFrame(0, '{}'), FinishFrame('tool_calls'), DoneFrame]);
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
      ToolArgsFrame(0, '{}'), FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    Events := Default(TAgentEvents);
    Events.OnToolCall := Log.OnToolCall;
    Events.OnToolResult := Log.OnToolResult;
    AssertTrue('send ok', FLoop.Send('time?', Events, Answer, Err));
    AssertTrue('call event',
      Log.Has('call:call_1:get_system_time:{}'));
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
      ToolArgsFrame(0, '{}'), FinishFrame('tool_calls'), DoneFrame]);
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
      ToolArgsFrame(0, '{}'), FinishFrame('tool_calls'), DoneFrame]);
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
      ToolArgsFrame(0, '{}'), FinishFrame('tool_calls'), DoneFrame]);
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

initialization
  RegisterTest(TAgentLoopTest);
end.
