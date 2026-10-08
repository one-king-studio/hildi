# Component Specification: Context Checkpoint v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.store` (messages, checkpoints, FTS),
`hildegard.helper.session.protocol`, `hildegard.helper.session.runtime`,
`hildegard.helper.harness.session` / `view`, `hildegard.helper.tui.app`,
`hildegard.helper.recall.tool`.

## Purpose

Implement the checkpoint: a **checkpoint** table, a **resume window** that starts
from the latest checkpoint, a **whole-session FTS5 recall**, and the operator UX
(`/checkpoint`, boundary, back-pagination). **One session id**; nothing is
deleted.

The checkpoint document is produced by an **ordinary turn**, not an out-of-band
call (see the FEATURE decision): `/checkpoint` queues the summarization
instruction as an **ambient** message and runs an ambient turn, the assistant's
reply to that turn *is* the document, and the runtime records the checkpoint at
the turn boundary when the turn completes.

## Requirements

### Functional

- [ ] **Store: checkpoints.** A `session_checkpoints` table (migration) with
      `(session_id, seq, summary, created_at)`. `SaveCheckpoint` records a
      checkpoint at the current message high-water mark; `LatestCheckpoint` returns
      the most recent; `ListCheckpoints` returns all (for a chain view).
- [ ] **Store: resume window.** `QueryActiveMessages(session, out msgs)` returns
      messages with `seq > latestCheckpoint.seq` (or all when no checkpoint).
      `QueryMessagesBefore(session, seq, limit, out msgs)` returns the archived
      page for back-pagination.
- [ ] **Store: FTS5.** A `messages_fts` virtual table (FTS5) over message
      fields; rows are indexed on append (same transaction). `SearchMessages`
      runs a query, optionally **column-scoped** (`tool_reason`, `tool_name`,
      `tool_arguments`, `content`, `label`). A migration backfills existing
      messages.
- [ ] **Build**: the vendored SQLite compiles with `-DSQLITE_ENABLE_FTS5`.
- [ ] **Protocol**: `scCheckpoint` (driver-only) starts a **checkpoint turn**.
      Event: `ekCheckpointCommitted` carries the recorded boundary `seq`, so the
      client reloads the transcript.
- [ ] **The turn**: the runtime queues the summarization instruction as an
      **ambient** message and runs an ambient turn; it streams like any turn and
      the ledger records it.
- [ ] **Commit**: when that turn completes normally the runtime records a
      checkpoint at the current HWM with the assistant's reply as the summary; the
      session's **active window** becomes "summary + messages after the boundary".
      Nothing is deleted. A failed or empty turn records nothing.
- [ ] **Resume**: opening/attaching a session loads the active window — the
      latest checkpoint's summary prepended, then messages after its `seq`. The
      TUI renders the summary as the segment's opening block.
- [ ] **Back-pagination**: the TUI can load the previous segment
      (`QueryMessagesBefore`) with a visible "— checkpoint —" boundary.
- [ ] **Recall**: `recall_tool_result` (or a new recall tool) searches the FTS
      index across **archived and current** messages; a query may scope to
      structured columns so it does not scan `content`.
- [ ] **Nudge**: the TUI hints `/checkpoint` past a configurable threshold; never
      triggers.

### Non-Functional

- [ ] **Non-destructive**: a checkpoint inserts one checkpoint row; no message is
      deleted, rewritten, or reordered.
- [ ] Indexing is incremental and in the append transaction (no drift).
- [ ] `make check` green; leak-clean.

## Contracts & Interfaces

```pascal
unit hildegard.helper.store;   // additions

type
  TCheckpointRecord = record
    SessionId: string;
    Seq: Int64;              // the boundary: messages with seq <= Seq are archived
    Summary: string;         // the checkpoint document (prose)
    CreatedAtMs: Int64;
  end;
  TCheckpointArray = array of TCheckpointRecord;

  TSqliteStore = class
    // ... existing ...
    { Record a checkpoint at the session's current message HWM. }
    function SaveCheckpoint(const ASessionId, ASummary: string;
      out ASeq: Int64; out AError: TStoreError): Boolean;
    { The most recent checkpoint; seNotFound when none. }
    function LatestCheckpoint(const ASessionId: string; out ASnap: TCheckpointRecord;
      out AError: TStoreError): Boolean;
    { All checkpoints, oldest first. }
    function ListCheckpoints(const ASessionId: string; out ASnaps: TCheckpointArray;
      out AError: TStoreError): Boolean;
    { Active window: messages with seq > latest checkpoint seq (all when none). }
    function QueryActiveMessages(const ASessionId: string;
      out AMessages: TMessageRecordArray; out AError: TStoreError): Boolean;
    { Archived page for back-pagination: the last ALimit messages with
      seq <= ABeforeSeq, oldest first. }
    function QueryMessagesBefore(const ASessionId: string; ABeforeSeq: Int64;
      ALimit: Integer; out AMessages: TMessageRecordArray;
      out AError: TStoreError): Boolean;
    { Whole-session FTS. AColumns empty searches all; otherwise restrict to the
      named columns (tool_reason, tool_name, tool_arguments, content, label). }
    function SearchMessages(const ASessionId, AQuery: string;
      const AColumns: array of string; ALimit: Integer;
      out AMessages: TMessageRecordArray; out AError: TStoreError): Boolean;
  end;
```

