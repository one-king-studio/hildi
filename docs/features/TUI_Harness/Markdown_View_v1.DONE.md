# Implementation Plan: Markdown View v1 (DONE)

**Related Specification:** `Markdown_View_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

A widget that stacks a parsed `TMdBlockArray` as styled text blocks plus chrome
(bullets, a quote bar, a code backdrop, a rule). Complete: `make check` green at
664 tests, leak-clean.

## Implementation Tasks

### Phase 1: Skeleton

- [x] **Test unit**: `tests/test_markdownview.pas`, added to the `uses` clause of
      `tests/hildegard_helper_tests.pas`
- [x] **Test**: `TestEmptySourceMeasuresZero`
- [x] **Implement**: `src/hildegard.helper.tui.markdownview.pas` with the types

### Phase 2: Block rendering

- [x] **Test**: `TestParagraphRenders`, `TestInlineBoldIsStyled`
- [x] **Test**: `TestHeadingUsesTheTheme`
- [x] **Test**: `TestBulletPrefix`, `TestOrderedPrefix`
- [x] **Test**: `TestQuoteBar`
- [x] **Test**: `TestRuleIsFullWidth`
- [x] **Test**: `TestCodeBackdropFillsTheRow`
- [x] **Test**: `TestBlocksAreSeparatedByABlankRow`, `TestTightListHasNoGap`
- [x] **Implement**: the block-to-spans mapping and the vertical stack

### Phase 3: Streaming

- [x] **Test**: `TestStreamingTailIsPlainText`
- [x] **Test**: `TestFinalisedBlocksAreNotRebuilt`
- [x] **Test**: `TestFinishPromotesTheTail`
- [x] **Implement**: `AppendSource`/`FinishSource` and the incremental child sync

### Phase 4: Chat panel integration

- [x] **Test**: `TestAssistantRendersMarkdown` in `tests/test_tui_chat.pas`
- [x] **Implement**: `TChatItem` uses a `TMarkdownView` for `ckAssistant` (lazily
      created; `SetText` resets it, `AppendText` feeds it incrementally) and
      branches in `BodyRows`/`Arrange`/`Render`/`LayoutBuilds`

### Phase 5: Docs & validation

- [x] **Update the SPEC** if the implemented behaviour diverged
- [x] **Update** `docs/features/FEATURES.md`
- [x] **Update** `HANDOFF.md`
- [x] **Run**: `make test SUITE=TMarkdownViewTest` (green, 14)
- [x] **Run**: `make check` (all gates, exit 0)

## Files Created/Modified

```
src/hildegard.helper.tui.markdownview.pas   (new)
tests/test_markdownview.pas                 (new) 14 tests
src/hildegard.helper.tui.chat.pas           (assistant blocks use the view)
tests/test_tui_chat.pas                     (TestAssistantRendersMarkdown)
tests/hildegard_helper_tests.pas            (add the test unit to uses)
src/hildegard.helper.markdown.pas           (FinalizedCount/FinalizedBlock/TailText)
docs/features/TUI_Harness/Markdown_View_v1.SPEC.md
docs/features/TUI_Harness/Markdown_View_v1.DONE.md
docs/features/FEATURES.md
HANDOFF.md
```

## Notes & Deviations

- **`{$codepage utf8}` is required** in this unit and its test: the bullet (`•`),
  quote bar (`│`), and rule (`─`) are non-ASCII literals, and without the
  directive FPC reads them in the system codepage and they mangle.
- **The parser gained three accessors** (`FinalizedCount`, `FinalizedBlock`,
  `TailText`) so the view can create a child only for a newly finalised block and
  reuse one child for the open tail. `Blocks` is unchanged for other callers.
- **`BlockLayoutBuilds`** is a small instrumentation accessor, mirroring the chat
  item's `LayoutBuilds`, so a test can prove a finalised block is not rebuilt.
- **Gap rule:** one blank row between blocks, except between two consecutive list
  items (a tight list), which get none.
- **Chat panel wiring is done.** `TChatItem` uses a `TMarkdownView` for
  `ckAssistant` blocks (created lazily; `SetText` resets it, `AppendText` feeds
  it incrementally) and branches in `BodyRows`/`Arrange`/`Render`/`LayoutBuilds`.
  User, tool, thought, and error blocks keep the plain `TTextBlock`, so a tool
  result is never parsed as markdown. Covered by `TestAssistantRendersMarkdown`.

## Success Criteria

- [x] All tasks above checked
- [x] Every acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
