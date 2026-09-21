# Component Specification: Markdown Colourisation

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildegard.helper.markdown` turns a supported subset of markdown into blocks of
styled spans, and maps block kinds and inline styles to text attributes (a
colouriser). It is deliberately **not** a renderer: it produces data that
`TTextBlock` already knows how to draw. This keeps parsing pure and testable, and
keeps the UI free of markdown knowledge.

The input is text the model produces (assistant output, file previews), so the
parser must never raise on malformed input; unsupported syntax renders literally.
The parser also supports incremental appends so a streaming response does not
re-parse completed content.

## Requirements

### Functional

- [ ] Parse a defined subset into blocks: paragraphs, headings (levels 1-6),
      bullet and ordered list items, blockquotes, fenced code (with an info
      string), horizontal rules, and blank separation.
- [ ] Parse inline within non-code blocks: bold, italic, inline code, strikethrough,
      and `[text](url)` links.
- [ ] Produce blocks of styled spans (`TMdSpan`), preserving the literal text
      with markup removed.
- [ ] Map inline styles and block kinds to `TAttr` through a theme, with a
      default theme.
- [ ] Support incremental append: completed blocks are final; only the trailing
      unstable block is re-parsed.
- [ ] Render unrecognised or malformed syntax literally rather than failing.

### Non-Functional

- Portability: macOS and Linux, FPC 3.3.1, `{$mode delphi}`.
- Reliability: leak-clean under `make test-leak`; no exceptions on malformed
  input.
- Performance: incremental append is O(len of the unstable tail), not O(document).
- Dependency: none beyond the toolkit's base types and the RTL.

## Contracts & Interfaces

> Contracts are Pascal type declarations. No method bodies.

### Public API

```pascal
unit hildegard.helper.markdown;

uses
  hildegard.helper.tui.base;   { TAttr }

