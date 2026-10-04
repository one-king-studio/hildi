# Component Specification: Session Runtime v1

**Related Feature:** [FEATURE.md](FEATURE.md)
**Implements:** [Session Protocol v1](Session_Protocol_v1.SPEC.md)

## Purpose

The per-session process that owns a session's agent loop and serves the protocol,
plus the client library that attaches to it and the store row that makes it
discoverable. Together these detach the loop from any UI: a session runs
headless, survives the client that started it, and can be attached to by any
number of clients.

v1 delivers the mechanism and proves it end to end with the CLI as the first
client. The TUI's adoption (it currently *owns* the loop) is the next slice.

## Requirements

### Functional

**Runtime process**

- [ ] `--session-runtime <session-id>` starts the runtime for one session: it
      resolves the workspace, opens the store, and builds the loop exactly as
      `THarnessSession` does today.
- [ ] It **binds the socket** for the session (`bind` is the acquisition). If the
      path exists and `connect` is refused, it unlinks the stale socket and
      re-binds; if the path exists and connects, another runtime is live and this
      one exits.
- [ ] It **serves** the protocol: `hello` on accept, `attach` handling, events
      out, commands in, `reply` correlation.
- [ ] It **runs turns** on a worker thread (reusing `TTurnWorker`): a `prompt`
      from the driver starts a turn; the loop's streamed callbacks become events
      on every attached connection.
- [ ] Approvals are bridged like `TApprovalGate`: the loop's approver emits
      `approval_request` and blocks; a driver's `approve` command resolves it,
      or it times out to a denial.
- [ ] It emits `loop_exited` and closes connections when the session's work
      ends, then exits.
- [ ] It **idle-exits** after `DefaultIdleExitMs` with no clients and no turn in
      flight. It is spawned **detached** (its own session/process group) so it
      survives the client, and its stdout/stderr go to a log, not the client's
      terminal.

**Client library**

- [ ] `TSessionClient` **connects or spawns**: it tries the session's socket; on
      `ECONNREFUSED`/`ENOENT` it spawns a detached runtime and retries until the
      socket accepts or a spawn timeout elapses.
- [ ] It attaches with a role and `from_seq`, receives events, delivers them to
      an `ISessionSink`, and sends commands with correlated replies.
- [ ] It follows the session across turns: when a runtime exits, the client
      re-reads the ledger and, on the next `prompt`, connects-or-spawns again.

**Store (additive migration v2)**

- [ ] A `session_runtimes` row per active session: `session_id` (PK), `pid`,
      `socket_path`, `status`, `started_at`, `updated_at`.
- [ ] `RegisterRuntime` / `LoadRuntime` / `ClearRuntime` / `ListRuntimes`.
- [ ] The row is **advisory** (discovery and display); see the authority rule
      below.

**CLI (first client)**

- [ ] `agent-cli --attach <session-id>` attaches as an observer and renders the
      live turn plus ledger history.
- [ ] A `prompt` from the CLI spawns or attaches to the runtime as the driver
      and streams the turn.

### Non-Functional

- [ ] Portability: macOS and Linux, FPC 3.3.1.
- [ ] Reliability: leak-clean under the heaptrc gate with a runtime, a client,
      and a worker thread running; a client that dies leaves the runtime serving.
- [ ] Performance: a runtime with no clients and no turn is idle (no spin); a
      turn's event append does not measurably slow the loop.
- [ ] Testability: the runtime and client are tested over a real socket with
      scripted clients and a fake transport; no terminals in the suite.
- [ ] `make check` passes.

## Decisions (resolving the FEATURE's open questions)

1. **Idle exit: 300 s.** `DefaultIdleExitMs = 300000` (no clients, no turn in
   flight), configurable via `HILDEGARD_RUNTIME_IDLE_MS`. Long enough to survive
   a TUI restart, short enough not to strand processes.
2. **The socket is authoritative for liveness; the store row is advisory.** A
   row is discovery and display only; it may be stale after a crash. Liveness is
   proven by `connect` succeeding, and a refused connect means the row is stale —
   the client cleans it and proceeds. The row is never consulted to decide
   whether a session is live.
3. **The drive role is granted on attach, not by a separate grant.** The first
   `attach{role:"drive"}` while free wins; a later claimer is downgraded to
   `observe` and named the current driver. A held role changes only through
   `claim_drive` → `drive_requested` → the driver's consent (or a timeout). No
   forced eviction.
