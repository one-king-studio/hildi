# Implementation Plan: Builtin Shell Tier v1

**Status: implemented (v1).** The deviations and refinements are recorded in
`Builtin_Tier_v1.SPEC.md` (notably `ICommandExecutor.OwnsApproval`, which stops
one command prompting twice).

**Related Specification:** `Builtin_Tier_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

The harness consumer of the Shell Library: a workspace-bounded filesystem, a
closed command set, a per-command gate over the existing approval service, tool
dispatch, and an `ICommandExecutor` that prefers the tier. Spec-driven, TDD,
`make check` before moving on. `main` only.

## Implementation Tasks

### Phase 0: The workspace filesystem

- [x] **Create** `src/hildegard.helper.shell.fs.pas` with `TWorkspaceShellFs`:
      `Resolve`, `ReadFile`, `WriteFile`, `ListDir`, `Stat`, `Delete`, `Move`,
      `Copy`, `MakeDir`, `Touch`.
- [x] **Test**: read/write/append/list/stat; every op refuses an outside path;
      a symlink to the outside is refused; recursive delete; move; copy;
      mkdir `-p`; touch; the read cap.

### Phase 1: The commands

- [x] **Create** `src/hildegard.helper.shell.commands.pas` with
      `TBuiltinCommands` and the command table from the SPEC.
- [x] **Test**: each command's output and status for the common and the error
      case; combined short flags; `--`; an unknown option; `grep`'s regex
      refusal without `-F`; `test`/`[` forms.

### Phase 2: The tier

- [x] **Create** `src/hildegard.helper.shell.tier.pas` with `TBuiltinShell`:
      the pre-flight (parse, names, literal options), the gate (ask construction
      + `IApprovalService.Resolve`), the run, and tool dispatch.
- [x] **Test**: a supported script runs; an unregistered name declines; an
      unsupported literal option declines; a parse error declines and nothing
      runs; the gate is asked once per command, in order, with the inherited
      reason; an exact grant suppresses; a denial is 126; `tool` dispatch with
      the allow-list; `run_command` refused; an outside path refused.

### Phase 3: The executor and the wiring

- [x] **Change** `ICommandExecutor.Execute` to take `const AReason: string`;
      update `TProcessCommandExecutor` and `TCommandTool.Run`.
- [x] **Create** `src/hildegard.helper.shell.executor.pas` with
      `TBuiltinCommandExecutor` (tier first, process fallback).
- [x] **Wire** `hildegard.helper.harness.session`: build the tier config from
      the workspace root, the allow-list, and the session's tool resolution.
- [x] **Test**: the executor uses the tier when supported (fallback not called)
      and falls back when not; reasons pass through; execution fields.

### Phase 4: Differential command fixtures

- [x] **Add** `tests/data/shell_commands_differential.txt`: command outputs
      recorded from `/bin/bash` and replayed against `TBuiltinCommands`.
- [x] **Test**: every fixture matches.

### Phase 5: Validation and docs

- [x] `make test`, `make test-leak`, `make check` — green.
- [x] **Update** `FEATURES.md`; rename this TODO to `Builtin_Tier_v1.DONE.md`.
- [x] **Record** what the tier does not cover (the fallback list) for the next
      feature.

## Files to Create/Modify

```
src/hildegard.helper.shell.fs.pas
src/hildegard.helper.shell.commands.pas
src/hildegard.helper.shell.tier.pas
src/hildegard.helper.shell.executor.pas
src/hildegard.helper.command.tool.pas      (the reason on the executor seam)
src/hildegard.helper.harness.session.pas   (wiring)
tests/test_shell_harness_fs.pas
tests/test_shell_commands.pas
tests/test_shell_tier.pas
tests/test_shell_executor.pas
tests/data/shell_commands_differential.txt
tests/hildegard_helper_tests.pas
docs/features/FEATURES.md
```

## Dependencies & Ordering

0 → 1 → 2 → 3 → 4 → 5.

## Success Criteria

- [x] All tasks checked.
- [x] Every SPEC acceptance criterion maps to a passing test.
- [x] `make check` passes (tests + leak gate).
- [x] A supported `run_command` spawns no process.
- [x] The fallback is chosen before any side effect.

## Outcome (v1)

- **The tier**: `TWorkspaceShellFs` (workspace-bounded, symlink-safe),
  `TBuiltinCommands` (22 commands), `TBuiltinShell` (whole-script pre-flight,
  per-command gate, tool dispatch), and `TBuiltinCommandExecutor` (tier first,
  `/bin/bash` fallback second).
- **Wiring**: the session builds the tier from the workspace root with an
  allow-list (`file_read`, `file_list`, `file_glob`, `file_grep`, `file_stat`,
  `mcp_*`); `HILDEGARD_BUILTIN_SHELL=0` disables it.
- **The gate**: the same `run_command:<bin>` refs and option shapes, the model's
  reason inherited, one ask per command, and `OwnsApproval` keeps the splitter's
  asks out of the builtin path.
- **Evidence**: the command differential (recorded from `/bin/bash`, jq and
  ripgrep) plus the unit suites; whole-script coverage is tracked in
  [COMMAND_COVERAGE.md](COMMAND_COVERAGE.md) (it has grown since this note).
  `make check` green, leak-clean.
- **Not covered**: anything outside the 22 commands or the listed flags
  (`git`, `curl`, `make`, `ls -l`, `grep -E`, `wc`-style formatting) falls back
  to the process tier, where the asks name the program and the paths. Growing
  the set means registering a handler, not changing the core. The measured
  coverage, the per-command flag table and the evidence-ordered backlog are in
  [COMMAND_COVERAGE.md](COMMAND_COVERAGE.md).
