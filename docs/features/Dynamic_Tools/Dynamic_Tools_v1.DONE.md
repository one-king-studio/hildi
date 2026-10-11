# Implementation Plan: Dynamic Tools v1

**Related Specifications:** `Tool_Boundary_v1.SPEC.md`,
`Mcp_Lifecycle_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

Two parts: a generic **tool boundary** (a loop hook + registry removal), then the
**MCP lifecycle** manager that rides it. TDD-first; each task starts with a
failing test. `make check` before moving on.

## Implementation Tasks

### Phase 0: Setup

- [x] **Branch**: work on `main` (or a feature branch per `source-control.md`).
- [x] **Register** any new test methods in existing suites (no new unit needed;
      additions go to `test_agent.pas` and `test_mcp_client.pas`).

### Phase 1: Tool boundary (`hildegard.helper.agent`)

- [x] **Test**: `TestRegistryRemovePresentAndAbsent` in `tests/test_agent.pas` —
      red.
- [x] **Implement**: `TToolRegistry.Remove(const AName: string): Boolean`.
- [x] **Test**: `TestTurnStartHookFiresOnceBeforeRequest` (a probe hook adds a
      tool; the turn's request includes it), `TestTurnStartNilIsNoOp`.
- [x] **Implement**: `TAgentBoundaryEvent`, `TAgentLoop.OnTurnStart`, and its
      single call at the top of `DoSend`.
- [x] **Refactor**; `make check`.

### Phase 2: MCP lifecycle (`hildegard.helper.mcp.client`)

- [x] **Expose** `TMcpClient.Dead: Boolean` (the existing `FDead`).
- [x] **Test**: `TestReconcileOpensNewServer`, `TestReconcileNoOpWhenConnected`
      (no respawn).
- [x] **Implement**: `TMcpServerState`, `TMcpServerRuntime`, manager runtimes,
      `Reconcile`.
- [x] **Test**: `TestReconcileDisableUnregisters` (tools removed).
- [x] **Implement**: close + exact unregister by registered names.
- [x] **Test**: `TestReconcileReconnectsDeadServer` (a failed call ⇒ dead ⇒
      reconnect after backoff ⇒ tools back).
- [x] **Implement**: dead detection (`Client.Dead`) + bounded exponential backoff
      (configurable for tests) + re-list on reconnect.
- [x] **Test**: `TestReconcileIsolatesFailures` (one bad server does not stop a
      healthy sibling), `TestBackoffGrowsAndResets`.
- [x] **Implement**: per-server isolation and backoff bookkeeping.
- [x] **Refactor**; `make test-leak SUITE=TMcpClientTest`.

### Phase 3: Wiring & docs

- [x] **Wire** `THarnessSession`: set `FLoop.OnTurnStart` to re-read the store,
      resolve, and `Reconcile`; keep the initial `Open` at session open.
- [x] **Test**: `TestSessionPicksUpServerAddedBetweenTurns` (fake servers).
- [x] **Update SPECs** if behaviour diverged; note deviations below.

### Phase 4: Validation

- [x] `make test`, `make test-leak`, `make check` — all green.

## Dependencies & Ordering

- Phase 1 before Phase 2 (the manager uses `Remove` and the hook is the caller).
- Phase 3 after Phase 2.

## Files to Create/Modify

```
src/hildegard.helper.agent.pas          (OnTurnStart hook; TToolRegistry.Remove)
src/hildegard.helper.mcp.client.pas     (lifecycle manager; TMcpClient.Dead)
src/hildegard.helper.harness.session.pas (wire OnTurnStart -> Reconcile)
tests/test_agent.pas                    (boundary + remove tests)
tests/test_mcp_client.pas               (lifecycle tests)
```

## Success Criteria

- [x] All tasks checked; every acceptance criterion maps to a passing test.
- [x] A config change is reflected within one turn; a dropped server reconnects.
- [x] `make check` green; no leaks across reconnect cycles.
- [x] Implementation matches the two SPECs.

## Notes & Considerations

- **Detection is call-driven** (v1): the manager treats a server as dead when
  `TMcpClient.Dead` is set (a write/read failure). A server that exits while
  idle is noticed on the next failed call, then reconnected at the next boundary.
  Active liveness (`ping`) is deferred (see the FEATURE's Out of Scope).
- Backoff is configurable on the manager (defaults 1s→60s) so tests run fast.
- **Implementation notes:** `TMcpClient.Open` now resets `FDead` so a reconnect
  works; `TMcpManager` records each server's exact registered tool names so
  unregister is exact (never by prefix); `THarnessSession` always constructs the
  manager (even with zero servers) so a later-added server is reconciled.
  `make check` green (882 tests, 0 failures).

## Outcome

Implemented on `main`. The loop gained `OnTurnStart` and `TToolRegistry.Remove`
(`Tool_Boundary_v1`); `TMcpManager` is now a per-server lifecycle manager with
enable/disable/remove and bounded-backoff reconnect (`Mcp_Lifecycle_v1`); and
`THarnessSession` reconciles at each turn boundary. Trust is unchanged: every
call is still approval-gated.
