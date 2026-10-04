# Component Specification: Markdown Tables v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Extends:** [Markdown v1](Markdown_v1.SPEC.md) (the parser) and
[Markdown View v1](Markdown_View_v1.SPEC.md) (the view).

## Purpose

GFM pipe tables: a new parser block kind, and the first block whose rendering is
not a single wrapped text block. A table is a grid of independently wrapping
cells, so its sizing and wrapping live in a dedicated `TTableBlock` widget rather
than in the view's block stack.

Two properties drive the design. A table takes the width its content needs and
never the container's full width. When the content is wider than the container it
compresses the columns and wraps the cells, rather than scrolling horizontally
(the toolkit has no horizontal scroll in v1).

## Requirements

### Functional

**Parser** (`hildegard.helper.markdown`)

- [ ] Recognise a pipe table: a header row containing an unescaped `|`, followed
      immediately by a delimiter row whose cells are `:?-+:?` and whose cell
      count equals the header's.
- [ ] Accumulate body rows until a blank line, a line with no unescaped `|`, or
      EOF.
- [ ] Split a row on unescaped `|`; drop an optional leading and trailing `|`;
      `\|` is a literal pipe.
- [ ] A delimiter cell `:---` is left, `:---:` centre, `---:` right, and `---`
      default (left).
- [ ] Inline-parse each cell, so bold, italic, code, strike, and links work
      inside a cell.
- [ ] Pad a short row with empty cells and truncate a long row to the header's
      column count.
- [ ] A table header begins a block: a delimiter row after the last line of a
      multi-line paragraph finalises the earlier lines as a paragraph and takes
      the last line as the header.
- [ ] Streaming: an open table is inert raw text until it finalises, like every
      other block.

**View** (`hildegard.helper.tui.markdownview`)

- [ ] Draw an `mbTable` block as a rounded grid with a `├─┼─┤` rule between
      every row, framed by `╭╮╰╯` and `┬┴┼`.
- [ ] Chrome in the rule colour (240); header text in the bold gold (222); body
      text plain (250). Cells keep their inline styling.
- [ ] Honour each column's alignment.
- [ ] **Content width:** a column's natural width is its widest cell. If the
      whole table fits the available width it is drawn at that width and is not
      stretched.
- [ ] **Compress and wrap:** if it does not fit, search for the smallest per-row
      line budget H for which every cell fits the width; each column then takes
      exactly the width it needs for H lines, so no column is starved while
      another keeps slack. Leftover width is spent on the drops that shrink the
      tallest rows. If even the word floors overflow, the widest columns are
      squeezed and words break.
- [ ] Clip a table narrower than its chrome (no horizontal scroll).
- [ ] A row is as tall as its tallest cell; cells top-align.
- [ ] Incremental: a finalised table's cell blocks are created once and are not
      rebuilt when a later chunk arrives.

### Non-Functional

- Parser stays pure: no I/O, never raises, total over any input.
- View leak-clean under `make test-leak`.
- Column widths are resolved from cached per-cell natural and word widths, so
  re-measuring at the same width does not rebuild cells.
- Portability: macOS and Linux, FPC 3.3.1, `{$mode delphi}`.

## Contracts & Interfaces

> Contracts are Pascal type declarations. No method bodies.

### Public API

Parser (additions to `hildegard.helper.markdown`):

```pascal
type
  TMdBlockKind = (
    mbBlank, mbParagraph, mbHeading, mbListItem, mbCodeFence, mbQuote, mbRule,
    mbTable);            { a GFM pipe table }

  TMdAlign = (maNone, maLeft, maCenter, maRight);

  { One table row: a run of spans per column. }
  TMdTableRow = array of TMdSpanArray;
  TMdTableRows = array of TMdTableRow;

  TMdBlock = record
    Kind: TMdBlockKind;
    Level: Integer;
    Language: UnicodeString;
    Ordered: Boolean;
    Ordinal: Integer;
    Spans: TMdSpanArray;
    { mbTable only. Head and every body row carry exactly Length(Align) cells. }
    Head: TMdTableRow;
    Align: array of TMdAlign;
    Rows: TMdTableRows;
  end;
```

View (additions to `hildegard.helper.tui.markdownview`):

```pascal
type
  { One mbTable block: a rounded grid whose columns are sized to content and
    whose cells wrap when the table is wider than the available width. }
  TTableBlock = class(TWidget)
  public
    constructor Create(const ABlock: TMdBlock; const ATheme: TMdTheme);
    destructor Destroy; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    { Instrumentation: total layout builds across the cells. }
    function LayoutBuilds: Integer;
  end;
```

`TMarkdownView` is unchanged in its public surface: it maps `mbTable` to a
`TTableBlock` internally.

### Data Contracts

- **Chrome.** For `n` columns the grid uses `3n + 1` columns: a border plus one
  space each side of every column. The grid's total width is
  `sum(widths) + 3n + 1`.
- **Height.** With `R` rows of heights `rowH`, the grid is `sum(rowH) + R + 1`
  rows tall: a top border, a rule before every row but the first, and a bottom
  border.
- **Natural width.** A column's natural width is the display width of its widest
  cell (measured on the rendered spans, so an inline-code chip counts its
  padding).
- **Word floor.** A column's floor is the width of its longest whitespace-
  delimited run, at least 1 and at most its natural width.
