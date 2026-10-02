# Component Specification: Sessions and Ledger v2

**Related Feature:** [FEATURE.md](FEATURE.md)
**Supersedes:** `Sessions_v1.SPEC.md` (the flat `session_records` ledger)

## Purpose

Define the relational session history - sessions, turns (loops), requests, and
messages - the store operations over it, the small seam the agent loop uses to
collect it, the normalised token usage the LLM client now parses, and the
restore/render path that brings a session back exactly as it streamed.

This is a **full schema reset**: the v1 ledger (`session_records`,
`TSessionRecord`) is deleted and the schema is defined fresh. There are no
data-preserving migrations; a database at a newer version than this build is
rejected with an actionable message.

## Requirements

### Functional

- [ ] Create `turns`, `requests`, and `messages`; keep `workspaces`,
      `sessions`, `credentials`, `settings`, and `approvals`.
- [ ] `sessions.workspace_id` and `messages.session_id` are foreign keys with
      `ON DELETE CASCADE`; `foreign_keys` is already ON.
- [ ] A turn is opened per user prompt and closed as completed or failed, with
      its request/message counts, rolled-up usage, duration, and outcome.
- [ ] A request is opened per LLM call and closed with its model, message
      count, finish reason, outcome/error, usage, duration, and
      time-to-first-token.
- [ ] A message records session, turn, request, role, content, tool fields
      (call id, name, arguments, reason, ok), created time, and duration.
- [ ] Message roles: system, user, assistant, reasoning, tool call, tool,
      error. Tool calls are ordered messages in their own right.
- [ ] `TSqliteStore` exposes typed operations for session create/exists/touch/
      list/most-recent, turn begin/finish/query, request begin/finish/query, and
      message append/query.
- [ ] `TSqliteConversationStore` implements `IConversationStore`, mapping chat
      messages to rows, tracking the current turn/request, and recomposing the
      conversation for the provider.
- [ ] `IConversationStore` gains the audit seam: `AppendReasoning`,
      `AppendError`, `BeginTurn`, `BeginRequest`, `FinishRequest`, `FinishTurn`.
      The in-memory store ignores the audit calls.
- [ ] The loop brackets each turn and request and persists reasoning and error
      blocks.
- [ ] The LLM client parses `usage` into `TTokenUsage` and records
      time-to-first-token; the request body asks the provider to include usage.
- [ ] The TUI restores user, assistant, reasoning, tool (titled by reason, with
      its result), error, and system blocks.
- [ ] Remove `TSessionRecordKind`, `TSessionRecord`, `TSessionRecordArray`,
      `AppendSessionRecord`, and `QuerySessionRecords`.

### Non-Functional

- [ ] Leak-clean; indexed appends and reads; no SQL outside the store.
- [ ] The loop stays provider-agnostic; it never sees SQL.
- [ ] The history inherits the store's owner-only file permissions and is never
      logged.
- [ ] `make check` green.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

### LLM additions (`hildegard.helper.llm`)

```pascal
type
  { Normalised token accounting, one shape across provider spellings. }
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

  TChatResult = record
    Message: TChatMessage;
    FinishReason: TFinishReason;
    RawFinishReason: string;
    ReasoningContent: string;
    Usage: TTokenUsage;
    FirstTokenMs: Int64;         // 0 when no content/reasoning arrived
  end;

  { crTool-only display/audit fields; never sent to the provider. }
  TChatMessage = record
    Role: TChatRole;
    Content: string;
    ToolCallId: string;
    ToolCalls: array of TChatToolCall;
    ToolName: string;            // the tool a tool result came from
    ToolOk: Boolean;             // whether it succeeded
    DurationMs: Int64;           // tool execution time
  end;

  TLLMClient = class
    ...
    property Model: string read GetModel;   // the resolved model name
  end;
```

`BuildRequestBody` adds `"stream_options": {"include_usage": true}`.

### Session model (`hildegard.helper.session`)

```pascal
unit hildegard.helper.session;

interface

uses
  SysUtils, hildegard.helper.llm;

type
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

function NewSessionId: string;
```

