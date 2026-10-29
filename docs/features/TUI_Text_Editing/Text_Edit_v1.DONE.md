# Implementation Record: Text Edit v1

**Spec:** [Text_Edit_v1.SPEC.md](Text_Edit_v1.SPEC.md)
**Feature:** [FEATURE.md](FEATURE.md)
**Status:** Implemented. `make check` green (419 tests, leak-clean).

## Phase 1 - Shared grapheme helpers

- [x] **1.1** `tests/test_tui_grapheme.pas`, registered in
      `tests/hildi_tests.pas`.
- [x] **1.2** `src/hildi.tui.grapheme.pas` with `Clusters`,
      `ClusterWidth`, `StringWidth`, and `ClusterStarts`.
- [x] **1.3** Adopted in `hildi.tui.text.pas` and
      `hildi.tui.prompt.pas`; their local copies are gone.
- [x] **1.4** Adopted in `hildi.tui.encoder.pas` (it keeps a local
      wrapper only because an empty cell still advances the cursor by one).
- [x] **1.5** `make check` green; the text/prompt/encoder suites pass unchanged.

## Phase 2 - Buffer and caret

- [x] **2.1** Editing tests in `tests/test_tui_edit.pas`.
- [x] **2.2** `src/hildi.tui.edit.pas` with the buffer, caret, and
      editing operations.

## Phase 3 - Layout and navigation

- [x] **3.1** Row-tiling, hard break, trailing-newline, char/word wrap, and wide
      cluster tests.
- [x] **3.2** `Rows(AWidth)` and `CaretCell(AWidth)` implemented.
- [x] **3.3** Navigation and caret-range tests.
- [x] **3.4** Movement with a goal column, plus `Measure`.

## Phase 4 - Rendering and scroll

- [x] **4.1** Rendering, caret, scroll, blink, and key-mapping tests.
- [x] **4.2** `Render`, `EnsureVisible`, `Advance`, `Animating`, and
      `HandleEvent`.

## Phase 5 - Compose integration

- [x] **5.1** `TComposeBox` now wraps a `TTextEdit`; the demo-local `WrapText`,
      `InsertText`, `Backspace`, and caret maths are deleted.
- [x] **5.2** `Enter` submits before the editor sees it; `Shift+Enter` and every
      other key go to the editor.
- [x] **5.3** Verified with a scripted pty capture: `Shift+Enter` shows the new
      row with the caret at its head, `Up` preserves the column, `Left`/`Right`
      move the caret, and a long line wraps and grows the compose overlay.
- [x] **5.4** Demo header comment updated.

## Phase 6 - Verification and close-out

- [x] **6.1** `make check` green.
- [x] **6.2** Acceptance criteria confirmed (see below).
- [x] **6.3** `docs/features/FEATURES.md` updated.
- [x] **6.4** This file records the outcome.

## Acceptance criteria

- [x] Buffer plus cluster-indexed caret.
- [x] Insert at the caret, backspace, delete forward; the caret lands where the
      spec says.
- [x] `Left`/`Right` by cluster; `Up`/`Down` by display row preserving the
      column; `Home`/`End` by logical line.
- [x] A trailing `#10` renders a final empty row (the `Shift+Enter` regression).
- [x] Grapheme- and width-correct wrapping.
- [x] Caret drawn at its cell; the view scrolls to keep it visible.
- [x] `OnChange` fires on every mutation and move.
- [x] `Enter` inserts a newline; the host intercepts submission.
- [x] One shared grapheme/width unit, adopted by three existing units.
- [x] Headless tests, leak-clean, `make check` green.

## Deviations from the SPEC

- **Row tiling.** The SPEC first claimed `sum(Rows[i].Count) == ClusterCount`.
  `#10` separators start no row and a word-wrap break keeps the trailing space in
  the upper row, so the real guarantee is "rows tile the buffer except for the
  `#10` separators". The SPEC now says so.
- **Extra caret row.** A buffer that does not end in `#10` and whose last row
  exactly fills the width gets one extra empty row, so the caret is never left
  with no cell. Not anticipated in the first SPEC draft; now documented.
- **Word-wrap break point.** The break is *after* the last space (the space hangs
  at the end of the upper row) rather than dropping it, so no cluster loses its
  row and the caret mapping stays total.
- **`CaretCell` at a wrap boundary** reports the continuation row, not the end of
  the upper row: that is the only place the caret can be drawn.
- **Compose integration test.** The SPEC asked for an integration test on the
  compose box. `TComposeBox` still lives in `examples/`, which is not linked into
  the fpcunit binary, so the integration is verified by a scripted pty capture
  (`5.3`) while `TTextEdit` carries the unit tests. Extracting the compose into
  `src/` would let it be unit-tested and is the natural next step.
- **`TNotifyEvent`** comes from the RTL `Classes` unit, matching `TButton` and
  `TListView`.
- **Movement width.** `MoveUp`/`MoveDown` use the arranged bounds, falling back
  to the width seen by the last `Measure`, so they work before the first render.

## Follow-ups

- Extract `TComposeBox` (and the chat widgets) into `src/` and unit-test them.
- `wmNone` with horizontal scrolling for code in the editor panel.
- Selection, clipboard, and undo/redo.
