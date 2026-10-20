# Feature: Per-call File Changes

**Status:** Phases 1 and 2 shipped. The builtin tier records every write
exactly (content included) through its filesystem seam; the process tier takes
an ignore-aware before/after snapshot of the tree and reports created, modified
and deleted paths. Surfacing the set (phase 3) is still a decision.

**Related:** [Builtin Shell Tier](../Builtin_Shell_Tier/FEATURE.md) ·
[Command & Flag Coverage](../Builtin_Shell_Tier/COMMAND_COVERAGE.md) ·
[Windows Port](../Windows_Port/FEATURE.md)

## The Problem

A tool call can change the workspace, and today nothing records *what* it
changed. `file_write`/`file_edit` know their one path, but `run_command` can
write any number of files through a compound script — and with the builtin tier
most of those writes are ours to see. Without a record, the operator cannot
tell what a call touched, the TUI cannot show a diff, and a checkpoint cannot
roll back a call.

## The Decision

Record changes **per tool call**, at the narrowest seam that sees them:

1. **The builtin tier writes through one filesystem.** `TWorkspaceShellFs` gained
   an `OnChange` observer, and every mutating operation reports
   `(path, kind, before, after, sizes)` after it succeeds: `WriteFile`
   (redirects, `sed -i`, `tee`), `Delete` (`rm`), `Move` (`mv`), `Copy` (`cp`),
   `MakeDir` (`mkdir`), `Touch`. Reads never report.
2. **One change set per call.** `ICommandExecutor.Execute` takes the call's
   `TFileChangeSet` (may be nil); `TCommandTool` creates it, passes it, and
   invokes `TCommandToolConfig.OnChanges` once when the call changed anything.
   A compound script therefore yields one set with many entries.
3. **Contents, bounded.** Before/after text is captured up to 256 KiB; larger
   or binary files record sizes only (`Captured = False`). A summary renders
   `M a.txt (+3 -1), A b.txt, D c.txt`.
4. **The process tier is phase 2.** A spawned program (`git`, `make`,
   `mode=bash`) writes behind our back, so the executor will snapshot the
   workspace around it — stat/hash walk, ignore-aware through the reusable
   `.gitignore` parser — and diff the result into the same set.

## Boundaries

- **Observability, not interception.** The recorder never blocks or rewrites a
  write; it reports what happened.
- **No new tool parameters.** The model's contract is unchanged.
- **The consumer decides where it surfaces** (tool-result line, TUI diff pane,
  checkpoint store) — that is phase 3, not this.
- **Ignored files are not tracked** for the process-tier snapshot (the tier's
  own writes are, which is correct: the shell wrote them on purpose).

## Acceptance

- A compound `run_command` that creates, modifies and deletes files yields one
  change set naming each path and kind, with before/after text for small files.
- `sed -i`, `tee`, `mv`, `cp`, `rm`, `mkdir` and redirects all appear.
- A call with no writes invokes no callback.
- The callback fires once per call, never per file.
