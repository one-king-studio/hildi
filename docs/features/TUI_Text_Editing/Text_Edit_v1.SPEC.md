# Component Specification: Text Edit v1

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

Two units: `hildi.tui.grapheme`, the shared grapheme-cluster and
display-width helpers currently copied into `text.pas` and `prompt.pas`, and
`hildi.tui.edit`, the caret-aware multi-line editor widget built on
them. The editor is the only thing that changes text; hosts (the compose box,
later the editor panel) supply chrome and decide what `Enter` means.

## Requirements

### Functional

- [ ] Core capability: own a text buffer plus a caret, and expose insert,
      delete, and caret movement as explicit operations.
- [ ] Input handling: map `Left`/`Right`/`Up`/`Down`/`Home`/`End`/`Backspace`/
      `Delete`/`Enter`/character keys to those operations.
- [ ] Output generation: render the buffer as display rows with the caret cell
      marked, scrolled so the caret is visible.
- [ ] Integration points: emit `OnChange` after every mutation or caret move so
      the host re-lays out; expose the text and caret for the host to read.

### Non-Functional

- Performance: layout is O(buffer) per measure/render; the buffers here are
  message-sized. No per-keystroke allocation beyond the rows array.
- Reliability: no leaks under `make test-leak`; a caret index is always in
  `0..ClusterCount`.
- Portability: pure Pascal; the RTL supplies grapheme and East Asian width data.

## Contracts & Interfaces

> Contracts are expressed as Pascal type declarations. This section defines
> *what* crosses the boundary; the implementer decides the bodies.

### Shared helpers: `hildi.tui.grapheme`

```pascal
unit hildi.tui.grapheme;

type
  TClusterArray = array of UnicodeString;
  TClusterOffsetArray = array of Integer;

{ Split AText into extended grapheme clusters, in order. }
function Clusters(const AText: UnicodeString): TClusterArray;

{ The display width of one cluster: 2 for East Asian wide/fullwidth, 0 for an
  empty cluster, otherwise 1. A combining mark belongs to its base cluster and
  is not passed here on its own. }
function ClusterWidth(const ACluster: UnicodeString): Integer;

{ The display width of AText, summed over its clusters. }
function StringWidth(const AText: UnicodeString): Integer;

{ The 1-based code-unit offset of each cluster's first character, so a caller
  can slice AText by cluster index. Length matches Clusters(AText). }
function ClusterStarts(const AText: UnicodeString): TClusterOffsetArray;
```

### Editor widget: `hildi.tui.edit`

```pascal
unit hildi.tui.edit;

uses
  hildi.tui.base, hildi.tui.input,
  hildi.tui.surface, hildi.tui.widget,
  hildi.tui.text;   { TWrapMode }

type
  { One visual line: the clusters it shows and their total display width.
    AFirst and ACount are cluster indices into the buffer. }
  TDisplayRow = record
    First: Integer;   // first cluster shown, inclusive
    Count: Integer;   // clusters shown
    Width: Integer;   // display columns
  end;
  TDisplayRowArray = array of TDisplayRow;

  { A leaf widget: a caret-aware multi-line editor over a UnicodeString.
    The caret is a cluster index in 0..ClusterCount; #10 separates logical
    lines. }
  TTextEdit = class(TWidget)
  public
    constructor Create(AWrap: TWrapMode = wmWord);
    destructor Destroy; override;

    { Buffer and caret. SetText resets the caret to the end. }
    procedure SetText(const AText: UnicodeString);
    function Text: UnicodeString;
    function CaretIndex: Integer;
    procedure SetCaret(AIndex: Integer);

    { Editing. All of these fire OnChange. }
    procedure InsertText(const AText: UnicodeString);
    procedure Backspace;        // delete the cluster before the caret
    procedure DeleteForward;    // delete the cluster at the caret
    procedure Clear;

    { Caret movement. All of these fire OnChange. }
    procedure MoveLeft;
    procedure MoveRight;
    procedure MoveUp;
    procedure MoveDown;
    procedure MoveHome;         // start of the logical line
    procedure MoveEnd;          // end of the logical line

    { The display rows for AWidth, the same split Render uses. }
    function Rows(AWidth: Integer): TDisplayRowArray;
    { The caret's display row and column for AWidth. }
    procedure CaretCell(AWidth: Integer; out ARow, ACol: Integer);

    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;

    property Wrap: TWrapMode read FWrap write FWrap;
    property Active: Boolean read FActive write FActive;
    property Attr: TAttr read FAttr write FAttr;            // text rendition
    property CaretAttr: TAttr read FCaretAttr write FCaretAttr;
    { Top visible display row; clamped to the row count on every layout. }
    property TopRow: Integer read FTopRow;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;
```

### Event Contracts

```pascal
type
  { RTL Classes.TNotifyEvent. Fired on the caller's thread, synchronously, after
    the buffer or the caret changed. Hosts use it to invalidate layout: the
    compose box grows. }
  TNotifyEvent = procedure(Sender: TObject) of object;
```

## Architecture

### Prior Art & Reuse

- `hildi.tui.text` already wraps clusters with correct widths and
  hard-break handling (`WrapClusters`), but the helpers are implementation-only.
  This spec lifts the shared helpers into `grapheme.pas`; `text.pas` keeps its
  styled-cluster wrapping and adopts the helpers.
