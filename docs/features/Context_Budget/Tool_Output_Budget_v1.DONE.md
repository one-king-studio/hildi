# Implementation Plan: Tool Output Budget v1

**Related Specification:** `Tool_Output_Budget_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Task breakdown for `Tool_Output_Budget_v1.SPEC.md`. Implemented test-first on top
of the Sessions v2 history.

## Implementation Tasks

### Phase 1: The cap in the prompt view

- [x] **Test**: `TestPromptCapsLargeToolResult`,
      `TestPromptLeavesSmallToolResultIntact`, `TestCapZeroDisablesTruncation`,
      `TestRenderStillShowsFullResult` in `tests/test_session.pas`
- [x] **Implement**: `ToolResultCap` on `TSqliteConversationStore`, applied in
      `Compose`; the marker names the message id and the recall tool

### Phase 2: The recall tool

- [x] **Test**: `TestRecallReturnsWindow`, `TestRecallDefaultsToCap`,
      `TestRecallClampsToArtifact`, `TestRecallCapsOverLargeLimit`,
      `TestRecallUnknownIdFails`, `TestRecallNonToolIdFails`,
      `TestRecallNegativeOffsetFails`, `TestRecallRegistersTheTool` in
      `tests/test_recall_tool.pas`
- [x] **Implement**: `TRecallTool` in
      `src/hildi.recall.tool.pas`; add `QueryMessage` to the store

### Phase 3: Wiring

- [x] **Implement**: `THarnessSessionConfig.ToolResultCap`; resolve the cap; set
      it on the adapter and register the recall tool in
      `hildi.harness.session.pas`
- [x] **Implement**: register the recall tool and set the cap in
      `examples/agent_cli.pas`
- [x] **Test**: `TestRecallToolRegisteredWithStore`,
      `TestRecallToolAbsentWithoutStore` in `tests/test_harness_session.pas`

### Phase 4: Validation

- [x] **Run**: `make test SUITE=<new tests>` (green)
- [x] **Run**: `make check` (tests + leak gate, exit 0)
- [x] **Run**: `make agent-cli` / `make tui-agent` build
- [x] **Update**: the SPEC where it diverged (below); this plan is now
      `Tool_Output_Budget_v1.DONE.md`; `docs/features/FEATURES.md`

## Files Created/Modified

### New Files

```
src/hildi.recall.tool.pas
tests/test_recall_tool.pas
```

### Modified Files

```
src/hildi.session.store.pas   the cap in Compose
src/hildi.store.pas           QueryMessage
src/hildi.harness.session.pas ToolResultCap + register the tool
examples/agent_cli.pas                   register the tool
tests/test_session.pas                   cap tests
tests/test_harness_session.pas           registration tests
tests/hildi_tests.pas         add the new test unit to uses
```

## Success Criteria

- [x] All tasks above checked
- [x] Every acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] A capped prompt and a working recall path, proven by tests

## Notes & Considerations

Deviations from the specification, and why:

- **The shared bits live in the tool unit.** `RecallToolName`,
  `DefaultToolResultCap`, `ResolveToolResultCap`, and
  `ToolResultTruncationMarker` are declared in
  `src/hildi.recall.tool.pas`, and the adapter imports the marker
  from there, so the prompt cap and the tool that reads the artifact cannot
  drift on the tool name or the marker shape.
- **`TSqliteStore.QueryMessage` was added** (not in the SPEC's contract) for the
  tool's lookup; it is session-scoped so a session cannot read another's
  artifacts.
- **Config shape:** `THarnessSessionConfig.ToolResultCap` is 0 for the default
  (8 KiB), negative for uncapped; `HILDI_TOOL_RESULT_CAP` overrides when the
  field is 0. The adapter property treats any value `<= 0` as "no cap".
- **The recall tool is registered only when a store exists** (harness and CLI):
  without one there are no artifacts to read.
- **The test names differ slightly** from the SPEC's sketch:
  `TestRecallCapsAndDoesNotMark` became `TestRecallCapsOverLargeLimit` (it
  asserts the slice is capped and carries no truncation marker), and
  `TestRecallDefaultsToCap` was added.
- **An offset at or past the end returns an empty result**, not an error, as the
  SPEC's validation rules imply; only an unknown id, a non-tool id, or a
  negative offset are errors.

The cap bounds the prompt only; the stored `messages` row and the rendered UI
still show the full result (`TestRenderStillShowsFullResult`).
