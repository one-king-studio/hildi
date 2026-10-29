# Component Specification: Turn Assembly v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildi.agent` (`TAgentLoop`, `TToolRegistry`,
`BuildRequest`, `ExecuteToolCalls`).
**Depended on by:** `Mcp_Provider_v1.SPEC.md` (MCP becomes a contributor).

## Purpose

Give the loop a **contributor seam** and make it **assemble each turn's tools
and prompt** from the base registry plus every contributor. This is the generic
mechanism; MCP and (later) skills are contributors.

Two assembly points already exist and are reused: `BuildRequest` (sets
`Result.Messages` and `Result.Tools`) and `ExecuteToolCalls` (resolves a called
name via `FTools.Find`).

## Requirements

### Functional

- [ ] A contributor interface `IToolProvider` with `Prepare`, `Specs`,
      `PromptFragment`, `Find`.
- [ ] `TAgentLoop.AddProvider(const AProvider: IToolProvider)` (registration
      order = call order). Zero or more.
- [ ] At turn start, `TAgentLoop` calls `Prepare` on each provider in order (the
      existing `OnTurnStart` call site). `Prepare` may reconcile/activate.
- [ ] `BuildRequest` composes `Result.Tools` from `FTools.Specs` **plus** each
      provider's `Specs`, in registration order; a provider contributing no tools
      adds nothing.
- [ ] `BuildRequest` injects each non-empty `PromptFragment` as a **request-only**
      `crSystem` message (after the base system message, before the first user
      message), never appended to `FStore`.
- [ ] `ExecuteToolCalls` resolves a called name via `FTools.Find` first, then
      each provider's `Find` in order; first match wins. Unknown ⇒ the existing
      error path.
- [ ] The existing `OnTurnStart` hook remains (it is the call site); providers
      are *additional* to it (a session may use either).

### Non-Functional

- [ ] No dependency added; `make check` green.
- [ ] Assembly is on the loop's thread; no shared mutable state races dispatch.
- [ ] Request-only injection leaves `FStore` unchanged.

## Contracts & Interfaces

```pascal
unit hildi.agent;   // additions

type
  { A per-turn source of tools and prompt. Prepare is called once at turn start
    on the loop's thread; Specs/PromptFragment/Find are read while assembling the
    request. Implementations need not be thread-safe: they run on the loop's
    thread only. }
  IToolProvider = interface
    { Called once at the start of each turn, in registration order. Reconcile or
      activate here. A provider that contributes nothing is a no-op. }
    procedure Prepare;
    { The tools this provider currently offers (already reason-augmented specs
      when it uses the registry's conventions). }
    function Specs: TToolSpecArray;
    { A request-only prompt fragment, or '' for none. Never persisted. }
    function PromptFragment: string;
    { Resolve a called tool name to a handler. First provider to return True
      wins. }
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
  end;

  TAgentLoop = class
    // ... existing ...
    procedure AddProvider(const AProvider: IToolProvider);
  end;
```

### Data Contracts

- **Tool composition.** `Result.Tools := Concat(FTools.Specs, Provider[0].Specs,
  …)` in registration order. Duplicate names are the provider's problem (MCP
  namespaces with `mcp_<server>_`); the loop does not dedupe.
- **Dispatch.** `FTools.Find` first (native tools keep priority), then providers
  in order. This preserves the current behaviour where a native tool name always
  resolves to the native tool.
- **Prompt injection.** For each provider with a non-empty fragment, insert a
  `crSystem` message into `Result.Messages` only. Placement: immediately after
  any leading `crSystem` message(s) and before the first non-system message, so
  the injected context reads as system guidance. Fragments are joined in
  registration order; each is its own message (so provenance is visible in the
  request), or concatenated — SPEC pins **separate messages**.
- **No persistence.** Injection never calls `FStore.Append*`. On the next turn
  the fragment is re-injected from the provider, so there is no duplication.

### Event Contracts

- None new. `Prepare` runs on the loop's thread, before `BuildRequest`.

## Architecture

### Prior Art & Reuse

- **`BuildRequest`** already assembles `Result.Messages` (store messages + a
  request-only continuation) and `Result.Tools` (`FTools.Specs`); the provider
  composition slots into both.
- **`ExecuteToolCalls`** already resolves via `FTools.Find`; the provider lookup
  is added after it.
- **`OnTurnStart`** (Dynamic_Tools) is the call site for `Prepare`.
- **Genuine gap:** the provider interface and the composed assembly.

### Component Boundaries

- **Responsibilities:** provider registration, `Prepare` dispatch, tool/prompt
  composition, provider-aware dispatch.
- **Dependencies:** none new.
- **Side effects:** none on `FStore`; providers may spawn/reconcile externally.

## Validation Rules

### Input

- `AddProvider(nil)` is ignored.
- A provider returning a spec with an empty `Name` contributes nothing (mirrors
  `TToolRegistry.Add`).

### Output Guarantees

- The request's tool list contains every base tool and every provider tool.
- The request's messages contain the base history plus (only) the non-empty
  fragments; `FStore.Messages` is unchanged by assembly.

## Error Handling

- A `Prepare`/`Specs`/`Find` that raises is caught per provider and logged as a
  turn error is **not** desired; the SPEC pins: a provider exception during
  assembly is caught, the provider is skipped for that turn, and the turn
  proceeds (a broken provider never wedges the loop).

## Testing Requirements

### Unit Tests (`tests/test_agent.pas` additions)

- [ ] A stub provider's `Specs` appear in the request's tool list alongside the
      base tools.
- [ ] `Prepare` is called once per turn, in registration order.
- [ ] A non-empty `PromptFragment` appears in the request messages (as a
      `crSystem` message) and **not** in `FStore.Messages`.
- [ ] A called provider tool dispatches to the provider's handler; a native tool
      still resolves to the native handler (priority).
- [ ] Two providers: first-registered wins on a name clash in `Find`.
- [ ] A provider that raises in `Specs` is skipped; the turn completes.

### Integration Tests

- [ ] The MCP provider (see `Mcp_Provider_v1`) registers and dispatches through
      this seam (session test).

## Performance Targets

- O(providers × tools) per turn; providers with no change do no work.

## Security Considerations

- **Prompt injection is operator/agent-controlled:** providers are registered in
  code/config; the model cannot register one. Fragments are request-only and
  never persisted, so injection cannot rewrite history.
- **Tools stay gated:** a contributed tool is resolved and executed through the
  same path as a native tool, including its approval ask.

## Success Criteria

- [ ] All contracts implemented; `make check` green; no leaks.
- [ ] MCP rides the seam (Mcp_Provider_v1); a future skill provider needs no
      loop change.

## Future Considerations

- Per-request assembly (currently per-turn).
- Provider ordering/priority as an explicit field.
- A provider contributing a fragment with **no** tools (pure context).
