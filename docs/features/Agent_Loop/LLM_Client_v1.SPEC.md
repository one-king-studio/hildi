# Component Specification: LLM Client

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildi.llm` is the provider boundary for the Agent Loop. It turns a
request (messages plus tool declarations) into an OpenAI-compatible chat
completion call over HTTPS, reads the **streamed** SSE response, surfaces text
deltas as they arrive, and returns a complete assistant message with its tool
calls and finish reason. It is the only unit that knows about HTTP, TLS, SSE,
and the provider's JSON shape.

The network boundary is expressed as an injectable transport so the whole client
can be tested offline against canned SSE streams.

## Requirements

### Functional

- [ ] Build an OpenAI-compatible chat-completions request from messages and
      tools, with `stream` enabled.
- [ ] POST over HTTPS with the API key in an authorization header.
- [ ] Read the response as a byte stream and parse SSE frames incrementally.
- [ ] Emit text deltas through a callback as they arrive.
- [ ] Accumulate tool-call deltas across frames by index (id, name, arguments).
- [ ] Capture the terminal `finish_reason`.
- [ ] Return a complete assistant message and mapped errors.
- [ ] Load configuration from a config record, defaulting from the environment.

### Non-Functional

- Performance: streamed text observable before the response completes; no
  full-body buffering before the first delta.
- Reliability: every allocated HTTP client/stream/JSON object is freed; errors
  never escape as uncaught exceptions.
- Portability: macOS and Linux, FPC 3.3.1, `{$mode delphi}`.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

### Public API

```pascal
unit hildi.llm;

type
  TChatRole = (crSystem, crUser, crAssistant, crTool);

  TChatToolCall = record
    Id: string;
    Name: string;
    Arguments: string;          // raw JSON string as sent by the provider
  end;

  TChatMessage = record
    Role: TChatRole;
    Content: string;
    ToolCallId: string;                     // set on tool results
    ToolCalls: array of TChatToolCall;      // set on assistant messages
  end;

  TChatMessageArray = array of TChatMessage;
  TChatToolCallArray = array of TChatToolCall;

  TToolSpec = record
    Name: string;
    Description: string;
    ParametersJson: string;     // JSON schema object, sent verbatim
  end;

  TToolSpecArray = array of TToolSpec;

  TFinishReason = (frStop, frToolCalls, frLength, frContentFilter, frUnknown);

  TChatRequest = record
    Messages: TChatMessageArray;
    Tools: TToolSpecArray;
  end;

  TChatResult = record
    Message: TChatMessage;      // assistant message: content and/or tool calls
    FinishReason: TFinishReason;
    RawFinishReason: string;    // provider string, for diagnostics
  end;

  TLLMErrorCode = (
    leOk,
    leConfig,           // missing key/model/endpoint
    leNetwork,          // connect/read/TLS failure
    leHttpStatus,       // non-2xx response
    leAuth,             // 401/403
    leRateLimit,        // 429
    leMalformedStream,  // SSE/JSON could not be parsed
    leProvider          // provider returned an error object
  );

  TLLMError = record
    Code: TLLMErrorCode;
    Message: string;
    Detail: string;       // status code, provider error; never the API key
  end;

  { Per-chunk text callback. Invoked on the calling thread. Empty-text
    tool-call frames do not invoke it. }
  TLLMTextEvent = procedure(const AText: string) of object;

  { Raw response-body callback used by the transport. }
  TLLMChunkEvent = procedure(const AData: RawByteString) of object;

  TLLMConfig = record
    Endpoint: string;      // full URL; '' -> default (Fireworks)
    Model: string;         // required; '' resolved from environment
    ApiKey: string;        // required; '' resolved from environment
    ConnectTimeoutMs: Integer;   // 0 => default (10000)
    ReadTimeoutMs: Integer;      // 0 => default (120000)
  end;

  { Streaming transport. The default implementation uses fphttpclient; tests
    inject a fake. Ownership stays with the caller. }
  TLLMTransport = class
  public
    function PostStream(const AURL: string; const ABody: string;
      const AHeaders: TStringList; AOnChunk: TLLMChunkEvent;
      out AStatusCode: Integer; out AError: string): Boolean; virtual; abstract;
  end;

  TFPHTTPTransport = class(TLLMTransport)
  public
    function PostStream(const AURL: string; const ABody: string;
      const AHeaders: TStringList; AOnChunk: TLLMChunkEvent;
      out AStatusCode: Integer; out AError: string): Boolean; override;
  end;

  TLLMClient = class
  public
    { ATransport = nil creates a TFPHTTPTransport owned by the client. }
    constructor Create(const AConfig: TLLMConfig; ATransport: TLLMTransport);
    destructor Destroy; override;
    function Complete(const ARequest: TChatRequest; AOnText: TLLMTextEvent;
      out AResult: TChatResult; out AError: TLLMError): Boolean;
  end;

