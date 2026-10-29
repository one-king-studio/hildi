# MCP Client

## Overview

The Model Context Protocol (MCP) is the emerging standard for exposing tools
to AI clients: any MCP server's tools become available to the helper's agent
loop without the helper implementing them. This feature makes the helper an
**MCP client** — it connects to MCP servers, adopts their tools into the
existing `TToolRegistry`, and dispatches calls through the existing
approvals, ledger, and reason gates.

Deliberate scope split, and the reason the door opens in one direction:
the helper is a **consumer** of MCP tools, not an MCP **server**. As a
server, the helper would expose its own tools to *other* AI clients whose
loops and trust models live elsewhere — bypassing the local approvals engine
while keeping its liability. As a client, every MCP tool gained flows through
the machinery the project spent its trust-model rebuild building: ref-scoped
approvals, the ledger, the required-reason contract.

Two transports, two phases:

- **v1: stdio** — MCP servers are child processes; JSON-RPC over
  stdin/stdout. No network, no TLS, no OAuth, and no new dependency. The
  majority of MCP servers ship this way. The child-process precedent is only
  partial, though: the existing runner (`hildi.process`) is
  one-shot, stdout-only, and never writes to the child's stdin, and the
  headless runtime reaches its own child over a detached socket rather than
  pipes. v1 therefore needs a small, new **bidirectional stdio child
  manager** (see Constraints); it reuses the `TProcess`/pipe pattern,
  `NormalizeExit`, and the socket unit's line-framing helpers, but not the
  runner itself.
- **v2: streamable HTTP** — remote MCP servers. Outbound authenticated
  HTTPS with OAuth 2.0: Protected Resource Metadata discovery, Dynamic
  Client Registration, PKCE authorization-code flow with RFC 8707
  `resource` parameters, and token lifecycle. This is *the same problem* as
  Remote Agent Link's outbound auth — **but the link feature as written does
  not yet specify it**: it pairs a device with a short-lived code and a
  bearer token, with OAuth explicitly out of scope. "One auth pipeline,
  three consumers" is therefore a goal to reconcile, not an existing fact:
  either the link's auth grows an authorization-server flow (and this doc
  cites it), or MCP v2 carries the pipeline and the link later consumes it.
  The SPEC resolves which, with the link doc updated to match.

## Problem Statement

The helper's tools are only the ones its authors wrote in Pascal. Every
third-party capability — GitHub, databases, browsers, search — arrives
either as a bespoke tool unit (the per-integration cost the project has
been paying one at a time: files, shell, recall) or as a shell-out through
`run_command` (process spawn, host prerequisites, approval noise, and
output-shape chaos for the model).

MCP collapses that: one protocol, thousands of existing servers, and the
helper's tool surface grows by configuration. But only if MCP tools land
*inside* the trust model — an external tool call that bypassed the approvals
engine would be exactly the failure mode the trust-model rebuild was meant
to prevent. The design below is shaped by that constraint: MCP tools are
ordinary tools with an `mcp/<server>/<tool>` ref, gated by the same engine,
ledgered the same way, reason-gated the same way.

Applying the Ponytail ladder: the registry, the approval engine, the ledger,
and the reason gate all exist and are tool-agnostic — an MCP tool that
registers a spec and, in its handler, builds the same approval asks as a
native tool needs no change to the loop. The genuine gap is narrower than
building tools one integration at a time, but it is not tiny: a
**bidirectional stdio child manager** (new — see above), a **JSON-RPC 2.0
client** (envelope, request/response correlation, notifications), an
**`inputSchema` → `ParametersJson` adapter**, a **result-shape mapper**, and
an **operator config loader** (none exists today). v1 still needs no network
stack.

## Goals

- Connect to configured MCP servers (child process, stdio transport) and
  expose their tools in the registry as namespaced specs. The **approval
  ref** is `mcp/<server>/<tool>`; the **model-visible tool name** is a
  provider-safe encoding of the same identity (the API tool-name grammar
  admits only `[A-Za-z0-9_-]`, so the literal `/` form cannot be the name).
  The adapter maps the two deterministically and the SPEC pins the encoding.
