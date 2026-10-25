# Workspace Snapshots

**Status: Implemented — capture and storage; deferred — the TUI surface and
state revert.**

What is **built**:

- **Capture**, at every write path. The builtin shell tier writes in-process
  through `TWorkspaceShellFs`, so `sed -i`, `tee`, `rm`, `mv`, `cp` and redirects
  are exact. The process tier (`git`, `make`, `mode=bash`) does an ignore-aware
  before/after tree walk. The file tools pass through `WriteAtomic`. The set is
  delivered through the `OnChanges` seam only — it is **not** appended to the
  tool result (a `[changed: …]` line used to ride it and was removed, since a
  diff view reads the change log instead).
- **Storage.** `TChangeRecorder` writes `file_changes` at the turn boundary
  (`hildegard.helper.changes.store`, migration v13), with **16-turn retention**
  enforced at the same boundary. A change is a patch anchored by its before/after
  hash, which is what makes it replayable and what makes a write a compare-and-swap.
  The patch is built from the two texts the recorder already holds, so a captured
  call replays; a side that was never captured (a process-tier modification whose
  before-text nobody read) stores no patch and says so rather than inventing one.
- **One consumer.** The board's staleness check reads the log
  (`ChangedSince`), which is what makes a board entry call itself stale.

What is **not built**, and is the remaining work:

- **The diff *viewer*.** A turn summary block now renders per-file stats
  (collapsed) and the diffs (expanded), so the log is legible to an operator for
  the first time. What does not exist yet is a dedicated viewer pane with per-file
  selection — the block shows every diff at once rather than letting the operator
  open one. See `Turn_Summary_v1.SPEC.md`.
- **Per-call anchoring** (`MessageId`). `TChangeRecorder.Observe` still writes
  `MessageId := 0`, because the tool-result row does not exist when the handler
  runs, so a diff cannot yet sit *under the tool block that produced it*. The
  turn summary groups by turn; per-call grouping needs the id stamped after the
  row is written, plus an `ekChanges` event carrying row ids to the client.
- **State revert**, and therefore `/undo`, `/redo` and `/revert`. The design is
  recorded in the FEATURE; two things gate it. Revert needs bytes, and a
  process-tier record has none (it captures no before-text), so only
  `Captured` rows are revertible and the UI must say which. And a subagent's
  writes land with `TurnId = 0` (only `THarnessSession` calls `SetTurn`), so a
  delegated turn would revert partially.
- **Keyframes are not written.** `KeyframeDue`, `PutKeyframe` and `Replay` exist in
  `src/changes` and are tested there, but the recorder never calls them, so nothing
  in the live path writes a keyframe and nothing replays. Replay is therefore
  *unbounded in principle* today — the retention window (16 turns) is what actually
  bounds the table. Wiring the keyframe interval is a prerequisite for a bounded revert,
  not an optimisation to defer. The patches themselves are now recorded, so replay
  has something to apply; what is still missing is the keyframe that bounds how far
  back it must start.

**Related:** [File Changes](../File_Changes/FEATURE.md) ·
[Workspace Board](../Message_Board/FEATURE.md) ·
[Task List](../Task_List/FEATURE.md) ·
[workspace-changes-and-board](../../research/workspace-changes-and-board.md) ·
[tool-result-shape](../../research/tool-result-shape.md)

## Overview

Give the operator **git-like visibility and control over the workspace**, without
depending on git (or on git being installed):

1. **See what changed.** Which files a tool call or a turn added, modified or
   deleted, with a diff of each.
2. **Undo / redo** a turn's changes, safely.

The record is a **workspace change log**: an append-only table of transitions,
each carrying the file's before and after hash and a bounded patch. It is written
by whoever sees the write — the builtin shell tier for in-process commands, the
file tools for their own edits, a before/after tree walk for a spawned program.
Storage is bounded by **patches anchored to periodic full copies (keyframes)**,
not by keeping every version whole.

Two things that make it more than a diff viewer, and were the reason to design it
properly rather than bolt a viewer on:

- **The hashes are compare-and-swap anchors.** A write can verify the file is
  still what it expects before touching it, so an out-of-band edit is a **visible
  conflict** rather than a silent clobber.
- **The log is an index for coordination.** It answers "who touched this, when",
  which is what makes [claims](../Task_List/FEATURE.md) and
  [board staleness](../Message_Board/FEATURE.md) possible.

