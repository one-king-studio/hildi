unit LLMClient;
{ OpenAI-compatible chat client with SSE streaming. Builds a chat-completions
  request, streams the response through an injectable transport, surfaces text
  deltas, accumulates tool-call deltas by index, and maps the finish reason and
  provider errors. The only unit that knows about HTTP, TLS, SSE, and the
  provider JSON shape. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, LLMEnv, LLMProvider,
  { Linked for its initialization: it installs the vendor registrar, so naming
    it here is what makes ProviderByKey resolve a real vendor. }
  LLMProviders;

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
    { Opt-OUT. A batch of calls in one assistant message is the model's intent
      to run them together, so every tool is parallel-safe by default. Set this
      True only for a tool that genuinely must run alone (never concurrently
      with a sibling). }
    SerialOnly: Boolean;
  end;

  TToolSpecArray = array of TToolSpec;

  TFinishReason = (frStop, frToolCalls, frLength, frContentFilter, frUnknown);

  { Normalised token accounting: one shape across the provider spellings
    (OpenAI/Fireworks, DeepSeek, Anthropic-style gateways). Absent usage is all
    zeros. The counters are Int64 because the SAME record carries session
    aggregates: SessionTotals sums every request, and every request re-bills the
    whole context, A long session crossed MaxInt and raised ERangeError
    (observed at 2,149,321,552 total tokens). }
  TTokenUsage = record
    PromptTokens: Int64;        // prompt_tokens | input_tokens
    CompletionTokens: Int64;    // completion_tokens | output_tokens
    TotalTokens: Int64;         // total_tokens, else prompt + completion
    CachedTokens: Int64;        // prompt_tokens_details.cached_tokens
                                 //   | prompt_cache_hit_tokens
                                 //   | cache_read_input_tokens
    ReasoningTokens: Int64;     // completion_tokens_details.reasoning_tokens
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
    leMalformedStream, leProvider, leCancelled,
    { The agent loop stopped itself: a tool-call loop or an over-large context.
      Appended last so stored ordinals are unchanged. }
    leLoop,
    { The response was truncated and could not be completed within the
      continuation budget. Appended last so stored ordinals are unchanged. }
    leTruncated
  );

  TLLMError = record
    Code: TLLMErrorCode;
    Message: string;
    Detail: string;
    { The HTTP status when the failure came from a response (0 otherwise), so a
      caller can tell a retryable 5xx from a terminal 4xx. }
    Status: Integer;
  end;

  TLLMTextEvent = procedure(const AText: string) of object;
  TLLMReasoningEvent = procedure(const AText: string) of object;
  TLLMChunkEvent = procedure(const AData: RawByteString) of object;
  { Consulted between stream reads; True abandons the request as cancelled. }
  TLLMCancelCheck = function: Boolean of object;

  { One optional request parameter. TRI-STATE on purpose: `Set_ = False` means
    the key is absent from the JSON body, which is a different request from a key
    present and zero. A sentinel - 0 meaning "unset" - would be a lie, because a
    temperature of 0 is a real and very different setting. }
  TLLMParam = record
    Set_: Boolean;
    Value: Double;      // numeric parameters; integers carried here too
  end;

  TLLMConfig = record
    Endpoint: string;
    Model: string;
    ApiKey: string;
    ConnectTimeoutMs: Integer;
    ReadTimeoutMs: Integer;
    { Optional request parameters. Unset => the key is not sent at all, so the
      provider's own default applies. Resolved from HILDI_LLM_* by
      ResolveLLMConfig; an explicitly set field is never overwritten. }
    Temperature: TLLMParam;        // 0..2
    TopP: TLLMParam;               // 0..1
    MaxTokens: TLLMParam;          // integer > 0
    FrequencyPenalty: TLLMParam;   // -2..2
    PresencePenalty: TLLMParam;    // -2..2
    Seed: TLLMParam;               // integer >= 0
    { Empty => no `stop` key. Sent as a JSON ARRAY when non-empty. }
    Stop: TStringArray;
    { Which vendor dialect this request speaks. '' means Fireworks, because that
      is what every install that has never configured a provider is - so an
      existing setup needs no edit and no migration. }
    Provider: string;
  end;

  TLLMTransport = class
  public
    { Consulted between stream reads; when it fires the request is abandoned
      and PostStream returns with ACancelled = True. }
    CancelCheck: TLLMCancelCheck;
    { Returns True when an HTTP response was received (even non-2xx). False on a
      transport/network failure with AStatusCode = 0. On non-2xx, AError carries
      the response body for error mapping; on 2xx it is ''. ACancelled is True
      when the read was abandoned by CancelCheck. }
    function PostStream(const AURL: string; const ABody: string;
      const AHeaders: TStringList; AOnChunk: TLLMChunkEvent;
      out AStatusCode: Integer; out AError: string;
      out ACancelled: Boolean): Boolean; virtual; abstract;
  end;

  TFPHTTPTransport = class(TLLMTransport)
  public
    function PostStream(const AURL: string; const ABody: string;
      const AHeaders: TStringList; AOnChunk: TLLMChunkEvent;
      out AStatusCode: Integer; out AError: string;
      out ACancelled: Boolean): Boolean; override;
  end;

  TLLMClient = class
  private
    FConfig: TLLMConfig;
    FTransport: TLLMTransport;
    FOwnsTransport: Boolean;
    FCancel: TLLMCancelCheck;
    { The vendor dialect resolved from FConfig.Provider. Never nil: an unknown key
      is a config error reported from Complete, and '' means Fireworks because
      that is what every existing install is. }
    FProvider: TLLMProvider;
    { A parameter that is present but unparseable. Carried out of Create because
      a constructor cannot fail, then reported from Complete - which already has
      an out AError: TLLMError - so the failure still happens before any I/O. }
    FConfigError: string;
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
    { Consulted mid-stream; when it fires, Complete returns leCancelled. }
    property CancelCheck: TLLMCancelCheck read FCancel write FCancel;
  end;