- **Width policy.** If `sum(natural) <= avail - (3n + 1)` the natural widths are
  used and the table stops. Otherwise, for a per-row line budget `H`, a column's
  width is the smallest width at which all of its cells fit within `H` lines
  (never below a cell's longest word); the smallest `H` whose widths fit the
  available width is found by binary search, and the columns take those widths.
  Any leftover is then spent on the line drops that shrink the tallest rows, so
  the total height falls further. If even the word floors overflow, the widest
  columns are reduced in turn and words break.
- **Alignment.** `maCenter`/`maRight` map to `TTextBlock.Align`; `maNone` and
  `maLeft` are left.
- **Cell text** has whitespace collapsed, like other inline content.

### Event Contracts

- None. The parser is pure; the view is drawn synchronously.

## Architecture

### Prior Art & Reuse

- `hildegard.helper.markdown.InlineSpans` - cell content.
- `hildegard.helper.tui.text.TTextBlock` - per-cell wrapping, alignment, and
  clipping (`WrapWidth`, `Align`), plus `LineCountAt` - a non-caching line count
  so the width search can probe many widths without disturbing the wrap cache.
  The table composes text blocks rather than wrapping text itself.
- `hildegard.helper.tui.surface` - `FillRect`/`PutText`/`PutCh` for the grid.
- The existing `TMarkdownView` block stack and its span-to-attribute helpers.
- No FPC facility covers table layout; the width policy is the gap.

### Component Boundaries

- **Responsibilities:** parse a pipe table into cells and alignments; resolve
  column widths; wrap cells; draw the grid.
- **Dependencies:** the markdown parser, `TTextBlock`, `TWidget`, `ISurface`.
- **Side effects:** none beyond drawing.

### Data Flow

1. **Detect.** On a delimiter row that follows the header (the open paragraph's
   last line), open `mbTable` and append the delimiter; the preceding paragraph
   lines (if any) finalise first.
2. **Accumulate.** Each further line with an unescaped `|` appends; anything else
   finalises the table.
3. **Finalise.** Split the header, delimiter, and body rows into cells and
   inline-parse each; pad/truncate to the header's column count.
4. **Map.** The view builds a `TTableBlock` once for the finalised block.
5. **Layout.** `Measure` resolves the column widths from the cached per-cell
   natural/floor widths, sets each cell's `WrapWidth`, and sums the row heights.
6. **Draw.** `Render` draws the frame, a rule between every row, the cells, and
   the column separators.

Block terminator (additions):

| Open block | Terminator |
| --- | --- |
| Table | a blank line, a line with no unescaped `|`, or EOF |

### Integration Patterns

- Synchronous and single-threaded, like the rest of the toolkit.
- Ownership: the view owns each `TTableBlock`; the table owns its cell text
  blocks and frees them in `Destroy`.

## Validation Rules

### Input

- A delimiter row with no `|`, or whose cell count differs from the header's, is
  not a table; the lines render as a paragraph.
- A header row must contain an unescaped `|`.
- `\|` is a literal pipe; other backslashes pass through to the inline scanner.
- A row with no cells after splitting yields empty cells (padded).

### Output Guarantees

- A table block has at least one column; `Head`, every body row, and `Align` all
  have the same length.
- `Parse`/`Blocks` never raise.

## Error Handling

- None surfaced. Malformed tables degrade to literal paragraph text.

## Testing Requirements

### Unit Tests (`tests/test_markdown.pas`)

- [ ] `TestTableDetected` (header + delimiter + rows)
- [ ] `TestTableAlignmentParsed` (`:---`, `:---:`, `---:`)
- [ ] `TestTableEscapedPipe`
- [ ] `TestTablePadsAndTruncatesCells`
- [ ] `TestTableEndsAtBlankLine`
- [ ] `TestTableEndsAtNonRowLine`
- [ ] `TestTableHeaderAfterParagraph`
- [ ] `TestTableInlineStylesInCells`
- [ ] `TestDelimiterWithoutPipeIsParagraph`
- [ ] `TestIncrementalTableMatchesFullParse`
- [ ] `TestNoLeaks` (via `make test-leak`)

### Unit Tests (`tests/test_markdownview.pas`)

- [ ] `TestTableRendersGrid`
- [ ] `TestTableIsContentWidth`
- [ ] `TestTableCompressesAndWraps`
- [ ] `TestTableBalancesForLeastHeight` (a short-content column is widened
      rather than starved, minimising the table height)
- [ ] `TestTableAlignment`
- [ ] `TestTableUsesTheThemeColours`
- [ ] `TestTableCellsAreNotRebuilt`
- [ ] `TestNoLeaks` (via `make test-leak`)

## Performance Targets

- Natural and floor widths are computed once per cell at build time.
- A finalised table is not rebuilt when later chunks arrive.

## Security Considerations

- Input is untrusted model output; it is never evaluated and no terminal escapes
  are built beyond cell attributes. A cell's link target is stored as data and
  not followed.

## Success Criteria

### Functional

- [ ] A narrow table is narrower than its container; an over-wide table wraps
      within it.
- [ ] Every contract implemented; `make check` passes.

### Quality

- [ ] No memory leaks.
- [ ] The view depends on the toolkit only through `TTextBlock`/`TWidget`.

## Future Considerations

- A column max-width hint, table captions, and nested block content in cells
  (deliberately out: GFM cells are inline-only).
- Horizontal scroll for a table that cannot fit.
