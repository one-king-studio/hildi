# Implementation Plan: Context Checkpoint v1

**Related Specification:** `Context_Checkpoint_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

Keyframes (keyframes) in one session, a resume window, FTS5 recall, and the
operator UX. TDD-first. Ordered: build flag → store (keyframes + window + FTS) →
protocol/runtime → TUI.

## Implementation Tasks

### Phase 0: Build

- [ ] Add `-DSQLITE_ENABLE_FTS5` to `SQLITE_CCFLAGS` in the Makefile; rebuild
      `libsqlite3.a`; assert `messages_fts` can be created (a smoke test).

### Phase 1: Store — keyframes (`hildegard.helper.store`)

- [ ] **Test**: `TestSaveKeyframeAtHwm`, `TestLatestKeyframe`,
      `TestListKeyframes` in `tests/test_store.pas` — red.
- [ ] **Implement**: migration (v-next) `session_keyframes` table;
      `SaveKeyframe`/`LatestKeyframe`/`ListKeyframes`.
- [ ] **Test**: `TestQueryActiveMessages` (after-keyframe only; all when none).
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

- [ ] **Add** `scCheckpoint`, `scCheckpointCommit`; `ekCheckpointReady`,
      `ekCheckpointCommitted`; `TSessionCommand.CheckpointText`.
- [ ] **Test**: `TestCheckpointDraft` (fake transport; session unchanged),
      `TestCheckpointCommitKeyframes` (runtime).
- [ ] **Implement**: `THarnessSession.DraftCheckpoint` (one bounded request);
      the runtime's `scCheckpoint`/`scCheckpointCommit` handling (keyframe at HWM).
- [ ] **Test**: message count unchanged after a checkpoint.

### Phase 4: Recall tool

- [ ] **Test**: `recall` finds an archived message by tool reason via FTS.
- [ ] **Implement**: extend `recall_tool_result` (or add a recall) to search
      `SearchMessages` with optional column scope.

### Phase 5: TUI

- [ ] **Tool-selection component**: a reusable picker/surface for choosing an
      action (not a bare keybinding) — the checkpoint entry point uses it, and so
      will other command surfaces. This is its own small component, built once.
- [ ] **Checkpoint UX**: the tool-selection surface offers `/checkpoint` → the agent
      drafts and commits in one action; refuse empty.
- [ ] **Resume rendering**: prepend the latest keyframe's summary as the
      segment's opening block.
- [ ] **Back-pagination**: load the prior segment on scroll; a "— checkpoint —"
      boundary marker.
- [ ] **Nudge**: hint `/checkpoint` past the threshold (never triggers).
- [ ] **Test**: the nudge threshold; the boundary renders.

### Phase 6: Validation

- [ ] `make test`, `make test-leak`, `make check` — green.
- [ ] **Manual**: a live session checkpoint — prompt shrinks, message count
      unchanged, back-pagination shows the archived segment, recall finds an
      archived message.

## Files to Create/Modify

```
Makefile                                  (-DSQLITE_ENABLE_FTS5)
src/hildegard.helper.store.pas            (keyframes, window, FTS)
src/hildegard.helper.session.protocol.pas (checkpoint verbs/events)
src/hildegard.helper.session.runtime.pas  (checkpoint handling)
src/hildegard.helper.harness.session.pas  (DraftCheckpoint)
src/hildegard.helper.recall.tool.pas      (FTS recall)
src/hildegard.helper.tui.*                (checkpoint UX, boundary, nudge)
tests/test_store.pas, test_session_runtime.pas, test_recall_tool.pas
```

## Notes & Considerations

- **Non-destructive is the invariant**: a checkpoint inserts one keyframe row; no
  message is ever deleted/rewritten. A test asserts the message count is
  unchanged across a checkpoint.
- **FTS drift**: index in the append transaction; backfill on migration.
- **Keyframe density**: manual-only in v1.
- Record deviations from the SPEC here.
