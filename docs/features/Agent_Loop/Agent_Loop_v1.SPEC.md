# Component Specification: Agent Loop

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildegard.helper.agent` is the reasoning core. It owns the conversation, injects
tools, drives the LLM client, executes the tool calls the model requests, feeds
the results back, and keeps re-querying until a proper stop reason or a bounded
iteration limit. Conversations live behind a small store interface with an
in-memory implementation today and a SQLite-backed one later.

This spec assumes the LLM client from `LLM_Client_v1.SPEC.md`; it does not repeat
provider/SSE details.

## Requirements

### Functional

- [ ] Maintain a multi-turn conversation through a store interface.
- [ ] Register tools (name, description, JSON-schema parameters, handler) and
      advertise them to the client.
- [ ] On each turn, call the client, stream assistant text to a callback, and
      act on the finish reason.
- [ ] Execute every tool call in an assistant message, append tool results, and
      re-query.
- [ ] Stop on `stop`; report `length`/`content_filter` distinctly; abort after a
      bounded number of tool iterations.
- [ ] Isolate tool failures: unknown tools and failing handlers return error
      results to the model without crashing the loop.
- [ ] Provide a built-in `get_system_time` tool.
- [ ] Support a configurable system prompt.
- [ ] Allow the store implementation to be swapped without changing the loop.

### Non-Functional

- Single-threaded and deterministic given a transport.
- Leak-clean under `make test-leak`.
- No network dependency in tests (the client is injected with a fake transport).

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

### Public API

```pascal
unit hildegard.helper.agent;

uses
  hildegard.helper.llm;

type
  { Conversation persistence boundary. The Agent Loop reads and writes only
    through this interface; a SQLite implementation can be added later. }
  IConversationStore = interface
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    procedure Clear;
  end;

  TMemoryConversationStore = class(TInterfacedObject, IConversationStore)
  public
    procedure Append(const AMessage: TChatMessage);
    function Messages: TChatMessageArray;
    procedure Clear;
  end;

  { A tool handler receives the raw JSON arguments string the model produced and
    returns a text result. On failure it returns False with AError set; the loop
    turns that into an error tool result. }
  TToolHandler = function(const AArgumentsJson: string;
    out AResult: string; out AError: string): Boolean of object;

  TRegisteredTool = record
    Spec: TToolSpec;
    Handler: TToolHandler;
  end;

  TToolRegistry = class
  public
    procedure Add(const ASpec: TToolSpec; AHandler: TToolHandler);
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    function Specs: TToolSpecArray;
    function Count: Integer;
  end;

  TAgentConfig = record
    SystemPrompt: string;        // '' => a minimal default
    MaxToolIterations: Integer;  // 0 => default (8)
  end;

  TAgentLoop = class
  public
    constructor Create(AClient: TLLMClient; AStore: IConversationStore;
      ATools: TToolRegistry; const AConfig: TAgentConfig);
    { Appends the user message, drives the loop, and returns the final answer.
      AOnText fires for each assistant text delta. }
    function Send(const AUserText: string; AOnText: TLLMTextEvent;
      out AAnswer: string; out AError: TLLMError): Boolean;
  end;

{ Registers the built-in tools (currently get_system_time). }
procedure RegisterDefaultTools(ATools: TToolRegistry);

const
  DefaultMaxToolIterations = 8;
  BuiltinGetSystemTimeName = 'get_system_time';
