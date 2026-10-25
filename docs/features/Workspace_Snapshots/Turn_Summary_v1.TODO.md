# Task Plan: Workspace Snapshots v1 — Turn Summary

**Spec:** [Turn_Summary_v1.SPEC.md](Turn_Summary_v1.SPEC.md)

Work TDD-first: each phase adds its tests before its implementation and runs
`make check` before moving on. Phase 1 is pure and needs no TUI.

## Phase 1 — the query (library + SQLite)

- [ ] **Test**: `ForTurn` on `TMemoryChangeStore` returns a turn's rows in write
      order; a second turn's rows are not mixed in.
- [ ] **Test**: `ForTurn` with an unknown turn id returns an empty array and
      `True`.
- [ ] **Implement** `ForTurn` on `IChangeStore` and `TMemoryChangeStore`.
- [ ] **Test**: `TSqliteChangeStore.ForTurn` matches the memory store for the same
      rows (the parity the library promises).
- [ ] **Implement** `ForTurn` on `TSqliteChangeStore`.
- [ ] **Migration**: `idx_changes_turn ON file_changes (workspace_id, turn_id)`.
      Additive; no data change.
- [ ] `make changes-standalone` still passes (the library gained no harness unit).

## Phase 2 — the net fold (the recorder learns to fold a turn)

The summary must show **net** change per path, not a pile of per-call patches.
That is a capture-side change, and it comes before the summary model.

- [x] **Test**: two edits to one path in a turn yield **one** net row whose patch
      is `diff(first before, last after)`.
- [x] **Test**: two edits that cancel out yield a net row with an **empty** patch
      (the file is unchanged), and the summary reports it as unchanged.
- [x] **Test**: a create then a delete in one turn yields no net change for the
      path.
- [x] **Test**: per-call rows are still written as they happen (the tool-block
      diff needs them), and are distinguishable from net rows.
- [x] **Migration**: `is_net INTEGER NOT NULL DEFAULT 0` on `file_changes`;
      `ForTurn` filters by it.
- [x] **Implement** the per-turn fold in `TChangeRecorder`: hold first-before and
      last-after per path, flush one net row per path at the turn boundary.
- [ ] **Test**: the fold is bounded — a turn touching 200 paths holds 200 entries,
      not 200 file bodies retained for the session.
- [ ] `make check` green.

## Phase 3 — the summary model (pure)

- [ ] **Test**: counts come from the patch — a one-line change reads `+1 −0`.
- [ ] **Test**: `Patch = ''` yields `CountsKnown = False`, never `+0 −0`.
- [ ] **Test**: `Capped` propagates from the record.
- [ ] **Test**: a watcher row (`SessionId = ''`) and an external row
      (`ExternalSession <> ''`) are labelled unattributed.
- [ ] **Test**: zero rows yield an empty summary with `Files = nil`.
- [ ] **Implement** `SummarizeTurn` and `TTurnChangeSummary`/`TFileChangeStat`.
- [ ] **Test**: `SummaryLines` orders files, caps at `AMaxFiles`, and appends the
      `· N more files · +a −r` tail.
- [ ] **Implement** `SummaryLines`.
- [ ] **Test**: a turn whose only changes are uncaptured renders `+? −?` and
      reports `UnknownCount` so the total is not silently wrong.
- [ ] `make check` green.

## Phase 4 — the diff view model (pure)

- [ ] **Test**: a unified diff parses into hunk/added/removed/context lines.
- [ ] **Test**: a capped patch is reported as capped.
- [ ] **Test**: an unparseable patch yields "not captured", not an exception.
- [ ] **Test**: the viewer never reads a workspace file (constructed only from a
      `TChangeRecord`).
- [ ] **Implement** `TDiffView` (parse once, expose lines).
- [ ] `make check` green.

## Phase 5 — the TUI block

- [ ] **Test**: a turn with changes renders a `ckTurnChanges` block, collapsed.
- [ ] **Test**: a turn with no changes renders **no** block.
- [ ] **Test**: the block expands and its file rows are selectable.
- [ ] **Test**: the block's height is memoised per width like any other block
      (no per-frame re-measure).
- [ ] **Implement** the block in `src/tui/widgets/` (a `tui.widgets.*` consumer).
- [ ] **Wire** the runtime to emit the summary at the turn boundary.
- [ ] **Test**: the live path and a resumed replay produce the **same** summary
      text for the same turn.
- [ ] `make tui-standalone` still green.

## Phase 6 — the viewer

- [ ] **Test**: selecting a file opens the viewer with the parsed diff.
- [ ] **Test**: closing the viewer leaves the stream unchanged.
- [ ] **Test**: a not-captured file says so; a capped diff says "at least".
- [ ] **Implement** the viewer over the existing scroll + styled-text widgets.
- [ ] `make check` and `make test-leak-parallel` green.

## Close-out

- [ ] Update `FEATURES.md` (the row's "not built" list shrinks to the command
      work).
- [ ] Update `FEATURE.md` with what landed and what remains.
- [ ] Rename this file to `Turn_Summary_v1.DONE.md`.
