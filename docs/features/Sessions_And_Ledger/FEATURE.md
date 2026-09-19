# Sessions and Ledger

## Overview

A **session** is a conversation run of the agent, bound to a workspace and
identified by a random 128-bit id rendered as 32 hex characters. Every session
keeps an append-only, timeseries **ledger** of what happened: system, user, and
assistant messages, reasoning, tool calls, tool results, errors, and error
handling details. The ledger is the durable history and audit for a session, and
the source from which a conversation can be **restored** (recomposed into
messages, leaving out non-essential records such as reasoning and errors).

This replaces the current in-memory `IConversationStore` with a SQLite-backed
adapter and removes the store's `requests` table, whose audit role is now served
by the ledger.

## Problem Statement

Conversations live only in memory today: closing the CLI loses everything, and
there is no audit of what the agent did or why. At the same time, the
`requests` table is a queue built for a different purpose and is being used (or
planned to be used) as a rough audit. Neither captures the richness a session
needs: messages, reasoning, tool calls and results, and errors, in order, tied
to a workspace and a session.

## Goals

- Define a session: random 128-bit id (32 hex), bound to a workspace, with
  timestamps.
- Persist an append-only ledger of typed records per session, ordered by
  sequence and time.
- Record enough to restore a conversation and to audit it.
- Provide a SQLite `IConversationStore` adapter that reads/writes messages
  through the ledger.
- Recompute/resume a session's messages from the ledger on restore.
- Remove the `requests` table and its API from the store.

## User Stories

- As a **user**, I want to resume yesterday's session, so I do not lose context.
- As an **operator**, I want an audit of everything the agent did, including
  reasoning and errors, so I can review a session after the fact.
- As a **user**, I want restore to bring back the conversation but not clutter it
  with reasoning and error records, so the resumed transcript reads naturally.
- As a **harness author**, I want conversations persisted behind
  `IConversationStore`, so the loop is unchanged while durability is added.
- As a **harness author**, I want the ledger typed and queryable, so future
  features (remote link, analytics) can consume it.

## Acceptance Criteria

### Functional Requirements

Session identity

- [ ] A session id is 32 hex characters from a random 128-bit value, generated at
      session creation.
- [ ] A session is bound to a workspace (its canonical path identity).
- [ ] A session can be resumed by id; an unknown id is a clear error.
- [ ] `--session ID` resumes an existing session; without it, a new session is
      created.
- [ ] Session timestamps (created/updated) are maintained.

Ledger

- [ ] Records are append-only and ordered by a monotonic sequence per session
      plus a timestamp.
- [ ] Record kinds include: system message, user message, assistant message,
      reasoning, tool call, tool result, error, and a generic event for future
      use.
- [ ] Each record carries its session id and enough payload to be self-describing
      (for tool records: tool name, ref, parameters/arguments, and result).
- [ ] Reasoning and error records are stored but are not part of the restored
      conversation.
- [ ] The ledger is queryable by session, kind, and sequence range.

Restore and conversation adapter

- [ ] A SQLite `IConversationStore` implementation persists appended messages to
      the ledger and reads them back.
- [ ] Restoring a session recomposes the messages in order (system, user,
      assistant with tool calls, tool results) from the ledger records, skipping
      reasoning and errors.
- [ ] The agent loop is unchanged; it continues to use `IConversationStore`.
- [ ] Tool calls and tool results are correlated (by tool-call id) in the ledger.

Store changes

- [ ] The `requests` table and its public API (`EnqueueRequest`,
      `ClaimNextPending`, `FinishRequest`, `GetRequest`, `QueryRequests`,
      `TStoredRequest`) are removed.
- [ ] Migrations add `sessions` and `session_records` and drop `requests`.
- [ ] Existing store tests for the removed API are deleted or replaced.

### Non-Functional Requirements

- [ ] Reliability: leak-clean; appends and reads are bounded and indexed.
- [ ] Performance: appending a record is a single indexed insert; loading a
      session is one indexed query.
- [ ] Security: the ledger may contain sensitive content; it is stored with the
      store's owner-only file permissions and is never logged.
- [ ] Portability: macOS and Linux; uses the vendored SQLite.
- [ ] `make check` passes.

## Success Metrics

### Quantitative

- A session round trip (append, close, reopen, restore) in tests.
- Restore reconstructs the same message sequence the loop produced.
- No leaks; no network.

### Qualitative

- Resuming a session "just works".
- The ledger is a single, comprehensible table of typed records.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- Must reuse `hildegard.helper.store`; migrations carry the schema changes.
- Must use the vendored SQLite; no new dependency.
- The `IConversationStore` interface must not change (the loop stays untouched).

### Business / Time

- This is the durability layer the Remote Agent Link and context budgeting will
  build on.

## Dependencies

### Internal

- `hildegard.helper.store` - migrations, connections, transactions.
- `hildegard.helper.agent` - `IConversationStore`, `TChatMessage`.
- Workspaces - sessions are bound to a workspace.
- Tool Approvals - session-scoped approvals reference session ids.

### External

- Vendored SQLite 3.53.4.

## Risks

- **Ledger growth.** Append-only records grow without bound. Mitigation: indexed
  queries and a future retention/compaction policy; not v1.
- **Restore fidelity.** Recomposed messages must match what the provider
  requires. Mitigation: replay from typed records and assert the sequence in
  tests.
- **Removing `requests` touches the store and its tests.** Mitigation: a single
  migration and a deliberate test update; the table has no other production
  consumer yet.
- **Sensitive content in the ledger.** Mitigation: owner-only file permissions
  (already enforced) and no logging of contents.

## Out of Scope

- Server-side session sync (Remote Agent Link, later).
- Compaction, retention, or summarization of old records.
- Full-text search over the ledger.
- Multi-user or concurrent sessions (single-threaded, one session per process).

## Future Considerations

- Retention/compaction and archival.
- Resuming the last session by default.
- Exporting a session transcript.
- Token/context budgeting from ledger statistics.
- Reading the ledger for the Remote Agent Link's audit.

## Notes

- **ICE score: Impact 8, Confidence 7, Ease 6.** Resume and audit are valuable;
  the schema and the store/API changes are the effort.
- **Sequencing:** depends on Workspaces for the workspace identity; Tool Approvals
  session scope depends on this. Removing `requests` is independent and can be
  done with the migration.
- **Reuse note (Ponytail):** the store, migrations, and `IConversationStore` seam
  already exist; the new pieces are the session/record tables and the SQLite
  conversation adapter. The `requests` table is deleted, not replaced.