function ResolveLLMConfig(const AConfig: TLLMConfig): TLLMConfig;
{ Resolve the optional request parameters, and REPORT rather than coerce. Fills
  any unset parameter from its HILDI_LLM_* variable (with the HILDEGARD_* legacy
  fallback), leaving a field the caller already set untouched. Returns False and
  fills AError - naming the variable and the offending text - when a value is
  present but unparseable or out of range. A value outside the documented range
  is never clamped: substituting a number the operator did not ask for is a
  silent behaviour change, which is worse than refusing.
  A pure function of the environment, so the whole policy is testable. }
function ResolveLLMParams(var AConfig: TLLMConfig;
  out AError: string): Boolean;
function RoleToString(ARole: TChatRole): string;

{ A failure's display text: the message, plus the cause after a colon when there
  is one. Pure, so the format is pinned without a surface, and shared by the TUI
  and the CLI so a failure reads the same everywhere. }
function ErrorText(const AMessage, ADetail: string): string;

{ Whether a request failure is worth retrying: a network/transport failure, a
  429, or a 5xx. A terminal error - auth, config, malformed, provider, cancelled,
  loop, truncated - is never retried. }
function IsRetryable(const AError: TLLMError): Boolean;

{ Build an error value. Exported because whoever resolves configuration - a
  session, a provider loader - has to report a leConfig failure through the same
  type the client uses, rather than inventing a parallel one. }
function ErrLLM(ACode: TLLMErrorCode; const AMessage, ADetail: string): TLLMError;
function OkLLM: TLLMError;

{ A short, operator-facing phrase for an error code ("network error",
  "rate limited", "authentication failed", ...). }
function OperatorPhrase(ACode: TLLMErrorCode): string;

const
  DefaultLLMEndpoint = 'https://api.fireworks.ai/inference/v1/chat/completions';
  DefaultConnectTimeoutMs = 10000;
  DefaultReadTimeoutMs = 120000;
  { The default running-context limit (latest prompt tokens) until the model API
    can supply it. Shared by the loop's guard and the UI's context meter. }
  DefaultMaxContextTokens = 120000;

