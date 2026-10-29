# Implementation Plan: Session Runtime v1

**Related Specification:** `Session_Runtime_v1.SPEC.md` (implements
`Session_Protocol_v1.SPEC.md`)
**Related Feature:** `../FEATURE.md`

## Overview

Build the wire protocol, a per-session headless runtime that owns the loop and
serves it, a client library that connects or spawns, and the store row that makes
a runtime discoverable — then prove it end to end with the CLI as the first
client. TDD-first; update tasks in real time.

**Status: implemented.** `make check` green (743 tests, leak-clean). The CLI
attaches as an observer and as a driver; the runtime survives its client and
idle-exits. See "Implementation notes" for the small deviations from the spec.

## Implementation Tasks

### Phase 1: Protocol codec (pure)

- [x] **Define** `hildi.session.protocol`: the message, event,
      command, hello, and attached types, and the codec class.
- [x] **Test**: `TestRoundTripEveryEventKind`, `TestRoundTrip*` for every
      message type, `TestRejectsBadJson`, `TestRejectsUnknownType`,
      `TestRejectsOversizeLine`, `TestRoundTripUnicodeText`.
- [x] **Implement** the NDJSON encode/decode over `fpjson`.

### Phase 2: Store migration (v2)

- [x] **Test**: `TestRuntimeMigrationIsAdditive` (v1 history survives),
      `TestRuntimeRowRoundTrip`, `TestClearRuntime`, `TestListRuntimes`.
- [x] **Implement** the `session_runtimes` table in `DefaultMigrations` and the
      `RegisterRuntime`/`LoadRuntime`/`ClearRuntime`/`ListRuntimes` methods
      (plus `MessageHighWaterMark`, needed for `store_hwm`).

### Phase 3: The runtime (server)

- [x] **Test**: `TestSocketPathFitsUnixLimit`, `TestStaleSocketRecovered`,
      `TestSecondRuntimeExits`.
- [x] **Implement** `hildi.session.runtime`: `TSessionRuntime.Open`,
      the bind-or-reuse acquisition, and `Serve`.
- [x] **Test**: `TestTurnStreamsToObserver`, `TestApprovalCrossesTheWire`,
      `TestAttachMidTurnReplaysLiveTurn`.
- [x] **Implement** turn execution on `TTurnWorker`, event emission to all
      connections, and the `TApprovalGate`-style approval bridge.
- [x] **Test**: `TestIdleExitConfigDefault`, `TestIdleExit`.
- [x] **Implement** the idle-exit timer and the detached spawn mode
      (`--session-runtime <id>`), with stdout/stderr to a log.
- [x] **Test**: `TestSlowObserverGetsGap`.

### Phase 4: The client

- [x] **Test**: `TestSpawnAndAttach`, `TestSecondDriverGetsObserve`,
      `TestClaimDriveNeedsConsent`.
- [x] **Implement** `TSessionClient`: connect-or-spawn, attach, the reader loop,
      `Send`/`SendAndWait`, role handling, and `ISessionSink` dispatch.

### Phase 5: CLI adoption (first client)

- [x] **Implement** `agent-cli --attach <session-id>` (observe) rendering the
      live turn plus ledger history.
- [x] **Implement** the driver path: `agent-cli --attach <id> --drive` connects
      or spawns as the driver and streams the turn.
- [x] **Test**: `TestAttachFlag`/`TestDriveFlag` (parsing); the end-to-end
      spawn/prompt/observe/idle-exit path is covered by the runtime suite and a
      live smoke run.

### Phase 6: Docs & validation

- [x] **Update** `docs/features/FEATURES.md`, `HANDOFF.md`, and the unit map.
- [x] **Run** `make check` (whole suite + leak gate).
- [x] **Rename** this TODO to `Session_Runtime_v1.DONE.md`.

## Implementation notes (deviations from the spec)

These were resolved during implementation; the specs were reconciled.

- **`TSessionEvent` gained fields** for payloads the spec's payload table names
  but the record lacked: `TurnSeq`, `LoopId`, `SessionId`, `ErrorCode`,
  `Reason`.
- **The runtime-row types live in `hildi.session`** (`TSessionRuntimeRow`,
  `TSessionRuntimeStatus`), not in `hildi.session.runtime`, so the
  store and the runtime can share them without a dependency cycle.
- **`TSessionClientConfig` gained `WorkspacePath` and `IdleExitMs`** so a
  spawned runtime can be told the workspace and a (short, for tests) idle exit.
- **The driver consents by releasing.** The spec's command list has no explicit
  `grant_drive`, so a held `claim_drive` marks the claimer pending and the
  driver promotes them by issuing `release_drive`; a pending claim times out
  after `DefaultDriveRequestMs`.
- **`RunSessionRuntime` / `RuntimeDir` / `SocketPathFor` / `SessionSocketReady`**
  are public helpers (the CLI and the test harness spawn a runtime by
  re-executing the binary with `--session-runtime`).
- **The socket runtime directory is `/tmp/hildi-<uid>/`** (mode
  `0700`), short enough for the `AF_UNIX` limit.
- **`HILDI_RUNTIME_IDLE_MS`** overrides the idle exit, as the spec's
  Decision 1 requires.
- **The CLI's `--attach` is opt-in.** The existing in-process prompt path is
  unchanged; routing it through the runtime is left for the TUI-adoption slice.

## Success Criteria

- [x] All tasks above checked
- [x] A session runs headless, survives its client, and is attachable
- [x] `make check` passes (tests + leak gate)

## Follow-on

- **The TUI adopts `TSessionClient`** (the next slice): `THarnessApp` becomes a
  sink and its worker/queue move into the runtime.
- The daemon (**Session Host**) and the network transport (A2A).