```
TFileChange = record
  Path: string;              // workspace-relative, '/'-separated
  Kind: TFileChangeKind;     // fcCreated, fcModified, fcDeleted
  IsDir: Boolean;
  Before, After: string;     // capped text; '' when not captured
  BeforeSize, AfterSize: Int64;
  Captured: Boolean;         // the after side is readable text
  BeforeCaptured: Boolean;   // the before side is readable text
end;
```

Two independent flags, because the two sides are captured independently: a
spawned command's modification has the after text (the file exists when the
post-run walk happens) but not the before. A line delta needs **both**; without
them the honest rendering is a size pair.

## Granularity: the tool call is the *review* point, the turn is the *storage* unit

The turn boundary is where history is **stored**: bounded, atomic, safe to undo,
no writer in flight, pruned as a whole. But **the operator reviews work where it
happens** — a turn can be twenty tool calls, and "what did *that*
`file_search_replace` do?" is a different question from "what did the turn do?".

| level | unit | purpose | context cost |
| --- | --- | --- | --- |
| **Tool change** | one tool call, or one parallel batch | what the operator sees under the call, as it happens | **zero** (never in the prompt) |
| **Turn snapshot** | the turn boundary | dedup storage, the revert chain, retention | zero for the model |

### The tool-change record

Three producers, with very different confidence, and the record says which:

| Source | Who writes | What we know | `source` |
| --- | --- | --- | --- |
| File tools (`file_write`, `patch_apply`, …) | us, via `WriteAtomic` | exact before/after | `file-tool` |
| Builtin shell tier (`sed -i`, `tee`, `rm`, `>`) | us, via `TWorkspaceShellFs.OnChange` | exact before/after | `tier` |
| Process tier (`git`, `make`, `mode=bash`) | a subprocess | only a before/after walk | `process` |
| Watchdog | a periodic walk | same, later | `watcher` |

Keyed by the **tool-result message id** — *the design intent, not yet implemented*:
`TChangeRecorder.Observe` hardcodes `R.MessageId := 0`, because the tool result
row does not exist when the handler runs (`THarnessSession.RecordChanges` says so
in a comment). Today a change is keyed by its **turn** only, so the review point
is the turn rather than the call. Stamping the id after the row is written is the
first thing per-call review needs; until then a batch's changes group by turn.
A call touching several files yields several rows for one message.

### Attribution, including parallel batches

A call's changes are the writes that land between its start and its result. The
tool call id is known in the handler, so the change record carries it; for a
**parallel batch** (`Parallel_Tools`) each call keeps its own record, and the
batch's tool results arrive in **call order**, so the rendered blocks keep their
attribution. The diff view can group a batch ("3 calls, 5 files") or list per
call — the rows support both.

### The shell is covered now, by two mechanisms

This section previously said the tool level is "blind to the shell". **That is no
longer true**, and the correction matters because the old text argued against a
limitation that has since been closed:

- **The builtin shell tier writes in-process**, so every write goes through
  `TWorkspaceShellFs` — the same observer as an edit tool, with exact before and
  after text. `sed -i`, `tee`, `rm`, `mv`, `cp`, `mkdir` and redirects are all
  exact.
- **The process tier** (`git`, `make`, `mode=bash`) writes behind our back, so the
  executor takes an **ignore-aware before/after tree walk** and diffs it. Every
  `.gitignore` applies to its own directory; `.git` and symlinks are skipped.

What remains genuinely unknowable, and should be surfaced rather than implied:

| Case | State |
| --- | --- |
| Builtin tier write | exact content, both sides |
| File tool write | exact content, both sides |
| Process-tier create/modify | after text only — **size-only delta** (see `BeforeCaptured`) |
| Process-tier **delete** | size only; **the bytes are gone** before we look |
| A write between two snapshots of the same call window | attributed to the window, not the call |
| Two concurrent calls with overlapping windows | attributed to the **batch**, not the call |

So the UI must still distinguish *inferred* from *exact* — a `source` column on
every row, and the diff view naming it. The one case that cannot be undone is a
process-tier deletion: there is no patch to write, because the content no longer
exists. A **watchdog** that catches the delete event while the bytes are still
there is the only fix, and it is future work.

### Attribution, including parallel calls

