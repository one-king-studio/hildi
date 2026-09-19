# Implementation Plan: Sessions and Ledger v1

**Related Specification:** `Sessions_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

> **Progress:** implemented and committed. `hildegard.helper.session` (session
> ids + record model), migration v4 (`sessions`, `session_records`, drop
> `requests`), store session/ledger methods, `TSqliteConversationStore`
> (persist + restore, skipping reasoning/errors), and CLI `--session` resume.
> `tests/test_session.pas` covers id format, the round trip, restore skipping,
> and restore after reopen; `test_store` asserts `requests` is gone.
>
> **Deviations:** `ISessionLedger` was dropped (unnecessary indirection - the
> adapter uses `TSqliteStore` directly; the no-store CLI path keeps the
> in-memory conversation store). `Clear` is a no-op by design (the ledger is
> durable history). 7 request tests were deleted with the table.
>
> Added: `sessions` subcommand (list a workspace's sessions), `-c/--continue`
> (resume the most recent), `--tail N` (resume loads the last N messages,
> default 5, 0 = all), and an interactive startup banner (workspace, session,
> model, store, loaded count), and the restored tail is rendered on screen
> (TTranscriptWriter.RenderHistory).
>
> **Remaining before DONE:** live CLI smoke (run, exit, resume by id).
>
> The checkboxes below are not ticked retroactively.

## Overview

Build `hildegard.helper.session`: session identity, the typed ledger, and a
SQLite `IConversationStore` adapter that persists and restores conversations.
Also remove the store's `requests` table and API. Depends on Workspaces for the
workspace id.

> `main`-only project: no feature branch.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [ ] Add `tests/test_session.pas` to the uses clause of
      `tests/hildegard_helper_tests.pas`
- [ ] Create `src/hildegard.helper.session.pas` with the interface from the SPEC
- [ ] Create `tests/test_session.pas` with an empty `TTestCase`

### Phase 2: Session identity (TDD)

- [ ] **Test**: `TestNewSessionIdIs32LowercaseHex`, `TestNewSessionIdIsUnique` - red
- [ ] **Implement**: `NewSessionId` (16 random bytes -> 32 hex)
- [ ] **Add** migration v4: `sessions(id TEXT PK, workspace_id INTEGER NOT NULL,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)` and
      `session_records(id INTEGER PK AUTOINCREMENT, session_id TEXT NOT NULL,
      seq INTEGER NOT NULL, kind INTEGER NOT NULL, content TEXT, data TEXT,
      created_at INTEGER NOT NULL)` with an index on `(session_id, seq)`; and
      `DROP TABLE requests`
- [ ] **Test**: `TestCreateSessionBindsWorkspace`, `TestSessionExistsFalseForUnknown`
- [ ] **Implement**: `CreateSession`, `SessionExists`, `TouchSession`

### Phase 3: Ledger (TDD)

- [ ] **Test**: `TestAppendAssignsIncreasingSeq` - red
- [ ] **Implement**: `AppendSessionRecord` (assign `seq = max+1` in the insert
      transaction)
- [ ] **Test**: `TestQueryByKindAndPagination`, `TestQueryOrdersBySeq`
- [ ] **Implement**: `QuerySessionRecords`
- [ ] **Create** `TMemorySessionLedger` for tests and the no-store path
- [ ] **Test**: `TestNoLeaks`

### Phase 4: Conversation adapter (TDD)

- [ ] **Test**: `TestAppendUserPersistsRecord`,
      `TestAppendAssistantWithToolCallsPersistsCallRecords`,
      `TestAppendToolResultPersistsResultRecord`
- [ ] **Implement**: `TSqliteConversationStore.Append` per the mapping table
- [ ] **Test**: `TestMessagesRoundTripMatchesAppended` - red
- [ ] **Implement**: `Messages` recomposition (assistant with attached tool calls
      in sequence; tool results by `tool_call_id`)
- [ ] **Test**: `TestRestoreSkipsReasoningAndErrors`,
      `TestToolCallResultCorrelatedByToolCallId`, `TestRestoreAfterReopen`

### Phase 5: Remove requests

- [ ] **Delete** `TStoredRequest`, `TStoredRequestArray`, `TRequestStatus`,
      `TRequestQuery`, `EnqueueRequest`, `ClaimNextPending`, `FinishRequest`,
      `GetRequest`, `QueryRequests`
- [ ] **Delete** their tests in `tests/test_store.pas`
- [ ] **Test**: migration test asserts `requests` is gone and the new tables exist
- [ ] **Grep** the tree for `TStoredRequest`/`EnqueueRequest` and fix references
      (including docs/specs)

### Phase 6: CLI wiring & docs

- [ ] `--session ID` (resume) and default new session in `examples/agent_cli.pas`
- [ ] Build `TSqliteConversationStore` and pass it to the loop
- [ ] Update `FEATURES.md` / `HANDOFF.md`

### Phase 7: Validation

- [ ] `make test SUITE=TSessionTest`, `make test`, `make test-leak`, `make check`
- [ ] Manual smoke: run, exit, resume by id, confirm messages restore

## Dependencies & Ordering

- Workspaces v1 must land first (workspace id).
- Migration v4 assumes v2 (workspaces) and v3 (approvals) exist; keep versions
  ordered.
- Independent of the command tool refactor.

## Files to Create/Modify

### New Files

```
src/hildegard.helper.session.pas
tests/test_session.pas
```

### Modified Files

```
src/hildegard.helper.store.pas   (migration v4, session methods; remove requests)
tests/test_store.pas             (remove requests tests)
src/hildegard.helper.cli.pas     (--session option)
examples/agent_cli.pas           (session + conversation store)
tests/hildegard_helper_tests.pas
```

## Success Criteria

- [ ] All tasks checked; every SPEC acceptance criterion has a test
- [ ] Session round trip and restore verified
- [ ] `requests` fully removed; `make check` passes; no leaks

## Notes & Considerations

- `IConversationStore` has no error channel; catch store errors and record an
  `srkError` where possible rather than raising into the loop.
- Assign `seq` inside the insert transaction; the store is single-threaded.
- Ledger content may be sensitive: never log it.