- Dispatch `tools/call` through the loop's normal tool path — reason gate,
  approval ask, ledger rows, budget accounting — so MCP tools are
  indistinguishable from native tools. The **handler**, not the loop, calls
  the approval engine (exactly as `run_command` and the file tools do); the
  loop has no approval hook.
- Survive servers: a slow, hanging, or crashed MCP server degrades its own
  tools (unregistered, or failing with a clean error) without wedging the
  session or blocking startup.
- Be a well-behaved JSON-RPC 2.0 client: correlate responses by `id`,
  consume (and never choke on) notifications, answer server→client requests
  it does not support with a JSON-RPC error rather than hanging, and
  negotiate `protocolVersion` with a defined fallback.
- Keep the door open for v2: the JSON-RPC client and tool adapter are
  transport-agnostic from the start; stdio and HTTP differ below the same
  interface.
- Token/cost discipline: tool listing happens once per server (cached for
  the session), not per turn.

## User Stories

- As an **operator**, I want to list servers in a config file (`{name,
  command, args}` per entry) and have the agent gain that server's tools, so
  extending the helper is configuration, not development. No structured
  config loader exists yet, so this feature introduces a small one, read by
  the process that owns the loop and the children.
- As the **agent**, I want MCP tools to look and behave exactly like native
  tools — spec, reason, call, result — so I never special-case them.
- As an **operator**, I want every MCP call approval-gated by ref
  (`mcp/github/create_issue`) with session scoping, so different agents get
  different MCP capabilities and everything is audited.
- As an **operator**, I want a misbehaving MCP server to take only its own
  tools down, so one flaky integration never wedges a session.
- As a **developer**, I want the JSON-RPC client to be unit-testable
  against in-process fakes over real pipes, so the protocol core needs no
  real servers in the suite.
- As the **Remote Agent Link designer**, I want MCP v2's OAuth and the
  link's outbound auth to be *one* implementation rather than two, so there
  is a single credential/token lifecycle — resolving whether that pipeline
  lives in the link (and MCP consumes it) or is shared.

## Acceptance Criteria

### Functional Requirements

Connection and lifecycle

- [ ] Configured servers spawn at session start (child process, stdio) in
      the process that owns the loop — the headless runtime — and the client
      performs the MCP `initialize` handshake (protocolVersion,
      capabilities, serverInfo) before listing tools. `protocolVersion` is
      negotiated: a server answering with a different supported version is
      accepted; an unsupported one is refused cleanly (that server's tools
      are dropped, not the session).
- [ ] A new bidirectional stdio child manager spawns a server with pipes in
      both directions, writes framed requests to its stdin, reads framed
      responses from its stdout, and tears down with a bounded
      close-then-kill. (The existing runner cannot be reused as-is: it is
      one-shot and stdout-only.)
- [ ] `tools/list` results (name, description, inputSchema) become registry
      specs; listing happens once per server per session, not per turn. The
      SPEC pins the provider-safe **tool name** encoding and the
      `mcp/<server>/<tool>` **approval ref**, and the deterministic mapping
      between them (server/tool names sanitized, collisions resolved).
- [ ] Servers are read from operator config by the process that owns the
      loop and the children; the config format is a SPEC decision (no
      structured loader exists today). The model cannot add a server.
- [ ] A server that fails to spawn, times out on initialize/list, or exits
      mid-session: its tools are unregistered (or fail cleanly with a typed
      error), the session logs the failure as a session event, and the loop
      continues. No hang, no crash, no partial registration. Listing is a
      **bounded wait** (configurable timeout); a server that misses it is
      dropped for the session rather than blocking startup.
- [ ] Notifications (messages with no `id`) are consumed and never
      correlated; `notifications/tools/list_changed` triggers a re-list if
      cheap, and is otherwise ignored. Server→client **requests** the helper
      does not implement (`sampling/createMessage`, `roots/list`,
      `elicitation`) are answered with a JSON-RPC error, never left hanging.
- [ ] Server lifecycle is explicit in config v1 (spawn per session; shared
      per-helper pooling is a SPEC decision if cheap).
- [ ] Graceful shutdown: terminating a session terminates its MCP children
      (close stdio, bounded wait, kill), leak-clean under the heaptrc gate.

Tool integration

