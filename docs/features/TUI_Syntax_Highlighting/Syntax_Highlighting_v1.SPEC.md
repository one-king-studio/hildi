# Component Specification: Syntax Highlighting v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Extends:** [Markdown v1](../TUI_Harness/Markdown_v1.SPEC.md) (the theme) and
[Markdown View v1](../TUI_Harness/Markdown_View_v1.SPEC.md) (the fenced-code
box).

## Purpose

Lexical syntax highlighting for fenced code blocks: a pure tokenizer turns code
text into spans of token kinds, and the markdown view maps those kinds to theme
roles and draws them inside the existing code box. Strings, comments, numbers,
keywords, and builtins become distinct; everything else stays the code
foreground.

It is a **viewer-grade** tokenizer, not a semantic engine: a left-to-right scan
over literal delimiters, driven by per-language rule tables. No regex engine
(untrusted input), no LSP, no vendored parser. The design borrows the *ideas* of
SynEdit's highlighters, not their code (see Prior Art).

## Requirements

### Functional

**Tokenizer** (`hildegard.helper.syntax`)

- [ ] `HighlightCode(text, language)` returns spans of `TSynToken` kinds,
      covering the input exactly once and in order.
- [ ] A language is matched case-insensitively from the **first
      whitespace-delimited word** of the fence info string, against a canonical
      name and its aliases (`pas`/`pascal`, `sh`/`bash`/`shell`, `py`/`python`,
      `json`, `sql`).
- [ ] An unknown or empty language yields **one `stPlain` span** — the block is
      rendered exactly as today (the feature is strictly additive).
- [ ] The scan recognises, in order: line comments, block comments, strings,
      numbers, identifiers (keyword/builtin/plain), and single plain characters.
      A delimiter opens only when the scanner is not already inside a string or
      comment, so a comment marker inside a string is string text and vice
      versa.
- [ ] Block comments nest when the rule says so (Pascal `{ }` / `(* *)`).
- [ ] Strings respect an escape character and/or a doubled closer (SQL and
      Pascal double the quote), and may be flagged multi-line.
- [ ] Identifiers are looked up case-insensitively or sensitively per language
      (`Pascal`/`SQL` insensitive; `shell`/`Python`/`JSON` sensitive).
- [ ] Numbers scan a digit run with `.`, exponent, and per-language prefixes
      (Pascal `$` hex, `%` binary, `&` octal).
- [ ] Adjacent plain characters coalesce into a single span.
- [ ] Pure and total: never raises, never loops unboundedly (a single
      left-to-right scan with a documented length cap).

**Theme** (`tui.widgets.mdtheme`)

- [ ] `TMdTheme` gains code-token roles: `CodeComment`, `CodeString`,
      `CodeNumber`, `CodeKeyword`, `CodeBuiltin`. `stPlain` uses the existing
      `CodeBackdrop` foreground.
- [ ] `CodeTokenAttr(token, theme)` returns the role's foreground on the code
      box's sunken background (never `sfScreenBg`), so the surface survives.

**View** (`hildegard.helper.tui.markdownview`)

- [ ] `MakeBlock` for `mbCodeFence` runs `HighlightCode` on the fence text with
      the fence language and maps each token span to a `TSpan`, built once when
      the block finalises.
- [ ] The code box, border, language label, padding, and width are unchanged.

### Non-Functional

- [ ] Pure: no I/O, no terminal, no theme dependency in the tokenizer.
- [ ] Leak-clean under `make test-leak`; no exceptions on any input.
- [ ] Computed once per finalised block, not per frame.
- [ ] Portability: macOS and Linux, FPC 3.3.1, `{$mode delphi}`.

## Contracts & Interfaces

> Contracts are Pascal type declarations. No method bodies.

### Public API

