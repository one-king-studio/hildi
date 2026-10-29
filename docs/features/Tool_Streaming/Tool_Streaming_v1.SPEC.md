# Component Specification: Tool Streaming v1

**Related Feature:** `FEATURE.md` (Tool Streaming)

## Purpose

Give every tool one output seam — an observer with `next` and `complete` — and
carry its stream live to the operator. A tool may flush chunks as it produces
them or complete in a single shot; the same seam covers both. The stream is the
result being produced, so the live view and a resumed view render the same
thing. `run_command` is the first streaming tool; the model defines its own
command timeout, with an optional operator-imposed cap.

## Requirements

### Functional

The seam

- [ ] `TToolObserver` (in `hildi.agent`) is an abstract object with
      `Next(const AText: string)` (flush a chunk) and `Complete` (end the
      stream).
- [ ] `TToolHandler` receives an observer as an optional trailing parameter:
      `function(const AArgumentsJson: string; out AResult: string;
      out AError: string; AObserver: TToolObserver = nil): Boolean of object`.
      Every registered tool takes the parameter; the non-streaming ones ignore
      it, and `nil` (the default) means no live output.
- [ ] `TAgentEvents` gains `OnToolOutput: TToolOutputEvent`
      (`procedure(const AId, AName, AText: string) of object`).