### Store operations (`hildegard.helper.store`)

```pascal
function TSqliteStore.CreateSession(AWorkspaceId: Integer; out AId: string;
  out AError: TStoreError): Boolean;
function TSqliteStore.SessionExists(const AId: string;
  out AError: TStoreError): Boolean;
function TSqliteStore.TouchSession(const AId: string;
  out AError: TStoreError): Boolean;
function TSqliteStore.ListSessions(AWorkspaceId: Integer;
  out AList: TSessionSummaryArray; out AError: TStoreError): Boolean;
function TSqliteStore.MostRecentSessionId(AWorkspaceId: Integer;
  out AId: string; out AError: TStoreError): Boolean;

function TSqliteStore.BeginTurn(const ASessionId: string; out ATurnId: Int64;
  out AError: TStoreError): Boolean;
function TSqliteStore.FinishTurn(ATurnId: Int64; AStatus: TTurnStatus;
  const AFinishReason: string; AErrorCode: Integer;
  const AErrorMessage, AErrorDetail: string;
  out AError: TStoreError): Boolean;
function TSqliteStore.QueryTurns(const ASessionId: string;
  out ATurns: TTurnRecordArray; out AError: TStoreError): Boolean;

function TSqliteStore.BeginRequest(ATurnId: Int64; const AModel: string;
  AMessageCount: Integer; out ARequestId: Int64;
  out AError: TStoreError): Boolean;
function TSqliteStore.FinishRequest(ARequestId: Int64; AOk: Boolean;
  const AFinishReason: string; AErrorCode: Integer;
  const AErrorMessage, AErrorDetail: string; const AUsage: TTokenUsage;
  ADurationMs, AFirstTokenMs: Int64; out AError: TStoreError): Boolean;
function TSqliteStore.QueryRequests(ATurnId: Int64;
  out ARequests: TRequestRecordArray; out AError: TStoreError): Boolean;

function TSqliteStore.AppendMessage(const AMessage: TMessageRecord;
  out AError: TStoreError): Boolean;
function TSqliteStore.QueryMessages(const ASessionId: string;
  out AMessages: TMessageRecordArray; out AError: TStoreError): Boolean;
```

Removed: `TSessionRecordKind`, `TSessionRecord`, `TSessionRecordArray`,
`AppendSessionRecord`, `QuerySessionRecords`. `TSessionSummary.RecordCount`
becomes `MessageCount` (+ `TurnCount`).

### Agent seam (`hildegard.helper.agent`)

```pascal
type
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

  TTurnOutcome = record
    Status: TTurnStatus;
    FinishReason: string;
    ErrorCode: TLLMErrorCode;
    ErrorMessage: string;
    ErrorDetail: string;
  end;

  IConversationStore = interface
    { Conversation (LLM-visible). }
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    procedure Clear;
    { Display-only blocks: persisted for restore, never sent to the provider. }
    procedure AppendReasoning(const AText: string);
    procedure AppendError(const AMessage, ADetail: string);
    { Turn/request audit. Ids are 0 when the implementation does not persist. }
    function BeginTurn: Int64;
    function BeginRequest(ATurnId: Int64; const AModel: string;
      AMessageCount: Integer): Int64;
    procedure FinishRequest(ARequestId: Int64; const AOutcome: TRequestOutcome);
    procedure FinishTurn(ATurnId: Int64; const AOutcome: TTurnOutcome);
  end;
```

### SQLite adapter (`hildegard.helper.session.store`)

```pascal
type
  TSqliteConversationStore = class(TInterfacedObject, IConversationStore)
  private
    FStore: TSqliteStore;
    FSessionId: string;
    FMaxMessages: Integer;      // 0 = all
    FCurrentTurnId: Int64;
    FCurrentRequestId: Int64;
  public
    constructor Create(AStore: TSqliteStore; const ASessionId: string;
      AMaxMessages: Integer = 0);
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    procedure Clear;                       // no-op: durable history
    procedure AppendReasoning(const AText: string);
    procedure AppendError(const AMessage, ADetail: string);
    function BeginTurn: Int64;
    function BeginRequest(ATurnId: Int64; const AModel: string;
      AMessageCount: Integer): Int64;
    procedure FinishRequest(ARequestId: Int64; const AOutcome: TRequestOutcome);
    procedure FinishTurn(ATurnId: Int64; const AOutcome: TTurnOutcome);
  end;
```