```pascal
unit hildegard.helper.syntax;

type
  { A lexical token kind. The role a code fragment plays, not its semantics. }
  TSynToken = (stPlain, stComment, stString, stNumber, stKeyword, stBuiltin);

  TSynTokenSpan = record
    Text: UnicodeString;
    Kind: TSynToken;
  end;
  TSynTokenSpans = array of TSynTokenSpan;

  { A delimiter pair: a block comment ({ } / (* *) / /* */) or a string quote
    ('…', "…", `…`). Escape is the in-delimiter escape char (#0 = none);
    Doubled means the closer written twice is a literal (SQL/Pascal ''); Nested
    means the closer nests (Pascal block comments); Multiline lets a string span
    lines. }
  TSynDelim = record
    Open, Close: UnicodeString;
    Escape: Char;
    Doubled: Boolean;
    Nested: Boolean;
    Multiline: Boolean;
  end;
  TSynDelimArray = array of TSynDelim;

  { One language's lexical rules. Pure data; no code. }
  TSynLang = record
    Name: string;
    Aliases: array of string;
    CaseSensitive: Boolean;
    LineComments: array of UnicodeString;   { '//', '#', '--' }
    BlockComments: TSynDelimArray;          { { }, (* *), /* */ }
    Strings: TSynDelimArray;                { '…', "…", `…`, '''…''' }
    Keywords: array of UnicodeString;
    Builtins: array of UnicodeString;
    NumberPrefixes: array of Char;          { Pascal '$', '%', '&' }
  end;

{ Highlight AText as ALanguage. An unknown or empty language yields one stPlain
  span. Pure and total. }
function HighlightCode(const AText: UnicodeString;
  const ALanguage: UnicodeString): TSynTokenSpans;

{ The rule table for a fence tag (canonical name or alias, case-insensitive). }
function SynLanguage(const AName: UnicodeString): TSynLang;
{ True when AName names a supported language. }
function SynLanguageKnown(const AName: UnicodeString): Boolean;
```

Theme additions (`tui.widgets.mdtheme`):

```pascal
type
  TMdTheme = record
    { …existing fields… }
    CodeComment: TAttr;
    CodeString: TAttr;
    CodeNumber: TAttr;
    CodeKeyword: TAttr;
    CodeBuiltin: TAttr;
  end;

{ The attribute for a code token: its role's foreground on the code surface
  (CodeBackdrop.Bg, no sfScreenBg). }
function CodeTokenAttr(const AToken: TSynToken;
  const ATheme: TMdTheme): TAttr;
```

### Data Contracts

- **Coverage.** Concatenating a result's `Text` reproduces the input exactly;
  kinds partition it. No empty spans are emitted.
- **Rule tables are data.** Adding a language is a table (a `TSynLang` constant)
  plus its tests — no new code path. `SynLanguage` returns a copy.
- **Delimiter precedence.** At a position the scanner tries, in order: each line
  comment marker, each block comment opener, each string opener (longest opener
  first within each group). Inside a string/comment the only special sequence is
  that delimiter's own close (and escape/doubling).
- **Proposed role colours** (subject to the design-companion review, per the
  palette workflow): comment `245` dim grey, string `114` green, number `215`
  orange, keyword `213` magenta bold, builtin `116` cyan; `stPlain` is
  `CodeBackdrop`'s `252`. All sit on the `233` sunken surface.

### Event Contracts

- None. Pure function; the view draws synchronously.

## Architecture

### Prior Art & Reuse

- **SynEdit** (`~/Code/lazarus/components/synedit`, present locally) is the
  closest prior art and the ladder was climbed against it. **Licence: MPL-1.1 /
  GPL-2.0; this project has none, so SynEdit is a design reference only — no code
  is copied.** Taken as ideas: the per-first-character dispatch (`fProcTable` —
  an FPC `case` over the first char compiles to the same jump table); the token
  model (`GetToken`/`GetTokenPos`/`GetTokenAttribute`); the named attribute roles
  (`Comment`, `String`, `Number`, `Keyword`, `Symbol`, `Identifier`); and
  longest-keyword-first matching. **Deliberately not taken:** the per-character
  hash plus per-hash function table (`mHashTable`/`fIdentFuncTable`) — built to
  disambiguate thousands of keywords at editor speed; our sets are small, so a
  sorted list with binary search is simpler and fast enough. The per-line range
  store (`TSynHighlighterRangeList`) — built to restart a highlighter
  mid-document; our blocks are immutable and scanned once. The
  attribute-modifier/priority merge — unneeded against a fixed palette.
- **Reuse `tui.widgets.mdtheme.TMdTheme`** for the roles and
  `hildegard.helper.tui.text.TTextBlock` for drawing; the tokenizer feeds the
  existing span pipeline and adds no renderer.
- **Reuse the RTL** (`SysUtils`, `UnicodeString`, a sorted `TStringList` for the
  keyword/builtin lookup). No regex engine: the markdown parser already refuses
  regex on untrusted output, and this holds the same line.

The gap: the per-language rule tables, the scanner, and the kind-to-role
mapping.

### Component Boundaries

