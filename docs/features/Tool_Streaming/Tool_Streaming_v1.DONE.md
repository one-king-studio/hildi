# Implementation Plan: Tool Streaming v1 (DONE)

**Related Specification:** `Tool_Streaming_v1.SPEC.md`
**Related Feature:** `FEATURE.md`
**Status:** Implemented — `make check` green (786 tests, leak-clean).

## Overview

Task breakdown for `Tool_Streaming_v1.SPEC.md`, implemented test-first. The seam
first, then the command tool, then the live path, then the UI.

## Implementation Tasks

### Phase 1: The observer seam

- [x] **Test**: `TestObserverForwardsChunks`, `TestSingleShotToolEmitsNoChunks`,
      `TestForwardObserverDropsChunksAfterComplete` in `tests/test_agent.pas`
- [x] **Implement**: `TToolObserver`, `TToolOutputEvent`, the `TToolHandler`
      parameter, `TAgentEvents.OnToolOutput`, and the forwarding observer in
      `src/hildi.agent.pas`
- [x] **Implement**: the parameter on every handler
      (`src/hildi.files.pas`, `src/hildi.recall.tool.pas`)

### Phase 2: The command tool

- [x] **Test**: `TestRunCommandStreamsOutput`, `TestCommandTimeoutIsClampedToMax`,
      `TestTimeoutIsHonouredWithoutACap` in `tests/test_command_tool.pas`
- [x] **Implement**: the observer through `ICommandExecutor` and
      `TProcessCommandExecutor`; `MaxTimeoutMs` and the clamp in
      `src/hildi.command.tool.pas`
- [x] **Implement**: `HILDI_COMMAND_TIMEOUT_MS` (an optional cap) in
      `src/hildi.harness.session.pas`

### Phase 3: The live path

- [x] **Test**: `TestWorkerEmitsToolOutput` in `tests/test_harness_turn.pas`
- [x] **Implement**: `teToolOutput` and the worker mapping in
      `src/hildi.harness.turn.pas`
- [x] **Test**: `tool_output` round trip in `tests/test_session_protocol.pas`
      (the all-kinds loop covers it)
- [x] **Implement**: `ekToolOutput` in
      `src/hildi.session.protocol.pas`; the runtime mapping in
      `src/hildi.session.runtime.pas`; the sink mapping in
      `src/hildi.harness.driver.pas`

### Phase 4: The UI

- [x] **Test**: `TestAppStreamsToolOutput`, `TestResumeShowsTheResult` in
      `tests/test_harness_app.pas`
- [x] **Implement**: append the streamed chunk to the live tool block and
      replace the body with the result on completion, bounded by the cap, in
      `src/hildi.harness.app.pas` (via `TChatItem.Live`; the cap is
      applied by `TCappedObserver` in the command tool)

### Phase 5: Docs and validation

- [x] **Update**: the protocol spec, `docs/features/FEATURES.md`, `HANDOFF.md`,
      the design preview
- [x] **Run**: `make check` (tests + leak gate)

## Outcome

The seam landed as an optional trailing parameter
(`AObserver: TToolObserver = nil`) so the ~50 existing direct handler calls in
the tests compile unchanged and `nil` reads as "single-shot".

Beyond the plan:

- `TToolForwardObserver` is exported from `hildi.agent` so its
  "drop chunks after `Complete`" contract is unit-tested directly.
- `TCappedObserver` (command tool) bounds the live body to `MaxOutputBytes`, so
  an unbounded command (`yes`) cannot grow the live block without end.
- The model defines its own `run_command` timeout. `MaxTimeoutMs` (from
  `HILDI_COMMAND_TIMEOUT_MS`) is an **opt-in** cap, default off, so the model
  is not silently limited; the tool description tells it to raise the timeout for
  slow commands.
- The live block uses the existing `TChatItem.Live` state (auto-expanded tail),
  settling to collapsed on the result — so live and resume match.

## Files Created/Modified

### New Files

```
docs/features/Tool_Streaming/FEATURE.md
docs/features/Tool_Streaming/Tool_Streaming_v1.SPEC.md
docs/features/Tool_Streaming/Tool_Streaming_v1.DONE.md
```

### Modified Files

```
src/hildi.agent.pas             the observer seam + forwarding observer
src/hildi.files.pas             the handler parameter
src/hildi.recall.tool.pas       the handler parameter
src/hildi.command.tool.pas      streaming executor + timeout cap + capped observer
src/hildi.harness.session.pas   HILDI_COMMAND_TIMEOUT_MS
src/hildi.harness.turn.pas      teToolOutput
src/hildi.session.protocol.pas  ekToolOutput
src/hildi.session.runtime.pas   map teToolOutput
src/hildi.harness.driver.pas    map ekToolOutput
src/hildi.harness.app.pas       live append + result replace
tests/test_agent.pas                       the observer tests
tests/test_command_tool.pas                the streaming + clamp tests
tests/test_harness_turn.pas                the worker streaming test
tests/test_harness_app.pas                 the app streaming tests
tests/test_session_protocol.pas            the tool_output round trip
docs/features/FEATURES.md                  the index row
docs/features/Headless_Sessions/Session_Protocol_v1.SPEC.md  the tool_output event
docs/design/tui_design_language.html       the tool streaming section
HANDOFF.md                                 the feature row
```

## Success Criteria

- [x] All tasks above checked
- [x] Every acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] A live and a resumed tool block render the same body
