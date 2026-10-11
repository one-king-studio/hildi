# Implementation Plan: Reply Metadata v1

**Related Specification:** `Reply_Metadata_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Give substantive replies a YAML frontmatter header (title + keywords), extract it
as metadata, persist the title (per session) and keywords (per reply), and render
a dedicated header on the assistant item. The block is stripped before the
markdown renderer; while streaming it is suppressed until it closes. TDD-first;
`make check` before moving on. `main` only.

## Implementation Tasks

### Phase 1: The extractor (`hildegard.helper.replymeta`)

- [ ] **Create** `src/hildegard.helper.replymeta.pas` (interface only):
      `TReplyMeta`, `ExtractReplyMeta`, `TFrontMatterSuppressor`,
      `SuppressFrontMatter`.
- [ ] **Add** `test_replymeta.pas` to the runner's `uses`.
- [ ] **Test**: `ExtractReplyMeta` on a well-formed block returns the title,
      keywords, and the body with the block removed.
- [ ] **Implement**: the block scanner (`---` … `---`, leading only).
- [ ] **Test**: no block, unterminated block, and a `---` only in the body each
      yield `HasMeta = False` and the unchanged body.
- [ ] **Test**: `[a, b, c]`, `- item` lists, unknown keys, CRLF, empty title, and
      duplicate keywords.
- [ ] **Implement**: the tolerant value parser (ignore unknown keys; lowercase +
      de-dupe keywords).
- [ ] **Test**: `SuppressFrontMatter` across every chunk boundary of a block;
      no-block replies flush fully; a later `---` is not treated as a start.

### Phase 2: Store (migration v10 + methods)

- [ ] **Test**: migration v10 adds `title`/`title_override` and `reply_keywords`;
      an existing store migrates additively.
- [ ] **Implement**: migration v10 in `DefaultMigrations`.
- [ ] **Test**: `SetSessionTitle`/`SetSessionTitleOverride`/`SessionTitle`
      (override wins; setting the generated title is a no-op when overridden).
- [ ] **Implement**: the title methods.
- [ ] **Test**: `SetReplyKeywords`/`ReplyKeywords` replace (not append); a
      message delete cascades.
- [ ] **Implement**: the keyword methods.

### Phase 3: The completed-turn seam (`session.runtime`)

- [ ] **Test**: on `teDone`, a reply with a block sets the session title and the
      reply's keywords; a reply without one changes neither.
- [ ] **Implement**: extract + persist at the boundary (alongside the checkpoint
      commit); the raw reply is already stored verbatim.

### Phase 4: The prompt

- [ ] **Test**: the assembled request's system prompt carries the frontmatter
      instruction and the flavor line, and it is not persisted.
- [ ] **Implement**: append the instruction in `DefaultSystemPrompt` / the
      session `SystemPrompt` path.

### Phase 5: The TUI header (`tui.chat`)

- [ ] **Test**: an assistant item with metadata draws a title line and chips and
      a body **without** the block (headless, `TSurfaceMemory`).
- [ ] **Implement**: the metadata header on `TChatItem` (`ckAssistant`), theme
      roles only; the body source is the stripped text.

### Phase 6: Validation & docs

- [ ] **Run**: `make test SUITE=TReplyMetaTest,TSessionTest`
- [ ] **Run**: `make test`; `make test-leak`; `make check`
- [ ] **Update the SPEC** if behaviour diverged; rename this TODO to
      `Reply_Metadata_v1.DONE.md`

## Files to Create/Modify

### New Files

```
src/hildegard.helper.replymeta.pas
tests/test_replymeta.pas
```

### Modified Files

```
tests/hildegard_helper_tests.pas        (add the test unit)
src/hildegard.helper.store.pas          (migration v10 + title/keyword methods)
src/hildegard.helper.session.runtime.pas (extract + persist at teDone)
src/hildegard.helper.agent.pas          (the prompt instruction)
src/hildegard.helper.tui.chat.pas       (the assistant metadata header)
```

## Dependencies & Ordering

### Must Complete Before Starting

- Nothing external. `Session_Modal_v1` depends on this (it lists titles and
  searches keywords).

### Can Be Done in Parallel

- The extractor (Phase 1) and the store (Phase 2) are independent.

### Critical Path

1 (extractor) -> 2 (store) -> 3 (seam) -> 4 (prompt) -> 5 (render) -> 6.

## Success Criteria

- [ ] All tasks checked
- [ ] Every SPEC acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] The renderer never sees the frontmatter; the raw reply stays verbatim
- [ ] A reply's keywords are stored per reply, not aggregated

## Notes & Considerations

- **Strip, don't render.** The markdown viewer is never handed the block.
- **Tolerant, no YAML dep.** Unknown keys ignored; malformed input yields nothing.
- **Per reply.** Keywords attach to the assistant message, not the session.
- **Raw stays raw.** The ledger keeps the reply verbatim; the stripped body and
  metadata are derived views.
- Record deviations from the SPEC here.
