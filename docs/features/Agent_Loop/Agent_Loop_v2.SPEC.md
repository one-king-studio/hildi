# Component Specification: Agent Loop v2 (Events)

**Related Specification:** `Agent_Loop_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

v2 makes the loop's internal activity observable so a UI can render it:
reasoning (dimmed), tool invocations, and tool results. v1 exposed only the
assistant text callback. v2 adds an events record without breaking the v1
`Send` signature.

## Requirements

### Functional

- [ ] Forward the client's reasoning deltas through an events callback.
- [ ] Fire a tool-call event for each invocation, before it runs, with id, name,
      and raw arguments.
- [ ] Fire a tool-result event after it runs, with the result text and whether it
      succeeded (unknown tool / handler failure / exception => `AOk = False`).
- [ ] Keep the v1 `Send` overload working unchanged.

### Non-Functional

Same as v1 (single-threaded, offline-testable, leak-clean).

## Contracts & Interfaces

```pascal
type
  TToolCallEvent = procedure(const AId, AName, AArguments: string) of object;
  TToolResultEvent = procedure(const AId, AName, const AResult: string;
    AOk: Boolean) of object;

  TAgentEvents = record
    OnText: TLLMTextEvent;            // final answer stream
    OnReasoning: TLLMReasoningEvent;  // thinking stream
    OnToolCall: TToolCallEvent;
    OnToolResult: TToolResultEvent;
  end;

  TAgentLoop = class
  public
    { v1 signature, unchanged; forwards only OnText }
    function Send(const AUserText: string; AOnText: TLLMTextEvent;
      out AAnswer: string; out AError: TLLMError): Boolean; overload;

    { v2: full event surface }
    function Send(const AUserText: string; const AEvents: TAgentEvents;
      out AAnswer: string; out AError: TLLMError): Boolean; overload;
  end;
```

### Ordering Guarantees

For each assistant turn with tool calls, the sequence is:
`OnReasoning*` / `OnText*`, then for each call in order `OnToolCall`, execution,
`OnToolResult`. Events fire on the calling thread.

## Testing Requirements

`test_agent.pas` additions:

- [ ] `TestReasoningForwardedThroughEvents`
- [ ] `TestToolCallEventFiresWithNameAndArgs`
- [ ] `TestToolResultEventFiresWithResult`
- [ ] `TestToolResultEventReportsFailure`
- [ ] `TestToolCallAndResultEventsAreInOrder`
- [ ] `TestV1SendOverloadStillWorks`

## Future Considerations

- Token usage / timing events.
- A structured event record instead of parallel callbacks if the surface grows.
