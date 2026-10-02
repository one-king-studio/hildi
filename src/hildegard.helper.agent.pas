unit hildegard.helper.agent;
{ Single-threaded agent loop. Owns the conversation, injects tools, drives the
  LLM client, executes the tool calls the model requests, feeds the results
  back, and re-queries until a proper stop reason or a bounded iteration limit.
  Conversations live behind IConversationStore (in-memory today; SQLite later). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, hildegard.helper.llm, hildegard.helper.session;

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

  { The loop's persistence seam: the conversation it replays, the display-only
    blocks it produces, and the turn/request audit. An implementation that does
    not persist (in-memory) ignores the audit calls and returns 0 for the ids. }
  IConversationStore = interface
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    procedure Clear;
    { Display-only blocks: persisted for restore, never sent to the provider. }
    procedure AppendReasoning(const AText: string);
    procedure AppendError(const AMessage, ADetail: string);
    { Turn/request audit. BeginTurn opens a loop; the user prompt is appended
      separately, linked to the open turn. Ids are 0 when not persisted. }
    function BeginTurn: Int64;
    function BeginRequest(ATurnId: Int64; const AModel: string;
      AMessageCount: Integer): Int64;
    procedure FinishRequest(ARequestId: Int64; const AOutcome: TRequestOutcome);
    procedure FinishTurn(ATurnId: Int64; const AOutcome: TTurnOutcome);
  end;

  TMemoryConversationStore = class(TInterfacedObject, IConversationStore)
  private
    FItems: TChatMessageArray;
  public
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

  { Receives the raw JSON arguments string and returns a text result. On failure
    returns False with AError set; the loop turns that into an error tool result. }
  TToolHandler = function(const AArgumentsJson: string;
    out AResult: string; out AError: string): Boolean of object;

  { Fires before dispatch. AReason is the model's stated reason for the call, or
    '' when the arguments had none or it was invalid. }
  TToolCallEvent = procedure(const AId, AName, AArguments, AReason: string)
    of object;
  TToolResultEvent = procedure(const AId, AName, AResult: string;
    AOk: Boolean) of object;

  TAgentEvents = record
    OnText: TLLMTextEvent;
    OnReasoning: TLLMReasoningEvent;
    OnToolCall: TToolCallEvent;
    OnToolResult: TToolResultEvent;
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
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    function Specs: TToolSpecArray;
    function Count: Integer;
  end;

  TAgentConfig = record
    SystemPrompt: string;
    MaxToolIterations: Integer;
  end;

  TAgentLoop = class
  private
    FClient: TLLMClient;
    FStore: IConversationStore;
    FTools: TToolRegistry;
    FConfig: TAgentConfig;
    FCancel: TAgentCancelCheck;
    function BuildRequest: TChatRequest;
    procedure ExecuteToolCalls(const ACalls: TChatToolCallArray;
      const AEvents: TAgentEvents; out AAllOk: Boolean);
    function FinishError(const AResult: TChatResult): TLLMError;
    function DoSend(const AUserText: string; const AEvents: TAgentEvents;
      out AAnswer: string; out AError: TLLMError): Boolean;
  public
    constructor Create(AClient: TLLMClient; AStore: IConversationStore;
      ATools: TToolRegistry; const AConfig: TAgentConfig);
    function Send(const AUserText: string; AOnText: TLLMTextEvent;
      out AAnswer: string; out AError: TLLMError): Boolean; overload;
    function Send(const AUserText: string; const AEvents: TAgentEvents;
      out AAnswer: string; out AError: TLLMError): Boolean; overload;
    { Consulted at each loop boundary (before building a request); True closes
      the turn as cancelled. Never breaks a tool batch part-way. }
    property CancelCheck: TAgentCancelCheck read FCancel write FCancel;
  end;

procedure RegisterDefaultTools(ATools: TToolRegistry);

{ Required, non-empty, human-readable reason every tool call must carry. }
function ExtractToolReason(const AArgumentsJson: string;
  out AReason: string; out AError: string): Boolean;

const
  DefaultMaxToolIterations = 8;
  BuiltinGetSystemTimeName = 'get_system_time';
  ToolReasonParamName = 'reason';
  DefaultSystemPrompt =
    'You are a helpful assistant running inside hildegard-helper. ' +
    'Use the provided tools when they help answer the user.';

implementation

uses
  DateUtils, fpjson, jsonparser;

type
  { Owns the built-in tool handlers. A singleton because TToolHandler is an
    "of object" method pointer that must outlive the registry. }
  TBuiltinTools = class
  public
    function GetSystemTime(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
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
  out AResult: string; out AError: string): Boolean;
begin
  AResult := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now));
  AError := '';
  Result := True;
