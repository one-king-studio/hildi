# Markdown v2 — Full document model

**Feature:** [Markdown Viewer](FEATURE.md)
**Status:** Specified, not implemented.
**Supersedes:** the shape constraint in `Markdown_v1.SPEC.md` §4.1.

## 1. Why v2 exists

v1 shipped a **flat block list**: `TMdBlockArray`, where each block is a record with a
`Spans` array. It parses the container correctly and renders it well, but it cannot
represent **structure**:

- a list inside a blockquote, or a nested list — `Level: Integer` is a depth counter, not
  nesting;
- a table cell containing anything but styled text;
- a footnote definition and the callout that refers to it — two nodes with a relation;
- a link reference used in three places — one definition, three uses.

The operator's goal is the deciding argument: **an AST that understands the whole document,
so a renderer or an interaction can address a specific kind of thing.** That needs nodes
with identity and nesting, not blocks with a depth field.

So v2 adopts the full node vocabulary. `TMdBlock` is retained only as a **compat adapter**
(§6) so the shipped TUI keeps working while consumers migrate one at a time.

## 2. What "full" means — the node vocabulary

Taken from the source design's `types.ts` (30 node types). This is the target, not a
subset: a feature is either in the vocabulary or explicitly listed as out in §9.

### Block nodes

| Node | Carries | Notes |
| --- | --- | --- |
| `document` | children | root; the whole parse is one tree |
| `paragraph` | children | inline children, not a span list |
| `heading` | `Level` (1..6), children | ATX and setext both produce this |
| `codeblock` | `Content`, `Language`, `Fenced` | fenced **and** indented code |
| `blockquote` | children | **recursive**: any block may nest inside |
| `list` | `Style` (ordered/unordered/checkbox), `Marker`, `Start`, children | recursive |
| `listitem` | `Checked` (checkbox only), children | recursive |
| `table` | `Align[]`, children | rows/cells are real nodes |
| `table_row` / `table_header` / `table_body` | children | structural, so a renderer can style the head separately |
| `table_cell` | `Align`, children | cells hold nodes, not spans |
| `horizontal_rule` | — | |
| `html_block` | `Content` | raw, preserved verbatim |
| `mathblock` | `Content`, `Language` | `$$ … $$` |
| `description_list` | children (`description_term`, `description`) | `term` / `: definition` |
| `footnote` | `Label`, children | the definition |
| `custom_block` | `Name`, children | `:::name … :::` |
| `reference` | `Label`, `Uri`, `Title` | a link-reference **definition** |

### Inline nodes

| Node | Carries |
| --- | --- |
| `text` | `Content`, and a `Formats` set (§3) |
| `codespan` | `Content` |
| `linebreak` | `Soft` (a hard break vs a soft wrap) |
| `hyperlink` | `Uri` — an autolink |
| `link` | `Uri`, `Title`, children; `Ref` when it came from a reference |
| `image` | `Uri`, `Title`, `Alt`; `Ref` for a reference |
| `html` | `Content` — inline raw HTML |
| `mathspan` | `Content` |
| `footnote_callout` | `Label` |
| `abbreviation` | `Label`, `Expansion` |

### Inline formatting

Carried **on the text node** rather than as wrapper nodes, matching the source:
`bold`, `italic`, `strikethrough`, `insert`, `delete`, `mark`, `superscript`,
`subscript`. That is 8 formats; v1 knew 5 (§3 explains the change).

## 3. The AST

