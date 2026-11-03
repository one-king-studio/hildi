# Implementation Plan: Workspace Instructions v1

**Related Specification:** `Workspace_Instructions_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

**Status: complete.** Committed as `8c8ba59`. Gate: 2,162 tests, 0 failures, 133
suites, leak-clean, standalone green.

This was built before it was documented. The plan is recorded as executed rather
than as an empty checklist, so the artifact chain stays honest about the order
things actually happened in.

## Implementation Tasks

### Phase 1: The split (prerequisite)

The feature could not be built until the coordination text was separable.

- [x] **Test**: existing `TestTheCoordinationTextRidesTheSystemPrompt` pinned the
      old placement — left failing deliberately while the split was written.
- [x] **Implement**: `CoordinationRulesText` and `CoordinationModeLine` in
      `HildiCoordination`; `CoordinationPromptFor` kept as the pair, for callers
      that want both.
- [x] **Refactor**: `CoordinationPromptFor` re-implemented in terms of the two
      halves, so there is one source and no duplicated prose.

### Phase 2: Static guidance to the system prompt

- [x] **Test**: `TestStablePromptIsSetWithoutAnyMcp` updated to assert shell
      guidance in `SystemPromptText` rather than `Loop.StablePrompt`.
- [x] **Implement**: `ShellGuidanceText` extracted; the system prompt is
      assembled with it in `THarnessSession.Open`, plus `CoordinationRulesText`
      when a board or task store exists.
- [x] **Implement**: `FSystemPromptText` retained and exposed as
      `SystemPromptText`, so placement is assertable.

### Phase 3: AGENTS.md

- [x] **Test**: `TestAgentsMdRidesTheStablePrompt` — content in the stable text,
      **and not** in the system prompt.
- [x] **Test**: `TestAgentsMdIsTaggedWithItsSource` — the element, its `source`
      attribute, and the subordination prose.
- [x] **Test**: `TestAgentsMdFallsBackToReadme` — the fallback, reporting
      `source="README.md"`.
- [x] **Test**: `TestAgentsMdAbsentLeavesNoBlock` — absence is silent.
- [x] **Test**: `TestAgentsMdIsRepublishedAfterAnEdit` — an edit between turns is
      picked up.
- [x] **Implement**: `ProjectInstructionsText` — candidate order, 32 KB cap,
      binary and whitespace-only files skipped, read failure treated as absent.
- [x] **Implement**: `AppendBlock` — blank-line separation only when both sides
      are non-empty.
- [x] **Implement**: `ComposeStablePrompt` ordered as instructions → skills →
      mode line.
- [x] **Implement**: `RecomposePrompt` public, so a test drives one refresh.

### Phase 4: Documentation

- [x] `FEATURE.md` — requirements, the prompt-split decision, the security note.
- [x] `Workspace_Instructions_v1.SPEC.md` — contracts, assembly order, tests.
- [x] `FEATURES.md` row.
- [x] This file.

## Deviations from the SPEC as first written

- **`HildiFiles.ReadTextFile` was not used.** It is implementation-only, and
  widening that unit's interface for one caller was not worth it; the read is
  local with `TFileStream`.
- **The system prompt is captured in `FSystemPromptText`.** Not in the SPEC's
  public API originally, but the split is only assertable if a test can see what
  landed where.

## What is NOT done

- **Nested/per-directory instructions.** Root only.
- **Shadowed-file reporting.** If `AGENTS.md` and `README.md` both exist the
  README is silently unused, and nothing tells the operator why their edit did
  nothing.
- **No end-to-end render check.** Each placement is asserted by unit tests, but
  nobody has printed the fully assembled prompt: the probe written for it failed
  to compile (the config type lives in another unit) and was not retried.

## Verification

`make check` — 2,162 tests, 0 failures, 133 suites, leak-clean, both standalone
gates green.
