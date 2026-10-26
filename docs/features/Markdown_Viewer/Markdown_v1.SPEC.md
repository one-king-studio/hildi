# Markdown v1 — Specification

**Feature:** [Markdown Viewer](FEATURE.md)
**Status:** Specified, not implemented.

## 1. Purpose and boundary

Extract markdown parsing into a **pure module** (`src/markdown/`) that produces a typed
AST, and add a **file viewer** that renders one. The module knows nothing about cells;
the viewer knows nothing about parsing.

One rule decides every question below: **would this compile with only the RTL on the
search path?** If yes it belongs in the module; if no it belongs to a consumer.

## 2. Prior art and reuse

Per `ponytail.md`, climb before building:

| Existing | Reuse how |
| --- | --- |
| `hildegard.helper.markdown` (1,219 lines, 676 test lines) | **The source.** The block scanner, inline scanner, wrap logic and table layout are moved, not rewritten. This is a refactor with a purity boundary, not a new parser. |
| `tests/test_markdown.pas` (676 lines) | **The acceptance bar.** Its assertions must pass against the new module with import changes only. |
| `tui.widgets.markdownview` (1,158 lines) | Keeps its drawing; gains the theme it currently imports. |
| `src/shell/`, `src/async/`, `src/changes/` | The module layout and `-standalone` target convention, copied. |
| `src/tui/core/tui.grapheme` | Width/cluster helpers the viewer needs. **Not** importable by the module — it is `tui.*`. See §4.4. |

Nothing new is invented for markdown parsing. Nothing new is invented for rendering.

## 3. Module layout

```
src/markdown/
  markdown.types.pas     AST only: blocks, spans, kinds, alignment
  markdown.inline.pas    lexer + pairer (moved from ScanInline)
  markdown.blocks.pas    block scanner (moved from ProcessLine and friends)
  markdown.stream.pas    the segmenter's open-kind state machine
  markdown.parse.pas     the entry point: batch and incremental
  markdown.render.pas    AST -> plain text (no styling)
```

Unit names carry the directory as a prefix, matching `shell.*`, `async.*` and `changes.*`.
Public types are declared in `markdown.types`; every other unit may be considered internal
but stays public for testability.

## 4. Contracts

### 4.1 The AST

Unchanged in shape from today's, deliberately: the AST already works, and a new shape would
mean silently changing behaviour.

```pascal
type
  TMdBlockKind = (
    mbParagraph, mbHeading, mbListItem, mbCodeFence, mbQuote, mbRule, mbTable);

  TMdInlineStyle = (misBold, misItalic, misCode, misStrike, misLink);
  TMdInlineStyles = set of TMdInlineStyle;

  TMdSpan = record
    Text: UnicodeString;
    Styles: TMdInlineStyles;
    Link: UnicodeString;      // target for misLink; '' otherwise
  end;
  TMdSpanArray = array of TMdSpan;

  TMdAlign = (maNone, maLeft, maCenter, maRight);
  TMdAlignArray = array of TMdAlign;

  TMdTableRow = array of TMdSpanArray;
  TMdTableRows = array of TMdTableRow;

  TMdBlock = record
    Kind: TMdBlockKind;
    Level: Integer;           // heading level; quote nesting depth
    Language: UnicodeString;  // mbCodeFence only
    Ordered: Boolean;         // mbListItem only
    Ordinal: Integer;         // mbListItem: the marker as written
    Spans: TMdSpanArray;      // inline content
    Head: TMdTableRow;        // mbTable only
    Align: TMdAlignArray;     // mbTable: one per column
    Rows: TMdTableRows;       // mbTable: every row has Length(Align) cells
  end;
  TMdBlockArray = array of TMdBlock;
```

**Requirement: the AST carries no presentation.** No `TAttr`, no colour, no theme, no
escape sequence. A test asserts `markdown.types` does not `uses tui.base`.

**Requirement: `TMdBlock` is a value type.** Records with managed fields, so a consumer may
copy freely; no pointers, no ownership protocol.

### 4.2 The parser

```pascal
type
  TMarkdownParser = class
  public
    function Parse(const AText: string): TMdBlockArray;
    procedure Reset;
    procedure Append(const AChunk: string);
    procedure Finish;
    function Blocks: TMdBlockArray;
  end;

{ The batch form: one call, same tree. }
function ParseMarkdown(const AText: string): TMdBlockArray;
```

**Requirement: batch and streamed produce the identical tree.** For any text `T` and any
chunking of `T`:

```
ParseMarkdown(T)  ==  (Reset; for each chunk Append; Finish; Blocks)
```

"Identical" means same block count, same kinds, same levels, same span text, styles and
links, in order. Asserted over a corpus (§7), not one document.

### 4.3 Streaming: the segmenter decides WHERE, not WHAT

`markdown.stream` tracks an open-kind and decides only where a block **ends**. Each closed
segment goes through the full block scanner, so every block kind works when streamed without
the streaming layer knowing about it.

```pascal
type
  TMdOpenKind = (okNone, okFence, okText, okList, okTable, okQuote);
```

Closure rules, each of which is a bug if wrong:

