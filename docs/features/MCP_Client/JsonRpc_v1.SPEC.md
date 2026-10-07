# Component Specification: JSON-RPC Client v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** nothing above it — this is the transport-agnostic protocol core.
**Depended on by:** `Stdio_Child_Manager_v1.SPEC.md` (framing),
`Mcp_Client_v1.SPEC.md` (initialize/list/call).

## Purpose

The MCP wire is JSON-RPC 2.0: newline-delimited JSON objects over a byte
stream. This component is the **codec and correlation core** — it turns method
calls into request envelopes, parses every incoming line into a typed message,
and classifies responses, notifications, and server→client requests. It knows
nothing about stdio, HTTP, MCP methods, or tools: it is pure string-in /
string-out plus one small stateful id allocator.

Keeping it pure is what makes v2 (streamable HTTP) a transport swap rather than
a rewrite, and what makes the protocol unit-testable with no server at all.

## Requirements

### Functional

- [ ] Encode a request (`id`, `method`, `params`), a notification (no `id`),
      a success response, and an error response, per the JSON-RPC 2.0 spec.
- [ ] Decode one line into a typed incoming message: a **response** (has `id`,
      has `result` or `error`), a **notification** (method, no `id`), a
      **server→client request** (method **and** `id`), or **malformed**.
- [ ] Allocate monotonically increasing request ids that never collide within a
      client instance, and never reuse an id whose response has not arrived.
- [ ] Preserve the raw `result`/`params` JSON as a string; the codec does not
      interpret MCP payloads.
- [ ] Distinguish a JSON-RPC error response from a transport failure: an `error`
      member is a decoded `TJsonRpcError`, not a decode failure.

### Non-Functional

- [ ] Pure and thread-free; no I/O, no globals, no allocations that outlive a
      call except the id counter.
- [ ] `make check` clean (functional tests + heaptrc leak gate).
- [ ] No new dependency — `fpjson`/`jsonparser` (already used throughout).

## Contracts & Interfaces

> Contracts are Pascal declarations, not bodies.

### Public API

```pascal
unit hildegard.helper.jsonrpc;

type
  TJsonRpcId = Int64;

  { A decoded JSON-RPC error member. DataJson is the raw `data` member, or ''
    when absent; the codec does not interpret it. }
  TJsonRpcError = record
    Code: Integer;
    Message: string;
    DataJson: string;
  end;

  { The four shapes one incoming line can have. Exactly one applies. }
  TJsonRpcIncomingKind =
    (ikResponse, ikNotification, ikServerRequest, ikMalformed);

  TJsonRpcIncoming = record
    Kind: TJsonRpcIncomingKind;
    { ikResponse / ikServerRequest }
    Id: TJsonRpcId;
    HasId: Boolean;
    { ikNotification / ikServerRequest }
    Method: string;
    ParamsJson: string;      // raw `params`; '' when absent
    { ikResponse }
    ResultJson: string;      // raw `result`; '' when the response is an error
    Error: TJsonRpcError;
    IsError: Boolean;        // ikResponse: True when `error` is present
    { diagnostics }
    Raw: string;             // the original line, verbatim
    MalformedReason: string; // ikMalformed only
  end;

  { Pure codec. Every function returns a complete, LF-free line; the caller
    owns framing (see Stdio_Child_Manager_v1.SPEC.md). }
  TJsonRpcCodec = class
  public
    class function EncodeRequest(AId: TJsonRpcId; const AMethod: string;
      const AParamsJson: string): string;
    class function EncodeNotification(const AMethod: string;
      const AParamsJson: string): string;
    class function EncodeResult(AId: TJsonRpcId;
      const AResultJson: string): string;
    class function EncodeError(AId: TJsonRpcId; ACode: Integer;
      const AMessage: string; const ADataJson: string = ''): string;
    class function Decode(const ALine: string): TJsonRpcIncoming;
  end;

const
  { Standard JSON-RPC 2.0 error codes; MCP uses these for its own refusals. }
  JsonRpcParseError     = -32700;
  JsonRpcInvalidRequest = -32600;
  JsonRpcMethodNotFound = -32601;
  JsonRpcInvalidParams  = -32602;
  JsonRpcInternalError  = -32603;

  { The version string carried in every envelope. }
  JsonRpcVersion = '2.0';
```

### Data Contracts

- **`params` omission.** An empty `AParamsJson` omits the `params` member
  entirely (a valid request may have none); a non-empty value is inserted as
  raw JSON. Same for `result` in `EncodeResult` (empty ⇒ `"result":null` is
  **not** emitted; callers always pass a real payload).
