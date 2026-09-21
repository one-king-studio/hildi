# Implementation Plan: TUI Core v1

**Related Specification:** `TUI_Core_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `hildegard.helper.tui.*`. Work directly on `main` (project
convention: no branches). Each implementation task starts with a failing test.
Order is deliberate: the memory surface and injected input come first so every
later phase is testable without a terminal; the terminal adapters are written
against the same interfaces and can be deferred until the example needs them.

## Implementation Tasks

### Phase 1: Base Types & Test Scaffolding

- [ ] **Test unit(s)**: create `tests/test_tui_surface.pas` with an empty
      `TTuiSurfaceTest`; add to `tests/hildegard_helper_tests.pas` `uses`
- [ ] **Types**: define `TSize`, `TRect`, `TStyle`, `TAttr`, `TCell`,
      `DefaultAttr` in `src/hildegard.helper.tui.base.pas`
- [ ] **Compile check**: an empty test referencing `TAttr` compiles (pins the
      shadowed `TRect` decision)

### Phase 2: Memory Surface

- [ ] **Test** `TestSurfaceClearFillsAllCells`
- [ ] **Test** `TestPutOutsideClipIsIgnored`
- [ ] **Test** `TestPushClipIntersects`
- [ ] **Test** `TestFillRect`
- [ ] **Test** `Test256ColorIndexRetainedInCell`
- [ ] **Test** `TestFlushIdempotent`
- [ ] **Test** `TestDimAddsFaintButKeepsGlyphsAndColors`
- [ ] **Implement** `ISurface` and `TSurfaceMemory` in
      `src/hildegard.helper.tui.surface.pas` (terminal class can be a stub here)

### Phase 3: Input

- [ ] **Test unit** `tests/test_tui_input.pas` + `TTuiInputTest`
- [ ] **Implement** the event types and `IInputSource` /
      `TInputSourceScripted` in `src/hildegard.helper.tui.input.pas`
- [ ] **Test** `TestScriptedSourceYieldsQueuedEvents`
- [ ] **Test** `TestScriptedSourceReportsResize`

### Phase 4: Widget Protocol & Layout

- [ ] **Test unit** `tests/test_tui_layout.pas` + `TTuiLayoutTest`
- [ ] **Implement** `TWidget`, `TTrack`/`Fixed`/`Auto`/`Fill`, `TContainer` in
      `src/hildegard.helper.tui.widget.pas`
- [ ] **Test** `TestFixedTracksTakeExactSize` - red/green
- [ ] **Test** `TestFillTracksShareRemainderByWeight`
- [ ] **Test** `TestAutoTrackMeasuresContent`
- [ ] **Test** `TestGapsReduceAvailableSpace`
- [ ] **Test** `TestNestedContainerIsLaidOut`
- [ ] **Test** `TestVerticalStackIsOneColumnGrid`
- [ ] **Test** `TestEmptyAndZeroSizedTracks`
- [ ] **Test** `TestOverflowingContentIsClipped`

### Phase 5: Text Block

- [ ] **Test unit** `tests/test_tui_text.pas` + `TTuiTextTest`
- [ ] **Implement** `TSpan`, `TTextBlock`, wrapping/measuring in
      `src/hildegard.helper.tui.text.pas`
- [ ] **Test** `TestMeasureLongestLine`
- [ ] **Test** `TestCharacterWrap`
- [ ] **Test** `TestWordWrap`
- [ ] **Test** `TestWideCharacterOccupiesTwoColumns`
- [ ] **Test** `TestCombiningMarkIsOneCluster`
- [ ] **Test** `TestStyledSpansRetainAttributes`
- [ ] **Test** `TestTextClippedToBounds`

### Phase 6: Scroll Containers & Scrollbars

- [ ] **Test unit** `tests/test_tui_scroll.pas` + `TTuiScrollTest`
- [ ] **Implement** `TScrollContainer` (clipping, offsets, keyboard) and
      `TScrollBar` geometry in `src/hildegard.helper.tui.scroll.pas`
- [ ] **Test** `TestContentSmallerThanViewportDoesNotScroll`
- [ ] **Test** `TestContentEqualViewportDoesNotScroll`
- [ ] **Test** `TestContentLargerThanViewportScrolls`
- [ ] **Test** `TestScrollClampedAtBothEnds`
- [ ] **Test** `TestKeyboardScrollKeysMoveViewport`
- [ ] **Test** `TestTwoContainersScrollIndependently`
- [ ] **Test** `TestScrollbarThumbGeometry`

### Phase 7: Planes, Modal & Application Loop

- [ ] **Test unit** `tests/test_tui_app.pas` + `TTuiAppTest`
- [ ] **Implement** `TPlane` and `TTuiApp` (`Step`, routing, layout dirtying,
      render order) in `src/hildegard.helper.tui.app.pas`
- [ ] **Test** `TestFrameRendersBaseThenModal`
- [ ] **Test** `TestModalDimsBackgroundButKeepsText` (base visible, glyphs intact,
      attributes gain `sfDim`)
- [ ] **Test** `TestModalRegionNotDimmed`
- [ ] **Test** `TestModalTrapsInput`
- [ ] **Test** `TestPopModalRestoresBase`
- [ ] **Test** `TestResizeRelayoutsRoot`
- [ ] **Test** `TestStepProcessesOneEvent`

### Phase 8: Terminal Adapters

- [ ] **Implement** `TSurfaceVideo` over FPC `video` (cells, `UpdateScreen`,
      cursor, lifecycle, restore on exit)
- [ ] **Implement** `TInputSourceTerminal` over FPC `keyboard` and `TIOCGWINSZ`
- [ ] **Calibrate** on macOS: verify resize detection and cursor visibility;
      record findings in `docs/guidelines/testing.md`
- [ ] **Manual check**: run the example in a real terminal; confirm resize and
      two independent scroll panes

### Phase 9: Performance & Benchmark

Deterministic perf tests assert *work* (changed cells, `Arrange` calls), not
wall-clock, so they live in `make check`. Wall-clock budgets are measured by the
benchmark, run explicitly.

- [ ] **Implement** `TSurfaceMemory.LastFrameChangedCells` / `ResetFrameStats`
- [ ] **Test** `TestFirstFrameChangesAllCells` (`= W*H`)
- [ ] **Test** `TestUnchangedFrameChangesZeroCells`
- [ ] **Test** `TestOneLineAppendChangesOnlyItsRow` (changed cells <= viewport
      width)
- [ ] **Test** `TestScrollChangesOnlyViewportRows` (bounded by viewport area, not
      document size)
- [ ] **Test** `TestLayoutRunsOnlyWhenDirty` (a spy widget counts `Arrange`
      calls across steps; a `Step` with no input must not re-arrange)
- [ ] **Test** `TestModalToggleChangesOnlyOverlayAndDimmedRegion`
- [ ] **Add** `tests/test_tui_perf.pas`; register it in the runner
- [ ] **Add** `examples/tui_bench.pas`: scenarios `full`/`append`/`scroll`/
      `resize`/`modal`; time with a monotonic clock; print frames, total ms,
      ms/frame, fps, and average changed cells/frame; support `--real` to use
      `TSurfaceVideo` end-to-end; print a verdict against the budgets
- [ ] **Add** `make bench` (builds and runs the benchmark, prints the table) and
      `make perf` (opt-in wall-clock budget run, not part of `make check`)
- [ ] **Run** `make bench`; confirm the `full` scenario >= 100 fps and `append`
      >= 200 fps on the development machine; record the numbers under Notes

### Phase 10: Example & Docs

- [ ] **Add** `examples/tui_demo.pas`: nested layout (a `fill` chat-ish pane, a
      `fixed`/`fill` second pane, a status row), two independently scrolling text
      blocks, a modal toggled by a key, and markdown-coloured sample text
- [ ] **Add** a `make tui-demo` target
- [ ] **Doc comments**: `{** ... }` on the public interfaces (fpdoc style)
- [ ] **Update the SPEC** if any implemented behaviour diverged

### Phase 11: Validation

- [ ] **Run** `make test SUITE=TTuiSurfaceTest,TTuiLayoutTest,TTuiTextTest,TTuiScrollTest,TTuiAppTest,TTuiPerfTest` (green)
- [ ] **Run** `make test` (whole suite)
- [ ] **Run** `make test-leak` (no leaks)
- [ ] **Run** `make check` (all gates)
- [ ] **Run** `make bench`; confirm budgets met
- [ ] **Rename** this TODO to `TUI_Core_v1.DONE.md`; update `FEATURES.md`

## Dependencies & Ordering

### Must Complete Before Starting

- Base types before every other phase.
- Memory surface and scripted input before layout/text/scroll/app tests (they use
  them as fixtures).
- Layout before text's `Measure` integration and before scroll's content extent.
- Widget protocol before text/scroll containers.
- Scroll before the app example (the demonstration needs scrolling panes).
- `TSurfaceMemory` diff counters before the deterministic perf tests; the
  benchmark depends on the whole toolkit (layout, text, scroll, modal, app).

### Can Be Done in Parallel

- Terminal adapters (Phase 8) can be developed once the interfaces are frozen;
  they are not needed by the in-memory tests.
- Markdown (`Markdown_v1.SPEC.md`) can proceed in parallel once `TAttr`/`TSpan`
  exist; it has its own TODO.

### Critical Path

1. Base types -> memory surface -> widget protocol
2. Layout tracks (`fixed`/`auto`/`fill`)
3. Text block (wrap/measure)
4. Scroll container + scrollbar
5. Planes/modal/app loop
6. Terminal adapters
7. Deterministic perf tests + benchmark
8. Example, docs, `make check`

## Files to Create/Modify

### New Files

```
src/hildegard.helper.tui.base.pas      (cell, attr, rect, size)
src/hildegard.helper.tui.surface.pas   (ISurface, TSurfaceMemory, TSurfaceVideo)
src/hildegard.helper.tui.input.pas     (event types, IInputSource, adapters)
src/hildegard.helper.tui.widget.pas    (TWidget, tracks, TContainer)
src/hildegard.helper.tui.text.pas      (TSpan, TTextBlock)
src/hildegard.helper.tui.scroll.pas    (TScrollContainer, TScrollBar)
src/hildegard.helper.tui.app.pas       (TPlane, TTuiApp)
tests/test_tui_surface.pas
tests/test_tui_input.pas
tests/test_tui_layout.pas
tests/test_tui_text.pas
tests/test_tui_scroll.pas
tests/test_tui_app.pas
tests/test_tui_perf.pas
examples/tui_demo.pas
examples/tui_bench.pas
```

### Modified Files

```
tests/hildegard_helper_tests.pas   (add the new test units to uses)
Makefile                           (tui-demo, bench, perf targets; unit paths)
docs/features/TUI_Harness/         (SPEC/TODO status)
docs/features/FEATURES.md          (status)
```

## Success Criteria

- [ ] All tasks above checked
- [ ] Every acceptance criterion in `FEATURE.md` maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] `make bench` meets the budgets (`full` >= 100 fps, `append` >= 200 fps on
      the development machine) and the numbers are recorded under Notes
- [ ] The example demonstrates nested layout, two independent scroll panes, a
      modal, markdown colour, and terminal resize
- [ ] Implementation matches the specification

## Notes & Considerations

### Resolutions

- `auto` is defined as max-content; wrapping text must live in `fixed`/`fill`
  tracks. This is the key decision that avoids CSS-style fixed-point iteration
  and should be recorded if it proves limiting.
- The core units must not `uses` `video`; only `surface`/`input` adapters do.
  This keeps the test path free of terminal code.
- v1 does not require mouse. The input contract reserves `ikMouse` so widgets can
  adopt it later without a breaking change.

### Performance notes

- Deterministic perf tests count *work* (changed cells, `Arrange` calls), so they
  are safe to keep in `make check`; wall-clock budgets live only in
  `make bench`/`make perf`, where timing variance cannot break the gate.
- Record the `make bench` numbers (per scenario: ms/frame, fps, changed
  cells/frame) here when first run, so later regressions are obvious.

### Deviations

- (Record deviations here with the reason as work proceeds.)

### Discovered work

- (Record newly discovered work here; do not silently expand scope.)
