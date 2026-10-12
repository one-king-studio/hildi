# Context Checkpoint

## Overview

Replace destructive **context compaction** with a **generative, recoverable
checkpoint** built on **checkpoints** within **one continuous session**.

Instead of spawning a new session, a checkpoint **archives the messages before it**
and records a **checkpoint**: a summary that stands in for those messages going
forward. Loading a session always resumes **from the most recent checkpoint
forward**. The archived messages are **never deleted** — they are frozen out of
the active prompt and remain fully retrievable (back-pagination, recall).

So there is **one session id forever**. Continuity is indefinite, the whole
chain is one group, and recall is a query within the same session rather than a
cross-session lookup. It is the session-scoped sibling of the hand-maintained
`HANDOFF.md`.

> Name note: `Session_Handoff/` already exists for a **different, superseded**
> meaning (exclusive session ownership; moving a live loop between devices). This
> feature is **Context Checkpoint**.

## Problem Statement

Long sessions hit the context limit. The common answer is **compaction**:
summarize and *replace* the history. That is **destructive** — the summary is
lossy, and a dropped decision is gone for good. The operator's words: "I really
don't want to reduce an entire session down to something unrecoverable if things
go wrong."

An earlier design of this feature spawned a **child session** per checkpoint. That
avoids data loss but introduces its own friction: N session ids, a predecessor
pointer, and recall that must "juggle" across sessions.

The **checkpoint model** removes that friction:

- **One session**, continuous. No id juggling, no predecessor link to chase.
- **A checkpoint** is a checkpoint: the current context is "the latest checkpoint,
  then every message after it."
- **Archived messages** are frozen out of the prompt but retained and reachable
  (scroll back; search).

It is video-style seek: jump to the nearest checkpoint and play forward, with the
footage before it still on disk.

## Goals

- A deliberate, operator-owned **checkpoint** (`/checkpoint`), with a **threshold
  nudge** (e.g. 80% context) that never fires automatically.
- The **agent writes** the checkpoint (one action); the operator triggers it but
  does not edit it.
- A checkpoint records a **checkpoint** at the current message boundary; messages
  before it are **archived** (frozen from the prompt, retained in the store).
- **Resume always starts from the latest checkpoint forward** — the checkpoint's
  summary is prepended as context; archived messages are not replayed.
- **Nothing is destroyed**: archived messages remain, reachable by
  **back-pagination** and by **recall**.
- **Recall** is whole-session **full-text search (SQLite FTS5)**, weighted toward
  the structured context we already store (tool reasons, names, arguments,
  labels) so searches can skip `content` when they do not need it.
- **One session id** throughout; the full chain stays one group.
- A deliberate, operator-owned **revert** of the latest checkpoint, so a bad
  handoff or a bad post-checkpoint turn can be undone without hand-editing the
  store (see the 2026-10-12 revert decision).

## User Stories

- As an **operator**, I want to keep working past the context limit without
  losing detail, in the **same session**, so nothing is unrecoverable.
- As an **operator**, I want the checkpoint written by the agent in one action, so
  continuing past the context limit is a single command.
- As an **operator**, I want to scroll back past a checkpoint to see exactly what
  was said, so the summary never has to be perfect.
- As the **agent**, I want to search my whole history (including archived) by
  tool reason/name, so I can recover a decision without a full-text scan of
  prose.
- As a **reviewer**, I want archived messages untouched, so a bad checkpoint is
  never a data loss.

## Acceptance Criteria

### Functional Requirements

- [ ] `/checkpoint` (operator) triggers a checkpoint; a **nudge** suggests it past a
      configurable context threshold but never triggers it.
- [ ] The agent generates a **checkpoint document**; the operator triggers it (no
      edit step).
- [ ] On confirm, a **checkpoint** is recorded for the session at the current
      message high-water mark: `session_checkpoints(session_id, seq, summary,
      created_at)`.
