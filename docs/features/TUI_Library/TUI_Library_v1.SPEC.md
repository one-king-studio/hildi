# Component Specification: TUI Library v1

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

Define the boundaries, contracts and testable behaviour that turn `src/tui/**`
into an exportable module with in-widget text selection. This is one spec for
the whole component because the pieces are not separable: the isolation gate
defines what may be imported, which in turn decides where selection's mouse
plumbing is allowed to live.

## Requirements

### Functional

- [ ] Tiering: a stated dependency rule per tier, enforced by build gates, not
      by convention.
- [ ] Markdown is a bundled dependency behind a substitutable seam.
- [ ] `TMouseEvent` distinguishes press, motion and release, and carries
      modifiers.
- [ ] `TWidget.HitTest` exists and containers dispatch topmost-first.
- [ ] `TSelection` models a character-granular span across wrapped rows and
      resolves to text without inserting newlines.
- [ ] `TSelectable` gives new widgets selection by inheritance; existing widgets
      adopt it by composition.
- [ ] `TUITestKit` ships the fixtures the suite currently hand-rolls.
- [ ] Two isolation gates join `make check`.

### Non-Functional

- Performance: selection paint is O(visible rows) per frame; no per-frame work
  when nothing is selected.
- Reliability: no leaks; a drag that ends outside the widget or the window still
  terminates.
- Portability: macOS and Linux; no new platform primitive.

## Contracts & Interfaces

### Tiering and the dependency rule

Three tiers. The rule is what the build gates assert.

| Tier | Directory | May use |
| --- | --- | --- |
| Core | `src/tui/core/` | RTL only |
| Terminal | `src/tui/terminal/` | Core + RTL + FPC terminal units |
| Widgets | `src/tui/widgets/` | Core + Terminal + `src/markdown/` |

**Widgets may not use any Hildi application unit.** That single sentence is the
whole export condition. Terminal adapters move out of `core/` because a
non-terminal consumer (a test, a web bridge) should be able to take Core without
compiling termios.

### Mouse input contract

The decoder currently destroys the distinction a drag needs. The replacement
keeps the event record flat and adds one explicit action field rather than
overloading `Button = mbNone`.

```pascal
type
  TMouseButton = (mbNone, mbLeft, mbMiddle, mbRight, mbWheelUp, mbWheelDown);

  { What the terminal reported this event to be. Separate from Button because a
    release carries no button, and a motion-with-button-held must not be
    confused with either a fresh press or a release. }
  TMouseAction = (maPress, maRelease, maMotion);

  TMouseEvent = record
    X, Y: Integer;
    Button: TMouseButton;   // the button involved; mbNone on release and on
                            // a motion with no button held
    Action: TMouseAction;   // what happened
    Mods: TModifiers;       // decoded: shift/alt/ctrl (+ super where sent)
  end;
```

Decoding rules the implementation must satisfy:

- SGR bit 32 set means motion. With no button bits held it is a bare
  `maMotion`; with a button held it is `maMotion` plus that `Button`.
- The trailing `m`/`M` of the SGR sequence means release: `Action = maRelease`,
  `Button = mbNone`. It must not be inferred from the coordinate payload.
- Bits 4/8/16 map to `moShift`/`moAlt`/`moCtrl` on **every** mouse event.
- Existing wheel and click decoding is unchanged in behaviour; only the new
  fields are added, so existing widget arms keep working.

### Hit-testing

```pascal
type
  TWidget = class
  public
    { True when (AX, AY) targets this widget. Default: the point is inside
      FBounds and the widget is Visible. Coordinates are surface-absolute, the
      same space as Bounds. Containers recurse; leaves override only when their
      shape is not their bounds. }
    function HitTest(AX, AY: Integer): Boolean; virtual;
  end;
```

Dispatch rule: a container offering a mouse event to its children walks them in
**reverse** Add order — the last added is the topmost painted, and the topmost
painted must get the click. This is the inverse of the current input order and
the inverse of paint order's intent; a test must pin both the new order and the
existing single-child and modal behaviour.

