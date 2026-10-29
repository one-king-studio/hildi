# Implementation Plan: Turn Injection v1

**Related Specifications:** `Turn_Assembly_v1.SPEC.md`, `Mcp_Provider_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

Add the `IToolProvider` seam to the loop, then move MCP behind it. TDD-first.
`make check` before moving on.

## Implementation Tasks

### Phase 1: The seam (`hildi.agent`)

- [x] **Expose** `MakeToolSpec` (a provider-facing spec builder that ensures the
      required `reason` param) alongside the existing augmentation.
- [x] **Test**: a stub provider's `Specs` appear in the request tool list;
      `Prepare` fires once per turn in order.
- [x] **Implement**: `IToolProvider`, `TAgentLoop.AddProvider`, `Prepare`
      dispatch at turn start.
- [x] **Test**: a non-empty `PromptFragment` appears as a request-only `crSystem`
      message and is absent from the store.
- [x] **Implement**: tool composition + request-only prompt injection in
      `BuildRequest`.
- [x] **Test**: a called provider tool dispatches to the provider; a native tool
      keeps priority; first provider wins a name clash.
- [x] **Implement**: `ResolveTool` (base registry, then providers) in
      `ExecuteToolCalls`.
- [x] **Refactor**; `make check`.

### Phase 2: MCP provider (`hildi.mcp.client`)

- [x] **Test**: `TMcpProvider.Specs` reflects connected servers; `Find`
      dispatches to the right handler; `PromptFragment` is `''`.
- [x] **Implement**: `TMcpClient.RegisteredSpecs` / `Find`; `TMcpConfigSource`;
      `TMcpProvider`.
- [x] **Decouple**: `TMcpManager.Reconcile` manages lifecycles only (no
      `TToolRegistry` argument); the provider exposes the live tools.
- [x] **Test**: `Prepare` reconciles (a config source that gains a server yields
      its tools); disable/reconnect parity.
- [x] **Refactor**; `make check`.

### Phase 3: Wiring & verification

- [x] **Wire** `THarnessSession`: build a config source from the store, register
      a `TMcpProvider` via `AddProvider` (drop `OnTurnStart := McpReconcile`).
- [x] **Test**: a server added between turns appears via the provider.
- [x] **Live check**: verify the configured Playwright server's tools load
      through the provider (a real session/request).

### Phase 4: Validation

- [x] `make test`, `make test-leak`, `make check` — green.

## Files to Create/Modify

```
src/hildi.agent.pas           (IToolProvider; compose; inject; ResolveTool)
src/hildi.mcp.client.pas      (TMcpProvider; Reconcile decoupled; client Specs/Find)
src/hildi.harness.session.pas (register the provider)
tests/test_agent.pas                     (provider seam tests)
tests/test_mcp_client.pas                (provider tests; reconcile tests via provider)
tests/test_harness_session.pas           (between-turns via provider)
```

## Notes & Considerations

- **Decoupling `Reconcile`** from `TToolRegistry` was the ripple: MCP tools no
  longer live in the base registry — the client owns its specs and the manager
  exposes them; the loop composes them per turn from the provider. Session tests
  now assert via `Session.Loop.ResolveTool`.
- **Bug found and fixed by the reconnect test:** MCP JSON-RPC ids are
  per-connection, so a fresh `Open` must reset the id generator; otherwise a
  reconnected client's responses never correlate (the fake server echoed fixed
  ids and exposed this).
- Trust unchanged: contributed tools dispatch through the same handler/approval
  path.
- **Outcome:** implemented on `main`. `make check` green (887 tests, 0 failures).
  A live check against the configured Playwright server resolved
  `mcp_playwright_browser_navigate` / `_close` / `_snapshot` through the provider
  seam (`examples/mcp_session_check.pas`).