- [ ] **Resume**: the active context is the **latest checkpoint's summary**
      followed by messages with `seq > checkpoint.seq`. Archived messages
      (`seq <= checkpoint.seq`) are **not** replayed into the prompt.
- [ ] **Nothing destructive**: a checkpoint adds a checkpoint row; it never deletes,
      rewrites, or reorders messages. The archived messages remain byte-for-byte.
- [ ] **Back-pagination**: the TUI can load messages before the checkpoint
      boundary (the previous segment); the checkpoint's ambient box is the
      visible boundary (no separate marker).
- [ ] **Recall**: a whole-session FTS5 index over messages lets the agent search
      **archived and current** messages; the query can scope to structured
      columns (tool reason/name/arguments/label) to avoid scanning `content`.
- [ ] A checkpoint is a **durable, listable artifact** (you can see a session's
      checkpoints and their summaries).
- [ ] A checkpoint on an empty session (no messages past the last checkpoint) is
      refused with a clear message.

### Non-Functional Requirements

- [ ] **One session id**; no child sessions, no predecessor pointer for recall.
- [ ] The checkpoint's summary is **bounded** (well under the context limit).
- [ ] FTS is available (build enables `SQLITE_ENABLE_FTS5`); indexing is
      incremental and leak-clean.
- [ ] `make check` green; leak-clean.

## Success Metrics

### Quantitative

- After a checkpoint, the resumed prompt is **bounded** while the full message
  count is **unchanged** (archived, not deleted).
- A recall query by tool reason returns the right archived message without a
  `content` scan.

### Qualitative

- Operators stop fearing the context limit; a checkpoint is cheap and reversible.
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

- `hildegard.helper.store` (a `session_checkpoints` table; an FTS5 virtual table;
  active-window queries).
- `hildegard.helper.session.protocol` / `runtime` (a checkpoint command + events).
- `hildegard.helper.harness.session` / `view` (draft + checkpoint).
- `hildegard.helper.tui.app` (the checkpoint UX, back-pagination, boundary marker).
- `recall_tool_result` (extended to search the FTS index).

### External

- None (FTS5 is in the vendored SQLite).

## Risks

- **The checkpoint request overflows the context.** Mitigation: reserved output
  budget; if it cannot fit, tell the operator.
- **FTS index drift** (messages added but not indexed). Mitigation: index on
  append in the same store transaction; a backfill on migration.
- **A bad summary.** Mitigation: archived messages remain fully retrievable, so
  the summary never has to be perfect.
- **Checkpoint density** (too few = big summaries; too many = churn). Mitigation:
  manual-only in v1; density is a later knob.

## Out of Scope

- **Automatic** checkpoint (the nudge is advisory).
- **Compaction** (this replaces it).
- **Structured/typed memory** (a small fixed set of fields) — that is a
  **separate future memory feature**; v1 is a prose checkpoint document.
- **Cross-workspace** checkpoint; a **checkpoint chain browser** (listable, but no UI
  browser yet).

## Future Considerations

- **Structured memory** (objective/decisions/open-threads as fields) as its own
  feature; the checkpoint summary is the prose fallback.
- Automatic checkpoint at a hard threshold (operator-confirmed).
- A checkpoint/segment browser; per-segment token accounting.
- Optional `archived-only` recall scope (a query change, not an architecture
  change).

## Notes

- **ICE score: Impact 8, Confidence 7, Ease 6.** The payoff is real and the
  model is simpler than the child-session design (one id, no link chasing); the
  new surface is checkpoints, the resume window, FTS recall, and the TUI UX.
- The distinction from compaction, in one line: **compaction replaces history; a
  checkpoint freezes it behind a checkpoint and keeps it.**

## Decisions

