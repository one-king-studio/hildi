# Implementation Plan: Markdown Colourisation v1 (DONE)

**Related Specification:** `Markdown_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

A pure parser (`hildegard.helper.markdown`) that turns a markdown subset into
typed blocks of styled spans and maps them to `TAttr`; no UI, no I/O. Complete:
`make check` green at 649 tests, leak-clean.

## Implementation Tasks

### Phase 1: Skeleton & types

- [x] **Test unit**: `tests/test_markdown.pas`, added to the `uses` clause of
      `tests/hildegard_helper_tests.pas`
- [x] **Test**: `TestEmptyInputYieldsNoBlocks`
- [x] **Implement**: `src/hildegard.helper.markdown.pas` with the SPEC's public
      types
- [x] **Check FPC user-contributed units for a reusable markdown subset**: none
      exists. `fcl-*` has JSON, XML, CSS, PDF, Mustache, and OpenAPI but no
      markdown; the closest (fcl-css, fcl-xml) are not reusable for markdown.
      A minimal parser is justified.

### Phase 2: Block pass

- [x] **Test**: `TestHeadingLevels`, `TestSevenHashesIsParagraph`
- [x] **Test**: `TestParagraphSplitsOnBlankLine`
- [x] **Test**: `TestBulletListItems`, `TestOrderedListItems`,
      `TestOrderedOrdinalCaptured`
- [x] **Test**: `TestListInterruptsParagraph`, `TestLooseListItemsAreAllKept`
- [x] **Test**: `TestBlockquoteNesting`
- [x] **Test**: `TestHorizontalRule`
- [x] **Test**: `TestFencedCodeIsVerbatim`, `TestFencedCodeLanguageCaptured`,
      `TestUnterminatedFenceIsCodeAtEof`
- [x] **Test**: `TestMarkerNotAtLineStartIsLiteral`
- [x] **Implement**: the line classifier and block accumulator in `ProcessLine`

### Phase 3: Inline pass

- [x] **Test**: `TestInlineBoldItalicCode`
- [x] **Test**: `TestInlineStrike`
- [x] **Test**: `TestInlineLinkTargetCaptured`
- [x] **Test**: `TestMalformedMarkupRendersLiterally`
- [x] **Test**: `TestWhitespaceCollapsedInParagraph`
- [x] **Test**: `TestCodeBlocksCarryNoInlineStyles`
- [x] **Implement**: `InlineSpans`, the scanner producing `TMdSpan` runs

### Phase 4: Theme & attribute mapping

- [x] **Test**: `TestStyleForMapsEachInlineStyle`
- [x] **Test**: `TestBlockAttrMapsEachBlockKind`
- [x] **Test**: `TestHeadingAttrUsesTheLevel`
- [x] **Implement**: `DefaultMdTheme`, `StyleFor`, `BlockAttr`

### Phase 5: Incremental append

- [x] **Test**: `TestIncrementalAppendMatchesFullParse`
- [x] **Test**: `TestOpenTailIsPlainText`
- [x] **Test**: `TestAppendAfterReset`
- [x] **Implement**: the raw tail buffer, block finalisation, `Finish`, `Reset`

### Phase 6: Integration

- [x] **Test**: `TestStyledSpansFeedTextBlock`

### Phase 7: Docs & validation

- [x] **Update the SPEC** (incremental section, `TMdBlock` fields, `Finish`)
- [x] **Update** `docs/features/FEATURES.md` (TUI Harness specs list)
- [x] **Update** `HANDOFF.md` (state, test count)
- [x] **Run**: `make test SUITE=TMarkdownTest` (green, 28)
- [x] **Run**: `make check` (all gates, exit 0)

## Files Created/Modified

```
src/hildegard.helper.markdown.pas   (new) parser, inline scanner, theme
tests/test_markdown.pas             (new) 28 tests
tests/hildegard_helper_tests.pas    (add the test unit to uses)
docs/features/TUI_Harness/Markdown_v1.SPEC.md   (incremental design, fields, Finish)
docs/features/FEATURES.md           (TUI Harness specs list)
HANDOFF.md                          (state, test count)
```

## Notes & Deviations

- **No UI in v1.** The parser produces data; a `TMarkdownView` widget that draws
  it is a future item, so this changes no pixels yet.
- **`Link` and `Language` are `UnicodeString`,** not `string`, so the parser
  stays Unicode-clean under `-Sew` (an implicit `UnicodeString`→`AnsiString`
  conversion is a warning-as-error). `TMdSpan.Text` was already `UnicodeString`.
- **`Finish` was added** to the contract: `Append` cannot know the stream ended,
  so `Finish` finalises the open tail as the last block. `Parse` = `Reset` +
  feed-to-EOF.
- **The open tail includes the pending partial line**, so a streamed line shows
  before its newline arrives; `Blocks` returns finalised blocks plus that raw
  tail as one plain text block.
- **`mbBlank` is never emitted** in v1; blank lines only separate blocks.
- **Accepted deviations** (recorded in the unit header and the SPEC): lazy
  continuation is not supported; any ordered number may interrupt a paragraph;
  underscore emphasis is recognised only at word boundaries; setext headings and
  the wider GFM surface (tables, footnotes, math, HTML blocks) are out of scope.
- **Loose lists:** a blank line keeps a list open (CommonMark), but the flat
  block model makes tight/loose lists render identically, so this is a
  forward-compatibility choice rather than an observable one today.

## Success Criteria

- [x] All tasks above checked
- [x] Every acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] Parser depends on the toolkit only through `TAttr`

## Follow-up: nested emphasis and heading colours (2026-10-03)

The inline scanner now re-scans a paired run and ORs the outer style into each
inner span, so `***x***` is bold **and** italic and emphasis nests
(`**bold *italic* bold**`). Previously `***x***` emitted a bold span with a
stray leading `*` and leaked a `*`, which could turn unrelated text downstream
italic. Nesting is depth-capped (`MaxInlineDepth = 16`) so untrusted input
cannot blow the stack.

`DefaultMdTheme` now sets every heading to the brightest white (231) and bold,
and the body a step dimmer (250), reserving the brightest white for headings.
H1-H3 also carry an underline (see the Markdown View DONE).
