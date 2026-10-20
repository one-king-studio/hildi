# Implementation Plan: Windows Port v1

**Related:** [FEATURE.md](FEATURE.md) · [Windows_Port_v1.SPEC.md](Windows_Port_v1.SPEC.md)

## Implementation Tasks

### Phase 0: the platform-neutral pieces (shipped)

- [x] **Extract** `shell.textlines` (one `LinesOf` for every text command) and
      make the CR policy explicit; Unix keeps the CR, Windows strips it.
- [x] **Test** both modes (`test_shell_textlines`).
- [x] **Make** `mv` overwrite an existing file (delete-then-rename), with a
      test.

### Phase 1: `TWindowsShellFs`

- [ ] **Implement** `Resolve`, `ReadFile`, `WriteFile`, `ListDir`, `Stat`,
      `Info`, `Delete`, `Move`, `Copy`, `MakeDir`, `Touch` per the SPEC.
- [ ] **Extend** `PhysicalContains` for junctions and short names.
- [ ] **Test** the same suite against it (a platform-conditional test setup).

### Phase 2: the process profile

- [ ] **Add** the `cmd.exe`/`/c` profile (or Git Bash) and the "process tier
      unavailable" error path.
- [ ] **Test**: a missing profile is a clear error; the builtin tier still runs.

### Phase 3: CI and fixtures

- [ ] **Add** a Windows CI job running `make test` and `make shell-standalone`.
- [ ] **Add** CRLF twins to the text fixtures.
- [ ] **Run** the differential suites on Windows where the tools exist.

### Phase 4: docs

- [ ] Update `PORTABILITY.md` and `FEATURES.md`; rename this TODO to
      `Windows_Port_v1.DONE.md`.

## Success Criteria

- [ ] The suite is green on Windows with no command-level changes.
- [ ] CRLF and LF inputs agree for every line-oriented command.
- [ ] A missing process tier is an error, never a crash.