- **2026-10-08 — The checkpoint is a turn, not an out-of-band call.** An earlier
  build produced the checkpoint document with a separate, synchronous
  `FClient.Complete` (`DraftCheckpoint`). It failed live with a bare
  "checkpoint draft failed" — the call blocked the runtime with no progress
  shown and swallowed the failure reason.

  **Decision:** the checkpoint is an ordinary **turn**. `/checkpoint` submits a
  summarization prompt as an **ambient** message; the assistant's response to
  that turn *is* the checkpoint document; and that turn is simultaneously the
  **last turn of the previous chain and the first turn of the next chain**. On
  completion, the checkpoint is recorded at the boundary and the view reloads,
  leaving a blank slate to continue. Streaming, progress, the ledger, and error
  handling come free from the normal turn path. The out-of-band
  `scCheckpoint`/`DraftCheckpoint` path is removed. See the TODO for the change
  list.
- **One session, one chain.** The checkpoint does not create a session or a
  child; it archives the messages behind a boundary and re-seeds the chain from
  the document. Recall and back-pagination are queries within the same session.
- **2026-10-12 — The summary is carried forward as a handoff, not a system
  block.** Observed live: after a checkpoint the resumed agent spent its whole
  first turn re-deriving what the document already said (re-reading docs,
  re-running `git log`, re-checking state) and never started the work. Two
  causes: the summary was injected as a bare system message with no framing, and
  the document was written as a narrative that named no sources.

  **Decision:** the summary is delivered as the **first user message of the new
  page**, wrapped as a `<handoff>` (`hildegard.helper.handoff`), with a generic
  instruction block that frames it as **orientation, not authority** — read the
  sources it names to ground yourself, then continue; do not re-explore. The
  operator's own turn follows as a second user message, so the handoff can never
  be mistaken for their words. It is **not** the system prompt (the system slot
  is for standing instructions, not volatile carried context) and **not** an
  ambient task result (that framing says "act on it, delegate, or tell the
  user", which is wrong for a handoff).

  **Generator:** `CheckpointInstruction` asks for a handoff document with a
  **Grounding** section naming the documents/files/resources to read first, so
  the next agent grounds in a few sources instead of exploring. Domain-neutral
  (a repo, a ticket queue, or a research task alike) — the handoff is the
  session-scoped sibling of the hand-maintained `HANDOFF.md`.

  **Why not a new message role:** the summary is not a stored message; it lives
  in `session_checkpoints` and is synthesized on compose (the TUI already does
  the same). A new `mrHandoff` role would duplicate that source of truth. The
  distinct *wrapper* is where the "type" belongs.
- **2026-10-12 — Reverting a checkpoint is a first-class operator action.** We
  had to revert the latest checkpoint **by hand** (a `sqlite3` delete of the
  checkpoint row, the checkpoint turn, and the turns after it) when a stale
  handoff and the turn that followed it had to be undone. A capability the
  operator reaches for under stress should not be a manual store edit, so it
  becomes a documented mechanism.

  **It is the conversation sibling of Workspace Snapshots.** That feature
  versions the *workspace files* across turns (undo/redo walks file state);
  this reverts the *conversation's* checkpoint. They are independent axes — the
  Workspace Snapshots Notes already say so — and neither substitutes for the
  other.

  **Semantics — reverting the latest checkpoint at boundary `B`:**
  - drops the `session_checkpoints` row at `B`, so the session resumes from the
    **previous** checkpoint (or from the beginning);
  - drops the checkpoint **turn** (its ambient request, its reasoning, and the
    document) — the turn exists only to produce the checkpoint, so the handoff
    cannot replay as an ordinary assistant message;
  - **never deletes the archived messages** — they un-archive and the active
    window expands;
  - runs in **one transaction**, and is **refused while a turn is in flight**
    (one writer).

  **Rewind is the companion, not the same action.** Reverting a checkpoint does
  *not* discard the work done after it. Discarding that work is a **rewind** to a
  message `seq` — a separate, explicitly destructive operation that drops the
  turns at or after it (their messages, requests, and FTS rows). The two compose:
  reverting a checkpoint is *rewind to the checkpoint request* + *drop the
  checkpoint*. Because a rewind destroys history, it is operator-confirmed and
  the store is backed up first (the same rule the non-destructive checkpoint
  invariant implies: a checkpoint never deletes, so a delete must be explicit).