end;

procedure RegisterDefaultTools(ATools: TToolRegistry);
var
  Spec: TToolSpec;
begin
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
    end;

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

procedure TMemoryConversationStore.AppendReasoning(const AText: string);
begin
  // in-memory: display blocks are not kept
end;

procedure TMemoryConversationStore.AppendError(const AMessage, ADetail: string);
begin
  // in-memory: display blocks are not kept
end;

function TMemoryConversationStore.BeginTurn: Int64;
begin
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

{ --- TAgentLoop --------------------------------------------------------- }

constructor TAgentLoop.Create(AClient: TLLMClient; AStore: IConversationStore;
  ATools: TToolRegistry; const AConfig: TAgentConfig);
begin
  inherited Create;
  FClient := AClient;
  FStore := AStore;
  FTools := ATools;
  FConfig := AConfig;
  if FConfig.MaxToolIterations <= 0 then
    FConfig.MaxToolIterations := DefaultMaxToolIterations;
end;

function TAgentLoop.BuildRequest: TChatRequest;
begin
  Result := Default(TChatRequest);
  Result.Messages := FStore.Messages;
  if FTools <> nil then
    Result.Tools := FTools.Specs;
end;

procedure TAgentLoop.ExecuteToolCalls(const ACalls: TChatToolCallArray;
  const AEvents: TAgentEvents; out AAllOk: Boolean);
var
  I: Integer;
  Tool: TRegisteredTool;
  ResultText, HandlerError, Reason, ReasonError: string;
  HandlerOk, ReasonOk: Boolean;
  Msg: TChatMessage;
  StartMs: Int64;
begin
  AAllOk := True;
  for I := 0 to High(ACalls) do
  begin
    Reason := '';
    ReasonOk := ExtractToolReason(ACalls[I].Arguments, Reason, ReasonError);

    if Assigned(AEvents.OnToolCall) then
      AEvents.OnToolCall(ACalls[I].Id, ACalls[I].Name, ACalls[I].Arguments,
        Reason);

    ResultText := '';
    HandlerOk := False;
    StartMs := GetTickCount64;
    if not ReasonOk then
      ResultText := 'error: tool "' + ACalls[I].Name + '" ' + ReasonError
    else if (FTools = nil) or not FTools.Find(ACalls[I].Name, Tool) then
      ResultText := 'error: unknown tool "' + ACalls[I].Name + '"'
    else
    begin
      HandlerError := '';
      try
        HandlerOk := Tool.Handler(ACalls[I].Arguments, ResultText, HandlerError);
      except
        on E: Exception do
        begin
          HandlerOk := False;
          HandlerError := E.Message;
        end;
      end;
      if not HandlerOk then
        ResultText := 'error: tool "' + ACalls[I].Name + '" failed: ' +
          HandlerError;
    end;
    if not HandlerOk then
      AAllOk := False;

    if Assigned(AEvents.OnToolResult) then
      AEvents.OnToolResult(ACalls[I].Id, ACalls[I].Name, ResultText, HandlerOk);

    Msg := Default(TChatMessage);
    Msg.Role := crTool;
    Msg.ToolCallId := ACalls[I].Id;
    Msg.Content := ResultText;
    Msg.ToolName := ACalls[I].Name;
    Msg.ToolOk := HandlerOk;
    Msg.DurationMs := Int64(GetTickCount64 - StartMs);
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
  Result := DoSend(AUserText, AEvents, AAnswer, AError);
end;

