# Portability: the builtin shell on Windows

**Related:** [FEATURE.md](FEATURE.md) · [Builtin_Tier_v1.SPEC.md](Builtin_Tier_v1.SPEC.md) ·
[Command & Flag Coverage](COMMAND_COVERAGE.md) · [Text & Data Commands](../Text_Data_Commands/FEATURE.md)

## The strategy

The builtin shell tier is not only a gate or a speed-up: it is the **portable
execution substrate**. On Windows there is no `/bin/bash`, and no `sed`,
`grep`, `awk`, `jq`, `rg`, `tail`, `sort` or `wc` either. Proxying commands to
the host's binaries (useful on macOS/Linux as an accelerator) cannot be the
architecture.

So:

- **The builtin tier is the portable core.** Every command the harness needs for
  composition is implemented in Pascal over the filesystem seam.
- **The process tier is the Unix accelerator and the escape hatch.** Where
  `/bin/bash` and real programs exist, they handle the long tail; on Windows
  they may be absent, and the script simply declines to a clear error (or a
  configured shell such as Git Bash).
- **`mode=builtin` is the portability mode** (no spawn, only our commands);
  `mode=auto` may proxy where the platform has the binaries; `mode=bash` is
  Unix-only by definition.

## What is already portable

- `src/shell/**` is pure Pascal + the RTL: no C, no regex, no OS unit.
- The harness's tier talks to the filesystem only through `IShellFileSystem`;
  `TWorkspaceShellFs` uses `TFileStream`, `FindFirst`, `RenameFile`,
  `DirectoryExists` — all RTL, all cross-platform.
- `sed`, `grep`, `awk` (planned) and the coreutils are written against that
  seam, not against the host shell.
- The parser handles `\r\n` input (a `\r` before a `\n` is swallowed).

## The audit (fixed)

The command set had three Unix-only spots; all are now guarded:

| Spot | Before | Now |
|---|---|---|
| `test -r/-w/-x` | `fpAccess(path, R_OK/W_OK/X_OK)` | `{$ifdef unix}`; elsewhere existence (documented coarse fallback) |
| `grep -r` symlinked-dir skip | `fpLstat` + `S_IFMT`/`S_IFLNK` | `{$ifdef unix}`; the walk's depth limit (64) bounds a Windows junction loop |
| `uses BaseUnix` | unconditional | `{$ifdef unix}, BaseUnix{$endif}` |

Nothing else in the tier (or in `src/shell`) imports an OS unit.

## What a Windows port still needs

1. **`TWindowsShellFs`** — an `IShellFileSystem` for drive letters and `\`
   separators: accept both separators on input, present `/` internally, and
   teach `PhysicalContains` about junctions. (`TWorkspaceShellFs` is the model.)
2. **CRLF policy** — decide once, globally. Recommended: `LinesOf` strips a
   trailing `\r` (so `grep`, `sed`, `awk`, `wc -l`, `sort`, `uniq`, `head`,
   `tail` behave); `cat` and `wc -c` stay byte-faithful. Without this, every
   line-oriented command sees a `\r` it did not ask for.
3. **Rename-over-existing** — `RenameFile` fails when the target exists on
   Windows. `mv` and any atomic write must delete-then-rename (or use a temp +
   `ReplaceFile`). `sed -i` currently writes in place, so it is unaffected.
4. **Case-insensitive paths** — glob and case matching are case-sensitive,
   which matches bash on Windows. No change; document it.
5. **Binary mode** — `TFileStream` is binary on all platforms (no text-mode
   translation), so `wc -c`, `sed -i` and redirects are byte-exact. Good.
6. **Process tier** — `TProcess` is cross-platform, but the *profile* is POSIX
   (`/bin/bash -c`). A Windows profile needs `cmd /c` (or Git Bash) and is out
   of scope here.

## The target command set

"Enough for composition" — the set an agent needs to read, filter, transform and
write a workspace, on any OS:

| Layer | Commands | Status |
|---|---|---|
| files | `cat`, `head`, `tail`, `wc`, `ls`, `mkdir`, `rm`, `mv`, `cp`, `touch` | done |
| text | `grep`, `sed`, `sort`, `uniq`, `basename`, `dirname`, `test`, `[` | done |
| transforms | `awk` (fields), `cut`, `tr`, `tee`, `printf` | `awk` done; the rest small |
| search | `grep -r`, `find`, `rg` (alias with rg's defaults) | `grep -r` and `find` done; `rg` small |
| data | `jq` (paths), `yq` (paths) | `jq` done; `yq` if asked |
| programs | `git`, `make`, `fpc`, `python3`, `curl`, `sqlite3` | **not** implementable; process tier only |

The last row is the honest boundary: those are real programs, not shell
primitives. On Windows the machine either has them or does not; the tier must
never pretend to be them.

## Testing

- The UNIX build keeps `make check` green (the guards are no-ops there).
- A future Windows CI job runs the same suite against `TWindowsShellFs`; the
  `{$ifdef}` branches are the only code it exercises differently.
- The command differential fixtures are recorded from `/bin/bash`, so they pin
  the Unix semantics; a Windows port adds its own recorded fixtures where the
  host tools differ (line endings, `ls -l`).
