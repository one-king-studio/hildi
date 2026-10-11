# Implementation Plan: Skills v1

**Related Specification:** `Skills_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Add `hildegard.helper.skills`: a `TSkillRegistry` that implements the existing
`IToolProvider` seam, renders a manifest as its `PromptFragment`, offers active
skills' tools plus the always-on `load_skill`, and decays idle skills at the turn
boundary. One new unit, no new seam. TDD-first; `make check` before moving on.
`main` only.

## Implementation Tasks

### Phase 1: Types and the registry skeleton (`hildegard.helper.skills`)

- [ ] **Create** `src/hildegard.helper.skills.pas` (interface only):
      `TSkillState`, `ISkillToolSource`, `TSkill`, `TSkillRegistry`,
      `DefaultSkillTtlMs`, `LoadSkillToolName`.
- [ ] **Add** `test_skills.pas` to the `uses` clause of
      `tests/hildegard_helper_tests.pas`.
- [ ] **Test**: `Add` declares skills; `StateOf` returns `ssUnloaded` for each.
- [ ] **Implement**: `TSkillRegistry.Add` / `StateOf` (declaration list).

### Phase 2: The manifest

- [ ] **Test**: `Manifest` lists every declared skill with name, description,
      when-to-use, and `unloaded` state; order is declaration order.
- [ ] **Implement**: `Manifest` (deterministic render).
- [ ] **Test**: `PromptFragment` equals `Manifest`; a state change alters exactly
      one line (stability per state change).
- [ ] **Implement**: `PromptFragment`.

### Phase 3: `load_skill`

- [ ] **Test**: `Specs` with nothing loaded = `[load_skill]` only; `Find`
      resolves `load_skill`.
- [ ] **Implement**: the `load_skill` spec (via `MakeToolSpec`, required
      `reason`) and its handler.
- [ ] **Test**: `LoadSkill` on a known key calls `Activate`, returns the tool
      names, sets state `loaded`.
- [ ] **Implement**: `LoadSkill` (activate, record `LastUsedMs`).
- [ ] **Test**: `LoadSkill` on an unknown key returns a structured error and
      changes nothing.
- [ ] **Test**: an `Activate` failure returns the error; the skill stays
      `unloaded` and no tools are added.
- [ ] **Test**: loading twice is a no-op success (`already loaded`), timer reset.
- [ ] **Implement**: the error paths.

### Phase 4: Tools and namespacing

- [ ] **Test**: after loading, `Specs` = `[load_skill] + source tools`; a
      namespaced `Find` resolves to the source's handler.
- [ ] **Implement**: `Specs` (active sources + `load_skill`) and `Find`
      (sources in order, then `load_skill`).
- [ ] **Test**: a `Find` hit on a loaded skill's tool resets that skill's timer.
- [ ] **Implement**: the use-resets-timer rule in `Find`.

### Phase 5: Decay

- [ ] **Test**: an idle skill is unloaded at the next `Prepare` (advance
      `MonotonicMs` past its TTL): `Deactivate` called, tools removed, manifest
      shows `unloaded`.
- [ ] **Implement**: `Prepare` decay (turn-boundary check only).
- [ ] **Test**: a skill used each turn is never unloaded (timer resets keep it).
- [ ] **Test**: `load_skill` is present regardless of any skill's state.

### Phase 6: Integration and cleanup

- [ ] **Test**: `TToolRegistry` (base) tools remain present with/without a loaded
      skill; a namespaced name resolves to exactly one handler.
- [ ] **Test**: no leak — load then unload releases the source and its tools
      (runs under the heaptrc gate).
- [ ] **Implement**: any needed teardown (release sources on unload/destroy).
- [ ] **Wire** the registry into `THarnessSession` as a provider (an empty
      registry by default; `Lazy_MCP` fills it).
- [ ] **Update the system prompt** so the model knows skills load on demand and
      the manifest carries state.

### Phase 7: Validation & docs

- [ ] **Run**: `make test SUITE=TSkillsTest` (green)
- [ ] **Run**: `make test` (whole suite)
- [ ] **Run**: `make test-leak` (no leaks)
- [ ] **Run**: `make check` (all gates)
- [ ] **Update** `FEATURES.md`; rename this TODO to `Skills_v1.DONE.md`

## Modified Files

```
src/hildegard.helper.skills.pas     (new)
tests/test_skills.pas               (new)
tests/hildegard_helper_tests.pas    (add the test unit)
src/hildegard.helper.harness.session.pas   (register the registry as a provider)
src/hildegard.helper.agent.pas      (only if the system prompt copy lives here)
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

- [ ] All tasks checked
- [ ] Every SPEC acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] With no skill loaded, the tool surface is base + `load_skill`, independent
      of how many skills are declared
- [ ] A loaded skill decays and reloads correctly; no leak

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