### Harness additions

```pascal
type
  THarnessSession = class
    ...
    { Prior message blocks for the initial render (empty for a new session). }
    function History: TMessageRecordArray;
  end;

  THarnessApp = class
    ...
    procedure RenderHistory;   // maps TMessageRecord -> chat blocks
  end;
```

### Data Contracts

Chat-message-to-row mapping (`Append`), linked to the current turn/request:

| `TChatMessage` | Rows written |
| --- | --- |
| `crSystem` | `mrSystem` (content) |
| `crUser` | `mrUser` (content) |
| `crAssistant` | `mrAssistant` (content) + one `mrToolCall` per call, in order: `tool_call_id`, `tool_name`, `tool_arguments`, `tool_reason` (extracted from the arguments), `tool_ok = 0` |
| `crTool` | `mrTool`: `tool_call_id`, `tool_name`, `tool_ok`, `duration_ms`, content |

`AppendReasoning` writes `mrReasoning`; `AppendError` writes `mrError`
(content = message, `tool_arguments` = detail). Both carry the current turn and
request.

Row-to-message recomposition (`Messages`), in `seq` order:

- `mrSystem` -> `crSystem`; `mrUser` -> `crUser`.
- `mrAssistant` -> `crAssistant`, attaching the `mrToolCall` rows that follow it
  (by `seq`) as `ToolCalls` (`id`, `name`, `arguments`).
- `mrTool` -> `crTool` with `ToolCallId`, `ToolName`, `ToolOk`, `DurationMs`.
- `mrReasoning`, `mrError` -> skipped (never sent to the provider).

`Seq` is `max(seq) + 1` per session (messages) or per turn (requests) or per
session (turns), assigned inside the insert.

### Schema

```sql
CREATE TABLE workspaces (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE turns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  status INTEGER NOT NULL,                  -- 0 running, 1 completed, 2 failed
  finish_reason TEXT NOT NULL DEFAULT '',
  error_code INTEGER NOT NULL DEFAULT 0,
  error_message TEXT NOT NULL DEFAULT '',
  error_detail TEXT NOT NULL DEFAULT '',
  request_count INTEGER NOT NULL DEFAULT 0,
  message_count INTEGER NOT NULL DEFAULT 0,
  prompt_tokens INTEGER NOT NULL DEFAULT 0,
  completion_tokens INTEGER NOT NULL DEFAULT 0,
  total_tokens INTEGER NOT NULL DEFAULT 0,
  cached_tokens INTEGER NOT NULL DEFAULT 0,
  reasoning_tokens INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  finished_at INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  UNIQUE (session_id, seq)
);

CREATE TABLE requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  turn_id INTEGER NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  model TEXT NOT NULL DEFAULT '',
  message_count INTEGER NOT NULL DEFAULT 0,
  finish_reason TEXT NOT NULL DEFAULT '',
  ok INTEGER NOT NULL DEFAULT 0,
  error_code INTEGER NOT NULL DEFAULT 0,
  error_message TEXT NOT NULL DEFAULT '',
  error_detail TEXT NOT NULL DEFAULT '',
  prompt_tokens INTEGER NOT NULL DEFAULT 0,
  completion_tokens INTEGER NOT NULL DEFAULT 0,
  total_tokens INTEGER NOT NULL DEFAULT 0,
  cached_tokens INTEGER NOT NULL DEFAULT 0,
  reasoning_tokens INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  finished_at INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  first_token_ms INTEGER NOT NULL DEFAULT 0,
  UNIQUE (turn_id, seq)
);

CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  turn_id INTEGER REFERENCES turns(id) ON DELETE CASCADE,
  request_id INTEGER REFERENCES requests(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  role INTEGER NOT NULL,   -- 0 system, 1 user, 2 assistant, 3 reasoning,
                           -- 4 tool_call, 5 tool, 6 error
  content TEXT NOT NULL DEFAULT '',
  tool_call_id TEXT NOT NULL DEFAULT '',
  tool_name TEXT NOT NULL DEFAULT '',
  tool_arguments TEXT NOT NULL DEFAULT '',
  tool_reason TEXT NOT NULL DEFAULT '',
  tool_ok INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  UNIQUE (session_id, seq)
);

CREATE INDEX idx_turns_session ON turns (session_id, seq);
CREATE INDEX idx_requests_turn ON requests (turn_id, seq);
CREATE INDEX idx_messages_session ON messages (session_id, seq);
CREATE INDEX idx_messages_turn ON messages (turn_id, seq);
CREATE INDEX idx_messages_request ON messages (request_id);
```

