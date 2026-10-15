# Implementation Plan: File Tools v2

**Related Specification:** `File_Tools_v2.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Add the first-class edit tools (the Composed Tool Sandbox's `tools.*` surface):
regex replace, multi-file search/replace, file ops, JSON/YAML edits, and a
unified-diff applier — each gated, confined, and reasoned like the v1 tools.
TDD-first; `make check` before moving on. `main` only.

> **Prerequisite:** Approval Path Scoping v1 Phases 1–4 (the `dir`/`ext`/
> `dir_ext` options), so the multi-file replace is one prompt rather than N.
> This plan can start before that lands (the tools work with the existing asks),
> but the multi-file ask is only *useful* once Path Scoping does.

> **Progress (Phases 1–3 done, `1b48bf3` + `e7c35e3`):** the six simple tools
> (`file_append`/`delete`/`move`/`copy`/`mkdir`/`stat`), `file_replace_regex`
> (over FPC's in-tree `regexpr`), and `file_search_replace` (glob-driven, with
> `dryRun`; the ask scopes on the glob's leading directory, so one `dir_ext`
> grant covers the batch). `make check` green (1366 tests, leak-clean).
> **Remaining:** Phases 4–5 — the structured formats (`json_read`/`json_edit`,
> `yaml_read`/`yaml_edit`) and `patch_apply` (the two new pure units
> `hildegard.helper.patch` and `hildegard.helper.yaml`).

## Implementation Tasks

### Phase 1: The simple tools (`hildegard.helper.files`)

- [x] **Test**: `file_append` creates then appends (`test_file_tools`).
- [x] **Implement**: `AppendFile`.
- [x] **Test**: `file_delete`/`file_move`/`file_copy`/`file_mkdir`/`file_stat`
      round-trip on a temp dir.
- [x] **Implement**: `DeleteFile`/`MoveFile`/`CopyFile`/`MakeDir`/`StatFile`.
- [x] **Register** them with `MakeToolSpec` + the `reason` param.

### Phase 2: Regex replace

- [x] **Test**: `file_replace_regex` replaces all/one, honours `i`, errors on a
      bad pattern, and bounds the count.
- [x] **Implement**: `ReplaceRegex` over FPC `RegExpr`.
- [x] **Test**: a path outside the workspace is refused; approval is asked first
      (a fake service records the subject path).
- [x] **Implement**: `ResolveChecked` + `Approve` with the operation's path.

### Phase 3: Multi-file search/replace

- [x] **Test**: `file_search_replace` over a glob hits the right files; `dryRun`
      writes nothing; the count is bounded.
- [x] **Implement**: `SearchReplace` (reuse the glob matcher; apply
      `ReplaceRegex` per file).
- [x] **Test**: the ask is write-shaped and scopes on the searched directory.
- [x] **Implement**: the ask's subject path = the searched directory.

### Phase 4: Structured formats

- [ ] **Test**: `json_read`/`json_edit` at a pointer; a parse failure never
      writes.
- [ ] **Implement**: `JsonRead`/`JsonEdit` over `fpjson`.
- [ ] **Test**: `yaml_read`/`yaml_edit` on the subset; an out-of-subset
      construct errors with a line number.
- [ ] **Implement**: `hildegard.helper.yaml` (`ParseYaml`, `SetYamlPath`) and the
      two handlers.

### Phase 5: Patches

- [ ] **Test**: `hildegard.helper.patch` applies a clean diff, counts a bad hunk
      rejected, `dryRun` writes nothing (`test_patch`).
- [ ] **Implement**: `ApplyUnifiedPatch` (pure; injected read/write).
- [ ] **Test**: `patch_apply` wires it to the workspace + approval.
- [ ] **Implement**: `PatchApply`.

### Phase 6: Validation & docs

- [ ] **Run**: `make test SUITE=TFileToolTest,TPatchTest,TYamlTest`
- [ ] **Run**: `make check` (all gates)
- [ ] **Update** `FEATURES.md`; **Update the SPEC** if behaviour diverged;
      rename this TODO to `File_Tools_v2.DONE.md`.

## Files to Create/Modify

### New Files

```
docs/features/File_Tools/File_Tools_v2.SPEC.md
docs/features/File_Tools/File_Tools_v2.TODO.md
src/hildegard.helper.patch.pas
src/hildegard.helper.yaml.pas
tests/test_patch.pas
tests/test_yaml.pas
```

### Modified Files

```
src/hildegard.helper.files.pas     (13 new handlers + registration)
tests/test_file_tools.pas          (the new tool tests)
tests/hildegard_helper_tests.pas   (register test_patch, test_yaml)
```

## Dependencies & Ordering

### Must Complete Before Starting

- Nothing hard; **Approval Path Scoping v1 Phases 1–4** makes the multi-file ask
  useful (one `dir_ext` grant instead of N prompts).

### Critical Path

1 (simple tools) -> 2 (regex) -> 3 (multi-file) -> 4 (formats) -> 5 (patch) -> 6.

## Success Criteria

- [ ] All tasks checked
- [ ] Every SPEC acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] Each tool maps to a `bash` idiom, and each is gated + confined + reasoned
- [ ] A `dir_ext` grant makes a multi-file replace one prompt

## Notes & Considerations

- **Each tool owns its ask.** The write-shaped tools offer `dir`/`ext`/`dir_ext`
  once Path Scoping lands; reads stay read-shaped. No shared option builder.
- **The patch and YAML parsers are pure** (injected I/O / string in-out), so
  they are unit-testable without a filesystem.
- **Bound the runaway.** A model-authored regex across a tree is capped
  (files/replacements), so a bad pattern cannot hang the turn.
- Record deviations from the SPEC here.
