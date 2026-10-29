# Component Specification: Changes Library v1

**Related Feature:** [Workspace Snapshots](../Workspace_Snapshots/FEATURE.md) ·
[File Changes](../File_Changes/FEATURE.md)
**Depends on:** nothing. A **standalone, publishable library** in the shape of
[Async Core](../Async_Core/FEATURE.md) and [Shell Library](../Shell_Library/FEATURE.md):
its own diff engine, its own log model, and a **store seam the consumer
implements**. No harness unit, no SQLite, no TUI.
**Depended on by:** the harness change recorder, the board's staleness rule, the
task list's "who touched this", and the undo/redo path.

## Purpose

Everything needed to answer three questions about a workspace's files, with no
notion of agents, sessions, or SQLite:

1. **What did this write change?** — a diff between two texts.
2. **What is the state of this file at point N?** — reconstruct from the log.
3. **Is this write safe?** — a compare-and-swap against an expected hash.

The harness supplies storage, hashing and the filesystem; the library owns the
model, the diff and the replay rules. That split is what makes it testable with an
in-memory store and liftable into another project, exactly like `src/shell/`.

## Prior art and reuse

| Need | Existing | Change |
| --- | --- | --- |
| Applying a unified diff | `hildi.patch` (trusted, tested) | **reuse the algorithm as the reference**, but the library cannot depend on a harness unit — move the applier into the library and have the harness unit delegate |
| File ignore rules | `hildi.gitignore` | same: the matcher moves in, the harness unit delegates |
| File walking | `hildi.workspace.snapshot` | the *walk* stays harness-side (it needs the workspace trust boundary); the library takes a seam |
| Hash + text capture | harness | the library takes a seam |

The genuinely new work: a diff **generator** (`hildi.patch` only
applies), the keyframe policy, and replay.

## The seam: two interfaces, no SQLite

```pascal
unit changes.store;
{ Persistence, supplied by the consumer. The library never opens a database. }

type
  TChangeRecord = record
    Id: Integer;               // assigned by the store on Append
    WorkspaceId: Integer;
    SessionId: string;         // '' => unattributed (a watcher)
    TurnId, MessageId: Integer;
    Path: string;              // workspace-relative, '/'-separated
    Kind: TChangeKind;         // ckCreated, ckModified, ckDeleted, ckDir
    BeforeHash, AfterHash: string;
    Patch: string;             // forward unified diff, '' when not applicable
    PatchBytes: Integer;
    Capped: Boolean;
    Source: TChangeSource;     // csFileTool, csTier, csProcess, csWatcher
    ExternalSession: string;   // a peer caught writing (CAS residue)
    CreatedAt: Int64;
  end;

  TKeyframe = record
    Id: Integer;
    WorkspaceId: Integer;
    Path: string;
    Hash: string;
    Content: string;
    ThroughChangeId: Integer;  // valid up to and including this change
  end;

  IChangeStore = interface
    ['{6F1D2E4C-8A3B-4C5D-9E7F-0A1B2C3D4E5F}']
    { Append one transition; returns the assigned id. }
    function Append(const ARecord: TChangeRecord; out AId: Integer;
      out AError: string): Boolean;
    { Changes for a workspace path, ascending by id, bounded by AFromId. }
    function ForPath(AWorkspaceId: Integer; const APath: string;
      AFromId, ALimit: Integer; out ARows: TChangeRecordArray;
      out AError: string): Boolean;
    { The newest change for a path, for the CAS check and the "last writer". }
    function Latest(AWorkspaceId: Integer; const APath: string;
      out ARow: TChangeRecord; out AError: string): Boolean;
    { Changes in an id range whose path is one of APaths (staleness, activity). }
    function Touching(AWorkspaceId: Integer; const APaths: TStringArray;
      AFromId: Integer; out ARows: TChangeRecordArray;
      out AError: string): Boolean;
    { The newest keyframe at or before AChangeId, or none. }
    function KeyframeBefore(AWorkspaceId: Integer; const APath: string;
      AChangeId: Integer; out AFrame: TKeyframe; out AFound: Boolean;
      out AError: string): Boolean;
    procedure PutKeyframe(const AFrame: TKeyframe; out AError: string);
    procedure Prune(AWorkspaceId, AKeepFromId: Integer;
      out AError: string);
  end;

{ A store that keeps everything in memory, for tests and for a
  filesystem-less embedding. The harness's SQLite store implements the same
  interface. }
type
  TMemoryChangeStore = class(TInterfacedObject, IChangeStore)
  end;
```

