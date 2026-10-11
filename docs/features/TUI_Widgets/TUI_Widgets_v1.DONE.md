# Implementation Plan: TUI Widgets v1

**Related Specification:** `TUI_Widgets_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `TUI_Widgets_v1.SPEC.md`. Work on `main`; each task starts
with a failing test; `make check` before moving on.

## Implementation Tasks

### Phase 1: Theme

- [x] Add `test_tui_theme` (name-free) `test_tui_widgets` units to the runner as
      created
- [x] **Test**: `DarkTheme`/`LightTheme` set every role
- [x] **Implement**: `hildegard.helper.tui.theme`

### Phase 2: Single child and panel

- [x] **Test**: `TSingleChild` forwards measure/arrange/render/event
- [x] **Implement**: `TSingleChild` in `hildegard.helper.tui.panel`
- [x] **Test**: `TPanel` border/title/padding; measure; border-off pads
- [x] **Implement**: `TPanel`

### Phase 3: Focus

- [x] **Test**: `Tab`/`Shift-Tab` cycle with wrap; click focuses; keys to focused
- [x] **Implement**: `TFocusable`, `TFocusGroup` in `hildegard.helper.tui.focus`

### Phase 4: Controls

- [x] **Test**: `TButton` fires `OnClick` on Enter/Space/click; renders caption
- [x] **Implement**: `hildegard.helper.tui.button`
- [x] **Test**: `TList` selection/clamp/activate; accent row
- [x] **Implement**: `hildegard.helper.tui.list`

### Phase 5: Integration & docs

- [x] **Test**: a focus group with a button and a list; `Tab` between them
- [x] Adopt the kit in a runnable example: `examples/tui_widgets_demo.pas`
      (`make widgets-demo`) — list, panel, buttons, focus; the existing
      `tui_demo` keeps its local panel (refactor left as an option)
- [x] Update `FEATURES.md`, `HANDOFF.md`; `make check`

## Files to Create/Modify

### New Files

```
src/hildegard.helper.tui.theme.pas
src/hildegard.helper.tui.panel.pas
src/hildegard.helper.tui.focus.pas
src/hildegard.helper.tui.button.pas
src/hildegard.helper.tui.list.pas
tests/test_tui_widgets.pas
examples/tui_widgets_demo.pas
```

### Modified Files

```
tests/hildegard_helper_tests.pas   (add the test unit)
examples/tui_widgets_demo.pas      (the kit demo; new)
Makefile                           (widgets-demo target)
docs/features/FEATURES.md
HANDOFF.md
```

## Success Criteria

- [x] All tasks checked
- [x] Every FEATURE acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] The demo uses the kit instead of a local panel

> **Complete.** All implementation tasks and success criteria are met; the code,
> tests (`TThemeTest`/`TPanelTest`/`TButtonTest`/`TListTest`/`TFocusGroupTest`/
> `TSingleChildTest`, all green) and the `tui_widgets_demo` (built by
> `make widgets-demo`) are in place. Tick-boxes above were completed
> retroactively.

## Notes & Considerations

- Record deviations from the specification here.
