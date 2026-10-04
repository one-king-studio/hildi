# Implementation Plan: Markdown Tables v1

**Related Specification:** `Markdown_Tables_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

GFM pipe tables: a new `mbTable` parser block and a `TTableBlock` widget that
sizes columns to content and wraps them when the table is wider than the
container. Completed; `make check` green.

## Implementation Tasks

### Phase 1: Parser types & helpers

- [x] **Define types** in `src/hildegard.helper.markdown.pas`: `mbTable`,
      `TMdAlign`, `TMdAlignArray`, `TMdTableRow`, `TMdTableRows`, and the
      `TMdBlock` table fields.
- [x] **Test**: `TestTableDetected`
- [x] **Implement**: `HasUnescapedPipe`, `SplitCells` (with `\|`), `ParseDelimiter`
- [x] **Test**: `TestTableAlignmentParsed`, `TestTableEscapedPipe`,
      `TestTablePadsAndTruncatesCells`, `TestTableInlineStylesInCells`

### Phase 2: Parser integration

- [x] **Test**: `TestTableEndsAtBlankLine`, `TestTableEndsAtNonRowLine`
- [x] **Implement**: `mbTable` in `FinalizeTail`; table continuation in
      `ProcessLine`
- [x] **Test**: `TestTableHeaderAfterParagraph`
- [x] **Implement**: delimiter-row detection that opens a table, splitting a
      preceding paragraph
- [x] **Test**: `TestDelimiterWithoutPipeIsParagraph`,
      `TestIncrementalTableMatchesFullParse`

### Phase 3: Table widget

- [x] **Refactor**: `Combine`/`ConvertSpans` to unit-level functions taking
      `TMdSpanArray`, so the table can share them
- [x] **Define** `TTableBlock` in `src/hildegard.helper.tui.markdownview.pas`
- [x] **Test**: `TestTableRendersGrid` (frame, header, rules, cells)
- [x] **Test**: `TestTableIsContentWidth` (narrow table is not full width)
- [x] **Test**: `TestTableCompressesAndWraps` (over-wide table wraps to width)
- [x] **Test**: `TestTableAlignment`
- [x] **Test**: `TestTableUsesTheThemeColours`
- [x] **Implement**: `BuildCells`, `Layout` (width policy + row heights),
      `Measure`, `Arrange`, `Render`

### Phase 4: View wiring

- [x] **Implement**: `MakeBlock` returns a `TWidget`; `mbTable` maps to a
      `TTableBlock`; `FBlocks` becomes `array of TWidget`; branch in
      `Measure`/`Arrange`/`Render`
- [x] **Test**: `TestTableCellsAreNotRebuilt`
- [x] **Implement**: `LayoutBuilds` for the table via a type test

### Phase 5: Docs & validation

- [x] **Update** `docs/features/TUI_Harness/FEATURE.md` (markdown criteria, out
      of scope)
- [x] **Update** `docs/features/FEATURES.md` status
- [x] **Run**: `make test SUITE=TMarkdownTest,TMarkdownViewTest` (green)
- [x] **Run**: `make check` (695 tests, leak-clean)

## Completion Notes

- The design is previewed in `docs/design/tui_design_language.html` (Markdown →
  Tables) and signed off: rounded grid, a rule between every row, header bold
  gold, body plain, borders in the dim rule colour.
- One bug found and fixed during TDD: the render loop drew the rule before
  incrementing to the row (an off-by-one that put the body one row too low and
  clipped the bottom border).
- **Width policy revised after review.** The first policy grew the slack into
  the column with the most headroom, which starved a column with short content
  (a wide "Detail" column kept the slack while "Status" wrapped to seven lines).
  It now searches for the smallest per-row line budget H for which every cell
  fits the width, so each column takes exactly the width it needs for H lines;
  leftover width is spent on the line drops that shrink the tallest rows. On the
  operator's gap-analysis table this took the widths from `[1,10,7,89]` to
  `[1,21,21,70]` and the height from 29 rows to 20. `TTextBlock` gained a
  non-caching `LineCountAt` so the search can probe widths without disturbing
  the wrap cache. The companion shows a before/after.
- Deviations accepted for v1, as recorded in the SPEC: a header must begin a
  block or be the last line of a paragraph; a delimiter with no `|` is not a
  table; a table is inert raw text while streaming, like every other block.
- Not committed: the design companion, the SPEC/DONE, and the code are staged
  for a commit once the operator gives the word.
