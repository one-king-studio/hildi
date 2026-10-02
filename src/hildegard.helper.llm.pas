unit hildegard.helper.llm;
{ OpenAI-compatible chat client with SSE streaming. Builds a chat-completions
  request, streams the response through an injectable transport, surfaces text
  deltas, accumulates tool-call deltas by index, and maps the finish reason and
  provider errors. The only unit that knows about HTTP, TLS, SSE, and the
  provider JSON shape. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils;

type
  TChatRole = (crSystem, crUser, crAssistant, crTool);

  TChatToolCall = record
    Id: string;
    Name: string;
    Arguments: string;
  end;

  TChatMessage = record
    Role: TChatRole;
    Content: string;
    ToolCallId: string;
    ToolCalls: array of TChatToolCall;
    { crTool-only display/audit metadata; never sent to the provider. }
    ToolName: string;       // the tool a tool result came from
    ToolOk: Boolean;        // whether it succeeded
    DurationMs: Int64;      // tool execution time
  end;

  TChatMessageArray = array of TChatMessage;
  TChatToolCallArray = array of TChatToolCall;

  TToolSpec = record
    Name: string;
    Description: string;
    ParametersJson: string;
  end;

  TToolSpecArray = array of TToolSpec;

  TFinishReason = (frStop, frToolCalls, frLength, frContentFilter, frUnknown);

  { Normalised token accounting: one shape across the provider spellings
    (OpenAI/Fireworks, DeepSeek, Anthropic-style gateways). Absent usage is all
    zeros. }
  TTokenUsage = record
    PromptTokens: Integer;       // prompt_tokens | input_tokens
    CompletionTokens: Integer;   // completion_tokens | output_tokens
    TotalTokens: Integer;        // total_tokens, else prompt + completion
    CachedTokens: Integer;       // prompt_tokens_details.cached_tokens
                                 //   | prompt_cache_hit_tokens
                                 //   | cache_read_input_tokens
    ReasoningTokens: Integer;    // completion_tokens_details.reasoning_tokens
                                 //   | reasoning_tokens
  end;

  TChatRequest = record
    Messages: TChatMessageArray;
    Tools: TToolSpecArray;
  end;

  TChatResult = record
    Message: TChatMessage;
    FinishReason: TFinishReason;
    RawFinishReason: string;
    ReasoningContent: string;   // display-only; not part of the message
    Usage: TTokenUsage;         // provider usage; zeros when absent
    FirstTokenMs: Int64;        // time to the first content/reasoning delta
  end;

  TLLMErrorCode = (
    leOk, leConfig, leNetwork, leHttpStatus, leAuth, leRateLimit,
    leMalformedStream, leProvider, leCancelled
  );

  TLLMError = record
    Code: TLLMErrorCode;
    Message: string;
    Detail: string;
  end;

  TLLMTextEvent = procedure(const AText: string) of object;
  TLLMReasoningEvent = procedure(const AText: string) of object;
  TLLMChunkEvent = procedure(const AData: RawByteString) of object;

  TLLMConfig = record
    Endpoint: string;
    Model: string;
    ApiKey: string;
    ConnectTimeoutMs: Integer;
    ReadTimeoutMs: Integer;
  end;

  TLLMTransport = class
  public
    { Returns True when an HTTP response was received (even non-2xx). False on a
      transport/network failure with AStatusCode = 0. On non-2xx, AError carries
      the response body for error mapping; on 2xx it is ''. }
    function PostStream(const AURL: string; const ABody: string;
      const AHeaders: TStringList; AOnChunk: TLLMChunkEvent;
      out AStatusCode: Integer; out AError: string): Boolean; virtual; abstract;
  end;

  TFPHTTPTransport = class(TLLMTransport)
  public
    function PostStream(const AURL: string; const ABody: string;
      const AHeaders: TStringList; AOnChunk: TLLMChunkEvent;
      out AStatusCode: Integer; out AError: string): Boolean; override;
  end;

  TLLMClient = class
  private
    FConfig: TLLMConfig;
    FTransport: TLLMTransport;
    FOwnsTransport: Boolean;
    function Endpoint: string;
    function GetModel: string;
  public
    constructor Create(const AConfig: TLLMConfig; ATransport: TLLMTransport);
    destructor Destroy; override;
    function Complete(const ARequest: TChatRequest; AOnText: TLLMTextEvent;
      out AResult: TChatResult; out AError: TLLMError): Boolean; overload;
    function Complete(const ARequest: TChatRequest; AOnText: TLLMTextEvent;
      AOnReasoning: TLLMReasoningEvent;
      out AResult: TChatResult; out AError: TLLMError): Boolean; overload;
    { The resolved model name, for recording on a request. }
    property Model: string read GetModel;
  end;

function ResolveLLMConfig(const AConfig: TLLMConfig): TLLMConfig;
function RoleToString(ARole: TChatRole): string;

const
  DefaultLLMEndpoint = 'https://api.fireworks.ai/inference/v1/chat/completions';
  DefaultConnectTimeoutMs = 10000;
  DefaultReadTimeoutMs = 120000;

implementation

uses
  fpjson, jsonparser, fphttpclient, opensslsockets;

type
  { Forwards each response-body chunk to a callback while capturing a bounded
    prefix, so non-2xx bodies can be reported. }
  TChunkProxyStream = class(TStream)
  private
    FOnChunk: TLLMChunkEvent;
    FCapture: RawByteString;
  public
    constructor Create(AOnChunk: TLLMChunkEvent);
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property Capture: RawByteString read FCapture;
  end;

  { Incremental SSE reader. Feed it raw bytes; it buffers partial lines, ignores
    comments/blank lines, joins data: lines per the SSE spec, and dispatches on
    a blank line (and at stream end). }
  TSSEParser = class
  private
    FBuffer: RawByteString;
    FPending: RawByteString;
    FHasData: Boolean;
    FOnText: TLLMTextEvent;
    FOnReasoning: TLLMReasoningEvent;
    FResult: TChatResult;
    FHasFinish: Boolean;
    FDone: Boolean;
    FMalformed: Boolean;
    FProviderError: string;
    FStartMs: QWord;
    FMarked: Boolean;
    procedure ProcessLine(const ALine: string);
    procedure FlushEvent;
    procedure HandleData(const AData: RawByteString);
    procedure HandleJson(const AJson: TJSONObject);
    procedure AccumulateToolCalls(const ADelta: TJSONObject);
    procedure ReadUsage(const AUsage: TJSONObject);
    procedure MarkFirstToken;
    procedure SetFinish(const AReason: string);
  public
    constructor Create(AOnText: TLLMTextEvent;
      AOnReasoning: TLLMReasoningEvent);
    procedure Feed(const AData: RawByteString);
    procedure Finish;
    property Result: TChatResult read FResult;
    property Done: Boolean read FDone;
    property Malformed: Boolean read FMalformed;
    property ProviderError: string read FProviderError;
  end;

function ErrLLM(ACode: TLLMErrorCode; const AMessage, ADetail: string): TLLMError;
begin
  Result.Code := ACode;
  Result.Message := AMessage;
  Result.Detail := ADetail;
end;

function OkLLM: TLLMError;
begin
  Result := ErrLLM(leOk, '', '');
end;

{ --- config ------------------------------------------------------------- }

function ResolveLLMConfig(const AConfig: TLLMConfig): TLLMConfig;
var
  V: string;
begin
  Result := AConfig;
  if Result.Endpoint = '' then
    Result.Endpoint := DefaultLLMEndpoint;
  if Result.Model = '' then
  begin
    V := GetEnvironmentVariable('HILDEGARD_LLM_MODEL');
    if V = '' then
      V := GetEnvironmentVariable('FIREWORKS_MODEL');
    Result.Model := V;
  end;
  if Result.ApiKey = '' then
  begin
    V := GetEnvironmentVariable('HILDEGARD_LLM_API_KEY');
    if V = '' then
      V := GetEnvironmentVariable('FIREWORKS_API_KEY');
    Result.ApiKey := V;
  end;
  if Result.ConnectTimeoutMs <= 0 then
    Result.ConnectTimeoutMs := DefaultConnectTimeoutMs;
  if Result.ReadTimeoutMs <= 0 then
    Result.ReadTimeoutMs := DefaultReadTimeoutMs;
end;

function RoleToString(ARole: TChatRole): string;
begin
  case ARole of
    crSystem: Result := 'system';
    crUser: Result := 'user';
    crAssistant: Result := 'assistant';
    crTool: Result := 'tool';
  end;
end;

{ --- TChunkProxyStream -------------------------------------------------- }

constructor TChunkProxyStream.Create(AOnChunk: TLLMChunkEvent);
begin
  inherited Create;
  FOnChunk := AOnChunk;
  FCapture := '';
end;

function TChunkProxyStream.Write(const Buffer; Count: LongInt): LongInt;
var
  S: RawByteString;
begin
  if Count <= 0 then
    Exit(0);
  SetString(S, PAnsiChar(@Buffer), Count);
  if Assigned(FOnChunk) then
    FOnChunk(S);
  if Length(FCapture) < 8192 then
    FCapture := FCapture + Copy(S, 1, 8192 - Length(FCapture));
  Result := Count;
end;

function TChunkProxyStream.Read(var Buffer; Count: LongInt): LongInt;
begin
  Result := 0;
end;

function TChunkProxyStream.Seek(const Offset: Int64;
  Origin: TSeekOrigin): Int64;
begin
  Result := 0;
end;

{ --- TFPHTTPTransport --------------------------------------------------- }

function TFPHTTPTransport.PostStream(const AURL: string; const ABody: string;
  const AHeaders: TStringList; AOnChunk: TLLMChunkEvent;
  out AStatusCode: Integer; out AError: string): Boolean;
var
  Client: TFPHTTPClient;
  Body: TStringStream;
  Proxy: TChunkProxyStream;
  I: Integer;
begin
  Result := False;
  AStatusCode := 0;
  AError := '';
  Client := TFPHTTPClient.Create(nil);
  Body := TStringStream.Create(ABody);
  Proxy := TChunkProxyStream.Create(AOnChunk);
  try
    Client.ConnectTimeout := DefaultConnectTimeoutMs;
    Client.IOTimeout := DefaultReadTimeoutMs;
    if AHeaders <> nil then
      for I := 0 to AHeaders.Count - 1 do
        Client.AddHeader(AHeaders.Names[I], AHeaders.ValueFromIndex[I]);
    try
      Client.RequestBody := Body;
      Client.Post(AURL, Proxy);
      AStatusCode := Client.ResponseStatusCode;
      if (AStatusCode < 200) or (AStatusCode >= 300) then
        AError := Proxy.Capture;
      Result := True;
    except
      on E: Exception do
      begin
        AError := E.Message;
        Result := False;
      end;
    end;
  finally
    Proxy.Free;
    Body.Free;
    Client.Free;
  end;
end;

{ --- TSSEParser --------------------------------------------------------- }

constructor TSSEParser.Create(AOnText: TLLMTextEvent;
  AOnReasoning: TLLMReasoningEvent);
begin
  inherited Create;
  FOnText := AOnText;
  FOnReasoning := AOnReasoning;
  FBuffer := '';
  FPending := '';
  FHasData := False;
  FHasFinish := False;
  FDone := False;
  FMalformed := False;
  FProviderError := '';
  FStartMs := GetTickCount64;
  FMarked := False;
  FResult := Default(TChatResult);
  FResult.Message.Role := crAssistant;
end;

procedure TSSEParser.Feed(const AData: RawByteString);
var
  P: Integer;
  Line: RawByteString;
begin
  FBuffer := FBuffer + AData;
  repeat
    P := Pos(#10, FBuffer);
    if P = 0 then
      Break;
    Line := Copy(FBuffer, 1, P - 1);
    Delete(FBuffer, 1, P);
    if (Length(Line) > 0) and (Line[Length(Line)] = #13) then
      Delete(Line, Length(Line), 1);
    ProcessLine(Line);
  until FDone;
end;

procedure TSSEParser.ProcessLine(const ALine: string);
var
  S: string;
begin
  if FDone then
    Exit;
  if ALine = '' then
  begin
    FlushEvent;
    Exit;
  end;
  if ALine[1] = ':' then
    Exit;                       // comment / heartbeat
  if Copy(ALine, 1, 5) = 'data:' then
  begin
    S := Copy(ALine, 6, MaxInt);
    if (S <> '') and (S[1] = ' ') then
      Delete(S, 1, 1);
    if FHasData then
      FPending := FPending + #10 + S
    else
    begin
      FPending := S;
      FHasData := True;
    end;
    Exit;
  end;
  // event:, id:, retry: and anything else are ignored.
end;

procedure TSSEParser.FlushEvent;
begin
  if not FHasData then
    Exit;
  HandleData(FPending);
  FPending := '';
  FHasData := False;
end;

procedure TSSEParser.HandleData(const AData: RawByteString);
begin
  if AData = '[DONE]' then
  begin
    FDone := True;
    Exit;
  end;
  if AData = '' then
    Exit;
  try
    HandleJson(TJSONObject(GetJSON(AData)));
  except
    on E: Exception do
    begin
      FMalformed := True;
      FDone := True;
    end;
  end;
end;

procedure TSSEParser.HandleJson(const AJson: TJSONObject);
var
  Err: TJSONData;
  Choices: TJSONData;
  Choice: TJSONObject;
  Delta: TJSONObject;
  Content: TJSONData;
  Reasoning: TJSONData;
  Finish: TJSONData;
  Usage: TJSONData;
begin
  if AJson = nil then
    Exit;
  try
    Err := AJson.Find('error');
    if Err <> nil then
    begin
      if Err is TJSONObject then
        FProviderError := TJSONObject(Err).AsJSON
      else
        FProviderError := Err.AsString;
      FDone := True;
      Exit;
    end;

    { Usage arrives on a chunk with no choices (OpenAI's include_usage) or on
      the final chunk (DeepSeek), so read it before the choices guard. }
    Usage := AJson.Find('usage');
    if Usage is TJSONObject then
      ReadUsage(TJSONObject(Usage));

    Choices := AJson.Find('choices');
    if (Choices = nil) or not (Choices is TJSONArray) then
      Exit;
    if TJSONArray(Choices).Count = 0 then
      Exit;
    Choice := TJSONObject(TJSONArray(Choices).Items[0]);

    Delta := TJSONObject(Choice.Find('delta'));
    if Delta <> nil then
    begin
      Content := Delta.Find('content');
      if (Content <> nil) and (Content.JSONType = jtString) and
        (Content.AsString <> '') then
      begin
        MarkFirstToken;
        FResult.Message.Content := FResult.Message.Content + Content.AsString;
        if Assigned(FOnText) then
          FOnText(Content.AsString);
      end;

      Reasoning := Delta.Find('reasoning_content');
      if (Reasoning = nil) or (Reasoning.JSONType <> jtString) then
        Reasoning := Delta.Find('reasoning');
      if (Reasoning <> nil) and (Reasoning.JSONType = jtString) and
        (Reasoning.AsString <> '') then
      begin
        MarkFirstToken;
        FResult.ReasoningContent :=
          FResult.ReasoningContent + Reasoning.AsString;
        if Assigned(FOnReasoning) then
          FOnReasoning(Reasoning.AsString);
      end;

      AccumulateToolCalls(Delta);
    end;

    Finish := Choice.Find('finish_reason');
    if (Finish <> nil) and (Finish.JSONType = jtString) then
      SetFinish(Finish.AsString);
  finally
    AJson.Free;
  end;
end;

procedure TSSEParser.AccumulateToolCalls(const ADelta: TJSONObject);
var
  Tcs: TJSONData;
  I, Idx: Integer;
  Item, Fn: TJSONObject;
  Id, Name, Args: TJSONData;
begin
  Tcs := ADelta.Find('tool_calls');
  if (Tcs = nil) or not (Tcs is TJSONArray) then
    Exit;
  for I := 0 to TJSONArray(Tcs).Count - 1 do
  begin
    Item := TJSONObject(TJSONArray(Tcs).Items[I]);
    Idx := Item.Get('index', 0);
    if Idx < 0 then
      Continue;
    while Length(FResult.Message.ToolCalls) <= Idx do
      SetLength(FResult.Message.ToolCalls,
        Length(FResult.Message.ToolCalls) + 1);

    Id := Item.Find('id');
    if (Id <> nil) and (Id.JSONType = jtString) and (Id.AsString <> '') then
      FResult.Message.ToolCalls[Idx].Id := Id.AsString;

    Fn := TJSONObject(Item.Find('function'));
    if Fn <> nil then
    begin
      Name := Fn.Find('name');
      if (Name <> nil) and (Name.JSONType = jtString) then
        FResult.Message.ToolCalls[Idx].Name :=
          FResult.Message.ToolCalls[Idx].Name + Name.AsString;
      Args := Fn.Find('arguments');
      if (Args <> nil) and (Args.JSONType = jtString) then
        FResult.Message.ToolCalls[Idx].Arguments :=
          FResult.Message.ToolCalls[Idx].Arguments + Args.AsString;
    end;
  end;
end;

procedure TSSEParser.ReadUsage(const AUsage: TJSONObject);
var
  V: TJSONData;
  Details: TJSONObject;
begin
  V := AUsage.Find('prompt_tokens');
  if V = nil then
    V := AUsage.Find('input_tokens');
  if (V <> nil) and (V.JSONType = jtNumber) then
    FResult.Usage.PromptTokens := V.AsInteger;

  V := AUsage.Find('completion_tokens');
  if V = nil then
    V := AUsage.Find('output_tokens');
  if (V <> nil) and (V.JSONType = jtNumber) then
    FResult.Usage.CompletionTokens := V.AsInteger;

  V := AUsage.Find('total_tokens');
  if (V <> nil) and (V.JSONType = jtNumber) then
    FResult.Usage.TotalTokens := V.AsInteger
  else
    FResult.Usage.TotalTokens := FResult.Usage.PromptTokens +
      FResult.Usage.CompletionTokens;

  V := nil;
  Details := nil;
  if AUsage.Find('prompt_tokens_details') is TJSONObject then
    Details := TJSONObject(AUsage.Find('prompt_tokens_details'));
  if Details <> nil then
    V := Details.Find('cached_tokens');
  if V = nil then
    V := AUsage.Find('prompt_cache_hit_tokens');
  if V = nil then
    V := AUsage.Find('cache_read_input_tokens');
  if (V <> nil) and (V.JSONType = jtNumber) then
    FResult.Usage.CachedTokens := V.AsInteger;

  V := nil;
  Details := nil;
  if AUsage.Find('completion_tokens_details') is TJSONObject then
    Details := TJSONObject(AUsage.Find('completion_tokens_details'));
  if Details <> nil then
    V := Details.Find('reasoning_tokens');
  if V = nil then
    V := AUsage.Find('reasoning_tokens');
  if (V <> nil) and (V.JSONType = jtNumber) then
    FResult.Usage.ReasoningTokens := V.AsInteger;
end;

procedure TSSEParser.MarkFirstToken;
begin
  if FMarked then
    Exit;
  FMarked := True;
  FResult.FirstTokenMs := Int64(GetTickCount64 - FStartMs);
end;

procedure TSSEParser.SetFinish(const AReason: string);
begin
  FResult.RawFinishReason := AReason;
  FHasFinish := True;
  if AReason = 'stop' then
    FResult.FinishReason := frStop
  else if AReason = 'tool_calls' then
    FResult.FinishReason := frToolCalls
  else if AReason = 'length' then
    FResult.FinishReason := frLength
  else if AReason = 'content_filter' then
    FResult.FinishReason := frContentFilter
  else
    FResult.FinishReason := frUnknown;
end;

procedure TSSEParser.Finish;
begin
  FlushEvent;
  if not FHasFinish then
    FResult.FinishReason := frUnknown;
end;

{ --- request serialization --------------------------------------------- }

function BuildRequestBody(const AConfig: TLLMConfig;
  const ARequest: TChatRequest): string;
var
  Root: TJSONObject;
  Msgs: TJSONArray;
  Tools: TJSONArray;
  MObj, TObj, FnObj, Opts: TJSONObject;
  CallObj: TJSONArray;
  I, J: Integer;
  Params: TJSONData;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('model', AConfig.Model);
    Root.Add('stream', True);
    { Ask the provider to send a final usage chunk; providers that ignore it
      simply leave the usage zeros. }
    Opts := TJSONObject.Create;
    Opts.Add('include_usage', True);
    Root.Add('stream_options', Opts);

    Msgs := TJSONArray.Create;
    for I := 0 to High(ARequest.Messages) do
    begin
      MObj := TJSONObject.Create;
      MObj.Add('role', RoleToString(ARequest.Messages[I].Role));
      if ARequest.Messages[I].Role = crTool then
        MObj.Add('tool_call_id', ARequest.Messages[I].ToolCallId);
      MObj.Add('content', ARequest.Messages[I].Content);
      if (ARequest.Messages[I].Role = crAssistant) and
        (Length(ARequest.Messages[I].ToolCalls) > 0) then
      begin
        CallObj := TJSONArray.Create;
        for J := 0 to High(ARequest.Messages[I].ToolCalls) do
        begin
          FnObj := TJSONObject.Create;
          FnObj.Add('name', ARequest.Messages[I].ToolCalls[J].Name);
          FnObj.Add('arguments', ARequest.Messages[I].ToolCalls[J].Arguments);
          TObj := TJSONObject.Create;
          TObj.Add('id', ARequest.Messages[I].ToolCalls[J].Id);
          TObj.Add('type', 'function');
          TObj.Add('function', FnObj);
          CallObj.Add(TObj);
        end;
        MObj.Add('tool_calls', CallObj);
      end;
      Msgs.Add(MObj);
    end;
    Root.Add('messages', Msgs);

    if Length(ARequest.Tools) > 0 then
    begin
      Tools := TJSONArray.Create;
      for I := 0 to High(ARequest.Tools) do
      begin
        TObj := TJSONObject.Create;
        FnObj := TJSONObject.Create;
        FnObj.Add('name', ARequest.Tools[I].Name);
        FnObj.Add('description', ARequest.Tools[I].Description);
        Params := GetJSON(ARequest.Tools[I].ParametersJson);
        FnObj.Add('parameters', Params);
        TObj.Add('type', 'function');
        TObj.Add('function', FnObj);
        Tools.Add(TObj);
      end;
      Root.Add('tools', Tools);
    end;

    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

{ --- TLLMClient --------------------------------------------------------- }

constructor TLLMClient.Create(const AConfig: TLLMConfig;
  ATransport: TLLMTransport);
begin
  inherited Create;
  FConfig := ResolveLLMConfig(AConfig);
  if ATransport = nil then
  begin
    FTransport := TFPHTTPTransport.Create;
    FOwnsTransport := True;
  end
  else
  begin
    FTransport := ATransport;
    FOwnsTransport := False;
  end;
end;

destructor TLLMClient.Destroy;
begin
  if FOwnsTransport then
    FTransport.Free;
  inherited Destroy;
end;

function TLLMClient.Endpoint: string;
begin
  Result := FConfig.Endpoint;
end;

function TLLMClient.GetModel: string;
begin
  Result := FConfig.Model;
end;

function TLLMClient.Complete(const ARequest: TChatRequest;
  AOnText: TLLMTextEvent; out AResult: TChatResult;
  out AError: TLLMError): Boolean;
begin
  Result := Complete(ARequest, AOnText, nil, AResult, AError);
end;

function TLLMClient.Complete(const ARequest: TChatRequest;
  AOnText: TLLMTextEvent; AOnReasoning: TLLMReasoningEvent;
  out AResult: TChatResult; out AError: TLLMError): Boolean;
var
  Body: string;
  Headers: TStringList;
  Parser: TSSEParser;
  Status: Integer;
  TransportError: string;
  SinkOk: Boolean;
begin
  AResult := Default(TChatResult);
  AError := OkLLM;
  if Length(ARequest.Messages) = 0 then
  begin
    AError := ErrLLM(leConfig, 'no messages to send', '');
    Exit(False);
  end;
  if (FConfig.Model = '') or (FConfig.ApiKey = '') then
  begin
    AError := ErrLLM(leConfig, 'model and API key are required', '');
    Exit(False);
  end;

  Body := BuildRequestBody(FConfig, ARequest);
  Headers := TStringList.Create;
  Parser := TSSEParser.Create(AOnText, AOnReasoning);
  try
    Headers.Values['Authorization'] := 'Bearer ' + FConfig.ApiKey;
    Headers.Values['Content-Type'] := 'application/json';
    Headers.Values['Accept'] := 'text/event-stream';

    SinkOk := FTransport.PostStream(Endpoint, Body, Headers, Parser.Feed,
      Status, TransportError);
    if not SinkOk then
    begin
      AError := ErrLLM(leNetwork, 'request failed', TransportError);
      Exit(False);
    end;

    if (Status < 200) or (Status >= 300) then
    begin
      if (Status = 401) or (Status = 403) then
        AError := ErrLLM(leAuth, 'authentication failed',
          'HTTP ' + IntToStr(Status) + ': ' + TransportError)
      else if Status = 429 then
        AError := ErrLLM(leRateLimit, 'rate limited',
          'HTTP 429: ' + TransportError)
      else
        AError := ErrLLM(leHttpStatus, 'provider returned an error',
          'HTTP ' + IntToStr(Status) + ': ' + TransportError);
      Exit(False);
    end;

    Parser.Finish;
    if Parser.ProviderError <> '' then
    begin
      AError := ErrLLM(leProvider, 'provider error', Parser.ProviderError);
      Exit(False);
    end;
    if Parser.Malformed then
    begin
      AError := ErrLLM(leMalformedStream, 'could not parse the stream', '');
      Exit(False);
    end;

    AResult := Parser.Result;
    Result := True;
  finally
    Parser.Free;
    Headers.Free;
  end;
end;

end.
