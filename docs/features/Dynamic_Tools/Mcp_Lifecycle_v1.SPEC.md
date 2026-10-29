# Component Specification: MCP Lifecycle v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `Tool_Boundary_v1.SPEC.md` (the hook and `Remove`),
`hildi.mcp.client` / `hildi.mcp.config`.
**Depended on by:** `hildi.harness.session` (wires the hook).

## Purpose

Turn `TMcpManager` from a one-shot `Open` into a **per-server lifecycle
manager**: given the resolved config, reconcile the live set — open, close,
**reconnect** (bounded backoff), and **unregister** — so a running session's MCP
tool surface tracks the store, and a dropped server comes back.

This is the remote-MCP requirement: a network drop is normal, not exceptional.

## Requirements

### Functional

- [ ] `TMcpManager.Reconcile(const AConfig: TMcpConfig;
      ATools: TToolRegistry): Boolean` diffs the resolved config against live
      servers **by name** and applies the per-server action table below.
- [ ] Each server has an explicit lifecycle state (see Data Contracts); actions
      are driven by state + config, not by a blind re-open.
- [ ] **Enable** (enabled, not connected) → open the client, register its tools.
- [ ] **Disable / remove** (row disabled, or absent from config) → close the
      client and **unregister** its tools (via `TToolRegistry.Remove`).
- [ ] **Reconnect** (enabled, dead, backoff elapsed) → close, re-open, re-run
      `tools/list`, and reconcile the registered tools (add/remove) — a
      recovered server's set may differ.
- [ ] **Backoff** is per server, exponential, capped (default 1s → 60s); a
      successful connect resets it. A reconnect attempt is skipped while
      `now < nextAttemptAt`.
- [ ] A server that fails during reconcile is logged (session event) and left
      `Dead` with its backoff advanced; other servers still reconcile. No hang,
      no crash, no partial registration.
- [ ] Trust is unchanged: no new permission path; calls remain approval-gated.

### Non-Functional

- [ ] One indexed config query per reconcile; unchanged connected servers are
      no-ops (no respawn).
- [ ] Bounded: reconcile time is bounded by the sum of per-server connect/list
      timeouts (`MaxMcpServers` caps the count).
- [ ] Leak-clean across open/close/reconnect cycles (`make test-leak`).

## Contracts & Interfaces

```pascal
unit hildi.mcp.client;   // additions/changes

type
  { A server's lifecycle state. }
  TMcpServerState = (mssStopped, mssConnected, mssDead);

  { Per-server runtime record the manager owns. }
  TMcpServerRuntime = record
    Name: string;
    Config: TMcpServerConfig;
    Client: TMcpClient;
    State: TMcpServerState;
    NextAttemptAt: Int64;      // ms epoch; 0 = now
    BackoffMs: Integer;        // current backoff
    Attempts: Integer;
  end;

  TMcpManager = class
    // ... existing (Open becomes a thin wrapper over Reconcile) ...
    { Diff AConfig against the live set and apply enable/disable/remove/reconnect.
      Returns True when the manager is consistent (individual server failures are
      logged, not fatal). }
    function Reconcile(const AConfig: TMcpConfig;
      ATools: TToolRegistry): Boolean;
    { The live runtime rows, for tests/UI. }
    function Runtimes: TMcpServerRuntimeArray;
  end;

const
  McpBackoffInitialMs = 1000;
  McpBackoffMaxMs     = 60000;
```

### Data Contracts

**Action table** (state × config, by `Name`):

| Config | State | Action |
| --- | --- | --- |
| enabled, present | `mssConnected` | no-op |
| enabled, present | `mssStopped` | open → `mssConnected` (or `mssDead`) |
| enabled, present | `mssDead` | if `now >= NextAttemptAt`: close → re-open → re-list → `mssConnected`, reset backoff; else skip |
| disabled / absent | `mssConnected` | close + unregister → `mssStopped` (or drop the row) |
| disabled / absent | `mssStopped` / `mssDead` | drop the row |

- **Identity:** a server is matched by `Name` (config is name-unique per scope
  after resolution). A *changed* definition for a connected server is **not**
  hot-applied in v1 (Out of Scope); it takes effect on the next disconnect or a
  disable→enable cycle.
- **Unregister:** removing a server unregisters exactly the tools it registered.
  The manager tracks each server's registered tool names (the client already
  tracks refs; the manager maps ref→name) so removal is exact, never by prefix.
- **Backoff:** `NextAttemptAt := now + BackoffMs`; `BackoffMs := min(BackoffMs *
  2, McpBackoffMaxMs)` on failure; reset to `McpBackoffInitialMs` on success.

