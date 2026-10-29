# Component Specification: TUI Widgets v1

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

A thin, reusable layer over TUI Core: a single-child base, a themed panel, a
focus model, and the first controls (button, list). Everything is a `TWidget`
and composes with the existing grid, scroll, and modal machinery.

## Requirements

### Functional

- [ ] `TSingleChild` forwards the widget protocol to one owned child.
- [ ] `TPanel` draws background, optional border/title, and padding.
- [ ] `TTheme` maps roles to `TAttr`; `DarkTheme`/`LightTheme`.
- [ ] `TFocusGroup` moves focus with `Tab`/`Shift-Tab` and on click, and routes
      keys to the focused control.
- [ ] `TButton` fires `OnClick` on `Enter`/`Space`/click.
- [ ] `TListView` selects with `Up`/`Down`/`Home`/`End` and activates with `Enter`.

### Non-Functional

- Performance: rendering is O(cells drawn); no allocation per frame beyond text.
- Reliability: no leaks; `make check` green.
- Portability: no terminal dependency in these units.

## Contracts & Interfaces

### Theme — `hildi.tui.theme`

```pascal
type
  TTheme = record
    Base, Panel, Border, Title: TAttr;
    Text, Muted, Accent, Error, Success: TAttr;
  end;

function DarkTheme: TTheme;
function LightTheme: TTheme;
```

### Single child and panel — `hildi.tui.panel`

```pascal
type
  { Owns one child and forwards Measure/Arrange/Render/HandleEvent to it.
    Subclasses override only what they add. }
  TSingleChild = class(TWidget)
  protected
    FChild: TWidget;
    function Child: TWidget;
  public
    constructor Create(AChild: TWidget);
    destructor Destroy; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  TBoxStyle = record
    Border: Boolean;     // draw a box-drawing border
    Title: string;       // shown in the top border when Border is on
    Padding: Integer;    // inset between the frame and the child
  end;

  function DefaultBoxStyle: TBoxStyle;

  TPanel = class(TSingleChild)
  public
    constructor Create(AChild: TWidget; const ATheme: TTheme;
      const AStyle: TBoxStyle);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect): override;
    procedure Render(const S: ISurface); override;
    property Theme: TTheme read FTheme write FTheme;
    property Style: TBoxStyle read FStyle write FStyle;
  end;
```

`DefaultBoxStyle` = `(Border: True; Title: ''; Padding: 1)`.

### Focus — `hildi.tui.focus`

```pascal
type
  TFocusable = class(TWidget)
  public
    property Focused: Boolean read FFocused write SetFocused;
    procedure FocusChanged; virtual;   // hook; subclasses may repaint
  end;

  TFocusableArray = array of TFocusable;

  { A container that manages focus among its focusable children. }
  TFocusGroup = class(TContainer)
  public
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Focusables: TFocusableArray;   // child order
    function Focused: TFocusable;
    procedure FocusNext;                    // Tab
    procedure FocusPrev;                    // Shift-Tab
    function FocusAt(X, Y: Integer): Boolean;  // left-click focus
  end;
```

Routing rules:
- `Tab` / `Shift-Tab` move focus among focusables (wrapping); return `True`.
- A left-button mouse event inside a focusable focuses it, then the event is
  forwarded.
- Other events go to the focused focusable first; if it returns `False`, the
  event is offered to the remaining children in order (base `TContainer`
  behaviour).
- With no focusable focused, the first focusable takes focus when a key arrives.

### Button — `hildi.tui.button`

```pascal
type
  TButton = class(TFocusable)
  public
    constructor Create(const ACaption: string; const ATheme: TTheme);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property Caption: string read FCaption write FCaption;
    property Theme: TTheme read FTheme write FTheme;
    property OnClick: TNotifyEvent read FOnClick write FOnClick;
  end;
```

Renders `[ caption ]`; when focused, the caption uses the theme's focus accent
(reverse). `Enter` or `Space` while focused, or a left click, fires `OnClick`.

### List — `hildi.tui.list`

```pascal
type
  TListView = class(TFocusable)
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    procedure AddItem(const AText: string);
    procedure Clear;
    property Count: Integer;
    function ItemAt(AIndex: Integer): string;
    property Selected: Integer read FSelected write SetSelected;  // -1 = none
    property Theme: TTheme read FTheme write FTheme;
    property OnActivate: TNotifyEvent read FOnActivate write FOnActivate;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;
```

`Up`/`Down`/`Home`/`End` move `Selected`; `Enter` fires `OnActivate`. The
selected row is drawn with the theme's accent; a focused list is visually
distinct. Long lists are placed in a `TScrollContainer`.

## Architecture

### Prior Art & Reuse

- TUI Core: `TWidget` (the four-method protocol), `TContainer`/tracks,
  `TTextBlock`, `TScrollContainer`, `ISurface`, `TInputEvent`.
- The demo's local `TPanel` is the model for `TSingleChild`/`TPanel`.
- `eastasianwidth` (via `TTextBlock`) for width; the encoder sanitizes output.

Gap designed here: the single-child base, panel drawing, focus routing, theme,
and the two controls.

### Component Boundaries

- Pure UI; no agent, store, or terminal dependency.
- `TFocusGroup` is a `TContainer`; `TButton`/`TListView` are `TFocusable`.

### Data Flow

1. `TFocusGroup.HandleEvent` resolves focus and dispatches.
2. A control changes its state and, for activation, fires its callback.
3. `Render` draws into the surface; layout is the container's job.

## Validation Rules

- `Padding >= 0`; a border needs at least 2 columns/rows to draw.
- `TListView.Selected` is `-1` or within `[0, Count-1]`; `Up`/`Down` clamp.
- A panel with `Border` off still applies padding.
- `TButton.OnClick`/`TListView.OnActivate` fire only when focused (or clicked).

## Error Handling

- No exceptions to callers; missing theme uses `DarkTheme`.
- Rendering clips to bounds (Core behaviour); a too-small panel draws what fits.

## Testing Requirements

### Unit Tests

- [ ] `TSingleChild` forwards measure/arrange/render/event to its child.
- [ ] `TPanel` draws a border/title, insets the child by padding, and measures
      the inflated size; border-off still pads.
- [ ] `TTheme`: `DarkTheme`/`LightTheme` set every role; `TPanel`/controls use
      the passed theme's attributes.
- [ ] `TFocusGroup`: `Tab`/`Shift-Tab` cycle with wrap; click focuses; keys go to
      the focused child.
- [ ] `TButton`: `Enter`/`Space`/click fire `OnClick`; only when focused; renders
      `[ caption ]`.
- [ ] `TListView`: `Up`/`Down`/`Home`/`End` move and clamp `Selected`; `Enter` fires
      `OnActivate`; selected row uses the accent.

### Integration Tests

- [ ] A focus group with a button and a list: `Tab` moves between them and the
      focused control receives keys.

### Leak Tests

- [ ] Composites free their children; `make test-leak` clean.

## Security Considerations

- Content drawn by these widgets (captions, list items) is cell text; the encoder
  sanitizes control characters, so no new injection surface.

## Success Criteria

### Functional

- [ ] All contracts implemented; every acceptance criterion maps to a test.
- [ ] `make check` passes.

### Quality

- [ ] A composite is a local change over `TSingleChild`.
- [ ] No terminal dependency; no leaks.

## Future Considerations

- Menus, tabs, tables; scrollable focus; theme files; hover.
