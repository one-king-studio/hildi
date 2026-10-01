# Implementation Plan: TUI Animation v1

**Related Specification:** `TUI_Animation_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `TUI_Animation_v1.SPEC.md`. Work on `main`; each task starts
with a failing test; `make check` before moving on.

## Implementation Tasks

### Phase 1: Clock and the widget hook

- [ ] Add `test_tui_animation` to `tests/hildegard_helper_tests.pas`
- [ ] **Test**: `MonotonicMs` is non-decreasing
- [ ] **Implement**: `hildegard.helper.tui.clock` (`MonotonicMs`, `DefaultTickMs`)
- [ ] **Test**: `TContainer.Advance` reaches children; `Animating` is the OR
- [ ] **Implement**: `TWidget.Advance`/`Animating`; forward in `TContainer`

### Phase 2: App frame loop

- [ ] **Test**: `Tick` advances the tree and renders once; unchanged frame emits
      zero changed cells; changed frame emits only those
- [ ] **Implement**: `TTuiApp.Tick(ANowMs)`, `NowMs`, `TickMs`
- [ ] **Test**: `NextFrameDelayMs` is `-1` when idle, else within `[0, TickMs]`
- [ ] **Implement**: `NextFrameDelayMs`, `Animating`
- [ ] **Implement**: `Run` waits on input to the next frame (or forever when idle)

### Phase 3: Spinner

- [ ] **Test**: frame advances with `now`; two same-origin spinners in phase;
      `Animating`; measure = widest frame
- [ ] **Implement**: `hildegard.helper.tui.spinner` (`TSpinner`, presets)

### Phase 4: Progress

- [ ] **Test**: determinate eighths at 0/50/100%; clamp; indeterminate bounce;
      `Animating` follows `Indeterminate`
- [ ] **Implement**: `hildegard.helper.tui.progress` (`TProgress`)

### Phase 5: Demo & docs

- [ ] **Demo**: add a spinner + progress to `examples/tui_widgets_demo.pas`
      (and/or `tui_agent` status) driven by the clock
- [ ] **Docs**: design-language "frame clock & timelines" section; update
      `FEATURES.md`, `HANDOFF.md`
- [ ] **Validation**: `make check`; confirm idle makes no periodic wakeups

## Files to Create/Modify

### New Files

```
src/hildegard.helper.tui.clock.pas
src/hildegard.helper.tui.spinner.pas
src/hildegard.helper.tui.progress.pas
tests/test_tui_animation.pas
```

### Modified Files

```
src/hildegard.helper.tui.widget.pas   (Advance/Animating)
src/hildegard.helper.tui.app.pas      (Tick/NextFrameDelayMs/Run)
tests/hildegard_helper_tests.pas      (add the test unit)
examples/tui_widgets_demo.pas         (spinner + progress)
docs/design/TUI_Design_Language.md
docs/features/FEATURES.md
HANDOFF.md
```

## Success Criteria

- [ ] All tasks checked
- [ ] Every FEATURE acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] The demo animates from the clock with no per-widget timers

## Notes & Considerations

- Record deviations from the specification here.
- Keep `Tick` deterministic; never read the wall clock inside a widget.
