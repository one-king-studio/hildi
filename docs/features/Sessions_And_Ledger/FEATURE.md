# Sessions and Ledger

## Overview

A **session** is a conversation run of the agent, bound to a workspace and
identified by a random 128-bit id rendered as 32 hex characters.

A session is a sequence of **turns** (loops). A turn is one user prompt pushed to
the LLM and every follow-up request it triggers, until the model returns a proper
stop reason. Each turn is made of one or more **requests** (a single LLM call
each), and each turn **produces messages**: the user prompt, assistant text,
reasoning, tool calls, tool results, and errors, in chronological order.

The persistence model therefore has two paths rooted at a session:

```
workspace --has--> sessions --is comprised of--> turns --is comprised of--> requests
                            \--contains--> messages (user, assistant, reasoning,
                                            tool call, tool, error)
                            \--is comprised of--> turns --produced--> messages
```

Every message carries its own stats/metrics (duration, tool outcome), every
request carries the model, finish reason, token usage and timings, and every turn
rolls its requests' metrics up. The ledger is the durable history: the source
from which a conversation can be **restored** for the provider and rendered back
to the operator exactly as it streamed.

This replaces the flat, single-table `session_records` ledger (v1) with the
relational model above, and removes the v1 `IConversationStore` that dropped
reasoning, tool reasons, metrics, and turn boundaries. It is a **full schema
reset**: there are no data-preserving migrations; a pre-v2 database is rejected
with a clear message and must be deleted.

## Problem Statement

Resuming a session today loses much of what streamed. The v1 ledger stores
messages as opaque records and the SQLite adapter recomposes only
system/user/assistant/tool messages, so on resume:

- reasoning (thought) blocks are gone;
- a tool call's **reason** - the title the operator sees while streaming - is
  gone, because only the raw call id/name/arguments were kept;
- a tool call and its result are not rendered as the same block;
- errors are gone;
- there is no timing or token usage at all, because the LLM client drops the
  `usage` object from the stream;
- there is no notion of a turn, so metrics cannot be rolled up to a loop.

At the same time, the flat ledger cannot express the relationships an operator
or a future analytics/remote-link consumer needs: which loop produced which
message, how many requests a loop took, or what each request cost.

## Goals

- Define the relational model: sessions, turns (loops), requests, and messages.
- Persist every message block the UI renders, in chronological order: user,
  assistant, reasoning, tool call, tool result, error, plus the system prompt.
- Capture token usage and timings per request, and roll them up per turn.
- Capture per-message stats (tool outcome and duration).
- Restore a faithful conversation for the provider and a faithful history for
  the UI, including tool reasons and reasoning.
- Keep the loop's persistence seam small and unchanged in spirit: the loop
  still appends messages; it now also brackets turns and requests.
- Reset the schema cleanly; reject an incompatible (pre-v2) database rather than
  silently misbehave.

## User Stories

- As a **user**, I want to resume yesterday's session and see the same
  conversation I saw live - bubbles, thoughts, tool calls with their reasons and
  results, and errors - so the context is not lost.
- As an **operator**, I want an audit of each loop: the prompt, every request it
  took, the model, the finish reason, and the tokens and wall time it cost, so I
  can understand and cost a session after the fact.
- As an **operator**, I want token usage and cache hit/miss counts collected per
  request and rolled up per turn, so a future stats view can display them.
- As a **harness author**, I want the loop to stay provider-agnostic and to see
  only a small persistence seam, so adding durability does not entangle the loop
  with SQL.
- As a **harness author**, I want the schema to express the workspace/session/
  turn/request/message relationships, so future features (analytics, remote
  link, context budgeting) can query it.

## Acceptance Criteria

### Functional Requirements

Schema

- [ ] `workspaces`, `sessions`, `turns`, `requests`, and `messages` exist with
      the relationships above; `sessions` and `messages` carry foreign keys.
- [ ] `turns` are ordered per session (`seq`), `requests` per turn, `messages`
      per session.
- [ ] A message records its session, the turn and request that produced it
      (nullable for the system prompt), its role, content, and tool fields.
- [ ] A request records its turn, model, message count, finish reason, outcome,
      error, token usage, and timings.
- [ ] A turn records its status, finish reason, outcome, error, request/message
      counts, rolled-up usage, and duration.
- [ ] A fresh database is created at the new schema version in one migration.
- [ ] A database whose schema version is newer than this build is rejected with
      a clear "delete the database" error rather than misbehaving.

Collection

- [ ] The loop opens a turn per user prompt and closes it when the model stops
      or the loop fails.
- [ ] The loop brackets every LLM request with begin/finish and records its
      outcome.
- [ ] The loop persists reasoning and error blocks for restore/rendering.
- [ ] Tool calls are persisted as ordered messages, each with its reason, name,
      and arguments.
- [ ] Tool results are persisted with the call id they answer, the tool name,
      the outcome, and the duration.
- [ ] The LLM client parses `usage` from the stream (OpenAI/Fireworks, DeepSeek,
      and Anthropic-gateway spellings) into prompt, completion, total, cached,
      and reasoning token counts, and records time-to-first-token.

