# Headless Sessions

## Overview

Run each session's agent loop in its own **headless process** that owns a stable
**socket**, and let any number of clients attach to a typed **event stream**. The
active agent loop is the only thing that must be headless; everything else — the
TUI, the CLI, a web client — is a consumer that attaches, replays the live turn,
and maps the events to its own rendering.

Today a session is welded to one process and its loop dies with it. This feature
detaches the loop: a session becomes a long-lived headless process that any
client can observe, exactly one of which may drive it.

## Problem Statement

The agent loop and the UI are the same process. Closing the TUI kills the turn;
nothing can watch a run from anywhere else; and the ledger is the only record,
which is coarse — committed blocks, no live detail. A second TUI cannot attach
without fighting the first. An independent session (a subagent) has no home: it
cannot run on its own and be observed.

Session Handoff tried to fix ownership *within* the one-process-per-session
model — a heartbeat lease, a drain-on-handoff migration of the loop. This feature
changes the model instead: the loop is always headless, so it never migrates, and
ownership becomes a role on a socket rather than a lease on a process.

## Decision

**Committed: a per-session headless process with a bidirectional typed socket.**
Not a daemon (that waits for Remote Agent Link), not a subprocess per turn, not
an in-process observer feed.

- **Per-session process.** A session's loop runs in its own process, alive while
  the session is active and exiting on idle. It is spawned by the first client
  that needs it (connect-or-spawn) and survives the client that started it.
- **Stable Unix socket.** `AF_UNIX` / `SOCK_STREAM`, one per active session, in
  an owner-only runtime directory. The socket is the session's endpoint for its
  whole active life, so a client connects once and follows across turns.
- **The bind is the lease and the liveness check.** `bind()` fails if the path
  exists; if it exists but `connect()` is refused, the socket is stale — unlink
  and re-bind. No heartbeat, no staleness window, no pid/start-time impersonation
  guard.
- **Bidirectional, typed, transport-agnostic messages.** Server→client typed
  **events**; client→server **commands** with correlated replies. Framed as
  **NDJSON** (one JSON object per line) over the socket in v1. The message
  *schema* is the durable asset; the envelope and transport are bindings, so a
  JSON-RPC codec or an SSE/HTTP or WebSocket transport can be layered later
  without changing the model.
- **Semantic events, not rendered text.** Each event carries a `kind` and a
  payload, so a consumer `map`s it to cells, ANSI lines, or DOM. Versioned, with
  a `hello`/capability handshake.
- **Replay is the live turn only.** The loop buffers the current in-flight turn
  and replays it from `seq` 0 to a late attacher; prior turns come from the
  ledger. A client composes "the whole session" as *ledger history + the live
  turn*.
- **One driver, many observers.** Exactly one attached client may send drive
  commands (prompt, approve, interrupt); observers receive events and are
  rejected with an error if they try to drive.
- **Subagents are child sessions.** A subagent is another session with its own
  process and socket, linked to its parent; the parent (or its client) observes
  it like any other session.

### Protocol shape (the SPEC formalizes it)

```
transport  AF_UNIX SOCK_STREAM, path in a 0700 runtime dir
framing    NDJSON: one JSON object per line, versioned ("v":1)
handshake  S→C hello {protocol, version, session, loop, caps}
           C→S attach {from_seq, role}
           S→C attached {loop, role, last_seq, store_hwm}
events     S→C event {seq, kind, ...payload}
commands   C→S cmd {id, name, ...args}  ->  S→C reply {id, ok, error?}

event kinds   loop_started, user_message, assistant_delta, assistant_block,
              reasoning_delta, tool_call, tool_result, approval_request,
              approval_resolved, turn_finished, error, loop_exited
commands      attach, detach, prompt, approve, interrupt, ping
roles         observe (default) | drive (exclusive)
```

## Goals

- Decouple the agent loop from any UI, so a turn survives the client that started
  it and can be observed from elsewhere.