- [ ] `ExecuteToolCalls` passes a concrete observer that forwards `Next` to
      `OnToolOutput` (capturing the call's id and name), then calls `Complete`.

The command tool

- [ ] `ICommandExecutor.Execute` receives the observer; `TProcessCommandExecutor`
      forwards each stdout/stderr chunk to `Next` as it arrives, while still
      collecting the full output for the result.
- [ ] `TCommandToolConfig` gains `MaxTimeoutMs` (0 => no cap); when set, the
      per-call `timeout_ms` is clamped to it. By default the model defines its
      own timeout. `THarnessSession` resolves the optional cap from
      `HILDI_COMMAND_TIMEOUT_MS`.

The live path

- [ ] `TTurnEventKind` gains `teToolOutput`; `TTurnWorker` maps
      `OnToolOutput` to it (`ToolId`, `ToolName`, `Text`).
- [ ] `TSessionEventKind` gains `ekToolOutput` (wire `tool_output`, payload
      `tool_id`, `name`, `text`); `TSessionRuntime` maps `teToolOutput` to it.
- [ ] `TRemoteSink` maps `ekToolOutput` to `teToolOutput`.
- [ ] The app appends a streamed chunk to the live tool block; on
      `teToolResult` it **replaces** the block's body with the authoritative
      result, so live and resume match.
- [ ] The live body is bounded by the same output cap as the result.

### Non-Functional

- [ ] The observer is thread-safe: chunks arrive on the process runner's thread.
- [ ] No per-frame work; a chunk with no client costs nothing.
- [ ] Leak-clean; `make check` passes.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

### Agent (`hildi.agent`)

```pascal
{ A tool's output observer, RxJS-shaped. A streaming tool calls Next for each
  chunk and then returns its result; Complete ends the stream. A single-shot
  tool never calls Next. }
TToolObserver = class
public
  procedure Next(const AText: string); virtual; abstract;
  procedure Complete; virtual; abstract;
end;

{ Fires for each streamed chunk of a tool's output. }
TToolOutputEvent = procedure(const AId, AName, AText: string) of object;

TToolHandler = function(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean of object;

TAgentEvents = record
  ...
  OnToolOutput: TToolOutputEvent;
end;
```

### Command tool (`hildi.command.tool`)

```pascal
TCommandToolConfig = record
  Shell: TShellProfile;
  DefaultCwd: string;
  DefaultTimeoutMs: QWord;   // 0 => ProfileDefaultTimeoutMs
  MaxTimeoutMs: QWord;       // 0 => no cap (the model defines its own)
  MaxOutputBytes: Integer;
end;

ICommandExecutor = interface
  function Execute(const AProfile: TShellProfile; const ACommand, AWorkDir: string;
    ATimeoutMs: QWord; AObserver: TToolObserver;
    out AExecution: TCommandExecution): Boolean;
end;
```

### Turn events (`hildi.harness.turn`)

```pascal
TTurnEventKind = (..., teToolOutput, ...);   // ToolId, ToolName, Text
```

### Session protocol (`hildi.session.protocol`)

```pascal
TSessionEventKind = (..., ekToolOutput, ...);   // wire: 'tool_output'
```

### Data Contracts

| kind | payload |
| --- | --- |
| `tool_output` | `tool_id`, `name`, `text` |

- A chunk is a raw piece of output; chunks concatenate to the result's body.
- The tool block is the same whether the call streamed or not: the authoritative
  result replaces the streamed body on completion.
- The timeout is the model's `timeout_ms`; 0 or absent uses the default. When a
  `MaxTimeoutMs` cap is configured, it is `min(requested, MaxTimeoutMs)`.

## Architecture

### Prior Art & Reuse

- `TCommandRunner` already streams stdout/stderr through `TOutputEvent` and
  enforces a timeout; the executor merely collects today. Forwarding to the
  observer reuses it unchanged.
- The `reasoning_done` work (Turn Stats v2) is the template for a new event kind
  crossing the agent → turn → protocol → driver → app layers.

### Component Boundaries

- **`agent`** owns the observer seam and the per-call forwarding observer.
- **`command.tool`** owns the streaming executor and the optional timeout cap.
- **`harness.turn` / `session.runtime` / `session.protocol`** carry the chunk.
- **`harness.app`** renders it and reconciles it with the result.

### Data Flow

1. `ExecuteToolCalls` creates an observer for the call.
2. The handler runs; a streaming tool calls `Next` per chunk (on the runner
   thread), then returns its result.
3. The observer forwards each chunk to `OnToolOutput`; the worker republishes it
   as `teToolOutput`; the runtime broadcasts `ekToolOutput`.
4. The client's sink maps it to `teToolOutput`; the app appends it to the block.
5. On `teToolResult` the app replaces the block's body with the authoritative
   result.

## Validation Rules

- The observer is optional at the seam (`nil` = no live output); a tool that
  ignores it is single-shot.
- `timeout_ms` is clamped to `MaxTimeoutMs` only when a cap is configured.

## Error Handling

- A handler that raises is the loop's existing tool-failure path.
- A chunk after `Complete` is ignored.
- A timeout still returns the collected output with the timeout note.

## Testing Requirements

### Unit Tests

- [ ] `TestObserverForwardsChunksAndCompletes`.
- [ ] `TestSingleShotToolEmitsNoChunks`.
- [ ] `TestRunCommandStreamsOutput` (a fake executor emitting chunks).
- [ ] `TestCommandTimeoutIsClampedToMax`.
- [ ] `TestToolOutputRoundTrip` (the protocol event).

### Integration Tests

- [ ] `TestWorkerEmitsToolOutput` (a fake tool streaming through the worker).
- [ ] `TestAppStreamsToolOutput` (chunks land in the live block, then the
      result replaces the body).
- [ ] `TestResumeShowsTheResult` (a resumed block equals the live final body).

## Performance Targets

- No per-frame work; the observer is a straight call.

## Security Considerations

- Streamed output is tool output, already capped and shown to the operator; no
  new content reaches the model beyond the existing result.

## Success Criteria

### Functional

- [ ] Every tool shares the observer seam.
- [ ] `run_command` streams live end-to-end.
- [ ] The command timeout is the model's, with an optional operator cap.

### Quality

- [ ] `make check` green; no leaks.

## Future Considerations

- Cancelling an in-flight tool from the UI (a handle from the loop to the
  running tool).
- Backpressure for a very fast producer.
- Per-chunk styling (stderr dimmed, progress bars).
