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

- [x] `src/markdown/markdown.compat.pas` — `BlocksForTui(const ADoc: TMdDocument;
      out ALossy: Boolean): TMdBlockArray`, projecting only what has a v1 equivalent.
- [ ] Repoint `tui.widgets.markdownview` and `tui.widgets.chat` at the tree + adapter. **DEFERRED** — the adapter is proven faithful first (below), which is the order that makes the repoint safe. The repoint is itself the trigger for the deletion condition, so it belongs with Phase 7.
- [x] **The regression wall:** every document in `tests/data/md_corpus/` projects through
      the adapter to exactly the blocks the v1 parser produced.
      *Test:* `TestCompatIsLosslessForV1Corpus` — asserts `ALossy = False` for the whole
      corpus, so the adapter cannot quietly become the product.
- [x] `tests/test_markdown.pas` still passes with import changes only. *(No repoint yet, so it is untouched and green.)* Any assertion that
      must change is justified in the commit.

**Two real bugs in the tree, found by the adapter's corpus guard** — not by review,
and not by the tree's own tests (which asserted shapes the bugs did not reach):

1. **Setext was checked after the paragraph branch had claimed the line**, so
   `Title` / `=====` became a paragraph plus a stray rule. The corpus document
   `04_setext_and_rules.md` is what caught it.
2. **A bare `>` was not a quote line.** Requiring a space after the marker split
   `07_quote_nesting.md` into two quotes and reported it lossy. A blank quote line
   is valid.

Plus one bug in the adapter itself: a **formatted run is a wrapper `text` node**
whose `Content` is empty and whose child holds the text. Pushing the wrapper's
content and stopping turned `a **bold** word` into `a word`.

**Three of my own assertions were wrong** and were rewritten rather than
weakened: I asserted that footnotes and math are lossy, but the tree does not
parse that syntax yet, so no node exists and nothing is discarded. A test that
asserts lossiness for unparsed syntax passes for the wrong reason.

## Phase 3 — Inline, once, linearly

The most likely place to reintroduce the source's ReDoS, so it is one unit of work with
the linearity test written **first**.

- [x] `src/markdown/markdown.inline.pas` — a linear tokenizer: `text`, `codespan`,
      `linebreak` (with `Soft`), `link`/`image` (with `Ref`), `hyperlink`, `html`,
      `mathspan`, `abbreviation`, `footnote_callout`, and 8 formats
      (`bold italic strike insert delete mark super sub`).
- [x] URI allow-list **at node creation**: `http`, `https`, `mailto`; everything else is
      dropped to text.
      *Test:* `TestJavascriptUriIsDropped`.
- [x] **Linearity, written first:** `'['` × 8000 and `'[a]('` × 800 parse to a tree and
      complete. A completion assertion, not a timing one, so it cannot flake.
      *Test:* `TestAdversarialInputIsLinear`.
- [ ] Escape/`html` nodes are marked raw and never interpreted by a consumer.

**Still open in Phase 3**, recorded rather than ticked:
- `html`, `mathspan`, `abbreviation`, `footnote_callout` tokens, and
  superscript/subscript. The token vocabulary exists; the syntax does not yet.
- Wiring the tokenizer into `markdown.tree`, so a parse emits these tokens as
  nodes. Until then the tree keeps its minimal inline parser and this unit is
  proven standalone. That wiring is what makes the two agree, and it is the next
  unit of work.

## Phase 4 — Nesting (what the flat model could not express)

- [x] Recursive `list` / `listitem`: a list inside a list item inside a blockquote.
- [x] `table` as `table > table_header|table_body > table_row > table_cell > *`.
- [x] Recursive `blockquote`: a paragraph, a list, a fence, a table inside one.
- [x] Indented code blocks (4 spaces), reported as `codeblock` with `Fenced = False`.
- [x] Loose list items keep block structure: a second paragraph is a second child.

**What `list > quote` and `> list` now produce**, verified by a probe rather than
assumed:

```
> - a / > - b        blockquote > list > 2 x (listitem > paragraph > text)
- item / "  > q"     list > listitem > [paragraph, blockquote > paragraph]
- a / <blank> / "  b" list > listitem > [paragraph(a), paragraph(b)]   <- loose
"    code line"      document > codeblock (Fenced = False)
```

**One ordering trap worth recording.** A blank line before an indented continuation
had to be claimed by the ITEM before the list loop's blank handling saw it,
otherwise the blank closed the list and the second paragraph became a sibling of
the list — structurally wrong while looking almost right. That is the third
bug in this lane where the pass ORDER, not the code, was the defect.

## Phase 5 — New block syntax

Each is one pass added to `MdBlockPassOrder`, or `TestBlockPassOrderIsPinned` fails.

- [x] `footnote` definitions (`[^label]: …`) and `footnote_callout` (`[^label]`).
- [x] `reference` definitions (`[label]: uri "title"`) + reference links/images.
- [x] `mathblock` (`$$ … $$`). **`mathspan` still open** — the inline tokenizer has the token kind but not the syntax yet.
- [x] `html_block`.
- [x] `description_list` / `description_term` / `description`.
- [x] `custom_block` (`:::name … :::`).

**Corpus got split by era, deliberately.** `tests/data/md_corpus/13_v2_blocks.md`
exercises every v2-only construct, so `TestCompatIsLosslessForV1Corpus` had to
learn the difference: documents `01`-`12` must project **losslessly**, and `13+`
must report **lossy**, because that is the adapter's honest signal working. An
adapter that claimed losslessness for a footnote would be lying.

**A deferral guard was inverted rather than deleted.**
`TestUnmodelledSyntaxIsNotClaimedAsParsed` was written in Phase 2 to assert that
footnotes and math were *not* lossy, because they were not parsed at all. Phase 5
made them real, so the assertion inverted: six constructs must now each report
loss. Left as it was, it would have been a test that passes while the adapter
silently eats every footnote.

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
