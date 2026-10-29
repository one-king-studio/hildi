# TUI Syntax Highlighting

## Overview

Markdown v1 renders fenced code blocks as boxed, padded, styled spans — but
every language renders identically. This feature adds **lexical syntax
highlighting** to fenced code blocks: strings, comments, numbers, keywords,
and builtins coloured per the code fence's language tag.

The scope is deliberately a **viewer-grade tokenizer, not a semantic engine**.
LSP is considered and rejected (see Constraints). The model is vim's classic
`syn` files — keyword lists plus pattern rules — proven adequate for four
decades of terminal editing, and the right fit for a TUI whose output medium is
~16 colours of per-cell attributes. The scanner itself is hand-written over
literal delimiters, not a regex engine: the project already avoids regex on
untrusted output (see Constraints).

First targets are the languages an AI-coding session actually puts in code
blocks: **Pascal, Python, shell, JSON, and SQL**. The design is data-driven
(per-language rule tables, not per-language code), so adding a language later
is a table, not a unit.

## Problem Statement

Assistant answers are full of code — snippets to review, commands to re-run,
diffs to inspect — and the chat renders them as undifferentiated text inside
a box. In a session about code, that is most of the visual content.
Readers parse structure from colour long before content (string vs keyword
vs comment is *shape*, perceived pre-attentively), so flat code costs real
comprehension speed.

Two wrong answers lurk nearby, and this document records why they are wrong:

- **LSP** solves *semantic* questions (types, definitions, diagnostics,
  accurate method-vs-variable colouring) by running a compiler-grade server
  per language. A read-only code *viewer* in a terminal gains almost nothing
  from that accuracy — there are no gutter colours, hovers, or completions
  to feed — while paying the full bill: per-language server binaries,
  process lifecycle, a protocol stack, and per-session latency. That is an
  IDE budget. (I checked the actual vim 9.1 on this machine: `pascal.vim` is
  186 `syn keyword`/`syn match`/`syn region` rules — zero semantic analysis,
  four decades good enough. That is the model.)
- **A heavyweight parser (tree-sitter etc.)** is a vendored-C dependency with
  per-language grammars — the same weight class the project just avoided for
  TLS, bought for accuracy a terminal viewer cannot display.

The genuine gap is narrow: a small tokenizer that turns code text into
styled spans, driven by per-language rule tables, behind the existing
markdown view's span pipeline. Nothing more.

## Goals

- Highlight fenced code blocks when the fence carries a language tag
  (```pascal, ```python, ```bash/```shell, ```json, ```sql); render
  untagged/unknown-language blocks exactly as today (monochrome in the box).
- One **generic tokenizer** with per-language **rule tables**: line comments,
  block comments, strings (with escapes), numbers, keywords, builtins/types.
  Rule tables are data (constants), so new languages are additions, not
  features.
- Colours come from `TMdTheme` (new code-token roles, alongside `Code` and
  `CodeBackdrop`), keeping the palette-review workflow (`ec84ca8`-style preview
  docs) in charge of looks.
- Performance: highlighting is **computed once per block** — a code block's
  content is immutable once finalised and its spans are built once, so the cost
  is not paid per frame; budget < 5 ms for a 200-line block; budget asserted in
  the deterministic `make check` style (work-counted, not wall-clock) with
  wall-clock reported by `make bench`.