```pascal
unit changes.text;
{ The diff engine: a bounded unified diff between two texts, and the applier. }

{ A unified diff of ABefore -> AAfter, or '' when they are equal. ACapBytes
  bounds the result: a diff that would exceed it returns ACapped = True and a
  truncated body rather than failing. }
function DiffText(const ABefore, AAfter: string; ACapBytes: Integer;
  out ACapped: Boolean): string;

{ Apply AUnifiedDiff to AText. False + AError on a hunk that does not match. }
function ApplyUnifiedDiff(const AText, AUnifiedDiff: string;
  out AResult, AError: string): Boolean;
```

```pascal
unit changes.log;
{ The model: replay, compare-and-swap, and the record builders. }

{ Reconstruct the text at AChangeId from the nearest keyframe plus the patches
  after it. False when a patch does not verify or no keyframe is available. }
function Reconstruct(const AStore: IChangeStore; ARecord: TChangeRecord;
  out AText, AError: string): Boolean;

{ Should a keyframe be written for this path now? True when the accumulated
  patch bytes exceed 2x the current size, or every 50 changes. }
function KeyframeDue(const AAccumulatedPatchBytes: Int64; ACurrentBytes: Int64;
  AChangesSinceKeyframe: Integer): Boolean;

{ The compare-and-swap verdict for a proposed write. }
type
  TCasVerdict = (cvOk, cvConflict, cvUnknown);
function CheckWrite(const AStore: IChangeStore; AWorkspaceId: Integer;
  const APath, AExpectedHash, AActualHash: string; out AVerdict: TCasVerdict;
  out ALastWriter: TChangeRecord; out AError: string): Boolean;
```

## Requirements

### Functional

- [ ] `DiffText` produces a unified diff with 3 lines of context, a proper
      `---`/`+++` header and hunks; equal inputs return `''`.
- [ ] `DiffText` respects `ACapBytes` and reports `ACapped`.
- [ ] `ApplyUnifiedDiff` applies a diff this library generated, and one that
      `hildi.patch` generates (they must agree).
- [ ] A hunk whose context does not match fails with a message naming the line.
- [ ] `Reconstruct` returns the exact text at any change id, verified by hash at
      each hop.
- [ ] `KeyframeDue` implements the 2×-size / 50-change rule.
- [ ] `CheckWrite` returns `cvConflict` when the expected hash differs, naming
      the last writer (session and time).
- [ ] `TMemoryChangeStore` satisfies every method of `IChangeStore`, so the whole
      library is testable with no database.
- [ ] `Prune` removes changes and keyframes before a point, keeping the newest
      keyframe at the horizon so the remainder stays replayable.

### Non-Functional

- [ ] **No harness unit in the closure.** Asserted by
      `TestChangesClosureExcludesHarness`, mirroring the shell and async gates.
- [ ] `make changes-standalone` builds and **runs** a program against `src/changes`
      only.
- [ ] No new dependency beyond the RTL. No SQLite, no TUI, no `hildi.*`.
- [ ] `make check` green; leak-clean.
- [ ] macOS + Linux, FPC 3.3.1.

## Retention: 16 turns

**Decided: sixteen turns of change history.** Beyond that, a restore is better
served by moving forward than by reaching back — an agent that has made sixteen
turns of progress almost always wants to *revert the recent mistake*, not
excavate. Sixteen is also small enough to reason about: the whole window fits in
one screen of review.

Consequences the library must honour:

- `Prune` is called with the id of the change at the start of the 17th-oldest
  turn.
- The newest keyframe **at or before** the prune point is retained, so the oldest
  surviving change is still reconstructable.
- Nothing prunes a keyframe that a surviving change depends on.

## Contracts & Interfaces

Bodies are the implementer's. The three units are the whole public surface:

```pascal
uses changes.store, changes.text, changes.log;
```

Three notes on the shapes, each load-bearing:

- **`BeforeHash` / `AfterHash` are not optional.** They are what makes a patch
  stateless and a restore verifiable. A record without them cannot be applied
  safely, so the seam requires them rather than trusting a caller to fill them.
- **`Patch` may be empty while `AfterHash` is set.** A deletion whose bytes were
  never captured, or a capped diff, has no applicable patch — the record still
  says *something happened*, which is what the activity view and the staleness
  rule need.
- **`Source` is on the record, not inferred.** A consumer must be able to say
  "exact" versus "inferred", because the two mean different things to an
  operator.

## Architecture

### Why a library, and what that forces

