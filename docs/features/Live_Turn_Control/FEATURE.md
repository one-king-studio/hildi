# Live Turn Control

## Overview

A trial run of the TUI surfaced six gaps in how the operator controls a live
turn: cancel is too coarse, there is no way to feed context to a loop that is
already running, the approval dialog hides the model's reason, the dialog
cannot wrap long tool details, there is no shared way to compact long content,
and the compose box submits on plain Enter, which makes multi-line paste
impossible.

This feature refines the live interaction loop: an immediate cancel that leaves
no trace and restores the prompt, a prompt queue that injects context at loop
boundaries, and the presentation work those need (a reason in the approval
dialog, wrapping and compaction of long content, and a Shift+Enter submit with
bracketed paste and a primary-action CTA).

## Problem Statement

The loop is a black box once a turn starts. The cancel path only runs between
requests, so a prompt sent by mistake cannot be stopped until the provider
answers, and even then the operator cannot recover the prompt they typed. There
is no way to add a correction ("actually, use the staging bucket") while the
agent is mid-turn; the operator has to wait for it to finish and start over.

The approval dialog is thin where it matters most: it shows the command but not
the model's reason for running it, and a long command or path either overflows
or forces the dialog to grow without bound. The compose box is a single-line
submit: pasting a multi-line block fires a turn at the first newline.

Applying the first Ponytail rung: the loop, the turn worker, the interrupt
machinery, the approval modal, and the text editor all exist. The genuine gaps
are narrow - a cancel that is honoured mid-stream, a queue drained at existing
loop boundaries, one extra field on the approval ask, a wrapping/compaction
helper, and a paste mode plus a CTA label.

## Goals

- Make a cancel take effect **immediately**, before the provider responds,
  when no tool call has been made and the loop has not concluded.
- On a successful cancel, leave **no message** behind and **restore the last
  user prompt** to the compose box, prepended to whatever is already typed.
- Let the operator **queue prompts** that are injected at loop boundaries, so
  context reaches a running loop.
- Show the model's **reason** in the approval dialog, and keep long details
  **wrapped and compact** so the dialog stays a sane size.
- Provide one **compact-content** helper (trim, first 2, ellipsis, last 3) that
  the dialog and other surfaces can share.
- Submit the compose box with **Shift+Enter**, support **bracketed paste**, and
  show a **primary-action CTA** that reflects the current state.

## User Stories

- As an **operator**, I want to cancel a prompt I just sent before the model
  answers, so a mistake costs nothing.
- As an **operator** who cancels, I want my prompt back in the compose box, so I
  can edit it instead of retyping it.
- As an **operator**, I want to add a correction while the agent is working, so
  I do not have to wait for the turn to finish and start over.
- As an **operator**, when I add context just before a tool call, I want the
  agent to reconsider the call with my context, so it does not run a tool I have
  just made unnecessary.
- As an **operator**, I want to see *why* the model wants to run a command, so I
  can make an informed approval decision.
- As an **operator**, I want a long command shown compactly, so the dialog does
  not fill the screen.
- As an **operator**, I want to paste a multi-line block into the compose box,
  so I can send structured prompts.
- As an **operator**, I want a clear primary action at the bottom right that
  tells me what Enter or Escape will do right now.

## Acceptance Criteria

### Functional Requirements

Cancel (immediate, no trace)

- [ ] A cancel issued before any tool call has been made and before the loop
      concludes takes effect immediately, without waiting for the provider's
      response.
- [ ] A successful cancel persists **no message** for the aborted turn: the
      user prompt, any streamed assistant text, and any reasoning are not kept.
- [ ] A successful cancel keeps the turn row, marked `tsCancelled`, with no
      messages; the live view and a later resume agree there were no messages.
- [ ] The cancelled turn's last user prompt is **prepended** to the current
      compose text (not appended, and not replacing what is already typed).
- [ ] A cancel after a tool call has been made, or after the loop has
      concluded, is not a "successful cancel": it falls back to stopping at the
      next loop boundary, preserving the tool call/result pair and recording the
      turn as cancelled.
- [ ] The cancel sequence stays Esc-Esc ("press esc again to cancel"); the CTA
      label is shorthand for it.
- [ ] The cancel keybinding is shown in the CTA when a turn is in flight (see
      the compose CTA below).

Prompt queue (inject context mid-flight)

- [ ] While a turn is in flight, the operator queues a prompt with Shift+Enter
      (the same key that sends when idle); one or more prompts are held until
      the loop reaches a boundary.
- [ ] Queued prompts are drained at loop boundaries: before the next request to
      the provider, between reasoning and a request, and before tool calls.
