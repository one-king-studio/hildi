# Implementation Plan: Context Handoff v1

**Related Specification:** `Context_Handoff_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

Snapshots (keyframes) in one session, a resume window, FTS5 recall, and the
operator UX. TDD-first. Ordered: build flag → store (snapshots + window + FTS) →
protocol/runtime → TUI.

## Implementation Tasks

### Phase 0: Build

- [ ] Add `-DSQLITE_ENABLE_FTS5` to `SQLITE_CCFLAGS` in the Makefile; rebuild
      `libsqlite3.a`; assert `messages_fts` can be created (a smoke test).

### Phase 1: Store — snapshots (`hildegard.helper.store`)

- [ ] **Test**: `TestSaveSnapshotAtHwm`, `TestLatestSnapshot`,
      `TestListSnapshots` in `tests/test_store.pas` — red.
- [ ] **Implement**: migration (v-next) `session_snapshots` table;
      `SaveSnapshot`/`LatestSnapshot`/`ListSnapshots`.
- [ ] **Test**: `TestQueryActiveMessages` (after-snapshot only; all when none).
- [ ] **Implement**: `QueryActiveMessages`.
- [ ] **Test**: `TestQueryMessagesBefore` (archived page, oldest first).
- [ ] **Implement**: `QueryMessagesBefore`.

### Phase 2: Store — FTS5 recall

- [ ] **Test**: `TestFtsIndexesOnAppend`, `TestSearchByToolReason`,
      `TestColumnScopedSearchSkipsContent` — red.
- [ ] **Implement**: `messages_fts` virtual table (migration); index on
      `AppendMessage` (same transaction); backfill migration.
- [ ] **Implement**: `SearchMessages` (whole + column-scoped).
- [ ] **Refactor**; `make check`.

### Phase 3: Protocol & runtime

- [ ] **Add** `scHandoff`, `scHandoffCommit`; `ekHandoffReady`,
      `ekHandoffCommitted`; `TSessionCommand.HandoffText`.
- [ ] **Test**: `TestHandoffDraft` (fake transport; session unchanged),
      `TestHandoffCommitSnapshots` (runtime).
- [ ] **Implement**: `THarnessSession.DraftHandoff` (one bounded request);
      the runtime's `scHandoff`/`scHandoffCommit` handling (snapshot at HWM).
- [ ] **Test**: message count unchanged after a handoff.

### Phase 4: Recall tool

- [ ] **Test**: `recall` finds an archived message by tool reason via FTS.
- [ ] **Implement**: extend `recall_tool_result` (or add a recall) to search
      `SearchMessages` with optional column scope.

### Phase 5: TUI

- [ ] **Tool-selection component**: a reusable picker/surface for choosing an
      action (not a bare keybinding) — the handoff entry point uses it, and so
      will other command surfaces. This is its own small component, built once.
- [ ] **Handoff UX**: the tool-selection surface offers `/handoff` → the agent
      drafts and commits in one action; refuse empty.
- [ ] **Resume rendering**: prepend the latest snapshot's summary as the
      segment's opening block.
- [ ] **Back-pagination**: load the prior segment on scroll; a "— handoff —"
      boundary marker.
- [ ] **Nudge**: hint `/handoff` past the threshold (never triggers).
- [ ] **Test**: the nudge threshold; the boundary renders.

### Phase 6: Validation

- [ ] `make test`, `make test-leak`, `make check` — green.
- [ ] **Manual**: a live session handoff — prompt shrinks, message count
      unchanged, back-pagination shows the archived segment, recall finds an
      archived message.

## Files to Create/Modify

```
Makefile                                  (-DSQLITE_ENABLE_FTS5)
src/hildegard.helper.store.pas            (snapshots, window, FTS)
src/hildegard.helper.session.protocol.pas (handoff verbs/events)
src/hildegard.helper.session.runtime.pas  (handoff handling)
src/hildegard.helper.harness.session.pas  (DraftHandoff)
src/hildegard.helper.recall.tool.pas      (FTS recall)
src/hildegard.helper.tui.*                (handoff UX, boundary, nudge)
tests/test_store.pas, test_session_runtime.pas, test_recall_tool.pas
```

## Notes & Considerations

- **Non-destructive is the invariant**: a handoff inserts one snapshot row; no
  message is ever deleted/rewritten. A test asserts the message count is
  unchanged across a handoff.
- **FTS drift**: index in the append transaction; backfill on migration.
- **Snapshot density**: manual-only in v1.
- Record deviations from the SPEC here.
