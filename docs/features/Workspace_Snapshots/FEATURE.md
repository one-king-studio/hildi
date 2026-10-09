# Workspace Snapshots

## Overview

Give the operator **git-like visibility and control over the workspace between
turns**, without depending on git (or on git being installed):

1. **See what changed.** After a turn, list the files the agent added, modified,
   or deleted, and open a **diff view** of each.
2. **Undo / redo.** Walk the workspace's history backwards and forwards, bringing
   the files along with it — revert a turn's changes, or re-apply them.

The snapshot is taken **at the turn boundary**, because a turn is the unit of
agent work: it is when the agent's tool calls (write/edit/command) have landed and
before the next one starts. The store is self-contained and local, and it keeps
storage bounded by **storing each turn as a bidirectional diff from the previous
one** (SynProject's `TVersions` model), on the SQLite we already vendor. A diff
carries the **before and after hash** of the file it applies to, so a restore can
verify the file is what the diff expects *before* it writes — and tell the operator
when it is not. History is retained for a bounded number of turns and pruned
beyond it, so a long session plateaus instead of growing without limit.

## Problem Statement

The agent edits the operator's files and runs commands that edit them, and today
there is **no record of what it did to the tree**. The ledger records *messages*
and *tool calls*, but not the *file states* they produced. So:

- The operator cannot answer "what did that turn change?" without `git status` —
  and the project deliberately does not assume git.
- A bad turn cannot be reverted except by hand.
- The parity table lists **undo / checkpoint / rollback** as table stakes (OpenCode
  `/undo`, Claude checkpoints, Codex git checkpoints); this is our equivalent.

Who feels it: the operator reviewing an agent's work, and the operator who wants
to try a turn, see it, and take it back.

Ponytail check first: do we need this at all? Yes — the agent's whole job is
changing the workspace, and there is currently no way to see or reverse that. Can
we reuse? We already vendor **SQLite** (content-addressed blobs + a manifest is a
few tables) and we already have the **turn boundary** (`harness.turn`) and the
**workspace** trust boundary. The genuine gap is the snapshot store, a line diff,
and the TUI surface.

## Goals

- **Per-turn snapshots** of the workspace, captured at the turn boundary,
  deduplicated so an unchanged tree costs nothing.
- A **changed-files view** for a turn: path, change kind (added/modified/deleted),
  and a line count.
- A **diff view** per file, between the turn's before/after states.
- **Undo/redo** that walks the snapshot history and restores the files, safely
  (no partial writes) and visibly (the view reflects the result).
- **Self-contained**: one local store; no git, no network, no external tool.
- **Bounded**: ignore rules, size caps, and binary handling so a workspace with
  `node_modules` or a large binary does not blow up.
- **Bounded history**: each turn is a diff, and diffs older than a retention
  window are pruned — regularly, or on demand with a slash command — leaving a
  full base at the horizon.

## Non-Goals

- Branching, merging, remotes, or collaboration — a linear turn history only.
- Replacing git, or committing/pushing on the operator's behalf.
- Versioning anything outside the workspace.
- Editing history or amending a snapshot.
- A full-file blame / annotation view.

## User Stories

- As an **operator**, after a turn I want to see exactly which files the agent
  touched, so I can review before I trust it.
- As an **operator**, I want a diff of a changed file, so I can read what actually
  changed rather than re-reading the whole file.
- As an **operator**, I want to undo a turn's changes, so a bad or exploratory turn
  is reversible.
- As an **operator**, after undoing I want to redo, so I can flip back and forth
  while I decide.
- As an **operator**, I want undo/redo to be safe, so a half-applied revert never
  leaves the tree broken.
- As a **harness author**, I want the snapshot to ride the turn boundary, so I do
  not have to instrument every tool.

## Acceptance Criteria

### Functional Requirements

- [ ] A **snapshot** of the workspace is recorded at each turn boundary, capturing
      the file set (paths + contents + mode) with content deduplication.
- [ ] The operator can **list the changes of a turn**: added / modified / deleted
      files, with a line count each, and a summary total.
- [ ] The operator can open a **per-file diff** between two snapshots (the turn's
      before and after), as a unified (or side-by-side) view.
- [ ] **Undo** restores the workspace to the previous snapshot's file states;
      **redo** re-applies forward. Both update the changed-files view.
- [ ] Undo/redo are **atomic per snapshot**: a failure leaves the workspace in the
      pre-undo state (or a clearly recoverable one), never half-applied.
- [ ] **Ignore rules** exclude configured paths (e.g. `.git/`, `build/`,
      `node_modules/`) and are configurable.
- [ ] **Binary and oversized files** are handled: a binary is not diffed as text,
      and a file over the cap is recorded by hash/size only (or skipped), with the
      view saying so.
- [ ] An unchanged turn records **no new content** (only a manifest that shares the
      previous blobs), so an idle turn is cheap.
- [ ] The history is **listable**: turn id, time, change count, and label.
- [ ] A **diff is bidirectional**: the same stored delta applies forward (redo)
      and backward (undo).
- [ ] A diff carries the **before and after hash** of the file; applying it
      verifies the file's current hash against the expected one **before** writing.
- [ ] On a **hash mismatch** — the file changed outside the snapshot system — the
      operator is told which file, that the restore may not be correct, and that
      approving it is their responsibility; the default is to refuse.
- [ ] History is retained for a **bounded window** (N turns, configurable) and
      older turns are **pruned** — on a schedule or on demand via a slash command —
      leaving a full base at the horizon so the chain stays replayable.
- [ ] **Snapshotting never changes the workspace** (read-only capture).

### Non-Functional Requirements

- [ ] Capture at the turn boundary is bounded: a large tree does not stall the
      turn (target: sub-second for a typical workspace; scanning is incremental by
      mtime+size, not full-content).
- [ ] Storage is **deduplicated**: N snapshots of a mostly-unchanged tree cost
      ~the size of the changes, not N × the tree.
- [ ] **Storage is bounded by the retention window**, not the session: N turns of
      diffs plus one base, pruned beyond it, so a long session plateaus.
- [ ] **Restore walks the diff chain** from the nearest retained base to the target
      turn; the walk is bounded by the retention window, not the session length.
- [ ] The store is **atomic and crash-safe** (SQLite transactions; WAL).
- [ ] No new dependency; no git requirement; macOS and Linux, FPC 3.3.1.
- [ ] `make check` green (functional tests plus the heaptrc leak gate).

## Success Metrics

### Quantitative

- A turn that changes 3 files in a 10k-file tree records and lists them in well
  under a second.
- 100 snapshots of a tree whose files change one at a time cost ~the size of the
  100 changes (dedup), not 100 × the tree.
- Undo of a turn restores every changed file byte-for-byte.

### Qualitative

- The operator can answer "what did that turn do?" in one glance, and take it back
  in one action.
- The feature never surprises the operator: it is explicit, bounded, and reversible.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- **No GPL code.** `TVersions` (`ProjectVersioning.pas`) is GPL-3.0 and
  Windows-only, so it is *prior art only* — the shape, not the code (see Notes).
- The snapshot store rides **SQLite**, which we already vendor (no new dependency).
- Capture happens at the **turn boundary** in the runtime (which owns the loop and
  the workspace); the TUI is a client that reads the store and sends undo/redo.
- **The workspace is the boundary**: snapshot only inside it (the `Workspaces`
  trust boundary); never follow symlinks out of it.
- **One writer.** Undo/redo mutate the workspace, so they are serialized with the
  turn (no undo while a turn is mid-flight).

### Business / Time

- No deadline. `main` only, TDD-first, one logical commit per step.

## Dependencies

### Internal

- `hildegard.helper.store` (SQLite) — the snapshot tables (blobs, snapshots,
  entries) and their migration.
- `hildegard.helper.workspace` — the root and the trust boundary to confine to.
- `hildegard.helper.harness.turn` / `session.runtime` — the turn boundary where a
  snapshot is taken, and the command path for undo/redo.
- `hildegard.helper.session.protocol` — the undo/redo commands and the
  changed-files/diff replies (the TUI is a client).
- `hildegard.helper.files` — the existing workspace-confined read/write primitives
  (restore reuses the same path checks and atomic write).
- `hildegard.helper.tui.*` — the changed-files list and the diff view; the diff
  rendering can reuse the `TTextBlock`/`TMarkdownView` stack and the planned
  syntax highlighting.

### External

- None. (A line-diff algorithm is a small, pure, testable unit we own.)

## Risks

- **Scan cost.** A naive full-tree hash every turn is expensive. Mitigation:
  incremental capture by `(mtime, size)`; hash only changed files.
- **Storage blow-up.** Mitigation: content-addressed blobs (dedup) + an ignore
  list + a size cap; a binary or oversized file is recorded by hash/size.
- **Undo mid-turn.** Undoing while the agent is writing would race. Mitigation:
  undo/redo are refused (or queued) while a turn is in flight; the boundary is the
  sync point.
- **Destructive restore.** Undo rewrites the operator's files. Mitigation: atomic
  per-snapshot restore; the pre-undo state is itself a snapshot (so an undo is
  itself undoable); a clear confirmation for a multi-file restore.
- **Ignoring the wrong thing.** A wrong ignore rule silently hides a change.
  Mitigation: ignores are explicit, configurable, and shown in the UI.
- **Symlinks and special files.** Mitigation: do not follow symlinks out of the
  workspace; record a symlink as a link, not its target.
- **The operator edits a file out of band.** The design assumes the agent is the
  only writer (the optimistic case). A manual edit makes a diff's "before" state
  wrong. Mitigation: every diff carries the before/after hash; a restore verifies
  the current hash first, refuses by default on a mismatch, and hands the decision
  — and the responsibility — to the operator.
- **A pruned or corrupt link breaks the chain.** A missing diff loses every later
  turn for that file. Mitigation: pruning drops only turns older than the window
  and always leaves a full base; a failed apply is caught by the hash guard before
  it writes.
- **Retention is a hard horizon.** A turn older than the window cannot be restored
  to. Mitigation: the window is explicit and configurable, and the UI says so.

## Out of Scope

- Branches, merges, remotes, PRs.
- Committing to git, or interoperating with a git repo's index.
- Versioning outside the workspace.
- History rewriting / amending.
- Blame/annotate.
- Windows.

## Future Considerations

- **Named snapshots / pins** (keep a turn forever) and **GC** of unreferenced
  blobs.
- **Snapshot the operator's manual edits too** (not just the agent's turns), so the
  history is the workspace's, not only the agent's.
