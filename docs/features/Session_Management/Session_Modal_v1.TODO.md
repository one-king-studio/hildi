# Implementation Plan: Session Modal v1

**Related Specification:** `Session_Modal_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

A `/sessions` modal over the Harness TUI: list the workspace's sessions (pinned
first, then newest), search by title/keyword/id, and manage a row — rename, pin,
archive/restore. It reads the titles and keywords Reply Metadata persists; it does
not derive them. **Opening** another session is out of v1. TDD-first; `make check`
before moving on. `main` only.

> **Prerequisite:** `Reply_Metadata_v1` (the v10 columns + `reply_keywords`).

## Implementation Tasks

### Phase 1: Store reads/writes (`hildegard.helper.store`)

- [ ] **Test**: `ListSessionRows` returns pinned-first then newest, excludes
      archived by default, and includes them when asked.
- [ ] **Implement**: `ListSessionRows` (join `sessions` with the v10 fields; the
      latest reply's keywords per row).
- [ ] **Test**: `SetSessionPinned` / `SetSessionArchived` round-trip.
- [ ] **Implement**: the pin/archive setters.
- [ ] **Test**: rename reuses `SetSessionTitleOverride` (set and clear).
- [ ] **Implement**: any needed glue.

### Phase 2: The row model and the modal widget

- [ ] **Create** `src/hildegard.helper.tui.sessionsmodal.pas`:
      `TSessionRow`, `TSessionRowArray`, `TSessionAction`,
      `TSessionActionEvent`, `TSessionsModal`.
- [ ] **Add** `test_tui_sessionsmodal.pas` to the runner's `uses`.
- [ ] **Test**: `SetRows` + `Render` draws the current row marked, pinned glyph,
      dimmed archived (headless, `TSurfaceMemory`).
- [ ] **Implement**: `Measure`/`Render`/`Arrange` (theme roles only; no colour-
      only state).
- [ ] **Test**: an empty workspace draws an empty-state line.
- [ ] **Implement**: the empty state.

### Phase 3: Navigation and the search filter

- [ ] **Test**: Up/Down/Home/End move the selection; the list scrolls to keep it
      visible.
- [ ] **Implement**: key handling over `TListView`.
- [ ] **Test**: typing filters live over title, keyword, and id; an empty query
      shows all; no per-keystroke store read (a spy store counts).
- [ ] **Implement**: the in-memory filter.

### Phase 4: Row actions

- [ ] **Test**: `P`/`A`/`R` raise `OnAction` for the selected row; the app calls
      the matching store method and re-reads the rows (a fake store records it).
- [ ] **Implement**: the action keys + the app's handler (store write + refresh).
- [ ] **Test**: rename opens an inline input seeded with the current title; empty
      cancels; a submitted value becomes the override.
- [ ] **Implement**: the inline rename input.
- [ ] **Test**: the archived toggle re-reads with `includeArchived=True` and dims
      those rows.
- [ ] **Implement**: the toggle.

### Phase 5: Command wiring (`hildegard.helper.harness.app`)

- [ ] **Test**: `sessions` is in `DefaultCommands`; `RunCommand('sessions')`
      pushes the modal plane; Escape pops it.
- [ ] **Implement**: the command + the plane push, modelled on the approval modal.
- [ ] **Test**: with no store, the command is a no-op status note (no crash).

### Phase 6: Validation & docs

- [ ] **Run**: `make test SUITE=TSessionsModalTest`
- [ ] **Run**: `make test`; `make test-leak`; `make check`
- [ ] **Update the SPEC** if behaviour diverged; rename this TODO to
      `Session_Modal_v1.DONE.md`

## Files to Create/Modify

### New Files

```
src/hildegard.helper.tui.sessionsmodal.pas
tests/test_tui_sessionsmodal.pas
```

### Modified Files

```
tests/hildegard_helper_tests.pas        (add the test unit)
src/hildegard.helper.store.pas          (ListSessionRows, pin/archive setters)
src/hildegard.helper.harness.app.pas    (the sessions command + plane)
```

## Dependencies & Ordering

### Must Complete Before Starting

- `Reply_Metadata_v1` (the title/keyword columns and table).

### Can Be Done in Parallel

- Phases 2 (widget) and 1 (store) overlap only at the row model; the widget can
  be built against a fake store.

### Critical Path

1 (store) -> 2 (widget) -> 3 (nav/filter) -> 4 (actions) -> 5 (command) -> 6.

## Success Criteria

- [ ] All tasks checked
- [ ] Every SPEC acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] The modal lists, searches, and manages; opening a session is not in v1
- [ ] State is glyph-carried, not colour-only; theme roles only

## Notes & Considerations

- **Management only.** Activation (open another session) is deferred — the
  driver seam.
- **Read, don't derive.** Titles/keywords come from Reply Metadata; the modal
  never parses a reply.
- **No per-keystroke query.** Filter the loaded rows in memory.
- Record deviations from the SPEC here.
