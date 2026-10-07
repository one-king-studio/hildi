# Component Specification: MCP Client v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `JsonRpc_v1.SPEC.md`, `Stdio_Child_Manager_v1.SPEC.md`,
`Config_v1.SPEC.md`, and the existing tool/approval/ledger machinery
(`hildegard.helper.agent`, `hildegard.helper.approval`).
**Depended on by:** `hildegard.helper.harness.session` (registration at session
open).

## Purpose

Make an MCP server's tools **indistinguishable from native tools** in the loop.
The client owns the server connection, performs the MCP handshake, lists tools
once, maps each into a `TToolSpec` + handler registered in the existing
`TToolRegistry`, and — on each call — asks the existing approval engine and
returns a result in the loop's shape.

The whole point of v1 is that the loop does not change. `TAgentLoop` already
validates the required `reason` and appends the `crTool` result to the ledger;
the registry already rejects bad schemas and injects `reason`; the approval
engine already decides by ref. The client is a **producer of specs and a
handler**, nothing more.

## Requirements

### Functional

**Connection & handshake**

- [ ] At session open, spawn one child per configured server (stdio) in the
      process that owns the loop (`THarnessSession`), and perform the MCP
      `initialize` handshake (`protocolVersion`, `capabilities`, `serverInfo`)
      **before** listing tools.
- [ ] Negotiate `protocolVersion`: accept a server that answers with a
      different **supported** version; refuse (drop that server's tools, keep
      the session) an unsupported one. Send `notifications/initialized` after a
      successful initialize.
- [ ] Listing is a **bounded wait** (configurable timeout, default per the
      child manager). A server that misses it is dropped for the session, not
      fatal to startup.

**Tool discovery & registration**

- [ ] `tools/list` → for each entry, build a `TToolSpec` (name, description,
      `inputSchema` → `ParametersJson`) and register a handler that calls
      `tools/call`.
- [ ] Listing happens **once per server per session**, not per turn; the specs
      are cached.
- [ ] A malformed or over-wide `inputSchema` rejects **that tool**, not the
      session.
- [ ] Tool-name collisions across servers are prevented by the namespace; a
      server tool whose name normalizes to a native tool's name is still
      namespaced (native tools keep their bare names).

**Dispatch**

- [ ] A `tools/call` handler (a) reads the model's `reason`, (b) asks the
      approval engine with subject ref `mcp/<server>/<tool>`, (c) on allow,
      strips the injected `reason` and sends `tools/call` with the remaining
      arguments, (d) maps the result to the loop's text shape.
- [ ] The approval subject is the **ref alone** (tool-level) in v1; param-scoped
      MCP rules are opt-in and deferred (MCP args are arbitrary JSON; approval
      params are an ordered `string[]` with no canonicalization yet).
- [ ] Results map as: `content` text blocks concatenated; `isError:true` maps to
      the tool-failure path (the model sees the error text, not a crash);
      non-text blocks (image/resource) and `structuredContent` degrade to a
      placeholder note — **never silently dropped**.

**Robustness**

- [ ] Notifications (no `id`) are consumed and never correlated.
      `notifications/tools/list_changed` triggers a re-list when cheap, else is
      ignored.
- [ ] Server→client **requests** the client does not implement
      (`sampling/createMessage`, `roots/list`, `elicitation`) are answered with
      a JSON-RPC error (`-32601`), never left hanging.
- [ ] A server that fails to spawn, times out, or exits mid-session: its tools
      are unregistered (or fail cleanly with a typed error), the failure is
      logged as a session event, and the loop continues. No hang, no crash, no
      partial registration.
- [ ] Graceful shutdown: terminating a session terminates its MCP children
      (close stdio, bounded wait, kill); leak-clean under the heaptrc gate.

### Non-Functional

- [ ] Portability: POSIX pipes (macOS/Linux); no new dependency, no TLS in v1.
- [ ] Startup does not block indefinitely on a slow server (bounded listing).
- [ ] Testability: the client is exercised against a **scripted fake server over
      real pipes**; no network in the suite.
- [ ] `make check` clean, including child-process teardown under the leak gate.

## Contracts & Interfaces

### Public API

