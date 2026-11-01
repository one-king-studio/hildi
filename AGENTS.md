# Hildi

A small, portable coding agent written in Free Pascal (FPC), developed with a
heavy emphasis on spec-first, test-driven work.

The goal is an agent harness that is small, portable, and dependency-free: one
compiled binary with no runtime, package manager, or installer, gated by an
approval dialog that shows exactly what it proposes to run. Today it provides the
execution core (builtin shell commands classified by effect), an embedded SQLite
store, a change log with revert, subagents, an MCP client, a message board and
task list, and both a terminal UI (`hildi`) and a headless runtime
(`hildi-agent`).

**This file is the entry point.** It states the rules that apply to every change,
and points at the guideline that holds the detail. Read the guideline before
working in its area, not after.

## Where to look

| You are about to... | Read |
| --- | --- |
| Add or change a feature | `docs/guidelines/spec-driven-development.md` |
| Write or run tests | `docs/guidelines/testing.md` |
| Commit, branch, or use a worktree | `docs/guidelines/source-control.md` |
| Touch platform- or OS-conditional code | `docs/guidelines/platform-support.md` |
| Hit an FPC/unicode/unit-reuse trap | `docs/guidelines/fpc-gotchas.md` |
| Change a widget, layout, or the event loop | `docs/guidelines/tui-rendering.md` |
| Consider Windows | `docs/guidelines/windows-portability.md` |
| Decide whether to build something at all | `docs/guidelines/ponytail.md` |

Beyond the guidelines, `docs/` is the source of truth for what exists, what is
specified, and what was tried and rejected:

- `docs/features/FEATURES.md` — the feature index, with a verified status per
  feature. Start here.
- `docs/features/<Feature>/` — the artifact chain: `FEATURE.md` → `SPEC.md` →
  `TODO.md` → `DONE.md`.
- `docs/research/` — investigations, including post-mortems of things that did
  not work and why.

## Engineering Ethos: Ponytail

Be a lazy senior developer — lazy means efficient, not careless. Before writing
code, stop at the first rung of the ladder that holds:

1. Does this need to be built at all? (YAGNI)
2. Does it already exist in this codebase? Reuse it.
3. Does the standard library already do this?
4. Does a native platform feature cover it?
5. Does an already-installed dependency solve it?
6. Can this be one line?

Then write the minimum that works. Read the task and trace the real flow
*before* climbing. Fix bugs at the root cause — grep the callers and fix the
shared function once. Deletion over addition; boring over clever; fewest files.
Question complex requests. Mark deliberate shortcuts with a `ponytail:` comment
naming the ceiling and the upgrade path. Not lazy about: understanding the
problem, validation at trust boundaries, error handling that prevents data loss,
security, and real-platform calibration.

Full pattern: `docs/guidelines/ponytail.md`.

## Project Structure

- `src/` — library units, PascalCase (`HildiProcess.pas`), with subdirectories
  for `shell/`, `tui/`, `async/`, `changes/`, `markdown/`, and `fileignore/`
- `tests/` — fpcunit test suites
- `examples/` — runnable example programs
- `scripts/` — developer tooling (watch loop)
- `docs/` — source of truth for what was, is, and should be built
- `deps/` — vendored third-party sources, fetched by `scripts/fetch-*.sh`
  (pinned, checksummed, not committed)
- `build/` — generated output; never committed

## Commands

All artifacts land under `build/`. The gate is `make check`; nothing is done
until it passes.

| Command | What it does |
| --- | --- |
| `make` | build the example (debug) |
| `make test` | build & run the whole fpcunit suite, one process |
| `make test SUITE=<name>` | one suite or a single test method (comma-separated lists allowed) |
| `make test-parallel [SUITE="<names>"]` | the same suite, one process per suite |
| `make test-leak` | the suite under heaptrc; fails (exit 203) on leaks |
| `make test-leak-parallel` | the same leak run, one process per suite |
| `make check` | **all gates**: both suite passes (parallel) + both library isolation checks |
| `make watch [TARGET=test-leak]` | auto-rerun on source changes |
| `make release-tui` | optimized, stripped TUI — the shipping artifact (3.4 MB) |
| `make release-agent` | optimized, stripped runtime — the shipping artifact (3.9 MB) |
| `make release-agent-cli` | optimized, static CLI binary |
| `make release` | optimized *example* build (not a shipping artifact) |
| `make clean` | remove build artifacts |

`make build/debug/bin/hildi` builds the TUI. Beware `make tui-agent`, which **builds
and launches** it — in a non-interactive shell that hangs forever.

Parallel testing, why the gate runs it that way, and what each gate catches are
in `docs/guidelines/testing.md`.

## Development Workflow

Spec-driven: **no implementation without a specification.** The artifact chain
and its templates are in `docs/guidelines/spec-driven-development.md`; the short
version is `FEATURE.md` → `SPEC.md` → `TODO.md` → `DONE.md` under
`docs/features/<Feature_Name>/`.

TDD loop: add a failing test, watch it fail, implement the minimum, refactor,
then `make check`. Each `test_*.pas` unit must be added to the `uses` clause of
`tests/hildi_tests.pas` — FPC does not auto-link test units.

Commit with Conventional Commits and a Gitmoji, one logical change each, and
**only when asked**. See `docs/guidelines/source-control.md`.

## Code Style

- Units are PascalCase and named for their area: `HildiProcess.pas`,
  `HildiPool.pas`, or `ShellInterpreter.pas` under `src/shell/`. Delphi has no
  dot naming, so the old `hildi.<area>` namespace is gone.
- Start every unit with `{$mode delphi}{$H+}`.
- Keep units focused; add tests for any new public behaviour.
- Comments explain *why*, not *what*.

For the traps that make any of the above harder than it looks — unicode
encoding, `TDictionary`, ppu reuse, platform conditionals — see
`docs/guidelines/fpc-gotchas.md` and `docs/guidelines/platform-support.md`.
