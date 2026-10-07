# Dynamic Tools

## Overview

Make a **running** session's tool surface dynamic: reconciled from the store at
turn boundaries, including **enable / disable / remove** of servers and
**reconnect** of servers that drop. Today the MCP client reads its server list
once, at session open; a config change needs a session restart, and a remote
server that loses its connection is dead for the rest of the session. This
feature closes that gap without changing the trust model: a config row widens
which tools are *offered*; every *call* is still gated by the approval engine.

## Problem Statement

The MCP client (v1) is store-backed and scoped, but **static per session**:
`THarnessSession.Init` resolves the server list once and opens a `TMcpManager`.
Consequences:

- An operator who adds a server mid-session gets nothing until they restart the
  session — the very thing the DB-driven config was meant to avoid.
- Disabling or removing a server leaves its tools registered (there is no
  `TToolRegistry.Remove`), so a revoked capability stays on offer.
- A **remote** MCP server (v2 HTTP, and any stdio server over a flaky link)
  that drops is dead for the session: the client marks itself dead and every
  call fails cleanly, but nothing ever reconnects. For remote servers this is
  the normal case, not an edge case.

Ponytail check: the loop already rebuilds its tool list every request
(`TAgentLoop` sets `Result.Tools := FTools.Specs` per request), and
`ResolveMcpConfig` / `TMcpManager` / the client's ref tracking already exist.
The genuine gaps are small: a boundary hook, `TToolRegistry.Remove`, and turning
the manager's one-shot `Open` into a per-server **lifecycle** (add / disable /
remove / reconnect with backoff).

## Goals

- Reconcile the MCP tool surface from the store at each turn boundary, with no
  session restart.
- Support **enable / disable / remove** of a server at runtime (register on
  enable, unregister on disable/remove).
- Support **reconnect** of a dropped server with bounded exponential backoff,
  re-listing its tools (a recovered server may advertise a different set).
- Keep the trust model unchanged: config is operator-only; every call is
  approval-gated by `mcp/<server>/<tool>` ref.
- Be leak-clean and race-free against the loop's per-request tool snapshot.

## User Stories

- As an **operator**, I want to add an MCP server by writing a row and have its
  tools appear on the agent's next turn, so I never restart a session to extend
  it.
- As an **operator**, I want to disable or remove a server and have its tools
  disappear, so a revoked capability is no longer offered.
- As an **operator**, I want a remote server that drops to reconnect
  automatically, so a transient network blip does not cost me its tools for the
  rest of the session.
- As the **agent**, I want my tool list to reflect current config at each turn,
  so I never call a tool that no longer exists or miss one that now does.
- As a **reviewer**, I want the change to leave the approval path untouched, so
  dynamic tools cannot become an approval bypass.

## Acceptance Criteria

### Functional Requirements

- [ ] `TAgentLoop` gains an `OnTurnStart` hook, invoked **once per turn** on the
      loop's own thread, before the first request. (Per-request invocation is a
      deliberate future widening; see Out of Scope.)
- [ ] `TToolRegistry.Remove(const AName: string)` removes a tool by name and
      reports whether it was present. Removal is safe between requests (the hook
      runs on the loop's thread; the loop snapshots the registry per request).
- [ ] `TMcpManager` becomes a **lifecycle manager**: `Reconcile(AConfig, ATools)`
      diffs the resolved config against live servers by name and applies:
      - enabled & not connected → open + register;
      - enabled & dead & backoff elapsed → close, reconnect, re-list, register;
      - disabled or absent from config → close + **unregister** its tools;
      - enabled & connected → no-op.
- [ ] Reconnect uses **bounded exponential backoff** per server (e.g. 1s, 2s,
      4s … capped at 60s); a successful connect resets the backoff.
- [ ] Reconnect **re-runs `tools/list`**: a recovered server's tool set is
      reconciled (added/removed), not assumed identical.
- [ ] `THarnessSession` wires `FLoop.OnTurnStart` to re-read the store, resolve,
      and `Reconcile` — so a row added/changed/removed between turns is picked
      up on the next turn.
- [ ] A server that fails to open during a reconcile is logged (session event)
      and skipped; the reconcile of *other* servers still applies. No hang, no
      crash, no partial registration.
- [ ] The trust model is unchanged: config is operator-only (no tool writes
      `mcp_servers`); every MCP call is decided by the approval engine.

### Non-Functional Requirements

- [ ] Reconciliation cost is O(servers) with one indexed config query per turn;
      an unchanged, connected server is a no-op (no respawn).
- [ ] No registry mutation races the loop's per-request snapshot (single-thread
      mutation at the boundary).