```pascal
unit hildegard.helper.mcp.client;

uses
  Classes, SysUtils,
  hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.stdio.child, hildegard.helper.mcp.config;

type
  { One discovered MCP tool, after mapping. Ref is the persisted-approval
    identity; Name is the provider-safe, model-visible name. }
  TMcpTool = record
    ServerName: string;
    ToolName: string;          // the server's original tool name
    Ref: string;               // 'mcp/<server>/<tool>'
    Name: string;              // provider-safe name (see Encoding)
    Description: string;
    ParametersJson: string;    // mapped inputSchema (reason already stripped)
  end;

  TMcpToolArray = array of TMcpTool;

  { A session event sink (reuses the conversation store's AppendError seam).
    Called from the loop's thread. }
  TMcpEvent = procedure(const AMessage, ADetail: string) of object;

  TMcpClientConfig = record
    Server: TMcpServerConfig;      // from Config_v1.SPEC.md
    ListTimeoutMs: Integer;        // 0 => DefaultMcpListTimeoutMs
    CallTimeoutMs: Integer;        // 0 => DefaultMcpCallTimeoutMs
    ClientName: string;            // 'hildegard-helper'
    ClientVersion: string;         // build version
  end;

  { Owns one server's child + JSON-RPC conversation and registers its tools. }
  TMcpClient = class
  public
    constructor Create(const AConfig: TMcpClientConfig;
      AApproval: IApprovalService; AOnEvent: TMcpEvent);
    destructor Destroy; override;

    { Spawn, handshake, list, and register into ATools. False + AError (and no
      registration) when the server is unusable; the caller logs and continues. }
    function Open(ATools: TToolRegistry; out AError: string): Boolean;

    { Re-run tools/list and register newly-appearing tools (already-registered
      refs are left in place, so a re-list does not collide). }
    function Refresh(ATools: TToolRegistry; out AError: string): Boolean;

    { The tools/call path for one tool: approval ask, strip reason, call, map. }
    function CallTool(const ATool: TMcpTool; const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;

    { Close the child. Idempotent. Called by the owner on session shutdown. }
    procedure Close;

    property ServerName: string;      // from config
    property Tools: TMcpToolArray;    // discovered, read-only
  end;

  { The owning façade: spawns every configured server, registers every tool,
    and tears them all down. This is what THarnessSession holds. }
  TMcpManager = class
  public
    constructor Create(const AConfig: TMcpConfig;
      AApproval: IApprovalService; AOnEvent: TMcpEvent);
    destructor Destroy; override;

    { Open every configured server. Servers that fail are skipped (logged via
      AOnEvent); Open succeeds as long as the manager itself is valid. }
    function Open(ATools: TToolRegistry): Boolean;

    procedure Close;
    function Servers: TMcpServerArray;   // configured servers, read-only
  end;

{ --- pure mapping (public for direct testing) --------------------------- }

{ The approval ref for a server/tool pair. Stable across releases. }
function McpRef(const AServer, ATool: string): string;

{ The provider-safe, model-visible tool name for a server/tool pair. }
function McpToolName(const AServer, ATool: string): string;

{ Maps an MCP inputSchema to a registry ParametersJson, or False when the
  schema is malformed or over-wide (the tool is rejected, not the session). }
function McpSchemaToParams(const AInputSchemaJson: string;
  out AParamsJson: string; out AError: string): Boolean;

{ Maps an MCP tools/call result object to the loop's text result. Always
  returns text; never drops content silently. }
function McpResultToText(const AResultJson: string): string;

const
  DefaultMcpListTimeoutMs = 10000;
  DefaultMcpCallTimeoutMs = 60000;
  McpClientName = 'hildegard-helper';
  { Schema-acceptance bounds: a tool whose inputSchema exceeds either is
    rejected (that tool only), keeping the registry sane. }
  MaxSchemaProperties = 64;
  MaxSchemaBytes = 16384;
  { Provider tool-name grammar cap. }
  MaxToolNameChars = 64;
```

### Data Contracts

**Identity encoding (the persisted contract — pin it).**

- **Ref:** `McpRef(S, T) = 'mcp/' + Sanitize(S) + '/' + Sanitize(T)` where
  `Sanitize` lowercases and replaces any character outside `[a-z0-9_-]` with
  `_`. Ref segments are stable across releases; a ref is what the approval store
  persists, so it must not change once shipped.