This also supplies what `TApprovalModal` hand-rolls today (`HitTest` at
`TUIWidgetsApprovalModal.pas:539`) and what `TFocusGroup` duplicates for
click-to-focus.

### Selection model

```pascal
type
  { A position inside a text-drawing widget. Row is a DISPLAY row within the
    widget's own content (0-based), not a document line and not a surface Y.
    Col is a display cell within that row, not a string index. }
  TTextPos = record
    Row: Integer;
    Col: Integer;
  end;

  { Anchor is where the drag began; Caret is the moving end. The pair is stored
    unnormalised so a drag can reverse direction without losing the origin. }
  TSelection = record
    Active: Boolean;
    Anchor: TTextPos;
    Caret: TTextPos;
    { True when the widget's content changed under the selection; the owner
      clears the selection on the next frame rather than trying to re-map it. }
    Stale: Boolean;
  end;

  { The text a widget must be able to answer about itself. Rows are the rows it
    actually drew, in the same units Render used. }
  ISelectableText = interface
    function RowCount: Integer;
    function RowText(ARow: Integer): UnicodeString;
    { Display width of the row, for clamping a column to its end. }
    function RowWidth(ARow: Integer): Integer;
    { True when ARow ended because the text wrapped rather than because a line
      ended. Decides whether a copy joins rows with a newline or not. }
    function RowWraps(ARow: Integer): Boolean;
  end;

{ Normalise an anchor/caret pair into an ordered span. Exposed as a function so
  every consumer agrees on inclusivity: the start is inclusive, the end is
  exclusive, both in cells. }
function SelectionSpan(const ASel: TSelection): TTextSpan;

{ The selected text, joined across rows with a newline only where the source
  breaks a line. A soft-wrapped row contributes a space (or nothing, per the
  widget's join rule) so copying a wrapped paragraph never injects a newline
  that was not in the text. }
```

Ownership rule: `TSelectable = class(TWidget)` holds one `TSelection`, offers
`SelectionText` for the copy path, and a `RenderSelection(S)` helper that paints
using the theme's existing `AccentSoft` role — *"a quieter accent, for large
areas of selection"* (`TUITheme.pas:29`). Widgets that cannot re-parent compose a
`TSelection` field and call the same helper; there is one implementation of the
span logic, two adoption paths.

`ponytail:` selection is per-widget. A drag that leaves one widget cleanly ends
there rather than extending into its neighbour. Upgrade path: a container-level
model keyed by child, when a second widget actually needs it.

### Widget-side additions

**Corrected to what shipped.** The original draft proposed an `ISelectableText`
interface and composition as the primary path. Building it showed the interface
was unnecessary — a subclass can simply answer four virtual methods — and that
selection must be OPT-IN, because `TMarkdownView` constructs one `TTextBlock` per
block *and* per table cell, so re-parenting it unconditionally would make every
cell swallow left-clicks.

```pascal
type
  TSelectable = class(TWidget)
  public
    constructor Create;                       // no theme: selection is behaviour
    procedure Arrange(const ABounds: TRect); override;  // sets the content origin
    { Opt-in, default False. }
    property Selectable: Boolean read FSelectable write FSelectable;
    { Painted over a selected cell. Default reverse video, so a host that sets
      nothing still gets a visible selection. }
    property Highlight: TAttr read FHighlight write FHighlight;
    procedure SetContentOrigin(AX, AY: Integer);
    procedure RenderSelection(const S: ISurface);
    procedure ClearSelection;
    procedure ContentChanged;
    function SelectedText: string;
    function CopySelection(const S: ISurface): Boolean; override;
    property Selection: TSelection read FSelection;
    property Dragging: Boolean read FDragging;
  protected
    function RowCount: Integer; virtual;
    function RowTextAt(ARow: Integer): UnicodeString; virtual;
    function RowWrapsAt(ARow: Integer): Boolean; virtual;
    { The surface X of display column 0 on ARow. A block with a hanging indent
      or a centred alignment does NOT start at its own Bounds.X, so the
      highlight must ask rather than assume. Added after the first draft: without
      it the highlight landed off the text on any indented or centred row. }
    function RowOriginX(ARow: Integer): Integer; virtual;
  end;
```

