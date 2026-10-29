# TUI Text Editing

## Overview

A reusable, caret-aware, multi-line text editor for the TUI toolkit: one widget
that owns a text buffer, tracks a caret through edits and wrapping, navigates by
keyboard, and paints a blinking caret. It is the missing middle between
`TPromptLine` (single line, caret-aware) and `TTextBlock` (multi-line,
width-aware layout), and it is shared by the chat compose box today and the
editor panel tomorrow.

## Problem Statement

The toolkit edits text in exactly one place: `TPromptLine`, a single-line prompt
with a grapheme-cluster caret, horizontal scrolling, and history. Everything
multi-line is read-only: `TTextBlock` wraps styled text with correct East Asian
width and grapheme handling but has no caret and no editing.

The layout demo's compose box papers over the gap with an append-only buffer:
`InsertText` concatenates at the end, `Backspace` trims the end, and the caret
is not modelled at all. The caret is *derived* at render time as "one cell past
the last rendered line's text". That derivation is the reported bug: after
`Shift+Enter` the buffer ends in `#10`, but the demo's ad-hoc wrapper drops a
trailing empty paragraph, so no new display row appears and the caret stays
parked on the previous row. The same shape of bug returns for every edit that
is not an append (mid-string insert, `Delete`, arrow keys).

The editor panel will need the identical capability, so a demo-local fix would
be built twice.

## Goals

- One widget, `TTextEdit`, that owns a text buffer and a caret and supports
  insertion, deletion, and caret movement.
- Navigation: `Left`/`Right` by grapheme cluster, `Up`/`Down` by display row
  preserving the visual column, `Home`/`End` by logical line.
- Soft wrapping (character or word) that is grapheme- and width-correct, with
  vertical scrolling that keeps the caret visible.
- A blinking caret cell drawn at the caret, correct after inserts, deletes,
  wraps, and scrolls.
- Reuse for the compose box now and the editor panel later; no new dependency.

## User Stories

- As an **operator**, I want to place the caret anywhere in my message with the
  arrow keys and edit there, so I can fix a typo without retyping the tail.
- As an **operator**, I want `Shift+Enter` to add a line and immediately see the
  caret at the head of that new line, so multi-line input is not surprising.
- As an **operator**, I want `Up`/`Down` to keep my column as I cross soft-wrapped
  and hard-broken lines, so moving vertically feels predictable.
- As an **operator**, I want a long message to scroll so the caret is always
  visible, so I never type blind.
- As a **harness author**, I want one editor widget I can drop into the compose
  box and the editor panel, so I do not build editing twice.
- As an **operator**, I want `Alt+Left`/`Alt+Right` to jump by word and
  `Alt+Backspace`/`Alt+Delete` to remove one, so I can reshape a sentence
  without holding an arrow key.
- As an **operator**, I want `Shift` plus the arrows (and `Ctrl+A`) to select a
  range that the next keystroke replaces, so I can retype a phrase in one go.
- As an **operator**, I want the caret to keep its column as I move vertically
  and to stay at the line end when it started there, so `Up`/`Down` feel
  predictable in a ragged paragraph.

## Acceptance Criteria

### Functional Requirements

- [ ] `TTextEdit` holds a `UnicodeString` buffer (`#10` separates logical lines)
      and a caret expressed as a grapheme-cluster index.
- [ ] `InsertText` inserts at the caret and advances it; `Backspace` deletes the
      cluster before the caret; `DeleteForward` deletes the cluster at it.
- [ ] `Left`/`Right` move one cluster; `Up`/`Down` move one display row and
      preserve the visual column (clamped to the row length).
- [ ] `Home`/`End` move to the start/end of the current logical line.
- [ ] A buffer ending in `#10` renders a final empty display row, and the caret
      after `Shift+Enter` sits at that row's head.
- [ ] Wrapping is grapheme- and East Asian width-correct: a wide cluster is two
      columns, a combining mark stays with its base and adds none.
- [ ] The caret is drawn at its cell; the view scrolls vertically so the caret
      row is always visible.