- [ ] When a queued prompt is present before a tool call, the tool call is
      dropped: the assistant's tool-call message is **deleted from the store**,
      no tool is executed, and the queued prompt is used instead. The agent may
      re-issue the call in a later response if it still judges it appropriate.
- [ ] Multiple queued prompts are appended together, in order, as multiple user
      messages in one request.
- [ ] If the loop concludes (a proper stop) with prompts still queued, those
      prompts immediately start the next turn.
- [ ] Queueing does not require the current turn to finish or be cancelled.

Approval dialog: reason

- [ ] The approval dialog shows the model's stated reason for the tool call,
      labelled `reason:`, immediately beneath the title.
- [ ] The reason is the reason carried with the tool call; when it is absent or
      invalid, the dialog shows a muted placeholder rather than a blank line.
- [ ] Every path that builds an ask fills it (the command tool's run and
      approval-ask paths, and the file tool), so the value reaches the dialog.
- [ ] The dialog order is: reason, tool/command details, options, scope,
      actions.
- [ ] The tool block in the transcript shows the reason as its title and the
      result as its body; the raw tool name and arguments are not shown, live
      or on resume.

Approval dialog: wrapping, padding, compaction

- [ ] The tool/command details wrap to the dialog width instead of overflowing.
- [ ] Long details use the compact-content helper (below) so the dialog does
      not grow without bound.
- [ ] When the dialog grows, it keeps at least a 4-column and 4-row padding
      from the screen edge.
- [ ] The dialog still renders correctly at narrow widths and short heights.

Compact content helper

- [ ] A shared unit compacts long text: after trimming leading and trailing
      blank lines, content longer than 10 lines renders as the first 2 lines, a
      `...` line, and the last 3 lines (6 lines total).
- [ ] Content of 10 trimmed lines or fewer is returned unchanged.
- [ ] Trimming removes blank lines before the first and after the last
      non-blank line; interior blank lines are preserved.
- [ ] The helper is pure and unit-tested, and is reused by the approval dialog.

Compose: submit, paste, CTA

- [ ] The compose box submits on **Shift+Enter**, with **Ctrl+Enter** as a
      fallback for terminals that cannot report Shift+Enter; plain Enter inserts
      a newline.
- [ ] Bracketed paste mode is enabled while the TUI runs and disabled on exit,
      so a pasted multi-line block is inserted as text and never submits.
- [ ] A pasted block is inserted literally (newlines preserved) at the caret.
- [ ] A primary-action CTA is drawn at the bottom right of the compose box,
      opposite the `Hildegard · model` label.
- [ ] The CTA uses the approval dialog's keybinding styling: the key muted, the
      action in the highlight colour as the primary call to action.
- [ ] CTA states: idle with no text shows no CTA; idle with text shows
      `shift+enter send`; in-flight with an empty box shows `esc cancel`;
      in-flight with text shows `shift+enter send`.
- [ ] The CTA updates as the operator types and as the turn starts and ends.

Reason length

- [ ] Every tool schema advertises a `maxLength` on its `reason` parameter
      (`ToolReasonMaxLength`), so a reason stays a short label.
- [ ] A tool/thought block title is truncated with an ellipsis when it does not
      fit the block's width (a narrow terminal), so the rule and the collapse
      mark stay visible.

Live thinking

- [ ] While reasoning streams, the block is titled `Thinking...` and shows the
      tail of the reasoning: the last up to six lines, prefixed with a `...`
      line when there is more above.
- [ ] When the reasoning finishes and is persisted, the block settles into a
      collapsed `Thought` block, matching what a resumed session shows.
- [ ] The live block cannot be toggled; the settled `Thought` block can.

Tool-call budget and context guard

- [ ] A turn may make at most 50 tool calls; the soft limit is 30.
- [ ] At 30, and every 5 calls after (35, 40, 45), the call is **intercepted**
      (not executed) and the model is told the limit was reached and that it
      may continue by resubmitting the tool request.
- [ ] At 50 the model is **locked down**: the call is intercepted and it is
      told no further calls are permitted and to answer with what it has.
- [ ] If it makes one more call after the lockdown, the turn ends with a loop
      error (`leLoop`).