`RenderSelection` recolours cells that are already drawn — it does not paint
text. That is why `TSelectable` owns no text and cannot disagree with what the
widget rendered: it changes attributes of what is there.

**Adoption in v1:** `TTextBlock`, by re-parenting. Because `TMarkdownView` builds
one per block and per table cell, that single change covers every markdown
paragraph, list item, table cell and plain chat line. The other text drawers
(`TFileviewer`, `TDiffViewer`) are follow-on cards, not v1.

### Copy: on release, not on a key

```pascal
type
  TTuiApp = class
  public
    function CopySelection: Boolean;
    { Copy on mouse release. Default True. }
    property CopyOnRelease: Boolean read FCopyOnRelease write FCopyOnRelease;
  end;

  TWidget = class
    { Walk the tree; the first usable selection wins. Containers recurse in
      reverse Add order, the same rule as mouse dispatch. }
    function CopySelection(const S: ISurface): Boolean; virtual;
  end;

  ISurface = interface
    procedure SetClipboard(const AText: UnicodeString);
  end;
```

**This reverses the original draft**, which assumed an explicit keybinding. A
keybinding has two problems the operator hit in sequence: it has to be
discoverable, and it has to be REACHABLE — twice the tree did not forward events
at all. Copy-on-release removes both: the gesture that makes a selection is the
gesture that delivers it, and a press-release with no drag copies nothing, so it
cannot clear the clipboard by accident.

`ISurface.SetClipboard` is the toolkit's one outbound escape that is not a cell.
`TSurfaceVideo` emits OSC 52 through `WriteOut`; `TSurfaceMemory` records the
text and counts writes, which is all a headless surface can honestly offer.

**Every composite must forward `CopySelection`**, exactly as it forwards
`HandleEvent`. Four did not, and each was a bug found in a terminal rather than
by a test: `TMarkdownView`, `TChatItem`, `TSingleChild`, `TScrollContainer`.
Nothing currently checks this, and a gate for it is the highest-value follow-up.

### Markdown: an optional companion module, not a seam

**This reverses the earlier design in this SPEC.** The original proposed an
`IMarkdownRenderer` returning flat styled lines. That interface cannot work:
`TUIWidgetsMarkdownView` renders GFM tables as a rounded grid at content width,
so it needs `TMdNode`, `TMdDocument`, `TMdTableRow` and `TMdAlignArray` — the
whole v2 node tree. Flattening to lines would mean re-deriving table structure
from painted text, and the interface would be a lie.

The honest shape is smaller:

| Tier | May use |
| --- | --- |
| `src/tui/core`, `src/tui/terminal` | RTL (+ `src/fuzzy` where needed) |
| the 17 library widgets | core + terminal + RTL + `src/fuzzy` |
| `TUIWidgetsMarkdownView`, `TUIWidgetsMdtheme`, `TUIWidgetsFileviewer` | the above **+ `src/markdown`** |

`src/markdown` is already a standalone, RTL-only module with its own isolation
gate (`markdown-standalone`), so depending on it is depending on a *library*,
not on the application. That is the same relationship `src/shell` and `src/fuzzy`
have to their consumers.

**Verified, not assumed:** the library builds and runs with no
`-Fu$(SRC)/markdown` and none of the three markdown units on the path. So
markdown is genuinely optional, and a consumer wanting no markdown takes the
other 17 widgets.

No `IMarkdownRenderer` in v1. An interface earns its place when a second
implementation exists; here it would cost a re-derivation of table layout for
zero callers. If a consumer needs a different renderer, the node tree is the
contract to abstract — which is a bigger decision than a lines interface, and
should be made with that consumer in hand.

### Test kit

