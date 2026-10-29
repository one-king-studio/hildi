# Implementation Plan: TUI Adoption v1

**Related Specification:** `TUI_Adoption_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Introduce a driver seam, add the remote driver over `TSessionClient`, point
`THarnessApp` at the driver, make the loop optional in `THarnessSession`, and
wire `tui-agent` to a runtime. TDD-first; the app's existing tests keep running
on the local driver.

**Status: implemented.** `make check` green (751 tests, leak-clean). `make
tui-agent` now spawns a detached runtime and drives it; a CLI `--attach` sees
the same session.

## Implementation Tasks

### Phase 1: The driver seam

- [x] Add `AskRef` to `TTurnEvent`; the local driver sets it from `RequestId`.
- [x] **Define** `hildi.harness.driver`: `ISessionDriver`,
      `TLocalDriver`, `TRemoteDriver`, and the `LocalDriver`/`RemoteDriver`
      factories.
- [x] **Test**: `TestLocalDriverEmitsUserMessageThenDone`,
      `TestLocalDriverNormalisesQueuedPrompt`,
      `TestLocalDriverApprovalAskCarriesRefAndResolvesGate`.
- [x] **Implement** `TLocalDriver` over `TTurnWorker`/`TTurnQueue`/`TApprovalGate`.

### Phase 2: The remote driver

- [x] **Test**: `TestRemoteDriverRendersATurn`,
      `TestRemoteDriverApprovalRoundTrip`, `TestRemoteDriverInterrupt`,
      `TestRemoteDriverReconnectsAfterRuntimeExit`.
- [x] **Implement** the `ISessionSink` → `TTurnEvent` mapping and the command
      direction; reconnect-on-demand.

### Phase 3: The app uses the driver

- [x] Change `THarnessApp` to take an `ISessionDriver`; drop `TTurnWorker`.
- [x] Handle `teUserMessage`; route approvals by `AskRef`.
- [x] **Test**: `TestAppRemoteTurnRenders` (over a real runtime); the existing
      22 app tests move to the local driver and stay green.

### Phase 4: Bootstrap & example

- [x] Add `THarnessSessionConfig.NoLoop`; skip the loop when True.
- [x] Wire `examples/tui_agent.pas` to a `TRemoteDriver`; drop `--no-store`;
      handle `--session-runtime` (the spawn re-exec).
- [x] **Smoke**: the TUI spawns a detached runtime (a separate process with the
      session socket) and renders.

### Phase 5: Docs & validation

- [x] Update `FEATURES.md`, `HANDOFF.md`, and the unit map.
- [x] **Run** `make check`.
- [x] **Rename** this TODO to `TUI_Adoption_v1.DONE.md`.

## Implementation notes (deviations from the spec)

- **The protocol `error` event gained `dropped`** (and `TSessionEvent` gained
  `Dropped: Boolean`): the TUI needs it to match the live view to a resumed one
  after an early cancel. Reused by the driver.
- **The error-code wire vocabulary moved to the protocol unit**
  (`SessionErrorCodeToWire`/`FromWire`), so the runtime and the driver share one
  spelling.
- **`THarnessSession.NoLoop`** is the flag (default False), rather than
  `BuildLoop` (default True): a record's `Default` zeroes booleans, so an
  inverted flag keeps every existing caller's behaviour.
- **`--no-store` was removed from the TUI**: the runtime is store-backed.

## Success Criteria

- [x] All tasks above checked
- [x] `make tui-agent` runs on a runtime; a CLI observer sees the same session
- [x] `make check` passes (tests + leak gate)

## Follow-on

- Observe mode in the UI (watch a session a CLI is driving).
- Subagent sessions in the UI.
