unit hildegard.helper.session.store;
{ SQLite-backed IConversationStore. Persists the loop's chat messages through
  the session ledger and recomposes them on read, skipping non-essential
  records (reasoning, errors, events). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, hildegard.helper.agent, hildegard.helper.llm,
  hildegard.helper.store, hildegard.helper.session;

type
  TSqliteConversationStore = class(TInterfacedObject, IConversationStore)
  private
    FStore: TSqliteStore;
    FSessionId: string;
    FMaxMessages: Integer;   // 0 = all
    procedure Write(const AKind: TSessionRecordKind; const AContent,
      ADataJson: string);
    function Compose: TChatMessageArray;
  public
    { AMaxMessages > 0 keeps only the most recent AMaxMessages messages (after
      the system prompt), dropping leading orphaned tool results. }
    constructor Create(AStore: TSqliteStore; const ASessionId: string;
      AMaxMessages: Integer = 0);
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    { The ledger is the durable record; clearing it here would defeat restore.
      The loop never calls Clear; this is a no-op by design. }
    procedure Clear;
  end;

implementation

uses
  fpjson, jsonparser;

function ToolCallData(const ACall: TChatToolCall): string;
var
  Root: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('id', ACall.Id);
    Root.Add('name', ACall.Name);
    Root.Add('arguments', ACall.Arguments);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

function ToolResultData(const AToolCallId: string): string;
var
  Root: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('tool_call_id', AToolCallId);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

function FieldOf(const ADataJson, AName: string): string;
var
  Data: TJSONData;
  Obj: TJSONObject;
begin
  Result := '';
  Data := nil;
  try
    try
      Data := GetJSON(ADataJson);
    except
      Exit;
    end;
    if Data is TJSONObject then
    begin
      Obj := TJSONObject(Data);
      Result := Obj.Get(AName, '');
    end;
  finally
    Data.Free;
  end;
end;

procedure AppendMessage(var AList: TChatMessageArray;
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
end;

procedure TSqliteConversationStore.Write(const AKind: TSessionRecordKind;
  const AContent, ADataJson: string);
var
  Rec: TSessionRecord;
  Err: TStoreError;
begin
  Rec := Default(TSessionRecord);
  Rec.SessionId := FSessionId;
  Rec.Kind := AKind;
  Rec.Content := AContent;
  Rec.DataJson := ADataJson;
  { IConversationStore has no error channel; a failed append is dropped rather
    than raised into the loop. }
  FStore.AppendSessionRecord(Rec, Err);
end;

procedure TSqliteConversationStore.Append(const AMessage: TChatMessage);
var
  I: Integer;
begin
  case AMessage.Role of
    crSystem:
      Write(srkSystemMessage, AMessage.Content, '');
    crUser:
      Write(srkUserMessage, AMessage.Content, '');
    crAssistant:
      begin
        Write(srkAssistantMessage, AMessage.Content, '');
        for I := 0 to High(AMessage.ToolCalls) do
          Write(srkToolCall, '', ToolCallData(AMessage.ToolCalls[I]));
      end;
    crTool:
      Write(srkToolResult, AMessage.Content,
        ToolResultData(AMessage.ToolCallId));
  end;
end;

function TSqliteConversationStore.Compose: TChatMessageArray;
var
  Records: TSessionRecordArray;
  Err: TStoreError;
  I, J: Integer;
  Msg: TChatMessage;
  Call: TChatToolCall;
begin
  Result := nil;
  if not FStore.QuerySessionRecords(FSessionId, False, srkEvent, 0, 0, Records,
    Err) then
    Exit;
  I := 0;
  while I <= High(Records) do
  begin
    case Records[I].Kind of
      srkSystemMessage:
        begin
          Msg := Default(TChatMessage);
          Msg.Role := crSystem;
          Msg.Content := Records[I].Content;
          AppendMessage(Result, Msg);
        end;
      srkUserMessage:
        begin
          Msg := Default(TChatMessage);
          Msg.Role := crUser;
          Msg.Content := Records[I].Content;
          AppendMessage(Result, Msg);
        end;
      srkAssistantMessage:
        begin
          Msg := Default(TChatMessage);
          Msg.Role := crAssistant;
          Msg.Content := Records[I].Content;
          J := I + 1;
          while (J <= High(Records)) and (Records[J].Kind = srkToolCall) do
          begin
            Call := Default(TChatToolCall);
            Call.Id := FieldOf(Records[J].DataJson, 'id');
            Call.Name := FieldOf(Records[J].DataJson, 'name');
            Call.Arguments := FieldOf(Records[J].DataJson, 'arguments');
            SetLength(Msg.ToolCalls, Length(Msg.ToolCalls) + 1);
            Msg.ToolCalls[High(Msg.ToolCalls)] := Call;
            Inc(J);
          end;
          AppendMessage(Result, Msg);
          I := J - 1;
        end;
      srkToolResult:
        begin
          Msg := Default(TChatMessage);
          Msg.Role := crTool;
          Msg.Content := Records[I].Content;
          Msg.ToolCallId := FieldOf(Records[I].DataJson, 'tool_call_id');
          AppendMessage(Result, Msg);
        end;
      { Tool calls are consumed with their assistant message above. }
      srkToolCall, srkReasoning, srkError, srkEvent:
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
    AppendMessage(Result, All[I]);
end;

procedure TSqliteConversationStore.Clear;
begin
  // no-op: the ledger is durable history, see the class comment
end;

end.
