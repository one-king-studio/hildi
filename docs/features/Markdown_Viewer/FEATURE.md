# Feature: Markdown Viewer

**Status:** Proposed — no spec yet beyond `Markdown_v1.SPEC.md`.

**Related:** [TUI Harness](../TUI_Harness/FEATURE.md) ·
[Markdown Tables](../TUI_Harness/Markdown_Tables_v1.SPEC.md) ·
[File Tools](../File_Tools/FEATURE.md) ·
[Workspace Snapshots](../Workspace_Snapshots/FEATURE.md)

## Overview

Two things, one direction of dependency:

1. **A standalone markdown module** (`src/markdown/`) that turns markdown text — batch or
   streamed — into a **typed AST**, with **no dependency on the TUI**. A consumer decides
   how to render it.
2. **A file viewer** in the TUI that reads a workspace file and renders it, using the
   existing styled-cell look for markdown and raw text for everything else.

> **Shipped.** Both goals are met and the old unit is gone. In the original code the
> parser and the renderer were one unit: `hildi.markdown` produced
> `TMdBlock` but also owned `TMdTheme` and `uses tui.base` for `TAttr`, so the AST
> was a private intermediate rather than a contract. `src/markdown/` now holds a
> pure node tree, `tui.widgets.mdtheme` owns the theme, `tui.widgets.markdownview`
> renders it and `fileviewer` draws a file. What shipped, and the three decisions
> revisited mid-build, are in [Markdown_v2.DONE.md](Markdown_v2.DONE.md).

## The problem

**The AST is real but unreachable.** `TMdBlockArray` is a genuine typed tree. But rendering
it anywhere other than the TUI requires linking `tui.base` for the colour type, so the
structure and the terminal are welded together. Consequences:

| Want | Blocked by |
| --- | --- |
| Render markdown to plain text (tests, transcripts, logs) | pulling in the TUI |
| Prove batch and streaming agree, structurally | assertions are co-located with theme code |
| Reuse the parser outside the harness | the unit names `hildi.*` and depends on `tui.*` |
| Add a second renderer (HTML, a debug dumper) | same |

**There is also no file viewer.** The harness can read a file with `file_read` (through an
agent turn) or show a diff in the turn summary, but the operator cannot simply *look at a
markdown file* in the TUI. Reading documentation is the most common reason to want one.

## Goals

- **A pure module.** `src/markdown/` depends on the RTL and nothing else — no `tui.*`, no
  `hildi.*`. Proven by a build target, the same way `shell-standalone` and
  `tui-standalone` prove theirs.
- **The AST is the product.** Batch and streaming produce the same tree; a consumer never
  needs the parser's internals.
- **The viewer is a consumer.** It links the module and supplies the look; the module knows
  nothing about cells, colours, or escape sequences.
- **Reader-grade rendering.** Headings, emphasis, code, lists, quotes, rules, GFM tables —
  the constructs a README actually uses — rendered as they are in the chat panel today.

## User stories

- As an **operator**, I want to open a markdown file from the workspace and read it in the
  TUI, scrolled and wrapped, without spending an agent turn.
- As an **operator**, I want a non-markdown file to show as plain text rather than failing.
- As a **harness author**, I want to render the AST somewhere that is not a terminal, so
  the parser can be tested on structure alone.
- As a **harness author**, I want batch and streaming to be provably the same tree, so a
  live-streamed reply and a resumed one look identical.

## Design shape

```
src/markdown/                        PURE: RTL only
  markdown.types      the AST: blocks, spans, attributes-free
  markdown.inline     lexer + pairer (no regex)
  markdown.blocks     block passes, order-guarded
  markdown.stream     segmenter: decides where blocks END
  markdown.parse      the assembled entry point (batch + incremental)
  markdown.render     the "flat" renderer: AST -> plain text

src/tui/widgets/
  tui.widgets.markdownview   AST -> styled cells (the theme lives HERE)

src/tui/widgets/
  tui.widgets.fileviewer     open a path, pick a renderer, scroll
```

**Why `markdown.render` exists in the pure module**: "AST → plain text" needs no terminal,
is the cheapest proof the AST is usable on its own, and gives tests a readable failure
message instead of an array dump.

## Non-functional requirements

- **No regex in the inline path.** Already true (`grep RegExpr` → 0); the spec must keep it
  true. Backtracking is a security property, not a performance one.
- **Batch and streaming agree**, asserted over a corpus, not one document.
- **Bounded work per streamed update**: O(open block), not O(document).
- **No new dependency.**
- **Non-ASCII survives** (the `cwstring` / `UTF8Encode` boundary rules).

## Success metrics

- `make markdown-standalone` builds and runs: the module compiles with no `tui.*` on the
  search path.
- The batch/streaming corpus: every document produces an identical tree both ways.
- Opening a 40 KB markdown file paints a first frame without a visible stall.

## Constraints

- Free Pascal 3.3.1, `{$mode delphi}`; `cthreads` first, `cwstring` next.
- Public names take the module prefix (`markdown.tree`, `markdown.stream`), like `shell.*`
  and `async.*`.
- The existing `hildi.markdown` was **replaced, not kept alongside**. Both it
  and its successor `markdown.parse` are now deleted: two parsers was the state this
  feature existed to end, and one model is the outcome.

## Out of scope

- **Footnotes, abbreviation lists, link reference definitions, math, `:::kind` blocks,
  description lists.** The source design has all of them; none is needed to read a README,
  and each carries a document-wide-resolution rule (see the source's §7) that is real work.
  Adding any of them later must follow that rule.
- **HTML rendering.** A terminal has no markup; raw tags are text.
- **Editing.** The viewer reads.
- **Syntax highlighting inside fences.** Colour for a fence is already a theme decision;
  tokenising code is [TUI Syntax Highlighting](../TUI_Syntax_Highlighting/FEATURE.md).
- **Image rendering.**

## Risks

- **The split is a refactor of a shipped, working parser.** Mitigation: the acceptance bar
  is behavioural equivalence — the existing `tests/test_markdown.pas` assertions must pass
  against the new module with only import changes. If a behaviour changes, it is a
  regression, not a design choice.
- **Theme/attr extraction touches every render call.** Mitigation: the theme becomes an
  argument the view supplies; the AST never carries an `TAttr`.
- **Pass order is load-bearing.** With 8+ passes whose order matters (`- item` vs `---` vs
  setext), a reorder compiles and silently breaks a feature. Mitigation: pin the order
  structurally, so a reorder fails a test.
- **A viewer invites scope creep** — editing, search, jump-to-heading. Mitigation: v1
  scrolls and renders. Nothing else.

## Notes

- **The source of the design** is a *separate* sibling project's markdown renderer
  (TypeScript, ~12.8k lines), not part of this repository and not required to build
  anything here. Its local checkout path is deliberately not recorded in source control;
  see `LOCAL_NOTES.md` (gitignored) on a machine that has both. Its *architecture*
  transfers; its code does not — it produces HTML for a DOM, and its sanitiser,
  URI allow-listing and node ids exist to serve that.
- **The lessons that transferred, restated here so they survive without the source:**
  one regex doing three jobs is unauditable; a green suite can prove nothing if it only
  exercises the path the app does not run; and a declaration must not become a node.
  Those three were paid for once already.
- **We already satisfy the biggest one.** Our inline scanner is hand-written and linear;
  the source's 6.8 s ReDoS on 200 characters is a failure mode we cannot have.