4. **Replay and reconciliation** are fixed in the protocol spec: the wire carries
   the live turn only; the `attached` reply carries `store_hwm`; the client
   composes ledger history up to `store_hwm` with replayed events.

## Contracts & Interfaces

### Public API

```pascal
unit hildegard.helper.session.runtime;

type
  TSessionRuntimeConfig = record
    SessionId: string;          // '' => create a new session
    WorkspacePath: string;      // '' => env / cwd
    StorePath: string;          // required (the runtime is store-backed)
    IdleExitMs: Integer;        // 0 => DefaultIdleExitMs
    Model: string;              // '' => resolved from env/.env
    Endpoint: string;
    Transport: TLLMTransport;   // test seam
  end;

  { The server. One per session. }
  TSessionRuntime = class
  public
    class function Open(const AConfig: TSessionRuntimeConfig;
      out AError: string): TSessionRuntime;
    { Bind, then accept and serve until stopped or idle-exit. Returns the
      process exit code. Blocking. }
    function Serve: Integer;
    procedure Stop;
    property SessionId: string read FSessionId;
    property SocketPath: string read FSocketPath;
  end;

  TSessionClientConfig = record
    SessionId: string;
    StorePath: string;
    Role: TSessionRole;
    FromSeq: Int64;             // 0 => the whole live turn
    Spawn: Boolean;             // connect-or-spawn
    SpawnTimeoutMs: Integer;    // 0 => default
    RuntimeCommand: string;     // the argv used to spawn a runtime
  end;

  { The consumer's mapping target: the TUI/CLI implement this. }
  ISessionSink = interface
    procedure OnHello(const AHello: TSessionHello);
    procedure OnAttached(const AAttached: TSessionAttached);
    procedure OnEvent(const AEvent: TSessionEvent);
    procedure OnDetached(const AReason: string);
    procedure OnError(const ACode, AMessage: string);
  end;

  TSessionClient = class
  public
    class function Open(const AConfig: TSessionClientConfig;
      const ASink: ISessionSink; out AError: string): TSessionClient;
    { Send a command and return immediately; the reply arrives via the sink's
      reply path. Returns False when the connection is gone. }
    function Send(const ACommand: TSessionCommand): Boolean;
    { Blocking helper: send and wait for the correlated reply. }
    function SendAndWait(const ACommand: TSessionCommand;
      ATimeoutMs: Integer; out AReply: TSessionMessage): Boolean;
    property Role: TSessionRole read FRole;
    procedure Close;
  end;
```

### Data Contracts

```pascal
type
  TSessionRuntimeStatus = (rsRunning, rsExited);

  TSessionRuntimeRow = record
    SessionId: string;
    Pid: Integer;
    SocketPath: string;
    Status: TSessionRuntimeStatus;
    StartedAt: Int64;
    UpdatedAt: Int64;
  end;

const
  DefaultIdleExitMs = 300000;
  DefaultSpawnTimeoutMs = 5000;
  DefaultMaxLineBytes = 1048576;   // 1 MiB
```

Store additions (migration v2):

```sql
CREATE TABLE session_runtimes (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  pid INTEGER NOT NULL,
  socket_path TEXT NOT NULL,
  status INTEGER NOT NULL DEFAULT 0,
  started_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL);
```

### Event Contracts

- `ISessionSink` methods fire on the client's own reader thread. A sink that
  touches a UI must marshal to its UI thread (the TUI already has this pattern
  from `TTurnQueue`).

## Architecture

### Prior Art & Reuse

- **`THarnessSession.Open`** already resolves the workspace, opens the store,
  ensures the session, and builds the tools/approvals/loop. The runtime reuses it
  rather than re-bootstrapping.
- **`TTurnWorker` / `TTurnQueue` / `TApprovalGate`** are the thread boundary; the
  runtime's turn execution and approval bridging reuse the same discipline.
- **`TSqliteConversationStore`** is the ledger and the restore path; the runtime
  writes it, the client reads it.
- **The protocol codec** is the only genuinely new type; the transport is a thin
  socket loop.

### Component Boundaries

- **Responsibilities:** the runtime owns the loop, the socket, and the ledger
  writes; the client owns the connection and the sink; the store row is
  discovery.