- [ ] Any buffer mutation or caret move fires `OnChange` so the host can
      re-layout.
- [ ] `HandleEvent` maps the navigation and editing keys; `Enter` inserts a
      newline, so a host that submits on `Enter` intercepts it first.
- [ ] Word-wise motion and deletion (`Alt` + arrow / backspace / delete) treat a
      word as a maximal run of non-whitespace clusters.
- [ ] `Shift` plus any movement extends a selection from an anchor; typing,
      backspace, and delete replace it; `Ctrl+A` selects all.
- [ ] A vertical move that starts at the end of a row keeps "end of row" as its
      goal, so it lands at the end of every row it crosses.
- [ ] Over a cluster the caret swaps the caret colour's foreground and
      background; with a selection it does not blink; when the widget is
      inactive it is a hollow box past the text and leaves the text under it
      unhighlighted.

### Non-Functional Requirements

- [ ] No new dependency; reuses TUI Core and the RTL grapheme/width units.
- [ ] Shared cluster/width helpers live in one unit, not copied per widget.
- [ ] Testable headlessly with the memory surface; leak-clean under
      `make test-leak`; `make check` green.
- [ ] Style: `{$mode delphi}{$H+}`, units named `hildi.tui.*`.

## Success Metrics

### Quantitative

- Every acceptance criterion maps to at least one named fpcunit test.
- The compose box edits, navigates, and renders entirely through `TTextEdit`.
- `make check` green.

### Qualitative

- The compose box loses its bespoke buffer and caret maths.
- Adding editing to the editor panel is wiring, not new logic.

## Constraints

### Technical

- Build with FPC 3.3.1, `{$mode delphi}`; keep `make check` green.
- `TTextEdit` is a leaf widget; no terminal or application dependency.
- Work on `main`; spec-first, TDD.

### Business / Time

- Operator-requested; unblocks correct compose input and the editor panel.

## Dependencies

### Internal

- `hildi.tui.base/widget/input/surface` (TUI Core).
- `hildi.tui.text` (`TWrapMode`), and the extracted
  `hildi.tui.grapheme` helper.
- The demo's compose box becomes the first consumer.

### External

- RTL `graphemebreakproperty` and `eastasianwidth` (already used by `text.pas`
  and `prompt.pas`).

## Risks

- **Caret/wrap mapping drift.** The caret is a cluster index and the display is
  derived, so a wrap change can move the caret. Mitigation: one mapping function,
  covered by round-trip tests, and a `Shift+Enter` regression test.
- **Duplicated cluster helpers.** A third copy would ossify the duplication.
  Mitigation: extract `hildi.tui.grapheme` first and adopt it in
  `text.pas`/`prompt.pas`.
- **Vertical column drift.** Up/Down must not accumulate rounding across rows.
  Mitigation: a stored goal column, cleared by any non-vertical move.
- **Scope creep into a full editor** (selection, clipboard, undo, horizontal
  scroll). Mitigation: the explicit out-of-scope list below.

## Out of Scope

- Selection, clipboard, undo/redo, search, mouse caret placement.
- Horizontal scrolling (`wmNone` buffers wider than the viewport).
- Word-wise motion (`Ctrl+Left`/`Ctrl+Right`), soft-wrap-aware `Home`/`End`.
- Syntax highlighting, line numbers, tabs/indent handling, `Tab` insertion.
- Multi-caret, IME composition, bidirectional text.
- Rewriting `TPromptLine` on top of `TTextEdit` (it keeps its history and
  prompt; a later spec may fold it in).

## Future Considerations

- Fold `TPromptLine` into `TTextEdit` once it gains history and a prompt gutter.
- Horizontal scroll and `wmNone` for code editing in the editor panel.
- Selection and clipboard once a system clipboard path exists.
- The editor panel adopting `TTextEdit` with a line-number gutter.

## Notes

- **ICE score: Impact 8, Confidence 8, Ease 6.** High impact (compose and editor
  share it); high confidence (cluster handling already exists twice); moderate
  ease (the caret/wrap mapping and the goal column are the fiddly parts).
