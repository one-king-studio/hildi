unit hildegard.helper.session.store;
{ SQLite-backed IConversationStore. Persists the loop's chat messages as history
  blocks (user, assistant, reasoning, tool call, tool, error), tracks the
  current turn/request so each block is linked, and recomposes the conversation
  for the provider on read (reasoning and errors are never sent). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, hildegard.helper.agent, hildegard.helper.llm,
  hildegard.helper.store, hildegard.helper.session,
  hildegard.helper.recall.tool, hildegard.helper.ambient;

type
  TSqliteConversationStore = class(TInterfacedObject, IConversationStore)
  private
    FStore: TSqliteStore;
    FSessionId: string;
    FMaxMessages: Integer;   // 0 = all
    FToolResultCap: Integer; // 0 = no cap
    FCurrentTurnId: Int64;
    FCurrentRequestId: Int64;
    procedure Write(const ARole: TMessageRole; const AContent,
      AToolCallId, AToolName, AToolArguments, AToolReason: string;
      AToolOk: Boolean; ADurationMs: Int64);
    function CapToolResult(const ARec: TMessageRecord): string;
    function Compose: TChatMessageArray;
  public
    { AMaxMessages > 0 keeps only the most recent AMaxMessages messages (after
      the system prompt), dropping leading orphaned tool results. }
    constructor Create(AStore: TSqliteStore; const ASessionId: string;
      AMaxMessages: Integer = 0);
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    { The history is durable; clearing it here would defeat restore. The loop
      never calls Clear; this is a no-op by design. }
    procedure Clear;
    procedure AppendReasoning(const AText: string; ADurationMs: Int64);
    procedure AppendError(const AMessage, ADetail: string);
    procedure AppendAmbient(const AText, ARefSessionId, ALabel,
      ASource: string; AElapsedMs: Int64);
    function BeginTurn: Int64;
    function BeginRequest(ATurnId: Int64; const AModel: string;
      AMessageCount: Integer): Int64;
    procedure FinishRequest(ARequestId: Int64; const AOutcome: TRequestOutcome);
    procedure FinishTurn(ATurnId: Int64; const AOutcome: TTurnOutcome);
    procedure DropTurnMessages(ATurnId: Int64);
    { Bytes a tool result may contribute to the prompt; over the cap the prompt
      carries a head plus a marker naming the artifact and the recall tool. 0
      (or less) leaves tool results uncapped. Storage is never affected. }
    property ToolResultCap: Integer read FToolResultCap write FToolResultCap;
  end;

implementation

procedure AddMessage(var AList: TChatMessageArray;
  const AMessage: TChatMessage);
begin
  SetLength(AList, Length(AList) + 1);
  AList[High(AList)] := AMessage;
end;

constructor TSqliteConversationStore.Create(AStore: TSqliteStore;
  const ASessionId: string; AMaxMessages: Integer);
begin
  inherited Create;
  FStore := AStore;
  FSessionId := ASessionId;
  FMaxMessages := AMaxMessages;
  FToolResultCap := 0;
  FCurrentTurnId := 0;
  FCurrentRequestId := 0;
end;

function TSqliteConversationStore.CapToolResult(
  const ARec: TMessageRecord): string;
begin
  Result := ARec.Content;
  if (FToolResultCap <= 0) or (Length(Result) <= FToolResultCap) then
    Exit;
  Result := Copy(Result, 1, FToolResultCap) + LineEnding +
    ToolResultTruncationMarker(ARec.Id, Length(ARec.Content));
end;

procedure TSqliteConversationStore.Write(const ARole: TMessageRole;
  const AContent, AToolCallId, AToolName, AToolArguments, AToolReason: string;
  AToolOk: Boolean; ADurationMs: Int64);
var
  Rec: TMessageRecord;
  Err: TStoreError;
begin
  Rec := Default(TMessageRecord);
  Rec.SessionId := FSessionId;
  Rec.TurnId := FCurrentTurnId;
  Rec.RequestId := FCurrentRequestId;
  Rec.Role := ARole;
  Rec.Content := AContent;
  Rec.ToolCallId := AToolCallId;
  Rec.ToolName := AToolName;
  Rec.ToolArguments := AToolArguments;
  Rec.ToolReason := AToolReason;
  Rec.ToolOk := AToolOk;
  Rec.DurationMs := ADurationMs;
  { IConversationStore has no error channel; a failed append is dropped rather
    than raised into the loop. }
  FStore.AppendMessage(Rec, Err);
end;

procedure TSqliteConversationStore.Append(const AMessage: TChatMessage);
var
  I: Integer;
  Reason, ReasonError: string;
begin
  case AMessage.Role of
    crSystem:
      Write(mrSystem, AMessage.Content, '', '', '', '', False, 0);
    crUser:
      Write(mrUser, AMessage.Content, '', '', '', '', False, 0);
    crAssistant:
      begin
        { An assistant message that only carried tool calls has no content, so
          it is not persisted as an empty row; Compose synthesises it on read
          from the tool calls that follow. }
        if AMessage.Content <> '' then
          Write(mrAssistant, AMessage.Content, '', '', '', '', False,
            AMessage.DurationMs);
        for I := 0 to High(AMessage.ToolCalls) do
        begin
          Reason := '';
          ExtractToolReason(AMessage.ToolCalls[I].Arguments, Reason,
            ReasonError);
          Write(mrToolCall, '', AMessage.ToolCalls[I].Id,
            AMessage.ToolCalls[I].Name, AMessage.ToolCalls[I].Arguments,
            Reason, False, 0);
        end;
      end;
    crTool:
      Write(mrTool, AMessage.Content, AMessage.ToolCallId, AMessage.ToolName,
        '', '', AMessage.ToolOk, AMessage.DurationMs);
  end;
end;

procedure TSqliteConversationStore.AppendReasoning(const AText: string;
  ADurationMs: Int64);
begin
  if AText <> '' then
    Write(mrReasoning, AText, '', '', '', '', False, ADurationMs);
end;

procedure TSqliteConversationStore.AppendError(const AMessage,
  ADetail: string);
begin
  Write(mrError, AMessage, '', '', ADetail, '', False, 0);
end;

procedure TSqliteConversationStore.AppendAmbient(const AText, ARefSessionId,
  ALabel, ASource: string; AElapsedMs: Int64);
var
  Rec: TMessageRecord;
  Err: TStoreError;
begin
  Rec := Default(TMessageRecord);
  Rec.SessionId := FSessionId;
  Rec.TurnId := FCurrentTurnId;
  Rec.RequestId := FCurrentRequestId;
  Rec.Role := mrAmbient;
  Rec.Content := AText;
  Rec.RefSessionId := ARefSessionId;
  Rec.LabelText := ALabel;
  Rec.Source := ASource;
  Rec.DurationMs := AElapsedMs;
  FStore.AppendMessage(Rec, Err);
end;

function TSqliteConversationStore.BeginTurn: Int64;
var
  Err: TStoreError;
begin
  Result := 0;
  if FStore.BeginTurn(FSessionId, Result, Err) then
    FCurrentTurnId := Result
  else
    FCurrentTurnId := 0;
  FCurrentRequestId := 0;
end;

function TSqliteConversationStore.BeginRequest(ATurnId: Int64;
  const AModel: string; AMessageCount: Integer): Int64;
var
  Err: TStoreError;
begin
  Result := 0;
  if FStore.BeginRequest(ATurnId, AModel, AMessageCount, Result, Err) then
    FCurrentRequestId := Result
  else
    FCurrentRequestId := 0;
end;

procedure TSqliteConversationStore.FinishRequest(ARequestId: Int64;
  const AOutcome: TRequestOutcome);
var
  Err: TStoreError;
begin
  FStore.FinishRequest(ARequestId, AOutcome.Ok, AOutcome.RawFinishReason,
    Ord(AOutcome.ErrorCode), AOutcome.ErrorMessage, AOutcome.ErrorDetail,
    AOutcome.Usage, AOutcome.DurationMs, AOutcome.FirstTokenMs, Err);
end;

procedure TSqliteConversationStore.FinishTurn(ATurnId: Int64;
  const AOutcome: TTurnOutcome);
var
  Err: TStoreError;
begin
  FStore.FinishTurn(ATurnId, AOutcome.Status, AOutcome.FinishReason,
    Ord(AOutcome.ErrorCode), AOutcome.ErrorMessage, AOutcome.ErrorDetail, Err);
  FCurrentTurnId := 0;
  FCurrentRequestId := 0;
end;

procedure TSqliteConversationStore.DropTurnMessages(ATurnId: Int64);
var
  Err: TStoreError;
begin
  if ATurnId > 0 then
    FStore.DeleteTurnMessages(ATurnId, Err);
end;

function TSqliteConversationStore.Compose: TChatMessageArray;
var
  Msgs: TMessageRecordArray;
  Err: TStoreError;
  I, J: Integer;
  Msg: TChatMessage;
  Call: TChatToolCall;
begin
  Result := nil;
  if not FStore.QueryMessages(FSessionId, Msgs, Err) then
    Exit;
  I := 0;
  while I <= High(Msgs) do
  begin
    case Msgs[I].Role of
      mrSystem:
        begin
          Msg := Default(TChatMessage);
          Msg.Role := crSystem;
          Msg.Content := Msgs[I].Content;
          AddMessage(Result, Msg);
        end;
      mrUser:
        begin
          Msg := Default(TChatMessage);
          Msg.Role := crUser;
          Msg.Content := Msgs[I].Content;
          AddMessage(Result, Msg);
        end;
      mrAmbient:
        begin
          { Delivered to the provider as a user message wrapped by the ambient
            format; the persisted record stays plain. }
          Msg := Default(TChatMessage);
          Msg.Role := crUser;
          Msg.Content := FormatAmbient(Msgs[I].Content,
            Msgs[I].RefSessionId, Msgs[I].LabelText, Msgs[I].Source,
            Msgs[I].CreatedAtMs);
          AddMessage(Result, Msg);
        end;
      mrAssistant:
        begin
          Msg := Default(TChatMessage);
          Msg.Role := crAssistant;
          Msg.Content := Msgs[I].Content;
          J := I + 1;
          while (J <= High(Msgs)) and (Msgs[J].Role = mrToolCall) do
          begin
            Call := Default(TChatToolCall);
            Call.Id := Msgs[J].ToolCallId;
            Call.Name := Msgs[J].ToolName;
            Call.Arguments := Msgs[J].ToolArguments;
            SetLength(Msg.ToolCalls, Length(Msg.ToolCalls) + 1);
            Msg.ToolCalls[High(Msg.ToolCalls)] := Call;
            Inc(J);
          end;
          AddMessage(Result, Msg);
          I := J - 1;
        end;
      mrToolCall:
        begin
          { A run of tool calls with no preceding assistant row: the assistant
            message had no content, so it was not persisted. Synthesise it. }
          Msg := Default(TChatMessage);
          Msg.Role := crAssistant;
          J := I;
          while (J <= High(Msgs)) and (Msgs[J].Role = mrToolCall) do
          begin
            Call := Default(TChatToolCall);
            Call.Id := Msgs[J].ToolCallId;
            Call.Name := Msgs[J].ToolName;
            Call.Arguments := Msgs[J].ToolArguments;
            SetLength(Msg.ToolCalls, Length(Msg.ToolCalls) + 1);
            Msg.ToolCalls[High(Msg.ToolCalls)] := Call;
            Inc(J);
          end;
          AddMessage(Result, Msg);
          I := J - 1;
        end;
      mrTool:
        begin
          Msg := Default(TChatMessage);
          Msg.Role := crTool;
          Msg.Content := CapToolResult(Msgs[I]);
          Msg.ToolCallId := Msgs[I].ToolCallId;
          Msg.ToolName := Msgs[I].ToolName;
          Msg.ToolOk := Msgs[I].ToolOk;
          Msg.DurationMs := Msgs[I].DurationMs;
          AddMessage(Result, Msg);
        end;
      { Tool calls are consumed with their assistant message above, or
        synthesised when the assistant had no content. }
      mrReasoning, mrError:
        ;   // not part of the restored conversation
    end;
    Inc(I);
  end;
end;

function TSqliteConversationStore.Messages: TChatMessageArray;
var
  All: TChatMessageArray;
  I, SysCount, RestCount, Start: Integer;
begin
  All := Compose;
  if (FMaxMessages <= 0) or (Length(All) <= FMaxMessages) then
    Exit(All);

  { Keep every leading system message, then the last FMaxMessages of the rest. }
  I := 0;
  while (I <= High(All)) and (All[I].Role = crSystem) do
    Inc(I);
  SysCount := I;
  RestCount := Length(All) - SysCount;
  if RestCount <= FMaxMessages then
    Exit(All);

  Start := SysCount + (RestCount - FMaxMessages);
  { Starting mid-turn can orphan tool results; drop them. }
  while (Start < Length(All)) and (All[Start].Role = crTool) do
    Inc(Start);

  Result := Copy(All, 0, SysCount);
  for I := Start to High(All) do
    AddMessage(Result, All[I]);
end;

procedure TSqliteConversationStore.Clear;
begin
  // no-op: the history is durable, see the class comment
end;

end.
