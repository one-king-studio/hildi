# Component Specification: Sessions and Ledger

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildegard.helper.session` defines session identity and the append-only ledger.
A session is a random 128-bit id (32 lowercase hex) bound to a workspace. The
ledger stores typed, ordered records of everything that happened in the session
(messages, reasoning, tool calls, tool results, errors). A SQLite
`IConversationStore` adapter persists the loop's messages through the ledger and
recomposes them on restore, leaving out non-essential records.

This work also removes the store's `requests` table and its public API.

## Requirements

### Functional

- [ ] Generate a session id: 16 random bytes, hex-encoded to 32 lowercase chars.
- [ ] Create a session bound to a workspace; resume by id; reject an unknown id.
- [ ] Maintain session timestamps (created, updated).
- [ ] Append ledger records with a monotonic per-session sequence and timestamp.
- [ ] Record kinds: system/user/assistant message, reasoning, tool call, tool
      result, error, generic event.
- [ ] Query records by session, optionally by kind and with limit/offset,
      ordered by sequence.
- [ ] Provide `TSqliteConversationStore` implementing `IConversationStore`:
      append a `TChatMessage` as ledger records, and read back a
      `TChatMessageArray`.
- [ ] Recompose restored messages in provider order: system, user, assistant
      (with its tool calls), tool results; skip reasoning and error records.
- [ ] Correlate tool calls and results by tool-call id.
- [ ] List a workspace's sessions newest-updated first, with created/updated
      timestamps and a record count.
- [ ] Resolve the most recently updated session for a workspace.
- [ ] Remove the `requests` table and the store's request API.

### CLI

- [ ] The `sessions` subcommand lists the active workspace's sessions
      (`id  updated  record-count`), needing no provider configuration.
- [ ] `-c`/`--continue` resumes the most recently updated session for the active
      workspace; `--session` and `--continue` are mutually exclusive.

### Non-Functional

- [ ] Appends and reads are indexed; loading a session is one query.
- [ ] Leak-clean; no global state.
- [ ] The ledger may hold sensitive content; it is never logged and inherits the
      store's owner-only file permissions.
- [ ] The agent loop is unchanged; it uses `IConversationStore` as before.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

### Session unit

```pascal
unit hildegard.helper.session;

interface

uses
  SysUtils, hildegard.helper.store, hildegard.helper.agent, hildegard.helper.llm;

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
    DataJson: string;     // structured payload: tool name/ref, tool_call_id,
                          // arguments, error code/detail, ...
    CreatedAtMs: Int64;
  end;

  TSessionRecordArray = array of TSessionRecord;

function NewSessionId: string;

{ Ledger seam; the SQLite implementation lives here, an in-memory one supports
  tests. }
ISessionLedger = interface
  function Append(const ARecord: TSessionRecord; out AError: string): Boolean;
  function Query(const ASessionId: string; AUseKind: Boolean;
    AKind: TSessionRecordKind; ALimit, AOffset: Integer;
    out ARecords: TSessionRecordArray; out AError: string): Boolean;
end;