- Let a client attach to a live session, replay the in-flight turn, and map the
  event stream to its own rendering.
- Support many observers and exactly one driver per session.
- Give subagents a home: independent sessions that run on their own and are
  observable by the session that spawned them.
- Introduce the transport Remote Agent Link will reuse over the network.

## User Stories

- As an **operator**, I want to start a turn and close my TUI without killing it,
  so long work continues unattended.
- As an **operator**, I want to reopen a TUI, see the live turn replayed, and the
  history from before, so the view is seamless whether I watched it or not.
- As an **operator** at a second TUI, I want to watch a session read-only without
  disturbing the window that is driving it.
- As the **driver**, I want exactly one client to be able to type and approve, so
  two windows never fight over one conversation.
- As the **agent**, I want to spawn a subagent for a delegated task and watch it
  run, so I can decompose work without losing sight of it.
- As a **web client**, I want the same event stream, so a browser can render the
  session without a new backend.
- As the **Remote Agent Link designer**, I want the socket protocol to be
  transport-agnostic, so the link tunnels it instead of inventing a second one.

## Acceptance Criteria

### Functional Requirements

Headless session

- [ ] A session runs as a headless process with a stable socket; it registers
      itself (session id, pid, socket path, status) so clients can discover it.
- [ ] The process is spawned by the first client that needs it and survives that
      client; it exits after an idle timeout (no turn in flight, no clients).
- [ ] Ledger rows land exactly as they do today; the process writes the durable
      ledger and the live event stream.
- [ ] A crashed process leaves a stale socket that the next client detects
      (`connect` refused) and recovers by unlinking and re-binding.

Protocol

- [ ] A client attaches over the socket and receives `hello` then `attached`
      with its role and the stream position.
- [ ] The server emits typed events for the turn: user message, assistant deltas
      and final blocks, reasoning, tool calls and results, approval asks and
      decisions, turn finish, errors, and loop exit.
- [ ] A late attacher replays the in-flight turn from `seq` 0 and then follows
      live; prior turns are read from the ledger.
- [ ] The `attached` reply carries the store high-water mark at attach time, so
      a client can reconcile ledger history with the replayed stream and neither
      duplicate nor gap a message.
- [ ] Drive commands (`prompt`, `approve`, `interrupt`) are accepted from exactly
      one client and rejected with an error from others; observe commands
      (`attach`, `detach`, `ping`) are always accepted.
- [ ] A client may claim or release the drive role; the loop keeps running
      headless when the driver disconnects.

Subagents

- [ ] A session can spawn a child session that runs its own headless process and
      socket, linked to the parent.
- [ ] The parent's client can attach to the child as an observer and map its
      stream the same way.

### Non-Functional Requirements

- [ ] Portability: macOS and Linux, FPC 3.3.1; the socket path stays within the
      platform's AF_UNIX limit (a short runtime directory, not `$HOME`).
- [ ] No new runtime dependency; no daemon; the release stays self-contained.
- [ ] Idle overhead near zero: a session with no turn and no clients consumes no
      measurable CPU and exits.
- [ ] Backpressure: a slow observer never stalls the loop; it is dropped with a
      `gap` event and re-syncs from the ledger.
- [ ] Framing limits: oversized or malformed frames are rejected without
      destabilising the loop.
- [ ] Testability: the protocol is tested against the real loop with a scripted
      client — no terminals in the suite.
- [ ] `make check` passes (functional tests plus the leak gate).

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- Must reuse the store, the ledger and restore path, the turn worker and its
  cancel seam, the approval engine, and the modal machinery.
- Store changes are an additive migration (v2): a runtime/loops row for
  discovery. No reset of existing history.
- The socket lives in an owner-only directory; access is same-user only in v1.
- One binding only in v1 (NDJSON over a Unix socket); the schema must not assume
  it, so JSON-RPC and SSE/HTTP remain derivable as codec/transport bindings.

### Business / Time

