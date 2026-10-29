# Implementation Plan: Skills v1

**Related Specification:** `Skills_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Add `hildi.skills`: a `TSkillRegistry` that implements the existing
`IToolProvider` seam, renders a manifest as its `PromptFragment`, offers active
skills' tools plus the always-on `load_skill`, and decays idle skills at the turn
boundary. One new unit, no new seam. TDD-first; `make check` before moving on.
`main` only.

## Implementation Tasks

### Phase 1: Types and the registry skeleton (`hildi.skills`)

- [x] **Create** `src/hildi.skills.pas` (interface only):
      `TSkillState`, `ISkillToolSource`, `TSkill`, `TSkillRegistry`,
      `DefaultSkillTtlMs`, `LoadSkillToolName`.
- [x] **Add** `test_skills.pas` to the `uses` clause of
      `tests/hildi_tests.pas`.
- [x] **Test**: `Add` declares skills; `StateOf` returns `ssUnloaded` for each.
- [x] **Implement**: `TSkillRegistry.Add` / `StateOf` (declaration list).

### Phase 2: The manifest

- [x] **Test**: `Manifest` lists every declared skill with name, description,
      when-to-use, and `unloaded` state; order is declaration order.
- [x] **Implement**: `Manifest` (deterministic render).
- [x] **Test**: `PromptFragment` equals `Manifest`; a state change alters exactly
      one line (stability per state change).
- [x] **Implement**: `PromptFragment`.

### Phase 3: `load_skill`

- [x] **Test**: `Specs` with nothing loaded = `[load_skill]` only; `Find`
      resolves `load_skill`.
- [x] **Implement**: the `load_skill` spec (via `MakeToolSpec`, required
      `reason`) and its handler.
- [x] **Test**: `LoadSkill` on a known key calls `Activate`, returns the tool
      names, sets state `loaded`.
- [x] **Implement**: `LoadSkill` (activate, record `LastUsedMs`).
- [x] **Test**: `LoadSkill` on an unknown key returns a structured error and
      changes nothing.
- [x] **Test**: an `Activate` failure returns the error; the skill stays
      `unloaded` and no tools are added.
- [x] **Test**: loading twice is a no-op success (`already loaded`), timer reset.
- [x] **Implement**: the error paths.

### Phase 4: Tools and namespacing

- [x] **Test**: after loading, `Specs` = `[load_skill] + source tools`; a
      namespaced `Find` resolves to the source's handler.
- [x] **Implement**: `Specs` (active sources + `load_skill`) and `Find`
      (sources in order, then `load_skill`).
- [x] **Test**: a `Find` hit on a loaded skill's tool resets that skill's timer.
- [x] **Implement**: the use-resets-timer rule in `Find`.

### Phase 5: Decay

- [x] **Test**: an idle skill is unloaded at the next `Prepare` (advance
      `MonotonicMs` past its TTL): `Deactivate` called, tools removed, manifest
      shows `unloaded`.
- [x] **Implement**: `Prepare` decay (turn-boundary check only).
- [x] **Test**: a skill used each turn is never unloaded (timer resets keep it).
- [x] **Test**: `load_skill` is present regardless of any skill's state.

### Phase 6: Integration and cleanup

- [x] **Test**: `TToolRegistry` (base) tools remain present with/without a loaded
      skill; a namespaced name resolves to exactly one handler.
- [x] **Test**: no leak — load then unload releases the source and its tools
      (runs under the heaptrc gate).
- [x] **Implement**: any needed teardown (release sources on unload/destroy).
- [x] **Wire** the registry into `THarnessSession` as a provider (an empty
      registry by default; `Lazy_MCP` fills it).
- [x] **Update the system prompt** so the model knows skills load on demand and
      the manifest carries state.

### Phase 7: Validation & docs

- [x] **Run**: `make test SUITE=TSkillsTest` (green)
- [x] **Run**: `make test` (whole suite)
- [x] **Run**: `make test-leak` (no leaks)
- [x] **Run**: `make check` (all gates)
- [x] **Update** `FEATURES.md`; rename this TODO to `Skills_v1.DONE.md`

## Modified Files

```
src/hildi.skills.pas     (new)
tests/test_skills.pas               (new)
tests/hildi_tests.pas    (add the test unit)
src/hildi.harness.session.pas   (register the registry as a provider)
src/hildi.agent.pas      (only if the system prompt copy lives here)
docs/features/FEATURES.md
```

## Dependencies & Ordering

### Must Complete Before Starting

- Nothing — the `IToolProvider` seam already exists (Turn_Injection, implemented).
- `Lazy_MCP` is **not** required; it consumes this, not the reverse.

### Can Be Done in Parallel

- Phases 2 (manifest) and 3 (`load_skill`) once the types exist.

### Critical Path

1 (types) -> 2/3 (manifest + load) -> 4 (tools) -> 5 (decay) -> 6 (wire) -> 7.

## Success Criteria

- [x] All tasks checked
- [x] Every SPEC acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] With no skill loaded, the tool surface is base + `load_skill`, independent
      of how many skills are declared
- [x] A loaded skill decays and reloads correctly; no leak

## Notes & Considerations

- **One seam, not two.** The registry is an `IToolProvider`; do not add a new
  contributor interface.
- **Curated metadata only.** Never place a provider's server-authored text
  (e.g. MCP `initialize.instructions`) in the manifest — it is a prompt-injection
  surface. The SPEC pins this.
- **Namespacing is the source's.** The registry does not rename tools; an MCP
  source names them `mcp_<id>_<tool>` (`Lazy_MCP`).
- **Decay at the boundary only** — no per-frame timer, no timer thread.
- Record deviations from the SPEC here.

## Outcome

Implemented on `main`. `hildi.skills` provides `TSkillRegistry` (an
`IToolProvider`), `ISkillToolSource`, `TSkill`, the manifest, `load_skill`, and
idle decay; `tests/test_skills.pas` has 18 tests; the registry is wired into
`THarnessSession` as the first provider and freed by refcount. `make check`
green.

**Deviations from the SPEC, with reasons:**
- **The clock.** The SPEC said to reuse `hildi.tui.clock`
  (`MonotonicMs`); that links a TUI unit into the headless runtime and fails the
  Process Split test. The registry calls `SysUtils.GetTickCount64` directly, like
  `process.pas` and `subagent.supervisor.pas`. The SPEC is corrected.
- **Empty registry.** With no skills declared the registry contributes **nothing**
  (no `load_skill`, no fragment), so a session without capabilities is
  byte-identical to one without the registry. `load_skill` appears once at least
  one skill is declared.
- **The manifest header** carries the load/decay contract (the SPEC's
  system-prompt requirement), rather than a global prompt change, so the copy is
  present only when skills exist.
