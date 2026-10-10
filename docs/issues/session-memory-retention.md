# Issue: session memory is not trimmed by a checkpoint

**Status:** open, deferred (documented while other work is in flight)
**Area:** session runtime + store (`hildegard.helper.session.runtime`,
`hildegard.helper.session.store`), not `Context_Checkpoint` itself
**Symptom:** memory stays high when a session is resumed from a new checkpoint,
even though the prompt sent to the model is small.

## Summary

A checkpoint trims the **context window** (what goes to the model), but it does
**not** trim the process's **retained memory**. Three places still hold the whole
session history, so a long session resumed from a checkpoint still pays for
everything before it.

## What the checkpoint does trim (correct)

`TSqliteConversationStore.Compose` (`session.store.pas:250`) filters at the
boundary: leading system messages, then the checkpoint summary block, then only
messages after `Snap.Seq`. Pre-boundary messages are skipped
(`// Archived (before the checkpoint): not replayed`, `:280`). `TAgentLoop`
holds no history of its own — `BuildRequest` reads `FStore.Messages`
(`agent.pas:890`) — so the **prompt is correctly trimmed**.

## What is *not* trimmed

### 1. The runtime replay log — the likely culprit

```pascal
FReplay: array of TSessionEvent;          // session.runtime.pas:91
...
SetLength(FReplay, Length(FReplay) + 1);  // :438
FReplay[High(FReplay)] := AEvent;
```

Every event of the session is retained for the life of the session, for
back-pagination (`ReplayTo`, `:554`). It is **never pruned**, not even at a
checkpoint. Two costs:

- **Unbounded retention** — every assistant/reasoning delta, tool chunk and
  status event stays in RAM.
- **O(n²) growth** — `SetLength(n+1)` reallocates per event (the same
  grow-by-one shape fixed in `TTurnQueue`).

### 2. `Compose` loads the entire history before filtering

```pascal
if not FStore.QueryMessages(FSessionId, Msgs, Err) then   // :250 — ALL rows
...
if (Boundary > 0) and (Msgs[I].Seq <= Boundary) then ...  // :280 — then filter
```

Each `Messages` call (i.e. each request) materialises the **full** session
history into a temporary `TChatMessageArray` before discarding the archived
part. Transient, but O(history) per request.

### 3. The in-memory store does not filter at all

```pascal
function TMemoryConversationStore.Messages: TChatMessageArray;
begin
  Result := Copy(FItems, 0, Length(FItems));   // agent.pas:584
end;
```

No checkpoint filtering (tests/CLI, so not the TUI case, but noted).

## Proposed fix (when picked up)

1. **Bound `FReplay`** — a ring buffer, or prune it at the checkpoint horizon
   (the same treatment `TTurnQueue` got). This is the main win.
2. **Query after the boundary** — `QueryMessagesAfter` already exists
   (`store.pas:239`); `Compose` should use it instead of loading everything and
   filtering.
3. **Checkpoint-filter the in-memory store** for parity.

## Why this is filed separately

The `Context_Checkpoint` work is correct — it trims the prompt as designed. This
is the **runtime/store retention** underneath it, which the checkpoint does not
touch. Filed here (not in the feature docs) so it does not collide with in-flight
edits to `docs/features/Context_Checkpoint/`.
