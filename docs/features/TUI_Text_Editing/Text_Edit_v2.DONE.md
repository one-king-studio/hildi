# Implementation Record: Text Edit v2

**Spec:** [Text_Edit_v2.SPEC.md](Text_Edit_v2.SPEC.md)
**Feature:** [FEATURE.md](FEATURE.md)
**Status:** Implemented. `make check` green (440 tests, leak-clean).

## Phase 1 - Shared delete range and word boundaries

- [x] **1.1** Tests: word motion from mid-word, from a boundary, across runs of
      spaces and newlines, and at both ends; word deletion back and forward.
- [x] **1.2** `DeleteRange(AFrom, ATo)`; `Backspace` and `DeleteForward` route
      through it.
- [x] **1.3** `WordLeftIndex`/`WordRightIndex` and the public word moves and
      deletes.

## Phase 2 - Selection

- [x] **2.1** Tests: the anchor is set once by a shift-move and cleared by an
      unshifted move; forward and backward bounds; `SelectAll`; `ClearSelection`.
- [x] **2.2** The anchor, the accessors, and the shift/alt handling in
      `HandleEvent`.
- [x] **2.3** Tests: insert, backspace, and delete replace the selection and
      leave the caret at its start.
- [x] **2.4** `InsertText`, `Backspace`, `DeleteForward`, `DeleteWordBack`, and
      `DeleteWordForward` all consume the selection first.

## Phase 3 - Sticky end-of-row column

- [x] **3.1** Tests: end of a short row to the end of a longer one and back; the
      numeric column still applies mid-row; the sticky goal survives repeated
      moves and is cleared by a horizontal move.
- [x] **3.2** `FGoalEnd`, set when a vertical run starts at the row end and used
      by `MoveUp`/`MoveDown`.

## Phase 4 - Caret and selection rendering

- [x] **4.1** Tests: `SelAttr` on selected clusters; the swapped caret colour
      over a cluster; the block past the last cluster; the caret staying drawn
      on the blink-off frame while a selection exists; the hollow box and the
      absent highlight when inactive.
- [x] **4.2** The selection pass, the swapped caret cell, the
      no-blink-with-selection rule, and the inactive rendering. `CaretOverlay`
      exposes the swapped caret rendition, and the compose sets `SelAttr` to it
      so a selection is exactly the cursor's colour.

## Phase 5 - Compose integration

- [x] **5.1** The compose sets `SelAttr` from the theme; `Enter` still submits.
- [x] **5.2** Scripted pty capture: `Alt+Left` then a typed character lands at
      the word start; `Alt+Backspace` removes the word; `Shift+Right` extends a
      selection and the next character replaces it; the caret over a cluster
      carries the swapped colours.

## Phase 6 - Verification and close-out

- [x] **6.1** `make check` green.
- [x] **6.2** `FEATURES.md` summary still accurate (v2 criteria added to
      `FEATURE.md`).
- [x] **6.3** This file records the outcome.

## Deviations from the SPEC

- **`AExtend` parameter.** Rather than separate `...Extending` methods, every
  movement takes `AExtend: Boolean = False`, which is source-compatible with the
  v1 signatures. The SPEC's contract block now shows them.
- **Decoder addition.** A terminal without the kitty keyboard protocol reports
  `Alt+Backspace` as `ESC DEL`, which the decoder previously split into Escape
  followed by Backspace. It now maps `ESC DEL`/`ESC BS` to `kkBackspace` with
  `moAlt`, and there is a test for it. `Alt+Delete` still needs a terminal that
  reports `CSI 3;3~` (or the kitty protocol); the decoder already handles it.
- **Word definition.** Words are whitespace-delimited, so `foo.bar` is one word.
  Identifier-aware motion is listed as future work.
- **Sticky end-of-row and soft wraps.** The sticky goal is resolved at the
  display row, as the SPEC says. Across a soft wrap this means the end of the
  visual row; resolving it at the logical line is future work.
- **Inactive caret colour.** The hollow box past the text uses the caret
  attribute; a dimmer rendition may read better once a focus model exists.
- **Demo focus.** The compose is always active, so the inactive rendering is
  covered by unit tests only; the demo has no focus model to toggle yet.

## Follow-ups

- Wire a focus model so the demo can show the unfocused caret.
- Identifier-aware word motion.
- Extract `TComposeBox` into `src/` and unit-test it.
- Selection with the mouse, clipboard, undo/redo.