- **Model-visible name:** the API tool-name grammar admits only
  `[A-Za-z0-9_-]` (max length 64), so the literal `/` form cannot be the name.
  Pin the deterministic mapping:
  `McpToolName(S, T) = 'mcp_' + Sanitize(S) + '_' + Sanitize(T)`, truncated to
  64 chars. Because `Sanitize` collapses `/` to `_`, the name is injective
  enough that collisions are resolved by the **namespace**: two servers can
  never produce the same name unless their sanitized names collide, in which
  case the second server's tool is suffixed `_2`, `_3`, … deterministically in
  the manager's server order (which is name-sorted; see `Config_v1.SPEC.md`).
  The SPEC requires a collision test.
- **Native tools keep bare names** (`read_file`, `run_command`); an MCP tool
  whose server/tool happen to normalize to a native name is still prefixed
  `mcp_`, so it cannot shadow a native tool.

**Schema mapping.**

- `ParametersJson` is the server's `inputSchema` object **minus** any `reason`
  property/required entry the server may itself declare (the registry re-injects
  its own). The mapped schema must be a JSON object with `type:"object"`; a
  non-object, a schema missing `properties`, or one exceeding
  `MaxSchemaProperties`/`MaxSchemaBytes` is rejected with `AError`.
- The registry's `AugmentReasonParam` then adds the required `reason`; the
  adapter strips it back out before `tools/call`.

**Result mapping.**

- `content` is an array; concatenate the `text` of every `type:"text"` block
  with `LineEnding` between blocks. A non-text block contributes
  `'[non-text content: <type>]'`. `structuredContent` (if present) appends
  `LineEnding + '[structured content omitted]'`. `isError:true` ⇒ the handler
  returns False with the text as the error, so the loop marks the result failed.

### Event Contracts

- `TMcpEvent` fires on the loop's thread for: server spawn failure, initialize
  refusal, listing timeout, mid-session exit, and schema-rejected tools. It is
  the same sink shape as `IConversationStore.AppendError` (message + detail).

## Architecture

### Prior Art & Reuse

- **Registry (rung 2):** `TToolRegistry.Add` already rejects a non-object
  `ParametersJson` and injects a required `reason` (`hildegard.helper.agent`).
  The adapter feeds it a valid object; it does **not** re-implement validation.
- **Loop (rung 2):** `TAgentLoop.DispatchTools` already validates `reason`
  (`ExtractToolReason`) and appends the `crTool` message (ledger row, duration,
  `ToolOk`). MCP adds **zero** loop code.
- **Approval (rung 2):** `IApprovalService.Resolve` + `TApprovalAsk` +
  `DefaultApprovalRule(aeAllow)`; ref-only subject with `AnyParams := True` (the
  `run_command` "any arguments" option is the exact precedent).
- **Framing (rung 2):** `TJsonRpcCodec` (`JsonRpc_v1`), `TStdioChild`
  (`Stdio_Child_Manager_v1`).
- **Genuine gap:** the MCP method subset (`initialize`, `tools/list`,
  `tools/call`, `notifications/*`), the identity/ref encoding, and the
  schema/result mappers. All new, all small.

### Component Boundaries

- **Responsibilities:** handshake, discovery, registration, dispatch, result
  mapping, per-server failure isolation, child lifetime.
