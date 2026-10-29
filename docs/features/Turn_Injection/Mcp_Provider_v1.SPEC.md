# Component Specification: MCP Provider v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `Turn_Assembly_v1.SPEC.md` (the provider seam),
`hildi.mcp.client` (the lifecycle manager).
**Depended on by:** `hildi.harness.session` (registration).

## Purpose

Make the MCP client a **contributor** on the turn-assembly seam, so the loop has
no MCP-specific branch. `TMcpManager` gains an `IToolProvider` implementation:
`Prepare` reconciles from the store, `Specs`/`Find` expose its live tools, and
`PromptFragment` is empty (MCP injects no prompt).

This retires `THarnessSession.OnTurnStart := McpReconcile` in favour of
`AddProvider(TMcpProvider)`. The reconcile behaviour (enable/disable/remove,
reconnect) is unchanged — it moves behind the interface.

## Requirements

### Functional

- [ ] `TMcpManager` (or a thin adapter) implements `IToolProvider`:
      - `Prepare` — re-read config (via a supplied config source), resolve,
        `Reconcile`;
      - `Specs` — the union of the live servers' registered specs (already
        namespaced `mcp_<server>_<tool>`);
      - `PromptFragment` — `''` (MCP contributes no prompt);
      - `Find` — resolve a tool name to the owning server's handler.
- [ ] The provider reads config through a **config source** the session supplies
      (a closure/interface that returns the current `TMcpConfig` from the store),
      so the provider stays free of the store.
- [ ] `THarnessSession` registers the MCP provider via `AddProvider`; it no
      longer sets `OnTurnStart` directly.
- [ ] Behaviour parity: enable/disable/remove and reconnect are exactly as
      `Mcp_Lifecycle_v1.SPEC.md`; the tool set offered equals the connected
      servers' tools.
- [ ] No prompt is injected by the MCP provider.

### Non-Functional

- [ ] One config read per turn (in `Prepare`); unchanged servers do no work.
- [ ] `make check` green; leak-clean.

## Contracts & Interfaces

```pascal
unit hildi.mcp.client;   // additions

type
  { Supplies the current effective MCP config (e.g. from the store). }
  TMcpConfigSource = function: TMcpConfig of object;

  { The MCP manager as a turn provider. Registered with TAgentLoop.AddProvider.
    Prepare reconciles from the config source; Specs/Find expose live tools. }
  TMcpProvider = class(TInterfacedObject, IToolProvider)
  public
    constructor Create(AManager: TMcpManager; AConfigSource: TMcpConfigSource);
    procedure Prepare;
    function Specs: TToolSpecArray;
    function PromptFragment: string;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
  end;
```

### Data Contracts

- **`Specs`** returns each live (connected) server's registered tool specs, in
  server order. The names are the manager's namespaced names — the same strings
  `Find` accepts.
- **`Find`** delegates to the owning server's client (`TMcpClient` already holds
  its handlers and tool names). First server to match wins.
- **`Prepare`** calls `AManager.Reconcile(AConfigSource(), nil)` — but the
  registry is not the manager's to mutate now: the manager keeps its own
  `RegisteredNames` and the **provider** exposes them, so `Reconcile` no longer
  needs `ATools`. The SPEC pins: `Reconcile` takes the provider's spec sink
  (or the provider reads the manager's live set after reconcile).

### Event Contracts

- The existing `TMcpEvent` sink continues to report failures/reconnects.

## Architecture

### Prior Art & Reuse

- **`TMcpManager.Reconcile`** is the engine; the provider is a thin adapter that
  supplies config and exposes specs/dispatch.
- **`TMcpClient`** already holds its tools and handlers; `Find` is a delegation.
- **Genuine gap:** the adapter and the decoupling of reconcile from a concrete
  `TToolRegistry` (the provider becomes the sink).

### Component Boundaries

- **Responsibilities:** config read (via source), reconcile trigger, spec
  exposure, dispatch.
- **Dependencies:** `mcp.client`, `mcp.config`, `agent` (provider interface).
- **Side effects:** spawns/kills children (on `Prepare`, loop thread).

### Data Flow

1. Turn start → `TAgentLoop` calls `TMcpProvider.Prepare` →
   `Reconcile(ConfigSource())`.
2. `BuildRequest` calls `Specs` → the turn's tool list includes live MCP tools.
3. A call → `ExecuteToolCalls` → `TMcpProvider.Find` → the server's handler.

### Integration Patterns

- **Threading:** all provider methods run on the loop's thread; `TMcpManager`
  remains synchronous.
- **Lifetime:** the session owns the manager and the provider; the provider holds
  a weak reference to the manager.

## Validation Rules

### Input

- `ConfigSource` may return an empty config (no servers) — a valid no-op.

### Output Guarantees

- `Specs` never returns a spec for a stopped/dead server.
- `Find` returns False for an unknown name (the loop then errors as today).

## Error Handling

- `Prepare` failure (config read, spawn) is logged; the provider contributes
  what it has; the turn continues.

## Testing Requirements

### Unit Tests (`tests/test_mcp_client.pas` additions)

- [ ] `TMcpProvider.Specs` reflects connected servers; `Find` dispatches to the
      right handler.
- [ ] `Prepare` reconciles: a config source that gains a server yields its tools
      on the next `Specs`.
- [ ] `PromptFragment` is `''`.
- [ ] Parity: disable/reconnect behaviour unchanged through the provider.

### Integration Tests

- [ ] `THarnessSession` registers the provider; a between-turns config change is
      reflected (replaces the Dynamic_Tools session test's direct call).

## Performance Targets

- One config read + O(servers) per turn.

## Security Considerations

- **No bypass:** the provider exposes tools; dispatch still routes through the
  approval engine (the handler asks, exactly as before).
- **No prompt contribution**, so MCP cannot inject instructions.

## Success Criteria

- [ ] MCP is a contributor; the loop has no MCP branch; behaviour parity holds;
      `make check` green.

## Future Considerations

- A second provider (skills) rides the same seam; nothing here changes.
- `PromptFragment` could carry server-provided hints later (out of scope: MCP
  servers do not supply prompt text today).
