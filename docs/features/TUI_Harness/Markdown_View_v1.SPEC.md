# Component Specification: Markdown View v1

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildegard.helper.tui.markdownview` draws a `TMdBlockArray` (from
`hildegard.helper.markdown`) as a vertical stack of styled text. It is the
render half of the markdown work: the parser produces the AST, this widget maps
it to `TTextBlock`s and block chrome (bullets, quote bars, a code backdrop, a
rule line).

It exists as a widget, not a helper that flattens to spans, because of
streaming: a finalised block's text block is created once and never touched, so
only the open tail is re-measured and re-clustered as chunks arrive. Flattening
the whole document into one `TTextBlock` would re-cluster everything on every
delta and reintroduce the O(n) per-chunk cost the parser was built to avoid.

## Requirements

### Functional

- [ ] Own a `TMarkdownParser`; `SetSource` parses a complete document,
      `AppendSource` feeds a streaming chunk, `FinishSource` ends the stream.
- [ ] Render a paragraph, heading (levels 1-6), list item (bullet and ordered),
      blockquote, fenced code, and rule, with the theme's attributes.
- [ ] Inline styles (bold, italic, code, strike, link) apply on top of the
      block's base attribute.
- [ ] A list item is prefixed with a bullet; an ordered item with its marker
      number. A quote is prefixed with a bar. A rule is a full-width line.
- [ ] A fenced code block's rows carry the code backdrop background across the
      full width, and its content is not inline-parsed.
- [ ] One blank row separates blocks, except between consecutive list items
      (a tight list).
- [ ] **Incremental:** a finalised block's child text block is created once and
      is not rebuilt when a later chunk arrives; only the open tail is updated.
- [ ] While streaming, the open tail is drawn as plain (unstyled) text.

### Non-Functional

- [ ] Leak-clean under `make test-leak`; no exceptions on any input.
- [ ] Portability: macOS and Linux, FPC 3.3.1, `{$mode delphi}`.
- [ ] Performance: `AppendSource` does O(new blocks + tail) work, not
      O(document); finalised blocks are never re-measured from scratch.

## Contracts & Interfaces

```pascal
unit hildegard.helper.tui.markdownview;

uses
  hildegard.helper.markdown, hildegard.helper.tui.base,
  hildegard.helper.tui.widget, hildegard.helper.tui.surface;

type
  TMarkdownView = class(TWidget)
  public
    constructor Create(const ATheme: TMdTheme); overload;
    constructor Create; overload;               { DefaultMdTheme }
    destructor Destroy; override;

    { Parse a complete document (resets the parser). }
    procedure SetSource(const AText: string);
    { Feed a streaming chunk. }
    procedure AppendSource(const AChunk: string);
    { End the stream: the open tail becomes a final block. }
    procedure FinishSource;

    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;

    { The number of finalised blocks currently drawn. Grows monotonically as a
      stream arrives; used to assert that blocks are not rebuilt. }
    property BlockCount: Integer read GetBlockCount;
  end;
```

The theme is the parser's `TMdTheme`; the view adds no colours of its own.

## Architecture

### Prior Art & Reuse

- `hildegard.helper.markdown` - the parser and theme (this widget is its only
  consumer).
- `hildegard.helper.tui.text.TTextBlock` - per-block wrapping and rendering; the
  view stacks text blocks rather than wrapping text itself.
- `hildegard.helper.tui.surface.FillRect` - the code backdrop and the rule line.
- `hildegard.helper.tui.widget.TWidget` - the measure/arrange/render protocol.

The gap: the per-block mapping (spans + chrome) and the vertical stack.

### Component Boundaries

- **Responsibilities:** own a parser, map blocks to child text blocks, stack and
  draw them.
- **Dependencies:** the markdown parser, `TTextBlock`, `TWidget`, `ISurface`.
- **Side effects:** none beyond drawing; owns and frees its children.

### Data Flow

1. `SetSource`/`AppendSource` feed the parser.
2. After each feed, children are created only for newly **finalised** blocks
   (`FinalizedCount`); the open tail (`TailText`) is written into one reused
   text block.
3. `Measure` sets each child's `WrapWidth` to the available width and sums the
   heights plus the inter-block gaps.
4. `Arrange` stacks the children top to bottom.
5. `Render` fills a code block's rows with the backdrop and draws each child;
   rules are drawn as a full-width line.

### Integration Patterns

- Synchronous and single-threaded, like the rest of the toolkit. `TWidget`.
- Ownership: the view owns every child text block and frees them in `Destroy`.

## Validation Rules

### Input

- Any string is accepted; malformed markdown is the parser's concern (it never
  raises). An empty source yields no children and a zero height.

### Output Guarantees

- `BlockCount` never decreases for a given source (append-only).
- A finalised child's spans are not recomputed when later chunks arrive.

## Error Handling

- None surfaced. Allocation failures propagate as exceptions.

## Testing Requirements

### Unit Tests (`tests/test_markdownview.pas`)

- [ ] `TestParagraphRenders` (text lands in the surface)
- [ ] `TestInlineBoldIsStyled`
- [ ] `TestHeadingUsesTheTheme`
- [ ] `TestBulletPrefix`
- [ ] `TestOrderedPrefix`
- [ ] `TestQuoteBar`
- [ ] `TestRuleIsFullWidth`
- [ ] `TestCodeBackdropFillsTheRow`
- [ ] `TestBlocksAreSeparatedByABlankRow`
- [ ] `TestTightListHasNoGap`
- [ ] `TestEmptySourceMeasuresZero`
- [ ] `TestStreamingTailIsPlainText`
- [ ] `TestFinalisedBlocksAreNotRebuilt` (a finalised block's text block is the
      same instance across appends)
- [ ] `TestFinishPromotesTheTail`
- [ ] `TestNoLeaks` (enforced by `make test-leak`)

## Performance Targets

- `AppendSource` is O(new blocks + tail), not O(document).

## Security Considerations

- Input is untrusted model output; the view never evaluates it and builds no
  terminal escapes beyond cell attributes.

## Success Criteria

### Functional

- [ ] All contracts implemented; every block kind renders.
- [ ] Finalised blocks are not rebuilt.
- [ ] `make check` passes.

### Quality

- [ ] No memory leaks.
- [ ] The view depends on the toolkit only through `TTextBlock`/`TWidget`.

## Future Considerations

- A `TMarkdownView` in the chat panel: replace the assistant block's plain
  `TTextBlock` with this widget.
- Collapsible code blocks, a copy affordance, and syntax highlighting (a
  separate tokenizer).
- Tables and the wider GFM surface.
