# Implementation Plan: File Tools v1

**Related Specification:** `File_Tools_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `File_Tools_v1.SPEC.md`. Work on `main`. Each task starts with
a failing test; `make check` before moving on.

## Implementation Tasks

### Phase 1: Types, config, path containment, approval

- [x] Add `test_file_tool` to `tests/hildegard_helper_tests.pas`
- [x] **Types**: `TFileToolConfig`, `TFileTool` in
      `src/hildegard.helper.files.pas` (interface only)
- [x] **Test**: containment - `../` and absolute escapes refused; inside allowed
- [x] **Test**: a denied ask returns the reason and performs no I/O
- [x] **Implement**: `ResolvePath` (root + containment), `Approve` (ask/options
      mirroring `TCommandTool`), and the JSON arg helpers

### Phase 2: read_file, write_file, edit_file

- [x] **Test**: `read_file` numbered lines, `offset`/`limit`, missing/dir errors,
      truncation
- [x] **Implement**: `ReadFile`
- [x] **Test**: `write_file` creates parents, overwrites, reports bytes; refused
      write leaves no file
- [x] **Implement**: `WriteFile` (temp file + rename)
- [x] **Test**: `edit_file` single replace, `replace_all`, not-found, ambiguous
- [x] **Implement**: `EditFile`

### Phase 3: list_dir, glob, grep

- [x] **Test**: `list_dir` sorted, dirs suffixed, recursive, missing dir
- [x] **Implement**: `ListDir`
- [x] **Test**: glob `*`/`?`/`**`, sorted relative paths, no matches
- [x] **Implement**: `Glob` + the matcher
- [x] **Test**: grep matches with `path:line: text`, `ignore_case`, `max_results`
- [x] **Implement**: `Grep`

### Phase 4: Registration & wiring

- [x] **Test**: `Register` advertises six tools, each requiring `reason`
- [x] **Implement**: `Register` with the six schemas
- [x] **Wire**: create a `TFileTool` in `THarnessSession` and `agent_cli`, and
      register it with the shared approval service
- [x] **Test (integration)**: an `exact` allow persists and the next call is
      auto-allowed

### Phase 5: Validation

- [x] `make test` / `make test-leak` / `make check`
- [x] Update `FEATURES.md`, `HANDOFF.md`, and the feature TODO
- [ ] **Live smoke**: exercise the six tools through the CLI/TUI against a real model

## Files to Create/Modify

### New Files

```
src/hildegard.helper.files.pas
tests/test_file_tool.pas
```

### Modified Files

```
tests/hildegard_helper_tests.pas   (add the test unit)
src/hildegard.helper.harness.session.pas  (own + register TFileTool)
examples/agent_cli.pas             (own + register TFileTool)
docs/features/FEATURES.md
HANDOFF.md
```

## Success Criteria

- [x] All tasks checked
- [x] Every FEATURE acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] Six tools registered and gated in both the TUI harness and the CLI

## Notes & Considerations

- Record deviations from the specification here.
- Containment is a guardrail, not a sandbox; keep the wording honest.
