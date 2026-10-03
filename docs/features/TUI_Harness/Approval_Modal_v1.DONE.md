# Implementation Plan: Approval Modal v1

**Related Specification:** `Approval_Modal_v1.SPEC.md`

## Implementation Tasks

### Phase 1: Dim the whole screen

- [x] **Implement**: `DimPaletteIndex` in `hildegard.helper.tui.base` (moved out
      of the video surface); both surfaces' `DimRect` now give a `sfScreenBg`
      cell an explicit dimmed background, darken `Fg`, and set `sfDim`.
- [x] **Test**: `TestDimDarkensColorsAndAddsFaint` (renamed from
      `TestDimAddsFaintButKeepsGlyphsAndColors`) also asserts the screen-bg flag
      is cleared.
- [x] **Test**: `TestApprovalDimsTheBackground` (harness app).

### Phase 2: Redraw the dialog

- [x] **Implement**: `TApprovalModal` takes the theme, draws the titled rounded
      box with a heavy bottom, the sunken details band, the option list with
      `→`/`◦` bullets and right-aligned dimmed numeric keys, the scope line, the
      separator, and the footer.
- [x] **Test**: `TestModalTitlesAndBorders`, `TestModalMarksTheSelectedChoice`,
      `TestModalKeybindingsAreRightAlignedAndDim`,
      `TestModalShowsTheScopeAndFooter`, `TestModalDetailsUseTheSunkenBackground`
      in `tests/test_tui_approvalmodal.pas`.
- [x] **Implement**: `THarnessApp.ShowApproval` passes the theme.

### Phase 3: Validation

- [x] **Run**: `make check` (556 tests, leak gate).
- [x] **Update**: `docs/features/FEATURES.md`; this plan is now
      `Approval_Modal_v1.DONE.md`.

## Files Created/Modified

```
src/hildegard.helper.tui.base.pas          DimPaletteIndex
src/hildegard.helper.tui.surface.pas       DimRect dims the screen background
src/hildegard.helper.tui.surface.video.pas same, with FScreenBg stored
src/hildegard.helper.tui.approvalmodal.pas redrawn to the design
src/hildegard.helper.harness.app.pas       pass the theme
tests/test_tui_surface.pas                 the dim test
tests/test_tui_approvalmodal.pas           the dialog tests
tests/test_harness_app.pas                 the dim integration test
```

## Success Criteria

- [x] All tasks above checked
- [x] `make check` passes (tests + leak gate)
- [x] A shown modal dims the whole screen; the dialog matches the design

## Notes & Considerations

Deviations from the specification, and why:

- **`TApprovalModal` takes the whole theme**, not a single text attribute, so it
  can use the three roles (`Text`, `Muted`, `Accent`) and `SunkenBg`. The old
  `Attr` property is gone.
- **The memory surface's `DimRect` now darkens colours too**, mirroring the video
  surface instead of only setting `sfDim`; the surface test was renamed and
  updated to match. This is what makes the dim observable in tests at all.
- **The dialog's height is `options + 8`**: details at row 1, options from row 3,
  the scope at `4+N`, the separator at `5+N`, the footer at `6+N`, and the heavy
  bottom at `7+N`. The first cut was one row short and clipped the footer.
- **The option bullets and the scope label are dimmed**, matching note 6 of the
  design ("dimmer than the choices"); the selected option's caption is bright
  (`Accent`) rather than reversed.
- **The screen background dims by swapping `sfScreenBg` for an explicit dimmed
  index.** Without that, only the text dimmed and a modal read as if it were
  behind the panel.

### Follow-on

The operator asked for a wider default, padding, a softer selection colour,
mouse support, and for picking to be separate from accepting:

- **`MinWidth = 55`** so a short ask still reads as a dialog, and
  **`RightPad = 2`** keeps every right-aligned key clear of the border.
- **`TTheme.AccentSoft`** was added (dark `74`, light `31`) and is used for the
  selected option, the hovered option, and the active scope value; the bright
  `Accent` was overwhelming.
- **Digits now select** (`FSelected := N-1`) instead of accepting, matching
  "the accept or deny actions must be the only exit".
- **Mouse support**: motion over an option (or a footer action) sets `FHover`
  and brightens it; a click on an option selects it; a click on the footer's
  accept or deny acts. Hover and click both use `HitTest`, which shares the
  geometry helpers with `Render` so the hit regions cannot drift.