```pascal
unit hildegard.helper.session.protocol;   // additions

type
  TSessionCommandKind = (
    // ... scShutdown ...
    scCheckpoint);            // start a checkpoint turn
  TSessionEventKind = (
    // ... ekLoopExited ...
    ekCheckpointCommitted);   // recorded at TurnSeq
```

### Data Contracts

- **Checkpoint boundary.** `Seq` = the message HWM at checkpoint time. The active
  window is strictly `seq > Seq`; the archived set is `seq <= Seq`.
- **Summary block.** On resume, the summary is presented as the opening context
  of the segment (a system/ambient block). It is **not** a stored message row
  (keeps role counts honest); it comes from the checkpoint.
- **FTS schema** (v1):
  ```sql
  CREATE VIRTUAL TABLE messages_fts USING fts5(
    content, tool_reason, tool_name, tool_arguments, label,
    session_id UNINDEXED, message_id UNINDEXED, tokenize='unicode61');
  ```
  `session_id`/`message_id` are unindexed carriers so a search joins back to
  `messages` and filters by session.
- **Indexing.** On `AppendMessage`, insert the matching `messages_fts` row in
  the same transaction. A migration backfills existing messages.
- **Column-scoped search.** A query with `AColumns = ['tool_reason']` issues
  `SELECT ... FROM messages_fts WHERE messages_fts MATCH 'tool_reason:…' AND
  session_id = ?` — the FTS column filter, so `content` is never scanned.

### Event Contracts

- `ekCheckpointCommitted` carries the recorded boundary `seq` (reuse `TurnSeq`).
  There is no draft event: the document streams as the checkpoint turn's
  assistant reply.

## Architecture

### Prior Art & Reuse

- **`QueryMessages` / `MessageHighWaterMark`** — the message reads the window
  builds on; the checkpoint is anchored to the HWM.
- **`AppendMessage`** — where FTS indexing hooks in.
- **`recall_tool_result`** — the recall surface; extended to FTS.
- **Runtime Lifecycle** — unchanged; the session keeps running (no switch, no
  runtime churn).
- **Genuine gap:** the checkpoint table, the active-window queries, the FTS table
  + build flag, the protocol verbs, and the TUI UX.

### Component Boundaries

- **Responsibilities:** checkpoint persistence, the active window, FTS recall, the
  checkpoint UX.
- **Dependencies:** the store (SQL), the loop (draft), the TUI.
- **Side effects:** inserts a checkpoint row and FTS rows; never deletes.

## Validation Rules

- A checkpoint on a session with no messages past the last checkpoint is refused.
- An empty/whitespace summary is refused.

## Error Handling

- A checkpoint turn that fails (`teError`) or returns an empty document ⇒ no
  checkpoint; the turn's error is surfaced as usual.
- Checkpoint/FTS failure ⇒ `ekError`, session unchanged.

## Testing Requirements

### Unit Tests (`tests/test_store.pas`)

- [ ] `SaveCheckpoint` records at the HWM; `LatestCheckpoint`/`ListCheckpoints` return
      it; a second checkpoint lists after the first.
- [ ] `QueryActiveMessages` returns only messages after the latest checkpoint;
      all messages when none.
- [ ] `QueryMessagesBefore` returns the archived page, oldest first.
- [ ] `SearchMessages` finds an archived message by `tool_reason`; a
      `content`-scoped search does not match a `tool_reason`-only hit (proving
      column scoping).
- [ ] FTS backfill indexes pre-existing messages.

### Integration Tests (`tests/test_session_runtime.pas`)

- [ ] `scCheckpoint` starts an ambient checkpoint turn; when it completes the
      runtime records a checkpoint and emits `ekCheckpointCommitted`; the message
      count is unchanged (nothing archived is deleted).
- [ ] A checkpoint turn that fails records no checkpoint.

### TUI Tests

- [ ] The nudge appears past the threshold; back-pagination loads the prior
      segment with a boundary marker.

## Performance Targets

- FTS indexing is O(message length) per append; a scoped search avoids the
  `content` scan.

## Security Considerations

- Driver-only checkpoint; the checkpoint summary is the agent-generated document.
- FTS queries are parameterized (no injection via the query string; the MATCH
  term is bound).

## Success Criteria

- [ ] A session handed off resumes bounded, keeps every message, and recalls
      across the boundary; `make check` green.

## Future Considerations

- Structured memory (a separate feature); automatic checkpoint; a checkpoint browser;
  archived-only recall scope (a query flag).
