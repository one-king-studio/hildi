# Implementation Plan: Sessions and Ledger v2

**Related Specification:** `Sessions_v2.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Task breakdown for `Sessions_v2.SPEC.md`. Implemented test-first; the full
schema reset landed as one batch so the store, the adapter, the loop seam, and
the TUI restore move together.

## Implementation Tasks

### Phase 1: LLM usage and timings

- [x] **Test**: `TestParsesOpenAIUsage`, `TestParsesDeepSeekUsage`,
      `TestParsesAnthropicUsageSpellings`, `TestUsageAbsentIsZero`,
      `TestFirstTokenMsSetOnFirstDelta`, `TestFirstTokenMsZeroWithoutContent`,
      `TestRequestAsksForUsage`, `TestClientExposesResolvedModel` in
      `tests/test_llm.pas`
- [x] **Implement**: `TTokenUsage`, `TChatResult.Usage`/`FirstTokenMs`; parse
      `usage` in `TSSEParser.HandleJson` before the choices guard; record the
      first delta's time; add `stream_options.include_usage` to
      `BuildRequestBody`; add `TLLMClient.Model`

### Phase 2: Schema and store operations

- [x] **Test**: `TestSchemaHasTheSessionTables`,
      `TestTurnRequestMessageRoundTrip`, `TestTurnRollupSumsRequests`,
      `TestMessageSeqIsPerSession`, `TestRequestSeqIsPerTurn`,
      `TestBeginRequestUnknownTurnFails`, `TestAppendMessageUnknownSessionFails`,
      `TestQueryTurnsDerivesPrompt`, `TestNewerSchemaVersionIsRejected`,
      `TestListSessionsCountsMessagesAndTurns` in `tests/test_store.pas`
- [x] **Implement**: replace `DefaultMigrations` with the single v2 migration;
      add the newer-version guard to `ApplyMigrations`; add `BeginTurn`/
      `FinishTurn`/`QueryTurns`, `BeginRequest`/`FinishRequest`/`QueryRequests`,
      `AppendMessage`/`QueryMessages`; update `ListSessions`
- [x] **Remove**: `TSessionRecordKind`, `TSessionRecord`,
      `TSessionRecordArray`, `AppendSessionRecord`, `QuerySessionRecords`

### Phase 3: Session model

- [x] **Test**: `TestNewSessionIdIs32LowercaseHex`, `TestNewSessionIdIsUnique`
- [x] **Implement**: `TMessageRole`, `TTurnStatus`, `TMessageRecord`,
      `TRequestRecord`, `TTurnRecord`, and the updated `TSessionSummary` in
      `src/hildegard.helper.session.pas`; keep `NewSessionId`

### Phase 4: Adapter and loop seam

- [x] **Test**: `TestAppendMapsRolesAndToolFields`,
      `TestMessagesRoundTripMatchesAppended`, `TestRestoreSkipsReasoningAndErrors`,
      `TestRestoreAfterReopen`, `TestToolCallResultCorrelatedByToolCallId`,
      `TestTailKeepsSystemAndRecent`, `TestTailDropsOrphanTools`,
      `TestBeginFinishTurnAndRequestRecorded`, `TestQueryMessagesReturnsAllBlocks`
      in `tests/test_session.pas`
- [x] **Implement**: rewrite `TSqliteConversationStore` over the new store
      operations; add `AppendReasoning`/`AppendError`; track the current
      turn/request
- [x] **Test**: `TestSendOpensAndClosesATurn`, `TestSendRecordsReasoning`,
      `TestSendRecordsErrorAndFailedTurn`, `TestSendRecordsRequestOutcome`,
      `TestToolResultCarriesNameOkAndDuration` in `tests/test_agent.pas`
- [x] **Implement**: extend `IConversationStore`; `TRequestOutcome`/
      `TTurnOutcome`; bracket turns/requests in `TAgentLoop.DoSend`; record
      reasoning and errors; set `ToolName`/`ToolOk`/`DurationMs` on tool results;
      update `TMemoryConversationStore`

### Phase 5: Restore and render

- [x] **Test**: `TestHistoryRestoresBlocks` in
      `tests/test_harness_session.pas`; `TestRenderHistoryRestoresToolBlocks` in
      `tests/test_harness_app.pas`
- [x] **Implement**: `THarnessSession.History: TMessageRecordArray`;
      `THarnessApp.RenderHistory` maps every role, pairs a tool call with its
      result, and titles the tool block by reason

### Phase 6: Callers, examples, docs

- [x] **Update**: `examples/agent_cli.pas` (session listing field rename) and
      `examples/store_demo.pas` (new store operations)
- [x] **Update**: the SPEC where it diverged (below); this plan is now
      `Sessions_v2.DONE.md`; `docs/features/FEATURES.md`
- [x] **Update**: `hildegard.helper.sqlite` (add `sqlite3_last_insert_rowid`)

### Phase 7: Validation

- [x] **Run**: `make test SUITE=<new tests>` (green)
- [x] **Run**: `make test` (whole suite, 502 tests)
- [x] **Run**: `make check` (tests + leak gate, exit 0)
- [x] **Run**: the TUI against a seeded store and confirm the blocks restore
      (user, Thought, tool titled by reason with its result, assistant, error) -
      done with a scripted pty capture; a live `make tui-agent` turn still needs
      an API key (operator sign-off)

## Files Created/Modified

### Modified Files

```
src/hildegard.helper.llm.pas          TTokenUsage, usage parsing, timings, Model
src/hildegard.helper.sqlite.pas       sqlite3_last_insert_rowid
src/hildegard.helper.session.pas      the record model
src/hildegard.helper.store.pas        schema + operations, guard
src/hildegard.helper.session.store.pas adapter + seam
src/hildegard.helper.agent.pas        seam + outcomes + loop bracketing
src/hildegard.helper.harness.session.pas  rich History
src/hildegard.helper.harness.app.pas  RenderHistory over blocks
examples/agent_cli.pas                listing field
examples/store_demo.pas               new operations
tests/test_llm.pas                    usage tests
tests/test_session.pas                model + adapter tests
tests/test_store.pas                  schema + operation tests
tests/test_agent.pas                  loop collection tests
tests/test_harness_session.pas        History test
tests/test_harness_app.pas            RenderHistory test
```

## Success Criteria

- [x] All tasks above checked
- [x] Every acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] A resumed session restores the streamed blocks
- [x] Implementation matches the specification

## Notes & Considerations

Deviations from the specification, and why:

- **Tool calls are `messages` rows** with role `mrToolCall`, not a child table.
  The operator chose this so every rendered block is one ordered row.
- **`turns` has no `prompt` column.** The turn's prompt is derived in
  `QueryTurns` as its first `mrUser` message, so the text is not stored twice.
- **`AppendError` stores the error detail in `tool_arguments`.** The message
  table has no dedicated detail column and the turn/request rows already carry
  it; this keeps the error block self-describing without a new column.
- **The store requires the caller to set `TurnId`/`RequestId`** on a
  `TMessageRecord`; the SQLite adapter does so from its current turn/request.
- **A newer-schema guard was added** to `ApplyMigrations` (not in the original
  v1 store): a database at a higher `user_version` than this build is rejected
  with a "delete the database" message rather than misbehaving.
- **The CLI resume still uses the provider view** (`Messages`); the richer
  block view is the TUI's, as the SPEC scoped.
- **`TSessionSummary.RecordCount` became `MessageCount` (+ `TurnCount`).**

The tool-output budget (cap/spill/recall) is specified in
`../Context_Budget/` and is the next feature; this plan leaves the full tool
output in `messages.content` so it can serve as the artifact.