type
  TMdBlockKind = (
    mbBlank,       { a run of blank lines separates blocks }
    mbParagraph,
    mbHeading,
    mbListItem,
    mbCodeFence,
    mbQuote,
    mbRule);

  TMdInlineStyle = (misBold, misItalic, misCode, misStrike, misLink);
  TMdInlineStyles = set of TMdInlineStyle;

  { A run of text with inline styling. Link carries the target for misLink. }
  TMdSpan = record
    Text: UnicodeString;
    Styles: TMdInlineStyles;
    Link: string;
  end;

  { A parsed block. Level is the heading level (1..6), list depth, or quote
    depth as applicable. Language is the code fence info string. }
  TMdBlock = record
    Kind: TMdBlockKind;
    Level: Integer;
    Language: string;
    Spans: array of TMdSpan;
  end;

  { Block kinds and inline styles mapped to cell attributes. }
  TMdTheme = record
    Heading: array[1..6] of TAttr;
    Paragraph: TAttr;
    ListBullet: TAttr;
    Quote: TAttr;
    Code: TAttr;         { fenced and inline code foreground }
    CodeBackdrop: TAttr; { fenced code block background }
    Link: TAttr;
    Rule: TAttr;
    Bold: TAttr;         { attribute deltas applied on top of the base }
    Italic: TAttr;
    Strike: TAttr;
  end;

  { The parser. Create once; Reset before a new document. }
  TMarkdownParser = class
  public
    constructor Create;
    destructor Destroy; override;

    procedure Reset;

    { Full parse of a complete document. }
    function Parse(const AText: string): TMdBlockArray;

    { Incremental: append a chunk of streamed text. Completed blocks are
      retained; only the trailing unstable block is re-parsed on access. }
    procedure Append(const AChunk: string);

    { All blocks known so far. The last block is "unstable" until the next
      Append proves it complete (blank line, closing fence, EOF). }
    function Blocks: TMdBlockArray;
  end;

  { The default theme (no terminal dependency; caller may override). }
  function DefaultMdTheme: TMdTheme;

  { Resolve a span's attributes from its inline styles and the theme. }
  function StyleFor(const AStyles: TMdInlineStyles; const ATheme: TMdTheme): TAttr;

  { Resolve the base attributes for a block kind and level. }
  function BlockAttr(AKind: TMdBlockKind; ALevel: Integer; const ATheme: TMdTheme): TAttr;
```

### Data Contracts

- Theme and span colours use `TAttr` from `hildegard.helper.tui.base`: 256-colour
  palette indices (0..255) plus rendition flags. Markdown styling therefore
  cannot exceed the terminal palette; truecolour is not required
  (`TUI_Core_v1.SPEC.md`).
- `TMdBlock.Kind` and `Level` follow the semantics in the type comment; code
  blocks never carry inline styles (their `Spans` have empty `Styles`).
- `TMdSpan.Text` is the literal text with markup tokens removed. Whitespace
  inside a paragraph is preserved as a single space on output.
- `Blocks` returns blocks in document order. `mbBlank` is only emitted when it
  separates two non-blank blocks or is insignificant; the renderer may skip it.

### Event Contracts

- None. The parser is synchronous and pure.

## Architecture

### Prior Art & Reuse

- **No FPC library covers markdown.** `fcl-*` supplies JSON, XML, CSS, PDF,
  Mustache, and OpenAPI, but not markdown. A minimal parser is therefore
  justified under the Ponytail ladder, after checking FPC user-contributed units
  for a reusable subset (record the result in the TODO).
- **Reuse `hildegard.helper.tui.base`** for `TAttr` so colourised spans feed
  `TTextBlock` directly.
- **Reuse the RTL** for string handling; no regex is needed for the chosen subset
  (line classification plus a small inline scanner).

The gap: the block/inline scanners, the span/attribute mapping, and incremental
stability.

### Component Boundaries

- **Responsibilities:** markdown subset -> typed blocks -> styled spans;
  theme mapping; incremental parse.
- **Dependencies:** `hildegard.helper.tui.base.TAttr`, `SysUtils`, `Classes`.
- **Side effects:** none; no UI, no I/O.

### Data Flow

1. **Input:** a document string, or chunks via `Append`.
2. **Block pass:** split into lines; classify each line (fence delimiter, heading,
   list marker, quote marker, rule, blank, else paragraph); accumulate paragraph
   and list/quote containers; code-fence content is taken verbatim until the
   closing fence.
3. **Inline pass:** for non-code blocks, scan for markup tokens and emit
   `TMdSpan` runs with `Styles` set; unmatched or malformed tokens are emitted as
   literal text.
4. **Mapping:** `BlockAttr` and `StyleFor` resolve attributes from the theme.
   The renderer combines block base attributes with span styles.
5. **Incremental:** `Append` accumulates into a tail buffer. On `Blocks`, the tail
   is re-parsed; a block is finalised when its terminator is seen (blank line for
   paragraph/list/quote, closing fence for code, EOF for the last block).

### Integration Patterns

- Synchronous/pure. The renderer decides layout and wrapping; the parser never
  touches the surface.
- Ownership: `TMarkdownParser` owns its buffers and returns arrays that the
  caller owns.

## Validation Rules

### Input

- Unterminated code fence at end of input is treated as a complete code block at
  EOF (no error).
- A heading with more than six `#` is a paragraph.
- Marker characters that are not at line start are literal text.
- Empty input yields zero blocks.

### Output Guarantees

- `Parse`/`Blocks` never raise for any input string.
- Markup removal is lossless for the visible text: the concatenation of span
  text equals the input with only markup tokens removed and inline whitespace
  collapsed.

## Error Handling

### Error Types

- None are surfaced. Malformed constructs degrade to literal text.
- Internal allocation failures propagate as exceptions (not handled specially).

### Error Contracts

- No error type crosses this boundary; callers may assume a total function.

## Testing Requirements

The parser is pure, so all tests are ordinary fpcunit cases with string in,
blocks out.

### Unit Tests (`tests/test_markdown.pas`)

- [ ] `TestEmptyInputYieldsNoBlocks`
- [ ] `TestHeadingLevels`
- [ ] `TestParagraphSplitsOnBlankLine`
- [ ] `TestBulletListItems`
- [ ] `TestOrderedListItems`
- [ ] `TestBlockquoteNesting`
- [ ] `TestFencedCodeIsVerbatim`
- [ ] `TestFencedCodeLanguageCaptured`
- [ ] `TestHorizontalRule`
- [ ] `TestInlineBoldItalicCode`
- [ ] `TestInlineLinkTargetCaptured`
- [ ] `TestUnterminatedFenceIsCodeAtEof`
- [ ] `TestMalformedMarkupRendersLiterally`
- [ ] `TestSevenHashesIsParagraph`
- [ ] `TestMarkerNotAtLineStartIsLiteral`
- [ ] `TestWhitespaceCollapsedInParagraph`
- [ ] `TestIncrementalAppendMatchesFullParse` (append the same text in chunks and
      compare `Blocks` to a single `Parse`)
- [ ] `TestCompletedBlocksAreNotReparsed` (observable via stable output across
      appends)
- [ ] `TestStyleForMapsEachInlineStyle`
- [ ] `TestBlockAttrMapsEachBlockKind`
- [ ] `TestNoLeaks` (enforced by `make test-leak`)

### Integration Tests

- [ ] `TestStyledSpansFeedTextBlock`: convert a parsed paragraph to `TTextBlock`
      spans and render to a `TSurfaceMemory`, asserting attributes land in cells
      (exercises the `TAttr` handoff with `TUI_Core`).

## Performance Targets

- Full parse is O(n) in input length for the supported subset.
- Incremental `Append` re-parses only the trailing unstable block; appending k
  chunks to build an n-character document is O(n), not O(n*k).

## Security Considerations

- Input is untrusted model output. The parser never evaluates content, never
  builds terminal escapes, and never follows links. Link targets are stored as
  data only; the renderer displays link text and ignores the target in v1.
- No filesystem, network, or process access.

## Success Criteria

### Functional

- [ ] All contracts implemented; unsupported syntax renders literally.
- [ ] Incremental appends produce the same blocks as a full parse.
- [ ] `make check` passes.

### Quality

- [ ] Every acceptance criterion in `FEATURE.md` maps to a passing test.
- [ ] Parser has no dependency on the toolkit beyond `TAttr`.
- [ ] No memory leaks.

## Future Considerations

- A `TMarkdownView` widget mapping blocks to a container of text blocks (fenced
  code gets a backdrop container, `mbRule` a rule widget).
- Syntax highlighting within fenced code (separate component; Pascal only at
  first).
- Tables, nested lists, reference links, setext headings (each a deliberate,
  documented subset extension).
- A link-follow action once mouse or a keybinding exists.
