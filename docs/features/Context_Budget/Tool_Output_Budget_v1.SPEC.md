# Component Specification: Tool Output Budget v1

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

Bound the bytes a tool result contributes to a prompt while keeping the full
result as a durable session artifact, and expose a windowed
`recall_tool_result` tool that caps (but never spills) its own output.

Depends on `../../Sessions_And_Ledger/Sessions_v2.SPEC.md`.

## Requirements

### Functional

- [ ] `TSqliteConversationStore` takes a `ToolResultCap` (bytes; 0 = no cap).
- [ ] When recomposing `Messages`, a `crTool` result longer than the cap is
      replaced by its first `cap` bytes plus a marker naming the message id and
      `recall_tool_result`.
- [ ] `recall_tool_result` returns a slice of a stored tool result given
      `message_id`, `offset`, `limit`, clamped to the artifact.
- [ ] A recall slice over the cap is truncated to the cap and is **not** marked
      for further recall.
- [ ] An unknown id, a non-tool id, or a negative offset is an error result.
- [ ] The cap defaults are documented; the recall cap defaults to the tool
      result cap.

### Non-Functional

- [ ] Leak-clean; no new storage; no new dependency.
- [ ] O(1) cap check per tool message when composing the prompt.

## Contracts & Interfaces

```pascal
type
  { Adapter additions. }
  TSqliteConversationStore = class(TInterfacedObject, IConversationStore)
    ...
    property ToolResultCap: Integer read FToolResultCap write FToolResultCap;
  end;

  { Registered as a normal tool; its handler is bound to the store and session. }
  TRecallTool = class
  public
    constructor Create(AStore: TSqliteStore; const ASessionId: string;
      ACap: Integer);
    function Recall(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
  end;
```

Tool name: `recall_tool_result`. Parameters:
`{ "message_id": integer, "offset": integer, "limit": integer, "reason": string }`
(`reason` is the standard required tool reason).

Marker appended to a capped prompt result:

```
[output truncated: <total> bytes total; message_id=<id>; use recall_tool_result
 with offset/limit to read more]
```

### Data Contracts

- The artifact is the `messages` row with `role = mrTool`; its `content` is the
  full output.
- A slice is `Copy(content, offset + 1, limit)`; `offset` is 0-based.

## Architecture

### Prior Art & Reuse

- The persisted tool message is the artifact - no new table, no file store.
- The recall tool is a normal `TToolRegistry` tool with a bound handler, like
  `run_command` and `file_read`.

### Component Boundaries

- **Adapter** owns the prompt-view cap; it has the records and their ids.
- **Recall tool** owns windowed reads; it caps and never spills.
- **Loop** is unchanged: it still appends and replays messages.

### Data Flow

1. A tool runs; the full result is appended as a `mrTool` message.
2. `Messages` composes the prompt, capping any tool result over `ToolResultCap`
   and appending the marker.
3. The model calls `recall_tool_result`; the handler reads the row and returns a
   capped slice.
4. The slice is appended as a normal tool result (full content stored; the
   prompt view caps it like any other).

## Validation Rules

- `message_id` must exist and have `role = mrTool`; otherwise error.
- `offset >= 0`; `limit > 0` (default the cap); both clamped to the artifact.
- A slice is never empty when the artifact has bytes at `offset`.

## Error Handling

- The recall handler returns `False` with an error string, which the loop turns
  into an error tool result (existing behaviour).
- Adapter store failures are swallowed as elsewhere in `IConversationStore`.

## Testing Requirements

- [ ] `TestPromptCapsLargeToolResult` (content truncated, marker present, id
      correct).
- [ ] `TestPromptLeavesSmallToolResultIntact`.
- [ ] `TestCapZeroDisablesTruncation`.
- [ ] `TestRecallReturnsWindow`.
- [ ] `TestRecallClampsToArtifact`.
- [ ] `TestRecallCapsAndDoesNotMark` (a slice at the cap is not marked).
- [ ] `TestRecallUnknownIdFails`, `TestRecallNonToolIdFails`.
- [ ] `TestRenderStillShowsFullResult` (the message row is untouched).

## Performance Targets

- One length check per tool message; one indexed read per recall.

## Security Considerations

- Artifacts may hold sensitive output; they are already owner-only and never
  logged. The marker exposes only the message id, not content.

## Success Criteria

- [ ] All contracts implemented; `make check` green.
- [ ] A capped prompt and a working recall path, proven by tests.

## Future Considerations

- File-backed artifacts for very large outputs.
- Per-tool caps and a global turn budget.
