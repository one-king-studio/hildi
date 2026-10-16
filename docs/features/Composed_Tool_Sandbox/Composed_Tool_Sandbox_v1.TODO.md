# Implementation Plan: Composed Tool Sandbox v1

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

### Phase 2: The facade (`hildegard.helper.script`)

- [ ] **Test**: a pure-compute script returns its value (`test_script`).
- [ ] **Implement**: `RunScript` — engine + interpreter per call, console
      capture, `TGocciaCapabilities.None`.
- [ ] **Test**: a syntax error yields `Ok=False` (no raise); console output is
      captured.
- [ ] **Implement**: the error mapping.
- [ ] **Test**: an injected tool call reaches `AInvoke` with name + args +
      reason; the returned text is visible to the script.
- [ ] **Implement**: the `tools` object (native methods, already-settled
      promises, the `reason` threaded).
- [ ] **Test**: the instruction cap and the timeout each stop a runaway script;
      `run_command`/`recall_tool_result` are absent.
- [ ] **Implement**: the limits; the tool filter.

### Phase 3: The tool (`hildegard.helper.tool.script`)

- [ ] **Test**: `run_script` is registered with a required `reason`; a missing
      reason fails before the engine runs (`test_tool_script`).
- [ ] **Implement**: `TScriptTool.Register` + `Run`.
- [ ] **Test**: the `script:run` gate resolves before the engine runs; a denial
      runs nothing.
- [ ] **Implement**: the `script:run` ask.
- [ ] **Test**: a script calling `tools.file_read` runs the same gated handler (a
      fake service records `file:read`).
- [ ] **Implement**: the invoker wiring to the registry.

### Phase 4: Wiring & limits

- [ ] **Wire** `TScriptTool` into the session's tool registry (like the file and
      command tools); thread the turn's cancel check as the timeout seam.
- [ ] **Test**: a script's sub-call approval relays to the operator (the gate).
- [ ] **Implement**: any glue.

### Phase 5: Validation & docs

- [ ] **Run**: `make test SUITE=TScriptTest,TToolScriptTest`
- [ ] **Run**: `make check` (all gates) — the engine linked, leak-clean
- [ ] **Run**: `make release`; confirm the binary is self-contained (`otool -L`)
- [ ] **Update** `FEATURES.md`; rename this TODO to
      `Composed_Tool_Sandbox_v1.DONE.md`.

## Files to Create/Modify

### New Files

```
scripts/patch-goccia.sh
src/hildegard.helper.script.pas
src/hildegard.helper.tool.script.pas
tests/test_script.pas
tests/test_tool_script.pas
```

### Modified Files

```
Makefile                              (libgoccia; -Fu for the engine units)
tests/hildegard_helper_tests.pas      (register the two test units)
src/hildegard.helper.harness.session.pas  (register the script tool)
docs/features/FEATURES.md
```

## Dependencies & Ordering

### Must Complete Before Starting

- The spike (done).

### Critical Path

1 (build) -> 2 (facade) -> 3 (tool) -> 4 (wiring) -> 5.

## Success Criteria

- [ ] All tasks checked
- [ ] Every SPEC acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] One turn runs N gated tool calls; a script cannot reach the shell
- [ ] `make release` is self-contained

## Notes & Considerations

- **The engine is precompiled once**, not per build — the spike found the
  compiler crashes on it under `-gl`. Our debug/leak flags stay intact for our
  own code; the engine's units come from `build/units/goccia`.
- **Path A (block in the callback).** No engine change; the script sees an
  ordinary `await`.
- **Recreate the engine per script** (realm isolation).
- Record deviations from the SPEC here.
