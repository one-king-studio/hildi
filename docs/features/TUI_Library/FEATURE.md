# TUI Library

## Overview

`src/tui/` is a complete, tested, immediate-mode terminal UI toolkit living
inside the Hildi application: 39 units and 17,324 lines, paired with 28 test
files and 12,168 lines. It is already structured the way an extracted library
should be — a pure `core/` substrate and a `widgets/` component tier — but it
cannot be lifted into another project without dragging Hildi with it.

This feature makes it a genuine module on the same footing as `src/shell`,
`src/markdown` and `src/async`: importable by a second Free Pascal project,
provable by an isolation gate, and shippable with the test utilities that
currently exist only as scaffolding inside the harness suite.

It also adds **in-widget text selection**, which the toolkit needs to call
itself a text UI library and which today has no foundation at all: the input
decoder discards the motion-versus-release distinction a drag requires, and
the widget protocol has no hit-testing.

## Problem Statement

The toolkit is good and it is trapped.

- **It cannot be exported.** Seven of the 25 widget units reach outside the
  module: four into the application layer (`HildiFuzzy`, `HildiSession`,
  `HildiApproval`, `HildiHarnessSubagent`) and four into the markdown library.
  A consumer taking `src/tui/**` must also take `HildiSession` — which pulls in
  the store, the agent and the LLM client.
- **Nothing enforces the boundary.** `make tui-standalone` exists, builds and
  passes — and is not in `make check`. `changes-standalone` is in the same
  position. A gate outside `make check` is a comment.
- **The test utilities are not a deliverable.** `TSurfaceMemory` — the
  in-memory surface with cell assertions and diff-locality counters, the single
  best thing in the toolkit for testability — lives inside the production unit
  `TUISurface.pas`. Twenty-three test files hand-roll their fixtures around it.
  A consumer adopting the widget has to reinvent all of that.
- **Text is not selectable.** For a text-heavy UI library this is a category
  gap, not a missing feature. Today the story is terminal-native selection
  behind a Shift+drag bypass, documented in `docs/features/TUI_Clipboard/` as
  an explicit non-goal — a decision this feature reverses, because "select the
  text you can see" is table stakes for a reusable toolkit rather than a Hildi
  behaviour.
- **Mouse input is lossy.** `TInputDecode` collapses SGR motion and release into
  `Button = mbNone` (`TUIInputDecode.pas:486-494`), so no drag can be
  distinguished from a mouse-up, and `Mouse.Mods` is never populated. The
  terminal already sends the bytes (`?1002h` is enabled); the decoder throws
  away the information.

## Goals

- `src/tui/**` compiles and runs with **no Hildi application unit** reachable,
  enforced by a gate inside `make check`.
- The module has three explicit tiers with a stated dependency rule — pure
  core, terminal adapters, and widgets — so a non-terminal consumer can take
  the pure part alone.
- A named test kit is part of the deliverable: memory surface, scripted input,
  cell/row assertions, and an app fixture, replacing the hand-rolled scaffolding
  in 23 test files.
- **Character-granular text selection** is available to any text-drawing widget,
  by inheritance for new widgets and by composition for the five existing ones,
  with no re-parenting of the existing hierarchy.
- Mouse events carry enough information for a drag: press, motion and release
  are distinguishable, and modifiers are populated.
- `TWidget` gains hit-testing, so mouse targeting is a protocol capability
  rather than six private implementations and a host callback.

## User Stories

- As a **harness author**, I want to take `src/tui/**` into a new project and
  compile it without any Hildi unit, so that I can build an unrelated terminal
  UI on a foundation that is already tested.
- As a **library consumer**, I want the in-memory surface and its assertions as
  a documented unit, so that I can write widget tests the same way the toolkit
  tests itself.
- As an **operator**, I want to drag across an assistant reply and copy exactly
  the text I selected, including part of a wrapped paragraph, so that I do not
  have to fight the app's mouse reporting with Shift+drag.
- As a **widget author**, I want text selection to come from a base class or a
  small field, so that I do not implement anchor/caret/span logic per widget.
- As a **widget author**, I want `HitTest` on the widget protocol, so that a
  click lands on the thing I can see rather than on whatever was added first.

## Acceptance Criteria

### Functional Requirements

- [ ] A widgets-tier standalone program (`examples/tui_widgets_standalone.pas`)
      compiles with only `src/tui/**` and the RTL on the search path, and is
      part of `make check`.
- [ ] `make check` runs `tui-standalone` and `tui-widgets-standalone`.
- [ ] No unit under `src/tui/` has a `uses` entry from `src/` outside
      `src/tui/` and `src/markdown/`.
- [ ] Markdown is bundled with the module behind a seam, so a consumer can
      substitute a renderer without editing widget sources.
- [ ] `TMouseEvent` distinguishes press, motion and release, and carries
      modifiers.
- [ ] `TWidget.HitTest(X, Y)` exists, defaults to a point-in-`FBounds` test, and
      containers dispatch mouse events topmost-first.
- [ ] A `TSelection` value type models anchor/caret and resolves to normalised
      spans per row.
- [ ] Character-granular selection works on at least one text widget end to end:
      press, drag, release, then copy yields exactly the selected text.
- [ ] Selection across a soft-wrapped paragraph copies **without** inserted
      newlines.
