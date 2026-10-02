# Component Specification: Text Edit v2

**Related Feature:** [FEATURE.md](FEATURE.md)
**Supersedes:** [Text_Edit_v1.SPEC.md](Text_Edit_v1.SPEC.md) (extends it; v1 contracts stand)

## Purpose

Extend `TTextEdit` with word-wise motion and deletion, a keyboard-driven
selection, a sticky end-of-row column for vertical movement, and focus-aware
caret rendering. Everything in v1 stands unchanged unless restated here.

## Requirements

### Functional

- [ ] Word motion: `Alt+Left`/`Alt+Right` move to the previous/next word
      boundary; `Alt+Backspace`/`Alt+Delete` remove the word before/after the
      caret. A word is a maximal run of non-whitespace clusters.
- [ ] Selection: `Shift` plus any movement extends a selection from an anchor;
      typing, backspace, and delete replace the selection.
- [ ] Vertical movement: when the caret starts a vertical move at the end of its
      display row, the goal becomes "end of row", so `Up`/`Down` land at the end
      of each row they cross even when the next row is longer.
- [ ] Caret rendering: over a cluster the caret cell is the caret attribute with
      foreground and background swapped; past the last cluster of a row it is a
      filled block; while a selection exists the caret does not blink; when the
      widget is inactive the caret past the last cluster is a hollow box and no
      highlight is drawn over a cluster.
- [ ] The key decoder maps `ESC DEL` / `ESC BS` (how a terminal without the
      kitty keyboard protocol reports Alt+Backspace) to `kkBackspace` with
      `moAlt`, so word deletion works there too. `CSI 1;<n>C/D` already carries
      the modifiers for Alt+Left/Right.

### Non-Functional

- Word motion, deletion, and selection deletion all go through one range-delete
  helper and one pair of word-boundary helpers - no parallel copies.
- Leak-clean under `make test-leak`; `make check` green.

## Contracts & Interfaces

### Public API additions

```pascal
type
  TTextEdit = class(TWidget)
  public
    { Movement and word motion take AExtend: when true the move keeps (or
      starts) a selection from the anchor instead of dropping it. }
    procedure MoveLeft(AExtend: Boolean = False);
    procedure MoveRight(AExtend: Boolean = False);
    procedure MoveUp(AExtend: Boolean = False);
    procedure MoveDown(AExtend: Boolean = False);
    procedure MoveHome(AExtend: Boolean = False);
    procedure MoveEnd(AExtend: Boolean = False);

    { Word motion. A word is a maximal run of non-whitespace clusters. }
    procedure MoveWordLeft(AExtend: Boolean = False);
    procedure MoveWordRight(AExtend: Boolean = False);
    procedure DeleteWordBack;
    procedure DeleteWordForward;

    { Selection: the range between an anchor and the caret. The anchor is set
      when a shift-move starts and cleared by any unshifted move or edit. }
    function HasSelection: Boolean;
    function SelectionStart: Integer;   { lower cluster index, inclusive }
    function SelectionEnd: Integer;     { upper cluster index, exclusive }
    procedure SelectAll;
    procedure ClearSelection;

    { Rendition of a selected cluster. Hosts usually set this to CaretOverlay so
      the selection matches the cursor. }
    property SelAttr: TAttr read FSelAttr write FSelAttr;
    { The rendition the caret paints over a cluster: the caret colour with its
      foreground and background swapped. }
    function CaretOverlay: TAttr;
  end;
```

### Key mapping additions

| Key | Modifier | Action |
| --- | -------- | ------ |
| `Left` / `Right` | - | move one cluster |
| `Left` / `Right` | `Alt` | move one word |
| `Up` / `Down` | - | move one display row |
| `Home` / `End` | - | logical line start / end |
| any movement | `Shift` | extend the selection |
| any movement | `Shift+Alt` | extend the selection by word |
| `Backspace` / `Delete` | - | delete one cluster (or the selection) |
| `Backspace` / `Delete` | `Alt` | delete one word |
| `a` | `Ctrl` | select all |

## Architecture

### Prior Art & Reuse

v1 already has cluster navigation, the display-row model, `CaretAt`, and a
`#10`-aware buffer. This version adds no new unit: it adds a range-delete helper
that `Backspace`, `DeleteForward`, and the two word deletes share, a pair of
word-boundary helpers that the word moves and word deletes share, a selection
anchor, and a "goal is end of row" flag beside the existing goal column.

### Component Boundaries

- **Responsibilities:** as v1, plus the selection range and the sticky column.
- **Dependencies:** unchanged.
- **Side effects:** unchanged; the host still owns the text.

### Data Flow

1. **Input validation:** a movement with `Shift` records the anchor once (on the
   first shifted move) and then only moves the caret; an unshifted move clears
   the anchor.
2. **Processing:** a delete with a selection removes the selection first; a word
   delete removes the range the matching word move would cross.
3. **Output generation:** a cluster inside `[SelectionStart, SelectionEnd)` is
   drawn in `SelAttr`; the caret cell is drawn unless the widget is inactive, and
   it blinks only while there is no selection.
4. **Error handling:** unchanged; every index is clamped.

## Validation Rules

- `SelectionStart` is `min(anchor, caret)` and `SelectionEnd` is
  `max(anchor, caret)`; both are `0` when there is no selection.
- `HasSelection` is true only when the anchor is set and differs from the caret.
- The word helpers always terminate at `0` or `ClusterCount`.

## Testing Requirements

### Unit Tests

- [ ] Word motion: left/right from mid-word, from a word boundary, and across
      runs of spaces and newlines; clamped at both ends.
- [ ] Word deletion: back and forward remove exactly the range the matching word
      move crosses; at the buffer ends they are no-ops.
- [ ] Selection: a shifted move sets the anchor once and extends; an unshifted
      move clears it; `HasSelection`/`SelectionStart`/`SelectionEnd` are correct
      for forward and backward selections; `SelectAll`; `ClearSelection`.
- [ ] Editing with a selection: insert, backspace, and delete replace the
      selection and leave the caret at the selection start.
- [ ] Shifted vertical movement extends the selection and still uses the goal
      column and the sticky end-of-row goal.
- [ ] Sticky end: from the end of a short row, `Down` lands at the end of a
      longer next row; the numeric column still applies elsewhere.
- [ ] Rendering: a selected cluster carries `SelAttr`; the caret over a cluster
      carries the caret attribute with fg/bg swapped; past the last cluster it is
      a block; an inactive editor draws a hollow box and no highlight; the caret
      does not blink while a selection exists.
- [ ] Key mapping for every row of the table above.

### Integration Tests

- [ ] The compose box still submits on `Enter`, adds a line on `Shift+Enter`,
      and now selects with `Shift`+arrows.

## Performance Targets

- Unchanged: message-sized buffers, one `Rows` pass per measure/render.

## Success Criteria

### Functional

- [ ] All contracts implemented; all tests passing (`make check`).

### Quality

- [ ] No memory leaks; documentation updated.

## Future Considerations

- Identifier-aware word motion (`foo.bar` as two words).
- Sticky end-of-row across soft wraps resolved at the logical line.
- Mouse selection, clipboard, undo/redo.