- Zero new dependencies; the ceiling is stated honestly in the SPEC (lexical
  approximation only; no semantic accuracy; the scan is length-bounded like the
  inline-emphasis fix in Markdown v1's follow-up).

## User Stories

- As an **operator** reviewing assistant-generated code, I want strings,
  comments, and keywords visually distinct inside code blocks, so I can
  scan structure before reading.
- As an **operator**, I want untagged fences and unknown languages to look
  exactly like today, so the feature can never make a block *worse*.
- As a **developer**, I want a new language supported by adding a rule
  table (and its tests), so the feature does not accrete per-language
  code paths.
- As a **debugger**, when a block renders oddly, I want the tokenizer to be
  a pure function (text + rules → spans), so I can unit-test the exact
  input and see the exact spans without a terminal.

## Acceptance Criteria

### Functional Requirements

- [ ] A fenced block tagged with a supported language renders its spans via
      the tokenizer: strings, comments, numbers, keywords, and builtins each
      carry a distinct theme role.
- [ ] Untagged fences, unknown tags, and unsupported languages render
      unchanged (today's boxed monochrome) — the feature is strictly
      additive, degrading to the current behaviour.
- [ ] Rule tables cover line comments, block comments, strings with escape
      sequences, numbers, keyword sets, and builtin/type sets for the five
      launch languages.
- [ ] Precedence is deterministic and tested: comments beat strings at the
      same position is *wrong* — the tokenizer is a left-to-right scanner
      where a comment opens only outside a string and vice versa; the tests
      pin the classic edge cases (comment markers inside strings, string
      delimiters inside comments, apostrophes in Pascal comments vs string
      quotes, `//` inside a URL in shell, `#` as comment vs `#include`).
- [ ] Token spans carry the token's foreground on the code box's sunken
      background (via the view's `OnSurface`), never `sfScreenBg`, so the box
      surface is preserved.
- [ ] Malformed/edge input cannot loop unboundedly (a single left-to-right scan
      with a documented length cap, mirroring the bounded-scan discipline of
      `MaxInlineDepth = 16`).
- [ ] highlighting integrates at the markdown view layer (spans into the
      existing block pipeline), not by touching the encoder or the chat
      block model.

### Non-Functional Requirements

- [ ] Computed once per block (immutable content → highlight once); memory
      bounded by the rendered blocks on screen.
- [ ] Deterministic gate: `make check` gains a work/budget assertion in the
      TUI Core style (no wall-clock flake); `make bench` reports ms.
- [ ] Zero dependencies; pure functions in, styled spans out.
- [ ] `make check` passes (functional tests plus the leak gate).

## Success Metrics

### Quantitative

- A 200-line Pascal block with mixed comments/strings highlights in < 5 ms
  once (computed once, not per frame).
- The five launch languages ship with tests covering their rule tables,
  including the shared edge-case battery.
- No frame-time regression in `make bench` on a chat stream full of code
  blocks (the memo is the guard).

### Qualitative

- Code in answers reads like code in an editor's read-only mode, not like
  prose in a box.
- The design-language palette doc remains the single source of visual truth
  (new code roles previewed there before landing, per the palette workflow).

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- Must integrate through the markdown view's existing span pipeline
  (`TTextBlock`-shaped spans into the chat stream blocks); must not fork a
  second renderer or bypass the encoder.
- Tokenizer is a **pure function** (text + rule table → spans) in
  `hildi.syntax`, unit-tested without a surface in
  `tests/test_syntax.pas`, per the testing conventions.
- Rule tables are data, versioned with the unit; language names match the
  common fence tags (with aliases: `sh`/`bash`/`shell` → the shell table,
  `json` → JSON table).
- Token roles are added to `TMdTheme` — the markdown theme the view already
  takes — and previewed in the design doc before landing, per the palette-review
  workflow. `TMdTheme` is a single fixed theme today (it does not track the
  app's light/dark `TTheme`); this feature keeps that.

### Constraints (explicitly rejected alternatives)

- **No LSP integration.** Semantic highlighting needs a language server per
  language (process spawn, protocol, lifecycle) and pays off in editor
  features (gutter/inline semantic colours, hovers, completions) a terminal
  viewer does not have. Vim's own highlighting — the four-decade incumbent —
  is pure regex + keyword lists; the app gets the same class of value from
  the same class of mechanism at a hundredth of the complexity.
- **No vendored parser (tree-sitter, chroma, bat).** External-process or
  vendored-C solutions add deployment weight (the thing the static-binary
  decision fights) for fidelity the 16-colour attribute medium cannot show.
  **Superseded (2026-10-12) for tree-sitter specifically** — see
  [`Tree_Sitter`](../Tree_Sitter/FEATURE.md). The dependency is bought by the
  approval gate's need for *correct* shell parsing, not by colour: the splitter
  names shell keywords as programs and misses programs inside `$(…)`. This
  feature's own criteria (additive, computed once, no regex on untrusted text)
  are preserved: tree-sitter becomes the engine for languages with a vendored
  grammar, and the rule-table tokenizer stays for the rest.
- **No regex engine on code.** FPC's `regexpr` is available, but the markdown
  parser already refuses regex on untrusted output (ReDoS); the tokenizer scans
  literal delimiters instead, so the same guarantee holds here.

### Prior Art (SynEdit)

Lazarus ships SynEdit (`components/synedit`) on this machine, so the ladder was
climbed against real code rather than in the abstract:

- **Licence: MPL-1.1 / GPL-2.0, and this project has no licence of its own.**
  The ideas are not copyrightable but the code is, so SynEdit is a **design
  reference only, not a source of code**. The SPEC records what was taken.
- **Worth taking (as ideas):** the per-first-character dispatch (`fProcTable`) —
  an FPC `case` over the first char compiles to the same jump table; the token
  model (`GetToken`/`GetTokenPos`/`GetTokenAttribute`); the named attribute roles
  (`Comment`, `String`, `Number`, `Keyword`, `Symbol`, `Identifier`), which map
  onto new `TMdTheme` roles; and longest-keyword-first matching (so `end` is
  tried before `endif`).
- **Not worth taking:** the per-character hash plus per-hash function table
  (`mHashTable`/`fIdentFuncTable` — the "computed goto" keyword matcher) exists
  to disambiguate thousands of keywords at editor speed; our per-language sets
  are small, so a sorted list with binary search is simpler and fast enough. The
  per-line range store (`TSynHighlighterRangeList`) exists to restart a
  highlighter mid-document; our blocks are immutable and scanned once, so it does
  not apply. The attribute-modifier/priority merge model is unneeded against a
  fixed palette.

## Non-Goals

- Semantic highlighting (types vs locals vs parameters).
- Autocomplete, go-to-definition, diagnostics, hovers — LSP-shaped features.
- Folding, indentation guides, bracket matching, or any editor affordance —
  this is a viewer, not an editor.
- Highlighting outside fenced code blocks (the compose box, stream text).
- Per-theme user configuration of code colours (palette doc governs).

## Notes

- **ICE score: Impact 6, Confidence 8, Ease 7.** High-frequency value (most
  blocks in an AI session are code), very low risk, small surface.
- Sequencing: independent of TLS / Session Handoff / Clipboard; a natural
  slot after the markdown-tables arc settles. The SPEC decides the exact
  theme-role names and the rule-table format (record vs JSON-ish constant),
  and must keep the pure-function shape.
- Landing order: Pascal and shell first (the project's own languages), then
  Python, JSON, and SQL as further rule tables — so the shared edge-case battery
  is proven once before it is multiplied by five.
- **Deliberate shortcut (`ponytail:`): lexical approximation only.** The
  upgrade path is rule-table enrichment (more patterns, more languages) —
  and, if ever truly needed, a semantic engine would arrive behind the same
  span pipeline, not replace it.
