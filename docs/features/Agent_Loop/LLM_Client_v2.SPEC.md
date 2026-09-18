# Component Specification: LLM Client v2 (Reasoning Stream)

**Related Specification:** `LLM_Client_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

v2 adds a second streamed channel: **reasoning** text. Reasoning-capable
OpenAI-compatible models (for example DeepSeek-R1 style endpoints) emit the
model's thinking separately from the answer. v1 discarded it; v2 captures it,
surfaces it through its own callback, and accumulates it into the result so a UI
can show it dimmed. Reasoning is display-only: it is **not** part of the
assistant message sent back to the provider.

## Requirements

### Functional

- [ ] Parse `delta.reasoning_content` (preferred) or `delta.reasoning` from each
      SSE frame.
- [ ] Fire a reasoning callback for each non-empty reasoning delta.
- [ ] Accumulate reasoning into the result, separate from `Message.Content`.
- [ ] Keep the v1 `Complete` overload working unchanged.

### Non-Functional

Same as v1 (streaming, no leaks, testable offline).

## Contracts & Interfaces

```pascal
type
  TChatResult = record
    Message: TChatMessage;       // unchanged: content + tool calls
    FinishReason: TFinishReason;
    RawFinishReason: string;
    ReasoningContent: string;    // NEW: display-only thinking text
  end;

  TLLMReasoningEvent = procedure(const AText: string) of object;   // NEW

  TLLMClient = class
  public
    { v1 signature, unchanged; forwards AOnReasoning = nil }
    function Complete(const ARequest: TChatRequest; AOnText: TLLMTextEvent;
      out AResult: TChatResult; out AError: TLLMError): Boolean; overload;

    { v2: adds the reasoning channel }
    function Complete(const ARequest: TChatRequest; AOnText: TLLMTextEvent;
      AOnReasoning: TLLMReasoningEvent;
      out AResult: TChatResult; out AError: TLLMError): Boolean; overload;
  end;
```

### Data Contract

A reasoning delta frame:

```json
{"choices":[{"delta":{"reasoning_content":"Let me think..."}}]}
```

Rules: `reasoning_content` wins if both fields are present; text goes to
`ReasoningContent` and the callback; it never affects `Message.Content` or the
request serialization.

## Testing Requirements

`test_llm.pas` additions:

- [ ] `TestEmitsReasoningDeltasSeparately`
- [ ] `TestReasoningAccumulatedInResult`
- [ ] `TestReasoningNotInMessageContent`
- [ ] `TestReasoningContentPreferredOverReasoning`
- [ ] `TestV1CompleteOverloadStillWorks`

## Future Considerations

- Provider-specific reasoning field names via configuration.
- Optionally persisting reasoning for audit, separate from the conversation.