- **Dependencies:** the three new units plus `agent`, `approval`, `llm`.
- **Side effects:** spawns children; mutates the shared `TToolRegistry` (only at
  open/refresh, on the loop's thread).

### Data Flow

1. `THarnessSession` builds the effective list — `store.LoadMcpServers` then
   `ResolveMcpConfig` (`Config_v1.SPEC.md`) — and constructs `TMcpManager`.
   `TMcpManager.Open` iterates the servers; for each, `TMcpClient.Open`.
2. `TMcpClient.Open`: `TStdioChild.Start` → `initialize` (encode → write → read
   → decode, bounded) → `notifications/initialized` → `tools/list` → map each
   tool → `ATools.Add(spec, handler)`.
3. On a model `tools/call`, the handler: reason check (loop already did) →
   approval `Resolve` with the ref → on allow, strip `reason`, encode
   `tools/call` → write → read (bounded) → `McpResultToText` → return.
4. Any notification/unknown server request encountered while waiting is handled
   in the read loop and the wait continues.
5. `Close` (manager or client) tears the children down.

### Integration Patterns

- **Threading:** the loop is single-threaded; the client is driven on that
  thread. The child manager is synchronous, so there is no lock here. Ceiling:
  a slow MCP call blocks the turn — acceptable because the loop is already
  single-threaded and the call has a bounded timeout.
- **Lifetime:** `THarnessSession` owns the `TMcpManager`; the manager owns its
  clients; each client owns one `TStdioChild`. `Close` runs in the session's
  `Close`, before the registry is freed.
- **Registry mutation** happens only in `Open`/`Refresh` (loop thread). The
  handler closes over the client and the resolved `TMcpTool`.

## Validation Rules

### Input

- A server whose `initialize` result lacks a supported `protocolVersion` is
  refused (tools dropped).
- A `tools/list` entry without a string `name` is skipped; one with a
  non-object `inputSchema` is skipped (logged), not fatal.
- A `tools/call` result that is not a JSON object is mapped to a placeholder
  note, not a crash.

### Output Guarantees

- Every registered spec has a provider-legal name and an object
  `ParametersJson`.
- `McpResultToText` always returns a non-nil string (possibly a placeholder).

## Error Handling

- **Spawn/initialize/list failure** ⇒ `Open` = False, **no** registration,
  event logged, session continues.
- **Mid-session exit** ⇒ the next call to that server returns a clean tool
  failure ("MCP server '<name>' is not available"); the client marks itself
  dead; a later `Refresh` may revive it (SPEC decision: v1 does not auto-restart;
  the server is dropped for the session).
- **Approval denied** ⇒ the handler returns False with a short "denied by
  operator" message; the loop records the failed tool result.
- **Timeout on call** ⇒ clean tool failure; the child is left alive (the server
  may just be slow) but the call is reported failed.

## Testing Requirements

### Unit Tests (`tests/test_mcp_client.pas`)

- [ ] `McpRef`/`McpToolName` are deterministic and stable; a native-name
      collision still yields an `mcp_`-prefixed name; two servers with a
      sanitized-name collision resolve deterministically.
- [ ] `McpSchemaToParams` accepts a valid object schema, strips a server-declared
      `reason`, and rejects non-object / over-wide schemas.
- [ ] `McpResultToText` concatenates text blocks, marks non-text blocks,
      appends the structured-content note, and signals `isError`.
- [ ] **Fake-server lifecycle** over real pipes: a scripted fake answers
      `initialize` + `tools/list`; assert the registry gains the tools with the
      pinned names/refs.
- [ ] Fake server that refuses the protocol version ⇒ no tools registered, an
      event logged, `Open` = False.
- [ ] Fake server that hangs on `tools/list` ⇒ bounded drop.
- [ ] Fake server that dies mid-session ⇒ the tool call returns a clean failure.
- [ ] Notifications interleaved before a response are consumed; a server→client
      request is answered with `-32601` and the wait continues.
- [ ] A `tools/call` with `isError:true` maps to a failed tool result whose text
      the model sees.
- [ ] Approval: with a session-scoped allow rule for the ref, the call proceeds;
      with none, it asks; a matching deny blocks.
- [ ] Leak-clean under `make test-leak`, including a fake server killed at
      teardown.

### Integration Tests

- [ ] `THarnessSession.Open` with one configured fake server registers its
      tools alongside the native ones; a native call and an MCP call both flow
      through approvals/ledger unchanged (the loop diff is empty).

## Performance Targets

- Discovery is one `tools/list` per server per session; registration is O(tools).
- A call's latency is dominated by the server; the adapter adds JSON
  encode/decode only.

## Security Considerations

- **No bypass:** every call is decided by the approval engine; ref-only
  subject; `mcp/*` refs are never permissive-by-default (`adAsk` with no rule).
- The model cannot add a server (config is operator-only and durable in the
  store; see `Config_v1`).
- Server output is untrusted: bounded lines, no interpretation, no eval.
- Arguments are passed as JSON to the server; the client never shells out.

## Success Criteria

### Functional

- [ ] Configured servers' tools appear in the registry within a bounded window.
- [ ] Calls are approval-gated, ledgered, and reason-validated with **no loop
      change**.
- [ ] A dead server costs the session nothing but its own tools.
- [ ] `make check` passes.

### Quality

- [ ] No leaks under the heaptrc gate, including child teardown.
- [ ] v2 can be added as one transport implementing the same seam (verified by
      interface review).

## Future Considerations

- **v2 transport:** replace `TStdioChild` with an HTTP transport behind the same
  `TJsonRpcCodec` + client layers; the client's method handling is unchanged.
- **Param-scoped approvals:** when approval params gain canonicalization, MCP
  asks can offer finer options; the ref shape does not change.
- **Auto-restart** of a dropped server is deliberately deferred.
- **`tools/list_changed`** re-list is wired but may be a no-op in v1 if cheap.
