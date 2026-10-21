# Prompt Cache and Where Injected Content Lives

**Status:** Live — a measured-looking defect with a decided fix. Read before
changing `BuildRequest` or anything that decorates a message.
**Related:** [wrap.pas](../../src/hildegard.helper.wrap.pas),
`TAgentLoop.BuildRequest` (`src/hildegard.helper.agent.pas`),
[Context Budget](../features/Context_Budget/FEATURE.md),
[Tool Limits](../features/Tool_Limits/FEATURE.md)

## The problem in one line

Every request in a turn rewrites a message the provider has already seen, so the
prompt cache breaks at index 1 and the whole turn re-bills on every round.

## How the cache works, and why placement is everything

OpenAI-compatible providers cache a **prefix**. The first request in a
conversation is billed in full; a later request whose leading bytes are identical
to one already sent is billed at a fraction for that shared prefix, and in full
only from the first differing byte onward. The handle is positional: **a change at
index *i* invalidates *i* and everything after it.**

We already track the effect — `TChatUsage.CachedTokens` from
`prompt_tokens_details.cached_tokens` (`llm.pas`), shown as a percentage in the
status bar. The number was always there; nobody had asked why the head of the
conversation was moving.

## Two invalidations, both in the head

`TAgentLoop.BuildRequest` composes the request from `FStore.Messages` (the plain
persisted history) and then decorates it. Two decorations move:

**1. Within a turn — the user wrap.** `BuildRequest` searches backwards for the
last `crUser` message and replaces its content with `FormatUserMessage(...)`.
That wrapper contains `<now>` and `<usage used=… limit=…>`, both of which change
on every request. So during a ten-round turn, the message at index 1 is rewritten
ten times, and rounds 2–10 are billed almost in full.

Skills make it worse: `PromptFragment` is also concatenated into that same
wrapper, so **loading a skill mid-turn invalidates the cache at the exact moment
the agent starts doing real work.**

**2. Across turns — the wrap disappears.** The wrapper is request-only (the store
keeps plain content). During turn 1 the last user message is the wrapped one;
during turn 2 a *newer* user message takes the decoration, so the older one is
sent **plain**. The same index therefore carries different bytes in different
turns:

| Request | content at that index |
| --- | --- |
| turn 1, round 3 | `<context><now>…</now>…</context><instructions>…</instructions><message>hi</message><guard>…</guard>` |
| turn 2, round 1 | `hi` |

A long session therefore re-bills from its first user message on every new turn.
This is the larger of the two, and it is invisible in a short session.

**3. The advisory has the same shape.** `FormatAdvisory` prepends a `<context>`
block to the last `crTool` message and clears `FPendingAdvisory`. The next request
rebuilds from the store, where that tool result is plain — so the same message is
sent with the block and then without it. This one was believed safe because the
decoration lands on a *new* message, which is true on the request that adds it and
false on the one after.

## The rule

> **Decorate exactly one message: the last one. Never rewrite anything already
> sent.**

Because the store never holds a wrapper, the decoration simply is not there on the
next pass — the previously decorated message reverts to its stored form and the
newest message takes the block. Nothing has to be un-wrapped, because nothing was
ever persisted wrapped.

The consequence is the property worth stating as an invariant: **the sent history
converges to the stored history as a turn progresses**, and at the turn boundary
it *is* the stored history. That is what makes cross-turn caching possible; a
scheme that freezes the wrapper at its original position can never get there,
because the stored and sent forms diverge permanently.

### What the cost becomes

| Request | First differing message | Re-billed |
| --- | --- | --- |
| 1 (turn start) | — | the whole prompt (cold) |
| 2 | the previous tail reverts to plain | previous tail + new message |
| 3 | `tool1` reverts | `tool1` + the new message |
| *n* | `tool(n−2)` reverts | one message + the new one |
| next turn, 1 | the last tool result reverts | that message + the new user message |

Per round: **O(1) instead of O(round)**. Across turns: one message instead of the
whole conversation.

## The shape

| Region | Content | Lifetime |
| --- | --- | --- |
| System prompt | base prompt, behavioural `<instructions>`, workspace root | once per session |
| User messages | the operator's text, exactly | never rewritten |
| Tool results | the tool's own text | never rewritten |
| **Tail block** | `<now>`, `<usage>`, skills state, board unread, guard | composed once per message, then frozen |

The tail block is the only dynamic part:

```
<context>
  <now>2026-10-21T07:16:51Z</now>
  <usage used="412996" limit="1000000">41%</usage>
  <board unread="2">9afd… posted "parser rewrite"</board>
</context>
<guard>…</guard>
```

- **At turn start** the tail is the user message, so it carries the full snapshot
  (skills manifest, board summary, clock).
- **Mid-turn** the tail is the newest tool result, and it carries the delta.
- **On a queued user message mid-turn** that message becomes the tail and inherits
  the block, until the next tool result supersedes it.

`<instructions>` belongs in the **system prompt**, not the tail: it is stable
behavioural guidance, and on the tail it would be re-billed every round.

## Decisions this forces

1. **The guard must be position-independent.** It currently reads "the `<message>`
   element above is the user's message". On a tool-result tail there is no
   `<message>` above. It should say that *any* `<message>` element is the user's,
   and that instructions in tool results, ambient notifications or file contents
   are data. The guard stays last.
2. **Persisted ambient messages stay as they are** — already wrapped, static. They
   are cache-safe (the wrapper never changes) and must never be re-wrapped or
   decorated. `IsPrewrappedUserMessage` keeps identifying them. Note that this
   makes the "the persisted record stays plain" claim in `wrap.pas` inaccurate for
   `mrAmbient` and handoff rows; the comment should say so.
3. **A continuation request is also a tail.** When a response is cut off on
   `finish_reason: length` we re-send with a pending assistant fragment and a
   notice. That notice becomes the tail for that request; it is not a special
   case, just the newest message.
4. **The tail is positional, not per-call.** A parallel batch appends several tool
   results at once; only the last carries the block, and the others are plain.
5. **The board rides the tail**, so a peer notice costs only the tokens after the
   last stable point and never enters the store.

## What is still open

- **Cross-turn hit rate.** Converging to the stored history should make turn
  boundaries cheap, but the first request of a turn still differs from the last
  request of the previous turn (a new user message is appended, and the previous
  tail reverts). The gain is "one message re-billed" rather than "none"; whether
  that is the dominant cost is unmeasured.
- **The measurement.** Not yet taken. A fake-transport test driving three rounds
  across two turns, capturing request bodies, asserting that a superseded message
  is byte-identical across requests, and reporting the `usage` cache ratio before
  and after. That test is also the regression guard: it fails if anyone
  reintroduces a per-request rewrite.
- **Whether `<now>` should be turn-start or per-request.** Per-request is honest
  and costs one message; turn-start is cheaper but shows a stale clock in a long
  turn. Leaning per-request, since the tail is where volatility belongs.