A call's changes are the writes that land inside its window, and a parallel batch
makes that window shared. File-tool and tier writes stay exact under parallelism
because each knows its own path; **two concurrent subprocess calls do not**, since
each sees the other's writes. So the attribution floor for a subprocess call is
the **batch**, and the record says so rather than claiming per-call precision it
does not have.

### Why this is not duplicated work

The per-call record is the **input** to the turn view, not a rival to it: the
boundary scan can start from the paths the changes already named and fall back to
a full walk for the rest. The same rows serve three other consumers — the
staleness check in [the board](../Message_Board/FEATURE.md), the write CAS, and
"who touched this" for an orchestrator — which is why this is a log rather than a
viewer's cache.

## The real purpose: an agent's memory of change, not a git replacement

The primary consumer is the **agent**, and the primary reason is that many
operators will never have a git history at all — a non-technical operator running
the harness on a device has no repository, no commits, and no `git log` to read.
The change log is what lets an agent answer "what changed since I last looked?"
in a workspace that has never seen a version control system.

That reframes the priority order:

| Capability | Value | Why |
| --- | --- | --- |
| **Capture + query** | essential | The agent reading its own history is the feature. Without it there is no memory. |
| **Operator review surface** | essential | A recorded change nobody can see does not earn its retention. |
| **Revert to a state** | valuable | Restores a known point. Preserves the decision, not the keystrokes. |
| **Undo/redo of individual actions** | novelty | Parity with other harnesses; not a reason to build. |

### Revert, not undo

The target is **revert to a prior state**, not an undo stack. An undo stack
replays actions backwards and must decide what "one action" means; a revert names
a *state* and moves the workspace to it. Revert also preserves the decision the
agent made — the agent can see what it chose, revert it, and choose differently,
with both the choice and the reversal in the log.

A clean revert is worth having but is **not required**: because the log keeps the
before/after text and hashes, an agent that cannot apply a mechanical revert can
still read the history and write the old content back through the normal tools.
The fallback is the agent's competence, not a code path — which is why revert is
valuable but not load-bearing, and why it does not block the review surface.

Consequence for design: **the log must keep enough text to reconstruct**, not just
counts. A capped diff and a hash are enough to detect and enough to *show*, but a
revert needs the bytes. The capture flags already distinguish "we have both
sides" from "we have sizes only"; revert is therefore only possible for records
whose `Captured` and `BeforeCaptured` are both true, and the surface must say so
rather than fail at revert time.

## Presentation: a turn summary, then a diff viewer

Two levels, matching the existing granularity table: the **turn** is where a
summary aggregates, and the **call** (or file) is what a diff shows.

```
╭─ Turn 14 · 6 calls · 4 files · +38 −12 ──────────────────────╮
│  M src/hildegard.helper.replymeta.pas            +30 −8      │
│  A tests/test_replymeta_preamble.pas             +93 −0      │
│  M docs/features/.../Reply_Metadata_v1.SPEC.md    +17 −4     │
│  · 3 more files                                   +12 −6     │
╰──────────────────────────────────────────────────────────────╯
```

- **The summary is one collapsed block per turn**, at the turn boundary, built
  from the rows already written. It states counts and per-file `+added −removed`,
  not the diffs — cheap to render, cheap to skim.
- **A click opens the diff viewer** for the selected file (or the whole call),
  showing the unified diff already stored in `patch`. The viewer is a *reader*:
  it opens on demand, and closing it returns to the stream unchanged.
- **The model never sees either.** Zero prompt cost, as the granularity table
  already promises; the summary is for the operator's eye.

Three presentation rules, inherited from the design language:

1. **Counts are honest.** A record whose before-side was never captured shows
   `+? −?` rather than a line count computed against an empty string. The
   existing capture flags make this expressible; pretending otherwise would be
   the `[changed: …]` mistake in a new costume.
2. **Unattributed changes are labelled.** A write the harness never observed
   (`source` says so) appears as *unattributed* rather than silently attributed
   to the agent.
3. **The summary is a block, not a modal.** It rides the stream where the work
   happened, so a resumed session shows it in place, from the same rows.

**TUI dependency:** the viewer needs a scrollable pane over styled text, which the
toolkit already has. The toolkit is being split into `src/tui/core` (pure) and
`src/tui/widgets`; per the board it is **done on `agent/tui-split` (`57e5fa3`)
but not merged**, so this surface should land after that merges and should
consume what it exposes rather than reaching into the current units. The diff
viewer is a `widgets` consumer (scroll + styled text), not core.

