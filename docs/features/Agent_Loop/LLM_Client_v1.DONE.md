# Implementation Plan: LLM Client v1

**Related Specification:** `LLM_Client_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `hildegard.helper.llm` as specified in
`LLM_Client_v1.SPEC.md`. Each implementation task starts with a failing test.
Work directly on `main` (project decision).

## Implementation Tasks

### Phase 1: Setup & Foundation

- [x] **Test unit**: create `tests/test_llm.pas` with an empty `TLLMClientTest`;
      add it and a shared `tests/llm_fakes.pas` to the runner's `uses`
- [x] **Fakes**: implement `TFakeTransport` (records URL/body/headers, replays a
      chunk list) and SSE-body builders in `tests/llm_fakes.pas`
- [x] **Types**: define the interface-section types from the SPEC in
      `src/hildegard.helper.llm.pas`

### Phase 2: Config & Serialization

- [x] **Test** `TestConfigResolutionPrefersExplicit`,
      `TestConfigResolutionReadsEnvironment` - red/green
- [x] **Test** `TestMissingApiKeyFailsBeforeRequest`
- [x] **Test** `TestRequestSerializationIncludesModelMessagesAndTools`
- [x] **Test** `TestRequestSerializationIncludesToolCallsAndToolResults`
- [x] **Implement** request JSON via `fpjson`

### Phase 3: SSE Parsing & Streaming

- [x] **Test** `TestParsesTextDeltasIncrementally` - red/green
- [x] **Test** `TestEmitsTextBeforeStreamEnds`
- [x] **Test** `TestHandlesFramesSplitAcrossChunks`
- [x] **Test** `TestIgnoresCommentsAndBlankLines`
- [x] **Test** `TestStopsOnDoneSentinel`
- [x] **Implement** the SSE sink `TStream` + frame state machine

### Phase 4: Tool-call Accumulation & Finish Reason

- [x] **Test** `TestAccumulatesFragmentedToolCallArguments` - red/green
- [x] **Test** `TestAccumulatesToolCallNameSplitAcrossFrames`
- [x] **Test** `TestAccumulatesMultipleToolCalls`
- [x] **Test** `TestMapsStopFinishReason`, `TestMapsToolCallsFinishReason`,
      `TestMapsUnknownFinishReason`

### Phase 5: Error Mapping

- [x] **Test** `TestHttpErrorStatusMapsToError`
- [x] **Test** `TestAuthStatusMapsToAuthError`
- [x] **Test** `TestRateLimitMapsToRateLimitError`
- [x] **Test** `TestProviderErrorObjectMapsToProviderError`
- [x] **Test** `TestMalformedStreamMapsToMalformedError`
- [x] **Test** `TestApiKeyNeverAppearsInError`

### Phase 6: Real Transport

- [x] **Implement** `TFPHTTPTransport` with `fphttpclient` + `opensslsockets`
      (verified streaming and TLS already)
- [x] **Test** `TestRealTransportAgainstLoopback` (optional; skip if no server)

### Phase 7: Validation

- [x] **Run** `make test SUITE=TLLMClientTest` (green)
- [x] **Run** `make check` (no leaks)
- [x] **Rename** this TODO to `LLM_Client_v1.DONE.md`; update `FEATURES.md`

## Dependencies & Ordering

- Fakes before any client test.
- SSE parsing before tool-call accumulation (accumulation rides the parser).
- Real transport last; the client is fully testable with the fake beforehand.

## Files to Create/Modify

### New Files

```
src/hildegard.helper.llm.pas
tests/test_llm.pas
tests/llm_fakes.pas
```

### Modified Files

```
tests/hildegard_helper_tests.pas   (add test_llm to uses)
docs/features/Agent_Loop/          (SPEC/TODO status)
docs/features/FEATURES.md          (status)
```

## Success Criteria

- [x] All tasks checked; every SPEC test name present and passing
- [x] Streamed text observed before stream end
- [x] `make check` passes
- [x] No API key in any error/detail

## Notes & Considerations

### Resolution

- Verified up front: FPC TLS works on this platform with no extra flags, and
  `fphttpclient` writes each socket read into the supplied `TStream` and fires
  `OnDataReceived`, which is how SSE streams.
- `RawByteString` carries transport chunks so UTF-8 bytes survive until the
  parser handles them.
- The fake transport records the last request so serialization is asserted at the
  boundary rather than by exposing internal builders.
- Tests set/clear environment variables through libc `setenv`/`unsetenv` (FPC has
  no cross-platform setter) on Unix only.

### Deviations

- The optional `TestRealTransportAgainstLoopback` was not added; the real
  transport is implemented and exercised manually. It can be added later behind a
  skip when no local server is available.
- Two accumulator bugs were caught by tests and fixed: text deltas now accumulate
  into the result message (not only the callback), and an empty `id` field in a
  later tool-call frame no longer clobbers an earlier id. Tool names are
  concatenated across frames, which also tolerates a split name.

## Outcome

`hildegard.helper.llm` implemented with 22 fpcunit tests (part of the 52-test
suite), all green under `make check` including the heptrc leak gate.
