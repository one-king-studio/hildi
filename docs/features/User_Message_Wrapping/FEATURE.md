# User Message Wrapping

## Overview

Every user message delivered to the provider is **wrapped in XML** so dynamic
context — the skills manifest, the current time, preferences — can never be
mistaken for the user's own words. The persisted record stays plain; only the
provider-visible form carries the wrapper.

This is a port of `hildegard/main`'s message formatter
(`src-backend/lib/main-agent/message-formatter.ts`), which `FormatAmbient` already
follows for ambient messages.

## Problem Statement

After the skills feature landed, the agent behaves as if the user **keeps pasting
the skills manifest** into the conversation. The cause is that dynamic context
has no home of its own:

- A plain user message is delivered **raw** — `Compose`
  (`session.store.pas:310-316`) maps `mrUser` straight to `Msg.Content`.
- Dynamic context (the skills manifest and similar) is injected near the user
  turn, so to the model it reads as *the user's text*.

There is no delimiter that says "this is context, not the user". Ambient messages
have one (`<ambient>…<message>…</message>`); ordinary user turns do not.

## Decision

**The user's text lives only inside `<message>`; dynamic context lives in
`<context>`, a sibling.**

1. **Wrap every user message** on the way to the provider — a `<context>` block,
   an `<instructions>` block, then `<message>escaped user text</message>`.
2. **Dynamic context goes in `<context>`** — the skills manifest, the current
   time, preferences. Nothing dynamic goes in the `<message>` body.
3. **Provider-visible only.** The persisted record stays plain, so history is
   stored once and wrapped on the way out (the same rule ambient already uses:
   *"the persisted record stays plain"*).
4. **One formatter, applied wherever a user message becomes provider-visible** —
   `Compose` (SQLite) and the in-memory store.

## The templates (verbatim, from the reference)

**Current user message** (`formatCurrentMessage`):

```
<context>
  <now>2026-10-11T14:03:00.000Z</now>
  <preferences>
    <item key="KEY">VALUE</item>
  </preferences>
</context>
<instructions>Respond with plain Markdown only. Do not wrap your response in XML tags such as <message>, <context>, or <summary> — those are system-provided metadata, not part of your output format.</instructions>
<message>ESCAPED USER CONTENT</message>
```

`<preferences>` is omitted when empty; `<now>` always appears. The skills manifest
becomes another child of `<context>` (e.g. `<skills>…</skills>`).

**Past user message** (`formatPastMessage`):

```
<message sent="2026-10-11T13:58:11.000Z">ESCAPED BODY</message>
```

## Goals

- A user turn is delivered as `<context>…</context><instructions>…</instructions><message>escaped</message>`.
- Dynamic context (skills, time, …) has a single home, `<context>`, and never
  appears inside `<message>`.
- The stored record is unchanged — plain — so a resumed or replayed session
  composes identically to a live one.
- Escaping matches the existing helpers (`&`, `<`, `>` in content; also `"`/`'`
  in attributes).

## Acceptance Criteria

- [ ] `Compose` wraps `mrUser` as above (SQLite store).
- [ ] The in-memory store (`TMemoryConversationStore.Messages`) wraps the same way.
- [ ] A user message containing `<message>` or `&` round-trips: stored plain,
      delivered escaped, never able to close the wrapper.
- [ ] The persisted record for a user turn is byte-identical to today's (the
      wrapper is added only on delivery).
- [ ] Existing plain history composes through the wrapper unchanged.
- [ ] The skills manifest is delivered inside `<context>`, not `<message>`.

## Out of Scope

- The **content** of the skills manifest — this feature is only about *where*
  dynamic context is placed.
- Preferences as a feature (the reference has them; we do not yet) — `<context>`
  is simply extensible.
- A `sent`-timestamp wrapper for every past message (the reference wraps all of
  them; we wrap the current turn first, and can extend later).

## Notes

- **Reference:** `hildegard/main/src-backend/lib/main-agent/message-formatter.ts`
  (`formatCurrentMessage`, `formatPastMessage`, `formatSystemEventMessage`).
- **The existing vocabulary is already ours:** `FormatAmbient`
  (`hildegard.helper.ambient`) uses `<message>` + `<instructions>`, and escaping
  helpers exist. The user-message wrapper reuses that shape.
- **Related:** `docs/issues/session-memory-retention.md` (the same composition
  path; independent).
