# Markdown v1 — Implementation Plan

**Spec:** [Markdown_v1.SPEC.md](Markdown_v1.SPEC.md) · **Feature:** [FEATURE.md](FEATURE.md)

Ordered so each phase leaves the tree green. Nothing here is started.

## Phase 0 — Baseline

- [x] Record the current gate: `make test-parallel` count, and `tests/test_markdown.pas`
      passing. This is the number every later phase is measured against.
- [x] Add the equivalence corpus as a **failing-capable** test against the *existing*
      parser: ~12 documents, batch vs chunked, asserting identical trees.
      *Files:* `tests/test_markdown_equivalence.pas`, `tests/data/md_corpus/*.md`
      *Why first:* it will find real bugs in what we already ship, before any move makes
      attribution ambiguous.

## Phase 1 — Extract the module (mechanical, behaviour-preserving)

- [x] `src/markdown/markdown.types.pas` — move `TMdBlock`, `TMdSpan`, kinds, alignment
      verbatim. No `uses tui.*`.
- [x] `src/markdown/markdown.parse.pas` — move `TMarkdownParser` and its block/inline
      scanners. Split into `markdown.inline` / `markdown.blocks` / `markdown.stream` as
      the units are touched, not in one commit.
- [x] `src/markdown/markdown.render.pas` — `RenderPlain`.
- [x] `markdown-standalone` make target: `-Fu$(SRC)/markdown` only.
      *Test:* `TestMarkdownModuleLinksNoTui` — grep the module for `tui.` and fail.
- [x] `src/tui/widgets/tui.widgets.mdtheme.pas` — theme, `DefaultMdTheme`, `MdAttrFor`,
      `MdBlockAttr` moved out.
- [x] Point `tui.widgets.markdownview` at the new units.
- [x] Delete `src/hildegard.helper.markdown.pas`. No alias.
- [x] `tests/test_markdown.pas` compiles against the new units with import changes only —
      **zero assertion changes**. Any assertion that must change is a regression; justify
      it in the commit.

**Deviation, deliberate:** `markdown.parse` is not yet split into
`markdown.inline` / `.blocks` / `.stream`. The inline scanner and the block
builders share `CollapseWhitespace` and `SplitCells`, so the split needs a
fourth home for them (or duplication) — a design choice, not a mechanical move.
Purity is by directory, so the feature's central claim already holds. Revisit
before the parser grows; do not treat it as done.

## Phase 2 — Setext headings

- [x] Block pass for `Title\n=====` → `mbHeading` level 1, `Title\n-----` → level 2.
      Position: **after** lists (so `- item` is consumed), **before** thematic breaks (so
      `---` is not eaten as a rule).
      *Tests:* setext under a paragraph; `---` under text is a heading not a rule;
      `- item\n---` is a list then a rule.
- [x] Streaming: a `---` under open text appends to the open segment.
      *(Falls out of the design: the paragraph stays open, so the underline
      arrives as a line inside it and the setext pass runs there. Pinned by
      `TestIncrementalSetextMatchesFullParse`.)*

**Two details settled by tests, not assumption:**

- The underline is a **continuous run** (no internal spaces). That is what keeps
  `- - -` a thematic break and `= =` ordinary text, so setext and rule never
  compete for the same line.
- The **whole open paragraph** becomes the heading, not just its last line:
  `Foo / bar / ===` is one level-1 heading reading `Foo bar`. This is the
  difference from the table pass, where only the last line is the header.

`TestDelimiterWithoutPipeIsParagraph` was rewritten deliberately (its old input,
`Header` + `---`, pinned the absence of setext). Its intent — a pipe-less
delimiter is not a table — is kept with `- - -`, which is unambiguous under both
readings.

## Phase 3 — Pass-order guard

- [x] Declare the pass order as data; a test reads it and pins it, so a reorder fails.
      *Test:* `TestBlockPassOrderIsPinned`. *Proven to bite: swapping setext
      and the thematic break in the declared list fails it at "pass 4 is in
      place".*

## Phase 4 — The file viewer

- [ ] `src/tui/widgets/tui.widgets.fileviewer.pas` — `TFileViewer`, `Open`/`Reload`.
      Markdown by extension, plain otherwise.
      *Tests:* markdown file renders blocks; plain file renders lines; missing file draws
      an error rather than raising; oversized file truncates with a notice.
- [ ] Scroll: Up/Down one line, PageUp/PageDown a screen, Home/End. Clamped.
- [ ] Wrapping at the pane width via `tui.grapheme`.

## Phase 5 — Wiring

- [ ] Decide open question §10.1: pane in the TUI, or separate binary.
- [ ] Expose it — a command or a key. Out of scope for the module.

## Testing phase (explicit)

| Test | Proves |
| --- | --- |
| `TestMarkdownModuleLinksNoTui` | purity, by grep |
| `TestBatchAndStreamingAgree` (corpus) | the AST is one thing, not two |
| `TestBlockPassOrderIsPinned` | a reorder fails loudly |
| `TestSetextHeading*` | the one missing construct |
| `TestRenderPlain*` | the AST is consumable without a terminal |
| `TestFileViewer*` | reads, distinguishes, survives a missing/oversized file |
| existing `test_markdown.pas` | nothing regressed |

## Completion criteria

- `make markdown-standalone` green; `make check` green and leak-clean.
- `hildegard.helper.markdown` gone.
- A markdown README of ≥10 KB opens in the viewer and scrolls.
- The equivalence corpus passes at chunk sizes 1, 7, 64 and 997 bytes.

## Sequencing note

Phases 1–3 are one lane and must be serial: every one touches the parser. Phase 4 is
independent once Phase 1 lands — it only needs the AST — so it can run in parallel with
Phase 2/3 in its own worktree.
