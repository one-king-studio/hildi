# SPEC: Per-call File Changes v1

**Related:** [FEATURE.md](FEATURE.md)

## Types

```pascal
unit hildegard.helper.workspace.changes;

type
  TFileChangeKind = (fcCreated, fcModified, fcDeleted);

  TFileChange = record
    Path: string;             // workspace-relative, '/'-separated
    Kind: TFileChangeKind;
    IsDir: Boolean;
    Before, After: string;    // '' when absent or not captured
    BeforeSize, AfterSize: Int64;
    Captured: Boolean;        // text captured (<= 256 KiB)
  end;

  TFileChangeSet = class
    procedure Add(const AChange: TFileChange);
    procedure Clear;
    function Summary: string;                     // "M a.txt (+3 -1), A b.txt"
    function CountOf(AKind: TFileChangeKind): Integer;
    property Count: Integer;
    property Items[Index]: TFileChange; default;
  end;
```

`Summary` codes: `A` created, `M` modified, `D` deleted; a modified captured
file also shows net line deltas, an uncaptured one its byte sizes.

## The observer

`TWorkspaceShellFs` gains

```pascal
property OnChange: TShellFsChangeEvent;   // proc(const AChange: TFileChange)
```

and reports after a successful mutation:

| Operation | Reported |
|---|---|
| `WriteFile` (truncate) | `fcCreated` when new, else `fcModified` if the content differs |
| `WriteFile` (append) | as above, with `After = Before + Data` |
| `Delete` (file) | `fcDeleted`, before content captured |
| `Move` | `fcDeleted` (source) + `fcCreated` (destination) |
| `Copy` | `fcCreated` (new) or `fcModified` (existing target) |
| `MakeDir` | `fcCreated`, `IsDir` (only when it did not exist) |
| `Touch` | `fcCreated` (empty) when new |

A write that leaves the content unchanged reports nothing (no diff to show).
`Delete` on a directory reports only the directory itself in v1.

## Plumbing

- `ICommandExecutor.Execute(..., AMode, AChanges: TFileChangeSet; out AExecution)`.
  The set may be nil (tests, callers that do not care).
- `TBuiltinShell.Create(..., AOnChange: TShellFsChangeEvent = nil)` passes it to
  the workspace filesystem.
- `TCommandToolConfig.OnChanges: TCommandChangesEvent` — invoked once per
  `Run`, after the executor returns, only when the set is non-empty. The set is
  freed after the callback.

## Phase 2: the process-tier snapshot (shipped)

A spawned command writes outside the seam. Before `TProcessCommandExecutor`
runs, the executor (when a change set was supplied) walks the workspace into a
`TWorkspaceSnapshot` of `(size, mtime, is-dir)` per path
(`hildegard.helper.workspace.snapshot`); after the run — including a failed or
timed-out one — it walks again and `DiffSnapshots` reports created, modified
(size or mtime differs) and deleted paths through the same `TFileChangeSet`.

- **Ignore-aware.** Every `.gitignore` in the tree applies to its own
  directory (the reusable parser), and an ignored path — or anything under an
  ignored directory — is never walked, so an edit to an ignored file is not
  reported. `.git` is always skipped; symlinks are skipped (a directory link
  can loop).
- **Directories are entries**, so a created or deleted directory is reported
  (`IsDir`); a directory's mtime moving with its children is not a change.
- **Contents** are read for created and modified files up to
  `MaxCapturedChangeBytes` (`Captured = False` with sizes beyond that). A
  deleted file's bytes are already gone: its size is recorded, `Captured`
  stays False, and `Before` is empty.
- **Cost.** Metadata only, so a large tree costs one walk before and one after
  per call. The tool passes a set **only when `OnChanges` is assigned**; with
  no listener the process tier does not snapshot at all.
- **Limits.** mtime has one-second resolution on Unix, so a same-size rewrite
  within one second is not seen — the caveat git's own index has. The snapshot
  root is the call's working directory; a script that `cd`s elsewhere is not
  tracked.

## Phase 3: surfacing (decision)

The recorder is a producer; nothing consumes it yet. The options:

- **tool result line** — append `[changed: M a.txt (+3 -1), A b.txt]` to the
  `run_command` transcript (model-visible, cheap, changes the format);
- **TUI diff pane** — the session forwards `OnChanges` to a turn event and the
  view renders a diff;
- **checkpoint store** — persist the set with the turn for a later revert.

Recommendation: start with the TUI/checkpoint (the operator's question), and
add the model-visible line only if the model needs it to reason about its own
work.

## Testing

- `test_shell_executor.TestRecordsFileChanges`: a compound script (create,
  append, `sed -i`, `cp`, `mv`, `rm`, `mkdir`) yields one set with the expected
  paths and kinds, and the content rides along.
- `test_command_tool.TestRunDeliversFileChanges`: the callback fires once, with
  the set, per call.
- Existing suites: no change to command output.
