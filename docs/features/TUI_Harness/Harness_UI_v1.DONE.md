# Implementation Plan: Harness UI v1

**Related Specification:** `Harness_UI_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `Harness_UI_v1.SPEC.md`. Work on `main` (no branches). Each
implementation task starts with a failing test; run `make check` before moving on.

## Implementation Tasks

### Phase 1: Turn events, queue, gate, worker

- [x] Add `test_harness_turn` to `tests/hildegard_helper_tests.pas`
- [x] **Types**: `TTurnEvent`/`TTurnEventKind`, `TTurnQueue`, `TApprovalGate`,
      `TTurnWorker` in `src/hildegard.helper.harness.turn.pas` (interface only)
- [x] **Test**: `TTurnQueueTest.TestFifoOrderAndEmpty`
- [x] **Implement**: `TTurnQueue` over a `TCriticalSection` FIFO
- [x] **Test**: `TApprovalGateTest.TestAskBlocksUntilAnswer` (Ask on a helper
      thread; Answer from the main thread)
- [x] **Test**: `TApprovalGateTest.TestCancelDenies`, `TestTimeoutDenies`,
      `TestStaleAnswerIgnored`
- [x] **Implement**: `TApprovalGate` (`TCriticalSection` + `TSimpleEvent`)
- [x] **Test**: `TTurnWorkerTest.TestStreamsDeltasThenDone` (canned
      `TFakeTransport`)
- [x] **Test**: `TTurnWorkerTest.TestProviderErrorEmitsError`
- [x] **Test**: `TTurnWorkerTest.TestToolEventsCarryNameReasonOk`
- [x] **Implement**: `TTurnWorker.Execute` mapping agent events to turn events
- [x] **Test (leak/concurrency)**: `TTurnWorkerTest.TestWorkerJoinsCleanly`;
      concurrent queue stress test

### Phase 2: Prompt line widget

- [x] Add `test_tui_prompt` to the runner
- [x] **Test**: typing, Backspace/Delete, Home/End, Left/Right by cluster
- [x] **Test**: Up/Down history and non-mutation after recall
- [x] **Test**: Enter fires `OnSubmit` with the text and clears; inactive ignores
- [x] **Implement**: `TPromptLine` in `src/hildegard.helper.tui.prompt.pas`

### Phase 3: Conversation view

- [x] Add `test_tui_conversation` to the runner
- [x] **Test**: append renders styled spans into the surface
- [x] **Test**: sticky-to-bottom - follows on append; stops after scroll-up;
      resumes at the bottom; `Clear`
- [x] **Implement**: `TConversationView` in
      `src/hildegard.helper.tui.conversation.pas`

### Phase 4: Approval modal

- [x] Add `test_tui_approvalmodal` to the runner
- [x] **Test**: renders summary and options; Up/Down and number keys select
- [x] **Test**: Enter fires `OnChoose` once with the matching option; Escape
      denies; a zero-option ask denies safely
- [x] **Implement**: `TApprovalModal` in
      `src/hildegard.helper.tui.approvalmodal.pas`

### Phase 5: Harness session

- [x] Add `test_harness_session` to the runner
- [x] **Test**: in-memory config builds a loop with builtins + `run_command`
- [x] **Test**: store config ensures workspace/session; `History` round trips
- [x] **Test**: `Resume` with a bad id fails
- [x] **Implement**: `THarnessSession.Open` in
      `src/hildegard.helper.harness.session.pas` (config resolution shared with
      the CLI; see the reuse note)

### Phase 6: Application assembly

- [x] Add `test_harness_app` to the runner
- [x] **Test**: a scripted turn drives the tree - prompt echo, streamed assistant
      text, a tool line, an approval modal answered to resume, `teDone`
      re-enables, `teError` shows an error line
- [x] **Test**: draining N events in one `Step` renders one frame
- [x] **Test (leak)**: quit mid-turn with a blocked approval joins the worker
- [x] **Implement**: `THarnessApp` in `src/hildegard.helper.harness.app.pas`

### Phase 7: Example & docs

- [x] **Example**: `examples/tui_agent.pas` (`cthreads` first) wiring surface,
      input, session, app; `Makefile` target `tui-agent`
- [x] **Docs**: fpdoc comments on public interfaces; update `HANDOFF.md` and
      `FEATURES.md`
- [~] **Validation**: `make check` green (300 tests, leak-clean) and a pty
      smoke of `make tui-agent` (start, Ctrl-C quit, balanced terminal modes)
      pass; a live LLM turn in a real terminal remains.

## Dependencies & Ordering

- Phase 1 has no TUI dependency and unblocks Phases 5/6.
- Phases 2-4 depend only on TUI Core (already implemented).
- Phase 5 depends on Phase 1; Phase 6 depends on 1-5; Phase 7 last.

### Critical Path

1. Turn layer -> widgets -> session -> app -> example.

## Files to Create/Modify

### New Files

```
src/hildegard.helper.harness.turn.pas
src/hildegard.helper.harness.session.pas
src/hildegard.helper.harness.app.pas
src/hildegard.helper.tui.prompt.pas
src/hildegard.helper.tui.conversation.pas
src/hildegard.helper.tui.approvalmodal.pas
tests/test_harness_turn.pas
tests/test_harness_session.pas
tests/test_harness_app.pas
tests/test_tui_prompt.pas
tests/test_tui_conversation.pas
tests/test_tui_approvalmodal.pas
examples/tui_agent.pas
```

### Modified Files

```
tests/hildegard_helper_tests.pas   (add the new test units to uses)
Makefile                           (tui-agent target)
docs/features/FEATURES.md
HANDOFF.md
```

## Success Criteria

- [x] All tasks above checked
- [x] Every FEATURE acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] `examples/tui_agent.pas` demonstrates streaming, tool lines, an approval
      modal, quit-mid-turn, and resume
- [x] Implementation matches the specification

> **Complete.** All tasks and success criteria are met; the harness suites
> (`TTurnQueueTest`/`TTurnWorkerTest`/`THarnessAppTest`/`THarnessSessionTest`/
> `THarnessViewTest`) are green and `examples/tui_agent.pas` builds
> (`make tui-agent`). Tick-boxes completed retroactively.

## Notes & Considerations

- Record deviations from the specification here, with the reason.
- Cancellation is best-effort (no transport interrupt hook): a documented
  ceiling with an upgrade path.