```pascal
unit TUITestKit;
{ Fixtures for testing widgets headlessly. Ships with the module: the toolkit's
  testability is part of its value, not an accident of the harness suite. }

type
  { Re-export of the in-memory surface, so consumers do not reach into a
    production unit for it. Behaviour is unchanged and the counters stay. }
  TTestSurface = TSurfaceMemory;

  { Build a widget, measure, arrange, render and hand back the surface. }
  TWidgetFixture = class
    constructor Create(AWidth, AHeight: Integer);
    function Render(AWidget: TWidget): ISurface;
    function RowText(ARow: Integer): UnicodeString;
    function Cells: TSurfaceMemory;
  end;
```

Also: a `MousePress/X,Y`-style event builder so a drag test reads as three
lines, and a `AppFixture` that wires a `TTuiApp` over a `TInputSourceScripted`.

### Gates

Two new make targets, both inside `make check`:

- `tui-standalone` — already exists, already passes; add it to the gate.
- `tui-widgets-standalone` — new, `-Fu$(SRC)/tui/core -Fu$(SRC)/tui/terminal
  -Fu$(SRC)/tui/widgets` and **no** `-Fu$(SRC)`, so any Hildi unit fails the
  link. It must both compile and run assertions, like `tui_standalone.pas` does.

`changes-standalone` is in the same unenforced position; adding it is one line
and worth doing in the same commit.

## Architecture

### Prior Art & Reuse

| Need | Already exists | Gap |
| --- | --- | --- |
| Rendering seam | `ISurface`, `TSurfaceMemory` | Only that it lives in a production unit |
| Mouse byte format | SGR `?1006h` decoding in `TUIInputDecode` | Motion/release/modifiers discarded |
| Span arithmetic | none | `TSelection` |
| Cell-accurate widths | `TUIGrapheme.StringWidth` | Nothing — use it |
| Highlight colour | `TTheme.AccentSoft` | Nothing |
| Copy transport | OSC 52, specced in `TUI_Clipboard` | Selection to feed it |
| Test fixtures | `TSurfaceMemory`, `TInputSourceScripted` | Naming, packaging, a `AppFixture` |
| Clipping/culling | `ISurface.PushClip`, `ClipRect` | Nothing |
| Isolation gate pattern | `shell-standalone`, `markdown-standalone` | A widgets-tier twin |

Nothing here needs a new primitive from the RTL or `deps/`.

### Component Boundaries

- **Core owns:** value types, geometry, surfaces, the widget protocol, the app
  loop, the clock, the frame encoder, selection *arithmetic*.
- **Terminal owns:** byte decoding adapters, the fd reader, the video surface.
- **Widgets own:** composition, painting, focus, and selection *presentation*.
- **The host owns:** which renderer is injected, the copy transport, and any
  policy about what may be selected.

### Data Flow

1. Terminal bytes → `TInputDecode` → `TInputEvent` with `Action` and `Mods`.
2. `TTuiApp.DispatchEvent` → topmost plane → container, reverse Add order,
   `HitTest` first.
3. The widget with the hit starts a drag: on press, `TSelection.Anchor := pos`;
   on motion, `TSelection.Caret := pos`; on release, the selection is final.
4. The next `Render` paints the highlight for visible rows only.
5. Copy asks `SelectionText`, which reads the same wrapped rows the last Render
   used — never a fresh re-wrap, or the copy drifts from what was highlighted.

### Integration Patterns

Synchronous and single-threaded, as today. `TSelection` is a value type, so it
is copied with the widget and cannot alias. No new thread, no callback across a
thread boundary.

## Validation Rules

### Input

- A mouse coordinate outside every plane is dropped, not clamped.
- A press on a widget with no `SelectableText` starts no selection.
- Shift-modified mouse events are passed through untouched — this is what keeps
  terminal-native selection working, and it is a hard rule, not a preference.
- `Row`/`Col` are clamped to the widget's own content on motion past an edge, so
  dragging outside does not produce negative or out-of-range spans.

### Output Guarantees

- `SelectionText` returns exactly the characters highlighted; no leading or
  trailing whitespace is invented or trimmed.
- A soft-wrapped row contributes no newline.
- A wide cluster is never split; a column landing mid-cluster snaps to its start.

## Error Handling

- No exception is raised by selection. A stale or empty selection copies as an
  empty string and is a visible no-op.
