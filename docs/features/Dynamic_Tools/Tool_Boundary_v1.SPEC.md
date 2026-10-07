# Component Specification: Tool Boundary v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.agent` (`TAgentLoop`, `TToolRegistry`).
**Depended on by:** `Mcp_Lifecycle_v1.SPEC.md` (reconcile rides the hook).

## Purpose

Give the loop a **boundary hook** and give the registry a **removal**, so a
tool source can add and remove tools between turns without racing the loop.
Two small primitives, both generic — nothing MCP-specific here.

The loop already rebuilds its tool list every request (`Result.Tools :=
FTools.Specs`), so *reads* are live; what is missing is a safe point to *mutate*
the registry and a way to remove a tool.

## Requirements

### Functional

- [ ] `TAgentLoop` exposes an `OnTurnStart` hook, invoked **once at the start of
      each turn**, on the loop's own thread, before the first request is built.
- [ ] `TToolRegistry.Remove(const AName: string): Boolean` removes the tool with
      that name and returns whether it was present. Removing an absent tool is a
      no-op returning False (not an error).
- [ ] Removal preserves order/identity of the remaining tools.
- [ ] The hook is optional (nil = no-op) and must not raise into the loop: an
      exception from a hook is caught, logged as a turn error is **not** desired
      here — the hook's owner handles its own errors (see Mcp_Lifecycle).

### Non-Functional

- [ ] No new dependency; no change to the request-building path beyond calling
      the hook once.
- [ ] `make check` green.

## Contracts & Interfaces

```pascal
unit hildegard.helper.agent;   // additions only

type
  { Invoked once at the start of a turn, on the loop's thread, before the first
    request. The owner may mutate the tool registry here; the loop snapshots the
    registry per request, so a boundary mutation is race-free. }
  TAgentBoundaryEvent = procedure of object;

  TAgentLoop = class
    // ... existing ...
    { Optional; called once per turn. Nil = no-op. }
    property OnTurnStart: TAgentBoundaryEvent read FOnTurnStart write FOnTurnStart;
  end;

  TToolRegistry = class
    // ... existing ...
    { Remove a tool by name. True when it was present. }
    function Remove(const AName: string): Boolean;
  end;
```

### Data Contracts

- **Invocation point.** The hook fires inside `TAgentLoop.Send` (or the method
  that opens a turn) exactly once, before the first `Complete`/request build, on
  the calling thread. It does **not** fire per request.
- **Reentrancy.** The hook may call `Add`/`Remove` on the same registry the loop
  uses; it must not call back into `Send`.
- **`Remove` semantics.** Matches by exact `Spec.Name`. The registry compacts the
  remaining entries; `Count` and `Specs` reflect the change immediately.

### Event Contracts

- `TAgentBoundaryEvent` runs on the loop's thread (the worker thread for a
  `TTurnWorker`-driven turn). A hook that touches UI state must marshal itself;
  a hook that touches the registry or the store may run inline.

## Architecture

### Prior Art & Reuse

- **`TAgentLoop.CancelCheck`** is the exact precedent: an optional
  `function: Boolean of object` consulted at a boundary, on the loop's thread.
  `OnTurnStart` mirrors its shape and lifetime.
- **`Result.Tools := FTools.Specs`** (per request) already makes reads live;
  this SPEC only adds the mutation point and the removal.
- **Genuine gap:** `TToolRegistry` has `Add` only; there is no `Remove`.

### Component Boundaries

- **Responsibilities:** the hook field and its single call site; `Remove`.
- **Dependencies:** none new.
- **Side effects:** `Remove` mutates the registry (loop thread, at a boundary).

## Validation Rules

### Input

- `Remove('')` returns False (no empty-named tool exists).

### Output Guarantees

- After `Remove(N)`, `Find(N)` is False and `Count` is one lower.

## Error Handling

- `Remove` never raises; absent name ⇒ False.
- The hook itself is the caller's responsibility; `TAgentLoop` invokes it
  directly (the owner wraps its own failures — see Mcp_Lifecycle's "log and
  continue").

## Testing Requirements

### Unit Tests (`tests/test_agent.pas` additions)

- [ ] `Remove` of a present tool returns True and the tool is gone; `Count`
      decrements.
- [ ] `Remove` of an absent tool returns False; `Count` unchanged.
- [ ] `OnTurnStart` fires exactly once per `Send`, before the request is built
      (assert via a probe hook that adds a tool, then the request's tool list
      includes it).
- [ ] A nil `OnTurnStart` is a no-op.

### Integration Tests

- [ ] Exercised by `Mcp_Lifecycle`'s reconcile tests.

## Performance Targets

- One extra procedure call per turn; `Remove` is O(n) over a tiny array.

## Security Considerations

- None beyond the registry's existing contract. The hook is a trusted in-process
  callback; it is not a model-reachable surface.

## Success Criteria

- [ ] All contracts implemented; `make check` green; no leaks.

## Future Considerations

- **Per-request** hook (`OnRequestBoundary`) is a one-line widening if mid-turn
  reconcile is ever wanted.
- A hook *result* (e.g. "tools changed") could let the loop skip a request; not
  needed for v1.
