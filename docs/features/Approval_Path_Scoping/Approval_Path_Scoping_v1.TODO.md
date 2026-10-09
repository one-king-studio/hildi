# Implementation Plan: Approval Path Scoping v1

**Related Specification:** `Approval_Path_Scoping_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Add directory/extension matching dimensions and a persistable `never` to the
approval engine, declare the operation's path on the subject, offer the new
options from the file tool, and migrate the `approvals` table. TDD-first; update
tasks in real time.

## Implementation Tasks

### Phase 1: Engine (pure, no store)

- [ ] **Define** the `TApprovalRule.Directory`/`.Extension` and
      `TApprovalSubject.Path` fields; add `NormalizeDirectory`,
      `NormalizeExtension`, `PathInDirectory`, `PathHasExtension`
- [ ] **Test**: `TestDirectoryMatchesSubtree`,
      `TestDirectoryDoesNotMatchPrefixSibling`, `TestExtensionMatchesCaseInsensitively`,
      `TestExtensionNormalisesLeadingDot`, `TestEmptyDirectoryOrExtensionMatchesAny`
- [ ] **Implement**: the path helpers
- [ ] **Test**: `TestDirectoryAndExtensionBothRequired`,
      `TestV1RuleMatchesUnchanged`, `TestScopedDenyWins`,
      `TestPathlessSubjectNeverMatchesPathRule`
- [ ] **Implement**: extend `ApprovalMatches` (params match + path dimensions);
      `Decide` untouched

### Phase 2: Store migration

- [ ] **Test**: `TestApprovalsMigrationRebuildsWithPathColumns`,
      `TestRulesDifferingOnlyByPathCoexist`, `TestPathRulesRoundTrip`
- [ ] **Implement**: the v2 migration (rebuild `approvals` with the new columns
      and the extended `UNIQUE`); carry the columns through `Load`/`Save`/
      `Remove`

### Phase 3: File tool asks

- [ ] **Test**: `TestWriteAskOffersPathOptions`,
      `TestReadAskOmitsExtensionScoping`,
      `TestGlobAskScopesOnTheDirectoryNotThePattern`,
      `TestNeverPersistsADenyRule`
- [ ] **Implement**: `Approve` takes the operation's path and sets
      `Subject.Path`; add the `dir`/`ext`/`dir_ext`/`never` options per ref
      shape (write-shaped vs read-shaped); leave the command tool's options
      untouched

### Phase 4: Modal / CLI

- [ ] **Test**: `TestModalRendersManyOptions` (the seven-option ask fits and
      selects)
- [ ] **Verify**: the CLI prompt renders the extra options through the existing
      ask/option mechanism (no code change expected)

### Phase 5: Docs & validation

- [ ] **Update** `docs/features/FEATURES.md` status
- [ ] **Run**: `make test SUITE=TApprovalTest,TFileToolTest,TStoreTest`
- [ ] **Run**: `make check` (whole suite + leak gate)

## Dependencies & Ordering

- Engine fields and helpers before the store migration.
- The store before the file-tool options (the options persist rules).
- The file-tool `Approve` signature change before the option tests.

## Files to Create/Modify

### Modified Files

```
src/hildegard.helper.approval.pas         (fields, path helpers, matching)
src/hildegard.helper.store.pas            (v2 migration, approvals SQL)
src/hildegard.helper.files.pas            (path on the subject, new options)
tests/test_approval.pas                   (matcher cases)
tests/test_store.pas                      (migration, round-trip)
tests/test_file_tool.pas                  (option sets)
tests/test_tui_approvalmodal.pas          (many options)
docs/features/FEATURES.md                 (status)
```

## Success Criteria

- [ ] All tasks above checked
- [ ] One click grants "`.md` under `docs/`"; existing rules are bit-compatible
- [ ] `make check` passes (tests + leak gate)

## Notes & Considerations

- **The path is declared on the subject.** The engine never parses params, so
  `file_glob`/`file_grep` (which pass `[pattern, path]`) scope on the directory by setting
  `Subject.Path`. This is why no per-ref path index is needed.
- **`never` is a blanket ref deny** in the ask; the engine supports scoped
  deny rules (directory/extension) and they are tested, but authoring them from
  the ask is deferred.
- **The migration must rebuild** `approvals` — SQLite cannot change a `UNIQUE`
  with `ALTER TABLE`, and without the new columns in the `UNIQUE`,
  `INSERT OR IGNORE` would silently drop a second rule differing only by path.
- **`file:list` breadth:** a `file:list` grant (including a directory one)
  covers recursive listing, because `recursive` is not a parameter. Documented,
  not changed, to keep existing rules byte-compatible.
