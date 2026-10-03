# Implementation Plan: Interrupt and Compose Keys v1

**Related Specification:** `Interrupt_v1.SPEC.md`

## Implementation Tasks

### Phase 1: Loop cancellation

- [x] **Implement**: `leCancelled` (llm); `tsCancelled` (session);
      `TAgentCancelCheck` + `CancelCheck` + the boundary check in
      `TAgentLoop.DoSend` and the `tsCancelled` outcome (agent)
- [x] **Implement**: bind `TTurnWorker.Cancelled` to the loop for the turn
- [x] **Test**: `TestLoopStopsWhenCancelled` in `tests/test_agent.pas`; the
      worker's `TestCancelBeforeStart` updated for `leCancelled`

### Phase 2: Compose keys

- [x] **Test**: `TestClearLineClearsTheCaretLine`,
      `TestClearLineOnEmptyLineIsNoOp`, `TestCtrlUClearsTheLine`,
      `TestCtrlCClearsTheBufferAndReportsHandled`,
      `TestCtrlCOnEmptyBufferReportsUnhandled` in `tests/test_tui_edit.pas`
- [x] **Implement**: `TTextEdit.ClearLine`; `Ctrl+U`/`Ctrl+C` in `HandleEvent`

### Phase 3: The app gesture and the guarded quit

- [x] **Implement**: `psInterrupt` in `TChatPanel`; the shell's `OnEscape` and
      `CanQuit`; `THarnessApp.HandleEscape`/`InterruptTurn` with the 2 s window;
      no error block for `leCancelled`
- [x] **Test**: `TestEscapeArmsThenCancels`,
      `TestCtrlCQuitsOnlyWhenComposeIsEmpty` in `tests/test_harness_app.pas`

### Phase 4: Validation

- [x] **Run**: `make check` (543 tests, leak gate)
- [x] **Update**: the demo's shell to guard `Ctrl+C`; this plan is now
      `Interrupt_v1.DONE.md`; `docs/features/FEATURES.md`

## Files Created/Modified

```
src/hildegard.helper.llm.pas             leCancelled
src/hildegard.helper.session.pas         tsCancelled
src/hildegard.helper.agent.pas           the cancel check
src/hildegard.helper.harness.turn.pas    bind the flag to the loop
src/hildegard.helper.tui.edit.pas        ClearLine + Ctrl+U/Ctrl+C
src/hildegard.helper.tui.chatpanel.pas   psInterrupt
src/hildegard.helper.harness.app.pas     the shell callbacks + the gesture
examples/tui_layout_demo.pas             the guarded Ctrl+C
tests/test_agent.pas                     the loop cancel
tests/test_tui_edit.pas                  the compose keys
tests/test_harness_app.pas               the gesture + the guarded quit
tests/test_harness_turn.pas              leCancelled in the cancel test
```

## Success Criteria

- [x] All tasks above checked
- [x] `make check` passes (tests + leak gate)
- [x] A turn can be interrupted from the UI and `Ctrl+C` is guarded

## Notes & Considerations

Deviations from the specification, and why:

- **`TestEscapeWindowExpires` was not written.** The 2 s window is implemented
  (`CheckInterruptWindow`, called from `Step` and `OnLoop`), but exercising it
  would add a two-second sleep to the suite; the arm-and-cancel path is covered
  instead. A clock seam on the app would make it testable.
- **`TestCancelBeforeStart` (turn worker) was updated**: the cancel is now seen
  by the loop's first boundary check, so the error code is `leCancelled` (8)
  rather than the old pre-check's `leProvider` (7).
- **The demo's shell guards `Ctrl+C` too**, so the reference layout shows the
  same behaviour.
- **The loop only checks between requests**, as specced: an in-flight stream
  finishes first (the transport has no cancel hook), and a tool batch is never
  broken part-way so its calls and results stay paired.
- **A cancel persists no error block** (follow-up fix). `FailTurn` appended an
  `mrError` message for every failure, including `leCancelled`, which the TUI
  recalled as a bright-red error block even though the live path draws none.
  The turn row already records the cancelled status, so the append is skipped
  for a cancel and the two paths match.