The brief: **move hand-coded implementations into a library format, like async and
shell.** Applying that here has real consequences, not just a directory move:

| Consequence | Detail |
| --- | --- |
| No SQLite in the library | the harness's `store` implements `IChangeStore`; the library has `TMemoryChangeStore` |
| No workspace trust in the library | path confinement stays harness-side; the library is given already-relative paths |
| No hashing in the library | a consumer supplies hashes (we have SHA-256 in the TLS/MCP path) |
| No walking in the library | the ignore-aware walk stays harness-side, since it needs the trust boundary |
| The diff engine **moves in** | `hildi.patch` and `hildi.gitignore` become thin delegates to the library, so there is one implementation |

That last row is the point of the exercise: today the diff algorithm, the ignore
matcher and the change model are three hand-coded harness pieces. After this they
are one library with one test suite, and the harness units are adapters.

### Migration path (so nothing breaks)

**Correction (2026-10-21, after building the library).** This section previously
said the diff applier would "move in and the harness unit delegates". Reading both
implementations shows that is **not a move** — they solve different problems:

| | `hildi.patch` (shipped, trusted) | `changes.text` (library) |
| --- | --- | --- |
| Scope | **one patch, many files** | one text, one file |
| Failure | **tolerant**: a bad hunk is counted `Rejected` and the rest are attempted | **strict**: the first mismatch fails with a line number |
| I/O | injected `ARead`/`AWrite` callbacks | plain strings in, string out |
| Callers | `patch_apply`, which must report `applied`/`rejected` and keep going | replay, which must stop rather than produce a wrong file |

Both behaviours are correct for their caller. A tolerant replay would silently
reconstruct a *wrong* file; a strict `patch_apply` would refuse a patch where one
hunk of five was fine. So the library does **not** absorb the harness applier, and
the earlier "one implementation instead of three" claim is retired for this unit.

The honest position:

- `changes.text.ApplyUnifiedDiff` is the **replay-grade** applier: exact, strict,
  and its refusal is what makes a reconstructed file trustworthy.
- `hildi.patch` keeps the **patch-grade** applier: multi-file,
  tolerant, callback-driven, and its `Rejected` count is what `patch_apply`
  reports.
- There is genuine duplication in the *hunk matcher* between them. Unifying that
  is a real, small task — and it needs the library to gain a tolerant multi-file
  mode first, which is a design change, not a move.

The `gitignore` matcher is a **true** move: it is pure, does no I/O, and both
callers want identical semantics. That one can be delegated.

1. Create `src/changes/` with the three units and the memory store; no consumer.
   *Done.*
2. `changes-standalone` and the closure test. *Done.*
3. Move the `gitignore` pattern matcher into the library; the harness unit
   delegates. Its existing tests passing unchanged is the proof.
4. **Not** a move: give `changes.text` an optional tolerant multi-file mode, then
   have `hildi.patch` delegate. Only if the duplication of the
   hunk matcher proves costly — otherwise leave both, and record why.
5. Then implement `IChangeStore` over SQLite in the harness, and wire
   `OnChanges` (which today has **no consumer at all**).

## Validation and error handling

- `DiffText` on identical input returns `''` and `ACapped = False`.
- `ApplyUnifiedDiff` failing a hunk reports the hunk's line and the expected
  context, not just "failed".
- `Reconstruct` distinguishing "no keyframe" from "a patch did not verify" —
  the first is a retention boundary, the second is data corruption, and an
  operator needs to know which.
- `CheckWrite` with no prior record returns `cvOk` (nothing to conflict with),
  not `cvUnknown`; `cvUnknown` is reserved for a store failure.

## Testing Requirements

The library's own suite, all with `TMemoryChangeStore` and no database:

- [ ] Diff/applier round-trip: `Apply(a, Diff(a, b)) = b` across created files,
      single-line edits, multi-hunk edits, and CRLF-vs-LF text.
- [ ] `DiffText` agrees with `hildi.patch`'s parser (generate here,
      apply there).
- [ ] A diff over the cap reports `Capped` and still applies to the extent it
      covers.
- [ ] Reconstruct at every change id in a 100-change chain returns text whose
      hash matches that change's `AfterHash`.
- [ ] Keyframe written at the 2× threshold and at 50 changes; replay never walks
      more than one interval.
- [ ] `CheckWrite` returns `cvConflict` for a mismatched hash and names the
      previous session.
- [ ] Prune keeps the horizon reconstructable; a pruned change is not returned
      but its successor is.
- [ ] The closure test: no `hildi.*` unit in the transitive uses.
