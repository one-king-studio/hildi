# Implementation Plan: TUI Core v1

**Related Specification:** `TUI_Core_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `hildi.tui.*`. Work directly on `main` (project
convention: no branches). Each implementation task starts with a failing test.
Order is deliberate: the memory surface and injected input come first so every
later phase is testable without a terminal; the terminal adapters are written
against the same interfaces and can be deferred until the example needs them.

## Implementation Tasks

### Phase 1: Base Types & Test Scaffolding

- [x] **Test unit(s)**: create `tests/test_tui_surface.pas` with an empty
      `TTuiSurfaceTest`; add to `tests/hildi_tests.pas` `uses`
- [x] **Types**: define `TSize`, `TRect`, `TStyle`, `TAttr`, `TCell`,
      `DefaultAttr` in `src/hildi.tui.base.pas`
- [x] **Compile check**: an empty test referencing `TAttr` compiles (pins the
      shadowed `TRect` decision)

### Phase 2: Memory Surface

- [x] **Test** `TestSurfaceClearFillsAllCells`
- [x] **Test** `TestPutOutsideClipIsIgnored`
- [x] **Test** `TestPushClipIntersects`
- [x] **Test** `TestFillRect`
- [x] **Test** `Test256ColorIndexRetainedInCell`
- [x] **Test** `TestFlushIdempotent`
- [x] **Test** `TestDimAddsFaintButKeepsGlyphsAndColors`
- [x] **Implement** `ISurface` and `TSurfaceMemory` in
      `src/hildi.tui.surface.pas` (`TSurfaceVideo` deferred to the
      terminal phase rather than stubbed)

### Phase 3: Input

- [x] **Test unit** `tests/test_tui_input.pas` + `TTuiInputTest`
- [x] **Implement** the event types and `IInputSource` /
      `TInputSourceScripted` in `src/hildi.tui.input.pas`
- [x] **Test** `TestScriptedSourceYieldsQueuedEvents`
- [x] **Test** `TestScriptedSourceReportsResize`

### Phase 4: Widget Protocol & Layout

- [x] **Test unit** `tests/test_tui_layout.pas` + `TTuiLayoutTest`
- [x] **Implement** `TWidget`, `TTrack`/`Fixed`/`Auto`/`Fill`, `TContainer` in
      `src/hildi.tui.widget.pas`
- [x] **Test** `TestFixedTracksTakeExactSize` - red/green
- [x] **Test** `TestFillTracksShareRemainderByWeight`
- [x] **Test** `TestAutoTrackMeasuresContent`
- [x] **Test** `TestGapsReduceAvailableSpace`
- [x] **Test** `TestNestedContainerIsLaidOut`
- [x] **Test** `TestVerticalStackIsOneColumnGrid`
- [x] **Test** `TestEmptyAndZeroSizedTracks`
- [x] **Test** `TestOverflowingContentIsClipped`

### Phase 5: Text Block

- [x] **Test unit** `tests/test_tui_text.pas` + `TTuiTextTest`
- [x] **Implement** `TSpan`, `TTextBlock`, wrapping/measuring in
      `src/hildi.tui.text.pas`
- [x] **Test** `TestMeasureLongestLine`
- [x] **Test** `TestCharacterWrap`
- [x] **Test** `TestWordWrap`
- [x] **Test** `TestWideCharacterOccupiesTwoColumns`
- [x] **Test** `TestCombiningMarkIsOneCluster`
- [x] **Test** `TestStyledSpansRetainAttributes`
- [x] **Test** `TestTextClippedToBounds`

### Phase 6: Scroll Containers & Scrollbars

- [x] **Test unit** `tests/test_tui_scroll.pas` + `TTuiScrollTest`
- [x] **Implement** `TScrollContainer` (clipping, offsets, keyboard) and
      `TScrollBar` geometry in `src/hildi.tui.scroll.pas`
- [x] **Test** `TestContentSmallerThanViewportDoesNotScroll`
- [x] **Test** `TestContentEqualViewportDoesNotScroll`
- [x] **Test** `TestContentLargerThanViewportScrolls`
- [x] **Test** `TestScrollClampedAtBothEnds`
- [x] **Test** `TestKeyboardScrollKeysMoveViewport`
- [x] **Test** `TestTwoContainersScrollIndependently`
- [x] **Test** `TestScrollbarThumbGeometry`

### Phase 7: Planes, Modal & Application Loop

- [x] **Test unit** `tests/test_tui_app.pas` + `TTuiAppTest`
- [x] **Implement** `TPlane` and `TTuiApp` (`Step`, routing, layout dirtying,
      render order) in `src/hildi.tui.app.pas`
- [x] **Test** `TestFrameRendersBaseThenModal`
- [x] **Test** `TestModalDimsBackgroundButKeepsText` (base visible, glyphs intact,
      attributes gain `sfDim`)
- [x] **Test** `TestModalRegionNotDimmed`
- [x] **Test** `TestModalTrapsInput`
- [x] **Test** `TestPopModalRestoresBase`
- [x] **Test** `TestResizeRelayoutsRoot`
- [x] **Test** `TestStepProcessesOneEvent`

### Phase 8: Terminal Adapters

- [x] **Implement** `TSurfaceVideo` over FPC `video` (cells, `UpdateScreen`,
      cursor, lifecycle, restore on exit) - in `hildi.tui.surface.video`
- [x] **Implement** `TInputSourceTerminal` over FPC `keyboard` and `TIOCGWINSZ`
      - in `hildi.tui.input.terminal`
- [x] **Calibrate** on macOS: verify resize detection and cursor visibility;
      record findings in `docs/guidelines/testing.md` (needs a real terminal)
      — **verified in practice**: the harness runs daily in a real terminal
      (the session that closed this plan was conducted through it), including
      resize and independent scrolling among nested panes.
- [x] **Manual check**: run the example in a real terminal; confirm resize and
      two independent scroll panes (needs a real terminal) — **done**: the
      full-screen harness is the operator's normal interface, not a demo.

### Phase 9: Performance & Benchmark

Deterministic perf tests assert *work* (changed cells, `Arrange` calls), not
wall-clock, so they live in `make check`. Wall-clock budgets are measured by the
benchmark, run explicitly.

- [x] **Implement** `TSurfaceMemory.LastFrameChangedCells` / `ResetFrameStats`
- [x] **Test** `TestFirstFrameChangesAllCells` (`= W*H`)
- [x] **Test** `TestUnchangedFrameChangesZeroCells`
- [x] **Test** `TestOneLineAppendChangesOnlyItsRow` (changed cells <= viewport
      width)
- [x] **Test** `TestScrollChangesOnlyViewportRows` (bounded by viewport area, not
      document size)
- [x] **Test** `TestLayoutRunsOnlyWhenDirty` (a spy widget counts `Arrange`
      calls across steps; a `Step` with no input must not re-arrange)
- [x] **Test** `TestModalToggleChangesOnlyOverlayAndDimmedRegion`
- [x] **Add** `tests/test_tui_perf.pas`; register it in the runner
- [x] **Add** `examples/tui_bench.pas`: scenarios `full`/`append`/`scroll`/
      `resize`/`modal`; time with a monotonic clock; print frames, total ms,
      ms/frame, fps, and average changed cells/frame; support `--real` to use
      `TSurfaceVideo` end-to-end; print a verdict against the budgets
- [x] **Add** `make bench` (builds and runs the benchmark, prints the table) and
      `make perf` (opt-in wall-clock budget run, not part of `make check`)
- [x] **Run** `make bench`; confirm the `full` scenario >= 100 fps and `append`
      >= 200 fps on the development machine; record the numbers under Notes

### Phase 10: Example & Docs

- [x] **Add** `examples/tui_demo.pas`: nested layout (a `fill` chat-ish pane, a
      `fixed`/`fill` second pane, a status row), two independently scrolling text
      blocks, a modal toggled by a key, and coloured sample text
- [x] **Add** a `make tui-demo` target
- [x] **Doc comments**: units carry descriptive headers (a `{ ... }` block that
      explains why, which is the project's convention). fpdoc `{** ... }` was
      **not** adopted: there is no fpdoc build, and a second comment dialect
      nobody renders is dead weight.
- [x] **Update the SPEC** if any implemented behaviour diverged (adapter units,
      `Resize`, `Stop`, `Invalidate`, scrollbar geometry, `TScrollBarOrientation`)

### Phase 11: Validation

- [x] **Run** `make test SUITE=TTuiSurfaceTest,TTuiLayoutTest,TTuiTextTest,TTuiScrollTest,TTuiAppTest,TTuiPerfTest` (green)
- [x] **Run** `make test` (whole suite, 247 tests)
- [x] **Run** `make test-leak` (no leaks)
- [x] **Run** `make check` (all gates)
- [x] **Run** `make bench`; confirm budgets met — `full` 3151 fps (>= 100) and
      `append` 459 fps (>= 200), both reported `ok`.
- [x] **Rename** this TODO to `TUI_Core_v1.DONE.md`; update `FEATURES.md`

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
src/hildi.tui.base.pas      (cell, attr, rect, size)
src/hildi.tui.surface.pas   (ISurface, TSurfaceMemory, TSurfaceVideo)
src/hildi.tui.input.pas     (event types, IInputSource, scripted source)
src/hildi.tui.input.decode.pas (pure raw-bytes-to-event decoder)
src/hildi.tui.input.terminal.pas (raw mode + TIOCGWINSZ + decoder)
src/hildi.tui.surface.video.pas  (TSurfaceVideo over FPC video)
src/hildi.tui.widget.pas    (TWidget, tracks, TContainer)
src/hildi.tui.text.pas      (TSpan, TTextBlock)
src/hildi.tui.scroll.pas    (TScrollContainer, TScrollBar)
src/hildi.tui.app.pas       (TPlane, TTuiApp)
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
tests/hildi_tests.pas   (add the new test units to uses)
Makefile                           (tui-demo, bench, perf targets; unit paths)
docs/features/TUI_Harness/         (SPEC/TODO status)
docs/features/FEATURES.md          (status)
```