- [ ] `tools/call` dispatches through the standard tool path: the loop
      validates the required non-empty `reason` before dispatch; the **MCP
      handler** then asks the approval engine, exactly as `run_command` and
      the file tools do (the loop itself never consults the approval
      engine); the ledger records call, result, duration, and outcome
      identically to native tools.
- [ ] The approval subject is the `mcp/<server>/<tool>` ref. Because MCP
      arguments are arbitrary JSON and approval params are an ordered
      `string[]` with no canonicalization yet (Tool Approvals lists that as
      future work), v1 defaults to asking on the **ref alone**
      (tool-level); param-scoped MCP rules are opt-in and deferred. The
      dialog identifies the server and tool unambiguously.
- [ ] Results map into the loop's tool-result shape: text content blocks
      concatenate; `isError` maps to the tool-failure path (the model sees
      the error text, not a crash); non-text blocks (images, embedded
      resources) and `structuredContent` degrade to a placeholder note in
      v1 — never silently dropped.
- [ ] `inputSchema` JSON from the server maps to the spec's
      `ParametersJson`. The registry rejects any spec whose
      `ParametersJson` is not a JSON object and injects a required `reason`
      string param, so the adapter maps the accepted subset (object with
      typed properties, required list), rejects the tool (not the session)
      on a malformed or over-wide schema, and **strips the injected
      `reason`** before calling `tools/call`.
- [ ] Tool name collisions across servers are prevented by the namespace; a
      server advertising a tool name that normalizes to a native tool's
      name still ends up namespaced (native tools keep their bare names).
      The namespaced name must satisfy the provider's tool-name grammar.

Security and trust

- [ ] Every MCP call is decided by the approvals engine — with no matching
      rule it defaults to `adAsk`, no implicit allow; session-scoped rules
      gate per-agent use exactly as for native tools.
- [ ] The approval dialog identifies the server and tool unambiguously
      ("MCP github · create_issue"); `mcp/*` refs are never
      permissive-by-default (server-level trust may be configurable, but the
      default stays ask).
- [ ] Server configuration is operator-only (config file/env, never
      model-authored); the model can request a server be added, but cannot
      add one.

### Non-Functional Requirements

- [ ] Portability: stdio transport is POSIX pipes (macOS/Linux); no new
      dependency, no TLS in v1.
- [ ] Performance: session startup does not block indefinitely on a slow
      server (listing is a bounded wait; past the timeout the server is
      dropped); tool call latency is dominated by the server, not the
      adapter; the registry lookup stays O(1)-ish.
- [ ] Testability: JSON-RPC client, initialize/list/call flows, and the
      spec-mapping adapter are pure or pipe-fake tested (a scripted fake
      server over real pipes for lifecycle tests); no network in the suite.
- [ ] `make check` passes (functional tests plus the leak gate), including
      child-process teardown under the leak gate.

## Success Metrics

### Quantitative

- A configured server's tools appear in the model-visible registry within a
  bounded startup window (target < 2 s for a well-behaved local server);
  a dead server costs the session nothing but its own tools.
- An MCP tool call is approval-gated, ledgered, and reason-validated
  identically to a native tool call — zero special cases in the loop code
  paths (the diff that adds MCP is confined to the client/adapter units).
- The v2 transport (HTTP + OAuth) can be added by implementing one
  transport interface, with the JSON-RPC and adapter layers unchanged —
  verified by the SPEC's interface review, not hoped for. The OAuth pipeline
  itself is shared with (or owned alongside) Remote Agent Link; which is
  decided before v2 is specified.

### Qualitative

- The helper's tool surface becomes configuration-shaped: servers in, tools
  available, approvals scoping who uses what.
- The trust model survives its first external-tool integration without a
  bypass, exception, or new mechanism.
- Outbound authenticated HTTP is implemented once for both MCP v2 and the
  link, rather than twice.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- JSON-RPC 2.0 framing and the MCP tool-calling subset (`initialize`,
  `tools/list`, `tools/call`, notifications, result shapes) are implemented
  from the published schema; no client library — the surface is small and
  the dependency would be larger than the code. `fpjson` is already used
  throughout.
- **New code required** (no existing equivalent): a bidirectional stdio
  child manager (the runner is one-shot/stdout-only); a JSON-RPC client with
  id correlation and notification handling; and a config loader (no
  structured config exists — `.env` is flat key/value, and the SQLite
  `settings` table is unused).