## Three commands, and the mode decides who may use them

| Command | What it does | Single | Multi |
| --- | --- | --- | --- |
| `/undo` | Move the message tail back one turn; revert the captured changes from that turn | ✅ | ❌ |
| `/redo` | Move forward again, re-applying the changes | ✅ | ❌ |
| `/revert` | Open a history dialog; move to a chosen point | ✅ | ✅ |

`/undo` and `/redo` are **operator** commands. They move the conversation back a
turn and revert that turn's captured changes together, so the transcript and the
workspace stay consistent. The redo window stays open **until the operator sends
another prompt** — that is the same rule as an editor's undo history, and it is
what makes `/redo` safe: once new work exists there is no ambiguity about what
"forward" means.

`/revert` is the dialog form of the same idea: it opens the change history and
lets the operator pick a point to move to, rather than stepping one turn at a
time. `/undo` and `/revert` open **the same dialog**; they differ only in what
happens on selection — `/undo` is the one-step case and defaults to the previous
turn, `/revert` asks which point.

### Why multi-agent mode allows only `/revert`

In single-agent mode the operator owns the conversation: moving the tail back is
a local act, and nothing else can be relying on that turn.

With several sessions in a workspace, **another agent may already have read that
turn** — from the board, from a task card, from a claim. Moving the tail back
unilaterally would invalidate a conclusion someone else is acting on, silently.
So the operator does not get a choice: `/undo` and `/redo` are unavailable, and a
revert goes through the agent, which can see what its peers have done and can
say so on the board. The agent is the one that knows whether the revert is safe.

This is the same rule as the claim model: the thing that can see the
consequences is the thing that decides.

### What a rewind costs

`DeleteTurnMessages` already exists, so moving the tail back is a store operation
rather than a new mechanism.

Two invariants the commands must hold:

1. **The transcript and the workspace move together.** An `/undo` that reverts
   files but leaves the messages is a worse lie than no undo at all. Both halves
   move, or neither does.
2. **Refused while a turn is in flight.** The runtime holds the workspace; a
   revert under a running turn has no correct resolution. Refuse and say why
   rather than queue, since a queued revert would land on a state the operator
   never saw.

### Revert needs bytes, and not every record has them

Already stated above, but it is sharper for a command than for a viewer: a
command that offers a revert it cannot perform has failed the operator. So the
history dialog shows which points are revertible and which are
**inspect-only** — the ones whose before-side was never captured (process tier,
watchdog). The agent can still reconstruct those by reading history and writing
the old content back; the command cannot, and must not pretend to.

## Problem Statement

The agent edits the operator's files and runs commands that edit them. The ledger
records *messages* and *tool calls* — and now, since the change log shipped, the
*file states* those calls produced are recorded too. So the original complaint is
partly answered and partly not, and the distinction is the point:

- **Recorded:** every observed write is in `file_changes`, anchored by hashes,
  retained for 16 turns. "Who touched this, and when" is answerable.
- **Not visible:** nothing shows it to the operator. The log is written and pruned,
  and only the board's staleness check reads it. So *"what did that turn change?"*
  still cannot be answered from the UI, and a bad turn still cannot be reverted
  except by hand.

That is the remaining work, and it is why this feature is still open while its
storage half is done. The parity table lists **undo / checkpoint / rollback** as
table stakes (OpenCode `/undo`, Claude checkpoints, Codex git checkpoints); this is
our equivalent, and it needs the surface before it needs more capture.

Who feels it: the operator reviewing an agent's work, and the operator who wants
to try a turn, see it, and take it back.

Ponytail check first: do we need this at all? Yes — the agent's whole job is
changing the workspace, and there is currently no way to see or reverse that. Can
we reuse? We already vendor **SQLite** (a patch log plus periodic keyframes is a
few tables), the **builtin shell tier** already observes every write it makes, the
**snapshot walk** already exists for the process tier, and we already have the
**turn boundary** (`harness.turn`) and the **workspace** trust boundary. The
genuine gaps are the store, a diff generator, and the TUI surface.

## Goals

- **Capture** every change the agent makes, with enough text to reconstruct it —
  the foundation for an agent's own memory of change in a workspace that may have
  no git history at all.
- **A turn summary**: affected files with per-file `+added −removed`, as one
  collapsed block at the turn boundary.