The whole schema is one migration, `Version := 1`. `ApplyMigrations` rejects a
database whose `user_version` is greater than the highest migration version,
with `seMigrationFailed` and a message naming the path and asking for deletion.

## Architecture

### Prior Art & Reuse

- `hildegard.helper.store` - the serialized connection, migration machinery,
  parameterized `TStmt` helper, and 0600 file permissions are reused unchanged.
- `hildegard.helper.llm` - the SSE parser is extended to read `usage`; the
  transport, request builder, and message types are reused.
- `hildegard.helper.session` - `NewSessionId` is reused; the record model is
  replaced.
- `hildegard.helper.tui.chat` - `TChatStream`/`TChatItem` are reused for
  rendering; no new widget is needed.
- `TSessionSummary`, `ListSessions`, `MostRecentSessionId`, `TouchSession`,
  `CreateSession`, and `SessionExists` keep their shape.

### Component Boundaries

- **`hildegard.helper.llm`** owns provider shape: it parses usage and timings
  and normalises them; it knows nothing about persistence.
- **`hildegard.helper.session`** owns the persisted record model and session
  identity; it has no store or agent dependency.
- **`hildegard.helper.store`** owns SQL and the schema; it knows nothing about
  the loop.
- **`hildegard.helper.agent`** owns the loop and the seam; it knows nothing
  about SQL or the provider's JSON shape.
- **`hildegard.helper.session.store`** adapts chat messages to rows and the
  seam to store operations; it is the only place the two meet.
- **`hildegard.helper.harness.*`** bootstraps and renders; it reads blocks.

### Data Flow

1. The harness/CLI opens a store, ensures a workspace, and selects or creates a
   session.
2. It builds `TSqliteConversationStore` and passes it to the loop.
3. `TAgentLoop.DoSend` appends the system prompt (once) and the user message,
   calls `BeginTurn`, then for each iteration calls `BeginRequest`, `Complete`,
   `AppendReasoning`, `Append`, `FinishRequest`, and finally `FinishTurn`.
4. Each append/audit call is one indexed insert/update through the store.
5. On resume, `Messages` recomposes the provider conversation and
   `QueryMessages` supplies the render blocks; `QueryTurns`/`QueryRequests`
   supply metrics.

### Integration Patterns

- Synchronous, single-threaded loop. The store serializes its own connection;
  the adapter is created and used on the loop's thread.
- The in-memory store implements the seam as no-ops (ids 0), so a session
  without a store behaves exactly as before.

## Validation Rules

- A session id is exactly 32 lowercase hex characters; an unknown id is
  rejected before the loop starts.
- `BeginRequest` requires an existing turn; `BeginTurn` an existing session.
- `Seq` is strictly increasing within its scope.
- A database at a newer schema version than this build is rejected, not opened.
- `ToolOk` is stored as 0/1.

## Error Handling

### Error Types

- **Store:** any statement failure returns `TStoreError`; `seNotFound` for an
  unknown session/turn/request; `seMigrationFailed` for an incompatible
  database.
