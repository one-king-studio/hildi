# Implementation Plan: Activity Spinner v1

**Related Specification:** `Activity_Spinner_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

One frame function; the toolbar, the thinking row, and an active box use it.
Pad a live block's tail to a constant height. TDD-first; `make check` before
moving on. `main` only.

## Implementation Tasks

### Phase 1: One frame source

- [x] **Test**: `TestActivityFrameAdvances` — the frame changes across
      `SpinnerIntervalMs` and is stable within it; it cycles `BrailleFrames`.
- [x] **Implement**: `ActivityFrame` in `chat`; retire the `Sparkles` set;
      `ThinkingSparkle` delegates to it.
- [x] **Test**: `TestThinkingRowDrawsTheSpinner` — the `ckThinking` row renders
      the current frame.
- [x] **Implement**: `TChatItem` (`ckThinking`) draws `ActivityFrame`.
- [x] **Implement**: `TChatPanel.RenderState`/`Advance` use `ActivityFrame`.
- [x] **Refactor**; `make check`.

### Phase 2: Stable live height

- [x] **Test**: `TestLiveThoughtKeepsAStableHeight` — a live block whose tail
      ends in a blank row measures the same as one that does not.
- [x] **Implement**: in `ApplyDisplay`'s live branch, pad the tail to
      `LiveTailLines` at the top.
- [x] **Refactor**; `make check`.

### Phase 3: The box spinner

- [x] **Test**: `TestLiveBoxDrawsTheSpinner` — a live thought/tool box renders
      the spinner at the bottom-right; no caret.
- [x] **Test**: `TestIdleBoxShowsTheCaret` — a settled collapsible box still
      draws its caret.
- [x] **Implement**: `TChatItem.Render` draws the spinner in the caret slot when
      `FLive`; suppress the caret then.
- [x] **Implement**: an active box registers the spinner interval for animation
      (so the frame advances while live).
- [x] **Refactor**; `make check`.

### Phase 4: Validation & docs

- [x] `make test`, `make test-leak`, `make check` — green.
- [x] **Manual**: watch a slow `run_command` — the box spins at the bottom-right
      and the toolbar matches; a streaming thought does not jump.
- [x] **Update** `FEATURES.md`; rename this TODO to
      `Activity_Spinner_v1.DONE.md`.

## Files to Create/Modify

```
src/hildi.tui.chat.pas        (ActivityFrame; live pad; box spinner)
src/hildi.tui.chatpanel.pas   (toolbar uses ActivityFrame)
tests/test_tui_chat.pas                  (extended)
docs/features/FEATURES.md
```

## Critical Path

1 (frame) → 2 (height) → 3 (box spinner) → 4.

## Success Criteria

- [x] All tasks checked.
- [x] Every SPEC acceptance criterion maps to a passing test.
- [x] `make check` passes.
- [x] The three indicators show the same frame; a live block's height is stable.

## Notes & Considerations

- **`TSpinner` already exists** with `BrailleFrames`; the chat surface uses the
  frames, not the widget (the widget is a standalone widget with its own
  `Advance`). Reuse the constant, not the class, to keep the frame a pure
  function of the shared clock.
- **The caret and the spinner share the slot.** A live block is not toggleable
  (`HandleEvent` already returns early when `FLive`), so suppressing the caret
  while live loses nothing.
- **Do not change `LiveTailLines`' value**; the fix is padding, not a new count.
- Record deviations from the SPEC here.