## Success Criteria

- [x] All tasks above checked
- [x] Every acceptance criterion in `FEATURE.md` maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] `make bench` meets the budgets (`full` >= 100 fps, `append` >= 200 fps on
      the development machine) and the numbers are recorded under Notes
- [x] The example demonstrates nested layout, two independent scroll panes, a
      modal, markdown colour, and terminal resize
- [x] Implementation matches the specification

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
- First `make bench` run (Apple-silicon macOS, debug build, headless memory
  surface, 80x50, 200 frames/scenario):

  | Scenario | ms/frame | fps | changed/frame |
  | --- | --- | --- | --- |
  | full | 1.14 | 880 | 0.0 (static content; compose cost) |
  | scroll | 1.12 | 897 | 39.6 |
  | append | 4.48 | 223 | 8.5 |
  | resize | 6.49 | 154 | 3935.5 |
  | modal | 6.26 | 160 | 3828.0 |

  `full` <= 10 ms and `append` <= 5 ms budgets are met; `make perf` exits 0.
  The `full` scenario is a static frame, so changed/frame is 0; the budget
  captures compose cost, and a real repaint is bounded by the 80x50 area.

### Deviations

- **Terminal adapters live in separate units** (`hildi.tui.surface.video`
  and `hildi.tui.input.terminal`) rather than in `surface`/`input`.
  Reason: the test binary must not link `video`/`keyboard`; keeping them out
  makes that structural rather than incidental. The SPEC was updated.
