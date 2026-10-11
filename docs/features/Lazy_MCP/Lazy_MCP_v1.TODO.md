# Implementation Plan: Lazy MCP v1

**Related Specification:** `Lazy_MCP_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Move MCP off the runtime's startup path: `THarnessSession.Init` stops connecting,
each enabled server becomes a `TSkillRegistry` skill (`TMcpSkillSource`), and a
load connects + discovers. A re-ordering plus one new class, on top of the
`Skills` registry. TDD-first; `make check` before moving on. `main` only.

> **Prerequisite:** `Skills` v1 (the registry + `ISkillToolSource`) must be
> implemented first — this plan consumes it.

## Implementation Tasks

### Phase 1: The skill source (`hildegard.helper.mcp.client`)

- [ ] **Test**: `TMcpSkillSource.Activate` calls the manager to open the server
      (a spy manager records `OpenRuntime`) and returns the tool names; a failure
      returns the error and leaves nothing registered.
- [ ] **Implement**: `TMcpSkillSource` (`Activate`/`Deactivate`/`Specs`/`Find`)
      over `TMcpManager` + one `TMcpServerRuntime`.
- [ ] **Test**: `Deactivate` closes the server (`CloseRuntime`) and `Specs`
      becomes empty; it is idempotent.
- [ ] **Implement**: `Deactivate`.
- [ ] **Test**: `Find` resolves `mcp_<server>_<tool>` to the client's handler.
- [ ] **Implement**: `Find` (delegates to the client).
- [ ] **Test**: `Declaration` returns key `mcp_<server>` and **curated**
      description/when-to-use; a server-authored `instructions` string never
      appears.
- [ ] **Implement**: `Declaration`.

### Phase 2: Build skills from config

- [ ] **Test**: `RegisterMcpSkills` adds one source per **enabled** server, key
      `mcp_<server>`; a disabled server adds none.
- [ ] **Implement**: `RegisterMcpSkills` (reads `TMcpConfig`, `McpSanitize`).
- [ ] **Test**: re-calling it after an add/enable/remove reflects the change (the
      registry's declaration set is updated) without connecting.
- [ ] **Implement**: the re-declare path (reconcile-safe).

### Phase 3: Take MCP off the startup path

- [ ] **Test**: `THarnessSession.Init` does **not** call `FMcp.Open` (a spy
      manager records no open before the session is returned).
- [ ] **Implement**: drop `FMcp.Open`; construct the manager only; register the
      MCP skills with the registry instead of adding `TMcpProvider`.
- [ ] **Test**: the runtime's socket binds and greets with MCP configured and no
      server connected (a connect-first assertion).
- [ ] **Test**: the manifest lists the configured servers `unloaded` on first
      turn; `Specs` carries no `mcp_` tools.

### Phase 4: Load, use, decay

- [ ] **Test**: `load_skill("mcp_<server>")` connects, registers the tools, and
      the next request carries them.
- [ ] **Implement**: the wiring from the registry's load to the source.
- [ ] **Test**: a tool call on the loaded server reaches the fake server and its
      result returns (the existing `CallTool` path).
- [ ] **Test**: after the TTL the skill unloads (the client closes) and the
      manifest shows `unloaded`.
- [ ] **Test**: a slow/unreachable server returns a structured load error; the
      socket and turn are unaffected.

### Phase 5: Operator preload

- [ ] **Test**: a preload request activates the named server before the first
      turn (the connect is explicit and opt-in).
- [ ] **Implement**: `--mcp <key>` (CLI/runtime flag) -> preload after `Init`,
      before the first turn.

### Phase 6: Validation & docs

- [ ] **Run**: `make test SUITE=TMcpClientTest,THarnessSessionTest,TSkillsTest`
      (green)
- [ ] **Run**: `make test` (whole suite)
- [ ] **Run**: `make test-leak` (no leaks)
- [ ] **Run**: `make check` (all gates)
- [ ] **Run**: a live check against the configured Playwright server:
      `mcp_playwright_*` resolves through the loaded skill (manual)
- [ ] **Update** `FEATURES.md`; rename this TODO to `Lazy_MCP_v1.DONE.md`

## Modified Files

```
src/hildegard.helper.mcp.client.pas       (TMcpSkillSource, RegisterMcpSkills)
src/hildegard.helper.harness.session.pas  (drop FMcp.Open; register MCP skills)
src/hildegard.helper.session.runtime.pas  (only if the preload flag lands here)
tests/test_mcp_client.pas                 (source tests)
tests/test_harness_session.pas            (startup / manifest / load tests)
docs/features/FEATURES.md
```

## Dependencies & Ordering

### Must Complete Before Starting

- **`Skills` v1** — the registry and `ISkillToolSource`. This plan cannot start
  without it.

### Can Be Done in Parallel

- Phase 1 (the source) once `Skills` types exist; Phase 5 (preload) last.

### Critical Path

Skills -> 1 (source) -> 2 (from config) -> 3 (off startup) -> 4 (load/decay) ->
5 (preload) -> 6.

## Success Criteria

- [ ] All tasks checked
- [ ] Every SPEC acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] The socket binds with no MCP connect; a slow server cannot fail the launch
- [ ] A server's tools appear only while its skill is loaded
- [ ] No idle connections linger after the TTL

## Notes & Considerations

- **Re-ordering, not a rewrite.** `TMcpManager`/`TMcpClient`/transports/OAuth/
  approvals are unchanged; only *when* `Open` happens moves.
- **The namespace is settled by the code** (`mcp_<server>_<tool>` for the tool
  name; `mcp:<server>:<tool>` for the approval ref, colon-separated like every
  other family) — do not invent a new scheme, and do not merge the two.
- **Curated metadata only**; never a server's `initialize.instructions`.
- **The socket-is-the-lease model holds**: readiness means "the protocol is up",
  not "optional subsystems finished".
- Record deviations from the SPEC here.