| Kind | Closes when |
| --- | --- |
| `okFence` | a line begins with the opening fence marker |
| `okTable` | a line contains no `|` |
| `okList` | a non-marker, non-indented line arrives. **A blank line does not close it** |
| `okQuote` | the `>` prefix stops. A blank line does not close it |
| `okText` | a blank line |

**Requirement: a `---` directly under open text is a setext underline, not a rule.** The
segmenter appends it to the open segment and lets the block layer decide.

### 4.4 Purity

```
make markdown-standalone
```

compiles the module with **only** `-Fu$(SRC)/markdown` on the search path. A dependency on
`tui.*` or `hildegard.helper.*` fails the build. This is the same gate as
`shell-standalone` and `tui-standalone`, and it is the feature's central claim.

**Consequence for width.** The inline scanner must not measure display width — that is a
terminal concern (`tui.grapheme.StringWidth`). Wrapping belongs to the renderer. The parser
produces spans; the viewer wraps them.

### 4.5 The plain renderer

```pascal
function RenderPlain(const ABlocks: TMdBlockArray; AWidth: Integer): TStringArray;
```

AST → unwrapped-in-content, width-wrapped plain text. No styling characters, no colours.
It exists for two reasons: it is the cheapest proof the AST is consumable without a
terminal, and it gives tests a diffable failure message.

## 5. Theme extraction

`TMdTheme`, `DefaultMdTheme`, `StyleFor`, `BlockAttr` and `MdAttr` move **out** of the
parser into the view layer:

```pascal
{ src/tui/widgets/tui.widgets.mdtheme.pas }
type
  TMdTheme = record ... end;
function DefaultMdTheme: TMdTheme;
function MdAttrFor(const AStyles: TMdInlineStyles; const ATheme: TMdTheme): TAttr;
function MdBlockAttr(AKind: TMdBlockKind; ALevel: Integer;
  const ATheme: TMdTheme): TAttr;
```

**Requirement: no signature change beyond the names.** `StyleFor` becomes `MdAttrFor` only
because `StyleFor` is too generic for a unit that anything might `uses`; callers change one
identifier.

## 6. The file viewer

```pascal
{ src/tui/widgets/tui.widgets.fileviewer.pas }
type
  TFileViewKind = (fvMarkdown, fvPlain);

  TFileViewer = class(TWidget)
  public
    { Load a path. Markdown by extension (.md, .markdown), plain otherwise. A read
      failure renders the error as text rather than raising: a viewer that cannot
      open a file must still draw. }
    procedure Open(const APath: string);
    procedure Reload;
    property Kind: TFileViewKind read FKind;
    property Path: string read FPath;
    property ScrollY: Integer read FScrollY;
  end;
```

**Requirement: v1 reads.** No editing, no search, no jump-to-heading, no syntax
highlighting inside fences.

**Requirement: a file too large to read is truncated with a notice**, not refused and not
loaded whole.

**Requirement: non-markdown files render as plain text.** `favicon.ico` shows as text, not
as an error and not as a blank pane.

## 7. Testing strategy

What must be tested, not how:

1. **Purity** — `make markdown-standalone` passes; `markdown.types` has no `tui` in `uses`.
2. **Equivalence corpus** — ~12 documents, each parsed batch and in several chunk sizes,
   asserting identical trees. Documents chosen for *seams*: a fence containing `---`, a
   table immediately after a list, a setext underline under a paragraph, a list item
   followed by a blank line and more list, a table whose delimiter follows a bullet.
3. **Every existing assertion** in `tests/test_markdown.pas` survives the move.
4. **Block-pass order**, pinned structurally: a declared order that a reorder fails.
5. **The plain renderer**, so the AST is proven consumable with no terminal.
6. **Viewer**: reads a markdown file, reads a plain file, a missing file draws an error,
   a large file truncates.

## 8. Performance

| Concern | Bound |
| --- | --- |
| Parse, 40 KB | comparable to today (the scanners are moved, not rewritten) |
| Per streamed update | O(open block), not O(document) |
| First frame of a 40 KB file | no visible stall; the viewer may paint before wrapping |

No timing assertion in `make check` — wall-clock budgets flake on a loaded machine. The
suite asserts *work* (block counts, call counts); `make bench` may report time.

## 9. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| The refactor changes behaviour silently | The existing 676 test lines are the bar; any changed assertion is treated as a regression and justified individually. |
| Theme extraction breaks every render call | One mechanical rename (`StyleFor` → `MdAttrFor`), done in the same commit as the move. |
| Pass order drifts | §7.4 pins it structurally. |
| Two parsers coexist | `hildegard.helper.markdown` is deleted. The old name is not kept as an alias. |
| The viewer grows into an editor | Out of scope in §6, and the acceptance criteria name only reads. |

## 10. Open questions

1. **Does the viewer live in the harness TUI or a separate binary?** The dashboard precedent
   is a separate binary; a viewer is more naturally a pane in the TUI. v1 assumes a widget;
   the wiring is a separate decision.
2. **Setext headings** are currently unparsed (`grep setext` → 0). In or out of v1? The
   source treats them as a block pass with load-bearing position (after lists, before
   rules). Recommend **in** — it is one pass and a README uses them.
3. **Where does `mbBlank` go?** It exists in the enum today and is never emitted. Either
   emit it (so a consumer can render spacing) or delete it. Recommend delete.