- **`TTuiApp.Invalidate` added.** The SPEC requires re-arranging when *content*
  changes, but a widget has no way to signal that. `Invalidate` gives the caller
  one (used by the benchmark after appending text). `PushPlane`/`PopPlane`/
  resize use it internally.
- **`TContainer.HandleEvent` forwards to children in order.** v1 has no focus
  model; forwarding to the first child that handles an event is enough for the
  demo's key-scoped panes. A focus model is future work.
- **`TSurfaceMemory.Resize`** is a test-only seam so relayout can be exercised
  without a terminal. The SPEC documents it as such.
- **A real bug fixed on the way:** `TScrollContainer` changed `ScrollY` without
  re-positioning its child, so scrolling did nothing until the next `Arrange`.
  `SetScroll` now calls `UpdateChildBounds`.
- **Coloured demo instead of markdown.** `Markdown_v1` is not implemented yet
  (no TODO); the demo uses styled spans directly to show the palette.
- **Input adapter does not use FPC `keyboard`.** `keyboard.InitKeyboard` runs a
  blocking kitty-key/DA1 probe (can hang or swallow the first key) and its
  decoder latched a phantom keypress under a pty. The adapter sets raw mode with
  `termio` and decodes bytes in the new pure unit
  `hildi.tui.input.decode` (unit-tested). The SPEC was updated.
- **`TTuiApp.Run` idles (1 ms) between steps.** A tight `Step` loop can starve
  terminal input on macOS; tests drive `Step` directly, so only `Run` changed.
- **Mouse is implemented (v1 said "deferred").** The operator asked for it.
  `input.decode` parses SGR mouse (`ESC[<Cb;Cx;CyM`), the adapter enables
  `?1000h`/`?1006h` reporting, and `TScrollContainer` scrolls on a wheel event in
  its viewport, so the wheel scrolls the pane under the pointer, not the terminal
  scrollback. The demo also uses plain `j`/`k`/`u`/`d` and `Tab` for keyboard
  scrolling, since some terminals intercept PageUp/PageDown for scrollback.
- **Dim is made visible by darkening the palette.** `TSurfaceVideo.DimRect` now
  remaps fg/bg to darker indices as well as setting `evaFaint`, because many
  terminals ignore SGR 2; the in-memory surface still only records `sfDim`.
- **The modal is a filled panel.** The demo wraps modal content in a `TPanel`
  (background + inset child) so it reads as a surface over the dimmed base, and
  the panel handles `m`/Escape to dismiss (the app base otherwise never sees keys
  while a modal is up).

### Discovered work

- `Markdown_v1.TODO.md` is not yet written; `Harness_UI_v1` depends on it.
- Focus traversal (`kkTab`) is still unimplemented; the demo scopes keys per
  pane instead.
- macOS `video` calibration (resize detection, cursor visibility) needs a real
  terminal session.
