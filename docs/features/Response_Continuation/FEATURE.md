# Response Continuation

## Overview

When a provider stops generating because it hit its output ceiling, it says so
with `finish_reason: "length"` (OpenAI-compatible) or `stop_reason: "max_tokens"`
(Anthropic-style gateways). The harness already detects this and then treats it
as a hard provider error: the turn fails and the partial text the operator
watched stream in is thrown away. There is no recovery.

This feature makes the **loop own the in-flight response**. On a truncated
response it re-requests a followup, appends what comes back, and repeats until
the provider reaches a proper stop - at which point the assembled response is
committed as one message. Persistence is ephemeral in between: nothing is written
to the store until a proper stop, and on any other error the whole pending
response is discarded. A tool call that cannot be completed is dropped and
answered back to the model so the ledger stays valid and it can resubmit.

## Problem Statement

A coding agent's completion tokens are dominated by tool-call arguments, not
prose: a large `file_write` or a long explanation will hit the ceiling. Today
that is unrecoverable. The model may have produced a nearly complete answer or a
nearly complete file body, and the harness discards it and fails the turn. The
operator sees an error block and has to re-prompt from scratch.

Two things are wrong:

1. **No recovery.** A truncated response is a *successful response that was cut
   short*, not a transient failure. It should be continued, not retried with
   backoff and not thrown away.
2. **Live and resume disagree.** The partial text is streamed to the panel but
   never persisted, so a resumed session shows the error block and none of the
   text the operator just watched. This breaks the project's standing invariant
   that a resumed session is identical to the live one.

Applying the first Ponytail rung: the loop, the request builder, the store, the
turn worker, the event stream, and the tool-intercept machinery all exist. The
genuine gaps are narrow - a pending buffer the loop owns, a bounded continuation
request, a distinct error code, and a rollback of the streamed blocks on error.

## Goals

- **Continue** a truncated response by re-requesting until the provider reaches
  a proper stop, so a cut-off answer is completed rather than lost.
- Keep the in-flight response **ephemeral**: it is committed only at a proper
  stop, and dropped entirely on any other error.
- Give a truncated response that **cannot** be continued (a cut-off tool call, or
  the continuation cap) a clear, bounded outcome.
- Keep the **tool call/result pairing invariant** valid: a dropped call is still
  answered, so the next request is well formed.
- Keep the live view and a resumed session **identical** after a failure.

## User Stories

- As an **operator**, when the model's answer is cut off, I want the harness to
  finish it for me, so I get a complete answer instead of an error.
- As an **operator**, I want a cut-off answer to arrive as one message, so the
  transcript reads as one reply and not a stutter of fragments.
- As an **operator**, when the model's file write is cut off mid-call, I want it
  to be told and to resubmit in smaller pieces, so the write completes.
- As an **operator**, when a response truly cannot be completed, I want the
  partial text removed from the live view as well, so what I see matches what a
  resumed session will show.
- As the **model**, when my call is dropped, I want to be told why, so I can
  resubmit it correctly.

## Acceptance Criteria

### Functional Requirements

Continuation

- [ ] A response that ends with `length` and carries no tool calls is **not** an
      error: the loop keeps its text and reasoning, re-requests a followup, and
      appends the new text until the provider returns a proper stop.
- [ ] The pending text is not written to the store while it is being continued;
      only the final assembled response is persisted.
- [ ] The assembled response is committed as **one** assistant message (the
      pending text followed by the continuation text), with its reasoning
      committed once, so a resumed session shows one reply.
- [ ] The continuation request carries the pending text as an assistant message
      (when it is non-empty) followed by a fixed continuation instruction; the
      instruction is never persisted and never drawn.
- [ ] Continuation is bounded: one response allows at most `MaxContinuations`
      followups (default 3). Exceeding the cap is an error.
- [ ] `MaxContinuations` is configurable on `TAgentConfig`; `0` takes the
      default and a negative value disables continuation (a truncated response
      fails immediately, as today).
- [ ] An empty-but-truncated response (a reasoning model that spent its whole
      budget thinking) is a continuation case, not a malformed response.

Truncated tool calls

- [ ] A response that ends with `length` **and** carries tool calls cannot be
      completed by text continuation. Its calls are dropped: none is executed,
      and each is answered with a paired tool result telling the model the call
      was cut off and must be resubmitted (splitting large arguments).
- [ ] The dropped call's round is committed (assistant message plus paired
      notice results) and the loop continues, so the model can resubmit. The
      ledger has no orphaned result and no unpaired call.
- [ ] The tool block for a dropped call shows the notice as its body, so the
      operator can see why it was not run.

Errors and rollback

- [ ] Any termination that is not a proper stop (`stop` / `tool_calls`) and not a
      continuable `length` is an error. The entire pending response - text and
      reasoning - is discarded and never persisted.
- [ ] A response that exhausts `MaxContinuations` fails the turn with a distinct
      truncation error code (`leTruncated`), not `leProvider`.
- [ ] An error during a continuation fails the turn with the underlying error
      code; the pending response is still discarded.
