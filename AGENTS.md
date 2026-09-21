# hildegard-helper

A headless agent harness written in Free Pascal (FPC), developed locally with a
heavy emphasis on test-driven development.

The goal is to install this on a remote device, register it to a Hildegard
account, and let an AI agent act on that machine through tools. Today it provides
the execution core (shell commands via a bounded-concurrency pool), an embedded
SQLite store, and a single-threaded OpenAI-compatible agent loop with tools and
an interactive CLI.

New to the project? Start with `HANDOFF.md` for current state, decisions, and
lessons learned.

- Compiler: Free Pascal 3.3.1 (aarch64-darwin), configured via `~/.fpc.cfg`.
- FPC source tree (for reading RTL/FCL/Packages units): `/Users/johnrcui/Code/fpc`.
- Language mode: `{$mode delphi}` (Object Pascal).

## Engineering Ethos: Ponytail

Be a lazy senior developer - lazy means efficient, not careless. Before writing
code, stop at the first rung of the ladder that holds:

1. Does this need to be built at all? (YAGNI)
2. Does it already exist in this codebase? Reuse it.
3. Does the standard library already do this?
4. Does a native platform feature cover it?
5. Does an already-installed dependency solve it?
6. Can this be one line?

Then write the minimum that works. Read the task and trace the real flow
*before* climbing. Fix bugs at the root cause - grep the callers and fix the
shared function once. Deletion over addition; boring over clever; fewest files.
Question complex requests. Mark deliberate shortcuts with a `ponytail:` comment
naming the ceiling and the upgrade path. Not lazy about: understanding the
problem, validation at trust boundaries, error handling that prevents data loss,
security, and real-platform calibration.

Full pattern: `docs/guidelines/ponytail.md`.

## Project Structure

- `src/` - library units (`hildegard.helper.*`)
- `tests/` - fpcunit test suites
- `examples/` - runnable example programs
- `scripts/` - developer tooling (watch loop)
- `docs/` - source of truth for what was, is, and should be built
- `deps/` - vendored third-party units (git submodules)
- `build/` - generated output; never committed

## Commands

All artifacts land under `build/`.

- `make` - build the example (debug)
- `make test` - build & run the whole fpcunit suite
- `make test SUITE=<name>` - run one suite or a single test method
  (comma-separated lists allowed)
- `make test-leak` - run the suite under heaptrc; fails (exit 203) on leaks
- `make check` - all gates: `test` + `test-leak` (run before considering work done)
- `make watch [TARGET=test-leak]` - auto-rerun on source changes
- `make release` - optimized example build
- `make clean` - remove build artifacts

## Development Workflow

This project uses spec-driven development; see
`docs/guidelines/spec-driven-development.md`. **No implementation without a
specification.**

1. Define the feature: `docs/features/<Feature_Name>/FEATURE.md` (`/feature`)
2. Write the technical spec: `<Component>_v1.SPEC.md` (`/spec`)
3. Plan the tasks: `<Component>_v1.TODO.md`
4. Implement TDD-first (`/implement`), marking tasks done as you go
5. On completion, rename the TODO to `<Component>_v1.DONE.md`

### TDD loop

1. Add a test in `tests/` that expresses the next SPEC requirement.
2. `make test SUITE=<TestName>` - watch it fail (red).
3. Implement the minimum in `src/` to make it pass (green).
4. Refactor; rerun `make test SUITE=<TestName>`.
5. Run `make check` before moving on.

Each `test_*.pas` unit must be added to the `uses` clause of
`tests/hildegard_helper_tests.pas` - FPC does not auto-link test units.

Test conventions and the FPC/FCL testing gotchas we have hit (managed-record
`Default` vs `FillChar`, initialising managed locals and results, SQLite binding
and parameter numbering) are collected in `docs/guidelines/testing.md`.

### Commits

Follow `docs/guidelines/source-control.md`: Conventional Commits with a Gitmoji,
for example `feat(pool): ✨ add bounded-concurrency agent pool`. Commit
progressively - one logical change per commit - and only commit when asked.

## FPC / Platform Notes

Hard-won constraints; please respect them:

- Unix programs must list `cthreads` as the **first** unit, or threading and
  synchronization are broken at runtime.
- `TSemaphore` is unusable on macOS (`sem_init` returns `ENOSYS`). Use
  `TCriticalSection` + `TSimpleEvent`.
- FPC's `TDictionary` `D[key] := value` setter raises `EListError` when the key
  is absent. Use `AddOrSetValue`.
- `TProcess.ExitStatus` conventions vary by platform/build;
  `hildegard.helper.process` normalizes them (`NormalizeExit`).
- Tests compile with `-Sew`, so warnings are errors - handle every `case`
  branch explicitly.
- Always `WaitFor`/`Free` threads and their owned objects; `make test-leak`
  enforces this.

## Code Style

- Name units `hildegard.helper.<area>` (e.g. `hildegard.helper.process`,
  `hildegard.helper.pool`).
- Start every unit with `{$mode delphi}{$H+}`.
- Keep units focused; add tests for any new public behavior.
- Comments explain *why*, not *what*.
