# Issue: session memory is not trimmed by a checkpoint

**Status:** fixed (both proposed code changes landed; see "Proposed fix" below)
**Area:** session runtime + store (`hildi.session.runtime`,
`hildi.session.store`), not `Context_Checkpoint` itself
**Symptom:** memory stays high when a session is resumed from a new checkpoint,
even though the prompt sent to the model is small.

## Summary

A checkpoint trims the **context window** (what goes to the model), but it does
**not** trim the process's **retained memory**. Two places still walk the whole
session history on the hot path — `Compose` re-reads all rows per request, and
the in-memory store never filters — so a long session resumed from a checkpoint
still pays for everything before it. (A third, the runtime replay log, turns out
to be per-turn bounded; only its append shape is worth fixing.)

## What the checkpoint does trim (correct)

`TSqliteConversationStore.Compose` (`session.store.pas:250`) filters at the
boundary: leading system messages, then the checkpoint summary block, then only
messages after `Snap.Seq`. Pre-boundary messages are skipped
(`// Archived (before the checkpoint): not replayed`, `:280`). `TAgentLoop`
holds no history of its own — `BuildRequest` reads `FStore.Messages`
(`agent.pas:890`) — so the **prompt is correctly trimmed**.

## What is *not* trimmed

### 1. `Compose` loads the entire history before filtering — the likely culprit

```pascal
if not FStore.QueryMessages(FSessionId, Msgs, Err) then   // :250 — ALL rows
...
if (Boundary > 0) and (Msgs[I].Seq <= Boundary) then ...  // :280 — then filter
```

Each `Messages` call (i.e. each request) materialises the **full** session
history into a temporary `TChatMessageArray` before discarding the archived
part. Transient, but O(history) per request — and `Messages` is called on
*every* request (`BuildRequest` → `FStore.Messages`), so a long resumed session
re-reads and re-allocates everything it no longer needs, on every turn.

### 2. The runtime replay log — per-turn bounded, but grows by one

```pascal
FReplay: array of TSessionEvent;          // session.runtime.pas:91
...
SetLength(FReplay, Length(FReplay) + 1);  // :438
FReplay[High(FReplay)] := AEvent;
```

**Correction:** `FReplay` is *not* session-lifetime. It is reset twice per turn —
`EmitLoopStarted` (`:416`) and `FinishTurn` (`:1200`, called from `teDone` and
`teError`) both do `SetLength(FReplay, 1)`. So it is bounded by **one turn's**
events, not the whole session; resuming from a checkpoint does not touch it.

The one real cost that remains is the append shape:

- **O(n²) growth** — `SetLength(n+1)` reallocates (and copies) per event; a
  chatty turn's streaming deltas (`ekAssistantDelta`/`ekReasoningDelta`) can run
  to thousands of events. Same grow-by-one shape fixed in `TTurnQueue`; `:438`
  should grow by capacity (or use a ring).

### 3. The in-memory store does not filter at all

```pascal
function TMemoryConversationStore.Messages: TChatMessageArray;
begin
  Result := Copy(FItems, 0, Length(FItems));   // agent.pas:584
end;
```

No checkpoint filtering (tests/CLI, so not the TUI case, but noted).

## Proposed fix (when picked up)

**Done:**

1. **Query after the boundary** — `Compose` now uses two windowed queries:
   `QueryLeadingSystemMessages` (new; the session setup prompt, never archived)
   plus `QueryMessagesAfter(max(boundary, lastLeadSeq))` for the tail, instead of
   loading the whole history and filtering. The system prompt is fetched
   separately, so it is not lost to the boundary and not double-emitted.
2. **Grow `FReplay` by capacity** — `ReplayPush` doubles the buffer (start 16)
   instead of `SetLength(n+1)`, so the per-turn append is amortised rather than
   O(n²); `ReplayReset` keeps the allocation across turns.

**Remaining:**

3. **Checkpoint-filter the in-memory store** for parity.

## Why this is filed separately

The `Context_Checkpoint` work is correct — it trims the prompt as designed. This
is the **runtime/store retention** underneath it, which the checkpoint does not
touch. Filed here (not in the feature docs) so it does not collide with in-flight
edits to `docs/features/Context_Checkpoint/`.
