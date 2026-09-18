unit test_llm;
{ fpcunit tests for hildegard.helper.llm, driven entirely by a fake transport
  that replays canned SSE chunks. No network access. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, ctypes, fpcunit, testregistry, fpjson, jsonparser,
  hildegard.helper.llm, llm_fakes;

type
  TTextCollector = class
  private
    FText: string;
    FSawText: Boolean;
    FChunkCount: Integer;
    FSawTextAfterFirstChunk: Boolean;
  public
    procedure OnText(const AText: string);
    procedure AfterChunk(Sender: TObject);
    property Text: string read FText;
    property SawText: Boolean read FSawText;
    property SawTextAfterFirstChunk: Boolean read FSawTextAfterFirstChunk;
  end;

  TLLMClientTest = class(TTestCase)
  private
    function MakeClient(out AFake: TFakeTransport;
      const AModel, AKey: string): TLLMClient;
    function UserRequest(const AText: string): TChatRequest;
  protected
    procedure TearDown; override;
  published
    procedure TestConfigResolutionPrefersExplicit;
    procedure TestConfigResolutionReadsEnvironment;
    procedure TestMissingApiKeyFailsBeforeRequest;
    procedure TestRequestSerializationIncludesModelMessagesAndTools;
    procedure TestRequestSerializationIncludesToolCallsAndToolResults;
    procedure TestParsesTextDeltasIncrementally;
    procedure TestEmitsTextBeforeStreamEnds;
    procedure TestHandlesFramesSplitAcrossChunks;
    procedure TestIgnoresCommentsAndBlankLines;
    procedure TestStopsOnDoneSentinel;
    procedure TestAccumulatesFragmentedToolCallArguments;
    procedure TestAccumulatesToolCallNameSplitAcrossFrames;
    procedure TestAccumulatesMultipleToolCalls;
    procedure TestMapsStopFinishReason;
    procedure TestMapsToolCallsFinishReason;
    procedure TestMapsUnknownFinishReason;
    procedure TestHttpErrorStatusMapsToError;
    procedure TestAuthStatusMapsToAuthError;
    procedure TestRateLimitMapsToRateLimitError;
    procedure TestProviderErrorObjectMapsToProviderError;
    procedure TestMalformedStreamMapsToMalformedError;
    procedure TestApiKeyNeverAppearsInError;
    procedure TestEmitsReasoningDeltasSeparately;
    procedure TestReasoningAccumulatedInResult;
    procedure TestReasoningNotInMessageContent;
    procedure TestReasoningContentPreferredOverReasoning;
    procedure TestV1CompleteOverloadStillWorks;
  end;

implementation

{$ifdef unix}
function c_setenv(name, value: PAnsiChar; overwrite: cint): cint; cdecl;
  external 'c' name 'setenv';
function c_unsetenv(name: PAnsiChar): cint; cdecl; external 'c' name 'unsetenv';
{$endif}

{ FPC has no cross-platform environment setter; tests set/clear via libc. }
procedure SetEnv(const AName, AValue: string);
begin
  {$ifdef unix}
  if AValue = '' then
    c_unsetenv(PAnsiChar(AnsiString(AName)))
  else
    c_setenv(PAnsiChar(AnsiString(AName)), PAnsiChar(AnsiString(AValue)), 1);
  {$endif}
end;

{ TTextCollector }

procedure TTextCollector.OnText(const AText: string);
begin
  FText := FText + AText;
  FSawText := True;
end;

procedure TTextCollector.AfterChunk(Sender: TObject);
begin
  Inc(FChunkCount);
  if FChunkCount = 1 then
    FSawTextAfterFirstChunk := FSawText;
end;

{ TLLMClientTest }

procedure TLLMClientTest.TearDown;
begin
  SetEnv('HILDEGARD_LLM_API_KEY', '');
  SetEnv('HILDEGARD_LLM_MODEL', '');
end;

function TLLMClientTest.MakeClient(out AFake: TFakeTransport;
  const AModel, AKey: string): TLLMClient;
var
  Cfg: TLLMConfig;
begin
  Cfg.Endpoint := 'https://example.test/v1/chat/completions';
  Cfg.Model := AModel;
  Cfg.ApiKey := AKey;
  Cfg.ConnectTimeoutMs := 1000;
  Cfg.ReadTimeoutMs := 5000;
  AFake := TFakeTransport.Create;
  Result := TLLMClient.Create(Cfg, AFake);
end;

function TLLMClientTest.UserRequest(const AText: string): TChatRequest;
var
  M: TChatMessage;
begin
  Result := Default(TChatRequest);
  Result.Messages := nil;
  M := Default(TChatMessage);
  M.Role := crUser;
  M.Content := AText;
  SetLength(Result.Messages, 1);
  Result.Messages[0] := M;
end;

procedure TLLMClientTest.TestConfigResolutionPrefersExplicit;
var
  Cfg, R: TLLMConfig;
begin
  Cfg.Endpoint := 'https://explicit';
  Cfg.Model := 'explicit-model';
  Cfg.ApiKey := 'explicit-key';
  Cfg.ConnectTimeoutMs := 0;
  Cfg.ReadTimeoutMs := 0;
  R := ResolveLLMConfig(Cfg);
  AssertEquals('endpoint', 'https://explicit', R.Endpoint);
  AssertEquals('model', 'explicit-model', R.Model);
  AssertEquals('key', 'explicit-key', R.ApiKey);
  AssertTrue('connect default', R.ConnectTimeoutMs > 0);
  AssertTrue('read default', R.ReadTimeoutMs > 0);
end;

procedure TLLMClientTest.TestConfigResolutionReadsEnvironment;
var
  Cfg, R: TLLMConfig;
begin
  SetEnv('HILDEGARD_LLM_MODEL', 'env-model');
  SetEnv('HILDEGARD_LLM_API_KEY', 'env-key');
  Cfg := Default(TLLMConfig);
  R := ResolveLLMConfig(Cfg);
  AssertEquals('model from env', 'env-model', R.Model);
  AssertEquals('key from env', 'env-key', R.ApiKey);
  AssertEquals('default endpoint', DefaultLLMEndpoint, R.Endpoint);
end;

procedure TLLMClientTest.TestMissingApiKeyFailsBeforeRequest;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  SetEnv('HILDEGARD_LLM_API_KEY', '');
  SetEnv('FIREWORKS_API_KEY', '');
  Client := MakeClient(Fake, 'a-model', '');
  try
    AssertFalse('fails', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('config error', Ord(leConfig), Ord(Err.Code));
    AssertTrue('no request sent', Fake.LastBody = '');
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestRequestSerializationIncludesModelMessagesAndTools;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Req: TChatRequest;
  Res: TChatResult;
  Err: TLLMError;
  Root: TJSONObject;
  Tools: TJSONArray;
  Spec: TToolSpec;
begin
  Client := MakeClient(Fake, 'my-model', 'key');
  try
    Req := UserRequest('hello');
    Spec.Name := 'get_system_time';
    Spec.Description := 'returns the time';
    Spec.ParametersJson := '{"type":"object","properties":{}}';
    SetLength(Req.Tools, 1);
    Req.Tools[0] := Spec;
    Fake.AddChunk(FinishFrame('stop'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('complete', Client.Complete(Req, nil, Res, Err));
    AssertEquals('endpoint used', 'https://example.test/v1/chat/completions',
      Fake.LastURL);

    Root := TJSONObject(GetJSON(Fake.LastBody));
    try
      AssertEquals('model', 'my-model', Root.Get('model', ''));
      AssertTrue('stream', Root.Get('stream', False));
      AssertEquals('one message',
        1, TJSONArray(Root.Find('messages')).Count);
      Tools := TJSONArray(Root.Find('tools'));
      AssertEquals('one tool', 1, Tools.Count);
      AssertEquals('tool name', 'get_system_time',
        TJSONObject(TJSONObject(Tools.Items[0]).Find('function')).Get('name', ''));
    finally
      Root.Free;
    end;
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestRequestSerializationIncludesToolCallsAndToolResults;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Req: TChatRequest;
  Res: TChatResult;
  Err: TLLMError;
  Root: TJSONObject;
  Msgs: TJSONArray;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Req := Default(TChatRequest);
    SetLength(Req.Messages, 2);
    Req.Messages[0].Role := crAssistant;
    SetLength(Req.Messages[0].ToolCalls, 1);
    Req.Messages[0].ToolCalls[0].Id := 'call_1';
    Req.Messages[0].ToolCalls[0].Name := 'get_system_time';
    Req.Messages[0].ToolCalls[0].Arguments := '{}';
    Req.Messages[1].Role := crTool;
    Req.Messages[1].ToolCallId := 'call_1';
    Req.Messages[1].Content := '2026-01-01T00:00:00Z';
    Fake.AddChunk(FinishFrame('stop'));
    AssertTrue('complete', Client.Complete(Req, nil, Res, Err));

    Root := TJSONObject(GetJSON(Fake.LastBody));
    try
      Msgs := TJSONArray(Root.Find('messages'));
      AssertEquals('assistant tool_calls present', 1,
        TJSONArray(TJSONObject(Msgs.Items[0]).Find('tool_calls')).Count);
      AssertEquals('tool_call_id present', 'call_1',
        TJSONObject(Msgs.Items[1]).Get('tool_call_id', ''));
    finally
      Root.Free;
    end;
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestParsesTextDeltasIncrementally;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
  C: TTextCollector;
begin
  Client := MakeClient(Fake, 'm', 'k');
  C := TTextCollector.Create;
  try
    Fake.AddChunk(TextDelta('Hello'));
    Fake.AddChunk(TextDelta(', '));
    Fake.AddChunk(TextDelta('world'));
    Fake.AddChunk(FinishFrame('stop'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('complete', Client.Complete(UserRequest('hi'), C.OnText, Res, Err));
    AssertEquals('all deltas', 'Hello, world', C.Text);
    AssertEquals('content in result', 'Hello, world', Res.Message.Content);
    AssertEquals('finish stop', Ord(frStop), Ord(Res.FinishReason));
  finally
    C.Free;
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestEmitsTextBeforeStreamEnds;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
  C: TTextCollector;
begin
  Client := MakeClient(Fake, 'm', 'k');
  C := TTextCollector.Create;
  try
    Fake.AddChunk(TextDelta('first'));
    Fake.AddChunk(FinishFrame('stop'));
    Fake.AddChunk(DoneFrame);
    Fake.AfterChunk := C.AfterChunk;
    AssertTrue('complete', Client.Complete(UserRequest('hi'), C.OnText, Res, Err));
    AssertTrue('text emitted after the first chunk', C.SawTextAfterFirstChunk);
  finally
    C.Free;
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestHandlesFramesSplitAcrossChunks;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
  C: TTextCollector;
  Frame: RawByteString;
begin
  Client := MakeClient(Fake, 'm', 'k');
  C := TTextCollector.Create;
  try
    Frame := TextDelta('split me');
    Fake.AddChunk(Copy(Frame, 1, 12));
    Fake.AddChunk(Copy(Frame, 13, MaxInt));
    Fake.AddChunk(FinishFrame('stop'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('complete', Client.Complete(UserRequest('hi'), C.OnText, Res, Err));
    AssertEquals('reassembled', 'split me', C.Text);
  finally
    C.Free;
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestIgnoresCommentsAndBlankLines;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
  C: TTextCollector;
begin
  Client := MakeClient(Fake, 'm', 'k');
  C := TTextCollector.Create;
  try
    Fake.AddChunk(': keep-alive' + SSEBlank);
    Fake.AddChunk(TextDelta('ok'));
    Fake.AddChunk(FinishFrame('stop'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('complete', Client.Complete(UserRequest('hi'), C.OnText, Res, Err));
    AssertEquals('text only', 'ok', C.Text);
  finally
    C.Free;
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestStopsOnDoneSentinel;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
  C: TTextCollector;
begin
  Client := MakeClient(Fake, 'm', 'k');
  C := TTextCollector.Create;
  try
    Fake.AddChunk(TextDelta('before'));
    Fake.AddChunk(DoneFrame);
    Fake.AddChunk(TextDelta('after'));
    AssertTrue('complete', Client.Complete(UserRequest('hi'), C.OnText, Res, Err));
    AssertEquals('text after DONE ignored', 'before', C.Text);
  finally
    C.Free;
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestAccumulatesFragmentedToolCallArguments;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.AddChunk(ToolNameFrame(0, 'call_1', 'get_system_time'));
    Fake.AddChunk(ToolArgsFrame(0, '{"tz":'));
    Fake.AddChunk(ToolArgsFrame(0, '"utc"}'));
    Fake.AddChunk(FinishFrame('tool_calls'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('complete', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('one call', 1, Length(Res.Message.ToolCalls));
    AssertEquals('id', 'call_1', Res.Message.ToolCalls[0].Id);
    AssertEquals('name', 'get_system_time', Res.Message.ToolCalls[0].Name);
    AssertEquals('args', '{"tz":"utc"}', Res.Message.ToolCalls[0].Arguments);
    AssertEquals('finish tool_calls', Ord(frToolCalls), Ord(Res.FinishReason));
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestAccumulatesToolCallNameSplitAcrossFrames;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    { Two frames each carry a tool_calls entry with the same index; the name is
      built by concatenation. A realistic provider sends the full name once, but
      the accumulator must not lose a split name either way. }
    Fake.AddChunk(ToolNameFrame(0, 'call_1', 'get_'));
    Fake.AddChunk(ToolNameFrame(0, '', 'system_time'));
    Fake.AddChunk(FinishFrame('tool_calls'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('complete', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('name joined', 'get_system_time', Res.Message.ToolCalls[0].Name);
    AssertEquals('id kept', 'call_1', Res.Message.ToolCalls[0].Id);
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestAccumulatesMultipleToolCalls;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.AddChunk(ToolNameFrame(0, 'a', 'tool_a'));
    Fake.AddChunk(ToolNameFrame(1, 'b', 'tool_b'));
    Fake.AddChunk(ToolArgsFrame(0, '{"x":1}'));
    Fake.AddChunk(ToolArgsFrame(1, '{"y":2}'));
    Fake.AddChunk(FinishFrame('tool_calls'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('complete', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('two calls', 2, Length(Res.Message.ToolCalls));
    AssertEquals('first name', 'tool_a', Res.Message.ToolCalls[0].Name);
    AssertEquals('first args', '{"x":1}', Res.Message.ToolCalls[0].Arguments);
    AssertEquals('second name', 'tool_b', Res.Message.ToolCalls[1].Name);
    AssertEquals('second args', '{"y":2}', Res.Message.ToolCalls[1].Arguments);
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestMapsStopFinishReason;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.AddChunk(FinishFrame('stop'));
    AssertTrue('complete', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('stop', Ord(frStop), Ord(Res.FinishReason));
    AssertEquals('raw', 'stop', Res.RawFinishReason);
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestMapsToolCallsFinishReason;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.AddChunk(FinishFrame('tool_calls'));
    AssertTrue('complete', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('tool_calls', Ord(frToolCalls), Ord(Res.FinishReason));
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestMapsUnknownFinishReason;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.AddChunk(FinishFrame('something_new'));
    AssertTrue('complete', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('unknown', Ord(frUnknown), Ord(Res.FinishReason));
    AssertEquals('raw preserved', 'something_new', Res.RawFinishReason);
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestHttpErrorStatusMapsToError;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.StatusCode := 500;
    AssertFalse('fails', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('http status', Ord(leHttpStatus), Ord(Err.Code));
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestAuthStatusMapsToAuthError;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.StatusCode := 401;
    AssertFalse('fails', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('auth', Ord(leAuth), Ord(Err.Code));
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestRateLimitMapsToRateLimitError;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.StatusCode := 429;
    AssertFalse('fails', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('rate limit', Ord(leRateLimit), Ord(Err.Code));
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestProviderErrorObjectMapsToProviderError;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.AddChunk(ProviderErrorFrame('model overloaded'));
    AssertFalse('fails', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('provider', Ord(leProvider), Ord(Err.Code));
    AssertTrue('detail has message', Pos('overloaded', Err.Detail) > 0);
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestMalformedStreamMapsToMalformedError;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.AddChunk(SSE('{not valid json'));
    AssertFalse('fails', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('malformed', Ord(leMalformedStream), Ord(Err.Code));
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestApiKeyNeverAppearsInError;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'super-secret-key');
  try
    Fake.StatusCode := 401;
    AssertFalse('fails', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertTrue('message clean', Pos('super-secret-key', Err.Message) = 0);
    AssertTrue('detail clean', Pos('super-secret-key', Err.Detail) = 0);
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestEmitsReasoningDeltasSeparately;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
  TextCol, ReasonCol: TTextCollector;
begin
  Client := MakeClient(Fake, 'm', 'k');
  TextCol := TTextCollector.Create;
  ReasonCol := TTextCollector.Create;
  try
    Fake.AddChunk(ReasoningDelta('think '));
    Fake.AddChunk(ReasoningDelta('more'));
    Fake.AddChunk(TextDelta('answer'));
    Fake.AddChunk(FinishFrame('stop'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('complete', Client.Complete(UserRequest('hi'), TextCol.OnText,
      ReasonCol.OnText, Res, Err));
    AssertEquals('reasoning streamed', 'think more', ReasonCol.Text);
    AssertEquals('answer streamed', 'answer', TextCol.Text);
  finally
    ReasonCol.Free;
    TextCol.Free;
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestReasoningAccumulatedInResult;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.AddChunk(ReasoningDelta('first '));
    Fake.AddChunk(ReasoningDelta('second'));
    Fake.AddChunk(TextDelta('done'));
    Fake.AddChunk(FinishFrame('stop'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('complete', Client.Complete(UserRequest('hi'), nil, nil, Res, Err));
    AssertEquals('reasoning accumulated', 'first second', Res.ReasoningContent);
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestReasoningNotInMessageContent;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.AddChunk(ReasoningDelta('secret thinking'));
    Fake.AddChunk(TextDelta('visible'));
    Fake.AddChunk(FinishFrame('stop'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('complete', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('content is answer only', 'visible', Res.Message.Content);
    AssertTrue('reasoning not in content',
      Pos('secret thinking', Res.Message.Content) = 0);
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestReasoningContentPreferredOverReasoning;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
begin
  Client := MakeClient(Fake, 'm', 'k');
  try
    Fake.AddChunk(SSE('{"choices":[{"delta":{' +
      '"reasoning_content":"primary","reasoning":"secondary"}}]}'));
    Fake.AddChunk(FinishFrame('stop'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('complete', Client.Complete(UserRequest('hi'), nil, Res, Err));
    AssertEquals('prefers reasoning_content', 'primary', Res.ReasoningContent);
  finally
    Client.Free;
    Fake.Free;
  end;
end;

procedure TLLMClientTest.TestV1CompleteOverloadStillWorks;
var
  Fake: TFakeTransport;
  Client: TLLMClient;
  Res: TChatResult;
  Err: TLLMError;
  C: TTextCollector;
begin
  Client := MakeClient(Fake, 'm', 'k');
  C := TTextCollector.Create;
  try
    Fake.AddChunk(TextDelta('ok'));
    Fake.AddChunk(FinishFrame('stop'));
    Fake.AddChunk(DoneFrame);
    AssertTrue('v1 overload', Client.Complete(UserRequest('hi'), C.OnText,
      Res, Err));
    AssertEquals('answer', 'ok', Res.Message.Content);
  finally
    C.Free;
    Client.Free;
    Fake.Free;
  end;
end;

initialization
  RegisterTest(TLLMClientTest);
end.