```pascal
type
  TMdNodeKind = (
    { block }
    mnDocument, mnParagraph, mnHeading, mnCodeBlock, mnBlockQuote,
    mnList, mnListItem, mnTable, mnTableRow, mnTableHeader, mnTableBody,
    mnTableCell, mnHorizontalRule, mnHtmlBlock, mnMathBlock,
    mnDescriptionList, mnDescriptionTerm, mnDescription, mnFootnote,
    mnCustomBlock, mnReference,
    { inline }
    mnText, mnCodeSpan, mnLineBreak, mnHyperlink, mnLink, mnImage,
    mnHtml, mnMathSpan, mnFootnoteCallout, mnAbbreviation);

  TMdFormat = (mfBold, mfItalic, mfStrike, mfInsert, mfDelete, mfMark,
    mfSuper, mfSub);
  TMdFormats = set of TMdFormat;

  TMdListStyle = (lsOrdered, lsUnordered, lsCheckbox);
  TMdMarker = (lmInteger, lmAlphaLower, lmAlphaUpper, lmRomanLower,
    lmRomanUpper);

  TMdNode = record
    Id: Integer;                  { document order, from 1; 0 = none }
    Kind: TMdNodeKind;
    Parent: Integer;              { parent Id, 0 for the root }
    Children: TMdNodeArray;
    { text-ish content; '' for containers }
    Content: UnicodeString;
    { every attribute any kind needs, so the record stays a value type.
      Zero/'' means "not applicable". }
    Level: Integer;               { heading }
    Language: UnicodeString;      { codeblock, mathblock }
    Fenced: Boolean;              { codeblock }
    Style: TMdListStyle;          { list }
    Marker: TMdMarker;            { list }
    Start: Integer;               { list: first ordinal as written }
    Checked: Boolean;             { listitem }
    Uri: UnicodeString;           { link, image, hyperlink, reference }
    Title: UnicodeString;
    Ref: UnicodeString;           { link, image: the reference label used }
    Label: UnicodeString;         { footnote, footnote_callout, abbreviation, reference }
    Expansion: UnicodeString;     { abbreviation }
    Alt: UnicodeString;           { image }
    Align: TMdAlignArray;         { table }
    CellAlign: TMdAlign;          { table_cell }
    Formats: TMdFormats;          { text }
    Soft: Boolean;                { linebreak }
    SrcStart, SrcEnd: Integer;    { byte offsets into the source text }
  end;
  TMdNodeArray = array of TMdNode;

  TMdDocument = record
    Root: TMdNode;
    NodeCount: Integer;
  end;
```

**A flat array with integer links, not pointers.** `TMdNode` stays a value type
(`Children: TMdNodeArray` of child *copies* is rejected — see §3.1), so the document is
stored as one `TMdNodeArray` and `Children` holds **child ids**, not nested records.

Revised to be unambiguous:

```pascal
  TMdNode = record
    ...
    Children: array of Integer;   { child ids, in document order }
    ...
  end;

  TMarkdownDocumentParser = class
  public
    function Parse(const AText: string): TMdDocument;
    function Node(AId: Integer): TMdNode;       { a copy; ids are stable }
    function NodesOfKind(AKind: TMdNodeKind): TIntArray;
    function Root: Integer;
  end;
```

### 3.1 Why ids and not nested records

Nesting records inside records makes a **copy** of the whole subtree when a consumer asks
for one node — the exact cost that kills a per-frame renderer. With ids, `Node(id)` is a
copy of one record and `Children` is a small integer array. It also makes a node
**addressable across a re-parse** of the same text, which is what an interaction layer
needs.

**`Parent` is stored**, not derived, because "which blockquote is this paragraph in" is a
constant query in a renderer and a linear scan otherwise.

### 3.2 Identity, and what it is not

Ids are **document order, deterministic, assigned per parse**. They are not stable across
an edit. A consumer that must survive edits keys on `(SrcStart, SrcEnd)` — which is why
those exist. Do not persist an id.

### 3.3 Source offsets

`SrcStart`/`SrcEnd` are **byte offsets** into the UTF-8 source the parser was given, half
open. Every node has them, so a renderer can map a painted cell back to the document and
vice versa. This is an **addition beyond the source design**, which had ids but not spans;
without it "interact with a specific node" means "interact with a node we cannot locate".

For a streamed parse, offsets are relative to the concatenation of everything appended so
far.

## 4. Semantics the node model forces

These follow from nesting, and each changes something v1 pinned:

1. **A list item's content is nodes.** v1's `Spans` becomes: `listitem` → `paragraph` →
   text nodes. A loose item's second paragraph is a second `paragraph` child. **v1 flattened
   this**; v2 keeps it, so a renderer can draw the block structure of a list item.