- [ ] On a non-cancel error, the live view removes the assistant and thinking
      blocks it streamed for the pending response, so the live view and a
      resumed session agree. Blocks from earlier committed tool rounds are kept.
- [ ] A cancel keeps its existing semantics; the pending response is discarded
      as it is today.

### Non-Functional Requirements

- [ ] Reliability: no leaks under the heaptrc gate; continuation, cap, dropped
      call, and rollback paths are covered by tests.
- [ ] Portability: works on macOS and Linux with Free Pascal 3.3.1; no
      provider-specific feature is required (no prefix/partial-completion API).
- [ ] Performance: continuation adds at most `MaxContinuations` requests per
      response and no idle CPU or per-frame cost.
- [ ] Testability: the loop, the dropped-call notice, and the rollback are
      tested headlessly with the fake transport and the memory surface.
- [ ] `make check` passes.

## Success Metrics

### Quantitative

- A response truncated once and then stopped yields exactly one persisted
  assistant message whose content is the concatenation of both fragments.
- A response truncated past the cap yields zero persisted assistant messages and
  an `leTruncated` error.
- A failed turn leaves the live panel and the resumed session with the same
  block sequence.

### Qualitative

- A cut-off answer is completed without operator intervention.
- A cut-off tool call is resubmitted by the model, not silently lost.
- The operator never sees text in the live view that a resume would not show.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- Must reuse the existing loop, `BuildRequest`, `InterceptToolCalls`, the
  `IConversationStore` seam, the turn worker, and the event stream. No new
  transport capability (prefix/partial-completion) may be required.
- The tool-call/result pairing invariant in the ledger must hold at all times.
- Store changes, if any, must be additive with no reset of existing history.
- `leTruncated` must be appended to `TLLMErrorCode` so stored ordinals do not
  shift (the precedent set by `leLoop`).

### Business / Time

- No external deadline; this follows from the truncation research review.

## Dependencies

### Internal

- `hildi.agent` - the loop, `BuildRequest`, `AppendResponse`,
  `InterceptToolCalls`, `FinishError`, `TAgentConfig`, `FailTurn`.
- `hildi.llm` - `TFinishReason`, `TLLMErrorCode`, `TChatResult`,
  `TChatMessage`, `TSSEParser.SetFinish`.
- `hildi.harness.turn` - `TTurnWorker`, `TTurnEvent`, `teError`.
- `hildi.harness.app` - `HandleTurnEvent`, the in-flight
  `FAssistant`/`FThought` blocks, `AppendError`.
- `hildi.session.store` - `IConversationStore` (no change expected).

### External

- None. The continuation is built from ordinary chat messages.

## Risks

- **The provider rejects a replayed partial message.** A truncated tool call
  carries incomplete JSON arguments. Mitigation: arguments are opaque strings to
  OpenAI-compatible APIs; if a provider rejects them, fall back to a user-message
  instruction (documented as a follow-up).
- **Continuation loops forever.** Mitigation: a hard cap per response
  (`MaxContinuations`, default 3) and the existing context guard.
- **The merged message reads oddly.** A continuation can start mid-sentence.
  Mitigation: the instruction forbids repetition; the cap bounds the damage.
- **The context guard fires during a continuation.** The prompt grows with each
  followup. Mitigation: the existing `MaxContextTokens` check runs each round;
  the cap makes it a bounded failure.
- **Rollback removes a committed block.** Mitigation: only the in-flight
  assistant/thinking blocks are removed; tool rounds are settled before the next
  response starts.

## Out of Scope

- Sending or escalating `max_tokens` (the harness does not set it today).
- Provider prefix / partial-completion modes (Kimi `partial=True`, DeepSeek
  beta prefix completion).
- Structured-output / JSON-mode continuation handling (the harness uses no
  `response_format`).
- Retry-with-backoff for transient errors (none exists today; keep truncation
  out of it if one is added).
- Summarising or compacting a long continuation.

## Future Considerations

- A configurable output cap (`max_tokens`) so truncation is rarer and the
  escalate-before-stitch strategy becomes available.
- Surfacing a continuation count in the turn stats.
- Detecting the cap via usage (`completion_tokens` at the ceiling) when
  `finish_reason` is missing.

## Notes

- **ICE score: Impact 8, Confidence 7, Ease 6.** Impact is high: output-cap
  truncation is the most likely failure for a writing agent. Confidence is good
  because the research is settled and the seams exist. Ease is moderate: the
  loop change is small, but the live/resume rollback and the ledger pairing need
  care.
- **Decisions:** a truncated tool call is answered with a paired notice and the
  round is committed (a cut-off call cannot be text-continued, so the round is
  over and must be answered); the continuation instruction is invisible and
  never persisted; the pending response is dropped on error; the live view rolls
  back its streamed blocks on error so live equals resume; the cap is 3 by
  default and configurable.
- **Reuse note (Ponytail):** the loop, request builder, store seam, event
  stream, and `InterceptToolCalls` exist. The new pieces are a pending buffer,
  one continuation branch, one notice string, one error code, one config field,
  and a rollback on the error path.
