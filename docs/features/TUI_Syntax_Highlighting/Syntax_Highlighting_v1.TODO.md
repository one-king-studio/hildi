# Implementation Plan: Syntax Highlighting v1

**Related Specification:** `Syntax_Highlighting_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

A pure tokenizer (`hildegard.helper.syntax`) turns fenced code into spans of
token kinds; the markdown theme gains code-token roles; the view maps kinds to
attributes and draws them in the existing code box. TDD-first; update tasks in
real time. Landing order: Pascal and shell first, then Python/JSON/SQL.

## Implementation Tasks

### Phase 1: Tokenizer core

- [ ] **Add the test unit** to the `uses` clause of
      `tests/hildegard_helper_tests.pas`
- [ ] **Define types** in `src/hildegard.helper.syntax.pas`: `TSynToken`,
      `TSynTokenSpan`, `TSynDelim`, `TSynLang`, and the `HighlightCode` /
      `SynLanguage` / `SynLanguageKnown` signatures
- [ ] **Test**: `TestPlainWhenLanguageUnknown`, `TestSpansCoverInputExactly`
- [ ] **Implement**: the left-to-right scanner (line comments, block comments,
      strings, numbers, identifiers, plain runs); unknown language → one plain
      span
- [ ] **Test**: `TestLongestOpenerWins`, `TestBoundedScan`

### Phase 2: Pascal and shell tables

- [ ] **Implement**: the Pascal rule table (`//`, `{ }`, `(* *)`, `'` doubled,
      `$`/`%`/`&` numbers, keywords, builtins, case-insensitive)
- [ ] **Test**: `TestPascalKeywordStringCommentNumber`,
      `TestNestedBlockComment`, `TestNumberPrefixes`,
      `TestIdentifierLookupIsCaseAware`
- [ ] **Implement**: the shell rule table (`#`, `'`/`"`, keywords)
- [ ] **Test**: `TestShellKeywordAndComment`
- [ ] **Test**: the edge battery — `TestCommentMarkerInsideStringIsString`,
      `TestStringMarkerInsideCommentIsComment`, `TestEscapeInString`,
      `TestDoubledQuoteIsLiteral`

### Phase 3: Python, JSON, SQL tables

- [ ] **Implement**: Python (`#`, `'''`/`"""`, keywords), JSON (`"`, literals),
      SQL (`--`, `/* */`, `'` doubled, keywords, case-insensitive)
- [ ] **Test**: `TestPythonTripleQuotedString`, `TestJsonStringNumberKeyword`,
      `TestSqlQuotedStringAndComment`

### Phase 4: Theme and view

- [ ] **Test**: `TestCodeTokenAttrUsesTheSurface` (roles, bg, no `sfScreenBg`)
- [ ] **Implement**: the `Code*` roles in `TMdTheme`/`DefaultMdTheme` and
      `CodeTokenAttr` in `tui.widgets.mdtheme`
- [ ] **Test**: `TestCodeFenceIsHighlighted`, `TestUntaggedFenceIsUnchanged`,
      `TestCodeFenceHighlightIsBuiltOnce`
- [ ] **Implement**: `MakeBlock` for `mbCodeFence` runs `HighlightCode` and maps
      spans via `CodeTokenAttr` (built once)

### Phase 5: Design & validation

- [ ] **Preview** the token palette in `docs/design/tui_design_language.html`
      (a highlighted Pascal/shell block) and get sign-off before landing
- [ ] **Update** `docs/features/FEATURES.md` status
- [ ] **Run**: `make test SUITE=TSyntaxTest,TMarkdownViewTest,TMarkdownTest`
- [ ] **Run**: `make check` (whole suite + leak gate)

## Dependencies & Ordering

- Types before the scanner; the scanner before the rule tables.
- The theme roles before the view wiring.
- The palette preview before the view lands (per the palette workflow).

## Files to Create/Modify

### New Files

```
src/hildegard.helper.syntax.pas
tests/test_syntax.pas
```

### Modified Files

```
src/tui/widgets/tui.widgets.mdtheme.pas   (Code* roles + CodeTokenAttr)
src/hildegard.helper.tui.markdownview.pas  (highlight the fence)
tests/hildegard_helper_tests.pas           (add the test unit)
tests/test_markdown.pas                    (theme mapping)
tests/test_markdownview.pas                (fence rendering)
docs/design/tui_design_language.html       (palette preview)
docs/features/FEATURES.md                  (status)
```

## Success Criteria

- [ ] All tasks above checked
- [ ] A tagged fence highlights; untagged/unknown fences are unchanged
- [ ] `make check` passes (tests + leak gate)
- [ ] Adding a language is a rule table plus tests, not a code path

## Notes & Considerations

- **SynEdit is design-only prior art (MPL-1.1/GPL-2.0).** The SPEC records what
  was taken (per-first-char dispatch, the token/role model, longest-first
  matching) and what was left (the per-char hash/function table, the per-line
  range store, the modifier merge).
- **No regex engine** — a hand-written scanner over literal delimiters, matching
  the markdown parser's stance on untrusted input.
- **Token spans sit on the code surface**: `CodeTokenAttr` sets
  `CodeBackdrop.Bg` and drops `sfScreenBg`, mirroring `OnSurface` in the view.
- Proposed role colours (comment `245`, string `114`, number `215`, keyword
  `213` bold, builtin `116`) are provisional until the companion review.
