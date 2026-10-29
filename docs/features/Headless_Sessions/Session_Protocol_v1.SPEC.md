# Component Specification: Session Protocol v1

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

The wire contract between a headless session runtime and its clients: how a
client attaches, replays the live turn, receives typed events, and sends
commands — over a local Unix socket, with a schema that a later network
transport (A2A) and other codecs (JSON-RPC, SSE) can re-bind.

The *schema* is the durable asset. The envelope and the transport are bindings;
this spec fixes the schema and the one binding v1 ships (NDJSON over
`AF_UNIX`/`SOCK_STREAM`).

## Requirements

### Functional

**Transport**

- [ ] `AF_UNIX` / `SOCK_STREAM`, one socket per active session, in an
      owner-only runtime directory (`0700`).
- [ ] The socket path is derived from the session id and kept short enough for
      the platform's `AF_UNIX` limit (a short runtime directory, never `$HOME`).
- [ ] `bind()` is the acquisition: it fails when the path exists. If the path
      exists but `connect()` is refused, the socket is stale — unlink and
      re-bind. A live socket is the liveness proof; there is no heartbeat.
- [ ] v1 is **Unix-only**. The transport is a seam and the schema does not
      assume `AF_UNIX`, so a Windows binding (TCP loopback + token, or named
      pipes) can be added later without a schema change. See
      [`docs/guidelines/windows-portability.md`](../../guidelines/windows-portability.md).

**Framing**

- [ ] NDJSON: one UTF-8 JSON object per line, terminated by `\n`. JSON escapes
      newlines, so a line is unambiguous.
- [ ] A line-length ceiling; an oversized or unparsable line is answered with
      `error` and the connection closed.

**Handshake and versioning**

- [ ] The server sends `hello` first, before any event: protocol name, version,
      session id, loop id, and capabilities.
- [ ] The client replies `attach` with `from_seq` and a requested role.
- [ ] A version mismatch is an `error` (`bad_version`) followed by a close; the
      client reports it and does not attach. The `v` field is present on every
      message so a future codec can evolve independently.

**Messages**

- [ ] Server→client: `hello`, `attached`, `event`, `reply`, `detached`, `error`.
- [ ] Client→server: `attach`, `detach`, `cmd`, `ping`.
- [ ] A `cmd` carries an `id`; the `reply` echoes it, so replies correlate with
      commands. `ping`/`pong` are unnumbered.

**Events**

- [ ] Every event carries a monotonic per-loop `seq`, a `ts` (epoch ms), and a
      `kind`.
- [ ] Events are semantic and typed — never pre-rendered text — so a consumer
      maps them to cells, ANSI lines, or DOM.
- [ ] Kinds and payloads are fixed below.

**Commands**

- [ ] `prompt`, `approve`, `interrupt`, `claim_drive`, `release_drive`, `ping`.

**Roles and the drive lease**

- [ ] `observe` may `attach`, `detach`, and `ping`. `drive` may additionally
      `prompt`, `approve`, and `interrupt`.
- [ ] Exactly one client holds `drive`. The first `attach{role:"drive"}` while
      free is granted. While held, the server grants `observe` and names the
      current driver in `attached`.
- [ ] `claim_drive` requests the role: granted if free; if held, the server
      emits `drive_requested` to the driver, who grants (`drive_granted`),
      denies, or lets it time out. **A driver is never evicted without consent.**
- [ ] A runtime with no driver (a headless session nobody has attached to)
      grants `drive` to the first claimer immediately.
- [ ] The driver may `release_drive`; the role then becomes free.

**Replay and reconciliation**

- [ ] The runtime buffers the **current in-flight turn** and replays it from
      `from_seq` (0 = the whole live turn). Prior turns are not on the wire; a
      client reads them from the ledger.
