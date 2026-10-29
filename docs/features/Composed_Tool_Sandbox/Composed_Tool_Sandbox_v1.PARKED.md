# Implementation Plan: Composed Tool Sandbox v1

> **Status: parked, and detached from the build (2026-10-17 / 2026-10-18).** The
> tasks below were all completed and the suite was green; the feature was then
> parked and its code moved here. **Nothing in this file is built, tested, or
> gated any more** — it is the record of what v1 was, not a plan to execute. Do
> not resume it from this file: read `REWRITE_PROPOSAL.md` (re-entry conditions
> and the admission battery) and `docs/research/gocciascript-embedder-issues.md`
> (the engine defects, as a standalone register).

**Related Specification:** `Composed_Tool_Sandbox_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Embed GocciaScript core-only, inject the harness's tools as one async `tools`
object, and add a `run_script` tool so N tool calls are one turn — every
sub-call gated exactly as a direct call. TDD-first; `make check` before moving
on. `main` only.

> **Prerequisite (done):** the spike (in `FEATURE.md`) — the engine builds,
> embeds, and runs; the operator accepted the ~8 MB delta. Two vendored-tree
> fixes were found (a `constref`→`const` mismatch; a compiler crash under `-gl`).

## Implementation Tasks

### Phase 1: Vendored build integration

- [x] **Create** `scripts/patch-goccia.sh`: apply the `constref`→`const` fix (7
      sites) to `deps/goccia`, idempotent.
- [x] **Add** a `libgoccia` Makefile target: fetch + patch + compile the engine's
      units once with its production flags into `build/units/goccia`, with
      `GOCCIA_INTL_NO_EMBEDDED_CLDR` set.
- [x] **Verify**: a throwaway program links the precompiled units and runs a
      script, under the debug flags (no compiler crash).

### Phase 2: The facade (`hildi.script`)

- [x] **Test**: a pure-compute script returns its value (`test_script`).
- [x] **Implement**: `RunScript` — engine + interpreter per call, console
      capture, `TGocciaCapabilities.None`.
- [x] **Test**: a syntax error yields `Ok=False` (no raise); console output is
      captured.
- [x] **Implement**: the error mapping.
- [x] **Test**: an injected tool call reaches `AInvoke` with name + args +
      reason; the returned text is visible to the script.
- [x] **Implement**: the `tools` object (native methods, already-settled
      promises, the `reason` threaded).
- [x] **Test**: the instruction cap and the timeout each stop a runaway script;
      `run_command`/`recall_tool_result` are absent.
- [x] **Implement**: the limits; the tool filter.

### Phase 3: The tool (`hildi.tool.script`)

- [x] **Test**: `run_script` is registered with a required `reason`; a missing
      reason fails before the engine runs (`test_tool_script`).
- [x] **Implement**: `TScriptTool.Register` + `Run`.
- [x] **Test**: the `script:run` gate resolves before the engine runs; a denial
      runs nothing.
- [x] **Implement**: the `script:run` ask.
- [x] **Test**: a script calling `tools.file_read` runs the same gated handler (a
      fake service records `file:read`).
- [x] **Implement**: the invoker wiring to the registry.

### Phase 4: Wiring & limits

- [x] **Wire** `TScriptTool` into the session's tool registry (like the file and
      command tools); thread the turn's cancel check as the timeout seam.
- [x] **Test**: a script's sub-call approval relays to the operator (the gate).
- [x] **Implement**: any glue.

### Phase 5: Validation & docs

- [x] **Run**: `make test SUITE=TScriptTest,TToolScriptTest`
- [x] **Run**: `make check` (all gates) — the engine linked, leak-clean
- [x] **Run**: `make headless-agent`; confirm the runtime is self-contained
      (`otool -L`) and the TUI stays engine-free (`nm`)
- [x] **Update** `FEATURES.md`; rename this TODO to
      `Composed_Tool_Sandbox_v1.DONE.md`.

## Files to Create/Modify

### New Files

```
scripts/patch-goccia.sh
src/hildi.script.pas
src/hildi.tool.script.pas
tests/test_script.pas
tests/test_tool_script.pas
```

### Modified Files

```
Makefile                              (libgoccia; -Fu for the engine units)
tests/hildi_tests.pas      (register the two test units)
src/hildi.harness.session.pas  (register the script tool)
docs/features/FEATURES.md
```

## Dependencies & Ordering

### Must Complete Before Starting

- The spike (done).

### Critical Path

1 (build) -> 2 (facade) -> 3 (tool) -> 4 (wiring) -> 5.

## Success Criteria

- [x] All tasks checked
- [x] Every SPEC acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] One turn runs N gated tool calls; a script cannot reach the shell
- [x] The runtime binary is self-contained; the TUI stays engine-free

## Notes & Considerations

- **The engine compiles per target**, not from a cache. The cache was tried and
  abandoned: it never converged (FPC recompiled the engine's circular core
  cluster on every build regardless) and a consumer whose flags differed
  crashed the compiler. The engine now builds into each target's own unit dir,
  like any vendored source. Its own warnings are silenced by a vendored patch
  so it compiles under our `-Sew`.
- **Path A (block in the callback).** No engine change; the script sees an
  ordinary `await`.
- **Recreate the engine per script** (realm isolation).
- Record deviations from the SPEC here.

## Deviations from the SPEC

- **`console` is injected, not the engine's.** The SPEC's "Console capture" row
  says "reuse the engine's `OutputCallback`", but core-only has no `console` at
  all (it is a runtime extension). The facade injects an inert capture-only
  `console` object (log/info/warn/error/debug → the output buffer); no host
  access. When a real console extension is added, the capture moves there.
- **`RunScript` takes the exposed tool names** (`AExposedTools`), not just the
  invoker. The SPEC signature carries only `AInvoke`, but the facade cannot
  enumerate the registry itself; the caller (the Phase 3 tool) filters `Specs`
  through `FilterScriptTools`. `ScriptExcludedTools` names the exclusions.
- **The engine's compatibility set is enabled.** GocciaScript is strict-subset
  by default — no `for`/`while`/`function`/`var` — which defeats the feature.
  The facade sets `Engine.Compatibility` to the standard-JS surface. Top-level
  await and TS-style type annotations need no flag. Deliberately off:
  `cfNonStrictMode`, `cfExperimentalJSModuleSource`.
- **The leak gate is bounded at a documented floor.** The engine pins
  process-global singletons at construction and never unpins them (a fixed
  ~2.5k-block floor; its own heaptrc CI is Linux-only). The facade releases each
  run's realm graph with a post-run `GC.Collect`, so the count does not grow per
  script; the gate parses the unfreed count and fails above the floor.
- **Two new vendored patches** (`patch-goccia.sh`): `{$WARNINGS OFF}` in the
  engine's shared include, and `JSONParser` → `Goccia.JSONParser` (an FCL
  collision that broke every harness `fpjson` call once the engine linked).
