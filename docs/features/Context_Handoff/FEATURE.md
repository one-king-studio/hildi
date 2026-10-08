# Context Handoff

## Overview

Replace destructive **context compaction** with a **generative, recoverable
handoff** built on **snapshots (keyframes)** within **one continuous session**.

Instead of spawning a new session, a handoff **archives the messages before it**
and records a **snapshot**: a summary that stands in for those messages going
forward. Loading a session always resumes **from the most recent snapshot
forward**. The archived messages are **never deleted** — they are frozen out of
the active prompt and remain fully retrievable (back-pagination, recall).

So there is **one session id forever**. Continuity is indefinite, the whole
chain is one group, and recall is a query within the same session rather than a
cross-session lookup. It is the session-scoped sibling of the hand-maintained
`HANDOFF.md`.

> Name note: `Session_Handoff/` already exists for a **different, superseded**
> meaning (moving a live loop between devices). This feature is **Context
> Handoff**.

## Problem Statement

Long sessions hit the context limit. The common answer is **compaction**:
summarize and *replace* the history. That is **destructive** — the summary is
lossy, and a dropped decision is gone for good. The operator's words: "I really
don't want to reduce an entire session down to something unrecoverable if things
go wrong."

An earlier design of this feature spawned a **child session** per handoff. That
avoids data loss but introduces its own friction: N session ids, a predecessor
pointer, and recall that must "juggle" across sessions.

The **keyframe model** removes that friction:

- **One session**, continuous. No id juggling, no predecessor link to chase.
- **A snapshot** is a keyframe: the current context is "the latest snapshot,
  then every message after it."
- **Archived messages** are frozen out of the prompt but retained and reachable
  (scroll back; search).

It is video-style seek: jump to the nearest keyframe and play forward, with the
footage before it still on disk.

## Goals

- A deliberate, operator-owned **handoff** (`/handoff`), with a **threshold
  nudge** (e.g. 80% context) that never fires automatically.
- The **agent writes** the handoff (one action); the operator triggers it but
  does not edit it.
- A handoff records a **snapshot** at the current message boundary; messages
  before it are **archived** (frozen from the prompt, retained in the store).
- **Resume always starts from the latest snapshot forward** — the snapshot's
  summary is prepended as context; archived messages are not replayed.
- **Nothing is destroyed**: archived messages remain, reachable by
  **back-pagination** and by **recall**.
- **Recall** is whole-session **full-text search (SQLite FTS5)**, weighted toward
  the structured context we already store (tool reasons, names, arguments,
  labels) so searches can skip `content` when they do not need it.
- **One session id** throughout; the full chain stays one group.

## User Stories

- As an **operator**, I want to keep working past the context limit without
  losing detail, in the **same session**, so nothing is unrecoverable.
- As an **operator**, I want the handoff written by the agent in one action, so
  continuing past the context limit is a single command.
- As an **operator**, I want to scroll back past a handoff to see exactly what
  was said, so the summary never has to be perfect.
- As the **agent**, I want to search my whole history (including archived) by
  tool reason/name, so I can recover a decision without a full-text scan of
  prose.
- As a **reviewer**, I want archived messages untouched, so a bad handoff is
  never a data loss.

## Acceptance Criteria

### Functional Requirements

- [ ] `/handoff` (operator) triggers a handoff; a **nudge** suggests it past a
      configurable context threshold but never triggers it.
- [ ] The agent generates a **handoff document**; the operator triggers it (no
      edit step).
- [ ] On confirm, a **snapshot** is recorded for the session at the current
      message high-water mark: `session_snapshots(session_id, seq, summary,
      created_at)`.
- [ ] **Resume**: the active context is the **latest snapshot's summary**
      followed by messages with `seq > snapshot.seq`. Archived messages
      (`seq <= snapshot.seq`) are **not** replayed into the prompt.
- [ ] **Nothing destructive**: a handoff adds a snapshot row; it never deletes,
      rewrites, or reorders messages. The archived messages remain byte-for-byte.
- [ ] **Back-pagination**: the TUI can load messages before the snapshot
      boundary (the previous segment), with a visible "— handoff —" boundary
      marker.
- [ ] **Recall**: a whole-session FTS5 index over messages lets the agent search
      **archived and current** messages; the query can scope to structured
      columns (tool reason/name/arguments/label) to avoid scanning `content`.
- [ ] A snapshot is a **durable, listable artifact** (you can see a session's
      snapshots and their summaries).
- [ ] A handoff on an empty session (no messages past the last snapshot) is
      refused with a clear message.

### Non-Functional Requirements

- [ ] **One session id**; no child sessions, no predecessor pointer for recall.
- [ ] The snapshot's summary is **bounded** (well under the context limit).
- [ ] FTS is available (build enables `SQLITE_ENABLE_FTS5`); indexing is
      incremental and leak-clean.
- [ ] `make check` green; leak-clean.

## Success Metrics

### Quantitative

- After a handoff, the resumed prompt is **bounded** while the full message
  count is **unchanged** (archived, not deleted).
- A recall query by tool reason returns the right archived message without a
  `content` scan.

### Qualitative

- Operators stop fearing the context limit; a handoff is cheap and reversible.
- The session feels "briefed", not "reset", and stays one conversation.

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`; reuse `TSqliteStore` messages, the ambient
  `ref_session_id`/`label` fields, and Runtime Lifecycle.
- **Build**: add `-DSQLITE_ENABLE_FTS5` to the vendored SQLite compile (the
  amalgamation already contains FTS5; it is currently compiled out).
- POSIX.

## Dependencies

### Internal

- `hildegard.helper.store` (a `session_snapshots` table; an FTS5 virtual table;
  active-window queries).
- `hildegard.helper.session.protocol` / `runtime` (a handoff command + events).
- `hildegard.helper.harness.session` / `view` (draft + snapshot).
- `hildegard.helper.tui.app` (the handoff UX, back-pagination, boundary marker).
- `recall_tool_result` (extended to search the FTS index).

### External

- None (FTS5 is in the vendored SQLite).

## Risks

- **The handoff request overflows the context.** Mitigation: reserved output
  budget; if it cannot fit, tell the operator.
- **FTS index drift** (messages added but not indexed). Mitigation: index on
  append in the same store transaction; a backfill on migration.
- **A bad summary.** Mitigation: archived messages remain fully retrievable, so
  the summary never has to be perfect.
- **Snapshot density** (too few = big summaries; too many = churn). Mitigation:
  manual-only in v1; density is a later knob.

## Out of Scope

- **Automatic** handoff (the nudge is advisory).
- **Compaction** (this replaces it).
- **Structured/typed memory** (a small fixed set of fields) — that is a
  **separate future memory feature**; v1 is a prose handoff document.
- **Cross-workspace** handoff; a **snapshot chain browser** (listable, but no UI
  browser yet).

## Future Considerations

- **Structured memory** (objective/decisions/open-threads as fields) as its own
  feature; the snapshot summary is the prose fallback.
- Automatic handoff at a hard threshold (operator-confirmed).
- A snapshot/segment browser; per-segment token accounting.
- Optional `archived-only` recall scope (a query change, not an architecture
  change).

## Notes

- **ICE score: Impact 8, Confidence 7, Ease 6.** The payoff is real and the
  model is simpler than the child-session design (one id, no link chasing); the
  new surface is snapshots, the resume window, FTS recall, and the TUI UX.
- The distinction from compaction, in one line: **compaction replaces history; a
  handoff freezes it behind a keyframe and keeps it.**
