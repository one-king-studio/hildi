# Implementation Plan: Tool-Call Reason v1

**Related Specification:** `Tool_Reason_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Add a required, non-empty `reason` string to every advertised tool and validate
it before dispatch, surfacing it on the tool-call event. This is a change to the
shared tool contract in `hildi.agent` plus the transcript, and it is
the foundation the Command Tool's approval and audit build on. Do this first.

> Deviation from template: this project is `main`-only (`HANDOFF.md`), so no
> feature branch is created. Commit progressively on `main`.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [x] **No new test unit**: extend `tests/test_agent.pas` and
      `tests/test_transcript.pas` in place
- [x] **Define the changed event signature and constants** in the interface of
      `src/hildi.agent.pas`:
      `TToolCallEvent` gains `AReason`; add `ToolReasonParamName = 'reason'`
      and `ExtractToolReason`

### Phase 2: Core Implementation (TDD)

- [x] **Test**: `TestRegistrationAddsRequiredReasonParam` - red
- [x] **Implement**: `TToolRegistry.Add` augments `ParametersJson` to include a
      required `reason` string (fpjson, idempotent); malformed schema handled
      per spec - green
- [x] **Test**: `TestRegistrationPreservesExistingParams`, `TestRegistrationIsIdempotent`
- [x] **Test**: `TestExtractReasonAcceptsNonEmpty` / `RejectsMissing` /
      `RejectsBlank` / `RejectsNonString` / `RejectsInvalidJson` - red
- [x] **Implement**: `ExtractToolReason` with `fpjson` - green
- [x] **Test**: `TestCallWithoutReasonReturnsErrorAndContinues` - red
- [x] **Implement**: in `ExecuteToolCalls`, extract `reason`; on failure emit
      `OnToolCall` with reason `''`, append
      `error: tool "<name>" missing required "reason"`, set `AAllOk := False`,
      skip the handler - green
- [x] **Test**: `TestHandlerReceivesFullArgumentsIncludingReason` (handler still
      sees the untouched JSON)
- [x] **Test**: `TestToolCallEventCarriesReason`, update
      `TestToolCallEventFiresWithNameAndArgs` and
      `TestToolCallAndResultEventsAreInOrder` for the new parameter
- [x] **Test**: `TestPromptAdvertisesReasonRequired` (serialized request schema
      contains the reason property and required entry)

### Phase 3: Transcript

- [x] **Test**: `TestTranscriptShowsToolCallReason` - red
- [x] **Implement**: `TTranscriptWriter.OnToolCall` gains `AReason`; render it on
      the tool-call line (labelled form when colour is off) - green
- [x] **Update**: existing transcript tests for the new signature
- [x] **Update**: `examples/agent_cli.pas` event wiring

### Phase 4: Docs

- [x] **Cross-reference**: add a note in `Agent_Loop_v1.SPEC.md` (or its feature)
      that this spec supersedes the `TToolCallEvent` contract
- [x] **Doc comments** on the new/changed public interface

### Phase 5: Validation

- [x] `make test SUITE=TestAgentLoop`
- [x] `make test SUITE=TestTranscript`
- [x] `make test` (whole suite - `get_system_time` and loop tests must still pass)
- [x] `make test-leak`
- [x] `make check`

## Dependencies & Ordering

### Must Complete Before Starting

- Nothing; this is the first component. It blocks the Command Tool.

### Critical Path

1. Event signature + constants
2. Schema augmentation (registry)
3. Extraction + loop validation
4. Transcript + CLI
5. `make check`

## Files to Create/Modify

### New Files

```
(none)
```

### Modified Files

```
src/hildi.agent.pas      (event, constants, ExtractToolReason, registry, loop)
src/hildi.transcript.pas (OnToolCall gains AReason)
examples/agent_cli.pas              (event wiring)
tests/test_agent.pas                (new + updated cases)
tests/test_transcript.pas           (new + updated cases)
docs/features/Agent_Loop/Agent_Loop_v1.SPEC.md  (cross-reference note)
```

## Success Criteria

- [x] Every advertised tool requires `reason`
- [x] Missing/blank reason is an error tool result, not execution
- [x] Reason reaches the tool-call event and the transcript
- [x] `make check` passes
- [x] Implementation matches the specification

## Notes & Considerations

- The event signature change is source-breaking for any `OnToolCall` assignee;
  the only ones are `TTranscriptWriter` and the test `TEventLog`. Grep before
  editing.
- Auto-injection mutates the stored `ParametersJson`; keep it idempotent and
  preserve caller-supplied properties.
- Do not use string concatenation to build the augmented JSON; use `fpjson`.
- Deviation: the spec's `TestRoundTripWithReasonAgainstFakeTransport` is covered
  by the updated `TestToolCallIsExecutedAndFedBack` (its tool call now carries a
  reason) rather than a separately named test. The registry also rejects a
  malformed schema (extra case `TestMalformedSchemaIsIgnored`).
