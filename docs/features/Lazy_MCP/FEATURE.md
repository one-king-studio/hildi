# Lazy MCP

## Overview

MCP servers are connected **at runtime startup**: `THarnessSession.Init` calls
`FMcp.Open`, which synchronously spawns or connects every configured server —
and this happens inside `TSessionRuntime.Open`, **before** `Serve` binds the
socket. So the socket the client waits for does not exist until every MCP server
has finished connecting.

Measured on a 906-message session with the current config, the TUI's first output
arrives at **2.06 s** versus **0.056 s** with MCP removed. With timeouts up to
`DefaultMcpListTimeoutMs = 10 s` and a client `DefaultSpawnTimeoutMs = 5 s`, a
single slow server does not merely lag — it makes the TUI fail with *"runtime did
not start in time"*.

This feature makes MCP **lazy**: a configured server is a *skill* (`Skills`),
advertised by name and description but **not connected** until the model (or the
operator) loads it. Nothing about MCP is on the startup path, and its tools are
paid for only in the turn that uses them.

## Problem Statement

Three costs, one cause — MCP is wired as a startup subsystem instead of an
on-demand capability:

1. **Startup latency.** Every cold start pays every server's connect + discovery.
   The observed config spawns `docker run … mcr.microsoft.com/playwright/mcp`
   (0.42 s) and connects `https://…/mcp` (0.46 s) before the socket is bound.
2. **A launch failure mode.** The MCP budget (10 s/server) exceeds the client's
   spawn budget (5 s), so a slow or hanging server aborts the launch.
3. **Permanent tool-surface cost.** Connected servers contribute their tools to
   every request, whether or not they are used (see `Skills`).

Who feels it: the operator, on every cold start, intermittently — fast when the
runtime is still alive, slow (or failing) after it idle-exits.

## Decision

**MCP servers are skills. Connect on load, not at startup.**

- **No connection at session open.** `THarnessSession.Init` no longer opens the
  manager's connections; the runtime binds and serves without touching MCP.
- **Each configured connection is a skill** in the manifest (`Skills`), keyed
  `mcp_<id>` (`<id>` a unique snake_case identifier), with a **description and a
  when-to-use hint**. That metadata is **user/curated, never server-authored** — a
  server's `initialize.instructions` must never reach the manifest.
- **Loading connects.** `load_skill("mcp_<id>")` connects, runs `tools/list`, and
  registers the tools (`mcp_<id>_<tool>`) for as long as the skill is active.
- **Lifetime is decay.** The connection is kept alive while the skill is used and
  unloaded once it is idle past its TTL (`Skills`); the manifest reports the state,
  so a reload is explicit rather than surprising.
- **The seam is `Turn_Injection`'s.** MCP is a contributor: it offers its manifest
  and, while a skill is active, its tools. It does not add a second seam.
- **A load failure is local.** A slow, unreachable, or unauthenticated server
  returns a structured error for that load; it never delays the socket and never
  aborts the turn.