implementation

uses
  fpjson, jsonparser, fphttpclient, LLMTLS;

type
  { Forwards each response-body chunk to a callback while capturing a bounded
    prefix, so non-2xx bodies can be reported. }
  { Raised inside a stream write when the cancel check fires, to unwind out of
    the HTTP read. Caught by PostStream, which reports ACancelled. }
  ECancelledStream = class(Exception);

  TChunkProxyStream = class(TStream)
  private
    FOnChunk: TLLMChunkEvent;
    FCancel: TLLMCancelCheck;
    FCapture: RawByteString;
  public
    constructor Create(AOnChunk: TLLMChunkEvent; ACancel: TLLMCancelCheck);
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
    { The vendor dialect, so a chunk can be interpreted before the neutral rules
      see it. Nil is legal and means "plain OpenAI shape", which keeps every
      existing test and the in-memory fakes working untouched. }
    FProvider: TLLMProvider;
    FPendingFinishHint: string;
    FResult: TChatResult;
    FHasFinish: Boolean;
    FDone: Boolean;
    FMalformed: Boolean;
    FProviderError: string;
    FStartMs: QWord;
    FMarked: Boolean;
    { The streamed reply assembled into a buffer, not by `Results := Results +`.
      A turn is ~5,900 allocations averaging 121 bytes, and string concatenation
      reallocs and copies the whole prefix each time - O(n^2) in the reply length.
      Appending to a buffer that grows geometrically turns that into amortised
      O(n); the two accumulators are handed to FResult once, in Finish. }
    FContentBuf: TStringBuilder;
    FReasoningBuf: TStringBuilder;
    procedure ProcessLine(const ALine: string);
    procedure FlushEvent;
    procedure HandleData(const AData: RawByteString);
    procedure HandleJson(const AJson: TJSONObject);
    procedure AccumulateToolCalls(const ADelta: TJSONObject);
    procedure ReadUsage(const AUsage: TJSONObject);
    procedure MarkFirstToken;
    procedure SetFinish(const AReason: string);
    function GetResult: TChatResult;
  public
    constructor Create(AOnText: TLLMTextEvent;
      AOnReasoning: TLLMReasoningEvent);
    destructor Destroy; override;
    procedure Feed(const AData: RawByteString);
    procedure Finish;
    property Result: TChatResult read GetResult;
    property Done: Boolean read FDone;
    property Malformed: Boolean read FMalformed;
    property ProviderError: string read FProviderError;
  end;

function ErrLLM(ACode: TLLMErrorCode; const AMessage, ADetail: string): TLLMError;
begin
  Result.Code := ACode;
  Result.Message := AMessage;
  Result.Detail := ADetail;
  Result.Status := 0;
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
    V := GetEnvLegacy('HILDI_LLM_MODEL');
    if V = '' then
      V := GetEnvironmentVariable('FIREWORKS_MODEL');
    Result.Model := V;
  end;
  if Result.ApiKey = '' then
  begin
    V := GetEnvLegacy('HILDI_LLM_API_KEY');
    if V = '' then
      V := GetEnvironmentVariable('FIREWORKS_API_KEY');
    Result.ApiKey := V;
  end;
  if Result.ConnectTimeoutMs <= 0 then
    Result.ConnectTimeoutMs := DefaultConnectTimeoutMs;
  if Result.ReadTimeoutMs <= 0 then
    Result.ReadTimeoutMs := DefaultReadTimeoutMs;
end;

{ --- optional request parameters ---------------------------------------- }

const
  { Documented provider conventions. Enforced as OUR policy so a typo is a
    configuration error rather than a silently odd request. }
  MinTemperature = 0.0;
  MaxTemperature = 2.0;
  MinProbability = 0.0;
  MaxProbability = 1.0;
  MinPenalty = -2.0;
  MaxPenalty = 2.0;

function ParamVar(const AName: string): string;
begin
  Result := 'HILDI_LLM_' + AName;
end;

