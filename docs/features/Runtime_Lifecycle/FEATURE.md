# Runtime Lifecycle

## Overview

Make the **session runtime** (the process that owns the agent loop and its
tools) stop promptly and gracefully, so it can be upgraded or restarted without
waiting for an idle timeout or killing it uncleanly. Three mechanisms: an
in-band **shutdown command**, an **exit-when-no-clients** policy, and
**signal handling** (SIGTERM/SIGINT → graceful stop).

This matters because the runtime is where the agent lives: the TUI is only a
client. A long-lived runtime pins the session to the binary it started with —
MCP tools, providers, and all — and today the only ways to replace it are a
5-minute idle wait or a hard kill that orphans its children.

## Problem Statement

The runtime owns the agent loop (`THarnessSession`: tools, MCP servers, the
LLM client). A client (the TUI/CLI) connects over an AF_UNIX socket and can
attach, prompt, approve, and interrupt — but **cannot ask the runtime to stop**,
and the runtime does not notice a disconnect promptly.

Today the runtime exits only when (a) `FStop` is set internally, or (b) there
are **no clients, no active turn, and the idle deadline has passed** —
`DefaultIdleExitMs` is **300000 ms (5 minutes)**. So:

- After the operator quits the TUI, the agent lingers for up to five minutes.
- Upgrading the binary (a rebuild, a new MCP provider) requires either waiting
  out that window or `kill`-ing the process — and a plain `kill` (SIGTERM) has
  no handler, so the runtime dies without tearing down its MCP child processes
  (docker containers, etc.), and without clearing its `session_runtimes` row.
- There is no way for a client to say "we're done, exit now."

The discovery that surfaced this: a rebuilt binary was not in effect because the
running runtime predated the build, and the TUI (fresh) had merely attached to
the stale runtime. Restarting required killing processes by hand.

## Goals

- A client can ask the runtime to **shut down gracefully** (in-band command).
- The runtime **exits when its last client disconnects**, after a short,
  configurable grace (so a crashed TUI does not strand a runtime, and an
  intentional detach can still linger briefly).
- **SIGTERM/SIGINT** cause a **graceful** stop (children torn down, runtime row
  cleared), so `kill` and a process supervisor are safe.
- Graceful stop tears down everything the runtime owns: MCP children, the
  session, the socket, and the `session_runtimes` row.
- Restart/upgrade is: quit the client → the runtime exits → relaunch spawns a
  fresh runtime from the current binary.

## User Stories

- As an **operator**, I want the agent to stop when I quit the TUI, so I can
  rebuild and relaunch without waiting or killing processes.
- As an **operator**, I want `kill <pid>` to stop the runtime cleanly, so I can
  script a restart without orphaning docker containers.
- As an **operator**, I want a background turn to survive a brief disconnect
  (attach → detach → reattach), so a client restart does not kill live work.
- As a **developer**, I want to replace a running agent with a freshly built
  one in one step, so iterating on tools/providers does not mean hunting PIDs.

## Acceptance Criteria

### Functional Requirements

- [ ] A new protocol command `scShutdown` (driver-only): the runtime replies,
      stops serving, tears down gracefully, and exits 0.
- [ ] The runtime handles **SIGTERM** and **SIGINT** by initiating the same
      graceful stop (not the default terminate), so a signal is a clean exit.
- [ ] A configurable **exit-when-no-clients** policy: when the client count
      reaches zero, the runtime exits after `ClientExitGraceMs` (default short,
      e.g. 2000 ms; 0 = immediate; negative = never, today's behaviour). A
      reattach within the grace cancels the exit.
- [ ] The grace does **not** apply while a turn is active: an in-flight turn
      keeps the runtime up until it finishes or is cancelled (the existing
      no-exit-during-turn rule is preserved).
- [ ] Graceful stop: close every client, free the session (`THarnessSession.Close`
      → MCP children closed), unlink the socket, and clear the
      `session_runtimes` row.
- [ ] The runtime's exit reason is observable (the `ekLoopExited` event / a log),
      distinguishing shutdown-command, signal, no-clients, and idle-timeout.
- [ ] Defaults preserve today's safety for a plain long-lived session where
      possible, but the **no-clients exit** is on by default (with a short
      grace) because a detached agent with no client is usually a leak.

### Non-Functional Requirements

- [ ] No busy poll introduced: the runtime still blocks on `select` with a
      finite timeout (see `docs/guidelines/tui-rendering.md`).
- [ ] Signal handling is async-signal-safe (set a flag; do the work in the loop).
- [ ] `make check` passes; leak-clean across a shutdown with MCP children.

## Success Metrics

### Quantitative

- A client disconnect stops the runtime within `ClientExitGraceMs` (target
  ≤ 2 s), down from ≤ 300 s.
- `kill -TERM <pid>` exits within the same bound with children reaped and the
  runtime row cleared (no orphan docker container).

### Qualitative

- Replacing a running agent with a rebuilt one is one client quit + one relaunch.
- The runtime never dies leaving an orphaned MCP child or a stale runtime row.

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`; POSIX signals via `BaseUnix`.
- Reuse the existing `FStop` flag and the serve-loop `Shutdown` path.
- Keep the protocol's `Version` bump discipline (a new command kind is additive;
  an unknown command from an old client must be answered, not crash).

## Dependencies

### Internal

- `hildi.session.runtime` (serve loop, `FStop`, `Shutdown`).
- `hildi.session.protocol` (`TSessionCommandKind`).
- `hildi.session.client` (the client sends `scShutdown`/detaches).
- `hildi.harness.session` (owns the MCP children to tear down).

### External

- None (POSIX signals).

## Risks

- **Killing live work** — Mitigation: the no-clients grace is cancelled by a
  reattach, and an active turn suppresses the exit.
- **Orphaned children on a hard kill** — Mitigation: signal handling makes
  SIGTERM graceful; SIGKILL remains unrecoverable (accepted, as ever).
- **A shutdown command abused** — Mitigation: driver-only; it stops *this*
  runtime, which is the operator's own session.

## Out of Scope

- **A supervisor / auto-restart** (systemd-style). This feature makes the runtime
  stop cleanly; supervising it is a deployment concern.
- **Hot binary swap** (exec a new binary in place). v1 is stop-and-relaunch.
- **Multi-client semantics beyond the grace** (e.g. quorum). Last-client wins.

## Future Considerations

- `exec`-based restart (the runtime replaces itself with a new binary).
- A runtime that outlives clients deliberately (a daemon serving many sessions).
- Session resumption after a runtime restart (partly exists via the store).

## Notes

- **ICE score: Impact 7, Confidence 8, Ease 7.** The mechanism is small (a
  command, a signal handler, a policy on an existing counter) and the payoff —
  painless upgrade/restart — is immediate and recurring.
- This is a **direct consequence** of the "tools live on the agent, not the
  client" architecture: it is the operational cost of that (correct) split, and
  this feature pays it.
