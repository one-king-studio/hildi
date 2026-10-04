# Implementation Plan: Session Runtime v1

**Related Specification:** `Session_Runtime_v1.SPEC.md` (implements
`Session_Protocol_v1.SPEC.md`)
**Related Feature:** `../FEATURE.md`

## Overview

Build the wire protocol, a per-session headless runtime that owns the loop and
serves it, a client library that connects or spawns, and the store row that makes
a runtime discoverable — then prove it end to end with the CLI as the first
client. TDD-first; update tasks in real time.

## Implementation Tasks

### Phase 1: Protocol codec (pure)

- [ ] **Define** `hildegard.helper.session.protocol`: the message, event,
      command, hello, and attached types, and the codec class.
- [ ] **Test**: `TestCodecRoundTrip` for every message type and event kind,
      `TestCodecRejectsBadJson`, `TestCodecRejectsUnknownType`,
      `TestCodecRejectsOversizeLine`.
- [ ] **Implement** the NDJSON encode/decode over `fpjson`.

### Phase 2: Store migration (v2)

- [ ] **Test**: `TestRuntimeMigrationIsAdditive` (v1 history survives),
      `TestRuntimeRowRoundTrip`, `TestClearRuntime`.
- [ ] **Implement** the `session_runtimes` table in `DefaultMigrations` and the
      `RegisterRuntime`/`LoadRuntime`/`ClearRuntime`/`ListRuntimes` methods.

### Phase 3: The runtime (server)

- [ ] **Test**: `TestSocketPathFitsUnixLimit`, `TestStaleSocketRecovered`,
      `TestSecondRuntimeExits`.
- [ ] **Implement** `hildegard.helper.session.runtime`: `TSessionRuntime.Open`,
      the bind-or-reuse acquisition, and `Serve`.
- [ ] **Test**: `TestTurnStreamsToObserver`, `TestApprovalCrossesTheWire`.
- [ ] **Implement** turn execution on `TTurnWorker`, event emission to all
      connections, and the `TApprovalGate`-style approval bridge.
- [ ] **Test**: `TestIdleExitConfigDefault`, `TestIdleExit` (fake clock).
- [ ] **Implement** the idle-exit timer and the detached spawn mode
      (`--session-runtime <id>`), with stdout/stderr to a log.

### Phase 4: The client

- [ ] **Test**: `TestSpawnAndAttach`, `TestClientSurvivesRuntimeExitAndRespawns`,
      `TestSecondDriverGetsObserve`, `TestClaimDriveNeedsConsent`,
      `TestSlowObserverGetsGap`.
- [ ] **Implement** `TSessionClient`: connect-or-spawn, attach, the reader loop,
      `Send`/`SendAndWait`, role handling, and `ISessionSink` dispatch.

### Phase 5: CLI adoption (first client)

- [ ] **Implement** `agent-cli --attach <session-id>` (observe) rendering the
      live turn plus ledger history.
- [ ] **Implement** the `prompt` path: the CLI connects-or-spawns as the driver
      and streams the turn.
- [ ] **Test**: a scripted end-to-end run (spawn, prompt, observe, idle-exit).

### Phase 6: Docs & validation

- [ ] **Update** `docs/features/FEATURES.md`, `HANDOFF.md`, and the unit map.
- [ ] **Run** `make check` (whole suite + leak gate).
- [ ] **Rename** this TODO to `Session_Runtime_v1.DONE.md`.

## Dependencies & Ordering

- The codec (Phase 1) before the runtime and client.
- The store migration (Phase 2) before the runtime registers.
- The runtime (Phase 3) before the client can attach.
- The CLI (Phase 5) last.

## Files to Create/Modify

### New Files

```
src/hildegard.helper.session.protocol.pas   the wire types + codec
src/hildegard.helper.session.runtime.pas    the runtime + client
tests/test_session_protocol.pas             codec unit tests
tests/test_session_runtime.pas              runtime/client integration tests
```

### Modified Files

```
src/hildegard.helper.store.pas              migration v2 + runtime-row methods
examples/agent_cli.pas                      --attach / prompt as a client
tests/hildegard_helper_tests.pas            add the new test units
Makefile                                    link any new C (none expected)
HANDOFF.md                                  current state + lessons
docs/features/FEATURES.md                   status
```

## Success Criteria

- [ ] All tasks above checked
- [ ] A session runs headless, survives its client, and is attachable
- [ ] `make check` passes (tests + leak gate)

## Notes & Considerations

- **The socket is the lease.** `bind` is the acquisition and a successful
  `connect` is the liveness proof; there is no heartbeat and no pid/start-time
  guard.
- **The wire carries the live turn only.** Prior turns come from the ledger; the
  `attached` reply's `store_hwm` is how the client reconciles the two.
- **One writer per session.** The runtime is the sole writer of its session's
  ledger; a client only reads it. This keeps multi-process SQLite contention
  mild.
- **Detachment matters.** The runtime is spawned in its own session/process
  group, or a client crash takes the loop with it.
- **Short socket paths.** AF_UNIX paths are capped (~104 bytes on macOS); use a
  short runtime directory, never `$HOME`.
- **The TUI is the next slice.** v1 proves the mechanism with the CLI; the TUI's
  adoption (it becomes an `ISessionSink`) is a follow-on spec.
