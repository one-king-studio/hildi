# Component Specification: Lazy MCP v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `Skills` (`TSkillRegistry`, `ISkillToolSource`, `TSkill`),
`hildi.mcp.client` (`TMcpManager`, `TMcpClient`, `TMcpServerRuntime`,
`McpToolName`, `McpRef`, `TMcpProvider`), `hildi.harness.session`
(`Init`, the provider registration), `hildi.session.runtime`
(`Open` vs `Serve`).

**Depended on by:** the `TUI_Startup` budget (a fast socket), the remote-MCP
requirement (`Dynamic_Tools`).

## Purpose

Make MCP **lazy**: a configured server is a *skill* advertised in the manifest
but **not connected** until loaded. Nothing about MCP is on the runtime's startup
path, so the socket binds and greets immediately; a slow or broken server becomes
a per-load error instead of a failed launch; and a server's tools cost nothing
until the turn that uses them.

This is a re-ordering, not a rewrite: `TMcpManager`, `TMcpClient`, the
transports, OAuth, and approvals all stay. What changes: `FMcp.Open` leaves the
startup path, and each server becomes a `ISkillToolSource` the `TSkillRegistry`
loads on demand.

## Prior art and reuse

| Need | Existing unit | What changes |
| --- | --- | --- |
| Connect + discover one server | `TMcpClient` (`Open`, `Refresh`, `Specs`, `Find`, `Close`) | none — wrapped by a skill source |
| Per-server lifecycle, backoff, reconcile | `TMcpManager` (`Reconcile`, `CloseRuntime`, `OpenRuntime`, backoff) | `Reconcile` no longer *opens* disabled-by-default servers; opening becomes explicit (on load) |
| Tool naming | `McpToolName` = `mcp_<server>_<tool>`; `McpRef` = `mcp:<server>:<tool>` | **ref separator** aligned to the other families (`:`); see Naming |
| The provider seam | `TMcpProvider` (`IToolProvider`) | **replaced** by a per-server `ISkillToolSource` under the registry |
| Manifest / load / decay | `hildi.skills` (`TSkillRegistry`, `ISkillToolSource`) | the registry is the new home; MCP is its first source |
| Startup ordering | `TSessionRuntime.Open` (builds session, then `Serve` binds) | `THarnessSession.Init` stops calling `FMcp.Open` |

No new MCP machinery; the change is *where* the connect is triggered.

## Requirements

### Functional

- [ ] The runtime **does not connect any MCP server before it binds and serves**
      the socket. `THarnessSession.Init` no longer calls `FMcp.Open`.
- [ ] Each **enabled, configured** connection appears in the skill manifest with
      its key, a **curated** description and when-to-use. Server-authored text
      (MCP `initialize.instructions`) is **never** used.
- [ ] `load_skill("<mcp key>")` connects the server, runs `tools/list`, and
      registers its tools; the load result reports the tool names.
- [ ] A slow, unreachable, or unauthorized server returns a **structured error**
      from the load; the turn continues and the socket is unaffected.
- [ ] A tool call on a loaded server succeeds and its result reaches the model
      (the existing `TMcpClient.CallTool` path, approval-gated as today).
- [ ] A loaded server is kept alive by use and **unloaded after its idle TTL**
      (`Skills` decay): the connection is closed and the manifest reports
      `unloaded`.
- [ ] A connection added, enabled, or removed while the runtime runs is reflected
      in the manifest at the next turn boundary, without a restart (the manager's
      reconcile survives; only *opening* is deferred).
- [ ] With no skill loaded, the request carries **no** MCP tools.
- [ ] A configured server may be **preloaded** at session start when the operator
      asks (`--mcp <key>` / an operator `load_skill`), so the round trip is
      optional, not required.

### Non-Functional

- [ ] Runtime spawn → socket accepts ≤ 100 ms with MCP configured (from ~2 s).
- [ ] Zero "runtime did not start in time" failures attributable to MCP.
- [ ] Connect + discover for a healthy server completes within a bounded time
      (target < 3 s); a failure is bounded by the client's own timeout.
- [ ] No idle connections linger: a server (e.g. a container) exists only while
      its skill is active.
- [ ] No leaks (heaptrc gate); `make check` green; macOS and Linux; FPC 3.3.1.
- [ ] The Process Split is preserved.

## Contracts & Interfaces

> Pascal type declarations; bodies are the implementer's.

### A server as a skill source

```pascal
unit hildi.mcp.client;   // additions

uses hildi.skills;

type
  { One configured MCP server as a skill tool source. Owns its TMcpClient via
    the manager; Activate connects + discovers, Deactivate closes. The registry
    calls Deactivate only on a source it Activated. }
  TMcpSkillSource = class(TInterfacedObject, ISkillToolSource)
  public
    constructor Create(AManager: TMcpManager; const AServer: TMcpServerConfig);
    function Activate(out AError: string): Boolean;
    procedure Deactivate;
    function Specs: TToolSpecArray;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    { The skill declaration for this server (key/description/when-to-use),
      curated, never server-authored. }
    function Declaration: TSkill;
  end;

  { Build the registry's MCP skills from the effective config: one TSkillSource
    per enabled server. Called at Init and re-called at each turn boundary so
    add/enable/remove is picked up. }
  procedure RegisterMcpSkills(const ARegistry: TSkillRegistry;
    const AConfig: TMcpConfig; AManager: TMcpManager);
```

