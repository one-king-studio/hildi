# Implementation Plan: Runtime Shutdown v1

**Related Specification:** `Runtime_Shutdown_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

Three triggers (command, signal, no-clients grace) into the existing `FStop` →
`Shutdown` path. TDD-first.

## Implementation Tasks

### Phase 1: Protocol (`hildegard.helper.session.protocol`)

- [ ] **Add** `scShutdown` to `TSessionCommandKind` (appended last) and its wire
      name `'shutdown'` to `CommandKindNames`.
- [ ] **Test**: a round-trip of `scShutdown` through the codec.
- [ ] **Implement**: the enum + name (the codec loops over the enum, so no other
      change).

### Phase 2: Runtime (`hildegard.helper.session.runtime`)

- [ ] **Add** `ClientExitGraceMs` to `TSessionRuntimeConfig` (0 => default,
      negative => never).
- [ ] **Test**: `TestShutdownCommandStopsRuntime` (driver sends `scShutdown`;
      gets `ok`, then `ekLoopExited` with `Reason = shutdown_command`).
- [ ] **Implement**: `HandleShutdown` in `HandleCommand` (driver-only).
- [ ] **Test**: `TestShutdownFromNonDriverRefused`.
- [ ] **Test**: `TestNoClientsExit` — after the last client detaches, the runtime
      stops within the grace; `TestReattachCancelsNoClientsExit`.
- [ ] **Implement**: track the last client count; when it hits 0 and no turn is
      active, set `FIdleDeadline := NowMs + ClientExitGraceMs`; a new client
      resets it.
- [ ] **Test**: `TestNoClientsExitSuppressedDuringTurn`.
- [ ] **Implement**: guard on `FTurnActive`.
- [ ] **Test**: `TestSignalFlagStopsRuntime` — set the signal flag, the loop
      stops with `Reason = signal`.
- [ ] **Implement**: SIGTERM/SIGINT handler setting `FSignalStop`; the loop and
      `Shutdown` honour it; reason precedence.
- [ ] **Verify** `Shutdown` clears the runtime row and unlinks the socket; extend
      if missing.
- [ ] **Refactor**; `make check`.

### Phase 3: Client & docs

- [ ] **Client**: a `Shutdown` convenience on the session client (send
      `scShutdown`) if the TUI/CLI needs it; the TUI quit path detaches (already)
      and the grace handles the rest.
- [ ] **Update SPEC** if behaviour diverged.

### Phase 4: Validation

- [ ] `make test`, `make test-leak`, `make check` — green.
- [ ] **Manual**: quit a TUI → the runtime exits within the grace; `kill -TERM` a
      runtime → clean exit, no orphan docker container, runtime row cleared.

## Files to Create/Modify

```
src/hildegard.helper.session.protocol.pas (scShutdown enum + wire name)
src/hildegard.helper.session.runtime.pas  (command, signal, no-clients grace)
src/hildegard.helper.session.client.pas   (Shutdown convenience; optional)
tests/test_session_protocol.pas           (round-trip)
tests/test_session_runtime.pas            (shutdown/grace/signal tests)
```

## Outcome

Implemented on `main`. `scShutdown` (driver-only), SIGTERM/SIGINT handling, and
an exit-when-no-clients grace (default 2000 ms; negative disables) all funnel
into the existing `FStop` → `Shutdown` path. `make check` green (890 tests, 0
failures).

**The debugging cost, for future you:** all three new tests crashed with
`EBusError` at first, and the cause was **not** the feature — it was the test
freeing a `TInterfacedObject` sink directly (`Sink.Free`) while the client held
its interface reference (double-free). The existing tests use `Sink := nil`.
See the lesson in `docs/guidelines/testing.md`.

## Notes & Considerations

- **Behaviour change:** a runtime now exits ~`ClientExitGraceMs` after its last
  client detaches (default 2000 ms), instead of surviving to the 5-minute idle
  timeout. A negative `ClientExitGraceMs` restores the old behaviour.
- **Signal tests:** the handler sets a flag; unit tests set the flag directly
  rather than raising a real signal (a true SIGTERM end-to-end is a manual
  check).
- Record deviations from the SPEC here.