Restore and render

- [ ] A session's conversation is recomposed for the provider in faithful order:
      system, user, assistant (with its tool calls), tool results; reasoning and
      errors are not sent.
- [ ] A session's messages are available as blocks (role, content, tool fields)
      in chronological order for rendering.
- [ ] The TUI restores the same blocks it streamed: user bubbles, assistant
      text, thought blocks, tool blocks titled by reason with their results, and
      errors.
- [ ] The CLI continues to resume and render the conversation (unchanged in
      scope; the richer view is the TUI's).

Store API

- [ ] Typed operations cover session create/exists/touch/list/most-recent, turn
      begin/finish/query, request begin/finish/query, and message append/query.
- [ ] A session listing reports its message and turn counts.
- [ ] The v1 ledger API (`TSessionRecord`, `AppendSessionRecord`,
      `QuerySessionRecords`, `TSessionRecordKind`) is removed.

### Non-Functional Requirements

- [ ] Reliability: leak-clean under the heaptrc gate; appends and reads are
      bounded and indexed; a failed write never leaves a partial turn.
- [ ] Performance: appending a message is one indexed insert; loading a session
      is one ordered query; rolling up a turn is one statement.
- [ ] Security: the history may contain sensitive content; it is stored with the
      store's owner-only file permissions and is never logged.
- [ ] Portability: macOS and Linux; uses the vendored SQLite; no new dependency.
- [ ] `make check` passes.

## Success Metrics

### Quantitative

- A session round trip (append, close, reopen, restore) reproduces the exact
  block sequence the loop produced, including reasoning, tool reasons, results,
  and errors.
- A turn's rolled-up token counts equal the sum of its requests' counts.
- No leaks; no network in tests.

### Qualitative

- Resuming a session "just works" and shows the same conversation.
- The schema reads as the workspace/session/turn/request/message story.
- The loop's seam stays small: append a message, bracket a turn, bracket a
  request.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- Must reuse `hildegard.helper.store` and its migration machinery.
- Must use the vendored SQLite; no new dependency.
- The loop must remain provider-agnostic and must not embed SQL.
- A pre-v2 database is not migrated; it is rejected.

### Business / Time

- This is the durability and metrics foundation the Remote Agent Link, a stats
  view, and context budgeting build on.

## Dependencies

### Internal

- `hildegard.helper.store` - migrations, connections, transactions.
- `hildegard.helper.llm` - `TChatMessage`, `TChatToolCall`, the SSE parser
  (`usage`), and `TTokenUsage`.
- `hildegard.helper.agent` - the loop and the persistence seam.
- Workspaces - sessions are bound to a workspace.
- TUI Harness - renders the restored blocks.

### External

- Vendored SQLite 3.53.4.

## Risks

- **Schema reset loses existing local data.** Mitigation: this is a deliberate
  reset; an incompatible database is rejected with an actionable message, and
  the operator deletes it.
- **History growth.** Full tool outputs are stored. Mitigation: indexed queries
  now; a context-budget/recall feature (below) keeps large outputs out of the
  prompt, and retention/compaction is future work.
- **Usage spellings vary by provider.** Mitigation: parse the known spellings
  into one normalised `TTokenUsage`; absent usage yields zeros.
- **Seam growth on the loop.** Mitigation: keep the seam to a handful of
  begin/finish/append calls; the loop never sees SQL.

## Out of Scope

- Migrating pre-v2 databases.
- Displaying the metrics beyond the status line (per-block durations, a full
  stats view).
- Context budgeting, output spilling, and a recall tool (see below).
- Server-side session sync (Remote Agent Link, later).
- Compaction, retention, or summarization of old records.
- Full-text search over the history.
- Multi-user or concurrent sessions (single-threaded, one session per process).

## Future Considerations

- **Tool output budget (next).** Faithful replay is kept, but tool results are
  capped before they are sent: an oversized result is spilled to a session
  artifact and the prompt carries a truncated head plus a reference. A
  `recall_tool_result` tool then reads the artifact in windowed slices; it caps
  (never spills) its own output so inspecting an artifact cannot spawn more
  artifacts. See `../Context_Budget/FEATURE.md`.
- A stats view over turns/requests (tokens, cache hit/miss, latency).
- Retention/compaction and archival.
- Resuming the last session by default.
- Exporting a session transcript.

## Notes

- **ICE score: Impact 9, Confidence 7, Ease 5.** Resume fidelity and metrics are
  high value; the schema, adapter rewrite, loop seam, and LLM usage parsing are
  the effort.
- **Sequencing:** supersedes Sessions v1. The store, migrations, the vendored
  SQLite, and the `IConversationStore` seam already exist; the new work is the
  relational model, the collector, and the richer restore/render.
- **Reuse note (Ponytail):** the migration machinery, the serialized connection,
  the SSE parser, and the chat-block widgets are reused; only the model, the
  store operations, and the small seam are new. The v1 ledger is deleted, not
  layered on.
