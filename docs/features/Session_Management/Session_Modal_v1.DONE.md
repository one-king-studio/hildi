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

### Phase 1: Store reads/writes (`hildi.store`)

- [x] **Test**: `ListSessionRows` returns pinned-first then newest, excludes
      archived by default, and includes them when asked.
- [x] **Implement**: `ListSessionRows` (join `sessions` with the v10 fields; the
      latest reply's keywords per row).
- [x] **Test**: `SetSessionPinned` / `SetSessionArchived` round-trip.
- [x] **Implement**: the pin/archive setters.
- [x] **Test**: rename reuses `SetSessionTitleOverride` (set and clear).
- [x] **Implement**: any needed glue.

### Phase 2: The row model and the modal widget

- [x] **Create** `src/hildi.tui.sessionsmodal.pas`:
      `TSessionRow`, `TSessionRowArray`, `TSessionAction`,
      `TSessionActionEvent`, `TSessionsModal`.
- [x] **Add** `test_tui_sessionsmodal.pas` to the runner's `uses`.
- [x] **Test**: `SetRows` + `Render` draws the current row marked, pinned glyph,
      dimmed archived (headless, `TSurfaceMemory`).
- [x] **Implement**: `Measure`/`Render`/`Arrange` (theme roles only; no colour-
      only state).
- [x] **Test**: an empty workspace draws an empty-state line.
- [x] **Implement**: the empty state.

### Phase 3: Navigation and the search filter

- [x] **Test**: Up/Down/Home/End move the selection; the list scrolls to keep it
      visible.
- [x] **Implement**: key handling over `TListView`.
- [x] **Test**: typing filters live over title, keyword, and id; an empty query
      shows all; no per-keystroke store read (a spy store counts).
- [x] **Implement**: the in-memory filter.

### Phase 4: Row actions

- [x] **Test**: `P`/`A`/`R` raise `OnAction` for the selected row; the app calls
      the matching store method and re-reads the rows (a fake store records it).
- [x] **Implement**: the action keys + the app's handler (store write + refresh).
- [x] **Test**: rename opens an inline input seeded with the current title; empty
      cancels; a submitted value becomes the override.
- [x] **Implement**: the inline rename input.
- [x] **Test**: the archived toggle re-reads with `includeArchived=True` and dims
      those rows.
- [x] **Implement**: the toggle.

### Phase 5: Command wiring (`hildi.harness.app`)

- [x] **Test**: `sessions` is in `DefaultCommands`; `RunCommand('sessions')`
      pushes the modal plane; Escape pops it.
- [x] **Implement**: the command + the plane push, modelled on the approval modal.
- [x] **Test**: with no store, the command is a no-op status note (no crash).

### Phase 6: Validation & docs

- [x] **Run**: `make test SUITE=TSessionsModalTest`
- [x] **Run**: `make test`; `make test-leak`; `make check`
- [x] **Update the SPEC** if behaviour diverged; rename this TODO to
      `Session_Modal_v1.DONE.md`

## Files to Create/Modify

### New Files

```
src/hildi.tui.sessionsmodal.pas
tests/test_tui_sessionsmodal.pas
```

### Modified Files

```
tests/hildi_tests.pas        (add the test unit)
src/hildi.store.pas          (ListSessionRows, pin/archive setters)
src/hildi.harness.app.pas    (the sessions command + plane)
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

- [x] All tasks checked
- [x] Every SPEC acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] The modal lists, searches, and manages; opening a session is not in v1
      (delivered by `Session_Switching_v1` — see the Notes)
- [x] State is glyph-carried, not colour-only; theme roles only

## Notes & Considerations

- **Management only in v1.** Activation (open another session) was deferred — the
  driver seam — and **delivered by `Session_Switching_v1`**: the modal's Enter now
  opens the selected session (`TSessionsModal.OnActivate` → `THarnessApp.
  SwitchSession`), including mid-turn (it detaches).
- **Read, don't derive.** Titles/keywords come from Reply Metadata; the modal
  never parses a reply.
- **No per-keystroke query.** Filter the loaded rows in memory.
- Record deviations from the SPEC here.

## Outcome

Implemented on `main` (`10521d2`, `f86b0b1`, `0bccc36`): the store reads/writes
(`ListSessionRows`, `SetSessionPinned`/`SetSessionArchived`, migration v11), the
modal widget (`TSessionsModal`), and the `/sessions` command wiring. `make check`
green; leak-clean.

**Deviations from the SPEC, with reasons:**
- **Phases 3-4 (navigation, filter, row actions) live inside the widget**, not a
  separate `TListView`-based layer: the modal draws its own rows (it needs the
  pinned/current/archived glyphs and the chip run), so it owns the key handling
  and the in-memory filter directly. Their tests sit in
  `test_tui_sessionsmodal` (Phase 2) rather than as a later phase.
- **Opening a session is out of v1** (Decision 5, the driver seam), as specced.
- **The action handler re-reads the row's flags before toggling** (a tiny read,
  not a per-keystroke query) — the modal does not carry the toggle target.