- **Responsibilities:** rule tables; lexical scanning; token-kind output; the
  theme mapping.
- **Dependencies:** the syntax unit is standalone (RTL only); the theme mapping
  lives in `tui.widgets.mdtheme`; the view wires them.
- **Side effects:** none; no I/O, no terminal.

### Data Flow

1. **Fence.** The parser already captures the info string; the view takes its
   first word as the language.
2. **Select.** `SynLanguage` resolves the language; unknown → plain.
3. **Scan.** A single left-to-right pass over the text; at each position the
   scanner matches a comment, string, number, or identifier start, else consumes
   one plain char. Identifier characters are looked up in the language's keyword
   and builtin sets.
4. **Emit.** Spans of `(text, kind)`, coalescing plain runs.
5. **Map.** The view maps each kind via `CodeTokenAttr` and draws the spans in
   the existing code box.

### Integration Patterns

- Synchronous and pure. The tokenizer owns nothing and frees nothing.
- Ownership: the view owns the `TTextBlock` it builds from the token spans.

## Validation Rules

### Input

- Any string, any language tag. Unknown tags and malformed input degrade to
  plain spans (never an error).
- An unterminated string/comment runs to the end of the block (no error), as the
  code fence already guarantees a complete block.

### Output Guarantees

- Spans are in order, non-empty, and cover the input exactly.
- `HighlightCode` terminates for any input (bounded by the input length).

## Error Handling

- None surfaced. The tokenizer is a total function; malformed input is plain
  text.

## Testing Requirements

### Unit Tests (`tests/test_syntax.pas`)

- [ ] `TestPlainWhenLanguageUnknown` (unknown/empty → one `stPlain` span)
- [ ] `TestPascalKeywordStringCommentNumber`
- [ ] `TestShellKeywordAndComment`
- [ ] `TestPythonTripleQuotedString`
- [ ] `TestJsonStringNumberKeyword`
- [ ] `TestSqlQuotedStringAndComment`
- [ ] `TestCommentMarkerInsideStringIsString` (the classic edge battery)
- [ ] `TestStringMarkerInsideCommentIsComment`
- [ ] `TestDoubledQuoteIsLiteral` (SQL/Pascal `''`)
- [ ] `TestNestedBlockComment` (Pascal)
- [ ] `TestEscapeInString`
- [ ] `TestIdentifierLookupIsCaseAware`
- [ ] `TestNumberPrefixes` (Pascal `$`, `%`, `&`)
- [ ] `TestSpansCoverInputExactly`
- [ ] `TestLongestOpenerWins` (`/*` before `/`, `--` before `-`)
- [ ] `TestBoundedScan` (pathological input terminates)
- [ ] `TestNoLeaks` (via `make test-leak`)

### Unit Tests (`tests/test_markdown.pas`)

- [ ] `TestCodeTokenAttrUsesTheSurface` (each role's fg, bg = `CodeBackdrop.Bg`,
      no `sfScreenBg`)

### Unit Tests (`tests/test_markdownview.pas`)

- [ ] `TestCodeFenceIsHighlighted` (a ```pascal block shows distinct
      comment/string/keyword attributes on the sunken surface)
- [ ] `TestUntaggedFenceIsUnchanged` (no language → the previous monochrome box)
- [ ] `TestCodeFenceHighlightIsBuiltOnce` (a finalised block is not rebuilt)

## Performance Targets

- One linear pass over the block text; the keyword/builtin lookup is a sorted
  binary search (O(log n) per identifier).
- Computed once per finalised block; a 200-line block well within the 5 ms
  budget, asserted as work in `make check` and reported by `make bench`.

## Security Considerations

- Input is untrusted model output. No regex engine, so no ReDoS; no evaluation,
  no I/O, no terminal escapes beyond cell attributes. The scan is bounded by the
  input length.

## Success Criteria

### Functional

- [ ] A tagged fence highlights; untagged/unknown fences are unchanged.
- [ ] Every contract implemented; `make check` passes.

### Quality

- [ ] No memory leaks.
- [ ] Adding a language is a rule table plus tests, not a code path.
- [ ] The palette is previewed in the design companion before landing.

## Future Considerations

- More languages (C, Rust, Go, YAML, Markdown) as further rule tables.
- A `stSymbol`/operator role, and bracket matching — only if the medium rewards
  it.
- The tokenizer is the seam a semantic engine would slot behind, if ever needed;
  it would not change the view.
