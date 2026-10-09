# Context Budget

## Overview

Faithful history keeps the whole conversation - including full tool output - so
the model can reason over what it actually did. But a single `run_command` can
return megabytes, and resending every byte on every request is expensive,
slow, and eventually impossible.

This feature keeps the history faithful **on disk** while bounding what enters
the **prompt**: a tool result over a configured cap is stored in full as a
**session artifact** (its persisted message), and the prompt carries a truncated
head plus a reference. A new `recall_tool_result` tool lets the model read the
artifact in windowed slices, so it can still inspect what it needs.

The recall tool is deliberately special: it **caps but never spills**. Reading
an artifact cannot create another artifact, so inspecting a large result never
produces a tree of partials of the thing being inspected.

## Problem Statement

Tool output is unbounded. Today the SQLite adapter recomposes the full
conversation for every request, so a large `run_command` or `file_read` result
is re-sent on every subsequent request in the loop and on every resumed turn.
That is the dominant cost of a long session and the most likely way to exceed a
model's context window. Truncating and forgetting would lose the operator's
audit trail and the model's ability to inspect the output; truncating and
storing, with a recall path, loses neither.

## Goals

- Bound the bytes any single tool result contributes to a prompt.
- Keep the full result durably, addressable, and renderable.
- Give the model a windowed way to read a spilled result.
- Never spill from the recall tool itself (cap only).
- Keep the caps configurable and the behaviour testable without a provider.

## User Stories

- As an **operator**, I want a huge tool output to stay in the session history
  in full, so the audit is complete, without it being re-sent on every request.
- As the **model**, I want a truncated result to tell me how to read more, so I
  can inspect the part I need instead of guessing.
- As a **harness author**, I want the cap applied in one place, so the loop and
  the provider view stay simple.

## Acceptance Criteria

### Functional Requirements

- [ ] A tool result longer than the cap is stored in full in its message row.
- [ ] When recomposing the prompt, a tool result over the cap is replaced by a
      head of at most the cap plus a marker naming the artifact and the recall
      tool.
- [ ] `recall_tool_result` returns a windowed slice of a stored tool result by
      its message id, offset, and limit.
- [ ] A recall result over the cap is truncated to the cap and **not** spilled
      or marked for further recall.
- [ ] An unknown or non-tool message id is a clear error result.
- [ ] Caps are configurable (defaults documented); `0` disables capping.
- [ ] Rendering is unaffected: the UI still shows the full stored result.

### Non-Functional Requirements

- [ ] Leak-clean; the cap check is O(1) per tool message.
- [ ] No new dependency; the artifact is the existing message row.
- [ ] `make check` passes.

## Success Metrics

### Quantitative

- A prompt containing a 1 MB tool result carries at most the cap plus the
  marker.
- A recall slice returns exactly the requested window (clamped).

### Qualitative

- The model can recover any byte of a spilled result, in order, without the
  operator losing the full record.

## Constraints

### Technical

- Depends on Sessions v2 (`messages` with full tool content and ids).
- Must not change the provider message shape beyond the truncated content.
- Caps apply to the prompt view only; storage and rendering are full.

## Dependencies

### Internal

- Sessions v2 - `messages`, `TSqliteConversationStore`, the store.
- `hildegard.helper.agent` - tool registration and the loop.

### External

- None.

## Risks

- **Truncation hides a detail the model needs.** Mitigation: the marker names
  the artifact and the tool; the model can recall any window.
- **Recall output is itself large.** Mitigation: the recall tool caps and never
  spills, so it cannot amplify.
- **Caps too small/large.** Mitigation: configurable with documented defaults.

## Out of Scope

- Summarising or compacting old turns.
- File-based artifacts (the message row is the artifact in v1).
- Semantic search over artifacts.

## Future Considerations

- File-backed artifacts for very large outputs.
- Per-tool caps.
- Compaction of old turns into summaries.

## Notes

- **ICE score: Impact 8, Confidence 7, Ease 6.** Depends on Sessions v2; the
  new pieces are the cap in the adapter and one tool.
- **Reuse note (Ponytail):** the artifact is the existing message row and the
  recall tool is a normal registered tool; nothing new is stored.
