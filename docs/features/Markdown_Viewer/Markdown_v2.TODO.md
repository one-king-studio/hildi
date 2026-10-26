# Markdown v2 — Implementation Plan

**Spec:** [Markdown_v2.SPEC.md](Markdown_v2.SPEC.md) · **Feature:** [Markdown Viewer](FEATURE.md)
**Supersedes the shape constraint in:** [Markdown_v1.SPEC.md](Markdown_v1.SPEC.md) §4.1

Ordered so each phase leaves `make check` green. The batch-vs-streamed corpus
(`tests/test_markdown_equivalence.pas`) runs at every phase; a phase that breaks it is
not done.

## Phase 1 — The tree

- [x] `src/markdown/markdown.tree.pas` — `TMdNode`, `TMdDocument`, id assignment,
      `SrcStart`/`SrcEnd`, `Parent`, `Children` as **child ids**.
- [x] `TMarkdownDocumentParser.Parse` for constructs v1 already parses: paragraph,
      ATX + setext heading, fenced code, blockquote (flat), list (flat), table, rule.
- [x] Query surface: `Node(Id)`, `NodesOfKind(Kind)`, `Root`, `NodeCount`.
- [x] Ids are deterministic: two parses of the same text assign identical ids.
      *Test:* `TestIdsAreDeterministic`.
- [x] `Parent` and `Children` agree in both directions.
      *Test:* `TestParentChildLinksAreSymmetric`.
- [ ] Source offsets round-trip for a plain text node. **NOT DONE** — the field exists but is not yet populated by the block parser; deferred to Phase 3 where inline nodes get real offsets.
      *Test:* `TestSourceOffsetsRoundTrip`.
- [x] Node count and shape for nesting: `> - a` is
      `blockquote > list > listitem > paragraph > text`.
      *Test:* `TestNestingShape`.

## Phase 2 — The compat adapter

- [ ] `src/markdown/markdown.compat.pas` — `BlocksForTui(const ADoc: TMdDocument;
      out ALossy: Boolean): TMdBlockArray`, projecting only what has a v1 equivalent.
- [ ] Repoint `tui.widgets.markdownview` and `tui.widgets.chat` at the tree + adapter.
- [ ] **The regression wall:** every document in `tests/data/md_corpus/` projects through
      the adapter to exactly the blocks the v1 parser produced.
      *Test:* `TestCompatIsLosslessForV1Corpus` — asserts `ALossy = False` for the whole
      corpus, so the adapter cannot quietly become the product.
- [ ] `tests/test_markdown.pas` still passes with import changes only. Any assertion that
      must change is justified in the commit.

## Phase 3 — Inline, once, linearly

The most likely place to reintroduce the source's ReDoS, so it is one unit of work with
the linearity test written **first**.

- [ ] `src/markdown/markdown.inline.pas` — a linear tokenizer: `text`, `codespan`,
      `linebreak` (with `Soft`), `link`/`image` (with `Ref`), `hyperlink`, `html`,
      `mathspan`, `abbreviation`, `footnote_callout`, and 8 formats
      (`bold italic strike insert delete mark super sub`).
- [ ] URI allow-list **at node creation**: `http`, `https`, `mailto`; everything else is
      dropped to text.
      *Test:* `TestJavascriptUriIsDropped`.
- [ ] **Linearity, written first:** `'['` × 8000 and `'[a]('` × 800 parse to a tree and
      complete. A completion assertion, not a timing one, so it cannot flake.
      *Test:* `TestAdversarialInputIsLinear`.
- [ ] Escape/`html` nodes are marked raw and never interpreted by a consumer.

## Phase 4 — Nesting (what the flat model could not express)

- [ ] Recursive `list` / `listitem`: a list inside a list item inside a blockquote.
- [ ] `table` as `table > table_header|table_body > table_row > table_cell > *`.
- [ ] Recursive `blockquote`: a paragraph, a list, a fence, a table inside one.
- [ ] Indented code blocks (4 spaces), reported as `codeblock` with `Fenced = False`.
- [ ] Loose list items keep block structure: a second paragraph is a second child.

## Phase 5 — New block syntax

Each is one pass added to `MdBlockPassOrder`, or `TestBlockPassOrderIsPinned` fails.

- [ ] `footnote` definitions (`[^label]: …`) and `footnote_callout` (`[^label]`).
- [ ] `reference` definitions (`[label]: uri "title"`) + reference links/images.
- [ ] `mathblock` (`$$ … $$`) and `mathspan` (`$…$`).
- [ ] `html_block`.
- [ ] `description_list` / `description_term` / `description`.
- [ ] `custom_block` (`:::name … :::`).

## Phase 6 — Frontmatter

- [ ] `TMdDocument.Metadata` (not a node — see SPEC §10.3), parsed before the first block.

## Phase 7 — Rendering and deletion

- [ ] `RenderPlain` over the tree.
- [ ] Migrate `markdownview` to the tree.
- [ ] **Delete `markdown.compat` and its test in the same commit.** The adapter's ceiling is
      that it silently drops every v2-only node; leaving it in place is how two models
      become permanent.

## Phase 8 — The file viewer

Unchanged from v1 Phase 4: `TFileViewer` (`Open`/`Reload`, markdown by extension, plain
otherwise, error-as-text, oversized truncates with a notice, clamped scroll, wrap via
`tui.grapheme`).

## Testing phase

| Test | Proves |
| --- | --- |
| `TestCompatIsLosslessForV1Corpus` | the tree can express everything v1 could |
| `TestIdsAreDeterministic` | ids are document order, not allocation order |
| `TestParentChildLinksAreSymmetric` | the flat-with-links model is consistent |
| `TestSourceOffsetsRoundTrip` | a node can be located in the source |
| `TestNestingShape` | nesting is real, not a depth counter |
| `TestAdversarialInputIsLinear` | the ReDoS class cannot come back |
| `TestJavascriptUriIsDropped` | scheme allow-listing is at creation |
| `TestBlockPassOrderIsPinned` (existing) | every new pass is placed deliberately |
| v1 corpus equivalence (existing) | streaming and batch still agree |

## Completion criteria

- `make check` green and leak-clean; `make markdown-standalone` still green.
- Every node kind in SPEC §2 is produced by at least one corpus document.
- No `markdown.compat` in the tree; one model, not two.
- A markdown README of ≥10 KB opens in the viewer and scrolls, with nesting intact.
