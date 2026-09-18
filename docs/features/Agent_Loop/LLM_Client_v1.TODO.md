# Implementation Plan: LLM Client v1

**Related Specification:** `LLM_Client_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `hildegard.helper.llm` as specified in
`LLM_Client_v1.SPEC.md`. Each implementation task starts with a failing test.
Work directly on `main` (project decision).

## Implementation Tasks

### Phase 1: Setup & Foundation

- [ ] **Test unit**: create `tests/test_llm.pas` with an empty `TLLMClientTest`;
      add it and a shared `tests/llm_fakes.pas` to the runner's `uses`
- [ ] **Fakes**: implement `TFakeTransport` (records URL/body/headers, replays a
      chunk list) and SSE-body builders in `tests/llm_fakes.pas`
- [ ] **Types**: define the interface-section types from the SPEC in
      `src/hildegard.helper.llm.pas`

### Phase 2: Config & Serialization

- [ ] **Test** `TestConfigResolutionPrefersExplicit`,
      `TestConfigResolutionReadsEnvironment` - red/green
- [ ] **Test** `TestMissingApiKeyFailsBeforeRequest`
- [ ] **Test** `TestRequestSerializationIncludesModelMessagesAndTools`
- [ ] **Test** `TestRequestSerializationIncludesToolCallsAndToolResults`
- [ ] **Implement** request JSON via `fpjson`

### Phase 3: SSE Parsing & Streaming

- [ ] **Test** `TestParsesTextDeltasIncrementally` - red/green
- [ ] **Test** `TestEmitsTextBeforeStreamEnds`
- [ ] **Test** `TestHandlesFramesSplitAcrossChunks`
- [ ] **Test** `TestIgnoresCommentsAndBlankLines`
- [ ] **Test** `TestStopsOnDoneSentinel`
- [ ] **Implement** the SSE sink `TStream` + frame state machine

### Phase 4: Tool-call Accumulation & Finish Reason

- [ ] **Test** `TestAccumulatesFragmentedToolCallArguments` - red/green
- [ ] **Test** `TestAccumulatesToolCallNameSplitAcrossFrames`
- [ ] **Test** `TestAccumulatesMultipleToolCalls`
- [ ] **Test** `TestMapsStopFinishReason`, `TestMapsToolCallsFinishReason`,
      `TestMapsUnknownFinishReason`

### Phase 5: Error Mapping

- [ ] **Test** `TestHttpErrorStatusMapsToError`
- [ ] **Test** `TestAuthStatusMapsToAuthError`
- [ ] **Test** `TestRateLimitMapsToRateLimitError`
- [ ] **Test** `TestProviderErrorObjectMapsToProviderError`
- [ ] **Test** `TestMalformedStreamMapsToMalformedError`
- [ ] **Test** `TestApiKeyNeverAppearsInError`

### Phase 6: Real Transport

- [ ] **Implement** `TFPHTTPTransport` with `fphttpclient` + `opensslsockets`
      (verified streaming and TLS already)
- [ ] **Test** `TestRealTransportAgainstLoopback` (optional; skip if no server)

### Phase 7: Validation

- [ ] **Run** `make test SUITE=TLLMClientTest` (green)
- [ ] **Run** `make check` (no leaks)
- [ ] **Rename** this TODO to `LLM_Client_v1.DONE.md`; update `FEATURES.md`

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

- [ ] All tasks checked; every SPEC test name present and passing
- [ ] Streamed text observed before stream end
- [ ] `make check` passes
- [ ] No API key in any error/detail

## Notes & Considerations

- Verified up front: FPC TLS works on this platform with no extra flags, and
  `fphttpclient` writes each socket read into the supplied `TStream` and fires
  `OnDataReceived`, which is how SSE streams.
- `RawByteString` is used for transport chunks to avoid encoding loss before the
  parser decides.
- The fake transport records the last request so serialization is asserted at the
  boundary rather than by exposing internal builders.
