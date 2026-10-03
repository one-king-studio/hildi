# Implementation Plan: Response Continuation v1 (DONE)

**Related Specification:** `Response_Continuation_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `Response_Continuation_v1.SPEC.md`. The change is almost
entirely in `hildegard.helper.agent`, with a small change to the live error path
in `hildegard.helper.harness.app`. Complete: `make check` green at 621 tests,
leak-clean.

## Implementation Tasks

### Phase 1: Foundation

- [x] **Add the types**: `leTruncated` appended to `TLLMErrorCode` in
      `src/hildegard.helper.llm.pas`; `DefaultMaxContinuations`,
      `ContinuationInstruction`, `TruncatedToolNotice`, `TPendingResponse`, and
      `TAgentConfig.MaxContinuations` in `src/hildegard.helper.agent.pas`
- [x] **Test**: `TestErrorCodeOrdinalsStable` in `tests/test_llm.pas` - the
      ordinals of `leOk..leLoop` are unchanged and `leTruncated` is last
- [x] **Implement**: nothing further - the ordinal test goes green with the type
      declaration

### Phase 2: Continuation of text

- [x] **Test**: `TestTruncatedResponseContinuesToStop`
- [x] **Implement**: the pending buffer and the `frLength` (no tool calls)
      branch in `TAgentLoop.DoSend`; a private `BuildRequest` overload that
      overlays the pending content and `ContinuationInstruction`
- [x] **Test**: `TestContinuationCommitsOneMessage`
- [x] **Test**: `TestContinuationMergesReasoning`
- [x] **Test**: `TestContinuationRequestCarriesPending`
- [x] **Test**: `TestEmptyContentTruncationContinues`

### Phase 3: Bounds and disabling

- [x] **Test**: `TestContinuationCapFailsTurn` (and
      `TestLengthFinishReasonReported` updated for the new code)
- [x] **Test**: `TestContinuationCapUsesTruncatedCode` - covered by
      `TestContinuationCapFailsTurn` and `TestLengthFinishReasonReported`
- [x] **Test**: `TestContinuationDisabledFailsImmediately`
- [x] **Implement**: the budget check and the `leTruncated` mapping
- [x] **Test**: `TestContinuationHonoursContextGuard`

### Phase 4: Truncated tool calls

- [x] **Test**: `TestTruncatedToolCallIsNotExecuted`
- [x] **Test**: `TestTruncatedToolCallGetsPairedNotice`
- [x] **Test**: `TestTruncatedToolCallLoopContinues` - covered by
      `TestTruncatedToolCallIsNotExecuted` (asserts the loop continued)
- [x] **Implement**: the `frLength`-with-tool-calls branch, reusing
      `InterceptToolCalls` with `TruncatedToolNotice`
- [x] **Test**: `TestTruncatedToolCallNoticeIsVisible` - covered by
      `TestTruncatedToolCallGetsPairedNotice`

### Phase 5: Discard on error

- [x] **Test**: `TestNonContinuableErrorDiscardsPending`
- [x] **Test**: `TestClientErrorDiscardsPending` - covered by
      `TestErrorRollsBackStreamedBlocks` (the continuation hits a network error)
- [x] **Implement**: discard the pending response on every error path
- [x] **Test**: `TestCommittedToolRoundSurvivesLaterTruncationError`

### Phase 6: Live rollback

- [x] **Test**: `TestErrorRollsBackStreamedBlocks` in
      `tests/test_harness_app.pas`
- [x] **Implement**: remove `FAssistant`/`FThought` on the non-cancel `teError`
      path in `THarnessApp.HandleTurnEvent` (`RollBackPendingResponse`)
- [x] **Test**: `TestResumeMatchesLiveAfterTruncationError`

### Phase 7: Docs

- [x] **Update the SPEC** (the live-view section gained the system-prompt rule)
- [x] **Update** `docs/features/FEATURES.md` with the feature row
- [x] **Update** `HANDOFF.md` (state, test count)

### Phase 8: Validation

- [x] **Run**: `make test SUITE=TAgentLoopTest,TLLMClientTest` (green)
- [x] **Run**: `make test` (whole suite, 621)
- [x] **Run**: `make test-leak` (no leaks)
- [x] **Run**: `make check` (all gates, exit 0)

## Files Modified

```
src/hildegard.helper.llm.pas         leTruncated appended
src/hildegard.helper.agent.pas       pending buffer, continuation, notice, config
src/hildegard.helper.harness.app.pas error rollback; system prompt not restored
tests/test_agent.pas                 12 new tests, 1 updated
tests/test_llm.pas                   TestErrorCodeOrdinalsStable
tests/test_harness_app.pas           2 new tests
```

## Notes & Deviations

- **`BuildRequest` signature:** the SPEC sketched `BuildRequest` with the pending
  record; the implementation passes the pending *content* as a `string` and keeps
  `TPendingResponse` implementation-private. The overlay is request-only either
  way; the reasoning is not sent back.
- **Truncated tool-call round is committed.** As decided, a `length` response
  carrying tool calls commits the merged assistant message and answers each call
  with `TruncatedToolNotice` (reusing `InterceptToolCalls`), then continues. It
  also counts as a tool round, so the existing soft/hard budget bounds a model
  that keeps truncating calls.
- **Pre-existing parity bug found and fixed.** The persisted system prompt was
  restored as a `system` `ckThought` block on resume but never drawn live, so
  every resumed session diverged from the live one. `RenderHistory` no longer
  draws `mrSystem`. This was surfaced by `TestResumeMatchesLiveAfterTruncationError`
  and is in scope because the feature's acceptance criterion is live equals
  resume.
- **`FinishError`'s `frLength` branch is now unreachable** (the loop handles
  `frLength` before it). Left in place as a defensive mapping.
- **Continuation cap default is 3**, configurable; `-1` disables continuation and
  reproduces the old "truncation is an error" behaviour, now with `leTruncated`.

## Success Criteria

- [x] All tasks above checked
- [x] Every acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] Implementation matches the specification
