# Implementation Plan: Session Header v1

**Related Specification:** `Session_Header_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Task breakdown for `Session_Header_v1.SPEC.md`, implemented test-first on top of
Turn Stats v2.

## Implementation Tasks

### Phase 1: The border titles

- [x] **Test**: `TestBorderDrawsRightTitle`,
      `TestRightTitleSkipsWhenTooNarrow` in `tests/test_tui_widgets.pas`
- [x] **Implement**: `TBoxStyle.TitleRight` and the right-aligned title in
      `src/hildegard.helper.tui.panel.pas`

### Phase 2: The formatters

- [x] **Test**: `TestFormatContextUsage`, `TestFormatContextUsageNoLimit`,
      `TestFormatSessionHeader`, `TestFormatSessionHeaderEmpty` in
      `tests/test_harness_stats.pas`
- [x] **Implement**: `FormatContextUsage`, `FormatSessionHeader` (and the
      private progress bar) in `src/hildegard.helper.harness.stats.pas`

### Phase 3: The panel and the app

- [x] **Implement**: `TChatPanel.SetHeader` in
      `src/hildegard.helper.tui.chatpanel.pas`
- [x] **Test**: `TestHeaderShowsSessionIdAndStats`,
      `TestHeaderUpdatesAfterATurn`, `TestResumeHeaderMatchesLive`,
      `TestStatusBarCleared` in `tests/test_harness_app.pas`
- [x] **Implement**: the header (id left, stats right) and the cleared status
      bar in `src/hildegard.helper.harness.app.pas`

### Phase 4: Docs and validation

- [x] **Update**: `docs/design/tui_design_language.html` (the preview),
      `examples/tui_layout_demo.pas`, `docs/features/FEATURES.md`; rename this
      plan to `Session_Header_v1.DONE.md`
- [x] **Run**: `make check` (tests + leak gate)

## Files Created/Modified

### New Files

```
docs/features/TUI_Harness/Session_Header_v1.SPEC.md
docs/features/TUI_Harness/Session_Header_v1.DONE.md
```

### Modified Files

```
src/hildegard.helper.tui.panel.pas        TitleRight on the top border
src/hildegard.helper.tui.chatpanel.pas    SetHeader, HeaderLeft/Right
src/hildegard.helper.harness.stats.pas    FormatContextUsage, FormatSessionHeader
src/hildegard.helper.harness.session.pas  MaxContextTokens resolves the default
src/hildegard.helper.harness.app.pas      the header; the cleared status bar
tests/test_tui_widgets.pas                the border titles
tests/test_harness_stats.pas              the header formatters
tests/test_harness_app.pas                the header + the cleared status bar
docs/design/tui_design_language.html      the preview
examples/tui_layout_demo.pas              the header
docs/features/FEATURES.md                 the feature index
HANDOFF.md                                the header note
```

## Success Criteria

- [x] All tasks above checked
- [x] Every acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] A resumed session's header is identical to the live one

## Notes & Considerations

Deviations from the specification, and why:

- **The header carries only the context; the status bar carries the
  consumption.** The first cut put the consumption on the header too and it read
  as too much. The header is now id + context (`ctx [bar] pct%`); the status bar
  is the workspace plus the billed in/out, cache hit, time and requests.
- **`MaxContextTokens` resolves to the default.** To keep the header's
  percentage and bar always present, `THarnessSession.MaxContextTokens` now
  resolves config -> `HILDEGARD_MAX_CONTEXT_TOKENS` -> the agent default (120k)
  rather than exposing 0.
- **The app tests pin the limit.** The environment may set
  `HILDEGARD_MAX_CONTEXT_TOKENS` (`.env`), so the test config sets
  `MaxContextTokens := 120000` to keep the header assertions deterministic.
- **Cost is omitted.** It will be tracked per turn with the provider and model;
  the header leaves the slot for it.
- **The right title is skipped, not truncated, when narrow.** A truncated right
  title would read as garbage; the left (the session id) wins the space.
- **The bar is ten shade cells.** A first horizontal bar (eighths) read as
  noise and a single vertical-eighth glyph read poorly; the final bar is ten
  `░`-backed cells with `▓` per full tenth and `▒` for a >=5% remainder. The
  status bar keeps the workspace on the left (its right side is empty).
