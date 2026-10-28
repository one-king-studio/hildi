# Implementation Plan: Markdown v2 — DONE

**Related Specification:** `Markdown_v2.SPEC.md`
**Related Feature:** `FEATURE.md`
**Supersedes:** the shape constraint in `Markdown_v1.SPEC.md` §4.1

## Outcome

Shipped. **2,067 tests, 0 failures, 133 suites, leak-clean**, both standalone
gates green (`markdown-standalone`, `shell-standalone`).

The parser is a **pure node tree** with identity, nesting and source offsets. It
streams. The TUI renders it. A file viewer draws it. The v1 flat-block model is
gone from production.

| Commit | What |
| --- | --- |
| `9371eeb` | v2 SPEC: a full node tree supersedes v1's flat blocks |
| `203ee20` | `markdown.tree` — nodes, ids, `Parent`/`Children` |
| `eb68519` | `markdown.compat` — and 3 bugs its corpus guard found |
| `4211545` | `markdown.inline` — linear tokenizer, ReDoS test first |
| `da21f45` | the tree emits nodes from the tokenizer |
| `6d01dd8` | recursive nesting, and indented code |
| `c5557c4` | footnotes, references, math, HTML, description and custom blocks |
| `6941568` | frontmatter (since reshaped — see "What changed during the build") |
| `6067efa` | `RenderTree`, and a verification hole closed |
| `02cc1d8` | streaming built into the tree; the compat adapter deleted |
| `219b078` | a demo that shows streaming working |
| `f6a8c49` | streaming allocates for the tail, not per chunk |
| `c2d3d8c` | a stream sink, and `TStream` as the input side |
| `9568335` | `markdownview` renders the node tree |
| `db1b1b8` | the chat widget drops its stale v1 import |
| `1b7a0af` | the file viewer |
| `3305341` | one inline projection, not two |
| `60c5023` | inline math |
| `273977c` | source offsets |
| `71668d7` | inline HTML, plus three dead guards it exposed |
| `074f65f` | implementation status recorded in the SPEC |
| `92293e9` | the file viewer draws markdown styled, by composition |

## Implementation Tasks

### Phase 0 — Baseline and corpus — done

- [x] Recorded the gate; the branch arrived **red** (a missing `FEATURES.md` row)
      and that was fixed first.
- [x] 12-document seam corpus + batch-vs-streamed equivalence at chunk sizes
      0/1/7/64/997, **proven able to fail** (dropping `Finish` gave 1 failure).

### Phase 1 — The tree — done

- [x] `markdown.types` (AST), `markdown.tree` (nodes), `markdown.render`.
- [x] Ids are document order, gapless, deterministic; `Parent`/`Children`
      symmetric both ways; every node reachable from the root.
- [x] `make markdown-standalone` compiles with only `-Fu$(SRC)/markdown`.
- [x] `hildegard.helper.markdown` deleted, no alias.

### Phase 2 — Compat adapter — done, then deleted

- [x] `markdown.compat` projected the tree back to v1 blocks.
- [x] Its corpus guard found **3 real bugs** the tree's own tests could not see.
- [x] **Deleted** when streaming made its premise false: it had **zero production
      consumers**, only its own test. Keeping it would have been two models
      indefinitely.

### Phase 3 — The linear inline tokenizer — done

- [x] No forward search per delimiter; a single prepass pairs brackets.
- [x] Linearity asserted by **completion**, not wall-clock time.
- [x] URI allow-list at token creation (`http`/`https`/`mailto`), because an OSC 8
      hyperlink is a terminal-initiated action.

### Phase 4 — Nesting — done

- [x] Recursive list/blockquote; `table > header|body > row > cell`.
- [x] Indented code (`Fenced = False`); loose items keep block structure.

### Phase 5 — New block syntax — done

- [x] Footnotes (+ callouts), references, mathblock, `html_block`, description
      lists, custom blocks.

### Phase 6 — Frontmatter — done, reshaped twice

