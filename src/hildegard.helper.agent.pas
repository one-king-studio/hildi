unit hildegard.helper.agent;
{ Single-threaded agent loop. Owns the conversation, injects tools, drives the
  LLM client, executes the tool calls the model requests, feeds the results
  back, and re-queries until a proper stop reason or a bounded iteration limit.
  Conversations live behind IConversationStore (in-memory today; SQLite later). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, hildegard.helper.llm, hildegard.helper.session;

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
    { Display-only blocks: persisted for restore, never sent to the provider.
      ADurationMs is the wall time the reasoning streamed (0 when unknown). }
    procedure AppendReasoning(const AText: string; ADurationMs: Int64);
    procedure AppendError(const AMessage, ADetail: string);
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
  end;

  TPromptArray = array of string;

  { Prompts the operator injects into a running turn, drained at loop
    boundaries. Safe to Push from the UI thread while the worker drains it. }
  TPromptQueue = class
  private
    FLock: TCriticalSection;
    FItems: TPromptArray;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(const AText: string);
    { Remove and return every queued prompt, in order. }
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
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    function Specs: TToolSpecArray;
    function Count: Integer;
  end;

  TAgentConfig = record
    SystemPrompt: string;
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
  end;

  TAgentLoop = class
  private
    FClient: TLLMClient;
    FStore: IConversationStore;
    FTools: TToolRegistry;
    FConfig: TAgentConfig;
    FCancel: TAgentCancelCheck;
    FPromptQueue: TPromptQueue;
    FLastTurnDropped: Boolean;
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
    { Answer each call with a notice instead of running the tool, so the
      assistant's tool_calls stay paired with results. }
    procedure InterceptToolCalls(const ACalls: TChatToolCallArray;
      const ANotice: string; const AEvents: TAgentEvents);
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
    { Consulted at each loop boundary (before building a request); True closes
      the turn as cancelled. Never breaks a tool batch part-way. }
    property CancelCheck: TAgentCancelCheck read FCancel write FCancel;
    { Prompts the operator injects into a running turn. }
    property PromptQueue: TPromptQueue read FPromptQueue;
    { True when the last turn was cancelled before any response was committed,
      so its messages were dropped. }
    property LastTurnDropped: Boolean read FLastTurnDropped;
  end;

procedure RegisterDefaultTools(ATools: TToolRegistry);

{ Required, non-empty, human-readable reason every tool call must carry. }
function ExtractToolReason(const AArgumentsJson: string;
  out AReason: string; out AError: string): Boolean;

const
  { Tool-call budget: nudge from 30, lock down at 50, and end the turn on the
    next call after that. }
  DefaultSoftToolLimit = 30;
  DefaultHardToolLimit = 50;
  DefaultToolNoticeStep = 5;
  { The running context (latest prompt tokens) may not exceed this. }
  DefaultMaxContextTokens = 120000;
  { Followup requests allowed for one truncated response. }
  DefaultMaxContinuations = 3;
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
    'You are a helpful assistant running inside hildegard-helper. ' +
    'Use the provided tools when they help answer the user.';

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
begin
  if Trim(AText) = '' then
    Exit;
  FLock.Acquire;
  try
    SetLength(FItems, Length(FItems) + 1);
    FItems[High(FItems)] := AText;
  finally
    FLock.Release;
  end;
end;

function TPromptQueue.Drain: TPromptArray;
begin
  FLock.Acquire;
  try
    Result := FItems;
    FItems := nil;
  finally
    FLock.Release;
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

function TAgentLoop.BuildRequest(const APendingContent: string;
  AContinuing: Boolean): TChatRequest;
var
  N: Integer;
  Msg: TChatMessage;
begin
  Result := Default(TChatRequest);
  Result.Messages := FStore.Messages;
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
  Observer: TToolForwardObserver;
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
      { A per-call observer forwards the tool's chunks to the caller's event. }
      Observer := TToolForwardObserver.Create(ACalls[I].Id, ACalls[I].Name,
        AEvents.OnToolOutput);
      try
        try
          HandlerOk := Tool.Handler(ACalls[I].Arguments, ResultText,
            HandlerError, Observer);
        except
          on E: Exception do
          begin
            HandlerOk := False;
            HandlerError := E.Message;
          end;
        end;
      finally
        Observer.Complete;
        Observer.Free;
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

function ToolSoftNotice(ARound, AHard: Integer): string;
begin
  Result := Format('tool call limit notice: %d tool calls have been made this ' +
    'turn (hard limit %d). You may continue, but reconsider whether the call ' +
    'is still needed; if it is, resubmit the tool request now.',
    [ARound, AHard]);
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
  Result := DoSend(AUserText, AEvents, AAnswer, AError);
end;

procedure TAgentLoop.DrainQueued(const AEvents: TAgentEvents);
var
  Prompts: TPromptArray;
  I: Integer;
  Msg: TChatMessage;
begin
  Prompts := FPromptQueue.Drain;
  for I := 0 to High(Prompts) do
  begin
    Msg := Default(TChatMessage);
    Msg.Role := crUser;
    Msg.Content := Prompts[I];
    FStore.Append(Msg);
    if Assigned(AEvents.OnUserQueued) then
      AEvents.OnUserQueued(Prompts[I]);
  end;
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
      if not FClient.Complete(Request, OnTimedText, OnTimedReasoning,
        ChatResult, AError) then
      begin
        Outcome.Ok := False;
        Outcome.ErrorCode := AError.Code;
        Outcome.ErrorMessage := AError.Message;
        Outcome.ErrorDetail := AError.Detail;
        Outcome.DurationMs := Int64(GetTickCount64 - StartMs);
        FStore.FinishRequest(RequestId, Outcome);
        if (AError.Code = leCancelled) and (not Committed) then
        begin
          FStore.DropTurnMessages(TurnId);
          FLastTurnDropped := True;
        end;
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
    else if (Rounds >= FConfig.SoftToolLimit) and
      ((Rounds - FConfig.SoftToolLimit) mod FConfig.ToolNoticeStep = 0) then
      InterceptToolCalls(ChatResult.Message.ToolCalls,
        ToolSoftNotice(Rounds, FConfig.HardToolLimit), AEvents)
    else if TruncatedRound then
      InterceptToolCalls(ChatResult.Message.ToolCalls,
        TruncatedToolNotice, AEvents)
    else
      ExecuteToolCalls(ChatResult.Message.ToolCalls, AEvents, AllOk);
    Continue;
  end;
end;

initialization
  BuiltinTools := TBuiltinTools.Create;

finalization
  BuiltinTools.Free;

end.
