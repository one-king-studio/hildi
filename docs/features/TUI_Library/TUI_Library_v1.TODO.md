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

- [x] **Add** `examples/tui_widgets_standalone.pas` — it listed every widget
      unit, so a single app import anywhere in the tier failed the build.
- [x] **Add** `Makefile` target `tui-widgets-standalone` with
      `-Fu core -Fu terminal -Fu fuzzy -Fu widgets -Fu $(SRC)/markdown` and
      **no** `-Fu $(SRC)`.
- [x] **Extract** `HildiFuzzy` to `src/fuzzy/FuzzyMath.pas` — 162 lines,
      `SysUtils` only, two widgets importing it. The operator asked for this.
- [x] **De-couple** `TUIWidgetsSessionsModal` from `HildiSession`: a local
      `TSessionViewRow` (5 of the store row's 9 fields) plus a local `ShortId`.
      The host maps through `ToViewRows`.
- [x] **Verify**: `make tui-widgets-standalone` builds, runs, passes.
- [x] **Commit**: `refactor(tui): ♻️ the widget tier is exportable, and the gates finally isolate`

**DECISION — no `src/tui/app` tier.** Two widgets could not be de-coupled
honestly: `TUIWidgetsApprovalModal` (renders a `TApprovalAsk` with its options,
script span, workdir and subject) and `TUIWidgetsAgentList` (reads a
`TSubagentRoster`). Mirroring either into TUI records would be a permanent
second copy in the most execution-sensitive widget we have.

**Operator's call: they live with the main program, not in the library.** They
became `HildiApprovalModal` and `HildiAgentList` in `src/`. A generic use case
can be extracted later; it is never hard to turn a class into its own module.

**FINDING — the gates were not isolating.** Every standalone target compiled
with `-FU$(DBGUNITS)`, the SAME unit output directory as the full test build, so
FPC satisfied an app import from a previous run's `.ppu`. The first symptom was
`HildiTLS` undefined in a tier that never mentions TLS. Each gate now owns
`$(BUILD)/units/<tier>`. The five pre-existing gates were re-run under isolation
and all still pass, so the hole was latent rather than a live false pass.

**LATER DECISION — six more widgets left the library.** The gate passed and that
was not enough. It proved no widget imports a Hildi unit, but
`TUIWidgetsHistorymodal` was still a dialog about turns and undo, and
`TUIWidgetsSessionsModal` about sessions: the data was plain records, so the
import check went green while the domain stayed welded in. The real test is
whether a stranger's project would want the unit. Six failed it:

  `HildiChat` (2041), `HildiChatPanel` (1062), `HildiSkillModal` (462),
  `HildiSessionsModal` (426), `HildiHistoryModal` (383), `HildiCompose` (241)

The library is now 17 widget units and 11,283 lines; the domain widgets are
6,129 lines in `src/`. Committed as `9076855`.

### Phase 6: Markdown seam

- [x] **Abandoned**: `IMarkdownRenderer` + `TRenderLine`. It cannot work — see
      the finding below.
- [x] **Documented** `src/markdown` as an optional companion module instead.
- [x] **Asserted** both configurations with two gates: `tui-widgets-standalone`
      (no markdown path, no markdown units) and `tui-widgets-markdown-standalone`.
- [x] **Commit**: `docs(tui): 📝 markdown is an optional companion, and both configurations gate`

**FINDING — the SPEC's seam is the wrong shape, and the honest answer is smaller.**

The SPEC proposed `IMarkdownRenderer.Render(md, width) -> TRenderLineArray`:
flat styled lines. `TUIWidgetsMarkdownView` cannot work on flat lines. It uses
`TMdNode`, `TMdDocument`, `TMdTableRow`, `TMdAlignArray` — the whole v2 node
tree — because it renders GFM tables as a rounded grid at content width. Flattening
to lines would mean re-deriving table structure from painted text. The interface
would be a lie.

The three coupled units are `TUIWidgetsMarkdownView`, `TUIWidgetsMdtheme` and
`TUIWidgetsFileviewer`. They need the node tree, and `src/markdown` is already a
standalone, RTL-only module with its own isolation gate — so taking it is a
dependency on a *library*, not on the application.

**Verified, not assumed:** the library builds and runs with **no `-Fu$(SRC)/markdown`
and none of the three units**, via a throwaway program that omits them. So
markdown is genuinely optional, and the tier rule is:

- `src/tui/core`, `src/tui/terminal`, and the other 17 widgets: **RTL only**
  (plus `src/fuzzy` for the palette).
- `TUIWidgetsMarkdownView`, `TUIWidgetsMdtheme`, `TUIWidgetsFileviewer`: **plus
  `src/markdown`**, which is documented as an optional companion.

That is the smallest true statement. An `IMarkdownRenderer` would be a real API
only if some consumer needed a different renderer — none does, and building one
now costs an interface plus a re-derivation of table layout for no caller.
Revisit if a second consumer appears. Recorded as a deliberate, reversible
decision, not an omission.

### Phase 7: Selection (character granularity)

**Status: built, tested headlessly, and TABLED by the operator.** Select and
copy are deferred so the library can land and unblock the lanes waiting on it.
What is in the tree works to the extent it has been driven; what is not verified
is whether the copy actually reaches the terminal clipboard.

- [x] `TUISelection` — cells not string indices, half-open spans, wide and
      combining clusters, wrap flags. 15 tests. (`0cb8a25`)
- [x] `TSelectable` + `ISurface.Get` — a widget can be dragged across and the
      surface read back so a highlight can RECOLOUR a cell. (`c91901f`)
- [x] `WrapClusters` records why each row ended, so a copy never invents a
      newline inside a soft-wrapped paragraph. (`553168d`)
- [x] `TTextBlock` adopts it by re-parenting; selection is opt-in and default
      off, because `TMarkdownView` builds one per block AND per table cell.
      (`26c872d`)
- [x] `TUIClipboard` — base64 + OSC 52, RFC 4648 vectors. (`f4e0c9a`)
- [x] `TTuiApp.CopySelection`, `ISurface.SetClipboard`. (`f4e0c9a`)
- [x] Wired: `TWidget.CopySelection` tree walk, `Ctrl+Y`, then copy-on-release
      as the default. (`b1e0ac9`, `18fb840`)

**The four bugs that made it unreachable.** Every one lived in the gap between
"the component works" and "the app routes to it", and no unit test could see it:

| Commit | What did not forward |
| --- | --- |
| `c47bcf0` | `TMarkdownView` had no `HandleEvent` at all |
| `71da219` | `TChatItem` exited early for prose blocks — the common case |
| `8407376` | `TSingleChild`, the tree ROOT, never forwarded `CopySelection` |
| `b4124e1` | `TScrollContainer` never forwarded `CopySelection` |

**The design gap this exposed, still open:** `TWidget` has accumulated
`HitTest` and `CopySelection`; every composite must forward both, and nothing
checks that it does. A test that walks the live tree asserting each composite
forwards every protocol method its base declares would have caught all four
before an operator did. That gate is the highest-value thing left.

**Not done:** keyboard selection, word/line granularity, cross-widget selection,
and any confirmation that OSC 52 reaches the clipboard in a real terminal.

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