- [x] A **document field** → a **node** (`mnFrontmatter`), queryable from the root
      via `FrontmatterOf`/`FrontmatterText` or any `QueryNodes` predicate.
- [x] Frontmatter is a **content type**, not a position: a `---` fence anywhere.
- [x] The parser knows **no keys** — it reports the block verbatim. Harness
      concerns stay in the harness.

### Phase 7 — Streaming and rendering — done

- [x] `TMarkdownStream`: segmenter decides WHERE, not WHAT.
- [x] `IMdStreamSink` (push) **and** one stable `TMdDocument` (pull), which a
      consumer may hold and watch grow. `Snapshot` for a consistent read.
- [x] Allocation confined to the volatile tail: `AppendParsed` closes segments
      into one document, the builder grows geometrically, text is built in one
      pre-sized buffer. Measured: 623 `Append` calls → 400 blocks, heaptrc-clean.
- [x] `markdownview` renders the tree; `TMarkdownViewTest` 31/31 unchanged.

### Phase 8 — The file viewer — done

- [x] `TFileViewer`: markdown by extension, plain otherwise, error-as-text on a
      missing/unreadable file, truncation with a notice, clamped scroll,
      display-cell wrapping, reload keeps place.
- [x] Markdown draws **styled**, composed as `TScrollContainer(TMarkdownView)`
      rather than threading a scroll offset through the view.

### Testing phase — done

| Test | Proves |
| --- | --- |
| corpus equivalence (0/1/7/64/997) | streaming and batch agree, and the test bites |
| `TestIdsAreDeterministic`, `TestParentChildLinksAreSymmetric` | the flat-with-links model is consistent |
| `TestSourceOffsets*` | a node can be found in the source again |
| `TestNestingShape` | nesting is real, not a depth counter |
| `TestAdversarialInputIsLinear` | the ReDoS class cannot come back |
| `TestJavascriptUriIsDropped` | scheme allow-listing is at creation |
| `TMdStreamTest` (22) | sink, snapshot, in-place growth, closure rules |
| `TFileViewerTest` (14) | reads, distinguishes, survives missing/oversized |
| `TMarkdownViewTest` (31) | nothing regressed in the live renderer |

## What changed during the build

Three decisions were revisited mid-implementation, and the TODO records each
rather than hiding the reversal:

1. **The compat adapter was deleted, not migrated from.** Its premise — "the view
   cannot stream, so flatten the tree" — was false once streaming existed, and it
   had no production consumer.
2. **Frontmatter went field → node → content-type.** Each step removed a
   harness concern from the parser.
3. **The file viewer's styled ceiling closed by composition**, not by threading a
   scroll offset through `markdownview`.

## Deliberately not done

- **`abbreviation`.** Markdown Extra's `*[X]: expansion` needs a definition pass
  *and* a substitution pass over already-emitted text, so it cannot be produced by
  one linear scan. Not required by CommonMark or GFM. The node kind stays declared
  so a future implementation has somewhere to put it (SPEC §9b).
- **The v1 parser (`markdown.parse`) is not deleted.** It has zero production
  references, but it is still the only pin on v1 behaviour (47 assertions) and its
  equivalence corpus proved the v1 streaming contract. Retiring it is a separate
  decision with a real coverage cost.

## Lessons worth carrying

1. **The corpus guard out-found every deliberate test.** It found the 3 bugs in
   Phase 2 and the extra `document` node in the segmenter — all at seams where two
   individually-correct units joined wrong.
2. **Duplicated projections drift.** `render.pas` kept its own copy of the inline
   walk; `InlineSpansOf` was fixed and the copy was not, silently dropping every
   bold word. One projection, one fix.
3. **Pass order has been the defect three times** (setext-vs-rule, blank-vs-list-
   continuation, table-vs-paragraph). Pinning it as data earns its place.
4. **A green build is not evidence a file compiles.** A whole unit was never
   compiled by the test target — nine errors hid behind a green `make check`
   until the standalone gate exercised it.
5. **Assert the produced value, not that something happened.** Three dead guards
   in the inline-HTML branch survived because a weaker assertion would have passed
   them all.