- A widget freed mid-drag is not referenced: the app clears the drag on plane
  change.

## Testing Requirements

### Unit Tests

- [ ] `TestTUIInputDecode`: motion with a button held reports `maMotion` and the
      button; release reports `maRelease` with `mbNone`; shift/alt/ctrl land in
      `Mods`; wheel and click behaviour unchanged.
- [ ] `TestTUIWidgets`: `HitTest` defaults to bounds; a container gives a click
      to the last-added overlapping child; a point outside every child matches
      none.
- [ ] `TestTUISelection`: normalisation when the caret precedes the anchor; a
      single-cell selection; clamping past the end of a row; wide-character and
      combining-mark fixtures never split.
- [ ] `TestTUISelection`: a soft-wrapped paragraph copies with no newline; a hard
      line break copies with one.
- [ ] `TestTUISelection`: content change under a selection marks it stale and the
      owner clears it.
- [ ] `TestTUITestKit`: the kit renders a known widget and asserts a known cell,
      proving the kit is usable rather than merely present.
- [ ] Resource cleanup: no leaks under `make test-leak`.

### Integration Tests

- [ ] Press, drag, release over the adopted text widget yields exactly the
      expected string, driven through `TTuiApp` and `TInputSourceScripted`.
- [ ] Shift+click opens no selection and is passed to the host hook.
- [ ] The existing modal input tests still pass with topmost-first dispatch.
- [ ] `tui-widgets-standalone` compiles with no Hildi unit on the path and its
      assertions pass.

## Performance Targets

- No measurable change to `TestTUIPerf`'s frame budget at 700 chat blocks.
- Selection paint touches only visible rows: `PutCount` on a memory surface with
  a selection over a 10,000-row document is proportional to viewport height.
- `make check` grows by under 5 s for both gates.

## Security Considerations

- Clipboard content is user-visible text and must never be logged; OSC 52
  writes carry it, traces do not.
- Selection adds no new input path that could inject bytes: it consumes decoded
  events only, and a terminal cannot force-selection by echo.

## Success Criteria

### Functional

- [ ] Both isolation gates in `make check`, green.
- [ ] Motion/release/modifiers decoded and tested.
- [ ] `HitTest` in the protocol; topmost-first dispatch pinned by a test.
- [ ] Character-granular selection works end to end on one text widget.
- [ ] `TUITestKit` shipped with three test files migrated to it.

### Quality

- [ ] No Hildi unit reachable from `src/tui/**`.
- [ ] No leaks; `make check` green.
- [ ] A demo driven by hand in a terminal, with what was seen recorded on the
      board — this area has twice shipped defects a green suite could not see.

## Staging

Ordered for independent value and independent revert. Each stage ends green.

1. **Gates.** Add `tui-standalone` and `changes-standalone` to `make check`.
   No code change.
2. **Mouse contract.** `TMouseAction` and `Mods` in the decoder, with fixtures.
3. **Hit-testing.** `TWidget.HitTest`, reverse-order container dispatch, and
   `TApprovalModal` deduped onto it — which closes card #36.
4. **Terminal tier.** Move the three terminal-bound units into
   `src/tui/terminal/`, update the Makefile and gates.
5. **Widgets gate.** Add the failing `tui-widgets-standalone`, then de-couple the
   four app-coupled widgets (records and `of object` callbacks) until it passes.
6. **Markdown boundary.** Document `src/markdown` as an optional companion
   module and assert the three markdown widgets are the only units that need it.
7. **Selection.** `TSelection`, `TSelectable`, highlight paint, one widget
   adopted, copy path wired to the existing OSC 52 transport.
8. **Test kit.** `TUITestKit`, three migrations, docs.
9. **Demo and index.** A runnable example a stranger can start from, plus the
   `FEATURES.md` entry and the `TUI_Clipboard` non-goal amendment.

## Future Considerations

- Keyboard selection and word/line granularity.
- Cross-widget selection via a container model.
- `src/markdown` growing a renderer abstraction if a second consumer appears.
- A distributable package once a second consumer exists.
