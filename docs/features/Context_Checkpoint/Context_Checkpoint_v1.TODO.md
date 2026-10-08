# Implementation Plan: Context Checkpoint v1

**Related Specification:** `Context_Checkpoint_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

Checkpoints (checkpoints) in one session, a resume window, FTS5 recall, and the
operator UX. TDD-first. Ordered: build flag → store (checkpoints + window + FTS) →
protocol/runtime → TUI.

## Implementation Tasks

### Phase 0: Build

- [x] Add `-DSQLITE_ENABLE_FTS5` to `SQLITE_CCFLAGS` in the Makefile; rebuild
      `libsqlite3.a`; assert `messages_fts` can be created (a smoke test).

### Phase 1: Store — checkpoints (`hildegard.helper.store`)

- [x] **Test**: `TestSaveCheckpointAtHwm`, `TestLatestCheckpoint`,
      `TestListCheckpoints` in `tests/test_store.pas` — red.
- [x] **Implement**: migration (v-next) `session_checkpoints` table;
      `SaveCheckpoint`/`LatestCheckpoint`/`ListCheckpoints`.
- [x] **Test**: `TestQueryActiveMessages` (after-checkpoint only; all when none).
- [x] **Implement**: `QueryActiveMessages`.
- [x] **Test**: `TestQueryMessagesBefore` (archived page, oldest first).
- [x] **Implement**: `QueryMessagesBefore`.

### Phase 2: Store — FTS5 recall

- [x] **Test**: `TestFtsIndexesOnAppend`, `TestSearchByToolReason`,
      `TestColumnScopedSearchSkipsContent` — red.
- [x] **Implement**: `messages_fts` virtual table (migration); index on
      `AppendMessage` (same transaction); backfill migration.
- [x] **Implement**: `SearchMessages` (whole + column-scoped).
- [x] **Refactor**; `make check`.

### Phase 3: Protocol & runtime

- [x] **Add** `scCheckpoint`, `scCheckpointCommit`; `ekCheckpointReady`,
      `ekCheckpointCommitted`; `TSessionCommand.CheckpointText`.
- [x] **Test**: `TestCheckpointDraft` (fake transport; session unchanged),
      `TestCheckpointCommitCheckpoints` (runtime).
- [x] **Implement**: `THarnessSession.DraftCheckpoint` (one bounded request);
      the runtime's `scCheckpoint`/`scCheckpointCommit` handling (checkpoint at HWM).
- [x] **Test**: message count unchanged after a checkpoint.

### Phase 4: Recall tool

- [x] **Test**: `recall` finds an archived message by tool reason via FTS.
- [x] **Implement**: extend `recall_tool_result` (or add a recall) to search
      `SearchMessages` with optional column scope.

### Phase 5: TUI

- [x] **Tool-selection component**: a reusable picker/surface for choosing an
      action (not a bare keybinding) — the checkpoint entry point uses it, and so
      will other command surfaces. This is its own small component, built once.
- [x] **Checkpoint UX**: the tool-selection surface offers `/checkpoint` → the agent
      drafts and commits in one action; refuse empty.
- [x] **Resume rendering**: prepend the latest checkpoint's summary as the
      segment's opening block.
- [x] **Back-pagination**: load the prior segment on scroll; a "— checkpoint —"
      boundary marker. Implemented; the trigger is tested, the anchor is not.

      Design (checked against the current code — `TChatStream` has `Add`/`Clear`/
      `ItemAt`, and `TScrollContainer` exposes `ScrollY`/`MaxScrollY`/`ScrollTo`):
      - `TChatStream` gains `OnNeedOlder: TNotifyEvent`, fired from `HandleEvent`
        when a scroll-up leaves `FScroll.ScrollY <= 0` (the top) and there is more
        archived history; plus a `ContentHeight` and a `ScrollOffset` passthrough
        so the app can restore the anchor.
      - The app keeps `FOlderPages: Integer` (0 at first). `RenderHistory` renders
        `QueryMessagesBefore(session, checkpoint.seq, FOlderPages * PageSize)` as
        the archived prefix, then a `— checkpoint —` marker, then the checkpoint
        document, then the active window.
      - On `OnNeedOlder`: `Inc(FOlderPages)`, note `ContentHeight` and
        `ScrollOffset`, `RenderHistory`, then
        `ScrollOffset := ScrollOffset + (ContentHeight_after - ContentHeight_before)`
        so the visible content stays put and the operator can keep scrolling up.
      - The marker is a divider-style block (`ckTurn`), "— checkpoint —".
- [x] **Nudge**: hint `/checkpoint` past the threshold (never triggers).
      Implemented at 80% in the CTA hints (`UpdateStats`); not yet tested.
- [x] **Test**: the trigger (`TestStreamFiresNeedOlderAtTheTop`), the metric
      (`TestSessionTotalsContextIsTheLatestRequest`), and the checkpoint turn
      (`TestCheckpointTurnRecords`).
- [ ] **Test**: the back-pagination anchor restore, the header `page N`, and the
      nudge threshold.

### Phase 6: Validation

- [x] `make test`, `make test-leak`, `make check` — green (1021 tests).
- [ ] **Manual** (operator): a live session checkpoint — prompt shrinks, message
      count unchanged, back-pagination shows the archived segment, recall finds an
      archived message.

## Redesign: the checkpoint as a turn (DO THIS)

**Status: DONE** (commits `a80450b`, `b33a132`). The one-action `scCheckpoint`
path used to run `THarnessSession.DraftCheckpoint` — a separate, synchronous
`FClient.Complete` — which blocked the runtime with no progress shown and
swallowed the failure reason. It is now a **turn-based** design that reuses the
normal loop.

**The flow:**

1. `/checkpoint` (app) submits a **summarization prompt as a normal turn** — the
   prompt is an **ambient** message ("summarize this session into a checkpoint
   document"), so the operator sees it stream like any turn.
2. The assistant's **response to that turn is the checkpoint document**.
3. The **entire checkpoint turn is the last turn of the previous chain and the
   first turn of the next chain** — it bridges them.
4. Record the checkpoint at the boundary (the turn's HWM), then **reload** the
   view: the new chain is `[system prompt] + [the checkpoint turn] + future`,
   leaving the operator a blank slate to continue.

**Why:** streaming, progress, the ledger, and error handling all come for free
from the normal turn path — the exact things the out-of-band call lacked.

**Changes:**

- **Delete** the out-of-band path: `scCheckpoint`/`scCheckpointCommit`,
  `ekCheckpointReady`/`ekCheckpointCommitted`, `THarnessSession.DraftCheckpoint`,
  the runtime's `HandleCheckpoint`/`HandleCheckpointCommit`, and
  `TCommandPalette`'s draft handling.
- **Loop prompt role** (`hildegard.helper.agent` ~line 1262): allow the turn's
  user prompt to be appended as **`mrAmbient`** (a flag on the loop or a
  checkpoint-turn marker), so the prompt is an ambient block.
- **Runtime**: on `teDone` for a checkpoint turn, `SaveCheckpoint(session,
  <assistant response>, <boundary = the turn's HWM>)`, then emit an event the
  app uses to **reload** the transcript from the new chain.
- **App**: `/checkpoint` runs the summarization turn (set a `FCheckpointTurn`
  flag); on the terminal event, clear the stream and re-render from the
  checkpoint. Show a `checkpointing` state (already added in `1c3415d`).
- **`Compose`** already resumes from the checkpoint (system + context + after the
  boundary) — the new chain falls out of it. Verify the checkpoint *turn's*
  messages land correctly (the ambient prompt and its assistant reply are at/below
  the boundary, so they are the bridge; the document re-injects as the context
  block).

**Keep:** the store (`session_checkpoints`, `SaveCheckpoint`, `LatestCheckpoint`,
active window), FTS recall, `Compose` resume, the palette/tray.

## Files to Create/Modify

```
Makefile                                  (-DSQLITE_ENABLE_FTS5)
src/hildegard.helper.store.pas            (checkpoints, window, FTS)
src/hildegard.helper.session.protocol.pas (checkpoint verbs/events)
src/hildegard.helper.session.runtime.pas  (checkpoint handling)
src/hildegard.helper.harness.session.pas  (DraftCheckpoint)
src/hildegard.helper.recall.tool.pas      (FTS recall)
src/hildegard.helper.tui.*                (checkpoint UX, boundary, nudge)
tests/test_store.pas, test_session_runtime.pas, test_recall_tool.pas
```

## Notes & Considerations

- **Non-destructive is the invariant**: a checkpoint inserts one checkpoint row; no
  message is ever deleted/rewritten. A test asserts the message count is
  unchanged across a checkpoint.
- **FTS drift**: index in the append transaction; backfill on migration.
- **Checkpoint density**: manual-only in v1.
- Record deviations from the SPEC here.
