# Live Turn Control v1 - Implementation Plan

**Spec:** `Live_Turn_Control_v1.SPEC.md`

Phases are ordered so each can land and be tested on its own. Phase 1 is
independent; phase 3 builds on it; phases 4-5 touch the loop and land last.

## Phase 1 - Compact content (item 5)

- [ ] `src/hildegard.helper.tui.compact.pas`: `TCompactOptions`,
      `DefaultCompactOptions`, `CompactLines`.
- [ ] `tests/test_tui_compact.pas`: short text unchanged, long text elided
      (2 + `...` + 3), blank edges trimmed, interior blanks kept.
- [ ] Add the suite to `tests/hildegard_helper_tests.pas`.

## Phase 2 - Approval dialog: reason, wrapping, compaction (items 3, 4)

- [ ] `hildegard.helper.approval`: add `TApprovalAsk.Reason`.
- [ ] `hildegard.helper.command.tool` and `hildegard.helper.files`: fill
      `Reason` from the call's `reason` argument in `ApprovalAsks`.
- [ ] `hildegard.helper.tui.approvalmodal`: draw `reason:` beneath the title;
      wrap details; compact long details; clamp to `AAvail - 8`.
- [ ] Tests: reason shown, details wrap, long details compact, edge padding.

## Phase 3 - Compose: submit, paste, CTA (item 6)

- [ ] `hildegard.helper.tui.input`: `ikPaste` kind and `Text` payload.
- [ ] `hildegard.helper.tui.input.decode`: parse `ESC [ 200 ~ ... ESC [ 201 ~`.
- [ ] `hildegard.helper.tui.input.terminal`: enable/disable bracketed paste
      around the run.
- [ ] `hildegard.helper.tui.edit`: insert `ikPaste` text literally.
- [ ] `hildegard.helper.tui.compose`: Shift+Enter/Ctrl+Enter submit; `Cta`.
- [ ] `hildegard.helper.tui.chatpanel` / `harness.app`: set the CTA from state.
- [ ] Tests: submit keys, newline, paste, CTA states, decoder paste.

## Phase 4 - Immediate cancel (item 1)

- [ ] `hildegard.helper.llm`: `TLLMCancelCheck`, `PostStream` `ACancelled`,
      `TLLMClient.CancelCheck`.
- [ ] `hildegard.helper.agent`: consult the check mid-stream; on early cancel
      drop the turn's messages (keep the row); `leCancelled`.
- [ ] `hildegard.helper.agent` / `session.store`: `DropLastResponse` and the
      turn-message drop.
- [ ] `hildegard.helper.harness.app`: remove the user block and prepend the
      prompt to the compose on an early cancel.
- [ ] Tests: mid-stream cancel, early vs late, restore.

## Phase 5 - Prompt queue (item 2)

- [ ] `hildegard.helper.agent`: `TPromptQueue`; drain before each request; drop
      a tool call in favour of queued prompts; start a new turn at the stop.
- [ ] `hildegard.helper.harness.turn`: `TTurnWorker.QueuePrompt`.
- [ ] `hildegard.helper.harness.app`: Shift+Enter enqueues when busy.
- [ ] Tests: drain, drop tool call, multi-prompt, next turn.

## Testing

Each phase adds its `tests/test_*.pas` to `tests/hildegard_helper_tests.pas`
and runs `make check` before moving on.

## Completion

- [ ] `make check` green (functional + leak gate).
- [ ] Rename this TODO to `Live_Turn_Control_v1.DONE.md` when all phases land.
