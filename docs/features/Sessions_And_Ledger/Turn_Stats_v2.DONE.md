# Implementation Plan: Turn Stats v2

**Related Specification:** `Turn_Stats_v2.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Task breakdown for `Turn_Stats_v2.SPEC.md`. Implemented test-first on top of
Turn Stats v1. Four slices: the formatters, the store/session aggregates, the
timing collection, and the UI (status, divider, thought label).

## Implementation Tasks

### Phase 1: The formatters (pure)

- [x] **Test**: `TestFormatSessionStatsPrefixesTotal`,
      `TestFormatSessionStatsEmpty`, `TestFormatThoughtLabel`,
      `TestFormatDurationMs` in `tests/test_harness_stats.pas`
- [x] **Implement**: `FormatSessionStats`, `FormatThoughtLabel`,
      `FormatDurationMs` in `src/hildi.harness.stats.pas`

### Phase 2: The aggregates

- [x] **Test**: `TestSessionTotalsContextAndGenerated`, `TestSessionTotalsEmpty` in
      `tests/test_store.pas`
- [x] **Implement**: `TSqliteStore.SessionTotals` in
      `src/hildi.store.pas`
- [x] **Test**: `TestSessionTotalsEmptyWithoutTurns` in
      `tests/test_harness_session.pas`
- [x] **Implement**: `THarnessSession.SessionTotals`, `THarnessSession.Turns`
      in `src/hildi.harness.session.pas`

### Phase 3: The timing collection

- [x] **Test**: `TestLoopRecordsReasoningDuration`,
      `TestLoopRecordsContentDuration`, `TestLoopReportsReasoningDone` in
      `tests/test_agent.pas`
- [x] **Implement**: time the reasoning/content phases in
      `TAgentLoop`; `TAgentEvents.OnReasoningDone`;
      `IConversationStore.AppendReasoning(AText, ADurationMs)`; persist the
      assistant's `DurationMs`
      (`src/hildi.agent.pas`,
      `src/hildi.session.store.pas`)
- [x] **Test**: `TestReasoningDoneRoundTrip` in
      `tests/test_session_protocol.pas`
- [x] **Implement**: `ekReasoningDone` (`reasoning_done`, `elapsed_ms`) in
      `src/hildi.session.protocol.pas`
- [x] **Implement**: `teReasoningDone` in
      `src/hildi.harness.turn.pas`; map it in
      `src/hildi.session.runtime.pas` and
      `src/hildi.harness.driver.pas`

### Phase 4: The UI

- [x] **Test**: `TestTurnDividerDrawsRuleAndRightAlignedStats` in
      `tests/test_tui_chat.pas`
- [x] **Implement**: `ckTurn` in `src/hildi.tui.chat.pas`
- [x] **Test**: `TestStatusShowsSessionTotals`,
      `TestTurnDividerAfterSuccessfulTurn`, `TestNoDividerAfterFailedTurn`,
      `TestResumeRendersTurnDividers`, `TestThoughtShowsDuration` in
      `tests/test_harness_app.pas`
- [x] **Implement**: the session-consumption status, the `ckTurn` divider (live
      and restore), and the thought label in
      `src/hildi.harness.app.pas`

### Phase 5: Docs and validation

- [x] **Update**: `docs/design/tui_design_language.html` (the preview), the
      protocol spec (`reasoning_done`), `docs/features/FEATURES.md`; rename this
      plan to `Turn_Stats_v2.DONE.md`
- [x] **Run**: `make check` (tests + leak gate)
- [x] **Verify**: a headless render of `TChatPanel` shows the session line, a
      loop divider and a `Thought for 2.3s` title; `make layout-demo` shows the
      same interactively. A live TUI sign-off remains.

## Files Created/Modified

### New Files

```
docs/features/Sessions_And_Ledger/Turn_Stats_v2.SPEC.md
docs/features/Sessions_And_Ledger/Turn_Stats_v2.DONE.md
```

### Modified Files

```
src/hildi.harness.stats.pas     FormatSessionStats, FormatThoughtLabel
src/hildi.store.pas             SessionTotals
src/hildi.harness.session.pas   SessionTotals, Turns
src/hildi.agent.pas             reasoning/content timing; AppendReasoning
src/hildi.session.store.pas     reasoning + assistant durations
src/hildi.session.protocol.pas  ekReasoningDone
src/hildi.harness.turn.pas      teReasoningDone
src/hildi.session.runtime.pas   map reasoning_done
src/hildi.harness.driver.pas    map reasoning_done; free the prior worker
src/hildi.tui.chat.pas          ckTurn divider
src/hildi.harness.app.pas       status, divider, thought label
tests/test_harness_stats.pas               the new formatters
tests/test_store.pas                       SessionTotals
tests/test_harness_session.pas             SessionTotals
tests/test_agent.pas                       the durations
tests/test_session.pas                     the reasoning duration
tests/test_session_protocol.pas            reasoning_done
tests/test_harness_turn.pas                the reasoning_done drain case
tests/test_tui_chat.pas                    the divider
tests/test_harness_app.pas                 status, dividers, thought label
tests/test_harness_driver.pas              the remote failed-turn guard
docs/design/tui_design_language.html       the preview
docs/features/Headless_Sessions/Session_Protocol_v1.SPEC.md  reasoning_done
docs/features/FEATURES.md                  the feature index
```

## Success Criteria

- [x] All tasks above checked
- [x] Every acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate): 773 tests, leak-clean
- [x] A resumed session's status, dividers and thought labels match the live one

## Notes & Considerations

Deviations from the specification, and why:

- **The session line moved to the header.** Session Header v1 (TUI Harness)
  moved it off the status bar and onto the messages panel's top border, adding
  the context bar and dropping the cache percentage. `FormatSessionStats` is
  gone, superseded by `FormatSessionHeader`; `SessionTotals` is unchanged.
- **The session line is `ctx · used · cached`.** The first cut summed the
  per-turn rollups, but a turn's `prompt_tokens` is itself the sum of its
  requests' prompts, and each request re-sends the growing context — so the sum
  compounded (a real session's 43 turns summed to ~10M against a final context
  of ~120k). A second cut showed the final context plus generated. The final
  design shows the window in play (`ctx` = `MAX(prompt_tokens)`), the billed
  total (`used` = Σprompt + Σcompletion — each request pays for its whole
  prompt, so the sum *is* the bill), and the token-weighted cache hit
  (Σcached/Σprompt): the three numbers needed to estimate cost.
- **The context guard is overridable.** The loop's `DefaultMaxContextTokens`
  (120000) failed a real session at 120,798 prompt tokens, far below the model's
  1M window, because the app has no model→limit table yet.
  `THarnessSessionConfig.MaxContextTokens` (0 => `HILDI_MAX_CONTEXT_TOKENS`,
  else the default) overrides it; the model API will supply it later.
- **`FormatDurationMs` gained hours** (`1h30m`); a session's total time is often
  over an hour.
- **The reasoning duration is measured in the loop, not the LLM client.** The
  loop owns the persistence and the event seam, so it timestamps the first
  reasoning delta, the first content delta, and the request end and reports the
  reasoning phase on `teReasoningDone`. One measurement feeds both the persisted
  row and the live event, so the live and resumed labels are the same number.
- **The reasoning duration is a `reasoning_done` session event.** The remote TUI
  client needs it, and the protocol is pre-release, so a new kind is appended
  (`elapsed_ms`). It is reported just before the first content delta, so the app
  settles the live thought block with its duration first.
- **A two-turn app leaked its first worker.** `TestStatusShowsSessionTotals`
  (the first test to run two turns in one app) exposed that
  `TLocalDriver.StartTurn` replaced `FWorker` without freeing it; fixed at the
  root (join and free the prior worker before starting the next).
- **The divider is only for successful loops.** A failed or cancelled loop has
  partial or absent metrics; `AddTurnDivider` requires `tsCompleted` and on
  restore only `tsCompleted` turns draw a divider, so live and resumed match.
- **The runtime's `turn_finished` after an error is not a `teDone`.** The
  runtime emits `ekError` then `ekTurnFinished` (`finish_reason: error`) on a
  failed turn, and the client mapped both to `teDone`, which flipped a failed
  remote turn back to `ready` and (with the divider) ended it with stats. The
  sink now skips an error `turn_finished`; `TestAppRemoteFailedTurnEndsInErrorWithoutDivider`
  guards it.
- **A store-less session draws no divider.** `FormatTurnStats` is empty for a
  zero turn, so `AddTurnDivider` skips it; existing no-store app tests keep their
  block counts.
- **A thought with any duration shows it.** `FormatThoughtLabel(0)` is `Thought`;
  a sub-second reasoning phase shows e.g. `Thought for 20ms`. The existing
  reasoning test now asserts the prefix, not exact equality.
- **The assistant's content duration is persisted but not drawn.** The operator
  chose "only the thought" for the block; the value is in the ledger (and the
  per-loop divider's turn duration) for a future view.