{ Read one optional numeric parameter. Absent => leave the field unset. Present
  but unparseable or out of range => False with a message naming the variable. }
function ReadNumericParam(const AEnvName: string; AMin, AMax: Double;
  var AParam: TLLMParam; out AError: string): Boolean;
var
  Raw: string;
  V: Double;
  FS: TFormatSettings;
begin
  Result := True;
  if AParam.Set_ then
    Exit;                       // an explicit config is a decision, not a default
  Raw := GetEnvLegacy(ParamVar(AEnvName));
  if Raw = '' then
    Exit;
  { JSONFormatSettings, not the locale default: on a comma-decimal locale
    StrToFloat('0.2') would parse as 2 or fail outright, so a value read here
    would disagree with the '.' the body is written with. }
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  if not TryStrToFloat(Raw, V, FS) then
  begin
    AError := ParamVar(AEnvName) + ' is not a number: "' + Raw + '"';
    Exit(False);
  end;
  if (V < AMin) or (V > AMax) then
  begin
    { NOT clamped. Substituting a value the operator did not ask for is a silent
      behaviour change, which is worse than refusing. }
    AError := Format('%s is out of range (%g..%g): "%s"',
      [ParamVar(AEnvName), AMin, AMax, Raw]);
    Exit(False);
  end;
  AParam.Set_ := True;
  AParam.Value := V;
end;

{ An integer parameter: 1.5 is an error, not a truncation. }
function ReadIntegerParam(const AEnvName: string; AMin: Double;
  var AParam: TLLMParam; out AError: string): Boolean;
var
  Raw: string;
  V: Int64;
begin
  Result := True;
  if AParam.Set_ then
    Exit;
  Raw := GetEnvLegacy(ParamVar(AEnvName));
  if Raw = '' then
    Exit;
  if not TryStrToInt64(Raw, V) then
  begin
    AError := ParamVar(AEnvName) + ' is not a whole number: "' + Raw + '"';
    Exit(False);
  end;
  if V < AMin then
  begin
    AError := Format('%s is out of range (%g..): "%s"',
      [ParamVar(AEnvName), AMin, Raw]);
    Exit(False);
  end;
  AParam.Set_ := True;
  AParam.Value := V;
end;

function SplitStop(const ARaw: string): TStringArray;
var
  Parts: TStringArray;
  I, N: Integer;
begin
  Result := nil;
  Parts := ARaw.Split([',']);
  N := 0;
  SetLength(Result, Length(Parts));
  for I := 0 to High(Parts) do
  begin
    if Trim(Parts[I]) = '' then
      Continue;                 // a stop list that yields nothing is unset
    Result[N] := Trim(Parts[I]);
    Inc(N);
  end;
  SetLength(Result, N);
end;

function ResolveLLMParams(var AConfig: TLLMConfig;
  out AError: string): Boolean;
var
  Raw: string;
  Cfg: TLLMConfig;
  Ok: Boolean;
begin
  { Resolve into a copy so a failure leaves the caller's config untouched, then
    publish only on success. A half-resolved config is not a state anyone
    should be able to observe. }
  Cfg := AConfig;
  AError := '';
  Ok := ReadNumericParam('TEMPERATURE', MinTemperature, MaxTemperature,
    Cfg.Temperature, AError);
  if Ok then
    Ok := ReadNumericParam('TOP_P', MinProbability, MaxProbability,
      Cfg.TopP, AError);
  if Ok then
    Ok := ReadIntegerParam('MAX_TOKENS', 1, Cfg.MaxTokens, AError);
  if Ok then
    Ok := ReadNumericParam('FREQUENCY_PENALTY', MinPenalty, MaxPenalty,
      Cfg.FrequencyPenalty, AError);
  if Ok then
    Ok := ReadNumericParam('PRESENCE_PENALTY', MinPenalty, MaxPenalty,
      Cfg.PresencePenalty, AError);
  if Ok then
    Ok := ReadIntegerParam('SEED', 0, Cfg.Seed, AError);
  if Ok and (Length(Cfg.Stop) = 0) then
  begin
    Raw := GetEnvLegacy(ParamVar('STOP'));
    if Raw <> '' then
      Cfg.Stop := SplitStop(Raw);
  end;
  if Ok then
    AConfig := Cfg;
  Result := Ok;
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

