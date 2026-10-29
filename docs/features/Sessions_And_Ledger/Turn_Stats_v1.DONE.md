# Implementation Plan: Turn Stats v1

**Related Specification:** `Turn_Stats_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Task breakdown for `Turn_Stats_v1.SPEC.md`. Implemented test-first on top of
Sessions v2.

## Implementation Tasks

### Phase 1: The formatter

- [x] **Test**: `TestFormatTurnStatsFull`,
      `TestFormatTurnStatsOmitsCacheWhenNoPromptTokens`,
      `TestFormatTurnStatsAbbreviatesTokens`, `TestFormatTurnStatsDuration`,
      `TestFormatTurnStatsZeroTurnIsEmpty` in `tests/test_harness_stats.pas`
- [x] **Implement**: `FormatTurnStats` in
      `src/hildi.harness.stats.pas`

### Phase 2: The latest turn

- [x] **Test**: `TestMostRecentTurnReturnsLatest`, `TestMostRecentTurnNotFound`
      in `tests/test_store.pas`; `TestLastTurnEmptyWithoutTurns` in
      `tests/test_harness_session.pas`
- [x] **Implement**: `TSqliteStore.MostRecentTurn`; `THarnessSession.LastTurn`

### Phase 3: The status line and the toolbar

- [x] **Test**: `TestStatsLineRendersRightAligned`,
      `TestLongWorkspaceIsTrimmedForStats` in `tests/test_tui_chatpanel.pas`
- [x] **Implement**: `TChatPanel.SetStats` (a right-aligned status block) and
      `FitStatus` (trim the left status so it never collides with the stats)
- [x] **Test**: `TestStatusShowsStatsAfterATurn`, `TestResumeStatusMatchesLive`,
      `TestCtaHoldsTheHints` in `tests/test_harness_app.pas`
- [x] **Implement**: `THarnessApp` sets the stats from `FSession.LastTurn` on
      startup and after each turn; the CTA holds the state and hints with `⇧+↵`

### Phase 4: Examples and docs

- [x] **Update**: `examples/tui_layout_demo.pas` (CTA `⇧+↵`, the status hints
      moved into the CTA, a stats line)
- [x] **Update**: the SPEC where it diverged (below); this plan is now
      `Turn_Stats_v1.DONE.md`; `docs/features/FEATURES.md`

### Phase 5: Validation

- [x] **Run**: `make test SUITE=<new tests>` (green)
- [x] **Run**: `make check` (tests + leak gate)
- [x] **Run**: the TUI against a seeded store and confirm the status line
      matches a live turn (scripted pty capture)

## Files Created/Modified

### New Files

```
src/hildi.harness.stats.pas
tests/test_harness_stats.pas
```

### Modified Files

```
src/hildi.store.pas            MostRecentTurn
src/hildi.harness.session.pas  LastTurn
src/hildi.tui.chatpanel.pas    the right-aligned stats line + FitStatus
src/hildi.harness.app.pas      compose the status/CTA
examples/tui_layout_demo.pas              CTA + stats
tests/test_store.pas                      MostRecentTurn tests
tests/test_harness_session.pas            LastTurn test
tests/test_tui_chatpanel.pas              stats-line tests
tests/test_harness_app.pas                live vs resume identity
tests/hildi_tests.pas          add the new test unit to uses
```

## Success Criteria

- [x] All tasks above checked
- [x] Every acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] A resumed session's status line is byte-identical to the live one

## Notes & Considerations

Deviations from the specification, and why:

- **The state moved to the CTA toolbar.** The operator asked for a two-part
  status bar (workspace left, stats right); the transient state
  (`ready`/`thinking...`/`approval needed`) is context, so it sits in the CTA
  toolbar with the hints. The demo's `ctrl+p`/`ctrl+b` hints moved there too.
- **`TChatPanel.FitStatus` was added.** A long workspace path and the stats can
  collide on a narrow terminal, so the left status is trimmed to leave the
  right-aligned stats intact (`TestLongWorkspaceIsTrimmedForStats`).
- **The formatter uses integer arithmetic** for its decimals, so the decimal
  point is always `.` regardless of the process locale.
- **`THarnessApp` exposes `StatusText`, `StatsText`, and `CtaText`** for tests;
  the identity test compares the live and resumed `StatsText` byte for byte.
- **Per-block durations** (the design doc's `Thought · 8.2s`) and a full stats
  view are left for a follow-up; this spec is the status line only.
- The `{$codepage utf8}` directive was deliberately not used in the new unit:
  the project's `string` is `AnsiString`, and the directive forces
  `AnsiString`↔`UnicodeString` warnings-as-errors. The `·` literal is stored as
  its UTF-8 bytes, matching the existing TUI units.

### Toolbar follow-on

After the first cut, the operator asked for the toolbar to be left/right split
too, and for the thinking sparkle to move there:

- **The toolbar is `Auto | Fill`**: the run state left, the hints right.
- **The sparkle moved out of the stream** into the toolbar and animates for the
  whole turn (including tool execution); `THarnessApp` no longer adds a
  `ckThinking` block. `ThinkingSparkle` is exported from `tui.chat` so the
  stream indicator and the toolbar share one cycle.
- **The states** are `psReady` (green `✓`), `psThinking`/`psTool` (sparkle),
  `psApproval` (warn `?`), and `psError` (error `✗`); the state is set on
  submit, on each tool call, on an approval, and on the turn's outcome.
- **Inline padding** (`ChromePad = 2`) insets the toolbar and the status row so
  their content does not touch the panel edges.