- Must reuse: `TToolRegistry`/`TToolSpec` (registration), the approval
  engine (refs + asks), the ledger (rows), the required-reason contract, the
  socket unit's line-framing helpers (`ExtractLine`/`ReadLineTimeout`), and
  `NormalizeExit`.
- The adapter maps MCP tool identities to names and refs deterministically;
  ref shapes (`mcp/<server>/<tool>`) are part of the persisted-approval
  contract and must be stable across releases. The model-visible name is a
  provider-safe encoding of the same identity.

### Non-Goals

- **No MCP server implementation** — the helper exposes nothing over MCP in
  this feature; other clients do not drive the helper's tools via MCP.
- No resources, prompts, sampling, elicitation, or other MCP server-side
  capabilities — tools only, in both directions of the client relationship.
  Server→client requests for these are answered with a JSON-RPC error.
- No v2 transport in v1: no HTTP, no OAuth, no Dynamic Client Registration.
  The OAuth pipeline is shared with (or owned alongside) Remote Agent Link
  and is resolved before v2 is specified.
- No MCP server auto-discovery or marketplace; servers are operator config.

## Notes

- **ICE score: Impact 8, Confidence 6, Ease 4.** Broad capability leverage
  per line of code, but the v1 surface is larger than "a client and an
  adapter": a bidirectional stdio child manager, a JSON-RPC client
  (correlation, notifications, server→client requests), a schema/result
  mapper, and a config loader are all new. The risk is lifecycle fiddliness
  and config plumbing, not protocol complexity.
- Sequencing: v1 (stdio) is independent of TLS and the link. Natural after
  Headless Sessions (child-process patterns) and alongside Approval Path
  Scoping (session-scoped MCP grants are the per-agent mechanism).
- **v2 auth is unresolved and cross-feature.** Remote Agent Link today
  specifies device pairing with a bearer token, not OAuth. The PRM discovery
  (RFC 9728), AS metadata, DCR (RFC 7591), PKCE (RFC 8707), and token-store
  pipeline this doc cites as "one pipeline, three consumers" must be built
  somewhere first; the SPEC resolves whether it belongs to the link (with
  MCP consuming it) or to MCP v2, and updates both docs. Until then the
  shared-pipeline claim is a target, not a fact.
- Operator preference recorded from ideation: helper is MCP **client**, not
  server — lending tools out bypasses the local trust model; consuming tools
  enriches it.

## Decisions (v1)

Resolved during SPEC drafting (2026-10-06); recorded here so the FEATURE, the
SPECs, and the code stay in sync. Each is also pinned in its SPEC.

- **Config storage is the SQLite store, not a file.** Servers live in a new
  `mcp_servers` table, scoped `global` / `workspace` / `agent`. This replaces
  the FEATURE's original "operator config file" assumption. Precedence on a name
  clash: `agent` > `workspace` > `global`. See `Config_v1.SPEC.md`.
- **Agent scope is reserved, not built.** The schema, the enum, and the
  precedence include `msAgent`; no agent rows are written in v1. The direction
  is that an agent configures **its own** MCP servers, scoped only to itself —
  never global or workspace. The session does not yet know an agent id.
- **No operator UI in v1.** The operator configures servers by writing directly
  to the `mcp_servers` table. A CLI subcommand or TUI screen is a later feature.
- **v1 is store-backed only.** A file source (JSON/JSONC/TOML) is a future
  alternative; the seam is the row array (`TMcpServerRowArray`), so a future
  loader produces the same rows and reuses `ResolveMcpConfig` unchanged.
- **Identity (persisted contract).** Approval ref `mcp/<server>/<tool>`
  (sanitized to `[a-z0-9_-]`); model-visible name `mcp_<server>_<tool>`
  (provider-safe, ≤64 chars). Native tools keep bare names; MCP tools can never
  shadow them. See `Mcp_Client_v1.SPEC.md`.
- **`NormalizeExit` is exported in place** from `hildi.process`
  (Decision A) so the stdio child manager reuses it. See
  `Stdio_Child_Manager_v1.SPEC.md`.
- **Approvals stay ref-only in v1** (tool-level asks, `AnyParams`); param-scoped
  MCP rules are deferred until approval params gain canonicalization.