### The skill key (stable, part of the approval ref)

```text
key          mcp_<server>            (snake_case; McpSanitize(server name))
tool name    mcp_<server>_<tool>     (McpToolName - already the code's scheme)
approval ref mcp:<server>:<tool>     (McpRef; colon-separated like the others)
```

- The key is derived from the server **name** (stable); renaming a server orphans
  its approvals — documented, treated as stable.

### Startup ordering (`THarnessSession.Init`)

```text
before   Init: FMcp := TMcpManager.Create(...); FMcp.Open;   <-- eager connect
after    Init: FMcp := TMcpManager.Create(...);              <-- no connect
         the registry declares one skill per enabled server (unloaded)
         on load_skill("mcp_<key>") -> source.Activate -> connect + discover
```

- `TSessionRuntime.Open` builds the session (no MCP connect) and `Serve` binds
  immediately; the client's `RemoteDriver` connects at once.

## Data flow

- **Startup**: the manager is constructed (no I/O); the registry declares the
  MCP skills (unloaded); the manifest lists them; `Serve` binds. No server is
  touched.
- **Manifest**: the registry's `PromptFragment` includes the `mcp_<key>` lines
  with curated metadata and `unloaded` state.
- **Load**: `load_skill("mcp_<key>")` → `TMcpSkillSource.Activate` →
  `TMcpManager.OpenRuntime` (spawn/handshake/`tools/list`) → specs registered;
  the result names the tools.
- **Use**: a `mcp_<key>_<tool>` call resolves via the source's `Find` →
  `TMcpClient.CallTool` (approval-gated), and resets the skill's idle timer.
- **Decay**: after the TTL, the registry unloads the skill → `Deactivate` →
  `TMcpManager.CloseRuntime`; the manifest shows `unloaded`.
- **Reconcile**: at each turn boundary the registry re-reads the config and
  re-declares skills (add/enable/remove), without opening anything.

## Validation and error handling

- **Load failure** (timeout, unreachable, unauthorized, protocol error): the
  source's `AError` is returned as the skill load's structured error; the skill
  stays unloaded; no tools are added; the socket and the turn are unaffected.
- **Load of a removed server**: `unknown skill: mcp_<key>`.
- **A dead server mid-turn**: the existing `TMcpClient.Dead` + manager backoff
  apply on the next load; the turn's current call returns the existing error.
- **Reconcile never throws**: the manager's reconcile is already guarded.

## Testing strategy

What must be covered (the tester chooses how; a fake MCP server/transport and a
fake manager):

- `Init` does not call `FMcp.Open` (a spy manager records no connect before
  `Serve`).
- The manifest lists one `mcp_<key>` entry per enabled server, `unloaded`, with
  curated metadata; a disabled server is absent.
- `load_skill("mcp_<key>")` connects (a spy manager records `OpenRuntime`),
  registers the tools, and reports the names; a slow/failing server returns the
  structured error and changes nothing.
- A loaded server's `mcp_<key>_<tool>` call resolves and reaches the model.
- After the TTL, the skill unloads (`CloseRuntime` called) and the manifest shows
  `unloaded`.
- Add/enable/remove a server between turns → the manifest reflects it without a
  connect.
- With no skill loaded, `Specs` carries no `mcp_` tools.
- No leak: load then unload releases the client and its tools.

## Performance

- Startup touches no server: the socket binds in ~30 ms (the measured no-MCP
  cost).
- A healthy load is one spawn + handshake + `tools/list`, bounded by the client's
  timeouts; a failure is bounded by the same.
- The manifest cost is one line per configured server (constant), independent of
  whether it is loaded.

## Open questions (settle at implementation)

1. **Namespace — two strings, on purpose (do not merge them).** The code already
   uses both and they serve different consumers:
   - **Tool name** `mcp_<server>_<tool>` (`McpToolName`) — what the **model**
     sees. Constrained: `McpSanitize` lowercases and maps non-`[a-z0-9_-]` to
     `_`, and the result is truncated to `MaxToolNameChars` (64). It is
     **collision-resolved** (`McpUniqueToolName` appends `_2`, `_3`…) and can
     therefore **change**.
   - **Approval ref** `mcp:<server>:<tool>` (`McpRef`) — what the **approval
     engine** keys on. An opaque, stable identity with no charset/length limit,
     **colon-separated** like every other approval family (`run_command:<bin>`,
     `file:read`, `subagent:<verb>`) so the scheme is uniform.

   They must stay separate: an approval rule matches on **exact `Ref` equality**
   (`approval.pas`), so a ref derived from the sanitized, collision-renamed,
   truncated name would **orphan or mis-apply a persisted grant** (two servers
   `MyServer`/`myserver`, or two long names truncated at 64, could alias; a
   collision-renamed name would move the ref). The ref keeps the *original*
   server/tool identity, with a sanitized `:` separator. (This supersedes the
   FEATURE's open question 3.)
2. **TTL** — reuse `Skills`' default (10 min), overridable per server (a stdio
   container vs an HTTP endpoint). Default: per-server from the row, else the
   registry default.
3. **`whenToUse` source** — curated template by known service name, operator
   override; required for MCP (per `Skills`).
4. **Explicit operator load in v1** — yes, `--mcp <key>` preloads; the model may
   also `load_skill`.
5. **Preload semantics** — a preload activates the skill before the first turn
   (a connect on the startup path *by explicit request*), which is acceptable
   because it is opt-in and not the default.
