# Implementation Plan: TUI Library v1

**Related Specification:** `TUI_Library_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Nine stages, each independently valuable and independently revertable. Every
stage ends with `make check` green. Tasks are checkboxes; update them in real
time.

Branch: `agent/tui-lib` (already created, worktree `.worktrees/tui-lib`).

**Order matters in two places:** stage 1 goes first because it is free and
catches regressions; stage 3 (`HitTest`) must precede stage 7 (selection) because
selection cannot receive a press without it.

## Implementation Tasks

### Phase 1: Gates first (free, catches everything after)

- [x] **Modify** `Makefile`: add `tui-standalone` and `changes-standalone` to the
      `check` target. No code change; both already pass on their own.
- [x] **Verify**: `make check` — same failure count as before the change (none).
- [x] **Commit**: `build(make): ✅ the TUI and changes isolation gates join make check`

**Deviation:** the first `make check` failed on `TFeaturesIndexTest`, which
requires every directory under `docs/features/` to have a row in `FEATURES.md`.
Added the `TUI Library` row. Recorded here because creating a feature directory
is never just a directory.

### Phase 2: Mouse contract (the drag foundation)

- [x] **Test**: `TestTUIInputDecode.TestMouseMotionWithButtonReportsMotion` —
      landed as `TestDecodeMouseActionDistinguishesMotionFromRelease`, which
      covers all three actions in one method because they are only meaningful
      against each other.
- [x] **Test**: `TestMouseReleaseIsNotConfusedWithMotion` — the same method.
- [x] **Test**: `TestMouseModifiersAreDecoded` — landed as
      `TestDecodeMouseModifiers`; covers press and motion paths.
- [x] **Test**: `TestMouseWheelAndClickUnchanged` — landed as
      `TestDecodeMouseClickIsAPress`, which pins a plain press, x/y, empty
      `Mods`, and that a wheel event is a press.
- [x] **Implement**: `TMouseAction` + `Action` + `Mods` in `TUIInput.pas`;
      decode in `TUIInputDecode.MapMouse` (`:447`).
- [x] **Check** every existing `mbNone` arm still behaves:
      `TUIWidgetsScroll.pas:368`, `TUIWidgetsApprovalModal.pas:919`. Both
      deliberately conflate motion-with-no-button and release, and both still
      get `mbNone`. The change is additive: `Button` semantics are untouched.
- [x] **Commit**: `feat(tui): ✨ a mouse event knows motion from release, and carries modifiers`

### Phase 3: Hit-testing (also closes card #36)

- [x] **Test**: `TestHitTestDefaultsToBounds` — inside, outside, and
      `Visible = False`.
- [x] **Test**: `TestOverlappingMouseClickGoesToTheTopmostChild` — two
      children over the same cell; the last added claims it and the bottom one
      is never consulted.
- [x] **Test**: `TestKeyboardDispatchKeepsAddOrder` — pins that keys are NOT
      reordered, before the mouse change could have disturbed them.
- [x] **Implement**: `TWidget.HitTest` virtual; `TContainer.HandleEvent` walks
      children in reverse **for mouse only**.
- [x] **Refactor**: `TApprovalModal.HitTest` renamed to `RowAt`.
- [x] **Commit**: `feat(tui): ✨ a widget can say whether a point is its own`

**Deviation — the SPEC was wrong twice here.**

1. `TApprovalModal.HitTest` returns `Integer` (an option index), so it could not
   override a `Boolean` protocol method; it would shadow it. Renamed to `RowAt`
   instead of "overridden".
2. The SPEC said containers gate dispatch on `HitTest`. They do not. All eight
   mouse-handling widgets already bounds-check themselves, and a gate would
   break drags that leave their widget — `TScrollContainer.FBarDragging` must
   keep receiving motion after the pointer exits, or the scrollbar stops
   mid-drag. Containers only order the offer; leaves decide.

Consequence worth keeping: a child *is* still offered an event outside its
bounds, and declines it. `TestMouseOutsideEveryChildIsNotHandled` pins that.

### Phase 4: Terminal tier

- [x] **Move** `TUIInputTerminal.pas`, `TUIInputFD.pas`, `TUISurfaceVideo.pas`
      to `src/tui/terminal/`. No content change.
- [x] **Modify** `Makefile`: add `-Fu$(SRC)/tui/terminal` to every target that
      builds the TUI (22 paths); `tui-standalone` deliberately untouched, still
      on `core` alone.
- [x] **Verify**: `make check`; `tui-standalone` still compiles with core alone.
- [x] **Commit**: `refactor(tui): ♻️ terminal adapters move to their own tier`

**Flake, not a regression:** the first full gate failed on
`TSessionRuntimeTest.TestAttachPushesTheSkillCatalogue` (a documented timing
flake that spawns a runtime and completes a socket handshake). It passed 34/34
alone and the gate then passed twice.

### Phase 5: Widgets isolation gate

- [ ] **Add** `examples/tui_widgets_standalone.pas`: uses `TPanel`, `TButton`,
      `TList`, `TScrollContainer`, asserts a few cells. **It will not compile**
      at this point — that failure is the driver for the rest of the phase.
- [ ] **Add** `Makefile` target `tui-widgets-standalone` with
      `-Fu core -Fu terminal -Fu widgets -Fu $(SRC)/markdown` and **no**
      `-Fu $(SRC)`.
- [ ] **De-couple** `TUIWidgetsPalette` from `HildiFuzzy`: inject a matcher as
      `of object` callback, or take a pre-filtered index list.
- [ ] **De-couple** `TUIWidgetsSessionsModal` from `HildiFuzzy` and
      `HildiSession`: a plain row record, as `TSkillDetail` already does.
- [ ] **De-couple** `TUIWidgetsApprovalModal` from `HildiApproval`: takes a
      plain ask/decision record; the host maps.
- [ ] **De-couple** `TUIWidgetsAgentList` from `HildiHarnessSubagent`: takes a
      row record and emits selection events.
- [ ] **Verify**: `make tui-widgets-standalone` builds, runs, passes.
- [ ] **Commit**: `refactor(tui): ♻️ no widget unit names a Hildi unit`

### Phase 6: Markdown seam

- [ ] **Test**: `TestTUITestKit`/`TestMarkdownView` — a fake
      `IMarkdownRenderer` returning fixed lines renders those lines.
- [ ] **Implement**: `IMarkdownRenderer` + `TRenderLine` in core (toolkit
      vocabulary only).
- [ ] **Implement**: default implementation binding `src/markdown/`, shipped
      with the module.
- [ ] **Refactor** the four widgets off direct `MarkdownTypes`/`MarkdownTree`/
      `MarkdownStream` imports.
- [ ] **Commit**: `refactor(tui): ♻️ widgets take a renderer, not the markdown tree`

### Phase 7: Selection (character granularity)

- [ ] **Test**: `TestTUISelection.TestSpanNormalisesWhenCaretPrecedesAnchor`
- [ ] **Test**: `TestSpanClampsPastTheEndOfARow`
- [ ] **Test**: `TestWideClusterIsNeverSplit` — CJK fixture; a column landing
      mid-cluster snaps to its start.
- [ ] **Test**: `TestSoftWrappedParagraphCopiesWithoutNewlines`
- [ ] **Test**: `TestHardLineBreakCopiesWithNewline`
- [ ] **Test**: `TestContentChangeMarksSelectionStale`
- [ ] **Implement**: `TTextPos`, `TSelection`, `SelectionSpan` in
      `src/tui/core/TUISelection.pas`.
- [ ] **Implement**: `TSelectable` + `RenderSelection` using `Theme.AccentSoft`
      in `src/tui/widgets/TUIWidgetsSelectable.pas`.
- [ ] **Test**: `TestDragAcrossATextWidgetSelectsExactlyThatText` — press, three
      motions, release, through `TTuiApp` + `TInputSourceScripted`; assert the
      copied string.
- [ ] **Test**: `TestShiftClickStartsNoSelection` — passed through to the host
      hook untouched.
- [ ] **Adopt** one text widget (`TMarkdownView` is the natural first: it owns a
      wrapped-line cache already).
- [ ] **Wire** the copy path to the OSC 52 transport from `TUI_Clipboard`.
- [ ] **Commit**: `feat(tui): ✨ drag across text to select it, character by character`

### Phase 8: Test kit

- [ ] **Implement** `src/tui/TUITestKit.pas`: `TTestSurface` alias,
      `TWidgetFixture`, event builders, `TAppFixture`.
- [ ] **Migrate** three test files: `TestTUIWidgets`, `TestTUIScroll`,
      `TestTUIHistorymodal`.
- [ ] **Test**: `TestTUITestKit` — the kit renders a known widget and asserts a
      known cell.
- [ ] **Commit**: `feat(tui): ✨ the test kit ships with the toolkit`

### Phase 9: Demo, docs, index

- [ ] **Add** `examples/tui_library_demo.pas` — build a window, a list, a
      selectable text pane; run it by hand.
- [ ] **Drive it in a terminal.** Record what was seen on the board, including
      "looks right". Padding, wide characters and drag highlight are arithmetic
      nobody has watched yet.
- [ ] **Amend** `docs/features/TUI_Clipboard/FEATURE.md`: in-widget selection is
      the toolkit's; scrollback selection stays the terminal's; Shift+drag must
      keep working.
- [ ] **Update** `docs/features/FEATURES.md` status.
- [ ] **Rename** this file to `TUI_Library_v1.DONE.md` when every box is ticked.
- [ ] **Commit**: `docs(tui): 📝 the library has a demo, a home, and a status`

## Dependencies & Ordering

### Must Complete Before Starting

- Phase 3 (`HitTest`) before Phase 7 (selection): no hit test, no press.
- Phase 2 (mouse contract) before Phase 7: no motion, no drag.
- Phase 6 (markdown seam) before Phase 7 for `TMarkdownView`, since its
  `IselectableText` should read the renderer's lines rather than the tree.
- Phase 5 failing gate before the de-coupling tasks — the gate is the test.

### Can Be Done in Parallel

- Phase 1, 2 and 4 are independent of each other.
- Within Phase 5, the four de-coupling tasks touch four different files.

### Critical Path

1. Gates (1) → mouse contract (2) → hit-testing (3) → selection model (7)
2. Widgets gate (5) → markdown seam (6) → adoption in a text widget (7)

## Files to Create/Modify

### New Files

```
src/tui/core/TUISelection.pas
src/tui/widgets/TUIWidgetsSelectable.pas
src/tui/TUITestKit.pas
src/tui/terminal/                         (moved units)
examples/tui_widgets_standalone.pas
examples/tui_library_demo.pas
tests/TestTUISelection.pas
tests/TestTUITestKit.pas
docs/features/TUI_Library/                (this directory)
```

### Modified Files

```
tests/HildiTests.pas                      (add TestTUISelection, TestTUITestKit)
Makefile                                  (gates, terminal path, new examples)
src/tui/core/TUIInput.pas                 (TMouseAction, Mods)
src/tui/core/TUIInputDecode.pas           (MapMouse)
src/tui/core/TUIWidget.pas                (HitTest, reverse mouse dispatch)
src/tui/widgets/TUIWidgetsApprovalModal.pas
src/tui/widgets/TUIWidgetsPalette.pas
src/tui/widgets/TUIWidgetsSessionsModal.pas
src/tui/widgets/TUIWidgetsAgentList.pas
src/tui/widgets/TUIWidgetsMarkdownView.pas
src/tui/widgets/TUIWidgetsFileviewer.pas
src/tui/widgets/TUIWidgetsChat.pas
src/tui/widgets/TUIWidgetsMdtheme.pas
docs/features/TUI_Clipboard/FEATURE.md    (non-goal amendment)
docs/features/FEATURES.md                 (status)
```

## Success Criteria

- [ ] All tasks above checked
- [ ] Every acceptance criterion in `FEATURE.md` maps to a passing test
- [ ] `make check` passes with both new gates
- [ ] A demo runs, and what it looked like is recorded
- [ ] Implementation matches `TUI_Library_v1.SPEC.md`, or the SPEC is updated
      where it diverged

## Notes & Considerations

- **Record deviations here, with the reason.** A stage that turns out to need a
  different shape than the SPEC describes is a SPEC edit, not a silent drift.
- **Do not script the widget edits.** Two `sed`/`python` passes corrupted
  `THistoryModal` in the previous lane (orphaned `Measure`, half-rewritten
  `FTheme`, `FBounds` outside a method). Both were reverted. Edit specific sites
  by hand.
- **Stage explicit paths on commit.** `git add -A` swept `.commit-msg.tmp` into
  a commit twice. Write messages to a file and use `git commit -F` — a backtick
  in a message runs command substitution.
- **Known flakes, both timing:** `TSessionRuntimeTest.TestAttachPushesTheSkillCatalogue`
  and `TestLoadSkillOverTheWireLoadsIt`. Re-run before investigating.
- **The performance gate is real.** `TestTUIPerf` and
  `TestStackLayoutDoesNotThrashAcrossMeasureAndArrange` exist because a
  Measure/Arrange width disagreement cost 16 ms per frame. If selection or
  hit-testing adds a pass over the tree, measure it there.
- **Card #36 closes at Phase 3**, not at Phase 7 — `TApprovalModal` gets the
  protocol method and its private duplicate goes away.
