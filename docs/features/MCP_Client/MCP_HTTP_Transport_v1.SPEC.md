# Component Specification: MCP HTTP Transport v1

**Related Feature:** [MCP_HTTP_v2_FEATURE.md](MCP_HTTP_v2_FEATURE.md)

**Depends on:** `MCP_Transport_Seam_v1.SPEC.md`, `hildegard.helper.tls`,
`hildegard.helper.mcp.config`, `hildegard.helper.store`.
**Depended on by:** the MCP manager/provider (unchanged).

## Purpose

An `IMcpTransport` that speaks JSON-RPC to a remote MCP server over HTTP
("streamable HTTP"), so a `url`-configured server works exactly like a
`command`-configured one. One POST per request; the response body is one
JSON-RPC object or an SSE stream carrying it.

## Requirements

### Functional

- [ ] `THttpTransport` implements `IMcpTransport`: `Send` queues a JSON-RPC line
      and POSTs it (or the client sends then receives — SPEC pins a
      request/response model: `Send` POSTs and stores the response body;
      `Receive` yields the parsed message).
- [ ] Request: `POST <url>` with `Content-Type: application/json`,
      `Accept: application/json, text/event-stream`, plus configured headers
      (e.g. `Authorization: Bearer ...`).
- [ ] Response: a 2xx body is either a JSON object (the JSON-RPC response) or
      `text/event-stream`; SSE is parsed to extract the `data:` JSON-RPC message.
- [ ] Non-2xx, a network error, or a malformed body ⇒ `Receive` returns
      `mrError` with detail; `Dead` is set.
- [ ] A `Mcp-Session-Id` response header, if present, is echoed on later
      requests (servers that require it).
- [ ] Config: `TMcpServerConfig` gains `Url` and `Headers`; `Command`/`Args` are
      unused for HTTP. The store row gains a transport kind + url/headers.

### Non-Functional

- [ ] HTTPS via the vendored TLS (`hildegard.helper.tls`); no new dependency.
- [ ] Bounded by the call/list timeouts.
- [ ] `make check` green; leak-clean.

## Contracts & Interfaces

```pascal
unit hildegard.helper.mcp.http.transport;   // or a unit under mcp.*

type
  THttpTransportConfig = record
    URL: string;
    Headers: array of string;   // 'Name: value'
    ConnectTimeoutMs: Integer;
    ReadTimeoutMs: Integer;
  end;

  THttpTransport = class(TInterfacedObject, IMcpTransport)
  public
    constructor Create(const AConfig: THttpTransportConfig);
    // IMcpTransport: Open/Send/Receive/Close/Dead
  end;
```

### Data Contracts

- **Request/response model.** MCP streamable HTTP is request/response for our
  use: the client `Send`s one JSON-RPC request; the server's HTTP response body
  carries the JSON-RPC response (directly or via SSE). `Send` performs the POST
  and retains the body; the next `Receive` yields it. (A notification `Send`
  posts with no body expected.)
- **SSE.** If `Content-Type` is `text/event-stream`, scan `data:` lines; the
  first complete JSON object with a matching `id` (or a notification) is the
  message. Reuse the LLM client's SSE approach.
- **Session id.** Capture `Mcp-Session-Id` from the initialize response and send
  it on subsequent requests.

### Event Contracts

- None.

## Architecture

### Prior Art & Reuse

- **`TJsonRpcCodec`** — unchanged; the transport only moves bytes.
- **`hildegard.helper.tls` / `fphttpclient`** — the HTTP + TLS stack already
  used by the LLM client; reuse it.
- **The SSE parsing** from `hildegard.helper.llm` is the model.
- **Genuine gap:** the HTTP transport itself.

### Component Boundaries

- **Responsibilities:** HTTP POST/response, SSE extraction, session-id echo,
  header auth.
- **Side effects:** network I/O.

## Validation Rules

- A server entry with a `url` uses HTTP; with a `command`, stdio. Both set ⇒ a
  config error.

## Error Handling

- Network/timeout/non-2xx/malformed ⇒ `mrError` + `Dead`; the manager's existing
  reconnect/backoff applies.

## Testing Requirements

### Unit Tests

- [ ] `Send`/`Receive` against a **local fake HTTP server** (in-process) that
      returns a canned JSON-RPC response (a JSON body and an SSE body).
- [ ] A non-2xx and a malformed body ⇒ `mrError`.
- [ ] The `Mcp-Session-Id` echo.
- [ ] The full client (`TMcpClient`) against the fake server: initialize, list,
      call — proving the seam.

### Integration Tests

- [ ] Manual (calibration): a real remote MCP server over HTTPS with a token.

## Performance Targets

- One POST per request; latency dominated by the network.

## Security Considerations

- Static header auth in v1 (OAuth later). TLS verified via the vendored CA.
- The URL is operator config; the model cannot set it.

## Success Criteria

- [ ] A `url`-configured server lists tools and dispatches calls through the same
      approval path; `make check` green.

## Future Considerations

- OAuth 2.0 (PRM, DCR, PKCE, tokens) — the next feature.
- A long-lived GET SSE stream for server-initiated messages.
