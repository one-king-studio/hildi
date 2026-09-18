# Implementation Plan: Agent Loop v2 (Events)

**Related Specification:** `Agent_Loop_v2.SPEC.md`

## Tasks

- [x] `TToolCallEvent`, `TToolResultEvent`, `TAgentEvents`
- [x] `Send` overload taking `TAgentEvents`; v1 overload delegates with only text
- [x] Forward reasoning; fire tool-call before execution and tool-result after
      (with `AOk = False` for unknown/failing/raising tools)
- [x] `tests/test_agent.pas`: six named event tests

## Outcome

17 -> 23 loop tests. Events fire on the calling thread, in order:
`OnToolCall` then `OnToolResult` per call.