- **Id allocation.** A `TJsonRpcIdGen` (or a counter inside the client) yields
  `1, 2, 3, …` as `TJsonRpcId`. Ids are unique for the life of a client.
- **Malformed classification.** A line that is not a JSON object, has no
  `jsonrpc:"2.0"`, has an `id` that is not a number, or has neither `result`
  nor `error` on a response-shaped message is `ikMalformed` with a reason
  string. A top-level JSON array (a JSON-RPC batch) is `ikMalformed` in v1 —
  MCP over stdio does not use batching (deliberate; see Notes).

### Event Contracts

- None. The codec is synchronous and side-effect-free.

## Architecture

### Prior Art & Reuse

- **`fpjson`/`jsonparser`** (rung 3): object build/parse and `AsString`/`Find`
  already do the heavy lifting; the codec is a thin, typed skin over them.
- **The session protocol** (`hildegard.helper.session.protocol`,
  `TSessionCodec`) is the closest in-house analogue: it also encodes/decodes a
  line-delimited envelope. It is **not** reused — its schema is the session
  wire, not JSON-RPC — but it is the pattern to follow, and the same framing
  helper (`ExtractLine`) serves both.
- **Genuine gap:** typed request/response/notification/error classification
  with id correlation. Nothing in `src/` does this.

### Component Boundaries

- **Responsibilities:** envelope encoding/decoding, message classification, id
  allocation, error-member extraction.
- **Dependencies:** `fpjson`, `jsonparser`, `SysUtils` only.
- **Side effects:** none (id counter is the sole state, and it lives with the
  caller's generator).

### Data Flow

1. **Outbound:** client → `EncodeRequest`/`EncodeNotification` → line →
   transport (stdio writes it).
2. **Inbound:** transport reads a line → `Decode` → `TJsonRpcIncoming` → client
   routes by `Kind`.

## Validation Rules

### Input (Decode)

- A line must parse as a JSON **object**; arrays and scalars are malformed.
- `jsonrpc` must equal `"2.0"` (absent ⇒ malformed).
- `id`, when present, must be an integer (JSON-RPC allows string/null ids; MCP
  uses integers — a non-integer id is malformed).
- A response must carry exactly one of `result`/`error`.
- A request/notification must carry a string `method`.

### Output Guarantees

- `Encode*` always returns valid JSON-RPC 2.0 that round-trips through `Decode`.
- `Decode` never raises: any input yields a `TJsonRpcIncoming`, with `Raw`
  always set for diagnostics.

## Error Handling

- **Decode failures** are values (`ikMalformed` + `MalformedReason`), never
  exceptions — a hostile or buggy server cannot crash the client by sending
  garbage.
- **Encode failures** (a caller hands in non-JSON `AParamsJson`) raise a single
  typed exception, because that is a programming error on our side, not server
  input; the SPEC pins `EJsonRpcEncode` as the type.

## Testing Requirements

### Unit Tests (`tests/test_jsonrpc.pas`)

- [ ] `EncodeRequest`/`EncodeNotification`/`EncodeResult`/`EncodeError`
      round-trip through `Decode` with the expected `Kind` and fields.
- [ ] `Decode` classifies: response (result), response (error), notification,
      server→client request, and each malformed shape (array, scalar, missing
      `jsonrpc`, non-integer `id`, response with neither member).
- [ ] Id generation yields distinct, increasing ids.
- [ ] A non-JSON `AParamsJson` raises `EJsonRpcEncode`.

### Integration Tests

- [ ] A request encoded here and fed to `Mcp_Client`'s initialize/list flows
      decodes to the shapes the client expects (covered in the client suite).

## Performance Targets

- `Decode`/`Encode` are O(line length); no buffering or state. Microseconds per
  call, dwarfed by the transport round-trip.

## Security Considerations

- The codec is the first thing untrusted server bytes hit. It must not raise on
  hostile input (fuzz-shaped tests), must not allocate unboundedly (the framing
  layer caps line length; see the child manager), and must never interpret
  payloads — interpreting is the client's job, behind typed boundaries.

## Success Criteria

### Functional

- [ ] All four message shapes encode and decode per spec.
- [ ] Malformed input is classified, never raised.
- [ ] `make check` passes.

### Quality

- [ ] No memory leaks under the heaptrc gate.
- [ ] Codec is dependency-free beyond `fpjson`.

## Future Considerations

- **Batch support** is a one-function addition (`DecodeArray`) if a future
  transport needs it; v1 declines it deliberately (MCP/stdio does not batch).
- **String ids** would relax the integer-id validation; MCP does not use them.
- v2 (HTTP) reuses this codec unchanged; only the framing transport differs.