function TAgentLoop.DoSend(const AUserText: string; const AEvents: TAgentEvents;
  out AAnswer: string; out AError: TLLMError): Boolean;
var
  Iterations: Integer;
  Request: TChatRequest;
  ChatResult: TChatResult;
  UserMsg, SystemMsg: TChatMessage;
  AllOk: Boolean;
  TurnId, RequestId: Int64;
  StartMs: Int64;
  Outcome: TRequestOutcome;
  TurnOutcome: TTurnOutcome;

  procedure FailTurn(ACode: TLLMErrorCode; const AMessage, ADetail,
    AFinishReason: string);
  begin
    AError := AgentError(ACode, AMessage, ADetail);
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

begin
  AAnswer := '';
  AError := AgentOk;

  if (FStore.Messages = nil) and (FConfig.SystemPrompt <> '') then
  begin
    SystemMsg := Default(TChatMessage);
    SystemMsg.Role := crSystem;
    SystemMsg.Content := FConfig.SystemPrompt;
    FStore.Append(SystemMsg);
  end;

  { Open the loop before appending the prompt, so the prompt is linked to it. }
  TurnId := FStore.BeginTurn;

  UserMsg := Default(TChatMessage);
  UserMsg.Role := crUser;
  UserMsg.Content := AUserText;
  FStore.Append(UserMsg);

  Iterations := 0;
  while True do
  begin
    { A cancel between requests stops the loop; a tool batch is never broken
      part-way, so its calls and results stay paired. }
    if Assigned(FCancel) and FCancel() then
    begin
      FailTurn(leCancelled, 'cancelled', '', '');
      Exit(False);
    end;
    Request := BuildRequest;
    RequestId := FStore.BeginRequest(TurnId, FClient.Model,
      Length(Request.Messages));
    StartMs := GetTickCount64;
    Outcome := Default(TRequestOutcome);

    if not FClient.Complete(Request, AEvents.OnText, AEvents.OnReasoning,
      ChatResult, AError) then
    begin
      Outcome.Ok := False;
      Outcome.ErrorCode := AError.Code;
      Outcome.ErrorMessage := AError.Message;
      Outcome.ErrorDetail := AError.Detail;
      Outcome.DurationMs := Int64(GetTickCount64 - StartMs);
      FStore.FinishRequest(RequestId, Outcome);
      FailTurn(AError.Code, AError.Message, AError.Detail, '');
      Exit(False);
    end;

    Outcome.Ok := True;
    Outcome.FinishReason := ChatResult.FinishReason;
    Outcome.RawFinishReason := ChatResult.RawFinishReason;
    Outcome.Usage := ChatResult.Usage;
    Outcome.FirstTokenMs := ChatResult.FirstTokenMs;
    Outcome.DurationMs := Int64(GetTickCount64 - StartMs);

    FStore.AppendReasoning(ChatResult.ReasoningContent);
    FStore.Append(ChatResult.Message);
    FStore.FinishRequest(RequestId, Outcome);

    if ChatResult.FinishReason = frStop then
    begin
      AAnswer := ChatResult.Message.Content;
      TurnOutcome := Default(TTurnOutcome);
      TurnOutcome.Status := tsCompleted;
      TurnOutcome.FinishReason := ChatResult.RawFinishReason;
      FStore.FinishTurn(TurnId, TurnOutcome);
      Exit(True);
    end;

    if ChatResult.FinishReason = frToolCalls then
    begin
      Inc(Iterations);
      if Iterations > FConfig.MaxToolIterations then
      begin
        FailTurn(leProvider, 'tool iteration limit reached',
          IntToStr(FConfig.MaxToolIterations), ChatResult.RawFinishReason);
        Exit(False);
      end;
      ExecuteToolCalls(ChatResult.Message.ToolCalls, AEvents, AllOk);
      Continue;
    end;

    AError := FinishError(ChatResult);
    FailTurn(AError.Code, AError.Message, AError.Detail,
      ChatResult.RawFinishReason);
    Exit(False);
  end;
end;

initialization
  BuiltinTools := TBuiltinTools.Create;

finalization
  BuiltinTools.Free;

end.
