# Feature: Windows Port

**Status:** Specified. Phase 0 shipped (the shared line policy and the
`mv` overwrite); the filesystem implementation and the CI matrix are pending.

**Related:** [Builtin Shell Tier](../Builtin_Shell_Tier/FEATURE.md) ·
[Portability notes](../Builtin_Shell_Tier/PORTABILITY.md) ·
[Text & Data Commands](../Text_Data_Commands/FEATURE.md)

## The Problem

The harness runs on macOS and Linux. On Windows there is no `/bin/bash`, and no
`grep`, `sed`, `awk`, `jq`, `rg`, `head`, `tail`, `sort` or `wc` either — an
agent's composition vocabulary is missing at the root.

The builtin shell tier exists for exactly this: `src/shell` has no OS unit, the
command set is pure Pascal over a filesystem seam, and the three Unix-only
spots in the command layer are already `{$ifdef unix}`. What remains is
platform surface, not language or commands:

- **paths** — drive letters, `\` separators, junctions/short names;
- **line endings** — CRLF files would give every line-oriented command a stray
  `\r`;
- **rename semantics** — `MoveFile` fails over an existing target where
  `rename(2)` succeeds;
- **the process tier** — its profile is `/bin/bash -c`;
- **CI** — nothing has ever run on Windows.

## The Decision

Port by implementing the platform pieces behind the existing seams, never by
forking a command:

1. **`TWindowsShellFs`** — an `IShellFileSystem` for Windows: accepts both
   separators, presents `/` internally, contains through junctions, and fills
   `Info` from the file attributes.
2. **One line policy** — `shell.textlines`: Unix keeps a trailing CR
   (byte-faithful), Windows strips it. Every text command already uses it.
3. **`mv` overwrites on both platforms** — delete-then-rename, which is what
   `mv` means and what Windows needs.
4. **A Windows process profile** (`cmd /c`, or Git Bash when configured) — or
   no process tier at all; a missing one is a clear error, not a crash.
5. **CI** — a Windows job runs the same suite against `TWindowsShellFs`; the
   `{$ifdef}` branches are the only code it exercises differently.

## Boundaries

- **No command forks.** The commands do not learn about Windows; the seam
  does.
- **The tier is the portable path.** The process tier stays an optional
  accelerator (Unix) and an escape hatch (installed programs).
- **No new Windows-only commands.** `cmd` builtins (`dir`, `copy`, `type`) are
  not added: the portable commands already cover them.

## Acceptance

- The suite passes on Windows with `TWindowsShellFs` (same tests, no skips
  beyond genuinely platform-specific ones).
- A CRLF file gives the same `grep`/`sed`/`awk`/`wc -l` results as its LF twin.
- `mv` replaces an existing file.
- A missing process tier reports a clear error; nothing crashes.
