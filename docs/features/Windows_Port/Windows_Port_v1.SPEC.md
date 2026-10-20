# SPEC: Windows Port v1

**Related:** [FEATURE.md](FEATURE.md) · [Portability notes](../Builtin_Shell_Tier/PORTABILITY.md)

## Scope

The platform pieces behind the existing seams: the Windows filesystem, the line
policy (shipped), rename semantics (shipped), the process profile, and CI. No
command learns about Windows.

## 1. The line policy (shipped)

`hildegard.helper.shell.textlines` owns line splitting for every text command:

```pascal
function SplitLinesEx(const S: string; AStripCR: Boolean): TStringArray;
function SplitLines(const S: string): TStringArray;   // platform default
function LinesOf(const S: string): TStringArray;      // alias
```

- Unix: `AStripCR = False` — a CRLF file keeps its `\r`, exactly as GNU/BSD
  `grep` does there. The differential fixtures pin this.
- Windows: `AStripCR = True` — a CRLF file behaves like its LF twin for
  `grep`, `sed`, `awk`, `cut`, `tr`, `sort`, `uniq`, `wc -l`, `head`, `tail`.
- `cat` and `wc -c` stay byte-faithful on both.
- `test_shell_textlines` covers both modes explicitly.

## 2. `TWindowsShellFs`

An `IShellFileSystem` rooted at a directory, mirroring `TWorkspaceShellFs`:

| Method | Windows behaviour |
|---|---|
| `Resolve(cwd, path)` | accept `\` and `/`; a drive-absolute path (`C:\x`, `C:/x`) is accepted; return `/`-separated absolute text |
| `ReadFile` / `WriteFile` | as today (binary `TFileStream`); the read cap applies |
| `ListDir` | sorted names, `.`/`..` excluded |
| `Stat` / `Info` | `GetFileAttributesEx`: size, last-write → Unix seconds; `Mode` from the read-only attribute (`0444`/`0666`, plus `0755`/`0555` for directories) so `ls -l` reads sensibly |
| `Delete` | recursive; refuse the root |
| `Move` | delete-then-rename (the shared `TWorkspaceShellFs` already does this) |
| `Copy`, `MakeDir`, `Touch` | as today |

- **Containment:** reuse `PhysicalResolve`/`PhysicalContains` from
  `hildegard.helper.workspace`, extended for junctions and 8.3 short names —
  the nearest existing ancestor is resolved, and the tail is re-appended.
- **Paths presented:** `/` internally, so commands, globs, `grep -r` output and
  `find` display the same text as on Unix.

## 3. `mv` over an existing file (shipped)

`TWorkspaceShellFs.Move` deletes an existing file target before renaming, which
is `mv`'s semantics and what Windows requires. A directory target is still an
error (the tier does not implement `mv dir/`).

## 4. The process profile

`TShellProfile` already carries `Executable`/`Switch`. On Windows the harness
configures `cmd.exe` + `/c` (or a configured Git Bash) and keeps the same
approval asks; if neither is configured, `run_command` reports that the process
tier is unavailable and the builtin tier still runs. The `run_command`
description names the platform shell it starts.

## 5. CI

- A Windows job builds with FPC and runs `make test` against `TWindowsShellFs`
  (the suite already avoids Unix-only assertions except where documented).
- The text fixtures gain CRLF twins: the same script over an LF and a CRLF
  copy must match.
- `make shell-standalone` runs on Windows too (the library has no OS unit).

## Recorded deviations

- `Mode` is derived from the read-only attribute, not an ACL; `ls -l` shows a
  permission shape, not Windows ACLs.
- Case-insensitive paths: matching stays case-sensitive (as bash on Windows
  behaves); `PhysicalContains` compares case-insensitively where the volume
  does.
- Symlinks/junctions: `grep -r`/`find` do not follow directory links; the depth
  limit (64) bounds a junction loop.
