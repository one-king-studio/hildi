unit hildegard.helper.agent;
{ Single-threaded agent loop. Owns the conversation, injects tools, drives the
  LLM client, executes the tool calls the model requests, feeds the results
  back, and re-queries until a proper stop reason or a bounded iteration limit.
  Conversations live behind IConversationStore (in-memory today; SQLite later). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, hildegard.helper.llm;

type
  IConversationStore = interface
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    procedure Clear;
  end;

  TMemoryConversationStore = class(TInterfacedObject, IConversationStore)
  private
    FItems: TChatMessageArray;
  public
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    procedure Clear;
  end;

  { Receives the raw JSON arguments string and returns a text result. On failure
    returns False with AError set; the loop turns that into an error tool result. }
  TToolHandler = function(const AArgumentsJson: string;
    out AResult: string; out AError: string): Boolean of object;

  TToolCallEvent = procedure(const AId, AName, AArguments: string) of object;
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
  end;

procedure RegisterDefaultTools(ATools: TToolRegistry);

const
  DefaultMaxToolIterations = 8;
  BuiltinGetSystemTimeName = 'get_system_time';

implementation

uses
  DateUtils;

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

{ --- TToolRegistry ------------------------------------------------------ }

procedure TToolRegistry.Add(const ASpec: TToolSpec; AHandler: TToolHandler);
var
  N: Integer;
begin
  if ASpec.Name = '' then
    Exit;
  N := Length(FTools);
  SetLength(FTools, N + 1);
  FTools[N].Spec := ASpec;
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
  ResultText, HandlerError: string;
  HandlerOk: Boolean;
  Msg: TChatMessage;
begin
  AAllOk := True;
  for I := 0 to High(ACalls) do
  begin
    if Assigned(AEvents.OnToolCall) then
      AEvents.OnToolCall(ACalls[I].Id, ACalls[I].Name, ACalls[I].Arguments);

    ResultText := '';
    HandlerOk := False;
    if (FTools = nil) or not FTools.Find(ACalls[I].Name, Tool) then
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

  UserMsg := Default(TChatMessage);
  UserMsg.Role := crUser;
  UserMsg.Content := AUserText;
  FStore.Append(UserMsg);

  Iterations := 0;
  while True do
  begin
    Request := BuildRequest;
    if not FClient.Complete(Request, AEvents.OnText, AEvents.OnReasoning,
      ChatResult, AError) then
      Exit(False);

    FStore.Append(ChatResult.Message);

    if ChatResult.FinishReason = frStop then
    begin
      AAnswer := ChatResult.Message.Content;
      Exit(True);
    end;

    if ChatResult.FinishReason = frToolCalls then
    begin
      Inc(Iterations);
      if Iterations > FConfig.MaxToolIterations then
      begin
        AError := AgentError(leProvider, 'tool iteration limit reached',
          IntToStr(FConfig.MaxToolIterations));
        Exit(False);
      end;
      ExecuteToolCalls(ChatResult.Message.ToolCalls, AEvents, AllOk);
      Continue;
    end;

    AError := FinishError(ChatResult);
    Exit(False);
  end;
end;

initialization
  BuiltinTools := TBuiltinTools.Create;

finalization
  BuiltinTools.Free;

end.
