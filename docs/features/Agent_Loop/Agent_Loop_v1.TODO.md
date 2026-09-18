# Implementation Plan: Agent Loop v1

**Related Specification:** `Agent_Loop_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `hildegard.helper.agent`. Depends on the LLM client
(`LLM_Client_v1`). Each implementation task starts with a failing test. Work
directly on `main`.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [ ] **Test unit**: create `tests/test_agent.pas` with an empty `TAgentLoopTest`;
      add it to the runner's `uses`
- [ ] **Reuse fakes**: build tool round-trip SSE sequences with
      `tests/llm_fakes.pas` from the client plan
- [ ] **Types**: define the interface-section types from the SPEC in
      `src/hildegard.helper.agent.pas`

### Phase 2: Conversation Store

- [ ] **Test** `TestStoreIsUsedThroughTheInterface` (counting fake store) - red/green
- [ ] **Implement** `IConversationStore` + `TMemoryConversationStore`
- [ ] **Test** `TestConversationPersistsAcrossTurns`
- [ ] **Test** `TestSystemPromptIncludedFirst`

### Phase 3: Tool Registry

- [ ] **Implement** `TToolRegistry.Add/Find/Specs/Count`
- [ ] **Test** unknown tool semantics; empty-name rejection (pin the behaviour)
- [ ] **Implement** `RegisterDefaultTools` + `get_system_time`
- [ ] **Test** `TestDefaultToolsRegistered`, `TestGetSystemTimeReturnsParseableTime`

### Phase 4: Single Turn

- [ ] **Test** `TestSendSingleTurnReturnsAnswer` - red/green
- [ ] **Test** `TestTextDeltasAreForwarded`
- [ ] **Implement** `TAgentLoop.Send` for the no-tool path

### Phase 5: Tool Round Trip

- [ ] **Test** `TestToolCallIsExecutedAndFedBack` - red/green
- [ ] **Test** `TestMultipleToolCallsAllExecuted`
- [ ] **Test** `TestToolResultsFollowAssistantInOrder`
- [ ] **Test** `TestUnknownToolReturnsErrorResultAndContinues`
- [ ] **Test** `TestFailingHandlerReturnsErrorResultAndContinues`
- [ ] **Test** `TestRaisingHandlerIsCaughtAndReported`

### Phase 6: Policy & Errors

- [ ] **Test** `TestMaxToolIterationsAborts`
- [ ] **Test** `TestLengthFinishReasonReported`
- [ ] **Test** `TestContentFilterFinishReasonReported`

### Phase 7: CLI Example

- [ ] **Add** `examples/agent_cli.pas`: read prompt, stream answer, loop over
      turns, exit/EOF, display errors without dying
- [ ] **Add** a `make agent-cli` target; document env vars for the API key
- [ ] **Test** the CLI manually against a live Fireworks endpoint

### Phase 8: Validation

- [ ] **Test** `TestLoopAgainstFakeTransportToolRoundTrip` (multi-frame SSE)
- [ ] **Run** `make test SUITE=TAgentLoopTest` (green)
- [ ] **Run** `make check` (no leaks)
- [ ] **Rename** this TODO to `Agent_Loop_v1.DONE.md`; update `FEATURES.md`

## Dependencies & Ordering

- The LLM client must be implemented first (the loop drives it).
- Store interface before `Send`; registry before the tool round trip.
- CLI last; it is a thin shell over a green loop.

## Files to Create/Modify

### New Files

```
src/hildegard.helper.agent.pas
tests/test_agent.pas
examples/agent_cli.pas
```

### Modified Files

```
tests/hildegard_helper_tests.pas   (add test_agent to uses)
Makefile                           (agent-cli target; maybe a real-transport demo)
docs/features/Agent_Loop/          (SPEC/TODO status)
docs/features/FEATURES.md          (status)
```

## Success Criteria

- [ ] All tasks checked; every SPEC test name present and passing
- [ ] A live interactive CLI completes a tool-assisted, multi-turn conversation
- [ ] `make check` passes; no leaks

## Notes & Considerations

- **API key handling:** the CLI reads it from the environment; it is never
  written to disk or logs. Do not commit it.
- **Live testing** happens only via the CLI, never in the suite.
- Pin the empty-tool-name behaviour in a test either way (raise vs ignore).
- Record spec deviations here as they occur.
