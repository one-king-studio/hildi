unit hildegard.helper.session;
{ Session identity and ledger record model. A session id is a random 128-bit
  value rendered as 32 lowercase hex characters. The ledger is an append-only
  sequence of typed records (messages, reasoning, tool calls/results, errors).

  The record model lives here, free of the store, so both the store (which
  persists records) and the conversation adapter (which maps chat messages) can
  depend on it without a cycle. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TSessionRecordKind = (
    srkSystemMessage, srkUserMessage, srkAssistantMessage,
    srkReasoning, srkToolCall, srkToolResult, srkError, srkEvent);

  TSessionRecord = record
    Id: Int64;
    SessionId: string;
    Seq: Int64;
    Kind: TSessionRecordKind;
    Content: string;      // text payload (message text, result text)
    DataJson: string;     // structured payload (tool name/id, arguments, ...)
    CreatedAtMs: Int64;
  end;

  TSessionRecordArray = array of TSessionRecord;

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
