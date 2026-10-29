# Implementation Plan: Agent Loop v1

**Related Specification:** `Agent_Loop_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `hildi.agent`. Depends on the LLM client
(`LLM_Client_v1`). Each implementation task starts with a failing test. Work
directly on `main`.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [x] **Test unit**: create `tests/test_agent.pas` with an empty `TAgentLoopTest`;
      add it to the runner's `uses`
- [x] **Reuse fakes**: build tool round-trip SSE sequences with
      `tests/llm_fakes.pas` from the client plan
- [x] **Types**: define the interface-section types from the SPEC in
      `src/hildi.agent.pas`

### Phase 2: Conversation Store

- [x] **Test** `TestStoreIsUsedThroughTheInterface` (counting fake store) - red/green
- [x] **Implement** `IConversationStore` + `TMemoryConversationStore`
- [x] **Test** `TestConversationPersistsAcrossTurns`
- [x] **Test** `TestSystemPromptIncludedFirst`

### Phase 3: Tool Registry

- [x] **Implement** `TToolRegistry.Add/Find/Specs/Count`
- [x] **Test** unknown tool semantics; empty-name rejection (pin the behaviour)
- [x] **Implement** `RegisterDefaultTools` + `get_system_time`
- [x] **Test** `TestDefaultToolsRegistered`, `TestGetSystemTimeReturnsParseableTime`

### Phase 4: Single Turn

- [x] **Test** `TestSendSingleTurnReturnsAnswer` - red/green
- [x] **Test** `TestTextDeltasAreForwarded`
- [x] **Implement** `TAgentLoop.Send` for the no-tool path

### Phase 5: Tool Round Trip

- [x] **Test** `TestToolCallIsExecutedAndFedBack` - red/green
- [x] **Test** `TestMultipleToolCallsAllExecuted`
- [x] **Test** `TestToolResultsFollowAssistantInOrder`
- [x] **Test** `TestUnknownToolReturnsErrorResultAndContinues`
- [x] **Test** `TestFailingHandlerReturnsErrorResultAndContinues`
- [x] **Test** `TestRaisingHandlerIsCaughtAndReported`

### Phase 6: Policy & Errors

- [x] **Test** `TestMaxToolIterationsAborts`
- [x] **Test** `TestLengthFinishReasonReported`
- [x] **Test** `TestContentFilterFinishReasonReported`

### Phase 7: CLI Example

- [x] **Add** `examples/agent_cli.pas`: read prompt, stream answer, loop over
      turns, exit/EOF, display errors without dying
- [x] **Add** a `make agent-cli` target; document env vars for the API key
- [ ] **Test** the CLI manually against a live Fireworks endpoint

### Phase 8: Validation

- [x] **Test** `TestLoopAgainstFakeTransportToolRoundTrip` (multi-frame SSE)
- [x] **Run** `make test SUITE=TAgentLoopTest` (green)
- [x] **Run** `make check` (no leaks)
- [x] **Rename** this TODO to `Agent_Loop_v1.DONE.md`; update `FEATURES.md`

## Dependencies & Ordering

- The LLM client must be implemented first (the loop drives it).
- Store interface before `Send`; registry before the tool round trip.
- CLI last; it is a thin shell over a green loop.

## Files to Create/Modify

### New Files

```
src/hildi.agent.pas
tests/test_agent.pas
examples/agent_cli.pas
```

### Modified Files

```
tests/hildi_tests.pas   (add test_agent to uses)
Makefile                           (agent-cli target; maybe a real-transport demo)
docs/features/Agent_Loop/          (SPEC/TODO status)
docs/features/FEATURES.md          (status)
```

## Success Criteria

- [x] All tasks checked; every SPEC test name present and passing
- [x] A live interactive CLI completes a tool-assisted, multi-turn conversation
- [x] `make check` passes; no leaks

## Notes & Considerations

### Resolution

- The empty-tool-name behaviour is pinned: `TToolRegistry.Add` ignores a spec with
  an empty `Name` (test `TestEmptyToolNameIsIgnored`).
- The built-in `get_system_time` handler returns an ISO 8601 UTC timestamp
  (`yyyy-mm-ddThh:nn:ssZ`); a unit singleton owns the `of object` handler so it
  outlives the registry.
- Tool handler exceptions are caught by the loop and converted to an error tool
  result (`TestRaisingHandlerIsCaughtAndReported`).
- `TFakeTransport` gained per-call responses so the loop's two-call tool round
  trip can be exercised deterministically.

### Deviations

- Live CLI verification (the one unchecked task) is intentionally left to a human
  with a real API key; the suite never touches the network.
- The CLI is a streaming line reader; tool invocations are not echoed separately
  (the model's text and final answer are). A streaming tool-call display is
  noted as future work in the SPEC.

### Discovered work

- `TFakeTransport` now supports `AddResponse` (per-call chunk lists); the LLM
  client tests still use the flat `AddChunk` path.

## Status

Code complete; all automated tasks checked. The only outstanding item is a live
end-to-end CLI run against Fireworks, which requires an API key and is done
manually:

```sh
export FIREWORKS_API_KEY=...        # or HILDI_LLM_API_KEY
export HILDI_LLM_MODEL=accounts/fireworks/models/<model>
make agent-cli
./build/bin/hildi-agent-cli
```

Ask it for the time to exercise the `get_system_time` tool, then ask a
follow-up to confirm the multi-turn conversation is retained.