```

### Data Contracts

Conversation ordering the provider requires:

1. Optional system message.
2. User message.
3. Assistant message, including any `ToolCalls`.
4. One `crTool` message per tool call, carrying `ToolCallId`, `Content` = the
   result text. Tool messages immediately follow the assistant message and appear
   in the same order as the calls.
5. Next user message (next turn), and so on.

Tool-result content on failure is a short error string (for example
`error: unknown tool "foo"`), never an exception.

### Event Contracts

- `TLLMTextEvent` (from the client) fires on the calling thread during `Send`.
- The loop emits no other events.

## Architecture

### Prior Art & Reuse

- `hildegard.helper.llm` (this feature) for provider I/O and streaming.
- `fpjson` for parsing tool arguments when a handler needs them; handlers decide
  their own argument handling.
- The SQLite store (`hildegard.helper.store`) already provides a request queue and
  settings; a future `IConversationStore` implementation can persist messages
  there. v1 does **not** wire that up.

The gap: the loop state machine, the tool contract/registry, the conversation
interface, and the default tools.

### Component Boundaries

- **Responsibilities:** conversation state, tool registration and dispatch, turn
  orchestration, stop-reason policy, iteration bounding.
- **Dependencies:** `hildegard.helper.llm`, `fpjson`, `Classes`, `SysUtils`.
- **Side effects:** none directly; tool handlers may have side effects.

### Data Flow

1. `Send` appends the user message to the store.
2. Loop: call `TLLMClient.Complete` with the store's messages and the registry's
   specs; stream text via `AOnText`.
3. Append the assistant message verbatim.
4. If `FinishReason` is `frToolCalls`: for each call, look up the tool; execute
   it; append a `crTool` result. Increment the iteration count and go to 2.
5. If `frStop`: set `AAnswer` from the assistant content and return True.
6. If `frLength`/`frContentFilter`/`frUnknown`: return False with a mapped
   `TLLMError`.
7. If the iteration count exceeds `MaxToolIterations`: return False with an error;
   the conversation is left intact for inspection.

### Integration Patterns

- Synchronous; no threads. Tool handlers run on the calling thread.
- Ownership: the loop does not own the client, store, or registry; it holds
  references. `Send` makes no copies beyond the store's.

## Validation Rules

- `TAgentConfig.MaxToolIterations` <= 0 uses the default.
- A tool spec with an empty `Name` is rejected by `Add` (raises `EArgumentException`
  or is ignored - implementer's choice, documented in code; tests pin the chosen
  behaviour).
- Tool handlers that raise an exception are caught by the loop and converted to
  an error tool result; the loop does not propagate handler exceptions.

## Error Handling

### Error Types

- **Config:** missing client configuration surfaces from the client (`leConfig`).
- **Provider:** client errors propagate as `TLLMError` from `Send`.
- **Tool:** unknown tool or failing handler becomes an error **tool result**, not
  a loop failure.
- **Policy:** `frLength`/`frContentFilter` -> `leProvider` with a descriptive
  message; iteration limit exceeded -> `leProvider` ("tool iteration limit
  reached").

### Error Contracts

`TLLMError` is shared with the LLM client. Tool errors are content, not
`TLLMError`.

## Testing Requirements

Tests use a fake `TLLMTransport` (from the client spec) so the loop is exercised
end to end without network.

### Unit Tests (`test_agent.pas`)

- [ ] `TestSendSingleTurnReturnsAnswer`
- [ ] `TestTextDeltasAreForwarded`
- [ ] `TestToolCallIsExecutedAndFedBack`
- [ ] `TestMultipleToolCallsAllExecuted`
- [ ] `TestUnknownToolReturnsErrorResultAndContinues`
- [ ] `TestFailingHandlerReturnsErrorResultAndContinues`
- [ ] `TestRaisingHandlerIsCaughtAndReported`
- [ ] `TestMaxToolIterationsAborts`
- [ ] `TestLengthFinishReasonReported`
- [ ] `TestContentFilterFinishReasonReported`
- [ ] `TestConversationPersistsAcrossTurns`
- [ ] `TestSystemPromptIncludedFirst`
- [ ] `TestToolResultsFollowAssistantInOrder`
- [ ] `TestStoreIsUsedThroughTheInterface` (a counting fake store)
- [ ] `TestDefaultToolsRegistered` (`get_system_time` present and callable)
- [ ] `TestGetSystemTimeReturnsParseableTime`
- [ ] `TestNoLeaks` (enforced by `make test-leak`)

### Integration Tests

- [ ] `TestLoopAgainstFakeTransportToolRoundTrip` (multi-frame SSE: text, tool
      call, tool result, final answer)

## Performance Targets

- No per-turn copies beyond what the store and client require.
- Iteration bounding prevents unbounded provider calls.

## Security Considerations

- Tool handlers are the trust boundary; the loop invokes only registered tools,
  never a name straight from the model.
- Tool arguments are passed as data (a JSON string), not evaluated.
- The conversation may contain sensitive user content; it is not logged by the
  loop.

## Success Criteria

- [ ] All contracts implemented; tool round trip works end to end.
- [ ] Multi-turn conversation retained in memory.
- [ ] `make check` passes; an interactive CLI example demonstrates it.

## Future Considerations

- **Tool-call reason:** every tool call now requires a non-empty `reason`
  string on the tool-call event and in the advertised schema (see
  `../Command_Tool/Tool_Reason_v1.SPEC.md`). `TToolCallEvent` gained an
  `AReason` parameter as part of that work.
- A SQLite `IConversationStore` for recall, restore, and durable logs.
- Streaming-aware tool-call display in the CLI.
- Context trimming/summarization and token budgets.
- Tool permissioning/approval and per-tool timeouts.
- Sandboxed script compute as a tool (parked feature).
