# Component Specification: TUI Core

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildegard.helper.tui.*` is the rendering and layout foundation for the TUI
Harness. It owns the cell surface, the input events, the grid layout engine, the
widget protocol, the basic text block, scroll containers with scrollbars, the
modal plane stack, and the application loop. It knows nothing about the agent,
approvals, sessions, or markdown: it is a small, testable UI toolkit that other
components build on.

The render target is an interface so that the entire toolkit is exercised in
tests without a terminal. The concrete target is FPC's `video` unit on Unix,
which already provides a dynamic Unicode cell buffer and a diffing flush, and
renders **the full 256-colour palette** (indices 0..255) by emitting `38;5;n` /
`48;5;n`.

## Requirements

### Functional

- [ ] Provide an abstract surface (size, draw cell, fill, dim, clip, flush) with
      a terminal implementation over `video` and an in-memory implementation for
      tests.
- [ ] Support the full 256-colour extended palette: base ANSI colours (0..15),
      the 6x6x6 colour cube (16..231), and greyscale (232..255), addressed by
      palette index.
- [ ] Read the terminal size at startup and report resize events through the
      input stream.
- [ ] Decode a minimal key set (characters, enter, escape, tab, backspace,
      delete, arrows, page up/down, home, end) into semantic events; leave room
      for a future mouse event.
- [ ] Lay out a tree of containers with grid tracks sized `fixed`/`auto`/`fill`
      on both axes, with gaps.
- [ ] Support nesting arbitrary containers; a stack is a one-line grid.
- [ ] Clip a container's content to its bounds and scroll it independently, with
      a vertical scrollbar.
- [ ] Render a text block of styled spans with UTF-8 grapheme/wide-char aware
      wrapping and clipping.
- [ ] For a modal: render the base plane(s) first, apply a dim effect to the
      rendered background, then draw the modal on top, trapping input while it is
      present.
- [ ] Compose a frame once per `Step` and flush once; only changed cells are
      written.

### Non-Functional

- Portability: macOS and Linux, FPC 3.3.1, `{$mode delphi}`; `cthreads` first if
  threaded.
- Reliability: leak-clean under `make test-leak`.
- Testability: no core unit depends on a live terminal; the surface is injected
  and the in-memory surface is asserted cell-by-cell.
- Performance: a full repaint is O(cells); `video` writes only changed cells.

## Contracts & Interfaces

> Contracts are Pascal type declarations. No method bodies.

### Base Types

```pascal
unit hildegard.helper.tui.base;