- [ ] The running context (the latest request's prompt tokens) is capped; a
      turn whose context exceeds the cap ends with a loop error.
- [ ] An intercepted call still gets a paired result in the ledger, so the
      history stays valid.

### Non-Functional Requirements

- [ ] Reliability: no leaks under the heaptrc gate; queue, cancel, and paste
      paths are covered by tests.
- [ ] Portability: works on macOS and Linux with Free Pascal 3.3.1; bracketed
      paste degrades gracefully on terminals that do not support it.
- [ ] Performance: queue polling and CTA updates add no measurable idle CPU and
      no frame cost.
- [ ] Testability: cancel, queue, compaction, wrapping, and paste are tested
      headlessly with the memory surface and a scripted input source.
- [ ] `make check` passes.

## Success Metrics

### Quantitative

- A cancel issued while the provider is streaming stops the turn without
  waiting for the response to complete.
- A cancelled turn leaves zero message rows and is invisible on resume.
- A prompt queued before a tool call is reflected in the very next request.

### Qualitative

- The operator never loses typed text: cancel returns it, paste preserves it.
- A running loop can be steered without being restarted.
- The approval decision is informed by the model's own reason.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- Must reuse the existing loop, turn worker, approval gate/modal, and
  `TTextEdit`/`TComposeBox`; the cancel must be honoured inside the streaming
  request, not only at the loop top.
- The tool-call/result pairing invariant in the ledger must hold at all times;
  a dropped tool call must not leave an orphaned result.
- Store changes, if any, must be additive with no reset of existing history.

### Business / Time

- No external deadline; this is a refinement batch from a live trial.

## Dependencies

### Internal

- `hildegard.helper.agent` - the loop and its boundaries, `IConversationStore`,
  the cancel check, `FailTurn`.
- `hildegard.helper.harness.turn` - `TTurnQueue`, `TTurnWorker`,
  `TApprovalGate`, `TTurnEvent.ToolReason`.
- `hildegard.helper.harness.app` - the interrupt handling, compose, and modal.
- `hildegard.helper.approval` - `TApprovalAsk` (needs the reason).
- `hildegard.helper.tui.compose` / `.edit` - submit key and paste insertion.
- `hildegard.helper.tui.approvalmodal` - reason line, wrapping, compaction.
- `hildegard.helper.tui.input.decode` / `.input.terminal` - bracketed paste.

### External

- Terminal bracketed paste (`\e[?2004h` / `\e[?2004l`, `\e[200~` / `\e[201~`).
- Terminals that report Shift+Enter distinctly (CSI-u / kitty / modifyOtherKeys);
  a fallback is needed where they do not.

## Risks

- **Shift+Enter is not distinguishable on some terminals.** Many send a bare
  CR for both Enter and Shift+Enter. Mitigation: decide a fallback binding and
  document the terminal requirement.
- **Mid-stream cancel races the stream.** Mitigation: cancel is checked at a
  single point in the request reader and the turn is finalised once.
- **Dropping a tool call breaks pairing.** Mitigation: drop the assistant
  tool-call message together with never executing its calls, and test the
  invariant.
- **Queue drain starves or duplicates.** Mitigation: drain atomically at named
  boundaries; test multi-prompt and end-of-loop cases.
- **Bracketed paste and the submit key interact.** Mitigation: a paste is a
  single event; the submit key is never interpreted inside paste brackets.
- **Modal wrapping grows unbounded.** Mitigation: compaction caps details and
  the modal keeps 4ch/4line edge padding.

## Out of Scope

- Reworking the turn worker or the approval protocol.
- Editing or reordering queued prompts before they are drained.
- Persisting queued prompts across a restart.
- Rich paste handling (images, file drops).
- Any change to how approvals are matched or stored.

## Future Considerations

- A visible queue (show pending prompts above the compose box).
- Editing/removing a queued prompt before the boundary.
- Per-turn cancel history in the transcript.
- A configurable submit keybinding.

## Notes

- **ICE score: Impact 8, Confidence 6, Ease 5.** Impact is high: this is the
  difference between a demo and a usable loop. Confidence is moderate because
  mid-stream cancel, queue boundaries, and Shift+Enter reporting need terminal
  and timing calibration. Ease is mixed: the compaction unit and the CTA are
  small; the cancel and queue touch the loop.
- **Sequencing:** the compact-content helper and the CTA are independent and can
  land first; cancel and queue touch the loop and should be specified together;
  the approval reason/wrapping depends on the compact helper.
- **Reuse note (Ponytail):** the loop boundaries, the interrupt path, the
  approval modal, and `TTextEdit` exist. The new pieces are a mid-stream cancel
  check, a queue drain at those boundaries, one reason field, one compaction
  helper, bracketed paste, and a CTA label.
- **Decisions:** a cancel after a tool call falls back to the next loop boundary
  (the tool call/result pair is preserved); a successful early cancel keeps a
  `tsCancelled` turn row with no messages; cancel stays Esc-Esc; Shift+Enter
  queues while in-flight and sends when idle; a dropped tool call is deleted
  from the store; Ctrl+Enter is the submit fallback where Shift+Enter cannot be
  reported.
