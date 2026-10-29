# MCP Transport v2 (Streamable HTTP)

## Overview

Connect the helper to **remote MCP servers over HTTP**, so MCP is no longer
stdio-only. This is the FEATURE's stated v2, and it is the point of the whole
"transport-agnostic client" design — but that design is currently **aspirational**:
`TMcpClient` is welded to `TStdioChild`. So this feature has two parts:

1. **Extract the transport seam** — an `IMcpTransport` the client depends on,
   with the existing stdio child as one implementation.
2. **Add the HTTP transport** — an `IMcpTransport` that POSTs JSON-RPC to a
   remote endpoint (MCP "streamable HTTP"), reusing the same `TJsonRpcCodec`,
   tool mapping, approval, and manager.

Auth (OAuth 2.0: PRM discovery, DCR, PKCE, token lifecycle) is a **separate,
later** feature; v1 of this feature is the transport with **static header auth**
(e.g. a bearer token in config), which proves the seam and unblocks real remote
servers that use a simple token.

## Problem Statement

MCP v1 (stdio) covers servers you run as local child processes. A large and
growing class of servers are **remote** — hosted, reachable over HTTPS, and the
only way to use them is HTTP. Today the helper cannot reach any of them.

The FEATURE claims "v2 can be added by implementing one transport interface, with
the JSON-RPC and adapter layers unchanged." That is not yet true: the client owns
a `TStdioChild` and calls `ReadLine`/`WriteLine` directly. Doing the HTTP work
therefore starts by making the claim true.

## Goals

- An `IMcpTransport` seam: `Open`, `Send(line)`, `Receive(out line, timeout)`,
  `Close`, and a `Dead` flag. The client depends only on this.
- `TStdioTransport` — the existing child, wrapped (behaviour unchanged).
- `THttpTransport` — POSTs each JSON-RPC message to an endpoint and reads the
  response body (one JSON-RPC object, or an SSE stream that yields one).
- Config: an HTTP server is configured by `url` (+ optional static `headers`),
  not `command`/`args`; the store row gains a transport kind.
- The manager, provider, approvals, and tool mapping are **unchanged** — the
  proof the seam holds.
- No OAuth in this feature (static header/bearer only); that is the next feature.

## User Stories

- As an **operator**, I want to point the helper at a remote MCP URL with a
  token, so I can use hosted tools without running a local server.
- As a **developer**, I want the client to depend on a transport interface, so
  stdio and HTTP share one client (and a future WebSocket/SSE variant is another
  implementation).
- As a **reviewer**, I want the HTTP transport to reuse the JSON-RPC codec and
  the approval path unchanged, so remote tools are gated exactly like local ones.

## Acceptance Criteria

### Functional Requirements

- [ ] `IMcpTransport` exists with `Open(out err)`, `Send(const line; out err)`,
      `Receive(out line; timeoutMs; out reason)`, `Close`, `Dead`.
- [ ] `TStdioTransport` wraps `TStdioChild`; the client uses it with no behaviour
      change (all existing MCP tests pass).
- [ ] `TMcpClient` depends only on `IMcpTransport` (no `TStdioChild` reference).
- [ ] `THttpTransport` POSTs a JSON-RPC request to the configured URL with
      `Content-Type: application/json` (and `Accept: application/json,
      text/event-stream`), reads the body, and yields the JSON-RPC message. A
      `text/event-stream` body is parsed as SSE to extract the message.
- [ ] Config supports `url` + `headers` (static), distinct from `command`/`args`;
      the store `mcp_servers` row records the transport kind (a migration).
- [ ] The manager/provider select the transport by kind; the tool list, approval
      refs, and dispatch are identical to stdio.
- [ ] A remote server that is unreachable, times out, or returns a non-2xx /
      malformed body fails cleanly (the existing per-server isolation and
      reconnect apply).

### Non-Functional Requirements

- [ ] Reuse the TLS stack (`hildi.tls`) for HTTPS — no new dependency.
- [ ] Requests are bounded by the configured call/list timeouts.
- [ ] `make check` green; leak-clean.

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`; reuse `TJsonRpcCodec`, `TMcpClient`,
  `TMcpManager`, `TMcpProvider`, and `hildi.tls`/`fphttpclient`.
- POSIX (macOS/Linux); no dependency.

### Business / Time

- Static auth only. OAuth is explicitly deferred.

## Dependencies

### Internal

- `hildi.mcp.client`, `.config`, `.stdio.child`, `hildi.tls`.
- `hildi.store` (the transport-kind column).

### External

- None.

## Risks

- **The seam is bigger than the FEATURE implied** — Mitigation: do the seam
  first, prove it with the existing stdio tests, then add HTTP.
- **SSE parsing for streamable HTTP** — Mitigation: reuse the SSE approach from
  the LLM client; a non-SSE JSON body is the common case and is parsed first.
- **Auth complexity** — Mitigation: static headers now; OAuth next.

## Out of Scope

- **OAuth 2.0** (PRM, DCR, PKCE, token lifecycle) — the next feature; it builds
  on this transport.
- **WebSocket** transport.
- **Server-initiated streams** kept open across calls (v1 does one POST per
  request; a long-lived GET stream is deferred).

## Future Considerations

- OAuth (the big one), reusing the transport.
- A session id header (`Mcp-Session-Id`) if a server requires it.
- WebSocket / long-lived SSE.

## Notes

- **ICE score: Impact 8, Confidence 6, Ease 4.** High impact (unlocks remote
  servers) but the seam extraction plus HTTP/SSE is real work, and OAuth looms.
- This feature **corrects a claim**: the FEATURE says v2 is "one transport"; it
  is really "one seam + one transport." The SPECs below do the seam first.