- **Dependencies:** the protocol unit, `ssockets`/`baseunix`, the harness
  session, the turn worker.
- **Side effects:** the socket file, the store rows, a log file.

### Data Flow

1. A client `Open`s: it reads the runtime row, tries the socket, and spawns a
   detached runtime if needed.
2. The runtime binds, serves `hello`, accepts `attach`, replays the live turn,
   then streams.
3. The driver sends `prompt`; the runtime runs a turn on the worker and emits
   events; approvals cross as `approval_request` / `approve`.
4. On turn end the runtime stays for the next `prompt`; on idle it exits.

### Integration Patterns

- One runtime per session; one worker thread per turn; the socket reader on the
  main thread. The runtime is spawned detached (`setsid`/new process group) and
  reparented to init when its spawner dies.

## Validation Rules

### Input

- A config must name a store path; the runtime is store-backed (the ledger is
  the durable truth).
- The socket path must fit the platform's `AF_UNIX` limit; the runtime refuses to
  start otherwise, with a clear error.

### Output Guarantees

- The ledger is written exactly as today, so a client that only reads the ledger
  sees a correct, if coarser, session.
- A runtime never runs two turns at once.

## Error Handling

### Error Types

- **Spawn failure** (no binary, bind refused after retries) → the client returns
  nil with a message; the caller surfaces it.
- **Another runtime is live** → the second runtime exits cleanly (exit 0) and the
  client attaches to the first.
- **Stale socket** → unlinked and re-bound.
- **Protocol errors** → per the protocol spec.
- **Loop errors** → `event{kind:"error"}`; the stream continues.

### Error Contracts

The runtime exits `0` on idle exit and on "another runtime is live", and non-zero
on a fatal startup error. Process-level codes are unchanged (`124` timeout,
`128+signal`, `130` cancelled).

## Testing Requirements

### Unit Tests

- [ ] `TestRuntimeRowRoundTrip` (store) and `TestRuntimeMigrationIsAdditive`.
- [ ] `TestIdleExitConfigDefault`.
- [ ] `TestSocketPathFitsUnixLimit`.

### Integration Tests

- [ ] `TestSpawnAndAttach` — a client spawns a runtime, attaches, and gets
      `hello`/`attached`.
- [ ] `TestSecondRuntimeExits` — a second runtime on the same session exits 0 and
      does not steal the socket.
- [ ] `TestStaleSocketRecovered` — a leftover socket file is unlinked and
      re-bound.
- [ ] `TestTurnStreamsToObserver` — a driver prompts, an observer sees the whole
      turn from `seq` 0.
- [ ] `TestApprovalCrossesTheWire` — an approval ask reaches the driver and the
      decision unblocks the loop.
- [ ] `TestClientSurvivesRuntimeExitAndRespawns`.
- [ ] `TestIdleExit` — with a fake clock, the runtime exits after the timeout.

## Performance Targets

- Runtime with no clients and no turn: no spin, near-zero CPU.
- Spawn-to-attached under ~200 ms on a warm filesystem.
- Event append adds no measurable latency to the turn.

## Security Considerations

- The socket is `0700` in a short runtime directory; same-user only.
- The API key never crosses the wire; only loop output does.
- A detached runtime does not inherit the client's terminal or file descriptors
  beyond what it needs.

## Success Criteria

### Functional

- [ ] A session runs headless, survives its client, and is attachable.
- [ ] The CLI attaches as an observer and as a driver.
- [ ] `make check` passes.

### Quality

- [ ] No leaks with a runtime, a client, and a worker running.
- [ ] The runtime is idle when unused; the socket is the liveness proof.
- [ ] The TUI adoption is a clean follow-on (it becomes a `ISessionSink`).

## Future Considerations

- **The TUI adopts `TSessionClient`** (the largest follow-on): `THarnessApp`
  becomes a sink, and its worker/queue move into the runtime.
- Subagent spawning on top of the runtime (a child session + runtime).
- The daemon (reserved name: **Session Host**) that owns many runtimes and hosts
  the link.
- A network transport over the same protocol.
- Windows: AF_UNIX + a process-detach equivalent (see
  [`docs/guidelines/windows-portability.md`](../../guidelines/windows-portability.md)).