- **Cross-session history** (a workspace's snapshots across sessions).
- **Selective undo** — revert one file, not the whole turn.
- **A side-by-side diff** and word-level intra-line highlighting (reuses the syntax
  highlighting feature).
- **Export a snapshot** as a zip or a patch series.

## Notes

- **Prior art: SynProject `TVersions`.** It is the shape we want — one self-contained
  archive per workspace, first version plain and later versions delta-compressed,
  with a readable commit index, and a `DoCommit` that scans configured directories
  and records only what changed. But it is **GPL-3.0** (viral), **Windows-only**
  (`Windows`/`ShlObj`/`ActiveX`), Delphi-7-era, and depends on a chain of Synopse
  units; and its delta chain makes restore O(history). So: borrow the model, write
  our own on SQLite.
- **Why SQLite, not a zip.** We already vendor SQLite, and it gives the diff store
  transactional atomicity and crash-safety for free — which the zip model would
  have to build. The *model* is `TVersions`': a linear chain of diffs, bounded by a
  retention window.
- **Why a bidirectional diff with hashes.** One delta that applies both ways keeps
  undo and redo symmetric; the before/after hashes make the apply **verifiable**, so
  an out-of-band edit is detected before a write rather than after.
- **Why the turn is the unit.** A turn is when the agent's edits land and before the
  next one; it is the natural review point, it matches the ledger, and it is where
  undo/redo is safe (no writer in flight).
- **The two capabilities are one feature** because they share the store: the
  changed-files view and the diff view *read* a snapshot pair; undo/redo *move the
  cursor* over the same snapshots.
- **Interaction with Context Checkpoint.** They are independent: Context Checkpoint
  versions the *conversation*, this versions the *workspace*. Both ride turn
  boundaries, and both are "recoverable, not destructive".
- **ICE score.** Impact 8 (reviewability and reversibility of the agent's actual
  work; a parity table-stakes gap), Confidence 7 (the store is straightforward; the
  scan cost and the TUI surface need calibration), Ease 5 (store, diff engine, the
  changed-files view, the diff view, undo/redo, and the runtime commands).
  Priority: high.
- **Related:** `docs/features/Workspaces/FEATURE.md` (the boundary),
  `docs/features/Local_SQLite_Store/FEATURE.md` (the store this builds on),
  `docs/features/Sessions_And_Ledger/FEATURE.md` (the turn boundary and ledger),
  `docs/features/Context_Checkpoint/FEATURE.md` (the conversation sibling),
  `docs/research/cli-agent-harness-parity.md` (undo/checkpoint as a table-stakes
  gap).