- No deadline. The daemon and the network transport wait for Remote Agent Link.

## Dependencies

### Internal

- `hildegard.helper.store` — the ledger, the additive migration for discovery.
- `hildegard.helper.session` / `.store` — the durable history a client reads and
  the loop restores from.
- `hildegard.helper.harness.turn` — the turn worker, the queue, and the cancel
  seam the host reuses.
- The approval engine and modal — approvals cross the socket as events/commands.
- The CLI and TUI — the first two clients; both stop owning the loop.

### External

- Unix domain sockets (`AF_UNIX`), a runtime directory, and `fpjson` — all
  already available; no new dependency.

## Risks

- **Ledger/stream reconciliation.** A block can commit between a client's ledger
  read and its attach. Mitigation: the `attached` reply carries the store
  high-water mark; the client discards replayed events already covered.
- **Stale socket and path length.** A crashed process leaves a socket file, and
  AF_UNIX paths are short. Mitigation: connect-refused recovery; a short runtime
  directory.
- **Slow observers.** A stalled client must not stall the loop. Mitigation: drop
  with a `gap`; the client re-syncs from the ledger.
- **Multi-process writes.** Each session process writes the ledger. Mitigation:
  short transactions, WAL, the existing busy timeout; a session process is the
  sole writer of its own session.
- **Protocol churn.** The message schema will grow. Mitigation: version from day
  one with a `hello` handshake.
- **Idle-exit tuning.** Too eager kills a session mid-thought; too lazy strands
  processes. Mitigation: a documented timeout, measured in the spike.
- **Scope creep into a daemon.** A supervisor is tempting. Mitigation: it is
  explicitly Remote Agent Link's work; v1 is process-per-session, no supervisor.

## Out of Scope

- The daemon / supervisor and the network transport — Remote Agent Link.
- Additional bindings (JSON-RPC, WebSocket, SSE/HTTP) — derivable later, not v1.
- Multiple concurrent drivers for one session.
- Cross-machine observation.
- Windows.

## Future Considerations

- A JSON-RPC codec and a WebSocket/SSE transport over the same schema.
- The daemon that owns and supervises sessions, hosting the link — the name
  **Session Host** is reserved for it, since it genuinely hosts many sessions.
- A richer observer UI (the full chat panel read-only).
- Push notification instead of the attach-time replay.
- Subagent budgets and a bounded spawn tree.

## Notes

- **Supersedes Session Handoff.** The drive lease and observation move here; the
  heartbeat lease, pid/start-time impersonation guard, and drain-on-handoff
  migration are dropped, because the loop no longer moves between processes. The
  old `Session_Handoff/FEATURE.md` is kept for the record.
- **The rxjs framing.** The event stream is `shareReplay`: a hot, replayable,
  multicast sequence; a consumer `map`s it. The `kind` field is what makes the
  mapping possible — the stream is semantic events, never pre-rendered text.
- **Why per-session, not per-turn.** A stable endpoint lets a client connect
  once and follow across turns; a per-turn process would force re-discovery and
  re-attach each turn, and re-bootstrap the loop every time.
- **Code facts this rests on** (verified): the store's `TCriticalSection` is
  in-process and WAL + a 5 s busy timeout are set; migrations are at v1 (the
  Sessions v2 reset collapsed them); `TTurnWorker`/`TTurnQueue`/`TApprovalGate`
  are the thread boundary; `TSqliteConversationStore.Compose` is the restore
  path; `THarnessSession.Open` is the shared bootstrap.
- **Open questions for the SPEC.** The idle-exit timeout; whether the store row
  or the live socket is authoritative when they disagree; the exact event
  payloads and the reconciliation rule; whether the driver role is claimed by a
  command or granted to the first attacher.
- **Reuse note (Ponytail):** the loop, the ledger, the turn worker, the approval
  engine, and the modal all exist. The new pieces are the host process, the
  socket protocol, the event model, and the clients that attach.
