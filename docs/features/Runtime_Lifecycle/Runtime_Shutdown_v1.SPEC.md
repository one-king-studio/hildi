# Component Specification: Runtime Shutdown v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.session.runtime`,
`hildegard.helper.session.protocol`, `hildegard.helper.session.client`.
**Depended on by:** the TUI/CLI clients (they may issue `scShutdown` / rely on
the no-clients exit).

## Purpose

Give the session runtime three ways to stop **promptly and gracefully**: an
in-band `scShutdown` command, SIGTERM/SIGINT handling, and an exit-when-no-
clients policy with a short grace. All three funnel into the existing `FStop`
flag and `Shutdown` path, so there is one teardown.

## Requirements

### Functional

- [ ] `scShutdown` (new `TSessionCommandKind`, driver-only): reply `ok`, then set
      `FStop`; the serve loop breaks and runs `Shutdown`.
- [ ] SIGTERM and SIGINT are installed with a handler that sets a
      `FSignalStop: Boolean` (async-signal-safe); the serve loop treats it like
      `FStop`.
- [ ] Exit-when-no-clients: when `FClients.Count` reaches 0 and no turn is
      active, set `FIdleDeadline := NowMs + ClientExitGraceMs` (default
      `DefaultClientExitGraceMs`). A new attach/accept resets the grace. A
      negative `ClientExitGraceMs` disables the policy (today's behaviour).
- [ ] The grace never fires while `FTurnActive`.
- [ ] `Shutdown` already frees the session (MCP children) and clears the runtime
      row; the SPEC requires it also closes clients and unlinks the socket
      (verify; extend if missing).
- [ ] The exit reason is recorded in the `ekLoopExited` event's `Reason`
      (`shutdown_command`, `signal`, `no_clients`, `idle`).

### Non-Functional

- [ ] No busy poll: the select timeout keeps its finite-timeout shape.
- [ ] The signal handler only sets a flag (no allocation, no syscalls beyond the
      handler's own bookkeeping).
- [ ] `make check` green; leak-clean across a shutdown with MCP children.

## Contracts & Interfaces

```pascal
unit hildegard.helper.session.protocol;   // addition

type
  TSessionCommandKind = (
    scAttach, scDetach, scPrompt, scApprove, scInterrupt,
    scClaimDrive, scReleaseDrive, scPing,
    { Ask the runtime to stop gracefully. Driver-only. Appended last so stored
      ordinals are unchanged. }
    scShutdown);

unit hildegard.helper.session.runtime;   // addition

type
  TSessionRuntimeConfig = record
    // ... existing ...
    { Exit this long after the last client disconnects (ms). 0 => the default;
      negative => never (a runtime outlives its clients). }
    ClientExitGraceMs: Integer;
  end;

const
  { Short grace so a crashed client does not strand a runtime, but a reattach
    can still cancel the exit. }
  DefaultClientExitGraceMs = 2000;
```

### Data Contracts

- **`scShutdown` semantics.** Driver-only (the current driver); a non-driver
  request is refused with an error reply. On success: reply `ok`, then stop.
- **Grace reset.** Any `AcceptClient` or successful attach sets
  `FIdleDeadline := NowMs + FClientExitGraceMs` (or clears the deadline when the
  policy is disabled), cancelling a pending no-clients exit.
- **Reason precedence.** A stop caused by `scShutdown` reports
  `shutdown_command`; by a signal, `signal`; by the no-clients grace,
  `no_clients`; by the idle timeout, `idle`.

### Event Contracts

- `ekLoopExited` carries `Reason`; clients that are still attached receive it
  before the socket closes.

## Architecture

### Prior Art & Reuse

- **`FStop`** and the serve-loop `Shutdown` already exist; every new trigger sets
  or feeds them.
- **`FIdleDeadline` / `FIdleExitMs`** already drive the idle exit; the no-clients
  policy is a second, shorter deadline reusing the same field.
- **`ReapClosing` / driver promotion** already handle client removal; the
  no-clients policy observes `FClients.Count`.
- **Genuine gap:** the command, the signal handler, and the shorter grace.

### Component Boundaries

- **Responsibilities:** accept the three triggers; run one graceful teardown.
- **Dependencies:** `BaseUnix` (signals), the protocol codec.
- **Side effects:** process exit; child teardown; socket unlink; store row clear.

### Data Flow

1. Trigger (`scShutdown` line / signal flag / client count → 0).
2. Serve loop breaks on `FStop or FSignalStop`, or on the no-clients deadline.
3. `Shutdown`: close clients, `FSession.Free` (closes MCP children), unlink
   socket, clear runtime row, emit `ekLoopExited`.

## Validation Rules

### Input

- `scShutdown` from a non-driver: error reply, no stop.
- Unknown command kind from an older client: error reply (existing behaviour).

### Output Guarantees

- After `Shutdown`, no client connection, no socket file, no runtime row, no
  orphaned MCP child.

## Error Handling

- A failure to clear the runtime row is logged, not fatal (the socket unlink and
  process exit still proceed).
- A signal during `Shutdown` is ignored (teardown is idempotent; a second
  SIGTERM after the flag is set is a no-op).

## Testing Requirements

### Unit Tests (`tests/test_session_runtime.pas` additions)

- [ ] `scShutdown` from the driver stops the runtime; the client gets `ok` and
      then `ekLoopExited` with `Reason = shutdown_command`.
- [ ] `scShutdown` from a non-driver is refused.
- [ ] No-clients exit: after the last client detaches, the runtime stops within
      the grace; a reattach within the grace cancels it.
- [ ] The no-clients exit does not fire while a turn is active.
- [ ] A negative `ClientExitGraceMs` disables the policy.
- [ ] A simulated signal flag stops the runtime with `Reason = signal`.
- [ ] `Shutdown` clears the runtime row and unlinks the socket.

### Integration Tests

- [ ] The TUI/CLI quit path issues a detach and (optionally) `scShutdown`; the
      runtime exits and a relaunch spawns a fresh runtime.

## Performance Targets

- Stop latency ≤ `ClientExitGraceMs` after the last disconnect; signal stop
  within one loop iteration.

## Security Considerations

- `scShutdown` is driver-only and stops the operator's own runtime; it is not a
  remote surface (AF_UNIX, owner-only, per the transport's access control).
- The signal handler allocates nothing.

## Success Criteria

- [ ] All contracts implemented; `make check` green; no leaks.
- [ ] Quitting the client, or `kill -TERM`, stops the runtime within the grace,
      with children reaped.

## Future Considerations

- `exec`-based self-restart (a runtime relaunches itself on the new binary).
- A `restart` command that execs in place.
- A daemon mode that intentionally outlives clients (negative grace).