- [ ] `make check` passes, including the leak gate (reconnect/open/close cycles
      must not leak).

## Success Metrics

### Quantitative

- A config row added between two turns is offered to the model on the **next**
  turn (target: 0 session restarts required).
- A killed server's tools are gone from the registry within one turn of the
  disable/remove.
- A dropped server reconnects within `backoff` after the drop, once the peer is
  reachable again.

### Qualitative

- The change is confined to the loop hook, the registry, and the MCP manager —
  no new trust mechanism, no new store primitive.
- The lifecycle is explicit (a state per server), not implicit in a diff.

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`; `make check` green.
- Reuse `ResolveMcpConfig`, `TMcpManager`, `TMcpClient` (its `FDead` /
  registered-ref tracking), and the per-request snapshot.
- POSIX (macOS/Linux); no new dependency.
- Registry mutation happens on the loop's thread at a boundary.

### Business / Time

- v1 is deliberately small: the hook, `Remove`, and the manager lifecycle.

## Dependencies

### Internal

- `hildegard.helper.agent` (`TAgentLoop`, `TToolRegistry`).
- `hildegard.helper.mcp.client` / `hildegard.helper.mcp.config`.
- `hildegard.helper.harness.session` (the wiring).
- `docs/features/MCP_Client/` (v1).

### External

- None.

## Risks

- **Registry race with the per-request snapshot** — Mitigation: mutate only at a
  boundary, on the loop's thread.
- **Reconnect storm** (a flapping remote server) — Mitigation: bounded
  exponential backoff, per server; a failed attempt does not block the turn
  (bounded by the connect timeout).
- **A reconnect that blocks a turn** — Mitigation: connect/list timeouts are
  already bounded; the boundary reconcile is bounded by the sum of per-server
  timeouts, so cap the number of servers (already `MaxMcpServers`).
- **Stale tools after a partial failure** — Mitigation: reconcile is per-server;
  one failure never leaves a half-registered server.

## Out of Scope

- **Active health checks** (`ping` on a timer). v1 detects death lazily (on a
  call or read) and reconnects at the next boundary; a timer is deferred.
- **Mid-turn reconcile** (between tool calls within one turn). v1 reconciles at
  turn start.
- **Hot-applying a *changed* server definition** (e.g. a new `command`) to an
  already-connected server; v1 treats enable/disable/add/remove, and a change to
  a live server needs a disable→enable cycle (or is picked up on reconnect).
- **Non-MCP dynamic tool sources.** The `OnTurnStart` hook is generic, but v1
  reconciles MCP only.
- **A config UI.** Operator writes SQL (MCP v1 decision stands).

## Future Considerations

- Per-request reconcile (the hook placement makes this a small change).
- Active `ping`-based liveness and a `notifications/tools/list_changed`-driven
  re-list.
- A generic `IToolSource` seam so file/other tools could be DB-driven too.
- Agent self-configuration (MCP v1 reserved `msAgent`); dynamic reconcile is the
  mechanism that would make it live without a restart.

## Notes

- **ICE score: Impact 7, Confidence 8, Ease 6.** The need is concrete (remote
  MCPs especially), the reuse is high (per-request snapshot, resolver, manager),
  and the trust model is already in place — the work is the boundary hook, one
  registry method, and the lifecycle/backoff.
- The trust argument (operator preference, recorded): every call remains
  approval-gated, so a config row changes *capability surface*, not *permission*;
  this is stricter than implementations that trust a config file outright.
