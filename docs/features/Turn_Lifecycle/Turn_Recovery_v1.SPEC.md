# Component Specification: Turn Recovery v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildi.store` (turn methods),
`hildi.session.runtime`, `hildi.harness.turn`
(`TApprovalGate`), `hildi.harness.session`.

## Purpose

Guarantee a turn always reaches a terminal state. Five small mechanisms:
finalize orphaned running turns on runtime start; self-heal in `BeginTurn`;
finalize on client loss; finalize on shutdown; bound the approval wait. Plus a
resume repair for a dangling tool call.

## Requirements

### Functional

- [ ] **Store: `FinalizeRunningTurns`** — finalize every `tsRunning` turn for a
      session to `tsCancelled` with a reason, rolling up counts (reuse the
      `FinishTurn` SQL), returning how many were finalized. Idempotent.
- [ ] **Runtime startup** — after acquiring the session (socket bound), call
      `FinalizeRunningTurns(session, 'recovered_on_start')` before serving.
- [ ] **`BeginTurn` self-heal** — before inserting, finalize any existing
      `tsRunning` turn for the session (`tsCancelled`, `superseded`).
- [ ] **Client loss** — when the last driver disconnects mid-turn, request the
      worker's cancel; the worker's terminal event finalizes the turn
      (`tsCancelled`, `client_disconnected`).
- [ ] **Shutdown** — `Stop`/idle-exit/SIGTERM/`scShutdown` cancels the worker and
      waits; the turn is finalized (`tsCancelled`, `shutdown`) before exit.
- [ ] **Bounded gate** — the approval gate is created with a finite timeout; on
      expiry the ask is denied (existing `wrTimeout` path) and the loop
      proceeds.
- [ ] **Resume repair** — when history is loaded and the last message is a
      `mrToolCall` with no following `mrTool` result for the same id, append a
      synthetic `mrTool` result ("tool not executed: session interrupted") so
      the replay is well-formed.

### Non-Functional

- [ ] Idempotent recovery; no already-terminal turn is modified.
- [ ] `make check` green; leak-clean.

## Contracts & Interfaces

```pascal
unit hildi.store;   // addition

type
  TSqliteStore = class
    // ... existing ...
    { Finalize every running turn for a session (tsCancelled, AReason), rolling
      up counts. Returns the number finalized. Idempotent. }
    function FinalizeRunningTurns(const ASessionId, AReason: string;
      out ACount: Integer; out AError: TStoreError): Boolean;
  end;

unit hildi.harness.turn;   // existing (used, not changed)

const
  { The default approval wait; past it the ask is denied and the loop proceeds.
    0 keeps "wait forever" only if a caller explicitly passes it. }
  DefaultApprovalTimeoutMs = 300000;
```

### Data Contracts

- **`FinalizeRunningTurns` SQL** (one statement, reuse the rollup):
  ```sql
  UPDATE turns SET status = <tsCancelled>, finish_reason = ?,
    finished_at = ?, duration_ms = ? - created_at,
    request_count = (…), message_count = (…), <token sums>
  WHERE session_id = ? AND status = <tsRunning>
  ```
  `ACount` is `sqlite3_changes`.
- **Reason vocabulary:** `recovered_on_start`, `superseded`,
  `client_disconnected`, `shutdown`.
- **Startup ordering:** acquire the socket **first** (a live socket means
  another runtime owns the session — do not recover), then reconcile. A second
  runtime that cannot bind exits without touching turns.
- **Resume repair scope:** only the **last** message is inspected; a dangling
  `mrToolCall` is answered, never a mid-history one (those are legitimate).

### Event Contracts

- The startup reconcile emits a session event (`recovered N interrupted
  turn(s)`) so the operator sees it.

## Architecture

### Prior Art & Reuse

- **`FinishTurn`** already performs the rollup; `FinalizeRunningTurns` is the
  same UPDATE with a `WHERE status = tsRunning` and no single-id.
- **`TApprovalGate`** already supports a timeout (`FTimeoutMs`, the `wrTimeout`
  → deny path); the change is passing a finite value.
- **`TTurnWorker.RequestCancel`** already exists; the change is calling it on
  client loss and shutdown.
- **Genuine gap:** the reconcile call, the `BeginTurn` guard, the resume repair,
  and wiring the existing timeout/cancel.

### Component Boundaries

- **Responsibilities:** recovery, self-heal, cancellation wiring, bounded gate,
  resume repair.
- **Dependencies:** the store, the runtime, the gate.
- **Side effects:** turn rows finalized; a synthetic message appended on repair.

## Validation Rules

- Recovery touches only `tsRunning` rows for the named session.
- A live socket blocks recovery (another runtime owns it).

## Error Handling

- A recovery failure is logged, not fatal (the runtime still serves); the next
  start retries.
- A cancelled worker that never emits a terminal event is finalized by the
  runtime's own `FinishTurn` on the cancel path.

## Testing Requirements

### Unit Tests (`tests/test_store.pas`)

- [ ] `FinalizeRunningTurns` finalizes a running turn, rolls up counts, returns
      1; a second call returns 0 (idempotent); a completed turn is untouched.
- [ ] `BeginTurn` on a session with a running turn finalizes the prior one.

### Unit Tests (`tests/test_harness_turn.pas`)

- [ ] The gate denies on timeout when no answer arrives.

### Integration Tests (`tests/test_session_runtime.pas`)

- [ ] A runtime opened on a session with an orphaned running turn finalizes it
      (`recovered_on_start`) and serves.
- [ ] Killing the last client mid-turn finalizes the turn
      (`client_disconnected`).
- [ ] Shutdown mid-turn finalizes the turn (`shutdown`).

### Unit Tests (`tests/test_agent.pas` or view)

- [ ] Resume of a history ending in a dangling tool call appends the synthetic
      result; a well-formed history is unchanged.

## Performance Targets

- Recovery is one UPDATE; negligible at startup.

## Security Considerations

- None beyond turn ownership: recovery only runs in the process that acquired
  the session (socket), so it cannot steal a live turn.

## Success Criteria

- [ ] No `tsRunning` turn survives a runtime start; `make check` green.

## Future Considerations

- A distinct "interrupted" status; auto-resume; a stale-runtime warning.
