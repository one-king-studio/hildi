# Implementation Plan: TUI Animation v1

**Related Specification:** `TUI_Animation_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `TUI_Animation_v1.SPEC.md`. Work on `main`; each task starts
with a failing test; `make check` before moving on.

## Implementation Tasks

### Phase 1: Clock and the widget hook

- [x] Add `test_tui_animation` to `tests/hildegard_helper_tests.pas`
- [x] **Test**: `MonotonicMs` is non-decreasing
- [x] **Implement**: `hildegard.helper.tui.clock` (`MonotonicMs`, `DefaultTickMs`)
- [x] **Test**: `TContainer.Advance` reaches children; `Animating` is the OR
- [x] **Implement**: `TWidget.Advance`/`Animating`; forward in `TContainer` and
      `TSingleChild`

### Phase 2: App frame loop

- [x] **Test**: `Tick` advances the tree and renders once; unchanged frame emits
      zero changed cells; changed frame emits only those
- [x] **Implement**: `TTuiApp.Tick(ANowMs)`, `NowMs`, `TickMs`
- [x] **Test**: `NextFrameDelayMs` is `-1` when idle, else within `[0, TickMs]`
- [x] **Implement**: `NextFrameDelayMs`, `Animating` (OR over all planes)
- [x] **Implement**: `Run` waits on input to the next frame (or the idle timeout)
- [x] **Refactor**: `Step`/`Tick` share `DispatchEvent`/`Present`; `Step` stays
      the event-only iteration

### Phase 3: Spinner

- [x] **Test**: frame advances with `now`; two same-origin spinners in phase;
      `Animating`; measure = widest frame
- [x] **Implement**: `hildegard.helper.tui.spinner` (`TSpinner`, presets)

### Phase 4: Progress

- [x] **Test**: determinate eighths at 0/50/100%; clamp; indeterminate bounce;
      `Animating` follows `Indeterminate`
- [x] **Implement**: `hildegard.helper.tui.progress` (`TProgress`)

### Phase 5: Demo & docs

- [x] **Demo**: add a spinner + indeterminate bar to
      `examples/tui_widgets_demo.pas`, run it with `App.Run(Demo.ShouldStop)`
- [x] **Fix**: rebase the ad-hoc demo/harness shells on `TSingleChild` so
      `Advance`/`Animating` reach the tree (they were swallowing it)
- [x] **Docs**: design-language "frame clock & timelines" section; update
      `FEATURES.md`, `HANDOFF.md`
- [x] **Validation**: `make check` green (370 tests, leak-clean); pty smoke of the
      demo (spinner + bar render, `q` exits 0)

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
src/hildegard.helper.tui.panel.pas    (TSingleChild forwards the hooks)
src/hildegard.helper.tui.app.pas      (Tick/NextFrameDelayMs/Run)
src/hildegard.helper.harness.app.pas  (TAppShell rebased on TSingleChild)
tests/hildegard_helper_tests.pas      (add the test unit)
examples/tui_widgets_demo.pas         (spinner + progress, App.Run)
docs/design/TUI_Design_Language.md
docs/features/FEATURES.md
HANDOFF.md
```

## Success Criteria

- [x] All tasks checked
- [x] Every FEATURE acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] The demo animates from the clock with no per-widget timers

## Notes & Considerations

- **`{$codepage utf8}`** is needed in units with non-ASCII literals (braille,
  eighth blocks); without it the glyphs compile to `?`.
- **`Run`'s idle wait is finite** (1000 ms), because `IInputSource.Wait` has no
  blocking form. It is a signal-check cadence, not a refresh rate.
- **Wrapper widgets must forward the hooks** - prefer extending `TSingleChild`
  over hand-wrapping `TWidget`.
- `Tick` stays deterministic; no widget reads the wall clock.