- **Adapter:** `IConversationStore` has no error channel; a failed write is
  dropped rather than raised into the loop, exactly as in v1. The audit calls
  likewise swallow store errors.
- **Loop:** an LLM failure closes the request and the turn as failed with the
  error code/message/detail recorded, and returns the error to the caller.

## Testing Requirements

### LLM (`tests/test_llm.pas`)

- [ ] `TestParsesOpenAIUsage` - prompt/completion/total + cached details.
- [ ] `TestParsesDeepSeekUsage` - prompt cache hit and reasoning tokens.
- [ ] `TestParsesAnthropicUsageSpellings` - input/output and cache read.
- [ ] `TestUsageAbsentIsZero`.
- [ ] `TestFirstTokenMsSetOnFirstDelta`.
- [ ] `TestRequestAsksForUsage`.

### Session model (`tests/test_session.pas`)

- [ ] `TestNewSessionIdIs32LowercaseHex`, `TestNewSessionIdIsUnique`.

### Store (`tests/test_store.pas`)

- [ ] `TestSchemaHasTheSessionTables` - turns/requests/messages exist,
      session_records gone.
- [ ] `TestTurnRequestMessageRoundTrip` - begin/finish/append/query.
- [ ] `TestTurnRollupSumsRequests`.
- [ ] `TestMessageSeqIsPerSession`.
- [ ] `TestRequestSeqIsPerTurn`.
- [ ] `TestBeginRequestUnknownTurnFails`.
- [ ] `TestAppendMessageUnknownSessionFails`.
- [ ] `TestQueryTurnsDerivesPrompt`.
- [ ] `TestNewerSchemaVersionIsRejected`.
- [ ] `TestListSessionsCountsMessagesAndTurns`.

### Adapter (`tests/test_session.pas`)

- [ ] `TestAppendMapsRolesAndToolFields`.
- [ ] `TestMessagesRoundTripMatchesAppended`.
- [ ] `TestRestoreSkipsReasoningAndErrors`.
- [ ] `TestRestoreAfterReopen`.
- [ ] `TestToolCallResultCorrelatedByToolCallId`.
- [ ] `TestTailKeepsSystemAndRecent`, `TestTailDropsOrphanTools`.
- [ ] `TestBeginFinishTurnAndRequestRecorded`.
- [ ] `TestQueryMessagesReturnsAllBlocks`.

### Loop (`tests/test_agent.pas`)

- [ ] `TestSendOpensAndClosesATurn`.
- [ ] `TestSendRecordsReasoningAndError`.
- [ ] `TestSendRecordsRequestOutcome`.
- [ ] `TestToolResultCarriesNameOkAndDuration`.

### Harness (`tests/test_harness_session.pas`, `tests/test_harness_app.pas`)

- [ ] `TestHistoryRestoresBlocks` (role, content, tool reason).
- [ ] `TestRenderHistoryRestoresToolBlocks` (call titled by reason, result
      appended; reasoning and error blocks).

### Leak

- [ ] The whole suite passes `make test-leak`.

## Performance Targets

- One indexed insert per message/request/turn; one ordered query per load; one
  statement per turn rollup. No full-table scans.

## Security Considerations

- The history holds conversation content, tool arguments, and tool output; it
  may be sensitive. No logging; owner-only file permissions are already
  enforced. Usage and timings are not sensitive but are stored alongside.

## Success Criteria

### Functional

- [ ] Contracts implemented; the loop collects turns/requests/messages/metrics.
- [ ] Restore reproduces the streamed blocks; the CLI still resumes.
- [ ] The v1 ledger API is removed; `make check` passes.

### Quality

- [ ] Recomposed messages equal what the loop appended.
- [ ] No leaks; no SQL outside the store.

## Future Considerations

- Tool output budget: cap and spill tool results, plus a `recall_tool_result`
  tool (see `../Context_Budget/`).
- A stats view over turns/requests.
- Retention/compaction and archival.
- Remote mirroring of sessions.
