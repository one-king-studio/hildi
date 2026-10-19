# Implementation Plan: Builtin Shell Tier v1

**Related Specification:** `Builtin_Tier_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

The harness consumer of the Shell Library: a workspace-bounded filesystem, a
closed command set, a per-command gate over the existing approval service, tool
dispatch, and an `ICommandExecutor` that prefers the tier. Spec-driven, TDD,
`make check` before moving on. `main` only.

## Implementation Tasks

### Phase 0: The workspace filesystem

- [ ] **Create** `src/hildegard.helper.shell.fs.pas` with `TWorkspaceShellFs`:
      `Resolve`, `ReadFile`, `WriteFile`, `ListDir`, `Stat`, `Delete`, `Move`,
      `Copy`, `MakeDir`, `Touch`.
- [ ] **Test**: read/write/append/list/stat; every op refuses an outside path;
      a symlink to the outside is refused; recursive delete; move; copy;
      mkdir `-p`; touch; the read cap.

### Phase 1: The commands

- [ ] **Create** `src/hildegard.helper.shell.commands.pas` with
      `TBuiltinCommands` and the command table from the SPEC.
- [ ] **Test**: each command's output and status for the common and the error
      case; combined short flags; `--`; an unknown option; `grep`'s regex
      refusal without `-F`; `test`/`[` forms.

### Phase 2: The tier

- [ ] **Create** `src/hildegard.helper.shell.tier.pas` with `TBuiltinShell`:
      the pre-flight (parse, names, literal options), the gate (ask construction
      + `IApprovalService.Resolve`), the run, and tool dispatch.
- [ ] **Test**: a supported script runs; an unregistered name declines; an
      unsupported literal option declines; a parse error declines and nothing
      runs; the gate is asked once per command, in order, with the inherited
      reason; an exact grant suppresses; a denial is 126; `tool` dispatch with
      the allow-list; `run_command` refused; an outside path refused.

### Phase 3: The executor and the wiring

- [ ] **Change** `ICommandExecutor.Execute` to take `const AReason: string`;
      update `TProcessCommandExecutor` and `TCommandTool.Run`.
- [ ] **Create** `src/hildegard.helper.shell.executor.pas` with
      `TBuiltinCommandExecutor` (tier first, process fallback).
- [ ] **Wire** `hildegard.helper.harness.session`: build the tier config from
      the workspace root, the allow-list, and the session's tool resolution.
- [ ] **Test**: the executor uses the tier when supported (fallback not called)
      and falls back when not; reasons pass through; execution fields.

### Phase 4: Differential command fixtures

- [ ] **Add** `tests/data/shell_commands_differential.txt`: command outputs
      recorded from `/bin/bash` and replayed against `TBuiltinCommands`.
- [ ] **Test**: every fixture matches.

### Phase 5: Validation and docs

- [ ] `make test`, `make test-leak`, `make check` — green.
- [ ] **Update** `FEATURES.md`; rename this TODO to `Builtin_Tier_v1.DONE.md`.
- [ ] **Record** what the tier does not cover (the fallback list) for the next
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

- [ ] All tasks checked.
- [ ] Every SPEC acceptance criterion maps to a passing test.
- [ ] `make check` passes (tests + leak gate).
- [ ] A supported `run_command` spawns no process.
- [ ] The fallback is chosen before any side effect.