- `hildi.tui.prompt` already does cluster-indexed insertion, deletion,
  and left/right/home/end, plus a reverse-video caret and horizontal scroll.
  `TTextEdit` generalises the same model to multiple lines and a wrapping width;
  the prompt is left alone (it owns history and a prompt gutter).
- `hildi.tui.widget` supplies the leaf protocol, bounds, and
  `Advance`/`Animating` for the blink. Nothing else in the tree edits text.
- The demo's `TComposeBox` becomes a thin chrome wrapper around `TTextEdit`; its
  `WrapText`, `InsertText`, and `Backspace` go away.

### Component Boundaries

- **Responsibilities:** the buffer, the caret, wrapping to display rows, caret
  movement, vertical scroll, and painting text plus the caret cell.
- **Dependencies:** `grapheme` for clusters/widths, `text` for `TWrapMode`,
  `base`/`input`/`surface`/`widget` for the protocol.
- **Side effects:** none beyond its own state; the host owns the text.

### Data Flow

1. **Input validation:** a key maps to one operation; a caret index is clamped
   to `0..ClusterCount`; `SetText` resets the caret to the end.
2. **Processing:** the operation mutates the buffer and/or the caret, then
   clears the goal column (except for vertical moves) and re-clamps the scroll.
3. **Output generation:** `Rows(AWidth)` splits the buffer into display rows
   using the shared cluster/width helpers; `CaretCell` maps the caret index to
   `(row, col)`; `Render` draws the visible rows and the caret cell.
4. **Error handling:** empty buffers, an empty last line, and widths below one
   column all degrade to at least one row.

### Integration Patterns

- Synchronous, single-threaded, like the rest of the toolkit.
- The host owns the widget and sets `Attr`/`CaretAttr` from the theme.
- `Enter` inserts `#10`; a host that submits on `Enter` checks the key before
  forwarding, so the editor never has to know about submission.

## Validation Rules

### Input

- Caret index is clamped to `0..ClusterCount` on every set and move.
- Width passed to `Rows`/`Measure` below 1 is treated as 1.
- `#13` is treated as `#10`; other control characters are stored and rendered
  as-is (a cluster of width 1).

### Output Guarantees

- `Rows` always returns at least one row; a buffer ending in `#10` yields a
  final empty row.
- The rows tile the buffer in order, excluding the `#10` separators, which start
  no row. A word-wrap break keeps the space at the end of the upper row, so no
  cluster is dropped.
- When the buffer does not end in `#10` and its last row exactly fills the
  width, `Rows` appends an empty row so the caret has a cell of its own.
- `CaretCell` returns a row in `0..High(Rows)` and a column in
  `0..Rows[row].Width`; at a soft-wrap boundary it reports the continuation row,
  which is where the caret can actually be drawn.

## Error Handling

### Error Types

- **Validation errors:** none exposed; invalid inputs are clamped.
- **System errors:** none; no I/O.

### Error Contracts

```pascal
type
  { No error surface: the widget clamps rather than fails. }
  TTextEditError = (teeNone);
```

## Testing Requirements

> What to test; the implementer decides how. Each item becomes a named fpcunit
> `TTestCase` method.

### Unit Tests

- [ ] `grapheme`: cluster splitting with combining marks and surrogate pairs;
      wide clusters measure 2; `StringWidth`; `ClusterStarts` offsets.
- [ ] Editing: insert at the caret, insert mid-buffer, backspace, delete
      forward, clear; the caret ends where the spec says.
- [ ] Navigation: left/right by cluster (with combining and wide characters);
      up/down preserving the column across hard breaks and soft wraps; home/end
      on a logical line.
- [ ] Layout: rows tile the buffer; a trailing `#10` yields a final empty row
      (the `Shift+Enter` regression); word wrap breaks at spaces; char wrap
      breaks mid-word.
- [ ] Caret mapping: `CaretCell` round-trips with `SetCaret` for every cluster
      index at a few widths.
- [ ] Rendering: the caret cell carries `CaretAttr`; the text renders in `Attr`;
      the caret row is scrolled into view when the buffer exceeds the viewport.
- [ ] `OnChange` fires for every mutation and movement.
- [ ] Resource cleanup: no leaks under `make test-leak`.

### Integration Tests

- [ ] `text.pas` and `prompt.pas` still pass their suites after adopting
      `grapheme` (rendering unchanged).
- [ ] The compose box: `Shift+Enter` shows a new row with the caret at its head;
      arrow keys move the caret; `Enter` still submits.

## Performance Targets

- Message-sized buffers (a few KB): layout well under a frame at 10 ms.
- No quadratic scan per keystroke beyond the single `Rows` pass.

## Security Considerations

- Text is stored and drawn, never executed or interpolated into a command.

## Success Criteria

### Functional

- [ ] All contracts implemented.
- [ ] All validation rules enforced.
- [ ] All error scenarios handled.
- [ ] All tests passing (`make check`).

### Quality

- [ ] Contract compliance verified.
- [ ] Performance targets met.
- [ ] No memory leaks.
- [ ] Documentation complete.

## Future Considerations

- `wmNone` with horizontal scrolling for code.
- Selection, clipboard, undo/redo.
- Folding `TPromptLine` into `TTextEdit` (history, prompt gutter).
- A line-number gutter for the editor panel.