- **A diff viewer** per file, opened on demand from the summary, rendering the
  unified diff already stored on the record.
- **Revert to a prior state** — not an undo stack. Revert names a state and moves
  the workspace to it, which preserves the decision the agent made; a mechanical
  revert is valuable but not required, since a capable agent can read the history
  and write the old content back through the normal tools.
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
- As an **operator**, I want to see what a *specific* tool call changed — the
  `file_search_replace` I just watched run, not only the turn's total — so I can
  review a long turn as it unfolds and catch a wrong edit where it happened.
- As an **operator**, I want a call's changes grouped per call (or per parallel
  batch) under its block, so a twenty-call turn reads as twenty reviewable steps
  rather than one big summary.
- As an **operator**, I want a diff of a changed file, so I can read what actually
  changed rather than re-reading the whole file.
- As an **operator**, I want to undo a turn's changes, so a bad or exploratory turn
  is reversible.
- As an **operator**, after undoing I want to redo, so I can flip back and forth
  while I decide.
- As an **operator**, I want a revert to be safe, so a half-applied revert never
  leaves the tree broken.
- As a **harness author**, I want the snapshot to ride the turn boundary, so I do
  not have to instrument every tool.

## Acceptance Criteria

### Functional Requirements

- [ ] Each change row records path, kind, **both hashes**, a bounded patch,
      `source` (file-tool / tier / process / watcher) and its `captured` flags;
      keyed by the tool result's message id, so live and resumed render identically.
- [ ] A **parallel batch** attributes file-tool and tier changes per call; two
      concurrent subprocess calls are attributed to the **batch**, and the record
      says so rather than claiming precision it lacks.
- [ ] The change record is **never part of the prompt**: it is stored beside the
      tool result, not inside its content.
- [ ] A call's changes are shown **at the call**, as it completes — not only in a
      turn-end summary.
- [ ] The diff is **bounded** when captured (a byte cap), so a huge edit cannot
      bloat the store or the view; the view says it was truncated.
- [ ] A **patch is applied as a compare-and-swap**: the file's current hash must
      match `before_hash` first, and the result must hash to `after_hash` after.
- [ ] On a **hash mismatch** — the file changed outside the record — the write is
      **refused** by default and the operator is told which file and which other
      session last touched it. This is also the stale-read warning an agent gets
      when it is about to overwrite a peer's edit.
- [ ] The operator can **list the changes of a turn**: added / modified / deleted
      files, with per-file and total counts.
- [ ] The operator can open a **per-file diff** between two points in the log.
- [ ] **`/undo`** moves the message tail back one turn **and** reverts that turn's
      captured changes together; **`/redo`** moves forward and re-applies them.
      Both are **single-agent only**, refused unless exactly one live runtime
      holds the workspace. The redo window closes when the operator sends another
      prompt.
- [ ] **`/revert`** opens a history dialog listing revertible points and moves to
      the chosen one. Available in **both** modes; in multi-agent mode it is the
      only one of the three, because a peer may already be acting on the turn.
- [ ] The history dialog distinguishes **revertible** points from
      **inspect-only** ones (a record whose before-side was never captured), so
      a command never offers a revert it cannot perform.
- [ ] A revert is **atomic per turn**: a failure leaves the workspace in the
      pre-revert state, never half-applied.
- [ ] A command is **refused while a turn is in flight**, with the reason shown —
      never queued onto a state the operator never saw.
- [ ] **Ignore rules** apply (`.git/`, `build/`, `node_modules/`, every
      `.gitignore` in its own directory).
- [ ] **Binary and oversized files** record hash and size only; the view says so.
- [ ] An unchanged turn records **no rows at all**, so an idle turn is free.
- [ ] **Keyframes** bound replay: a full copy per path is stored when its
      accumulated patches exceed 2× its size or every 50 changes, so
      reconstructing state at any point never walks the whole history.
- [ ] History is **pruned** past a retention window, keeping the newest keyframe
      at the horizon so the remainder stays replayable.
- [ ] **Recording never changes the workspace** (the walk is read-only).

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
  the workspace); the TUI is a client that reads the store and sends revert requests.
- **The workspace is the boundary**: snapshot only inside it (the `Workspaces`
  trust boundary); never follow symlinks out of it.
- **One writer.** A revert mutates the workspace, so they are serialized with the
  turn (no revert while a turn is mid-flight).

