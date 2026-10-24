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
- `deps/` - vendored third-party sources, fetched by `scripts/fetch-*.sh`
  (pinned, checksummed, not committed)
- `build/` - generated output; never committed

## Commands

All artifacts land under `build/`.

- `make` - build the example (debug)
- `make test` - build & run the whole fpcunit suite
- `make test SUITE=<name>` - run one suite or a single test method
  (comma-separated lists allowed)
- `make test-parallel [SUITE="<names>"]` - the same suite, one process per
  suite, in parallel (see below)
- `make test-leak` - run the suite under heaptrc; fails (exit 203) on leaks
- `make test-leak-parallel` - the same leak run, one process per suite
- `make check` - all gates: both suite passes (parallel) + library isolation
  (run before considering work done), ~60 s
- `make watch [TARGET=test-leak]` - auto-rerun on source changes
- `make release` - optimized example build
- `make clean` - remove build artifacts

### Parallel testing

`make test` runs all ~1,800 tests in **one process**. `make test-parallel` runs
each suite in **its own process**, `$(cores)` at a time:

```
make test-parallel                        # every suite, auto-discovered
make test-parallel SUITE="TSessionRuntimeTest TBoardStoreTest"
HILDEGARD_TEST_JOBS=4 make test-parallel  # cap the workers
```

Measured on a 10-core machine, 1,826 tests:

| Mode | Time | Failures |
| --- | --- | --- |
| `make test` (one process, `--all`) | ~169 s | see below |
| one process per suite, serial | ~100 s | 0 |
| one process per suite, 10-way | **~22 s** | 0 |

Two reasons to prefer it while iterating, and the second is not about speed:

1. **The heavy suites are I/O-bound**, not CPU-bound - they spawn subprocesses
   and wait on Unix sockets - so they overlap almost perfectly. The five
   heaviest (`TSessionRuntimeTest`, `THarnessDriverTest`, `TMcpClientTest`,
   `TSubagentSupervisorTest`, `THarnessAppTest`) go from 64 s serial to 21 s
   with all five in flight.

2. **Process isolation removes a class of failure.** Running every suite in one
   process produces failures in the TUI/harness suites that disappear when each
   suite gets its own process - serial or parallel, same tests, same order. That
   is intra-process state pollution, not a real defect. Until the shared state is
   found, one-process-per-suite is the trustworthy reading.

`test-parallel` refuses to start without `build/bin/hildegard-helper-agent`: the
integration suites spawn it, and its absence alone produces ~36 spurious
failures. `make headless-agent` builds it.

It is **not a replacement for `make check`** — the gate now runs both suite
passes this way (`test-parallel` and `test-leak-parallel`), so there is nothing
left to run single-process except the standalone library checks.


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
  synchronization are broken at runtime. List `cwstring` immediately after it in
  any program that handles non-ASCII text: without it the RTL uses an ASCII-only
  widestring manager, so implicit `AnsiString`↔`UnicodeString` conversions
  (fpjson, tool arguments, command strings) replace each non-ASCII code unit with
  `?`.
- **`cwstring` present is not enough: the implicit `UnicodeString`→`string`
  conversion is still lossy here.** The *decode* direction
  (`UnicodeString(s)`, `UTF8Decode`) is fine, but `string(U)`/`AnsiString(U)`
  writes `?` for non-ASCII (the widestring manager is not a UTF-8 encoder in this
  build; `SetMultiByteConversionCodePage(CP_UTF8)` does **not** fix it). Encode
  explicitly with `UTF8Encode(U)` — assign the `RawByteString` result to a
  `string`, and the panel's `UnicodeString(string)` decode reads it back
  correctly. This bit the session title, the compose's submitted prompt, and the
  modal's filter/rename; the fix is `UTF8Encode` at each such boundary.
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
- A widget's `Measure` and `Arrange` must lay children out at the **same width**,
  or per-width memos (block heights, wrapped text) miss and re-measure everything
  every frame - CPU that scales with the block count while typing or streaming.
  A `select` timeout of `0` is a busy poll: return it only when about to exit.
  See `docs/guidelines/tui-rendering.md`.
- **A vendored FPC library can use a different `{$mode}` than ours.** A vendored
  engine (the parked GocciaScript engine did) may be `{$mode delphiunicode}` per
  unit; forcing `-Mdelphi` on it clashes and the FPC 3.3.1 compiler **crashes**
  (first a type error, then a nondeterministic `EAccessViolation`). Every unit in
  `src/` self-declares `{$mode delphi}`, so the build simply **does not pass
  `-Mdelphi`** — it is redundant. Let any vendored FPC library set its own mode.
- **`{$R name.res}` resolves against the unit's OUTPUT dir, not its source dir.**
  A unit that uses `{$R Generated.X.res}` needs the `.res` findable — either
  copied next to the `.ppu`, or on the unit search path.
- **FPC reuses a precompiled unit only when the consumer's flags match and the
  source is still on the search path.** The ppu records the *relative* source
  path, so `-FU` (output) and `-Fu` (search) must point at the **same** dir and
  the defines must match; a mismatch silently invalidates every ppu (and can
  crash the compiler). This is why a vendored engine is better compiled **per
  target** than from a shared cache — a cache never converged in practice, and
  FPC recompiled the engine's circular core cluster on every build regardless.
- **Vendored C/FPC dependencies: pin a fork you can patch, and checksum it.**
  The parked sandbox's fixes ended up as commits on a fork, fetched by SHA and
  checksummed, with the patch script reduced to an *assertion* that the tree
  carries them. Better than `sed` patches: the tree is exactly a revision, a
  re-fetch cannot lose the fixes, and the diff is the upstream PR.
- **The GocciaScript engine is detached from the build (parked 2026-10-18).**
  The composed-tool sandbox was parked: the engine works, but its AST/ownership
  defects cost far more than the feature returned, and the *real* goal — gating
  compound shell work — is better served by gating bash itself. Its code,
  tests, scripts and vendored fork are kept under
  `docs/features/Composed_Tool_Sandbox/`; nothing in `src/`, `tests/`,
  `examples/` or the `Makefile` references it, and `deps/goccia` is deleted.
  Read `docs/research/vendored-engine-lessons.md` before adopting another
  vendored parser or runtime: it carries the nine lessons (ownership, fail-safe,
  the heaptrc + `atos` method, prefer the boundary you already have) into the
  Tree-Sitter work. The engine's defects themselves are catalogued in
  `docs/research/gocciascript-embedder-issues.md` — 47 items, no host-project
  references, written to be handed to the engine's own maintainers.

## Code Style

- Name units `hildegard.helper.<area>` (e.g. `hildegard.helper.process`,
  `hildegard.helper.pool`).
- Start every unit with `{$mode delphi}{$H+}`.
- Keep units focused; add tests for any new public behavior.
- Comments explain *why*, not *what*.
