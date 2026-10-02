unit hildegard.helper.session;
{ Session identity and the persisted history model. A session id is a random
  128-bit value rendered as 32 lowercase hex characters.

  A session is a sequence of turns (loops): one user prompt pushed to the LLM
  until it returns a proper stop reason. A turn is made of requests (one LLM
  call each) and produces messages - the user prompt, assistant text, reasoning,
  tool calls, tool results, and errors - in chronological order.

  The record model lives here, free of the store, so both the store (which
  persists records) and the conversation adapter (which maps chat messages) can
  depend on it without a cycle. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, hildegard.helper.llm;

type
  { One block in a session's history. Tool calls are messages in their own
    right, so a tool call and its result are separate, ordered rows. }
  TMessageRole = (
    mrSystem, mrUser, mrAssistant, mrReasoning, mrToolCall, mrTool, mrError);

  TTurnStatus = (tsRunning, tsCompleted, tsFailed);

  TMessageRecord = record
    Id: Int64;
    SessionId: string;
    TurnId: Int64;          // 0 when not part of a turn (the system prompt)
    RequestId: Int64;       // 0 when not produced by a request
    Seq: Int64;
    Role: TMessageRole;
    Content: string;
    ToolCallId: string;
    ToolName: string;
    ToolArguments: string;
    ToolReason: string;
    ToolOk: Boolean;
    CreatedAtMs: Int64;
    DurationMs: Int64;
  end;

  TMessageRecordArray = array of TMessageRecord;

  TRequestRecord = record
    Id: Int64;
    TurnId: Int64;
    Seq: Int64;
    Model: string;
    MessageCount: Integer;
    FinishReason: string;
    Ok: Boolean;
    ErrorCode: Integer;
    ErrorMessage: string;
    ErrorDetail: string;
    Usage: TTokenUsage;
    CreatedAtMs: Int64;
    FinishedAtMs: Int64;
    DurationMs: Int64;
    FirstTokenMs: Int64;
  end;

  TRequestRecordArray = array of TRequestRecord;

  TTurnRecord = record
    Id: Int64;
    SessionId: string;
    Seq: Int64;
    Status: TTurnStatus;
    Prompt: string;         // derived: the turn's first user message
    FinishReason: string;
    ErrorCode: Integer;
    ErrorMessage: string;
    ErrorDetail: string;
    RequestCount: Integer;
    MessageCount: Integer;
    Usage: TTokenUsage;     // rolled up from the turn's requests
    CreatedAtMs: Int64;
    FinishedAtMs: Int64;
    DurationMs: Int64;
  end;

  TTurnRecordArray = array of TTurnRecord;

  { A session listing entry. }
  TSessionSummary = record
    Id: string;
    CreatedAtMs: Int64;
    UpdatedAtMs: Int64;
    MessageCount: Integer;
    TurnCount: Integer;
  end;

  TSessionSummaryArray = array of TSessionSummary;

{ A random 128-bit session id as 32 lowercase hex characters. }
function NewSessionId: string;

implementation

function NewSessionId: string;
const
  Hex = '0123456789abcdef';
var
  I, B: Integer;
begin
  SetLength(Result, 32);
  for I := 0 to 15 do
  begin
    B := Random(256);
    Result[I * 2 + 1] := Hex[(B shr 4) + 1];
    Result[I * 2 + 2] := Hex[(B and $0F) + 1];
  end;
end;

initialization
  Randomize;

end.