function ErrorText(const AMessage, ADetail: string): string;
begin
  if Trim(ADetail) = '' then
    Result := AMessage
  else
    Result := AMessage + ': ' + ADetail;
end;

function IsRetryable(const AError: TLLMError): Boolean;
begin
  case AError.Code of
    leNetwork, leRateLimit:
      Result := True;
    leHttpStatus:
      { A 5xx is the provider's fault and may clear; a 4xx will not. }
      Result := (AError.Status >= 500) and (AError.Status < 600);
  else
    Result := False;
  end;
end;

function OperatorPhrase(ACode: TLLMErrorCode): string;
begin
  case ACode of
    leOk: Result := '';
    leConfig: Result := 'configuration error';
    leNetwork: Result := 'network error';
    leHttpStatus: Result := 'provider error';
    leAuth: Result := 'authentication failed';
    leRateLimit: Result := 'rate limited';
    leMalformedStream: Result := 'could not parse the provider stream';
    leProvider: Result := 'provider error';
    leCancelled: Result := 'cancelled';
    leLoop: Result := 'agent loop stopped';
    leTruncated: Result := 'response truncated';
  end;
end;

{ --- TChunkProxyStream -------------------------------------------------- }

constructor TChunkProxyStream.Create(AOnChunk: TLLMChunkEvent;
  ACancel: TLLMCancelCheck);
begin
  inherited Create;
  FOnChunk := AOnChunk;
  FCancel := ACancel;
  FCapture := '';
end;

function TChunkProxyStream.Write(const Buffer; Count: LongInt): LongInt;
var
  S: RawByteString;
begin
  if Count <= 0 then
    Exit(0);
  { Between reads: abandon the request as soon as the caller asks. }
  if Assigned(FCancel) and FCancel() then
    raise ECancelledStream.Create('cancelled');
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
  out AStatusCode: Integer; out AError: string;
  out ACancelled: Boolean): Boolean;
var
  Client: TFPHTTPClient;
  Body: TStringStream;
  Proxy: TChunkProxyStream;
  I: Integer;
begin
  Result := False;
  AStatusCode := 0;
  AError := '';
  ACancelled := False;
  Client := TFPHTTPClient.Create(nil);
  Body := TStringStream.Create(ABody);
  Proxy := TChunkProxyStream.Create(AOnChunk, CancelCheck);
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
      on E: ECancelledStream do
      begin
        ACancelled := True;
        AError := 'cancelled';
        Result := False;
      end;
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
  FProvider := nil;
  FPendingFinishHint := '';
  FBuffer := '';
  FPending := '';
  FHasData := False;
  FHasFinish := False;
  FDone := False;
  FMalformed := False;
  FProviderError := '';
  FStartMs := GetTickCount64;
  FMarked := False;
  FContentBuf := TStringBuilder.Create;
  FReasoningBuf := TStringBuilder.Create;
  FResult := Default(TChatResult);
  FResult.Message.Role := crAssistant;
end;

destructor TSSEParser.Destroy;
begin
  FContentBuf.Free;
  FReasoningBuf.Free;
  inherited Destroy;
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
  Hint: string;
  HintError: string;
