# Component Specification: Approval Modal v1

**Related Feature:** `../FEATURE.md` (TUI Harness)

## Purpose

Redraw the approval dialog to the design in `docs/design/chat_panel_tui.md`
(its "Modals" section), and make the modal actually read as modal: when it is
shown the whole base screen - background included - is dimmed behind it.

## Requirements

### Functional

- [ ] `DimRect` darkens the **screen background** as well as the text, so a
      modal dims the whole screen and not just the glyphs. Cells that carry
      `sfScreenBg` swap it for an explicit dimmed background index.
- [ ] The dialog is a rounded box titled `Approval needed`, with a heavy bottom
      edge (like the user bubble).
- [ ] The tool details sit in a full-width band on the sunken (darker)
      background.
- [ ] Each option is left-aligned, prefixed by `→` when selected and `◦`
      otherwise, with its numeric keybinding right-aligned.
- [ ] The selected option's text is bright; unselected options are normal.
- [ ] Bullets, the `scope` label, and every keybinding are dimmed.
- [ ] A `scope: <value>` line shows the active scope as a bright value, with
      `tab / g w s` right-aligned and dimmed.
- [ ] A separator rule divides the body from a footer holding
      `enter accept   esc deny`, with the keys dimmed and the actions normal.
- [ ] Three text roles only: normal (labels/values), dimmed (keys/labels), soft
      accent (active values), taken from the theme.
- [ ] The dialog is at least 55 columns wide, so a short ask still reads as a
      dialog.
- [ ] Right-aligned keys keep two columns clear of the right border.
- [ ] The selected option and the active scope value use the theme's
      `AccentSoft`, not the bright `Accent`.
- [ ] A digit selects an option; it does not accept. Only Enter/Escape - or a
      click on the footer's accept/deny - leave the dialog.
- [ ] Mouse: moving over an option brightens its text, clicking one selects it,
      and clicking the footer's accept or deny acts.

### Non-Functional

- [ ] Leak-clean; the dialog is a single widget with no new dependency.
- [ ] `make check` passes.

## Contracts & Interfaces

```pascal
type
  TApprovalModal = class(TWidget)
  public
    constructor Create(const AAsk: TApprovalAsk; const ATheme: TTheme);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property Ask: TApprovalAsk read FAsk;
    property Answered: Boolean read FAnswered;
    property Choice: TApprovalChoice read FChoice;
    property OnChoose: TApprovalChoiceEvent read FOnChoose write FOnChoose;
  end;
```

### Dimming (`hildegard.helper.tui.base` / the surfaces)

```pascal
{ Map a 256-colour palette index to a darker one. }
function DimPaletteIndex(AIndex: Byte): Byte;
```

`TTheme` gains `AccentSoft: TAttr`, a quieter accent for large areas of
selection (the selected option, the active scope value).

`ISurface.DimRect(R)` then, for every cell in R:

- if the cell has `sfScreenBg`, clear it and set `Bg := DimPaletteIndex(the
  surface's screen-bg index)`;
- darken `Fg` with `DimPaletteIndex`;
- include `sfDim`.

### Layout

```
╭─ Approval needed ───────────────────────────────╮
│ <details, sunken background>                    │
│                                                 │
│ → allow once                                  1 │
│ ◦ always this exact command                   2 │
│ ◦ always command with any arguments           3 │
│                                                 │
│ scope: workspace                    tab / g w s │
├─────────────────────────────────────────────────┤
│                        enter accept  esc deny   │
╰═════════════════════════════════════════════════╯
```

## Architecture

### Prior Art & Reuse

- `TTheme` already has `Text`, `Muted`, `Accent`, `SunkenBg`, `Border`; no new
  roles.
- `DimPaletteIndex` moves out of the video surface into `tui.base` so both
  surfaces share it.
- The dialog keeps `TApprovalModal`'s event handling (arrows, digits, Tab,
  g/w/s, Enter, Esc) unchanged; only `Measure`/`Render` change.

### Component Boundaries

- **Surfaces** own the dim (palette + flag).
- **`TApprovalModal`** owns the dialog's look and keys.
- **`THarnessApp`** owns the plane (modal + dim) and the choice plumbing.

## Validation Rules

- The selected index stays within the options.
- A zero-option ask still renders (the details + footer) and Enter denies.

## Error Handling

- None new; the dialog cannot fail.

## Testing Requirements

### Unit Tests

- [ ] `TestDimRectDimsTheScreenBackground` - a `sfScreenBg` cell loses the flag
      and gains a darker `Bg`.
- [ ] `TestModalTitlesAndBorders` - the title, rounded corners, heavy bottom.
- [ ] `TestModalDefaultWidthIsWide` - a short ask measures 55 columns.
- [ ] `TestModalMarksTheSelectedChoice` - `→` on the selected, `◦` on others,
      and the soft accent on the selected caption.
- [ ] `TestModalKeybindingsAreRightAlignedAndDim` - the numeric and scope keys
      sit clear of the border in the muted attribute.
- [ ] `TestModalShowsTheScopeAndFooter` - `scope: workspace` and
      `enter accept   esc deny`.
- [ ] `TestModalDetailsUseTheSunkenBackground`.
- [ ] `TestModalActionsKeepClearOfTheBorder` - two columns of right padding.
- [ ] `TestNumberSelectsWithoutAccepting` - a digit moves the selection and
      Enter then accepts.
- [ ] `TestModalMouseHoverBrightens` - motion over an option switches its
      caption to the soft accent.
- [ ] `TestModalClickSelectsWithoutAccepting` - a click selects only.
- [ ] `TestModalFooterClickAcceptsAndDenies` - the footer's accept/deny act.

### Integration Tests

- [ ] `TestApprovalDimsTheBackground` (already added) still passes.

## Performance Targets

- One measure/render per frame; no per-frame allocation beyond the spans.

## Security Considerations

- The details band renders untrusted command text; it goes through the surface,
  which sanitizes control characters.

## Success Criteria

### Functional

- [ ] The dialog matches the design's structure and three text roles.
- [ ] A shown modal dims the whole screen, background included.

### Quality

- [ ] `make check` green; no leaks.

## Future Considerations

- Markdown rendering of the details; per-tool detail widgets.
