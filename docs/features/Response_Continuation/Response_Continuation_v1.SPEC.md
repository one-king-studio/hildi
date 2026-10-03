# Component Specification: Response Continuation v1

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

Teach the agent loop to own the in-flight response. When a provider signals that
its output ceiling was hit (`frLength`), the loop accumulates the partial text
and reasoning and re-requests a followup, repeating until a proper stop, then
commits the assembled response as one message. Anything else is an error: the
pending response is discarded and never persisted. A truncated tool call is
dropped, answered with a paired notice, and the loop continues so the model can
resubmit.

One component, `hildegard.helper.agent`, plus a small change to the live app's
error path.

## Requirements

### Functional

Continuation

- [ ] A request that returns `frLength` with no tool calls is a continuation
      case: the loop keeps the response's content and reasoning, and issues a
      followup request.
- [ ] The followup request is the store's messages, plus the pending content as
      an assistant message (only when non-empty), plus one fixed user
      instruction to continue.
- [ ] The followup response's content and reasoning are appended to the pending
      response, and the loop repeats.
- [ ] When a request returns `frStop`, the pending response merged with that
      response is committed as a single assistant message (reasoning committed
      once) and the turn completes.
- [ ] When a request returns `frToolCalls`, the pending response merged with that
      response is committed as a single assistant message (carrying the tool
      calls) and the existing tool handling runs.
- [ ] An empty-but-truncated response (empty content) is a continuation case.
- [ ] `MaxContinuations` bounds the followups for one response. `0` takes the
      default; negative disables continuation.

Truncated tool calls

- [ ] A request that returns `frLength` **and** carries tool calls commits the
      merged assistant message and answers every call with `TruncatedToolNotice`
      via the existing intercept path; no tool handler runs.
- [ ] The loop then continues, so the model can resubmit.
- [ ] The intercepted call still gets a paired `crTool` message, so the ledger
      stays valid.

Errors

- [ ] Any `TFinishReason` other than `frStop`, `frToolCalls`, or a continuable
      `frLength` is an error; the pending response is discarded.
- [ ] Exhausting `MaxContinuations` fails the turn with `leTruncated`.
- [ ] An error returned by the client mid-continuation fails the turn with that
      error's code; the pending response is discarded.
- [ ] The context guard (`MaxContextTokens`) still applies on every request,
      including continuations.
- [ ] Cancellation keeps its current semantics; the pending response is discarded
      and no new store write happens for it.

Live view

- [ ] On a non-cancel error, the app removes the in-flight assistant and
      thinking blocks before appending the error block.
- [ ] Tool blocks from earlier committed rounds are not removed.
- [ ] The persisted system prompt is not drawn on resume (it is never drawn
      live), so the live and resumed block sequences stay identical.

### Non-Functional

- [ ] Leak-clean; `make check` green.
- [ ] No new transport capability is required; the continuation uses ordinary
      chat messages.
- [ ] The continuation adds no idle CPU and no per-frame cost.

## Contracts & Interfaces

### Agent (`hildegard.helper.agent`)

```pascal
const
  { Followup requests allowed for one response before the turn fails. }
  DefaultMaxContinuations = 3;

  { The user message that asks the model to resume a truncated response. It
    exists only in the continuation request: never persisted, never drawn. }
  ContinuationInstruction =
    'Continue exactly from where you stopped. Do not repeat the previous text. ' +
    'Finish the answer in the same language and format.';

  { The paired tool result that answers a call dropped because the response was
    cut off mid-call. }
  TruncatedToolNotice =
    'your tool call was cut off before it completed and was not run. ' +
    'Resubmit it; if its arguments are large, split them across smaller calls.';

type
  { Loop-private: the response accumulated across continuation requests. It is
    not persisted until a proper stop; on error it is discarded. }
  TPendingResponse = record
    Content: string;      // assistant text so far
    Reasoning: string;    // display-only reasoning so far
  end;

  TAgentConfig = record
    SystemPrompt: string;
    SoftToolLimit: Integer;
    HardToolLimit: Integer;
    ToolNoticeStep: Integer;
    MaxContextTokens: Integer;
    { Followup requests allowed for one truncated response. 0 takes
      DefaultMaxContinuations; negative disables continuation. }
    MaxContinuations: Integer;
  end;
```

### LLM (`hildegard.helper.llm`)

```pascal
type
  { leTruncated is appended last so stored ordinals are unchanged, following the
    precedent set by leLoop. It means: the response was truncated and could not
    be completed within the continuation budget. }
  TLLMErrorCode = (leOk, leConfig, leNetwork, leHttpStatus, leAuth, leRateLimit,
    leMalformedStream, leProvider, leCancelled, leLoop, leTruncated);
```

`TFinishReason` is unchanged. `TSSEParser.SetFinish` already maps `length`;
optionally it also maps `max_tokens` (Anthropic-style gateways) to `frLength`.

### Turn worker and app (`hildegard.helper.harness.turn` / `.app`)

No new event kind and no new event field. The existing `teError` carries the
error code and message. The app removes the in-flight blocks on any non-cancel
`teError`; `leCancelled` keeps its existing path (`Dropped` still means the early
cancel restored the prompt).

## Architecture

### Prior Art & Reuse

- The loop and its round handling (`TAgentLoop.DoSend`) already distinguish
  `frStop`, `frToolCalls`, and `frLength`; only the `frLength` branch changes.
- `TAgentLoop.InterceptToolCalls` already commits an assistant tool-call message
  and answers each call with a paired notice. Reuse it verbatim for a truncated
  call by passing `TruncatedToolNotice`; no new notice machinery.
