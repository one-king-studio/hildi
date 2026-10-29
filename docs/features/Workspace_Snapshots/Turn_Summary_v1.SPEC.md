# Component Specification: Workspace Snapshots v1 — the turn summary and diff viewer

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `changes.types`, `changes.store`, `changes.log` (the standalone
library), `hildi.changes.store` (the SQLite adapter), and the TUI
widget layer (`tui.widgets.*`) after the core/widgets split.

**Depended on by:** the `/undo`, `/redo` and `/revert` commands (a later spec);
the diff view they open.

## Purpose

Show the operator what a turn changed: one collapsed **summary block** per turn
listing affected files with per-file `+added −removed`, and a **diff viewer**
opened on demand that renders the unified diff already stored on the record.

This spec deliberately covers only what today's data supports. It does **not**
add per-call anchoring (`MessageId` is still `0`), and it does **not** implement
revert. Those are separate specs; see [Out of Scope](#out-of-scope).

## Scope and the two gaps it must not paper over

### Net changes, not a pile of patches

A turn that edits one file three times must not show three diffs. Three patches
that undo each other read as a large change; the operator concludes the agent
rewrote something it merely touched. **The summary shows the net change per
path**: `diff(first before-text, last after-text)` within the turn.

That is a different question from "what did this call do", and both are wanted:

| View | Question | Source |
| --- | --- | --- |
| **Turn (net)** | what does the workspace look like now, versus when the turn started? | folded per path across the turn |
| **Call** | what did *this* tool call do? | the per-call row's own patch |

So the log keeps **both**, and they are written at different times:

- **Per-call rows** are appended as they happen (today's behaviour), each with
  its own patch. These are what a diff-under-the-tool-block reads.
- **One net row per path** is written at the turn boundary, carrying
  `diff(first.Before, last.After)`. This is what the summary and the diff viewer
  read.

`ForTurn` must return the **net** rows for presentation and the per-call rows for
call detail, so the record needs to say which it is:

```pascal
TChangeRecord = record
  ...
  { True for the folded per-path row written at the turn boundary; False for a
    per-call row. A turn's summary reads only net rows; a call's drill-down
    reads only per-call rows. Never mixed. }
  IsNet: Boolean;
end;
```

A new column (`is_net INTEGER NOT NULL DEFAULT 0`) and `ForTurn` gains a filter.
Without the flag the two kinds would double-count and the summary would report
both the net and the parts.

**The cost, stated plainly:** the recorder must hold, per turn, the *first*
before-text and the *last* after-text for each path. That is a small in-memory
map (bounded by the turn's file count), and it is the only way to compute a net
diff — the stored patch alone cannot reconstruct the turn's starting text,
because a keyframe is what `Reconstruct` needs and none is written.

**A nullified change is the point.** Two edits to a file that cancel out produce
a net row whose patch is empty; the summary shows the file as unchanged and the
viewer says so. That is the correct answer, and the one a pile of patches cannot
give.

### Per-call diffs ride the tool block, not the result text

The captured diff for a call appears **immediately under that call's tool block**
so it is unambiguous which call produced it:

- **Collapsed** (the default): the block shows **stats only** — `M path  +30 −8`,
  one line per file.
- **Expanded**: the block shows the **full diff**.

This is the presentation the operator asked for, and it has one hard constraint:
**the diff must not be appended to the tool result text.** `AResult` is what the
model reads back; a diff there would enter the prompt on every subsequent turn.
The block is a *rendering* of stored data, not part of the result.

That means the diff has to reach the TUI by a route other than the result
string. Today nothing carries it:

```pascal
TToolResultEvent = procedure(const AId, AName, AResult: string;
  AOk: Boolean) of object;         // no change payload
// and on the wire:
ekToolResult: PutStr(O, 'tool_id', ...); PutStr(O, 'text', ...)
```

Two options, and the second is the one this spec takes:

| Route | Cost | Problem |
| --- | --- | --- |
| Extend `TToolResultEvent` with a changes payload | one signature change, 2 call sites | the payload crosses the NDJSON wire for every call; large for a big diff |
| **Read the rows in the TUI, keyed by tool id** | a new `ekChanges` event carrying only *ids* | none — the TUI already has a store handle |

So: the runtime emits a small `ekChanges` event at each tool-call boundary
carrying the **ids** of the rows it just wrote (not their patches), and the TUI
reads those rows and renders them under the matching block. The patch crosses
the socket once, inside the reply to that read, instead of riding every event.

**Consequence for the net/patch split:** the per-call rows are what this block
renders. The net rows are what the turn summary renders. A call whose changes are
later undone in the same turn still shows its own diff — that is a true statement
about that call — but the turn summary shows the net. See the tension below.

### The two gaps

The feature doc names two things the code does not do. Both are visible in the
UI, so they must be stated rather than hidden:

| Gap | Reality | What the UI does |
| --- | --- | --- |
| Per-call anchoring | `TChangeRecorder.Observe` writes `MessageId := 0`; the tool-result row does not exist when the handler runs | The summary aggregates by **turn**. There is no diff-under-tool-block. |
| Capture completeness | The process tier (`git`, `make`, `mode=bash`) captures the after-text but not the before-text, so it records sizes and a hash, never a patch | A file with no patch renders `+? −?` and the viewer says the diff was not captured. It never renders a line count computed against an empty before-side. |

A summary that guessed at either would be the `[changed: …]` mistake in a new
costume: a number that looks authoritative and is not.

## Requirements

### Functional

- [ ] A turn with recorded changes renders **one summary block** at the turn
      boundary, after the turn divider.
- [ ] The block lists affected files, each with its change kind and
      `+added −removed` where a patch exists, and `+? −?` where it does not.
- [ ] The block is **collapsed by default** and bounded: at most `MaxFiles`
      files are named, with `· N more files · +a −r` summarising the rest.
- [ ] A turn with **no** recorded changes renders no block (an empty summary is
      noise, not information).
- [ ] Selecting a file opens the **diff viewer** for that file: a scrollable pane
      rendering the stored unified diff with added lines, removed lines and hunk
      headers distinguished by colour **and** a leading glyph.
- [ ] The viewer is **read-only**; closing it returns to the stream unchanged.
- [ ] The viewer states when the diff is **capped** (the patch was truncated at
      the cap) and when it was **not captured** (no patch on the record).
- [ ] A **resumed session** renders the same summary blocks from the same rows,
      so live and resumed views agree.
- [ ] Changes whose `SessionId` is `''` (a watcher) or whose `ExternalSession` is
      set (a peer caught writing) are labelled **unattributed** and **external**
      respectively, never silently attributed to the agent.

### Non-Functional

- [ ] **Zero prompt cost.** Nothing in this spec enters the model's prompt.
- [ ] The summary is built from **one query per turn**, not one per file.
- [ ] Render cost is proportional to the visible blocks, not the transcript
      (the existing windowing must not be defeated).
- [ ] `make check` green, leak-clean, `make tui-standalone` still green.
- [ ] macOS + Linux; no new dependency.

## Contracts & Interfaces

### The one library change: query by turn

`IChangeStore` has `ForPath`, `Latest` and `Touching`, but no way to ask "what
changed in this turn". The table already has `turn_id`, so this is a query, not a
migration:

```pascal
{ Every change recorded for one turn, ascending id (i.e. in write order).
  A turn with no changes returns an empty array, which is a success: "nothing
  changed" is an answer, not a miss. }
function ForTurn(AWorkspaceId: Integer; ATurnId: Integer;
  out ARows: TChangeRecordArray; out AError: string): Boolean;
```

It belongs on `IChangeStore` in `src/changes` (so `TMemoryChangeStore` gets one
too, and the library stays testable without a database), and on the SQLite
adapter. It must be indexed: `idx_changes_session` does not help, so this spec
adds `idx_changes_turn ON file_changes (workspace_id, turn_id)`.

### The summary model

A pure function over rows, so it is testable with no TUI and no database:

```pascal
type
  TFileChangeStat = record
    Path: string;
    Kind: TChangeKind;
    Added, Removed: Integer;
    { True when the record carries a patch, so Added/Removed mean something.
      False => the diff was not captured and the UI must show '+? -?'. }
    CountsKnown: Boolean;
    Capped: Boolean;
    Attributed: Boolean;   // False => watcher or external session
  end;

  TTurnChangeSummary = record
    TurnId: Integer;
    Files: array of TFileChangeStat;
    TotalAdded, TotalRemoved: Integer;
    { Files whose counts are unknown; the total excludes them and says so. }
    UnknownCount: Integer;
  end;

{ Build a summary from one turn's rows. Never raises; empty rows yield an empty
  summary with Files = nil, which the caller renders as no block. }
function SummarizeTurn(const ARows: TChangeRecordArray): TTurnChangeSummary;

{ One line per file, `M path  +30 -8`; capped at AMaxFiles with a `· N more`
  tail. Pure, so the block's text is testable. }
function SummaryLines(const ASummary: TTurnChangeSummary;
  AMaxFiles: Integer): TStringArray;
```

`Added`/`Removed` come from the stored patch, counted once when the summary is
built. A capped patch under-reports and says so (`Capped`), rather than being
counted as if complete.

### The block and the viewer

```pascal
{ A chat block kind, drawn like a tool block: a collapsed summary that expands,
  and whose file rows are selectable. }
TChatKind = (..., ckTurnChanges);

{ The viewer's state: which file, and the diff lines to draw. Built from one
  TChangeRecord; no store access at render time. }
TDiffView = class
public
  class function FromRecord(const ARow: TChangeRecord): TDiffView;
  function LineCount: Integer;
  function Line(I: Integer; out AKind: TDiffLineKind;
    out AText: string): Boolean;
end;
```

## Architecture

**Where it lives.** The summary model and diff parsing are **pure** and belong
beside the change library (`src/changes`, or a small `changes.summary` unit) so
they are testable with no harness. The TUI block and viewer are `tui.widgets`
consumers.

**Flow.**

```
turn boundary (runtime)
      │  rows already written by TChangeRecorder
      ▼
ForTurn(workspace, turn) ──► SummarizeTurn ──► ckTurnChanges block
                                                    │ operator selects a file
                                                    ▼
                                          ForTurn row's Patch ──► TDiffView
```

The runtime emits the summary with the turn-finished event (the block is drawn
where the turn ends). A resumed session builds the same blocks from the ledger
during replay, using the same `ForTurn` + `SummarizeTurn` path — one code path,
two entry points.

**No new storage.** This spec reads rows that already exist.

## Validation Rules

- A row with `Patch = ''` yields `CountsKnown = False`; it never yields
  `Added = 0, Removed = 0` as if the file were unchanged.
- A row with `Capped = True` yields the counts its truncated patch supports and
  `Capped = True`, so the UI can say "at least".
- A summary built from zero rows is empty and renders nothing.
- `ForTurn` with an unknown turn id returns an empty array and `True` (an
  existing turn that changed nothing and a turn id that does not exist are the
  same answer for this feature).

## Error Handling

- `ForTurn` failing is a **render failure, not a turn failure**: the block is
  omitted and the error is logged once. Nothing in this feature may fail a turn.
- A malformed patch (stored but unparseable) renders as **not captured** with a
  one-line reason, rather than a half-drawn diff or an exception.
- The viewer over a huge diff is bounded by the same cap the record already
  carries; the viewer never re-reads the file from disk.

## Testing Requirements

- `SummarizeTurn`: counts from a patch; `CountsKnown = False` when there is no
  patch; `Capped` propagates; unattributed and external rows are labelled; empty
  rows yield an empty summary.
- `SummaryLines`: ordering, the `· N more` tail, and the cap.
- `ForTurn` (memory store and SQLite store): a turn's rows in write order; an
  unknown turn is empty-and-True; a second turn's rows are not mixed in.
- `TDiffView`: hunk headers, added/removed/context line kinds; a capped patch; an
  unparseable patch.
- A **regression test for the resume/live parity**: the same turn replayed from
  the ledger yields the same summary text as the live path.
- The TUI block: renders collapsed, expands, and is absent for a change-free turn.

## Performance Targets

- `SummarizeTurn` over 200 files: under 5 ms (it is a single pass over rows).
- One `ForTurn` per turn rendered, not per file.
- No measurable change to steady-state frame cost (the windowing must still hold:
  a summary block's height is memoised like any other block).

## Security Considerations

- Diff content is **untrusted text** (a file the agent wrote). It is sanitised by
  the existing cell encoder (C0/C1 → U+FFFD) like any other block body.
- The viewer reads **only** the stored patch; it never opens a workspace file, so
  it cannot leak a path outside the workspace.
- Paths rendered in the summary are workspace-relative and already sanitised by
  the capture layer.

## Success Criteria

- After a turn that edited files, the operator sees one block naming the files and
  the counts, without asking the agent.
- Clicking a file shows its diff, and closing the viewer leaves the stream
  untouched.
- A turn with uncaptured changes says so, visibly, rather than showing `+0 −0`.
- Resuming the session shows the same blocks.

## The three commands: two mechanisms, one dialog

**`/undo` and `/redo` are MECHANICAL. `/revert` is AGENTIC.** They are not
variations on one operation, and the difference is the whole design.

| Command | Mechanism | What it does | Available |
| --- | --- | --- | --- |
| **`/undo`** | mechanical | Reset to an earlier state: revert the captured changes and rewind the transcript. The traditional undo. | When a completed turn exists |
| **`/redo`** | mechanical | Move forward again, re-applying the changes undone. | **Only after an `/undo`** |
| **`/revert`** | **agentic** | Inject a prompt telling the agent to revert the changes **while moving FORWARD** — the way `git revert` applies an inverse as a *new* commit rather than `git reset` erasing history. | Any completed turn |

### Why revert is agentic, and why that is not the same as undo

`/undo` moves the workspace *backwards*: the state after undoing turn N is the
state before turn N, and the transcript no longer contains N.

`/revert` moves **forwards**: the agent is asked to produce the inverse of a
previous turn's changes as *new work*. The reverted turn stays in the ledger; the
repository moves forward with a change that undoes it. Nothing is erased, so the
record shows both what was done and that it was later reverted — the `git revert`
model rather than the `git reset` one.

That is why it cannot be mechanical. The agent has to read what changed, decide
how to invert it in the *current* state (which may have moved on), and make a
coherent change. A patch inversion (`RevertText`) proves a byte-exact restore is
possible; a revert only needs the *effect* undone, and only the agent can judge
that when the file has changed since.

**Consequence for the machinery:** `/undo` uses `RevertTurn` (the mechanical
engine, precondition-checked). `/revert` uses none of it — it queues a prompt and
lets the loop do the work, through the agent's own gated tools.

### One dialog, two handlers

`/undo`, `/redo` and `/revert` all open **the same history dialog**: the captured
turns, newest first, with each turn's file stats. What differs is what selection
*does*:

- **`/undo`** — the dialog is the "go back to here" list. Selecting a turn undoes
  every turn from the newest back to and including it.
- **`/redo`** — the dialog is the "move forward to here" list, and it appears
  **only after an undo**. It shows the turns the undo took away, so the operator
  can move forward again. Absent after a prompt, because new work makes "forward"
  ambiguous.
- **`/revert`** — the same list, but selecting a turn injects the agentic revert
  prompt for it. Nothing is rewound; the reply is new work.

Sharing the dialog is deliberate: the operator is answering one question (*which
turn?*) three times, and the difference is in the action, not the browsing.

### Undo and redo are CUMULATIVE, and the wiped history is soft-deleted

"Undo five turns" means *walk back five turns*, not five separate commands. So:

- **`/undo` to turn N undoes the suffix**: every turn from the newest back to and
  including N, in reverse order. The workspace ends at the state before N, and the
  transcript ends before N. **This is the invariant**: the two move together over
  a *range*, not a single turn. Undoing one turn in the middle while later turns
  survive would leave the transcript claiming work that happened after a turn that
  no longer exists, on top of files derived from reverted state.
- **`/redo` to turn M re-applies the same suffix forward**, in order. Available
  only after an undo, and only for turns that undo took away.

**The wiped turns are soft-deleted, never erased.** A turn the operator undoes is
marked (status `tsUndone`, with who and when), its messages are marked
reverted rather than deleted, and its change rows are marked reverted. They are
excluded from **the current context** (not sent to the provider, not drawn in the
transcript) but they remain in the ledger.

Two consequences that make the marking mandatory rather than tidy:

1. **The record still shows what happened.** A reverted turn is a fact about the
   session: it was done, then undone. Hard deletion would make the history claim
   the work never occurred, which is the same class of lie as moving the files
   without the transcript.
2. **The aggregate stats must still count them.** The status bar's lifetime totals
   (billed tokens in/out, cache hit, wall time, request count) are the cost of the
   *session*, not of its current context. A turn that ran, consumed tokens, and was
   later undone still consumed them. So `SessionTotals` sums over requests joined
   to turns with **no status filter** — which it already does — and that must stay
   true. The context filter and the totals filter are deliberately different
   things: one asks "what does the model see?", the other "what did this session
   cost?".

Continuing from an undo **rewrites the future**: the operator who undoes five
turns and then prompts has abandoned those five, and the new turn replaces them
as the session's live tail. The abandoned turns keep their soft-deleted status.
`/redo` closes at that moment, because "forward" is no longer unambiguous.

## Out of Scope

- **Per-call anchoring** (`MessageId`) and diff-under-tool-block. Separate spec;
  requires stamping the id after the tool-result row exists.
- **The commands themselves** (`/undo`, `/redo`, `/revert`) and the history
  dialog. Separate spec — see above for the semantics they must implement.
- **Keyframes** — `KeyframeDue`/`PutKeyframe` stay unwired; nothing here replays.
- **Side-by-side / word-level diffs**; the viewer renders the stored unified diff.
- **Editing or exporting** a diff.

## Notes

- **Why the summary before the commands.** The summary works with today's data
  (rows keyed by turn) and the commands do not (revert needs captured bytes and
  the subagent turn-attribution question answered). Building the summary first
  makes the log legible, which is the precondition for anyone trusting a revert.
- **Why counts come from the patch.** Computing them from the before/after text
  would need both sides, which the process tier does not have. The patch is what
  the record actually holds.