{ Fill missing config fields from HILDI_LLM_ENDPOINT/MODEL/API_KEY and
  FIREWORKS_API_KEY (first non-empty wins). }
function ResolveLLMConfig(const AConfig: TLLMConfig): TLLMConfig;

const
  DefaultLLMEndpoint = 'https://api.fireworks.ai/inference/v1/chat/completions';
```

### Data Contracts

Tool call is emitted by the provider split across frames:

```json
{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function",
  "function":{"name":"get_system_time","arguments":""}}]}}]}
{"choices":[{"delta":{"tool_calls":[{"index":0,
  "function":{"arguments":"{\"tz\":"}}]}}]}
{"choices":[{"delta":{"tool_calls":[{"index":0,
  "function":{"arguments":"\"utc\"}"}}]}}]}
```

Accumulation rules:

- Tool calls are keyed by `index`; the first frame carrying an index creates the
  entry, later frames append `function.name` and `function.arguments`.
- Text arrives as `choices[0].delta.content`.
- Role arrives in the first frame (`delta.role`) and is otherwise ignored; the
  result is always an assistant message.
- `choices[0].finish_reason` on the final frame maps to `TFinishReason`;
  unknown strings map to `frUnknown` with `RawFinishReason` set.

### Event Contracts

- `TLLMTextEvent` fires for each non-empty content delta, on the thread that
  called `Complete` (single-threaded by design).
- `TLLMChunkEvent` is the transport's raw-body hook; the client's SSE parser
  consumes it and never surfaces raw frames.

## Architecture

### Prior Art & Reuse

- **HTTP/TLS:** `fphttpclient` (fcl-web) with `opensslsockets`. Verified on this
  platform (macOS aarch64, FPC 3.3.1): HTTPS works with no extra unit paths or
  linker flags. `TFPCustomHTTPClient.ReadResponse` writes each socket read into
  the supplied `TStream` (and fires `OnDataReceived` per read), so passing a
  custom `TStream` yields incremental SSE with no third-party dependency.
- **JSON:** `fpjson` / `jsonparser` (FPC). Do not hand-parse JSON.
- **No new dependency:** the SSE parser is a small state machine over the
  transport's chunks.

The gap is: request/response mapping, the SSE state machine, tool-call
accumulation, and error mapping.

### Component Boundaries

- **Responsibilities:** config resolution, request serialization, HTTPS POST,
  SSE parsing, tool-call accumulation, finish-reason mapping, error mapping.
- **Dependencies:** `fphttpclient`, `opensslsockets`, `fpjson`, `Classes`,
  `SysUtils`.
- **Side effects:** outbound network I/O (or nothing, when a fake transport is
  injected).

### Data Flow

1. **Resolve:** `ResolveLLMConfig` fills missing fields from the environment.
   A missing `Model` or `ApiKey` fails with `leConfig` before any I/O.
2. **Serialize:** build the JSON body: `model`, `messages` (role/content plus
   `tool_calls` and `tool_call_id` where present), `tools` (name, description,
   `parameters` schema), `stream: true`.
3. **Send:** the transport POSTs and forwards each response chunk to a sink
   `TStream` whose `Write` feeds the SSE parser.
4. **Parse:** an SSE state machine buffers bytes, splits frames on line breaks,
   concatenates `data:` lines per the SSE spec, ignores comments/blank lines, and
   stops on `[DONE]`. Each JSON payload is mapped to deltas.
5. **Accumulate:** text deltas call `TLLMTextEvent`; tool-call deltas accumulate
   by index; the finish reason is recorded.
6. **Return:** on `[DONE]` (or stream end), return the assistant message and
   finish reason. On non-2xx status, parse an optional error body and map it.

### Integration Patterns

- Synchronous and single-threaded: `Complete` blocks until the stream ends. The
  callback fires on the same thread.
- Ownership: the client owns an internally created transport and frees it in
  `Destroy`; an injected transport is owned by the caller. The sink stream and
  the HTTP client are freed on every path.

## Validation Rules

- `Model` and `ApiKey` must be non-empty after resolution; otherwise `leConfig`.
- `Endpoint` must be `https://` (an `http://` endpoint is allowed only for
  tests/loopback and is documented as insecure).
