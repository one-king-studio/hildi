# Scoping: TUI Startup + Lazy MCP

A scoping pass over the two features you want next, their shared cause, the
dependency chain, and a recommended order. Both are **Proposed** (FEATURE.md
only — no SPEC yet). Neither is implemented.

## The two features, in one line each

- **Lazy MCP** — stop connecting MCP servers on the runtime's *startup* path;
  make each configured connection a **skill** that connects on load. Removes the
  measured ~2 s cold-start cost and the "runtime did not start in time" launch
  failure.
- **TUI Startup** — paint a **connecting frame before** the TUI connects/spawns,
  and render the transcript **tail-first** (page older on scroll-up). The general
  safety net for any slow startup subsystem; covers the residual ~0.5 s after
  Lazy MCP plus the O(session) history load.

## They share one root cause and one ordering

Today `examples/tui_agent.pas` does, in order:

```
TSessionView.Open(store)  →  RemoteDriver(connect-or-spawn, BLOCKING)  →
TSurfaceVideo / TInputSourceTerminal  →  THarnessApp.Create  →
RenderHistory(all messages)  →  Run (first frame)
```

Two independent problems, both fixed by *reordering*:
1. **The runtime's socket doesn't exist until MCP finishes** — because
   `TSessionRuntime.Open` builds the session (`THarnessSession.Open` →
   `FMcp.Open`, `session.runtime.pas:279`) *before* `Serve` binds. So the client
   blocks on `RemoteDriver`. → **Lazy MCP** removes the cause.
2. **The TUI can't draw until the driver is attached** — the composition root
   connects before it has a surface. → **TUI Startup** makes it draw first.

