# Implementation Plan: LLM Client v2 (Reasoning Stream)

**Related Specification:** `LLM_Client_v2.SPEC.md`

## Tasks

- [x] `TChatResult.ReasoningContent`; `TLLMReasoningEvent`
- [x] Parse `delta.reasoning_content` (preferred) or `delta.reasoning`
- [x] Reasoning accumulator + callback in `TSSEParser`
- [x] `Complete` overload with the reasoning callback; v1 overload delegates
- [x] `tests/test_llm.pas`: five named reasoning tests
- [x] `llm_fakes.pas`: `ReasoningDelta` / `AlsoReasoningDelta`

## Outcome

22 -> 27 client tests. Reasoning is display-only and never enters
`Message.Content` or request serialization.
