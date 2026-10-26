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
    mrSystem, mrUser, mrAssistant, mrReasoning, mrToolCall, mrTool, mrError,
    { An ambient notification: a subagent's result delivered back to the parent.
      Appended last so stored ordinals are unchanged. }
    mrAmbient);

  { tsUndone is APPENDED, never inserted: the status is persisted as its
    ordinal, so a new member in the middle would silently reinterpret every
    existing turn row. tsUndone is distinct from tsCancelled because they answer
    different questions - cancelled is "the turn was interrupted, it may be
    partly in effect", undone is "the turn completed and its files were put
    back". Only the second may be excluded from the current context. }
  TTurnStatus = (tsRunning, tsCompleted, tsFailed, tsCancelled, tsUndone);

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
    { Ambient (v4/v5/v6): for an mrAmbient record, the producing task's
      identity and outcome. RefSessionId is the task's id; LabelText, Source,
      and Status describe it. '' otherwise. }
    RefSessionId: string;
    LabelText: string;
    Source: string;
    Status: string;
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
    { The context window in play: a turn's own is 0 (unused); a session
      aggregate sets it to the largest prompt it ever sent. }
    ContextTokens: Int64;
    CreatedAtMs: Int64;
    FinishedAtMs: Int64;
    DurationMs: Int64;
  end;

  TTurnRecordArray = array of TTurnRecord;

  { A context-checkpoint checkpoint (keyframe): a summary standing in for every
    message up to and including Seq. Messages after Seq are the active window. }
  TCheckpointRecord = record
    SessionId: string;
    Seq: Int64;            // boundary: messages with seq <= Seq are archived
    Summary: string;       // the checkpoint document (prose)
    CreatedAtMs: Int64;
  end;

  TCheckpointArray = array of TCheckpointRecord;

  { A session listing entry. }
  TSessionSummary = record
    Id: string;
    CreatedAtMs: Int64;
    UpdatedAtMs: Int64;
    MessageCount: Integer;
    TurnCount: Integer;
    { Lineage (v3). A root session has ParentId = '' and Depth = 0. }
    ParentId: string;
    Depth: Integer;
    LabelText: string;
  end;

  TSessionSummaryArray = array of TSessionSummary;

  { A session row resolved for the /sessions modal: its title (override else
    extracted), its latest reply's keywords, and its lifecycle flags. }
  TSessionRow = record
    Id: string;
    Title: string;
    Keywords: TStringArray;
    Pinned: Boolean;
    Archived: Boolean;
    UpdatedAtMs: Int64;
    { Lineage. A root session has ParentSessionId='' and Depth=0; a delegated
      child carries the session that spawned it, so a list can render it UNDER
      its parent instead of as a peer. }
    ParentSessionId: string;
    Depth: Integer;
    LabelText: string;
  end;

  TSessionRowArray = array of TSessionRow;

  { A session's live runtime row (migration v2). Advisory: discovery and
    display only - the socket, not this row, is the authority on liveness. }
  TSessionRuntimeStatus = (rsRunning, rsExited);

  TSessionRuntimeRow = record
    SessionId: string;
    Pid: Integer;
    SocketPath: string;
    Status: TSessionRuntimeStatus;
    StartedAt: Int64;
    UpdatedAt: Int64;
  end;

  TSessionRuntimeRowArray = array of TSessionRuntimeRow;

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