2. **`ordinal` is per item, not per list.** `list.Start` holds the first number written;
   `listitem` does not carry a number, matching CommonMark and the source.
3. **A soft line break is a node.** v1 collapsed a paragraph's lines into one text run.
   v2 emits `linebreak(Soft: true)` so a renderer may join with a space or honour the wrap.
   The plain renderer joins soft breaks; the TUI may not.
4. **Inline emphasis is a format set on text.** Already true in v1 for 5 formats; v2 adds
   `insert`, `delete`, `mark`, `super`, `sub`. Kept as a set, not wrapper nodes, because
   the terminal has no nesting to express and a set makes `MdAttrFor` a pure function.

## 5. Security constraints that survive the port

The v1 spec correctly said a DOM sanitiser does not transfer. Three lessons do, and one is
new because our target is a terminal.

| Lesson | Applies? |
| --- | --- |
| **A linear scanner, never a backtracking regex.** The source measured a 6.8 s ReDoS on 200 characters of `[a](` repetition — model output is attacker-influenced. | **Yes, absolutely.** Every new inline feature must be a linear scan. A new inline parser is the single most likely place to reintroduce this. |
| **Pass order guarded explicitly.** The source had 16 passes; we have 10 and will have ~20. | **Yes.** v1 Phase 3 already pins the order as data. Every v2 pass is added to that array or the test fails. |
| **Escape at creation, not at render.** The source's XSS was an unpaired HTML tag stored raw. | **Partly.** We do not emit HTML, so `& < >` escaping is not the hazard. But `html_block`/`html` nodes hold **raw attacker-influenced text**; a consumer must never interpret them. State it on the node. |
| **URI scheme allow-listing belongs at node creation.** | **Yes, and it matters more in a terminal**: OSC 8 hyperlinks and some terminals execute actions from control sequences. A `javascript:` URI that reaches an OSC 8 emitter is a live injection. Allow-list `http https mailto` at creation; drop the rest. |

**Control characters.** A terminal renderer must strip C0/C1 control characters from every
text-bearing node. The source's DOM had no equivalent risk; we do. This is a v2 requirement
because the new vocabulary adds ways to smuggle text (`html`, `mathspan`, `custom_block`
names).

## 6. Migration: a compatibility adapter, with a deletion condition

The TUI renders `TMdBlockArray` today with 78 passing assertions. v2 must not break it in
one commit, and must not leave two parsers for good (the v1 risk table already forbids that).

```
markdown.tree     the node model + parser      (pure)
markdown.compat   TMdDocument -> TMdBlockArray  (pure, temporary)
markdown.render   RenderPlain over the tree     (pure)
```

`markdown.compat` projects the tree onto the v1 flat blocks **for nodes that have a v1
equivalent**, and reports which nodes it cannot represent:

```pascal
function BlocksForTuI(const ADoc: TMdDocument; out ALossy: Boolean): TMdBlockArray;
```

`ponytail:` — this adapter exists only until `tui.widgets.markdownview` renders the tree
directly. Its ceiling: it silently drops footnotes, references, abbreviations, math, HTML,
description lists, custom blocks, and all nesting beyond a depth counter. `ALossy` is the
honest signal, and `TestCompatIsLosslessForV1Corpus` asserts it is `False` for every
document in the v1 corpus — so the adapter cannot quietly become the product.

**Deletion condition:** the commit that migrates `markdownview` to the tree deletes
`markdown.compat` and its test. Recorded here so it is not forgotten.

## 7. Sequencing

Each phase leaves `make check` green. The corpus (§8) runs at every phase.