- **Servers remain reconcilable.** Adding/removing a connection is still picked up
  at a turn boundary (the manager's reconcile survives), so no restart is needed.

### Shape (the SPEC formalizes it)

```text
startup   TSessionRuntime.Open does not connect MCP; Serve binds and greets first
manifest  one skill entry per configured connection: name + description + whenToUse
load      load_skill("mcp_<name>") -> connect -> tools/list -> register (namespaced)
lifetime  kept alive by use; unloaded after an idle TTL; the state is in the manifest
errors    connection_failed / not_connected / ... returned to the model, not thrown
```

## Goals

- A runtime's socket is available independent of MCP server latency.
- A slow or unreachable MCP server can never cause a failed launch.
- MCP tools cost nothing until the turn that loads them.
- MCP servers remain first-class: discoverable, loadable, callable, reconcilable.
- Adding an MCP server requires no harness change (it is a skill entry).

## Non-Goals

- The MCP wire protocol, transports, OAuth, or approval model.
- Removing or making MCP opt-in (servers stay configured; they are just lazy).
- The skill mechanism itself (`Skills`).
- A connection UI (a later surface).
- Windows.

## User Stories

- As an **operator**, I want to start a session without waiting for MCP servers, so
  startup is predictable whether or not I have connections configured.
- As an **operator**, I want a broken MCP server to be a message, not a failed
  launch.
- As an **operator**, I want to use an MCP server by naming it, without waiting for
  the model to discover it.
- As a **harness author**, I want MCP to be one skill provider, so adding a
  connection never touches the runtime's startup.
- As a **harness author**, I want no idle MCP connections holding processes open.

## Acceptance Criteria

### Functional Requirements

- [ ] The runtime does **not** connect any MCP server before it binds and serves
      the socket.
- [ ] Each configured connection appears in the skill manifest with a curated (or
      operator-set) description and when-to-use; server-authored text is never
      used for either.
- [ ] `load_skill("mcp_<id>")` connects, discovers tools, registers them as
      `mcp_<id>_<tool>`, and reports the tool names.
- [ ] Loading a slow, unreachable, or unauthorized server returns a structured
      error; the turn continues and the socket is unaffected.
- [ ] A tool call on a loaded server succeeds and its result reaches the model.
- [ ] A loaded server is kept alive by use and unloaded after its idle TTL; the
      manifest then reports it unloaded.
- [ ] A connection added or removed while a runtime is running is reflected at the
      next turn boundary without a restart.
- [ ] With no skill loaded, the request carries no MCP tools.

### Non-Functional Requirements

- [ ] Cold start to first frame is unaffected by the MCP configuration (target:
      the `TUI_Startup` budget).
- [ ] A runtime's socket accepts a connection within a small bound of process
      start, independent of MCP (target ≤ 100 ms).
- [ ] Connect + discover for a healthy server completes within a bounded time
      (target < 3 s), and a failure is bounded by the client's own timeout.
- [ ] No idle connections linger: a connection is closed after its idle TTL, so no
      server process (e.g. a container) outlives its usefulness.
- [ ] No leaks (the heaptrc gate); `make check` passes; macOS and Linux, FPC 3.3.1.

## Success Metrics

### Quantitative

- Runtime spawn → socket accepts: ≤ 100 ms with MCP configured (from ~2 s).
- TUI first output: unchanged by the number of configured MCP servers.
- Zero "runtime did not start in time" failures attributable to MCP.
- No MCP tools in the request until a load.

### Qualitative

- An operator cannot tell, at startup, whether MCP is configured.
- A broken MCP server reads as a per-load error, not a launch failure.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- The runtime's socket-is-the-lease model (`Headless_Sessions`) is preserved:
  readiness means "the protocol is up", not "optional subsystems finished".
- The MCP manager's reconcile/backoff behaviour is retained; only *when* a
  connection is opened changes.
- Tool names are namespaced (`mcp_<server>_<tool>`); the approval ref is
  `mcp:<server>:<tool>` (colon-separated like every other family). The namespace is part of the
  approval `ref`, so it must stay stable.
- The manifest is a stable system fragment (`PromptFragment`), never persisted.

### Business / Time

- No deadline. `main` only, TDD-first, one logical commit per step.

## Dependencies

### Internal

- `hildegard.helper.harness.session` — `Init` / `FMcp.Open` (the thing that moves).
- `hildegard.helper.session.runtime` — `Open` vs `Serve` ordering.
- `hildegard.helper.mcp.client` — `TMcpManager`, `TMcpProvider`,
  `Reconcile`/`OpenRuntime`, `Specs`/`Find`.
- `hildegard.helper.mcp.config` / `.store` — the connection rows.
- `hildegard.helper.agent` — `IToolProvider`, `load_skill`, the turn boundary.
- `docs/features/Skills/FEATURE.md` — the mechanism this is the first provider
  for; `docs/features/Turn_Injection/FEATURE.md` — the contributor seam.

### External

- `docker` (the operator's MCP server), TLS (already vendored). No new dependency.

## Risks

- **The model may not load the server it needs.** Mitigation: the manifest is
  always present; the operator can load by name; the error is actionable.
- **A server-authored description is a prompt-injection vector.** Mitigation:
  descriptions/when-to-use are curated or operator-set; `initialize.instructions`
  is never surfaced.
- **Connection lifetime.** Closing per turn costs a reconnect per use; keeping
  alive holds processes. Mitigation: decide a bounded keep-alive, and make it
  observable; default to close-at-turn-end.
- **Concurrent loads.** Two loads of the same server in one turn, or a load during
  a turn boundary, must not double-connect or leak. Mitigation: the manager is the
  single owner of a connection; loads are idempotent per turn.
- **Namespacing drift.** Renaming a server orphans approvals keyed on the old
  namespace. Mitigation: document the scheme; treat the name as stable.
- **Silent failures.** A failed load that the model ignores looks like "MCP does
  not work". Mitigation: the error is structured and the session records it.

## Out of Scope

- MCP protocol/transport/OAuth/approval changes.
- Making MCP opt-in or removing configured servers.
- The skill registry/manifest machinery (`Skills`).
- A connections UI.
- Windows.

## Future Considerations

- **Preload** — load a named server at session start when the operator asks for it
  (`--mcp notion`), avoiding the round trip.
- **Keep-alive tuning** — reuse a connection across rapid turns.
- **Health probe** — a background, non-blocking status per connection for the UI.
- **Resource/prompt capabilities** — beyond tools, on the same load.

## Open Questions

1. **TTL default for an MCP connection** — one value, or per server (a stdio
   container vs an HTTP endpoint)?
2. **Where does `whenToUse` come from** — a curated template by known service
   name, the operator, or both? (The main project curates by name and lets the
   user override.)
3. **Namespace vs `Dynamic_Tools` — resolved.** Both now agree: the tool name is
   `mcp_<server>_<tool>`, and the approval ref is `mcp:<server>:<tool>`
   (colon-separated, matching `run_command:<bin>` / `file:read` / `subagent:<verb>`).
   `McpRef` was aligned from the older `mcp/<server>/<tool>` to the colon form;
   nothing parses refs and MCP grants never persist, so there is no migration.
4. **Does the operator get an explicit load** (a CLI flag / TUI command) in v1, or
   is model-initiated load enough?

## Notes

- **This is a re-ordering, not a rewrite.** `TMcpManager`, `TMcpClient`, the
  transports, OAuth, and approvals all stay. What changes: `FMcp.Open` moves off
  the startup path, the provider advertises a manifest instead of a live tool
  list, and a `load_skill` call triggers the connect/discover that used to happen
  eagerly.
- **The seam exists.** `TMcpProvider` already implements `Prepare` / `Specs` /
  `PromptFragment` / `Find`; today `PromptFragment` returns `''` and `Prepare`
  reconciles (connects). The redesign fills in the fragment and defers the
  connect.
- **The measured baseline.** A runtime with no MCP connects in ~30 ms, so the
  socket cost is entirely MCP.
- **A side effect worth noting:** today each live runtime holds a
  `mcr.microsoft.com/playwright/mcp` container up; lazy loading means a container
  exists only while its skill is active.
- **ICE score.** Impact 8 (removes the regression and the failure mode),
  Confidence 9 (measured cause, small change), Ease 7 (an ordering change plus the
  manifest/load wiring). Priority: high.
- **Related:** `docs/features/Skills/FEATURE.md` (the mechanism),
  `docs/features/Turn_Injection/FEATURE.md` (the contributor seam),
  `docs/features/Dynamic_Tools/FEATURE.md` (the MCP reconcile this builds on),
  `docs/features/TUI_Startup/FEATURE.md`.
