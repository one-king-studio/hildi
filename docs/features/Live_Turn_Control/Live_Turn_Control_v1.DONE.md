# Live Turn Control v1 - Implementation Plan

**Spec:** `Live_Turn_Control_v1.SPEC.md`

Phases are ordered so each can land and be tested on its own. Phase 1 is
independent; phase 3 builds on it; phases 4-5 touch the loop and land last.

## Phase 1 - Compact content (item 5) - done

- [x] `src/hildi.tui.compact.pas`: `TCompactOptions`,
      `DefaultCompactOptions`, `CompactLines`.
- [x] `tests/test_tui_compact.pas`: short text unchanged, long text elided
      (2 + `...` + 3), blank edges trimmed, interior blanks kept.
- [x] Add the suite to `tests/hildi_tests.pas`.

## Phase 2 - Approval dialog: reason, wrapping, compaction (items 3, 4) - done

- [x] `hildi.approval`: add `TApprovalAsk.Reason`.
- [x] `hildi.command.tool` and `hildi.files`: fill
      `Reason` from the call's `reason` argument in `ApprovalAsks`.
- [x] `hildi.tui.approvalmodal`: draw `reason:` beneath the title;
      wrap details; compact long details; clamp to `AAvail - 8`.
- [x] Tests: reason shown, details wrap, long details compact, edge padding.

## Phase 3 - Compose: submit, paste, CTA (item 6) - done

- [x] `hildi.tui.input`: `ikPaste` kind and `Text` payload.
- [x] `hildi.tui.input.decode`: parse `ESC [ 200 ~ ... ESC [ 201 ~`.
- [x] `hildi.tui.input.terminal`: enable/disable bracketed paste
      around the run.
- [x] `hildi.tui.edit`: insert `ikPaste` text literally.
- [x] `hildi.tui.compose`: Shift+Enter/Ctrl+Enter submit; `Cta`.
- [x] `hildi.tui.chatpanel` / `harness.app`: set the CTA from state.
- [x] Tests: submit keys, newline, paste, CTA states, decoder paste.

## Phase 4 - Immediate cancel (item 1) - done

- [x] `hildi.llm`: `TLLMCancelCheck`, `PostStream` `ACancelled`,
      `TLLMClient.CancelCheck`.
- [x] `hildi.agent`: consult the check mid-stream; on early cancel
      drop the turn's messages (keep the row); `leCancelled`.
- [x] `hildi.store` / `session.store` / `agent`: `DropTurnMessages`.
- [x] `hildi.harness.app`: remove the user block and prepend the
      prompt to the compose on an early cancel (`Dropped`).
- [x] Tests: mid-stream cancel, early vs late, restore.

## Phase 5 - Prompt queue (item 2) - done

- [x] `hildi.agent`: `TPromptQueue`; drain before each request; drop
      a tool call in favour of queued prompts; start a new turn at the stop.
- [x] `hildi.harness.turn`: `TTurnWorker.QueuePrompt`; `tePromptQueued`.
- [x] `hildi.harness.app`: a submit while busy enqueues; the compose
      stays active so the operator can type mid-flight.
- [x] Tests: drain, drop tool call, next turn, app queueing.

## Phase 6 - Reason length and live thinking (trial follow-up) - done

- [x] `hildi.agent`: `ToolReasonMaxLength`; `AugmentReasonParam`
      advertises `maxLength` on the reason property.
- [x] `hildi.tui.chat`: truncate a block title to the block width
      with an ellipsis; add a live block mode that shows `TailLines(FBody, 6)`
      and cannot be toggled.
- [x] `hildi.tui.compact`: `TailLines`.
- [x] `hildi.harness.app`: reasoning streams as `Thinking...` (live),
      settles to a collapsed `Thought` when the next event arrives.
- [x] Tests: schema cap, title truncation, live tail, tail helper, app settle.

## Phase 7 - Tool-call budget and context guard - done

- [x] `hildi.llm`: `leLoop` error code.
- [x] `hildi.agent`: `SoftToolLimit`/`HardToolLimit`/
      `ToolNoticeStep`/`MaxContextTokens` replace `MaxToolIterations`; the loop
      intercepts calls from the soft limit, locks down at the hard limit, fails
      one past it, and guards the running context.
- [x] `hildi.harness.session` / `examples/agent_cli.pas`: drop the
      old `MaxToolIterations` plumbing (defaults apply).
- [x] Tests: soft intercept, hard lockdown, loop abort, context abort.

## Testing

Each phase adds its `tests/test_*.pas` to `tests/hildi_tests.pas`
and runs `make check` before moving on.

## Completion

- [x] `make check` green (functional + leak gate).
- [x] Renamed to `Live_Turn_Control_v1.DONE.md`.

## Follow-up: paste dispatch fix (2026-10-03)

Field report (VSCode, macOS): pasting into the compose did nothing. The decoder
was not at fault - byte-by-byte and 64-byte-chunk delivery are now covered by
`TestDecodeBracketedPasteByteByByte` / `...InSixtyFourByteChunks` and pass. The
gap was `TTuiApp.DispatchEvent`: it switched on `ikResize`/`ikKey`/`ikMouse` and
had no arm for `ikPaste`, so a decoded paste was dropped before it reached the
widget tree. `ikPaste` now routes like a key (to the modal plane while one is
up, else the base). Covered by `TestPasteIsDispatched` (app) and
`TestPasteInsertsIntoTheCompose` (harness).

## Follow-up: Cmd+Enter submit (2026-10-03)

macOS terminals do not forward Cmd by default, so `TModifier` gained `moSuper`
(kitty super bit 8; `CSI 13;9u`) and the compose submits on Cmd+Enter. It only
fires when the terminal is configured to send that sequence (a VSCode
`terminal.sendSequence` keybinding); Shift+Enter and Ctrl+Enter stay as
fallbacks. The compose CTA advertises the platform's key: `⌘+enter send` on
macOS, `ctrl+enter send` elsewhere (`SendCtaKey`). The toolbar hints default
is blanked, but the hints component is unchanged and can be given text later.

## Follow-up: tool result output (2026-10-03)

The tool panel no longer prefixes a result with `[ok]`/`[failed]`: the reason is
the title and the result is the body. A tool that benefits from repeating part
of its call puts it in the result itself - `run_command` now returns a
shell-transcript form (`$ <command>`, a blank line, the output, and `[exit N]`
when non-zero), and `file_read` names the file and its size above the content
(or `[binary file: N bytes]` when it cannot read it).

## Follow-up: approval ask presentation (2026-10-03)

The approval dialog's details are the tool's own summary of the call, so
`file_read` says `read test.txt:5-30` for a ranged read. A blank line now
separates the reason from the details, and the details carry inline padding.