| Phase | Work | Why here |
| --- | --- | --- |
| 1 | `markdown.tree` — node model, id assignment, source offsets. `ParseTree` for the constructs v1 already parses. | The shape must be stable before features lean on it. |
| 2 | `markdown.compat` + repoint `markdownview`. | Proves the tree can express everything v1 could, before adding anything. |
| 3 | Inline: `codespan`, `linebreak`, `link`/`image` with `Ref`, `hyperlink`, `html`, `mathspan`, `abbreviation`, `footnote_callout`, and the 8 formats. | The linear scanner is one unit of risk; do it once. |
| 4 | Blocks: `list` nesting, `table` node rows/cells, `blockquote` nesting, indented code. | This is what v1's flat shape could not express. |
| 5 | New blocks: `footnote`, `reference`, `mathblock`, `html_block`, `description_list`, `custom_block`. | Genuinely new syntax; each is one pass + its tests. |
| 6 | Frontmatter. | Orthogonal; parse before the first block. |
| 7 | `RenderPlain` over the tree; delete `markdown.compat` when the view migrates. | |
| 8 | The file viewer (v1 Phase 4, unchanged). | |

**Not in v2** (records the decision rather than leaving it implicit): editing, search,
incremental re-parse of an edited region, a JSON serializer, and any change to the
streaming segmenter's contract — v2 *extends* the segmenter's open-kind set, it does not
redefine "decides where, not what".

## 8. Testing strategy

1. **The v1 corpus stays authoritative.** All 12 documents must parse identically through
   `markdown.compat` as they did through the v1 parser. This is the regression wall.
2. **New corpus documents per feature**, and the batch-vs-streamed equivalence runs over
   all of them at chunk sizes 1, 7, 64, 997 — unchanged from v1.
3. **Nesting is asserted by shape, not by rendered text.** `> - a` must yield
   `blockquote > list > listitem > paragraph > text`; a renderer test would pass on a
   flattened model.
4. **Ids are deterministic**: parsing the same text twice yields identical id assignment.
   `Parent` and `Children` are consistent both ways.
5. **Source offsets round-trip**: `Copy(Source, SrcStart, SrcEnd - SrcStart)` for a text
   node equals its `Content` for the cases where they should be equal (not for entities or
   escapes — assert the rule, not a coincidence).
6. **Security**: control characters stripped; a `javascript:` URI dropped; an `html` node
   never interpreted. Each as a test, because each is a real injection.
7. **The ReDoS class**: a linearity test over adversarial input (`'['` × 8000,
   `'[a]('` × 800) asserting it completes and produces a tree. Not a timing assertion —
   a completion one, so it does not flake.

## 9. Explicitly out

Footnotes with multiple paragraphs are **in**; footnote *ordering* rules (numbering by
first use) are the renderer's problem and out. Raw HTML is preserved, never rendered as
markup. No HTML output mode. No reference-style *image* inside a table cell (the source
does not support it either).

## 10. Open questions

1. **Byte offsets vs codepoint offsets.** Bytes are what the parser receives; a viewer
   painting cells needs codepoints or graphemes. Recommendation: **bytes** on the node
   (transport truth), converted at the view boundary — one conversion, not N.
2. **Does `markdown.compat` ship in the library, or live under `src/tui/`?** It is pure, so
   it belongs in `src/markdown/`, but it exists for a TUI. Recommendation: keep it pure and
   in `src/markdown/`, so `markdown-standalone` proves it too.
3. ~~**Frontmatter: node or document field?**~~ **Decided: a document field.**
   Metadata is not body, so a renderer must never walk it as content.

   **And an ownership boundary the operator set, which is the more important
   half: enforcing that a reply HAS frontmatter is not the parser's job.** The
   response protocol already owns that (`hildegard.helper.replymeta` extracts the
   block at the turn boundary, and the prompt contract asks for it). The parser
   only FOLLOWS the rules for recognising frontmatter — the same rules replymeta
   uses, so the two cannot disagree about the same bytes:

   - **frontmatter is structurally the FIRST BLOCK of a document** — a `---`
     fence on line 0 closed by a later `---` fence line, and nothing else;
   - the parser does **not inspect keys**. It does not know that `title` or
     `keywords` mean anything, and it requires no particular key. Knowing them
     would be harness knowledge inside a pure module;
   - a leading `---` with no closing fence is a thematic break, so it cannot eat
     the document;
   - a fence pair that is **not** first is ordinary markdown.

   The parser never refuses a document for lacking frontmatter. Interpreting the
   entries — deciding what `title` is for — belongs to the consumer.