{ The loop's conversation store, persisted through the ledger. }
TSqliteConversationStore = class(TInterfacedObject, IConversationStore)
public
  constructor Create(AStore: TSqliteStore; const ASessionId: string;
    ALedger: ISessionLedger);
  procedure Append(const AMessage: TChatMessage);
  function Messages: TChatMessageArray;
  procedure Clear;
end;
```

### Store additions (`hildegard.helper.store`)

```pascal
function TSqliteStore.CreateSession(AWorkspaceId: Integer; out AId: string;
  out AError: TStoreError): Boolean;
function TSqliteStore.SessionExists(const AId: string;
  out AError: TStoreError): Boolean;
function TSqliteStore.TouchSession(const AId: string;
  out AError: TStoreError): Boolean;
function TSqliteStore.AppendSessionRecord(const ARecord: TSessionRecord;
  out AError: TStoreError): Boolean;
function TSqliteStore.QuerySessionRecords(const ASessionId: string;
  AUseKind: Boolean; AKind: TSessionRecordKind; ALimit, AOffset: Integer;
  out ARecords: TSessionRecordArray; out AError: TStoreError): Boolean;
function TSqliteStore.ListSessions(AWorkspaceId: Integer;
  out AList: TSessionSummaryArray; out AError: TStoreError): Boolean;
function TSqliteStore.MostRecentSessionId(AWorkspaceId: Integer;
  out AId: string; out AError: TStoreError): Boolean;
```

```pascal
type
  TSessionSummary = record
    Id: string;
    CreatedAtMs: Int64;
    UpdatedAtMs: Int64;
    RecordCount: Integer;
  end;
  TSessionSummaryArray = array of TSessionSummary;
```

### Removed store API

`TStoredRequest`, `TStoredRequestArray`, `TRequestStatus`, `TRequestQuery`,
`EnqueueRequest`, `ClaimNextPending`, `FinishRequest`, `GetRequest`,
`QueryRequests`, and the `requests` table. Store tests for them are deleted.

### Data Contracts

Message-to-record mapping (append):

| `TChatMessage` | Records written |
| --- | --- |
| `crSystem` | `srkSystemMessage` (Content) |
| `crUser` | `srkUserMessage` (Content) |
| `crAssistant` with tool calls | `srkAssistantMessage` (Content, may be empty) + one `srkToolCall` per call (DataJson: id, name, arguments) |
| `crAssistant` no tool calls | `srkAssistantMessage` (Content) |
| `crTool` | `srkToolResult` (Content; DataJson: tool_call_id) |

Record-to-message recomposition (read):

- `srkSystemMessage` -> `crSystem`.
- `srkUserMessage` -> `crUser`.
- `srkAssistantMessage` -> `crAssistant`, attaching any `srkToolCall` records
  that follow it (by sequence) up to the next non-tool-call record.
- `srkToolResult` -> `crTool` with `ToolCallId` from DataJson.
- `srkReasoning`, `srkError`, `srkEvent` -> skipped.

`Seq` is assigned by the store as `max(seq)+1` per session inside the insert's
transaction (single-threaded store, so no races).

### Event Contracts

None. The conversation adapter is called by the loop on its thread.

## Architecture

### Prior Art & Reuse

- `hildegard.helper.agent.IConversationStore` and `TChatMessage` - the seam.
- `hildegard.helper.store` - migrations, locking, transactions.
- `SysUtils.CreateGUID` gives 128 bits to seed/format; platform randomness may be
  used for the bytes.

### Component Boundaries

- **Responsibilities:** session identity, ledger records, conversation
  persistence, restore recomposition.
- **Dependencies:** `hildegard.helper.store`, `hildegard.helper.agent`,
  `hildegard.helper.llm` (`TChatMessage`, `TChatToolCall`), `fpjson` for
  `DataJson`.
- **Side effects:** inserts into `sessions` and `session_records`.

### Data Flow

1. The CLI selects or creates a session (workspace id + id).
2. It builds `TSqliteConversationStore` and passes it to the loop.
3. Each `Append` writes one or more ledger records.
4. On resume, `Messages` reads the ledger and recomposes the conversation.

## Validation Rules

- A session id is exactly 32 lowercase hex characters.
- An unknown or malformed session id is rejected before the loop starts.
- `Append` ignores nothing silently: an unsupported role raises no exception but
  writes an `srkEvent` (so the ledger stays complete) - implementer pins one
  behaviour with a test.
- `Seq` is strictly increasing per session.

## Error Handling

### Error Types

- **Store:** append/query failure -> `TStoreError`; the conversation adapter
  cannot surface an error to the loop (its interface returns no error), so it
  records the failure as an `srkError` record where possible and otherwise
  degrades to in-memory behaviour for that append (documented).
- **Session:** unknown id -> fatal at startup with a clear message.

### Error Contracts

The store returns `TStoreError`. The conversation adapter's `IConversationStore`
has no error channel; it must not raise into the loop.

## Testing Requirements

### Unit Tests (`tests/test_session.pas`)

- [ ] `TestNewSessionIdIs32LowercaseHex`
- [ ] `TestNewSessionIdIsUnique`
- [ ] `TestCreateSessionBindsWorkspace`
- [ ] `TestSessionExistsFalseForUnknown`
- [ ] `TestTouchSessionUpdatesTimestamp`
- [ ] `TestAppendAssignsIncreasingSeq`
- [ ] `TestQueryByKindAndPagination`
- [ ] `TestQueryOrdersBySeq`
- [ ] `TestNoLeaks`

### Conversation tests

- [ ] `TestAppendUserPersistsRecord`
- [ ] `TestAppendAssistantWithToolCallsPersistsCallRecords`
- [ ] `TestAppendToolResultPersistsResultRecord`
- [ ] `TestMessagesRoundTripMatchesAppended`
- [ ] `TestRestoreSkipsReasoningAndErrors`
- [ ] `TestToolCallResultCorrelatedByToolCallId`
- [ ] `TestRestoreAfterReopen` (close/reopen the store)
- [ ] `TestListAndMostRecentSessions` (store; newest-first, counts, not-found)
- [ ] `TestNoLeaks`

### Store removal tests

- [ ] The `requests` tests are removed; a migration test asserts `requests` is
      gone and `sessions`/`session_records` exist.

## Performance Targets

- One indexed insert per record; one ordered query per session load.
- No full-table scans.

## Security Considerations

- The ledger holds conversation content, which may be sensitive; no logging.
- Owner-only file permissions are already enforced by the store.
- Restore never resurrects secrets into prompts beyond the original content.

## Success Criteria

### Functional

- [ ] Contracts implemented; session round trip and restore work.
- [ ] `requests` table and API removed; `make check` passes.

### Quality

- [ ] Recomposed messages equal what the loop appended.
- [ ] No leaks.

## Future Considerations

- Configurable ledger recording for reasoning/errors (the loop currently does not
  emit them to the store).
- Retention/compaction and archival.
- Resume-last-session convenience.
- Remote mirroring of sessions.
