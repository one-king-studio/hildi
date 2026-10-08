# Component Specification: Context Handoff v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.store` (messages, snapshots, FTS),
`hildegard.helper.session.protocol`, `hildegard.helper.session.runtime`,
`hildegard.helper.harness.session` / `view`, `hildegard.helper.tui.app`,
`hildegard.helper.recall.tool`.

## Purpose

Implement the keyframe handoff: a **snapshot** table, a **resume window** that
starts from the latest snapshot, a **whole-session FTS5 recall**, and the
operator UX (`/handoff`, boundary, back-pagination). **One session id**;
nothing is deleted.

## Requirements

### Functional

- [ ] **Store: snapshots.** A `session_snapshots` table (migration) with
      `(session_id, seq, summary, created_at)`. `SaveSnapshot` records a
      snapshot at the current message high-water mark; `LatestSnapshot` returns
      the most recent; `ListSnapshots` returns all (for a chain view).
- [ ] **Store: resume window.** `QueryActiveMessages(session, out msgs)` returns
      messages with `seq > latestSnapshot.seq` (or all when no snapshot).
      `QueryMessagesBefore(session, seq, limit, out msgs)` returns the archived
      page for back-pagination.
- [ ] **Store: FTS5.** A `messages_fts` virtual table (FTS5) over message
      fields; rows are indexed on append (same transaction). `SearchMessages`
      runs a query, optionally **column-scoped** (`tool_reason`, `tool_name`,
      `tool_arguments`, `content`, `label`). A migration backfills existing
      messages.
- [ ] **Build**: the vendored SQLite compiles with `-DSQLITE_ENABLE_FTS5`.
- [ ] **Protocol**: `scHandoff` (driver-only) requests a draft;
      `scHandoffCommit` (driver-only, carries the agent's text) records the
      snapshot. Events: `ekHandoffReady` (draft), `ekHandoffCommitted` (the
      snapshot seq).
- [ ] **Draft**: the runtime runs one bounded LLM request (a handoff
      instruction) and emits the draft; the session is not modified.
- [ ] **Commit**: the runtime records a snapshot at the current HWM with the
      agent-generated summary; the session's **active window** becomes "summary
      + messages after the boundary". Nothing is deleted.
- [ ] **Resume**: opening/attaching a session loads the active window — the
      latest snapshot's summary prepended, then messages after its `seq`. The
      TUI renders the summary as the segment's opening block.
- [ ] **Back-pagination**: the TUI can load the previous segment
      (`QueryMessagesBefore`) with a visible "— handoff —" boundary.
- [ ] **Recall**: `recall_tool_result` (or a new recall tool) searches the FTS
      index across **archived and current** messages; a query may scope to
      structured columns so it does not scan `content`.
- [ ] **Nudge**: the TUI hints `/handoff` past a configurable threshold; never
      triggers.

### Non-Functional

- [ ] **Non-destructive**: a handoff inserts one snapshot row; no message is
      deleted, rewritten, or reordered.
- [ ] Indexing is incremental and in the append transaction (no drift).
- [ ] `make check` green; leak-clean.

## Contracts & Interfaces

```pascal
unit hildegard.helper.store;   // additions

type
  TSnapshotRecord = record
    SessionId: string;
    Seq: Int64;              // the boundary: messages with seq <= Seq are archived
    Summary: string;         // the handoff document (prose)
    CreatedAtMs: Int64;
  end;
  TSnapshotArray = array of TSnapshotRecord;

  TSqliteStore = class
    // ... existing ...
    { Record a snapshot at the session's current message HWM. }
    function SaveSnapshot(const ASessionId, ASummary: string;
      out ASeq: Int64; out AError: TStoreError): Boolean;
    { The most recent snapshot; seNotFound when none. }
    function LatestSnapshot(const ASessionId: string; out ASnap: TSnapshotRecord;
      out AError: TStoreError): Boolean;
    { All snapshots, oldest first. }
    function ListSnapshots(const ASessionId: string; out ASnaps: TSnapshotArray;
      out AError: TStoreError): Boolean;
    { Active window: messages with seq > latest snapshot seq (all when none). }
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
    scHandoff, scHandoffCommit);
  TSessionEventKind = (
    // ... ekLoopExited ...
    ekHandoffReady, ekHandoffCommitted);
  TSessionCommand = record
    // ... existing ...
    HandoffText: string;   // scHandoffCommit: the agent-generated document
  end;
```

### Data Contracts

- **Snapshot boundary.** `Seq` = the message HWM at handoff time. The active
  window is strictly `seq > Seq`; the archived set is `seq <= Seq`.
- **Summary block.** On resume, the summary is presented as the opening context
  of the segment (a system/ambient block). It is **not** a stored message row
  (keeps role counts honest); it comes from the snapshot.
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

- `ekHandoffReady` carries the draft in `Text`.
- `ekHandoffCommitted` carries the snapshot `seq` (reuse `TurnSeq` or a new
  field) and reason `handoff`.

## Architecture

### Prior Art & Reuse

- **`QueryMessages` / `MessageHighWaterMark`** — the message reads the window
  builds on; the snapshot is anchored to the HWM.
- **`AppendMessage`** — where FTS indexing hooks in.
- **`recall_tool_result`** — the recall surface; extended to FTS.
- **Runtime Lifecycle** — unchanged; the session keeps running (no switch, no
  runtime churn).
- **Genuine gap:** the snapshot table, the active-window queries, the FTS table
  + build flag, the protocol verbs, and the TUI UX.

### Component Boundaries

- **Responsibilities:** snapshot persistence, the active window, FTS recall, the
  handoff UX.
- **Dependencies:** the store (SQL), the loop (draft), the TUI.
- **Side effects:** inserts a snapshot row and FTS rows; never deletes.

## Validation Rules

- A snapshot on a session with no messages past the last snapshot is refused.
- An empty/whitespace summary is refused.

## Error Handling

- Draft failure ⇒ `ekError`, no snapshot.
- Snapshot/FTS failure ⇒ `ekError`, session unchanged.

## Testing Requirements

### Unit Tests (`tests/test_store.pas`)

- [ ] `SaveSnapshot` records at the HWM; `LatestSnapshot`/`ListSnapshots` return
      it; a second snapshot lists after the first.
- [ ] `QueryActiveMessages` returns only messages after the latest snapshot;
      all messages when none.
- [ ] `QueryMessagesBefore` returns the archived page, oldest first.
- [ ] `SearchMessages` finds an archived message by `tool_reason`; a
      `content`-scoped search does not match a `tool_reason`-only hit (proving
      column scoping).
- [ ] FTS backfill indexes pre-existing messages.

### Integration Tests (`tests/test_session_runtime.pas`)

- [ ] `scHandoff` emits `ekHandoffReady`; `scHandoffCommit` records a snapshot
      and emits `ekHandoffCommitted`; the message count is unchanged.

### TUI Tests

- [ ] The nudge appears past the threshold; back-pagination loads the prior
      segment with a boundary marker.

## Performance Targets

- FTS indexing is O(message length) per append; a scoped search avoids the
  `content` scan.

## Security Considerations

- Driver-only handoff; the snapshot summary is the agent-generated document.
- FTS queries are parameterized (no injection via the query string; the MATCH
  term is bound).

## Success Criteria

- [ ] A session handed off resumes bounded, keeps every message, and recalls
      across the boundary; `make check` green.

## Future Considerations

- Structured memory (a separate feature); automatic handoff; a snapshot browser;
  archived-only recall scope (a query flag).