begin
  if AJson = nil then
    Exit;
  try
    { THE VENDOR SEES THE CHUNK FIRST. Two things the neutral rules cannot know:
      OpenRouter can deliver a genuine failure inside an HTTP 200 stream (a
      choice carrying an `error` object), and OpenAI still documents the
      deprecated `function_call` finish reason. Without this the first becomes a
      clean stop with an empty answer and the second a turn that looks like the
      model simply quit. }
    if FProvider <> nil then
    begin
      Hint := '';
      HintError := '';
      if not FProvider.InspectChunk(AJson, HintError, Hint) then
      begin
        FProviderError := HintError;
        FDone := True;
        Exit;
      end;
      if Hint <> '' then
        FPendingFinishHint := Hint;
    end;

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
        FContentBuf.Append(Content.AsString);
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
        FReasoningBuf.Append(Reasoning.AsString);
        if Assigned(FOnReasoning) then
          FOnReasoning(Reasoning.AsString);
      end;

      AccumulateToolCalls(Delta);
    end;

    Finish := Choice.Find('finish_reason');
    { THE VENDOR'S RECLASSIFICATION WINS. It inspected this chunk first precisely
      because its raw vocabulary needs translating - OpenAI's `function_call` is
      real on the wire but has no neutral equivalent, and the naive mapping drops
      it to frUnknown, which reads as "the model stopped" while a tool call was
      actually requested. Checking the hint first is what makes the hook do its
      job; checking it only as a fallback means it never fires for any reason the
      parser already recognises. }
    if FPendingFinishHint <> '' then
      SetFinish(FPendingFinishHint)
    else if (Finish <> nil) and (Finish.JSONType = jtString) then
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
  { `function_call` is OpenAI's DEPRECATED spelling of the same event, and it is
    still in the published enum (openapi.yaml: stop | length | tool_calls |
    content_filter | function_call). Mapping it here rather than only in a
    vendor override means every caller gets it right, including an
    OpenAI-compatible endpoint nobody wrote an adapter for. Left unmapped it
    becomes frUnknown - a turn that looks like the model simply stopped while a
    tool call was actually requested, so no tool runs and nothing reports why. }
  else if AReason = 'function_call' then
    FResult.FinishReason := frToolCalls
  else
    FResult.FinishReason := frUnknown;
end;

procedure TSSEParser.Finish;
begin
  FlushEvent;
  if not FHasFinish then
    FResult.FinishReason := frUnknown;
end;

function TSSEParser.GetResult: TChatResult;
begin
  { Publish the streamed text on READ, not only in Finish. Finish is reached
    only on a clean 2xx; a cancel, a transport failure or an HTTP error exits
    before it, and the accumulated text must still be visible on Result - the
    pre-buffer code wrote each delta straight into FResult and so had that
    property for free. Assigning here keeps it, and costs one copy per read
    rather than one realloc per delta. }
  if FContentBuf.Length > 0 then
    FResult.Message.Content := FContentBuf.ToString;
  if FReasoningBuf.Length > 0 then
    FResult.ReasoningContent := FReasoningBuf.ToString;
  Result := FResult;
end;

{ --- request serialization --------------------------------------------- }

function BuildRequestBody(const AConfig: TLLMConfig;
  AProvider: TLLMProvider; const ARequest: TChatRequest): string;
var
  Root: TJSONObject;
  Msgs: TJSONArray;
  Tools: TJSONArray;
  MObj, TObj, FnObj, Opts: TJSONObject;
  CallObj: TJSONArray;
  StopArr: TJSONArray;
  Context: TProviderContext;
  I, J: Integer;
  Params: TJSONData;