- An empty `Messages` array yields `leConfig` ("nothing to send").
- Tool specs with an empty `Name` are rejected at registration by the tool
  registry (see the Agent Loop spec), not by the client.

## Error Handling

### Error Types

- **Config:** missing key/model/endpoint -> `leConfig`.
- **Network:** connect/read timeout, TLS failure -> `leNetwork`.
- **HTTP status:** non-2xx -> `leHttpStatus`, or `leAuth` (401/403) /
  `leRateLimit` (429).
- **Provider:** a streamed `{"error":{...}}` object -> `leProvider`.
- **Malformed:** unparseable SSE/JSON -> `leMalformedStream`.

`Detail` carries the HTTP status and provider message; it **never** contains the
API key or the authorization header.

## Testing Requirements

All tests run offline against a fake `TLLMTransport` that replays chunk
sequences; no network access.

### Unit Tests (`test_llm.pas`)

- [ ] `TestConfigResolutionPrefersExplicit`
- [ ] `TestConfigResolutionReadsEnvironment`
- [ ] `TestMissingApiKeyFailsBeforeRequest`
- [ ] `TestRequestSerializationIncludesModelMessagesAndTools`
- [ ] `TestRequestSerializationIncludesToolCallsAndToolResults`
- [ ] `TestParsesTextDeltasIncrementally`
- [ ] `TestEmitsTextBeforeStreamEnds`
- [ ] `TestHandlesFramesSplitAcrossChunks`
- [ ] `TestIgnoresCommentsAndBlankLines`
- [ ] `TestStopsOnDoneSentinel`
- [ ] `TestAccumulatesFragmentedToolCallArguments`
- [ ] `TestAccumulatesToolCallNameSplitAcrossFrames`
- [ ] `TestAccumulatesMultipleToolCalls`
- [ ] `TestMapsStopFinishReason`
- [ ] `TestMapsToolCallsFinishReason`
- [ ] `TestMapsUnknownFinishReason`
- [ ] `TestHttpErrorStatusMapsToError`
- [ ] `TestAuthStatusMapsToAuthError`
- [ ] `TestRateLimitMapsToRateLimitError`
- [ ] `TestProviderErrorObjectMapsToProviderError`
- [ ] `TestMalformedStreamMapsToMalformedError`
- [ ] `TestApiKeyNeverAppearsInError`
- [ ] `TestNoLeaks` (enforced by `make test-leak`)

### Integration Tests

- [ ] `TestRealTransportAgainstLoopback` (optional; a local HTTP server serving a
      canned SSE body, skipped when unavailable)

## Performance Targets

- First text delta is delivered before the stream completes.
- No accumulation of the full raw body in memory beyond the SSE buffer.
- Overhead beyond network is negligible for small responses.

## Security Considerations

- The API key is sent only in the authorization header and never logged.
- TLS certificate verification stays at the FPC default (enabled); no override.
- Provider error text is surfaced but the request body (which may contain user
  content) is not logged by default.
- `http://` endpoints are permitted only for local testing and must be called out
  as insecure.

## Success Criteria

- [ ] All contracts implemented and all error scenarios mapped.
- [ ] Streamed text observed before completion in a test.
- [ ] `make check` passes.

## Future Considerations

- Retry/backoff for 429/5xx and idempotent request IDs.
- Optional non-streaming mode for simple calls.
- Additional provider adapters beyond the OpenAI-compatible surface.
- Request/response size and token accounting hooks.