Lazy MCP is the *cause*; TUI Startup is the *safety net*. The TUI Startup doc
says this explicitly ("`Lazy_MCP` removes the current 2 s cause; this feature
covers the residual").

## The dependency chain (this is the real finding)

Lazy MCP is **not** standalone — it is the last link of a chain that is *already
mostly built*:

```
Dynamic_Tools  ──►  Turn_Injection  ──►  Skills  ──►  Lazy_MCP
(MCP lifecycle)     (the seam)           (manifest)   (MCP = a skill)
```

- **Dynamic_Tools** — per-turn MCP reconcile, `TToolRegistry.Remove`, the
  `OnTurnStart` boundary hook, reconnect/backoff. **Implemented** (specs +
  all tasks ticked).
- **Turn_Injection** — the `IToolProvider` seam (`Prepare`/`Specs`/
  `PromptFragment`/`Find`); MCP moves behind it. **Implemented** (specs + all
  tasks ticked; the seam is live in `agent.pas:216`).
- **Skills** — the manifest with loaded/unloaded state, `load_skill`, decay by
  idle TTL. **Now Specified (`Skills_v1.SPEC.md` + `TODO.md`); no code yet.**
  This is the missing piece.
- **Lazy MCP** — "MCP servers are skills": a `load_skill("mcp_<id>")` connects +
  discovers + registers. Depends on Skills.

So **Lazy MCP cannot be built before Skills**, and **Skills** is the real next
piece — a whole feature, not a tweak.

## What's already true in the code (verified, not assumed)

- The `IToolProvider` seam exists: `agent.pas` `IToolProvider`, `AddProvider`,
  `PrepareProviders`, `OnTurnStart`, `BuildRequest` injects `PromptFragment`.
- `TMcpProvider` already implements `Prepare`/`Specs`/`PromptFragment`/`Find`
  (`mcp.client.pas:184`); today `PromptFragment` returns `''` and `Prepare`
  reconciles (connects) — exactly the seam Lazy MCP fills in.
- `TToolRegistry.Remove` and MCP backoff/reconcile exist.
- The *ordering bug* is real and located: `session.runtime.pas:279`
  (`THarnessSession.Open`, which calls `FMcp.Open` at `harness.session.pas:302`)
  runs inside `TSessionRuntime.Open`, before `Serve` (called at
  `session.runtime.pas:1607`).

## Recommended order

**Option A — TUI Startup first (independent, shippable now).**
TUI Startup does **not** depend on Skills or Lazy MCP; it depends only on the
composition root, `THarnessApp`, the driver, and the view. It is self-contained
and delivers visible value (no blank screen, visible failure, tail-first
history) *without* the chain. It also builds the **back-pagination primitive**
that `Context_Handoff` reuses.
- Risk: the residual cost it covers is smaller once Lazy MCP lands, but the
  blank-screen/failure-mode fixes stand alone. The doc already frames it as the
  general net.

**Option B — Skills first, then Lazy MCP, then TUI Startup.**
Follows the dependency chain strictly and lands the biggest single win (Lazy
MCP) sooner *if* Skills is small. But Skills is a full feature (manifest,
`load_skill`, decay, namespacing, the system-prompt copy) — realistically larger
than TUI Startup, and it unblocks nothing else on the critical path.

**My recommendation: A, then Skills → Lazy MCP.** TUI Startup is the smaller,
independent, immediately-visible win and yields the reusable back-pagination
primitive; then take the chain. It also means a slow MCP start is already
*survivable* (visible, in-app) before we optimise it away.

## Scope estimate (rough, TDD-first, one commit per step)

| Feature | Depends on | Size | Notes |
| --- | --- | --- | --- |
| **TUI Startup** | driver, app, view (all exist) | **M** | composition-root reorder; app connecting/failed state; tail-first history + scroll-up paging; ~4–6 steps + tests |
| **Skills** | Turn_Injection seam (exists) | **L** | new `hildegard.helper.skills` unit; manifest fragment; `load_skill` tool; decay timer at turn boundary; namespacing; system-prompt copy; SPEC + TODO |
| **Lazy MCP** | **Skills** | **S–M** | move `FMcp.Open` off startup; make `TMcpProvider.PromptFragment` return the manifest; `load_skill` triggers connect/discover; TTL unload. Small *because* the seam and manager already exist |

## Risks / decisions to settle before speccing

1. **Two open questions Lazy MCP itself flags** (must reconcile before its SPEC):
   - **Namespace**: `mcp_<id>_<tool>` (Lazy MCP/Skills) vs `mcp/<server>/<tool>`
     (Dynamic_Tools). Pick one — it's part of the approval `ref`.
   - **Skills is a prerequisite with no SPEC.** Either write the Skills SPEC
     first, or fold a minimal "manifest + load_skill" subset into Lazy MCP's SPEC
     (riskier — the decay/lifetime semantics are load-bearing).
2. **TUI Startup open questions** (from its doc): connecting-state content,
   page size, first-window size, where the connecting state renders.
3. **Don't regress the socket-is-the-lease model**: Lazy MCP must keep
   "readiness = protocol up", not "optional subsystems finished".
4. **Process Split**: TUI Startup touches only client-side units; keep the TUI
   free of agent/runtime units (there's a test asserting the closure).

## What I'd write next (pick one)

- **A1** — SPEC + TODO for **TUI Startup** (self-contained; recommended first).
- **B1** — SPEC + TODO for **Skills** (unblocks Lazy MCP).
- **A2** — also finalize the two already-implemented prerequisites'
  docs (`Dynamic_Tools`, `Turn_Injection`: all tasks ticked but TODOs not renamed
  to DONE and FEATURES still says "not yet implemented" — same stale-doc pattern
  I fixed for TUI Widgets/Harness UI).

## Footnote: stale docs found during this pass (resolved)

`Dynamic_Tools`, `Turn_Injection`, and `Runtime_Lifecycle` had **all tasks
ticked** and their code present, yet their `TODO.md` files were not renamed to
`DONE.md` and `FEATURES.md` still said **"not yet implemented"** (or listed them
as Parked). Reconciled: all three now appear in the main table as
**Implemented**, and the two remaining `TODO.md` files were renamed to `DONE.md`.
Their dependents (Skills, Lazy MCP) may now cite them as done.