type
  { Size in character cells and rows. }
  TSize = record
    W, H: Integer;
  end;

  { Rectangle in character cells. The toolkit's own rect; it intentionally
    shadows the RTL's TRect to avoid the A/B vs Left/Top ambiguity. }
  TRect = record
    X, Y, W, H: Integer;
  end;

  { Rendition flags, mapped to the terminal backend's attributes. }
  TStyleFlag = (sfBold, sfDim, sfItalic, sfUnderline, sfReverse, sfBlink, sfStrike);
  TStyle = set of TStyleFlag;

  { A cell attribute: 256-colour foreground/background palette indices plus
    rendition flags. Indices 0..15 are the base ANSI colours, 16..231 the 6x6x6
    colour cube, and 232..255 greyscale; a theme chooses the indices. }
  TAttr = record
    Fg, Bg: Byte;    // 0..255
    Style: TStyle;
  end;

  { A screen cell. Ch is an extended grapheme cluster; '' means erased/blank. }
  TCell = record
    Ch: UnicodeString;
    Attr: TAttr;
  end;

const
  DefaultAttr: TAttr = (Fg: 7; Bg: 0; Style: []);
  ErasedChar = '';
```

### Surface

```pascal
unit hildegard.helper.tui.surface;

type
  { The rendering target. All widget drawing goes through this; it is the sole
    seam between the toolkit and the terminal. Coordinates are surface-absolute
    and clipped by the current clip rectangle. }
  ISurface = interface
    function Width: Integer;
    function Height: Integer;
    procedure Clear(const AAttr: TAttr);
    procedure Put(X, Y: Integer; const ACell: TCell);
    procedure FillRect(const R: TRect; const AAttr: TAttr);
    procedure DimRect(const R: TRect);
    procedure PushClip(const R: TRect);   // intersects with the current clip
    procedure PopClip;
    procedure Flush;                       // present the buffer (diff only)
  end;

  { Terminal implementation over FPC's video unit. Owns the video lifecycle
    (alternate screen, cursor). Maps TAttr to TEnhancedVideoCell: Fg/Bg become
    ForegroundColor/BackgroundColor (0..255) and Style becomes the enhanced
    video attribute set. Declared in the adapter unit
    `hildegard.helper.tui.surface.video` so this core unit never `uses` video
    (the test binary stays terminal-free). }
  TSurfaceVideo = class(TInterfacedObject, ISurface)
  public
    constructor Create;
    destructor Destroy; override;
  end;

  { In-memory implementation for tests: a Width x Height cell array that can be
    asserted cell-by-cell. Flush does not emit; it compares the buffer against
    the previous frame, records how many cells changed, and counts calls. This
    makes the diff's locality a deterministic, testable property. }
  TSurfaceMemory = class(TInterfacedObject, ISurface)
  public
    constructor Create(AWidth, AHeight: Integer);
    function CellAt(X, Y: Integer): TCell;
    function FlushCount: Integer;
    function LastFrameChangedCells: Integer;   // cells that differed last Flush
    function RowText(Y, X, Len: Integer): UnicodeString;
    procedure ResetFrameStats;                  // zero the counters
    procedure Resize(AWidth, AHeight: Integer); // test seam: mirrors a terminal resize
  end;
```

Note: `Resize` exists only on the in-memory surface, to let tests change
dimensions in place; the terminal surface gets its size from `video` and reports
the change through an `ikResize` input event instead.

Notes:

- **256 colours.** `TSurfaceVideo` writes `Fg`/`Bg` into
  `TEnhancedVideoCell.ForegroundColor`/`BackgroundColor`; `video`'s `attr2ansi`
  emits the basic 16 colours for indices <= 15 and `38;5;n`/`48;5;n` for the
  rest. No escape-sequence code is written by this toolkit.
- **Diff and flush.** `TSurfaceVideo.Flush` calls `video.UpdateScreen(False)`;
  `video` diffs against its own previous buffer, so the toolkit never tracks
  damage and unchanged cells are not re-emitted.
- **DimRect** rewrites the attributes of cells already in the region: it adds
  `sfDim` (mapped by the backend to `evaFaint`) to every cell, leaving the glyphs
  and the colour indices unchanged. Because the whole frame is rebuilt on every
  `Step`, dimming never accumulates. If a terminal does not render faint, the
  terminal surface falls back to mapping each colour index to a darker index
  (documented; the in-memory surface always records `sfDim`, so behaviour is
  testable regardless of terminal support).
- `Put` outside the clip rectangle is silently ignored (all widgets may draw
  freely; clipping is enforced by the surface).

### Input

```pascal
unit hildegard.helper.tui.input;

type
  TModifier = (moShift, moCtrl, moAlt);
  TModifiers = set of TModifier;

  TKeyKind = (kkNone, kkChar, kkEnter, kkEscape, kkTab, kkBackspace, kkDelete,
    kkUp, kkDown, kkLeft, kkRight, kkPageUp, kkPageDown, kkHome, kkEnd,
    kkFunction);

  TKeyEvent = record
    Kind: TKeyKind;
    Ch: UnicodeString;   // when Kind = kkChar
    FuncIndex: Integer;  // when Kind = kkFunction (1 = F1)
    Mods: TModifiers;
  end;

  TMouseButton = (mbNone, mbLeft, mbMiddle, mbRight, mbWheelUp, mbWheelDown);
  TMouseEvent = record
    X, Y: Integer;
    Button: TMouseButton;
    Mods: TModifiers;
  end;

  TInputKind = (ikNone, ikKey, ikMouse, ikResize);

  TInputEvent = record
    Kind: TInputKind;
    Key: TKeyEvent;
    Mouse: TMouseEvent;
    NewSize: TSize;      // when Kind = ikResize
  end;

  { A non-blocking source of input events. Poll returns False when no event is
    ready. The terminal implementation reads raw input and checks TIOCGWINSZ;
    a scripted implementation feeds canned events to tests. }
  IInputSource = interface
    function Poll(out AEvent: TInputEvent): Boolean;
    function Wait(ATimeoutMs: Integer; out AEvent: TInputEvent): Boolean;
  end;

  { Declared in the adapter unit `hildegard.helper.tui.input.terminal`, which
    owns raw mode and reads bytes; the pure decoding lives in
    `hildegard.helper.tui.input.decode`. The core input unit stays terminal-free. }
  TInputSourceTerminal = class(TInterfacedObject, IInputSource)
  public
    constructor Create;
    destructor Destroy; override;
  end;

  TInputSourceScripted = class(TInterfacedObject, IInputSource)
  public
    procedure Push(const AEvent: TInputEvent);
  end;
```

Notes:

- v1 emits `ikMouse` only if the terminal source is implemented for it; the
  toolkit consumes the event shape but no widget needs mouse to satisfy the
  feature. Mouse can be deferred without changing contracts.
- `Wait` is used by the application loop to idle without busy-spinning; a
  timeout of zero is a pure poll.

### Widgets

```pascal
unit hildegard.helper.tui.widget;

type
  { Base widget protocol. Bounds are surface-absolute after Arrange. }
  TWidget = class
  protected
    FBounds: TRect;
    FVisible: Boolean;
  public
    { Preferred size given an available area. Used to resolve `auto` tracks and
      scrollbar/content extents. Must not depend on a prior Arrange. }
    function Measure(const AAvail: TSize): TSize; virtual;

    { Assign final bounds; containers recurse into children here. }
    procedure Arrange(const ABounds: TRect); virtual;

    { Draw self into the (already clipped) surface. }
    procedure Render(const S: ISurface); virtual;

    { Consume an event. Return True if handled. }
    function HandleEvent(const E: TInputEvent): Boolean; virtual;

    property Bounds: TRect read FBounds;
    property Visible: Boolean read FVisible write FVisible;
  end;

  { Layout tracks. `fixed` is an exact size; `auto` is max-content (Measure);
    `fill` shares leftover space by Weight. }
  TTrackKind = (tkFixed, tkAuto, tkFill);
  TTrack = record
    Kind: TTrackKind;
    Size: Integer;    // for tkFixed
    Weight: Integer;  // for tkFill (>= 1)
  end;

function Fixed(ASize: Integer): TTrack;
function Auto: TTrack;
function Fill(AWeight: Integer = 1): TTrack;

type
  { A grid container. Columns and Rows describe the tracks; children are placed
    into cells row-major by Add order, or explicitly by (ACol, ARow). A vertical
    stack is a 1-column grid; a horizontal stack is a 1-row grid. }
  TContainer = class(TWidget)
  public
    constructor Create(const AColumns: array of TTrack;
      const ARows: array of TTrack; AColGap: Integer = 0; ARowGap: Integer = 0);
    procedure Add(const AW: TWidget); overload;                 // next free cell
    procedure Add(const AW: TWidget; ACol, ARow: Integer); overload;
    function ChildCount: Integer;
  end;
```

Notes:

- **Track resolution (top-down, single pass).** Given the container's bounds:
  fixed tracks take their `Size`; `fill` tracks share `avail - sum(fixed) -
  gaps`, distributed by `Weight`; `auto` tracks take `max(measure(child))` across
  the cells in that track. Because `auto` is max-content and wrapping text is
  required to be in `fixed`/`fill` tracks, no width/height fixed-point iteration
  is needed.
- Cross-axis alignment (stretch/start/center/end) is **not** in v1; children
  fill their cell. A later version may add `Align` without a contract break.
- Widgets that are not visible are skipped by Arrange measurement contribution
  and Render, but still consume a cell unless explicitly excluded.

### Text

```pascal
unit hildegard.helper.tui.text;

type
  TSpan = record
    Text: UnicodeString;
    Attr: TAttr;
  end;

  TWrapMode = (wmNone, wmChar, wmWord);
  TTextAlign = (taLeft, taCenter, taRight);

  { A leaf that holds styled text. Widths are measured in display columns using
    grapheme clusters and East Asian width. }
  TTextBlock = class(TWidget)
  public
    constructor Create(const ASpans: array of TSpan; AWrap: TWrapMode = wmWord);
    procedure SetText(const AText: string; const AAttr: TAttr);
    procedure SetSpans(const ASpans: array of TSpan);
    property Align: TTextAlign;   // read/write
  end;
```

Behaviour:

- `Measure` returns the preferred size for the current spans: with `wmNone`, the
  longest line; with wrapping, the block needs a width to be meaningful, so its
  preferred width is the longest word and its preferred height is the wrapped
  height at that width. In practice `auto` text blocks in a container should be
  paired with a `fixed`/`fill` width; the measure is a best effort for `auto`.
- Scrolling a text block uses the same viewport machinery as any overflowing
  container (below), so much of the wrap/measure logic is shared.

### Scroll

```pascal
unit hildegard.helper.tui.scroll;

type
  TScrollMode = (smNever, smAuto, smAlways);

  { A container that clips a single child and scrolls it. It fills the space it
    is given (it does not propagate content size upward). }
  TScrollContainer = class(TWidget)
  public
    constructor Create(AChild: TWidget; AVert: TScrollMode = smAuto;
      AHorz: TScrollMode = smNever);
    procedure ScrollTo(AX, AY: Integer);
    procedure ScrollBy(AX, AY: Integer);
    property ScrollX: Integer;   // read/write, clamped to content
    property ScrollY: Integer;   // read/write, clamped to content
    property VertScrollBar: TScrollMode;   // read/write
    property HorzScrollBar: TScrollMode;   // read/write
  end;

  { A scrollbar. v1 implements the vertical case; orientation is a property so
    horizontal can be added without a contract break. }
  TScrollBarOrientation = (soVertical, soHorizontal);
  TScrollBar = class(TWidget)
  public
    constructor Create(AOrientation: TScrollBarOrientation);
    property Value: Integer;    // read/write (clamped to [0, Range - Page])
    property Range: Integer;    // read/write (content extent)
    property Page: Integer;     // read/write (viewport extent)
    function ThumbSize: Integer;    // thumb length in cells
    function ThumbStart: Integer;   // absolute cell (row/column) of the thumb
  end;
```

Behaviour:

- `TScrollContainer` handles `kkUp`/`kkDown`/`kkPageUp`/`kkPageDown`/`kkHome`/
  `kkEnd` when focused, and forwards any other event to its child first.
- Scrollbar interaction in v1 is keyboard-driven through the container; the
  scrollbar is display plus optional click in a later version.
- Clamping: `ScrollX`/`ScrollY` are clamped to `[0, max(0, Content - Viewport)]`.
- Scrollbar geometry: the track is the bar's own length (height for vertical,
  width for horizontal). When `Range <= Page` the thumb covers the whole track;
  otherwise `ThumbSize = max(1, Track * Page div Range)` and the thumb offset is
  `Value * (Track - ThumbSize) div (Range - Page)`. `ThumbStart` is absolute
  (bar origin plus offset).

### Planes and Application

```pascal
unit hildegard.helper.tui.app;

type
  { A plane is a widget tree drawn as one layer. Modal planes trap input. }
  TPlane = class
  public
    constructor Create(ARoot: TWidget; AIsModal: Boolean;
      ADimBackground: Boolean = False);
    property Root: TWidget;
    property IsModal: Boolean;
    property DimBackground: Boolean;
  end;

  TTuiApp = class
  public
    constructor Create(const ASurface: ISurface; const AInput: IInputSource;
      ARoot: TWidget);
    destructor Destroy; override;

    procedure PushPlane(const APlane: TPlane);
    procedure PopPlane;
    function ModalActive: Boolean;
    procedure Stop;             // request the loop to end on the next Step
    procedure Invalidate;       // mark layout dirty for the next Step

    { One iteration: process at most one input event (or resize), mark layout
      dirty on change, lay out if dirty, render the frame, flush. Returns False
      when the loop should stop (for example, the base root requested close). }
    function Step: Boolean;

    { Convenience: Step until it returns False. The example uses this; tests use
      Step directly with a scripted input source. }
    procedure Run;
  end;
```

Behaviour:

- **Render order (explicit, locked).** For each frame:
  1. `Clear` the surface.
  2. Render the non-modal base plane(s) in stacking order. The main content is
     now in the buffer at full brightness.
  3. For each modal plane with `DimBackground`: `DimRect(full surface bounds)`.
     This mutes the already-rendered background **without erasing it**, so the
     main content remains visible underneath the modal's overlay.
  4. Render the modal plane's `Root` on top, at full brightness, clipped to its
     own bounds. The modal's region is therefore not dimmed; everything around it
     is.
  5. `Flush` once (diff against the previous frame).

  No background snapshot is needed: the whole frame is rebuilt every `Step`, so
  the base is re-rendered fresh and dimming cannot accumulate. A second dimmed
  modal would dim the already-dimmed base once more (documented; typical UIs use
  one modal at a time).
- **Input routing.** If any modal plane exists, dispatch only to the topmost
  modal; otherwise to the base root. A consumed event is not offered further.
  If the topmost modal does not handle a `kkEscape`, the app pops it, so a modal
  is dismissible by a key (the base is never popped this way). `Stop` requests
  the loop to end: the next `Step` returns False.
- **Focus.** The application holds the focused widget; a container forwards
  unhandled scroll keys to its focused descendant. `kkTab` cycles focus among
  focusable widgets in the base plane. v1 may keep focus set programmatically by
  the caller rather than fully implementing tab traversal, provided the example
  demonstrates switching panes.
- **Resize.** An `ikResize` marks layout dirty; the surface already reflects the
  new size. The root is re-arranged to the new bounds.
- **Layout dirtying.** `Arrange` is only called when the surface size, content,
  or plane stack changes, not on every `Step`. A resize, `PushPlane`, and
  `PopPlane` mark layout dirty internally; a caller whose widget content changed
  calls `Invalidate` (for example, after appending text or changing a container
  tree). The next `Step` arranges once and clears the flag.

## Architecture

### Prior Art & Reuse

- **FPC `video`** supplies the entire terminal layer: `EnhancedVideoBuf` (a
  dynamic array of Unicode cells with 8-bit foreground/background indices),
  `UpdateScreen(Force)` (a cell-by-cell diff and flush that emits true 256-colour
  `38;5;n`/`48;5;n`), `SetCursorPos`/`SetCursorType`, `ScreenWidth`/`ScreenHeight`,
  `StringDisplayWidth`, and `SetVideoMode`/`TIOCGWINSZ` for resize. This is rung
  3 of the ladder and removes the need to write any escape-sequence code. The
  256-colour extended palette is exactly the ceiling `video`'s cell model
  supports, which is sufficient for this feature.
- **FPC `keyboard` is deliberately not used.** Its `InitKeyboard` runs a blocking
  kitty-key/DA1 probe (it can hang or swallow the first key) and its decoder
  proved unreliable under a pty. Instead, RTL `termio`/`baseunix` set raw mode
  and read bytes, and `hildegard.helper.tui.input.decode` maps them to events
  (a pure, unit-tested unit).
- **RTL `graphemebreakproperty` and `eastasianwidth`** supply grapheme cluster
  iteration and display width, already used by `video`.
- **`fcl-fpterm`** (`packages/fcl-fpterm/src`) is prior art: its `TCell`/
  `TAttribute` model (which also uses a 256-colour palette plus rendition flags)
  and its abstract `TTerminalView` backend seam overlap with this spec. It is
  **not** a dependency because its platform adapters (video view, keyboard,
  mouse, pty) are deliberately excluded on macOS by its `fpmake.pp`, and it
  provides no widgets or layout. Its cell/attribute design informed `TAttr`.
- **Free Vision (`fv`)** is prior art for widgets but is deliberately not used:
  its overlapping-window, 16-colour, global-state model is far more than a tiled
  layout needs, and adopting it would climb past the required rung.
- **`hildegard.helper.ansi`** is not reused: it is a streaming SGR emitter with
  no buffer or cursor control.

The genuine gap: the surface abstraction, the track layout engine, the widget
protocol, the text viewport, scroll containers/scrollbars, modal planes, and the
application loop.

### Component Boundaries

- **Responsibilities:** cell rendering, input events, layout, widgets, scrolling,
  planes, the loop.
- **Dependencies:** FPC `video`, `SysUtils`, `Classes`, RTL `termio`/`baseunix`,
  and the RTL Unicode units. The core units (`base`, `surface`, `input`,
  `widget`, `text`, `scroll`, `app`) must not depend on `video` directly; only
  the adapter units `surface.video` and `input.terminal` do, so the test binary
  never links a terminal. (`input.decode` is pure and is unit-tested.)
- **Side effects:** the terminal surface owns the screen (alt-screen, raw mode,
  cursor); nothing else mutates global state.

### Data Flow

1. **Input:** `TTuiApp.Step` polls the input source. A key is routed (modal-first)
   to a widget; an unhandled key may quit. A resize marks layout dirty.
2. **Layout:** on dirty, `Root.Arrange(surface bounds)` recursively resolves
   tracks and arranges children; `auto` uses `Measure`; `fill` shares leftover.
3. **Render:** `Clear`; render base planes; dim the background once per dimmed
   modal; render modal planes; `Flush` diffs and writes.
4. **Error handling:** widget methods do not raise for ordinary input; a failed
   surface flush is reported once and the loop stops.

### Integration Patterns

- Synchronous and single-threaded. The toolkit does not start threads; only the
  future `Harness_UI` moves agent work off the main thread, and it does so behind
  an event queue (deferred).
- Ownership: `TTuiApp` does not own the surface or input source; it owns the
  plane objects it is given (documented and tested for leaks). Widget ownership
  is by their containers; the app's root owns its children.

## Validation Rules

### Input

- `TTrack` `tkFill` with `Weight <= 0` is normalised to 1.
- `tkFixed` with `Size < 0` is normalised to 0.
- Scroll offsets are clamped to the content; negative becomes 0.
- A `TPlane` root must be non-nil; a modal pushed with a nil root is rejected.

### Output Guarantees

- Drawing is always clipped; a widget cannot write outside its bounds or the
  surface.
- `Flush` is idempotent with respect to the current buffer; a second flush with
  no changes writes nothing.
- `Measure` is pure: it does not mutate widget state or the surface.

## Error Handling

### Error Types

- **Configuration:** an unsupported surface size (zero) is treated as 1x1 rather
  than failing.
- **Runtime:** a widget that raises during `Render`/`Arrange` is caught by the
  application loop, logged as a single line to stderr after restoring the
  terminal, and stops the loop. (Widgets should not raise for input.)
- **No error codes** cross this boundary; this is an internal UI toolkit.

### Error Contracts

- The application restores the terminal (alternate screen off, cursor shown) on
  every exit path, including a raised widget error.

## Testing Requirements

Tests drive `TSurfaceMemory` and `TInputSourceScripted`, so no terminal is
attached. Each named test becomes an fpcunit method.

### Unit Tests (`tests/test_tui_surface.pas`)

- [ ] `TestSurfaceClearFillsAllCells`
- [ ] `TestPutOutsideClipIsIgnored`
- [ ] `TestPushClipIntersects`
- [ ] `TestFillRect`
- [ ] `Test256ColorIndexRetainedInCell`
- [ ] `TestFlushIdempotent` (memory surface)
- [ ] `TestDimAddsFaintButKeepsGlyphsAndColors`

### Unit Tests (`tests/test_tui_layout.pas`)

- [ ] `TestFixedTracksTakeExactSize`
- [ ] `TestFillTracksShareRemainderByWeight`
- [ ] `TestAutoTrackMeasuresContent`
- [ ] `TestGapsReduceAvailableSpace`
- [ ] `TestNestedContainerIsLaidOut`
- [ ] `TestVerticalStackIsOneColumnGrid`
- [ ] `TestOverflowingContentIsClipped`
- [ ] `TestEmptyAndZeroSizedTracks`

### Unit Tests (`tests/test_tui_text.pas`)

- [ ] `TestMeasureLongestLine`
- [ ] `TestCharacterWrap`
- [ ] `TestWordWrap`
- [ ] `TestWideCharacterOccupiesTwoColumns`
- [ ] `TestCombiningMarkIsOneCluster`
- [ ] `TestStyledSpansRetainAttributes`
- [ ] `TestTextClippedToBounds`

### Unit Tests (`tests/test_tui_scroll.pas`)

- [ ] `TestContentSmallerThanViewportDoesNotScroll`
- [ ] `TestContentEqualViewportDoesNotScroll`
- [ ] `TestContentLargerThanViewportScrolls`
- [ ] `TestScrollClampedAtBothEnds`
- [ ] `TestKeyboardScrollKeysMoveViewport`
- [ ] `TestTwoContainersScrollIndependently`
- [ ] `TestScrollbarThumbGeometry`

### Unit Tests (`tests/test_tui_app.pas`)

- [ ] `TestFrameRendersBaseThenModal`
- [ ] `TestModalDimsBackgroundButKeepsText` (glyphs under the overlay survive,
      attributes gain `sfDim`)
- [ ] `TestModalRegionNotDimmed`
- [ ] `TestModalTrapsInput`
- [ ] `TestPopModalRestoresBase`
- [ ] `TestResizeRelayoutsRoot`
- [ ] `TestStepProcessesOneEvent`
- [ ] `TestNoLeaks` (enforced by `make test-leak`)

### Performance Tests (`tests/test_tui_perf.pas`)

Deterministic and part of `make check`; they assert **work**, not wall-clock, so
they cannot flake:

- [ ] `TestFirstFrameChangesAllCells` (`LastFrameChangedCells = W*H`)
- [ ] `TestUnchangedFrameChangesZeroCells`
- [ ] `TestOneLineAppendChangesOnlyItsRow` (changed cells <= viewport width)
- [ ] `TestScrollChangesOnlyViewportRows` (bounded by viewport area, not document)
- [ ] `TestLayoutRunsOnlyWhenDirty` (spy widget counts `Arrange` calls across
      steps; a `Step` with no input must not re-arrange)
- [ ] `TestModalToggleChangesOnlyOverlayAndDimmedRegion`

Wall-clock budget tests are **not** in `make check`; they run explicitly and
print numbers (see the benchmark), because timing assertions are environment
dependent.

### Benchmark (`examples/tui_bench.pas`, `make bench`)

A manual, printable benchmark the operator runs to verify refresh rate. It
composes a representative layout (a scrolling chat pane, a second pane, a status
row) and measures, with a monotonic clock
(`fpgettimeofday`/`clock_gettime`, or `TStopwatch`), over a fixed number of
frames:

| Scenario | What it times |
| --- | --- |
| `full` | clear + render the whole tree every frame (full repaint) |
| `append` | append one short line to the chat block, then render |
| `scroll` | advance a scroll offset by one, then render |
| `resize` | alternate between two terminal sizes (relayout + render) |
| `modal` | toggle a dimmed modal on and off |

For each it prints: frames, total ms, ms/frame, fps, and average changed
cells/frame (from `TSurfaceMemory.LastFrameChangedCells`). Two modes: headless
(memory surface, deterministic cells; default) and `--real` (the actual
`TSurfaceVideo`, end-to-end including `video.UpdateScreen`). The benchmark
exits 0 and makes no assertions; the operator reads the table. A short printed
verdict compares the numbers against the budgets above.

## Performance Targets

Budgets are for the development machine (Apple-silicon macOS), an 80x50 terminal,
and the representative layout used by the benchmark below. They are deliberately
loose enough to be stable locally and tight enough to catch a regression.

- **Compose:** full-frame layout + render (into the surface) <= 2 ms.
- **Frame (full repaint):** compose + flush <= 10 ms (>= 100 fps).
- **Frame (incremental):** a one-line content change, compose + flush <= 5 ms
  (>= 200 fps).
- **Streaming:** sustain >= 60 fps while appending text every frame.
- **Relayout:** one resize/relayout <= 20 ms.
- **Diff locality (deterministic, not timed):** a one-line append changes cells
  only on the affected row(s); an unchanged frame changes zero cells. Measured
  via `TSurfaceMemory.LastFrameChangedCells`, so it is asserted in `make check`.
- **Memory:** steady-state frames at a fixed size do not grow heap usage beyond a
  small tolerance (measured with `GetFPCHeapStatus`, reported by the benchmark;
  the hard leak gate remains `make test-leak`).
- A full repaint is O(W*H); `Flush` writes only changed cells.
- No allocation per `Step` beyond the surface buffer and widget-owned data.
- Layout runs only when dirty, not per frame.

## Security Considerations

- Text content may originate from the model or command output and is **untrusted
  for display only**: it is drawn as cells, never evaluated, never used to build
  escape sequences, and clips rather than overflows. Control characters other
  than the ones the surface handles are rendered as their printable replacement.
- The toolkit adds no network, filesystem, or process access.

## Success Criteria

### Functional

- [ ] All contracts implemented; all validation rules enforced.
- [ ] The full 256-colour palette renders correctly (indices > 15 emit
      `38;5;n`/`48;5;n` via `video`).
- [ ] A nested layout with two independently scrolling text panes and a dimmed
      modal (base visible underneath) renders correctly and responds to resize in
      the example.
- [ ] `make check` passes.

### Quality

- [ ] Every acceptance criterion in `FEATURE.md` maps to a passing test.
- [ ] Core units compile and test without the `video` unit on the unit path
      (except the terminal surface/input adapters).
- [ ] No memory leaks.

## Future Considerations

- Cross-axis alignment (`stretch`/`start`/`center`/`end`) per child.
- Mouse: focus-on-click, wheel-to-scroll, scrollbar drag.
- Horizontal scrolling and tab stops.
- A `TMarkdownView` widget that maps markdown blocks to a container of text
  blocks (see `Markdown_v1.SPEC.md`).
- An editable text widget backed by FPC's gap-buffer editor model.
- A terminal pane backed by `fcl-fpterm`'s controller and a pty (Linux first).
- Themed colours: a named palette resolved to 256-colour indices, layered over
  the raw index model.

## Revision Note

This spec was revised before implementation to (a) state the 256-colour extended
palette explicitly (it was implied by `Byte` indices; truecolour is **not** a
goal, so FPC `video` remains the backend and no custom emitter is written), and
(b) lock the modal render order: render the base, dim the rendered background,
then draw the modal, so the main content stays visible underneath. No version
bump: nothing was implemented against the prior draft.