- [ ] The `attached` reply carries `last_seq` (the highest buffered event) and
      `store_hwm` (the ledger's high-water mark at attach time).
- [ ] **Reconciliation rule.** A client composes the session as *ledger history
      up to `store_hwm`* plus *replayed events from `from_seq`*. It discards any
      replayed event whose content is already covered by a committed ledger
      block (a block that committed between its ledger read and its attach), so
      the composition neither duplicates nor gaps.

**Backpressure**

- [ ] A slow observer whose outbound buffer exceeds a ceiling is dropped with a
      `gap` event naming the last delivered `seq`; the client re-syncs from the
      ledger and re-attaches. A slow observer never stalls the loop.

**Lifetime**

- [ ] On loop exit the runtime emits `loop_exited`, then `detached` and closes
      each connection. A client that connects after exit is refused and must
      read the ledger.

### Non-Functional

- [ ] Portability: macOS and Linux; no dependency beyond the RTL and `fpjson`.
- [ ] Testability: the codec is a pure function (record ⇄ line) and is unit
      tested without a socket; the transport is tested with a scripted client.
- [ ] The schema assumes nothing about the transport, so a JSON-RPC codec or an
      SSE/WebSocket binding can be added without changing the types.

## Contracts & Interfaces

### Public API

```pascal
unit hildi.session.protocol;

type
  TSessionRole = (srObserve, srDrive);

  TSessionCaps = set of TSessionRole;

  TSessionEventKind = (
    ekLoopStarted, ekTurnStarted, ekUserMessage,
    ekAssistantDelta, ekAssistantBlock, ekReasoningDelta,
    ekToolCall, ekToolResult,
    ekApprovalRequest, ekApprovalResolved,
    ekDriveRequested, ekDriveGranted, ekDriveReleased,
    ekTurnFinished, ekError, ekGap, ekLoopExited,
    ekReasoningDone,
    { A transient request failure is being retried (Request Retry v1): the event
      carries the attempt number, the total, and the delay before the next try.
      Appended last so stored ordinals are unchanged. }
    ekRetrying);

  { One streamed event. A flat record with optional fields, the same shape as
    TTurnEvent: only the fields named by Kind are meaningful. }
  TSessionEvent = record
    Seq: Int64;                 // monotonic per loop
    Ts: Int64;                  // epoch ms
    Kind: TSessionEventKind;
    Text: string;               // message/delta/block/result text; error message
    Detail: string;             // error detail
    LoopId: string;             // loop_started
    SessionId: string;          // loop_started
    TurnSeq: Int64;             // turn_started: the per-session turn sequence
    ToolId: string;
    ToolName: string;
    ToolArguments: string;      // raw JSON
    ToolReason: string;
    ToolOk: Boolean;
    AskId: string;              // approval_request / approval_resolved
    Ask: TApprovalAsk;          // approval_request payload
    Choice: TApprovalChoice;    // approval_resolved
    FinishReason: string;       // turn_finished
    Usage: TTokenUsage;         // turn_finished
    ElapsedMs: Int64;           // turn_finished / reasoning_done
    ErrorCode: string;          // error
    Dropped: Boolean;           // error: the turn was cancelled with no commit
    FromSeq: Int64;             // gap: first missing seq
    ToSeq: Int64;               // gap: last delivered seq
    Client: string;             // drive_*: client id
    Reason: string;             // loop_exited
  end;

  TSessionCommandKind = (
    scAttach, scDetach, scPrompt, scApprove, scInterrupt,
    scClaimDrive, scReleaseDrive, scPing);

  { One client command. Id is echoed in the reply. }
  TSessionCommand = record
    Id: string;
    Kind: TSessionCommandKind;
    FromSeq: Int64;             // attach
    Role: TSessionRole;         // attach
    Text: string;               // prompt
    AskId: string;              // approve
    Choice: TApprovalChoice;    // approve
  end;

  { The in-memory form of any wire message. }
  TSessionMessageKind = (mkHello, mkAttached, mkEvent, mkReply, mkDetached,
    mkError, mkAttach, mkDetach, mkCmd, mkPing, mkPong);

  TSessionMessage = record
    Kind: TSessionMessageKind;
    Hello: TSessionHello;
    Attached: TSessionAttached;
    Event: TSessionEvent;
    Command: TSessionCommand;
    ReplyId: string;            // reply
    Ok: Boolean;                // reply
    ErrorCode: string;          // error / reply
    ErrorMessage: string;
    Detail: string;
    Reason: string;             // detached
  end;

  TSessionHello = record
    Protocol: string;           // 'hildi-session'
    Version: Integer;           // 1
    SessionId: string;
    LoopId: string;
    Caps: TSessionCaps;
  end;

  TSessionAttached = record
    Role: TSessionRole;         // granted role
    Driver: string;             // current driver client id ('' when none)
    LastSeq: Int64;
    StoreHwm: Int64;
  end;

  { Pure codec: record <-> one NDJSON line. No sockets, no state. Encode returns
    the line including its trailing '\n'; Decode tolerates one. }
  TSessionCodec = class
  public
    class function Encode(const AMessage: TSessionMessage): string;
    class function Decode(const ALine: string;
      out AMessage: TSessionMessage): Boolean;
  end;
```

### Data Contracts (wire schema)

Every message is a JSON object with `v` (protocol version) and `type`. Field
names below are the contract.

| type | fields |
| --- | --- |
| `hello` | `protocol`, `version`, `session`, `loop`, `caps[]` |
| `attach` | `from_seq`, `role` |
| `attached` | `role`, `driver`, `last_seq`, `store_hwm` |
| `event` | `seq`, `ts`, `kind`, …payload |
| `cmd` | `id`, `name`, …args |
| `reply` | `id`, `ok`, `error?` |
| `detached` | `reason` |
| `error` | `code`, `message`, `detail?` |
| `ping` / `pong` | — |

Event payloads (the fields beyond `seq`/`ts`/`kind`):

| kind | payload |
| --- | --- |
| `loop_started` | `loop`, `session` |
| `turn_started` | `turn_seq` |
| `user_message` | `text` |
| `assistant_delta` | `text` |
| `assistant_block` | `text` |
| `reasoning_delta` | `text` |
| `tool_call` | `tool_id`, `name`, `arguments`, `reason` |
| `tool_result` | `tool_id`, `name`, `ok`, `text` |
| `approval_request` | `ask_id`, `summary`, `reason`, `options[{key,caption}]` |
| `approval_resolved` | `ask_id`, `choice` |
| `drive_requested` | `client` |
| `drive_granted` | `client` |
| `drive_released` | `client` |
| `turn_finished` | `finish_reason`, `usage`, `elapsed_ms` |
| `error` | `code`, `message`, `detail`, `dropped` |
| `gap` | `from_seq`, `to_seq` |
| `loop_exited` | `reason` |
| `reasoning_done` | `elapsed_ms` (the reasoning phase's duration) |
| `tool_output` | `tool_id`, `name`, `text` (a streamed chunk) |

### Event Contracts

- Events are emitted by the runtime on its own thread and serialized by the
  protocol layer; a client's decoder runs on the client's thread. No callback
  crosses threads in v1.

## Architecture

### Prior Art & Reuse

- **`TTurnEvent`** (`hildi.harness.turn`) is the in-process event
  shape this protocol externalizes; the kinds map closely, and the flat-record
  style is reused.
- **`TSSEParser`** (`hildi.llm`) is prior art for a line-oriented,
  incremental stream reader; the NDJSON reader follows the same discipline
  (buffer partial lines, dispatch whole ones).
- **`fpjson`** is the JSON layer already in use; the codec adds no dependency.
- **`TApprovalAsk`/`TApprovalChoice`** are reused verbatim in the payloads.

The gap is the wire schema, the codec, and the framing — none of which exist.

### Component Boundaries

- **Responsibilities:** the codec is pure (record ⇄ line). The protocol spec
  owns the schema; the transport (in `Session_Runtime`) owns the socket.
- **Dependencies:** `fpjson`, the approval types, the LLM usage type.
- **Side effects:** none; the codec is a function.

### Data Flow

1. The runtime emits a `TSessionEvent`; the protocol layer encodes it to a line
   and writes it to each attached connection.
2. A client reads lines, decodes them, and maps events to its rendering.
3. A client writes a `TSessionCommand` line; the runtime decodes it, acts, and
   writes a `reply`.

### Integration Patterns

- Synchronous, single-threaded per side; the runtime serializes writes to its
  connections. No shared mutable state crosses the wire.

## Validation Rules

### Input

- A line must be valid JSON with an integer `v`, a known `type`, and the fields
  that type requires; otherwise `error` + close.
- `role` must be `observe` or `drive`.
- `from_seq` must be `>= 0`.

### Output Guarantees

- `seq` is monotonic and gap-free within a loop except across a `gap`.
- A `reply` always carries the `id` of its `cmd`.
- An event's `kind` is always one of the fixed set.

## Error Handling

### Error Types

- **Protocol errors** (`bad_version`, `bad_message`, `too_long`, `unknown_cmd`)
  → an `error` message, then a close for framing errors.
- **Authority errors** (`not_driver`) → a `reply{ok:false,error:"not_driver"}`;
  the connection stays open.
- **Runtime errors** → an `event{kind:"error"}`; the stream continues.

### Error Contracts

Wire errors use a stable string `code`; the client maps them to its own
presentation. Process-level exit codes are unchanged.

## Testing Requirements

### Unit Tests

- [ ] `TestCodecRoundTrip` for every message type and event kind.
- [ ] `TestCodecRejectsBadJson`, `TestCodecRejectsUnknownType`.
- [ ] `TestCodecRejectsOversizeLine`.
- [ ] `TestAttachedCarriesStoreHwm`.
- [ ] `TestReconciliationDropsCoveredEvents` (a block committed in the window).

### Integration Tests

- [ ] `TestAttachReplaysLiveTurn` — a scripted client attaches mid-turn and sees
      the whole turn from `seq` 0.
- [ ] `TestSecondDriverGetsObserve` and `TestClaimDriveNeedsConsent`.
- [ ] `TestSlowObserverGetsGap`.
- [ ] `TestStaleSocketIsRecovered`.

## Performance Targets

- Encode/decode a small event in microseconds; no allocation churn beyond the
  JSON value.
- A streamed turn at token rate does not saturate the socket or the CPU.

## Security Considerations

- The socket lives in a `0700` directory: same-user access only in v1.
- Events carry no secrets beyond what the ledger already holds; the API key is
  never on the wire.
- Framing limits bound memory against a hostile or garbled client.

## Success Criteria

### Functional

- [ ] All message types and event kinds encode, decode, and round-trip.
- [ ] The reconciliation rule is enforced and tested.
- [ ] `make check` passes.

### Quality

- [ ] The codec is pure and unit tested without a socket.
- [ ] The schema is transport-agnostic (no socket assumptions in the types).

## Future Considerations

- A JSON-RPC codec and an SSE/WebSocket transport over the same schema.
- A binary framing for the network link.
- Compression for high-volume streams.
- A Windows transport binding (TCP loopback + token, or named pipes) — see
  [`docs/guidelines/windows-portability.md`](../../guidelines/windows-portability.md).
