# Tool Response Wrapping

## Overview

Wrap every **in-turn tool response** the model sees, the same way
[`User_Message_Wrapping`](../User_Message_Wrapping/FEATURE.md) wraps a user turn,
so that:

- the tool's own output is always inside a `<result>` element,
- dynamic context (the skills manifest, the time) rides in a `<context>` sibling,
- and non-blocking advisories (a limit hit, a truncation) arrive as `<ambient>`
  messages *alongside* the result — never as a separate turn the model must
  follow up on.

One invariant, applied to both front doors: **the payload lives in its own
element; context and advisories are siblings, never mixed into it.**

## Problem Statement

Two problems, one cause.

**1. The manifest appears as a message with no user message.** The skills
manifest is injected as a **request-only system fragment** on *every* request
(`agent.pas:891-917`), including the mid-turn ones (one per tool round). Mid-turn
requests append tool results and no user message, so the model receives a fresh
`system` message containing the manifest with nothing to anchor it — and reports
exactly that: *"a manifest message without any user message mid-turn."* It is
also re-sent (whole) every round: a real token cost.

**2. Limit warnings block.** A tool that hits a limit (output truncated, results
capped, a timeout) returns an error-ish result that forces the model into a
**follow-up call** just to learn the limit was hit. The warning is information,
not a failure — it should ride along with the result.

## Decision

1. **Every in-turn tool response is wrapped** as:
   ```
   <context>
     <now>ISO</now>
     <skills>…</skills>
   </context>
   <result tool="NAME" id="CALL_ID" status="ok|error">
   …the tool's output…
   </result>
   ```
2. **The skills manifest lives in `<context>`**, attached to the user message
   (turn start) and to each tool response (mid-turn) — so it is always present
   *and* always anchored to a message. The standalone per-request system fragment
   goes away.
3. **Advisories are `<ambient>` messages**, emitted alongside the result:
   ```
   <ambient timestamp="ISO">
     <message source="tool" id="CALL_ID" label="NAME" status="truncated">
   …the advisory…
     </message>

     <instructions>…</instructions>
   </ambient>
   ```
   A limit is reported, not enforced by blocking: the tool returns what it has
   **plus** the advisory, in one response.
4. **Reuse `FormatAmbient`.** The ambient wrapper already exists
   (`hildi.ambient`); advisories use it. `FormatUserMessage` and the
   new `FormatToolResult` share its escapers.

## Goals

- A tool response is delivered as `<context>…</context><result …>…</result>`,
  with any advisories as `<ambient>` siblings.
- The skills manifest is delivered inside `<context>` on the user turn and each
  tool response — never as a standalone system message.
- A tool limit produces an **advisory**, not a blocking error: no follow-up call
  is needed to learn the limit was hit.
- The persisted records stay **plain** — the wrapper is applied on the way out,
  exactly as user messages and ambient records already are.

## Acceptance Criteria

- [ ] A tool result is delivered wrapped: `<result tool="…" id="…" status="…">`.
- [ ] The tool's own output is XML-escaped inside `<result>`, so it cannot close
      the element.
- [ ] The skills manifest appears in the `<context>` block of the user message and
      of each tool response — and **nowhere else** (the per-request system
      fragment is removed).
- [ ] A limit (truncation / cap / timeout) yields the result **and** an
      `<ambient>` advisory in the same response; the model is not required to
      make a follow-up call.
- [ ] The persisted tool record is byte-identical to today's; the wrapper is
      added only on delivery.
- [ ] A resumed session composes identically to a live one.

## Out of Scope

- The **content** of the skills manifest — only its placement.
- Changing which limits exist; only how they are reported.
- Tool-call *requests* (the model's calls) — this is about responses.

## Open Questions

- **`<context>` per response is repeated.** Each tool response carries the
  manifest, so a long turn repeats it N times. Cheaper: the manifest rides the
  **first** response of a turn (or the user message only), and mid-turn responses
  carry a short `<context>` (time) — decide in the SPEC.
- **`status` values.** `ok` / `error` for sure; whether `truncated` is a status
  or only an advisory is a SPEC decision.
- **Do advisories go in the same message or a following one?** Same response is
  the intent (one round-trip); confirm the provider tolerates a system/user
  message carrying both.

## Notes

- **The reference does not wrap tool results** (it wraps user and system-event
  messages). This is our extension, using the same invariant.
- **Pairs with** `User_Message_Wrapping` (the front door) — both make dynamic
  context a sibling of the payload, so nothing dynamic can be mistaken for the
  payload.
- **Fixes** the "manifest message without a user message" symptom at the root:
  the manifest stops being a message of its own.