- [ ] Selection columns are display cells: a wide character or combining
      cluster is never split, and never misaligned by `Length` versus
      `StringWidth`.
- [ ] Selection is cleared when the underlying content changes underneath it.
- [ ] Shift+click and Shift+drag are not consumed, so terminal-native selection
      still works.
- [ ] The test kit ships as `TUITestKit`, and at least three existing test files
      are migrated to it as proof it is usable.

### Non-Functional Requirements

- [ ] Performance: the per-frame cost of an active selection is O(visible rows),
      and a steady-state frame with no selection draws no additional work.
- [ ] Reliability: no leaks under `make test-leak`; a drag that leaves the
      widget still terminates correctly.
- [ ] Portability: macOS and Linux; no new platform primitive.
- [ ] Backward compatibility: the harness and its 2,173-test suite stay green
      throughout, with each stage landing independently.

## Success Metrics

### Quantitative

- Widgets-tier isolation gate: **0** external units reachable from `src/tui/**`.
- `make check` duration increase: **under 5 s** for both new gates.
- Selection copy fidelity: every character of the selected range returned, on
  ASCII, wide-character and combining-mark fixtures.
- Test-kit adoption: **3 of 23** surface-using test files migrated in this
  feature; the rest tracked as a follow-on.

### Qualitative

- A consumer can read one `README`-level document and build a window.
- The tier rule is obvious from the directory layout, with no explanation.

## Constraints

### Technical

- Free Pascal 3.3.1, `{$mode delphi}{$H+}`, no anonymous methods (`of object`
  callbacks only).
- Field declarations precede methods in a class body.
- Must keep `make check` green at every commit.
- **No physical relocation of the 39 units.** `src/tui/core` and
  `src/tui/widgets` are already the right shape; the work is seams.
- No change to the immediate-mode rendering model: full-tree render into a cell
  buffer, diffed once at `ISurface.Flush`.

### Business / Time

- Incremental: each stage is independently valuable and independently
  revertable. No stage is allowed to leave the suite red.

## Dependencies

### Internal

- `src/tui/core/TUIWidget.pas` — the widget protocol and `TContainer` grid.
- `src/tui/core/TUIApp.pas` — planes, the frame loop, input dispatch.
- `src/tui/core/TUIInputDecode.pas` — pure byte-to-event decoding.
- `src/tui/core/TUISurface.pas` — `ISurface` and `TSurfaceMemory`.
- `src/markdown/` — the bundled renderer behind the seam.
- `docs/features/TUI_Clipboard/` — the OSC 52 copy path selection feeds.
- `docs/guidelines/tui-rendering.md` — the Measure/Arrange and animation
  invariants any change must preserve.

### External

- None. No new `deps/` entry, no platform binding.

## Risks

- **Risk: the widgets-tier gate cannot go green without a hierarchy change.**
  Mitigation: the four app-coupled widgets take plain records and `of object`
  callbacks; `TSkillDetail` (`HildiSkillModal.pas`) is the existing
  precedent for exactly this.
- **Risk: changing mouse dispatch to topmost-first breaks existing widgets that
  rely on first-added-wins.** Mitigation: the current order is only observably
  different for overlapping cells, which today means modals; assert the existing
  modal behaviour with a test before and after.
- **Risk: selection corrupts on wide characters.** Mitigation: anchor in display
  cells, convert through `StringWidth`, and test with CJK and combining-mark
  fixtures from the start.
- **Risk: the markdown seam over-abstracts.** Mitigation: default to the bundled
  renderer; the seam exists only so a consumer can substitute, and gets one
  interface, not a plugin system.
- **Risk: an interactive feature is shipped unrendered** — the failure mode this
  area has already produced twice. Mitigation: every stage ends with a demo run
  in a real terminal, recorded on the board, not just a green suite.

## Out of Scope

- Retained-mode rendering, dirty rectangles, or a scene graph.
- Cross-widget selection. v1 is per-widget; the ceiling is marked with a
  `ponytail:` comment naming the upgrade path.
- Scrollback integration, or selection of text the toolkit did not draw.
- Keyboard selection (Shift+arrows) and double/triple-click word and line
  selection — natural v1.1, deliberately deferred.
- A distributable artifact (package manifest, versioning, vendoring). The design
  must not preclude it; building it now is over-engineering.
- Clipboard *read*, and copy-on-select.
- Migrating the remaining 20 test files to `TUITestKit`.

## Future Considerations

- Keyboard-driven selection and word/line granularity.
- Cross-widget and cross-block selection through a container-level model.
- A distributable package plus a versioned changelog, once a second consumer
  exists and the seam has been exercised by hand.
- `TModal` gaining row hit-testing — falls out of this feature's `HitTest`
  work and closes card #36.

## Notes

**ICE score: Impact 8, Confidence 7, Ease 5.**

High impact because the toolkit is already good and unusable elsewhere; high
confidence because the blockers are measured (seven units, one gate omission,
one lossy decoder) rather than assumed; middle ease because selection at
character granularity touches layout, not just paint.

**Decision recorded:** the `TUI_Clipboard` non-goal ("No general text selection
— the terminal owns that") is **reversed** for in-widget selection. Scrollback
selection remains the terminal's. The Shift+drag bypass must keep working, which
is why selection does not consume Shift-modified mouse events.