### Event Contracts

- The existing `TMcpEvent` sink (message + detail) reports: open failure,
  reconnect attempt, reconnect success, and tools removed. Fired on the loop's
  thread (reconcile runs there).

## Architecture

### Prior Art & Reuse

- **`TMcpClient`** already tracks `FDead` (set on EOF/read failure) and its
  registered refs (`FRegisteredRefs`); `Open`/`Close`/`Tools` are the primitives.
  The manager adds state + policy around them.
- **`ResolveMcpConfig`** produces the effective list; `Reconcile` consumes it.
- **`TToolRegistry.Remove`** (Tool_Boundary_v1) is the unregister primitive.
- **Genuine gap:** the per-server state machine and backoff. Nothing covers it.

### Component Boundaries

- **Responsibilities:** per-server state, backoff, open/close/reconnect, exact
  register/unregister.
- **Dependencies:** `mcp.client`, `mcp.config`, `agent` (registry), `session.socket`
  (`NowMs`).
- **Side effects:** spawns/kills children; mutates the registry (loop thread).

### Data Flow

1. `THarnessSession.OnTurnStart` → `LoadMcpServers` → `ResolveMcpConfig` →
   `TMcpManager.Reconcile`.
2. `Reconcile` walks the union of configured names and live runtime names, and
   applies the action table.
3. Register/unregister go through `TTools`; the loop snapshots per request, so
   the change is visible on the first request of the turn.

### Integration Patterns

- **Threading:** reconcile runs on the loop's thread (the `OnTurnStart` hook),
  so registry mutation is race-free. `TMcpClient` remains synchronous; a connect
  is bounded by its timeouts.
- **Lifetime:** `THarnessSession` owns the manager; the manager owns its runtimes
  and clients; `Close` stops everything.

## Validation Rules

### Input

- `AConfig.Servers` are already validated by `ResolveMcpConfig`.
- A server name that appears twice in config cannot occur (name-unique after
  resolution).

### Output Guarantees

- After `Reconcile`, the registry contains exactly the tools of enabled,
  connected servers, and no tools of stopped/disabled ones.
- `Runtimes` reflects the live set (one row per configured enabled server, plus
  any still-shutting-down).

## Error Handling

- **Open failure:** log, state `mssDead`, backoff advanced; the turn continues.
- **Reconnect failure:** same; retried after the next backoff.
- **Read failure mid-call:** the client sets `FDead`; the next reconcile
  reconnects it.
- **Remove/disable:** always succeeds (close is idempotent; `Remove` is a no-op
  for an absent name).

## Testing Requirements

### Unit Tests (`tests/test_mcp_client.pas` additions)

- [ ] `Reconcile` opens a newly-enabled server (tools appear) and is a no-op on a
      second call with the same config (no respawn — assert the child PID/identity
      is unchanged, or that no new process is spawned).
- [ ] Disabling a server (config with it absent/disabled) unregisters exactly its
      tools and closes it.
- [ ] A dead server reconnects after the backoff elapses, re-lists, and its tools
      are registered again.
- [ ] A recovered server advertising a *different* tool set reconciles (old tool
      removed, new one added).
- [ ] Backoff grows on repeated failure and resets on success (drive with a fake
      clock or a short configured backoff).
- [ ] A failing server in a reconcile does not stop a healthy sibling from
      opening.
- [ ] Leak-clean across open/disable/reconnect cycles (`make test-leak`).

### Integration Tests

- [ ] `THarnessSession` with a configured server: add a second server row
      between turns, and the next turn offers its tools (fake servers).

## Performance Targets

- One config query + O(servers) work per turn; unchanged servers are no-ops.
- A reconnect attempt is bounded by the client's connect/list timeouts.

## Security Considerations

- **No bypass:** reconcile only widens the offered set; every call is still
  approval-gated. Disabling/removing narrows the set — a revocation is honored
  on the next turn.
- **No new write path:** config remains operator-only (the model cannot add a
  server).

## Success Criteria

- [ ] All contracts implemented; `make check` green; no leaks.
- [ ] A config change is reflected within one turn; a dropped server reconnects
      with backoff.

## Future Considerations

- **Active liveness:** a periodic `ping` (v2 transport) instead of lazy
  detection.
- **Hot definition change:** detect a changed row (not just presence) and cycle
  the server without a manual disable→enable.
- **`notifications/tools/list_changed`:** drive a re-list from the server's own
  signal.
- **Give-up policy:** v1 retries forever with capped backoff; a max-attempts
  policy is a config knob if wanted.