begin
  Root := TJSONObject.Create;
  try
    { What a vendor needs to add its own fields: the endpoint it was configured
      with, so a proxy or self-hosted install is handled without a special case. }
    Context := Default(TProviderContext);
    Context.Endpoint := AConfig.Endpoint;
    Context.ApiKey := AConfig.ApiKey;
    Context.Model := AConfig.Model;
    Root.Add('model', AConfig.Model);
    Root.Add('stream', True);
    { Ask the provider to send a final usage chunk; providers that ignore it
      simply leave the usage zeros. }
    Opts := TJSONObject.Create;
    Opts.Add('include_usage', True);
    Root.Add('stream_options', Opts);

    { OPTIONAL REQUEST PARAMETERS. Emitted only when set, so nothing here changes
      the body for an install that configures none of them. Placed before
      `messages` to keep the large arrays last, which is also the order the
      parameters read in. }
    if AConfig.Temperature.Set_ then
      Root.Add('temperature', AConfig.Temperature.Value);
    if AConfig.TopP.Set_ then
      Root.Add('top_p', AConfig.TopP.Value);
    if AConfig.MaxTokens.Set_ then
      Root.Add('max_tokens', Int64(Round(AConfig.MaxTokens.Value)));
    if AConfig.FrequencyPenalty.Set_ then
      Root.Add('frequency_penalty', AConfig.FrequencyPenalty.Value);
    if AConfig.PresencePenalty.Set_ then
      Root.Add('presence_penalty', AConfig.PresencePenalty.Value);
    if AConfig.Seed.Set_ then
      Root.Add('seed', Int64(Round(AConfig.Seed.Value)));
    if Length(AConfig.Stop) > 0 then
    begin
      { Always an array. OpenAI accepts a bare string too, but an array is what
        every compatible endpoint handles and it removes the ambiguity of a
        single stop that itself contains a comma. }
      StopArr := TJSONArray.Create;
      for I := 0 to High(AConfig.Stop) do
        StopArr.Add(AConfig.Stop[I]);
      Root.Add('stop', StopArr);
    end;

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

    { THE VENDOR ADDS ITS OWN FIELDS LAST. It receives the finished neutral body,
      so it can only add or rewrite what it owns - it can never corrupt the
      message array it does not understand. }
    if AProvider <> nil then
      AProvider.DecorateRequest(Context, Root);

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
  { Resolve the optional request parameters too, and remember a complaint rather
    than raising: Create has no failure channel, so the error is reported from
    Complete, before any network I/O. }
  FConfigError := '';
  if not ResolveLLMParams(FConfig, FConfigError) then
    ;  // FConfigError is reported from Complete
  { Resolve the vendor dialect. An empty key is Fireworks (every existing
    install); a key nobody registered is a config error reported from Complete,
    never a silent fallback - a typo must not quietly send traffic to the wrong
    vendor. }
  FProvider := ProviderByKey(FConfig.Provider);
  if (FProvider = nil) and (FConfig.Provider <> '') then
    FConfigError := 'unknown provider "' + FConfig.Provider + '"';
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
  TLSError: string;
  SinkOk, Cancelled: Boolean;
begin
  AResult := Default(TChatResult);
  AError := OkLLM;
  { A parameter that was present but unparseable. Reported here, before any I/O,
    because Create has no failure channel. }
  if FConfigError <> '' then
  begin
    AError := ErrLLM(leConfig, 'invalid request parameter', FConfigError);
    Exit(False);
  end;
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
  { A missing or unreadable CA bundle is a configuration error, reported before
    any network I/O. }
  if not ValidateTLSConfig(TLSError) then
  begin
    AError := ErrLLM(leConfig, 'TLS configuration error', TLSError);
    Exit(False);
  end;

  Body := BuildRequestBody(FConfig, FProvider, ARequest);
  Headers := TStringList.Create;
  Parser := TSSEParser.Create(AOnText, AOnReasoning);
  { The parser needs the dialect to interpret chunks the neutral rules cannot:
    an error carried inside a 200 stream, and a vendor-specific finish reason. }
  Parser.FProvider := FProvider;
  try
    Headers.Values['Authorization'] := 'Bearer ' + FConfig.ApiKey;
    Headers.Values['Content-Type'] := 'application/json';
    Headers.Values['Accept'] := 'text/event-stream';
    { Attribution or dialect headers, if the vendor has any. Added after the
      required three so a provider cannot displace Authorization by accident. }
    if FProvider <> nil then
      FProvider.ExtraHeaders(Headers);

    FTransport.CancelCheck := FCancel;
    Cancelled := False;
    SinkOk := FTransport.PostStream(Endpoint, Body, Headers, Parser.Feed,
      Status, TransportError, Cancelled);
    if Cancelled then
    begin
      AError := ErrLLM(leCancelled, 'cancelled', '');
      Exit(False);
    end;
    if not SinkOk then
    begin
      AError := ErrLLM(leNetwork, 'network error', TransportError);
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
      { The status lets a retry policy tell a 5xx from a terminal 4xx. }
      AError.Status := Status;
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