- `TAgentLoop.BuildRequest` already assembles `FStore.Messages` plus tool specs.
  Continuation needs an ephemeral overlay of at most two messages; a private
  overload is the whole change.
- `TAgentLoop.FinishError` maps the non-`length` reasons; it keeps doing so. The
  `frLength`-with-no-continuation-budget case becomes `leTruncated`.
- The app already tracks the in-flight blocks as `FAssistant`/`FThought` and
  already removes them for a queued prompt and for an early cancel; the error
  path reuses that removal.
- Nothing in the store changes: the pending response is never persisted until it
  is committed, and committed writes use the existing `Append`/`AppendReasoning`.

### Component Boundaries

- **Responsibilities:** the loop owns the pending response and the continuation
  budget; it decides when to continue, commit, or discard. The app owns the live
  rollback. The store stays a plain append seam.
- **Dependencies:** `hildegard.helper.llm` for the finish reason and error codes;
  `IConversationStore` for the committed messages.
- **Side effects:** committed assistant/tool messages and reasoning blocks; the
  turn outcome (`tsCompleted` / `tsFailed`).

### Data Flow

For one outer round (one request plus its continuations):

1. Clear the pending response; reset the continuation count.
2. Build the request: the store's messages, plus (when a continuation) the
   pending content as an assistant message and `ContinuationInstruction` as a
   user message.
3. Send the request and read the finish reason.
4. On `frLength` with no tool calls: if the continuation budget is exhausted,
   discard the pending response and fail with `leTruncated`; otherwise append the
   content and reasoning to the pending response, count the followup, and go to
   step 2.
5. On `frLength` with tool calls: merge the pending response with this response
   into one assistant message, commit it, answer every call with
   `TruncatedToolNotice`, and go to the outer loop (a new round).
6. On `frStop`: commit the merged response as one assistant message, commit its
   reasoning once, and complete the turn.
7. On `frToolCalls`: commit the merged response (carrying the tool calls) and run
   the existing tool-round handling.
8. On anything else: discard the pending response and fail the turn with the
   mapped error.

"Commit the merged response" means: the pending content followed by the current
response's content in one assistant message, and the pending reasoning followed
by the current reasoning in one reasoning block. The pending is then cleared.

### Integration Patterns

- The loop stays single-threaded and synchronous, as today; continuation is
  another iteration, not a new thread.
- The continuation instruction and the pending overlay are request-only and are
  never appended to the store, so a later request sees the committed history
  without them.
- The live rollback runs on the app's event-handling thread, like the existing
  cancel rollback.

## Validation Rules

### Input

- `MaxContinuations < 0` disables continuation; `0` means
  `DefaultMaxContinuations`; positive values are used as given.

### Output Guarantees

- A completed turn that was continued persists exactly one assistant message for
  the response, whose content is the concatenation of the fragments.
- A failed turn persists no fragment of the pending response.
- Every persisted assistant message carrying tool calls is followed by a paired
  `crTool` message for each call.

## Error Handling

### Error Types

- **Truncation exhausted:** `leTruncated` - the response was truncated and could
  not be completed within the budget.
- **Non-continuable termination:** `leProvider` (`content_filter`, unknown, or an
  unexpected reason), as today.
- **Transport/provider failure during a continuation:** the code the client
  returns (`leNetwork`, `leHttpStatus`, `leRateLimit`, `leAuth`, ...).
- **Cancellation:** `leCancelled`, unchanged.

### Error Contracts

All failures flow through `FailTurn`, which records the turn outcome and appends
the error block. The pending response is discarded on every error path; the
error's `Detail` may carry the continuation count.

## Testing Requirements

### Unit Tests

- [ ] A response truncated once, then stopped, commits one assistant message
      whose content is the concatenation of both fragments.
- [ ] The continuation request carries the pending content and the instruction;
      neither is persisted.
- [ ] Reasoning from both fragments is committed once.
- [ ] Exhausting `MaxContinuations` fails with `leTruncated` and persists no
      assistant message.
- [ ] `MaxContinuations = -1` fails a truncated response immediately (today's
      behaviour).
- [ ] An empty-but-truncated response is continued.
- [ ] A truncated response carrying tool calls: no handler runs, each call gets a
      paired notice, and the loop continues.
- [ ] A non-continuable reason (`content_filter`, unknown) discards the pending
      response and persists no fragment.
- [ ] The context guard still fails a turn whose prompt exceeds the cap during a
      continuation.
- [ ] `leTruncated` is appended (ordinals of existing codes are unchanged).

### Integration Tests

- [ ] After a truncation error, the live block sequence equals the block
      sequence produced by restoring the persisted session.
- [ ] A tool call committed in an earlier round survives a later truncation
      error.

## Performance Targets

- At most `MaxContinuations` extra requests per truncated response; no other
  overhead.

## Security Considerations

- The continuation instruction is a fixed string; no model output is injected
  into it.
- The pending overlay is request-only, so it cannot leak into the persisted
  history or the audit tables.

## Success Criteria

### Functional

- [ ] All contracts implemented.
- [ ] All validation rules enforced.
- [ ] All error scenarios handled.
- [ ] All tests passing (`make check`).

### Quality

- [ ] Contract compliance verified.
- [ ] No memory leaks.
- [ ] Documentation complete.

## Future Considerations

- A configurable `max_tokens` with escalate-before-continue.
- A continuation counter in the turn stats and the audit tables.
- Usage-based truncation detection when `finish_reason` is absent.