### Business / Time

- No deadline. `main` only, TDD-first, one logical commit per step.

## Dependencies

### Internal

- `hildegard.helper.store` (SQLite) — the change-log tables (`file_changes`,
  `file_keyframes`) and their migration.
  entries) and their migration.
- `hildegard.helper.workspace` — the root and the trust boundary to confine to.
- `hildegard.helper.harness.turn` / `session.runtime` — the turn boundary where a
  snapshot is taken, and the command path for revert.
- `hildegard.helper.session.protocol` — the revert commands and the
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
- **Storage blow-up.** Mitigation: patches rather than whole copies, keyframes only
  when a path's patches exceed 2× its size, an ignore list, and a size cap; a
  binary or oversized file is recorded by hash and size only.
- **Undo mid-turn.** Undoing while the agent is writing would race. Mitigation:
  revert requests are refused (or queued) while a turn is in flight; the boundary is the
  sync point.
- **Destructive restore.** Undo rewrites the operator's files. Mitigation: atomic
  per-snapshot restore; the pre-undo state is itself a snapshot (so an undo is
  itself undoable); a clear confirmation for a multi-file restore.
- **Ignoring the wrong thing.** A wrong ignore rule silently hides a change.
  Mitigation: ignores are explicit, configurable, and shown in the UI.
- **Symlinks and special files.** Mitigation: do not follow symlinks out of the
  workspace; record a symlink as a link, not its target.
- **A write nobody observed.** A *builtin-tier* or *file-tool* write is exact,
  because it goes through the one choke point. The gap that used to be here — "the
  shell is invisible at the tool level" — is **closed** for the builtin tier and
  covered by a tree walk for the process tier; see *The shell is covered now*
  above. What remains is a write made by something we never see at all: a
  subprocess that edits and exits between two walks of the same tool call, or an
  operator editing out of band mid-turn. Mitigation: the record carries a `source`
  per row so *inferred* never reads as *exact*, and a file the snapshot sees but no
  call claimed is shown as **unattributed** rather than implied unchanged.
- **Capture cost at the write.** Reading the old text to diff requires the file
  contents the write was about to replace. Mitigation: `WriteAtomic` is the single
  choke point, so it is one place; the read is bounded by the file size cap, and a
  file over the cap records hash/size only.
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
  keyframes.
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
- **Why patches, anchored by hashes.** A patch plus the before/after hash is
  stateless: applying it verifies the file is still what the patch expects, so an
  out-of-band edit is refused rather than silently overwritten. Undo re-applies
  the reverse patch under the same check, so redo is symmetric without storing two
  forms.
- **Why the turn is the unit.** A turn is when the agent's edits land and before the
  next one; it is the natural review point, it matches the ledger, and it is where
  a revert is safe (no writer in flight).
- **Why the tool call is also a unit.** Reviewing work where it happens: a turn-end
  summary cannot answer "what did this one `file_search_replace` do?", and a
  twenty-call turn read as one total hides which step went wrong. The tool-level
  record is cheap (zero prompt cost, captured at the one write choke point) and is
  the **input** to the turn snapshot rather than a rival to it.
- **Why the diff is display-only.** A diff in the tool result would be permanent
  prompt cost, replayed every request, for information the model does not act on.
  It belongs beside `mrTool`'s content — see `docs/research/tool-result-shape.md`
  for the full argument, including why tool results should be Markdown rather than
  JSON.
- **The two capabilities are one feature** because they share the store: the
  changed-files view and the diff view *read* a snapshot pair; a revert *moves the
  cursor* over the same snapshots.
- **Interaction with Context Checkpoint.** They are independent: Context Checkpoint
  versions the *conversation*, this versions the *workspace*. Both ride turn
  boundaries, and both are "recoverable, not destructive".
- **Related:** `docs/features/Workspaces/FEATURE.md` (the boundary),
  `docs/features/Local_SQLite_Store/FEATURE.md` (the store this builds on),
  `docs/features/Sessions_And_Ledger/FEATURE.md` (the turn boundary and ledger),
  `docs/features/Context_Checkpoint/FEATURE.md` (the conversation sibling),
  `docs/research/tool-result-shape.md` (why the diff is display-only and why tool
  results should be Markdown), `docs/research/cli-agent-harness-parity.md`
  (undo/checkpoint as a table-stakes gap).
