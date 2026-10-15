# Implementation Plan: Approval Path Scoping v1

**Related Specification:** `Approval_Path_Scoping_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Add directory/extension matching dimensions and a persistable `never` to the
approval engine, declare the operation's path on the subject, offer the new
options from the file tool, and migrate the `approvals` table. Two consumers
share the engine: the **file tools** (workspace-relative paths, scoping a grant
within the workspace) and the **command tool** (absolute paths, gating a command
that names something outside the workspace root). TDD-first; update tasks in
real time.

> **Progress (Phases 1–4 done, `f0bc651`):** the engine fields + matcher, the v12
> store migration (rebuild `approvals` with `directory`/`extension` + the
> extended UNIQUE), and the file-tool asks (`dir`/`ext`/`dir_ext`/`never`;
> extension scoping on write-shaped refs only; `file_glob`/`file_grep` scope on
> the searched directory). The modal already renders options dynamically, so
> Phase 4 needed no code change. `make check` green (1354 tests, leak-clean).
> **Remaining:** Phases 5–8 — the command boundary (the physical resolver, the
> path extractor, precedence, and the command-tool ask). The `never` option is
> offered on file asks; the SPEC's `TestNeverPersistsADenyRule` is covered by the
> engine's `TestScopedDenyWins` and the option's shape rather than a dedicated
> test (a follow-up could add one).

## Implementation Tasks

### Phase 1: Engine (pure, no store)

- [x] **Define** the `TApprovalRule.Directory`/`.Extension` and
      `TApprovalSubject.Path` fields; add `NormalizeDirectory`,
      `NormalizeExtension`, `PathInDirectory`, `PathHasExtension`
- [x] **Test**: `TestDirectoryMatchesSubtree`,
      `TestDirectoryDoesNotMatchPrefixSibling`, `TestExtensionMatchesCaseInsensitively`,
      `TestExtensionNormalisesLeadingDot`, `TestEmptyDirectoryOrExtensionMatchesAny`
- [x] **Implement**: the path helpers
- [x] **Test**: `TestDirectoryAndExtensionBothRequired`,
      `TestV1RuleMatchesUnchanged`, `TestScopedDenyWins`,
      `TestPathlessSubjectNeverMatchesPathRule`
- [x] **Implement**: extend `ApprovalMatches` (params match + path dimensions);
      `Decide` untouched

### Phase 2: Store migration

- [x] **Test**: `TestApprovalsMigrationRebuildsWithPathColumns`,
      `TestRulesDifferingOnlyByPathCoexist`, `TestPathRulesRoundTrip`
- [x] **Implement**: the v2 migration (rebuild `approvals` with the new columns
      and the extended `UNIQUE`); carry the columns through `Load`/`Save`/
      `Remove`

### Phase 3: File tool asks

- [x] **Test**: `TestWriteAskOffersPathOptions`,
      `TestReadAskOmitsExtensionScoping`,
      `TestGlobAskScopesOnTheDirectoryNotThePattern`,
      `TestNeverPersistsADenyRule`
- [x] **Implement**: `Approve` takes the operation's path and sets
      `Subject.Path`; add the `dir`/`ext`/`dir_ext`/`never` options per ref
      shape (write-shaped vs read-shaped); leave the command tool's options
      untouched

### Phase 4: Modal / CLI

- [x] **Test**: `TestModalRendersManyOptions` (the seven-option ask fits and
      selects)
- [x] **Verify**: the CLI prompt renders the extra options through the existing
      ask/option mechanism (no code change expected)

### Phase 5: The physical primitive (`hildegard.helper.workspace`)

- [ ] **Test**: `TestPhysicalContainsRefusesOutside`,
      `TestPhysicalContainsAcceptsInside`
- [ ] **Implement**: `PhysicalResolve` — lexical join, walk to the nearest
      existing ancestor, `realpath(3)`, re-append the tail
- [ ] **Test**: `TestSymlinkOutOfTheWorkspaceIsRefused` (the lexical check says
      inside — the fix)
- [ ] **Test**: `TestNonExistentTailUsesTheNearestExistingAncestor`,
      `TestDotDotThroughASymlinkIsConservative`,
      `TestBoundarySiblingIsNotUnder`
- [ ] **Implement**: `PhysicalContains` — the both-readings (lexical ∧ physical)
      rule; the separator boundary

### Phase 6: The extractor (`hildegard.helper.command.paths`, NEW)

- [ ] **Test**: `TestCdParentIsAnOutsideAccess`,
      `TestAbsoluteArgumentIsAnOutsideAccess`, `TestInBoundsArgumentIsSilent`
- [ ] **Implement**: reuse `TCommandSegment.Paths`; expand `~`; resolve against
      the effective base
- [ ] **Test**: `TestUnresolvedTokenIsChecked`
- [ ] **Implement**: the unresolved-token rule
- [ ] **Test**: `TestCdMovesTheBaseForLaterSegments`,
      `TestSubshellCdDoesNotLeak`, `TestCwdArgumentIsAnAccess`
- [ ] **Implement**: top-level `cd` tracking (subshell reset); the `cwd`
      argument as an access
- [ ] **Test**: `TestOrderAndDedupAreDeterministic`

### Phase 7: Precedence (`hildegard.helper.approval`)

- [ ] **Test**: `TestExactCommandGrantSuppressesThePathAsk`,
      `TestWildcardCommandGrantDoesNotSuppressIt`
- [ ] **Implement**: `TApprovalAsk.Covers`/`HasCovers`; the suppression check in
      `Resolve` (after deny-first, before prompting)
- [ ] **Test**: `TestPathDenyBeatsWildcardCommandAllow`,
      `TestAbsolutePathRuleMatchesByDirectory`

### Phase 8: The command tool (`hildegard.helper.command.tool`)

- [ ] **Test**: `TestWildcardAllowedCatStillAsksAboutThePath`,
      `TestExactlyApprovedCatDoesNotAskAboutThePath`,
      `TestUnknownCommandAsksForBoth`
- [ ] **Implement**: `ApprovalAsks` appends a path ask per outside access,
      carrying `Covers` = the segment's command subject
- [ ] **Implement**: the path ask's options (`once`/`dir`/`any`/`never`) and the
      dialog line that says the command is already allowed

### Phase 9: The file tools (`hildegard.helper.files`)

- [ ] **Test**: `file_read` through a symlink pointing outside is refused
- [ ] **Implement**: `ResolveChecked` uses `PhysicalContains`

### Phase 10: Docs & validation

- [ ] **Update** `docs/features/FEATURES.md` status
- [ ] **Run**: `make test SUITE=TApprovalTest,TFileToolTest,TStoreTest,TWorkspaceTest,TCommandPathTest`
- [ ] **Run**: `make check` (whole suite + leak gate)

## Dependencies & Ordering

- Engine fields and helpers before the store migration.
- The store before the file-tool options (the options persist rules).
- The file-tool `Approve` signature change before the option tests.
- Phase 5 (the physical primitive) before Phase 6 (the extractor); Phase 6 and
  Phase 7 before Phase 8 (the command tool adapter). Phase 9 (the file tools'
  physical check) depends only on Phase 5.

## Files to Create/Modify

### Modified Files

```
src/hildegard.helper.approval.pas         (fields, path helpers, matching, Covers)
src/hildegard.helper.store.pas            (v2 migration, approvals SQL)
src/hildegard.helper.files.pas            (path on the subject, new options,
                                           PhysicalContains)
src/hildegard.helper.workspace.pas        (PhysicalResolve / PhysicalContains)
src/hildegard.helper.command.paths.pas    (NEW: the extractor)
src/hildegard.helper.command.tool.pas     (path asks, Covers)
tests/test_approval.pas                   (matcher cases, suppression)
tests/test_store.pas                      (migration, round-trip)
tests/test_file_tool.pas                  (option sets, the symlink refusal)
tests/test_tui_approvalmodal.pas          (many options)
tests/test_workspace.pas                  (physical containment)
tests/test_command_paths.pas              (NEW)
tests/test_command_tool.pas               (the boundary asks)
docs/features/FEATURES.md                 (status)
```

## Success Criteria

- [ ] All tasks above checked
- [ ] One click grants "`.md` under `docs/`"; existing rules are bit-compatible
- [ ] `cat /etc/hosts` asks about the path, and an **exact** grant clears it once
      (a wildcard grant does not)
- [ ] A symlink inside the workspace pointing out is refused by the file tools
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
- **The command boundary is separate from scoping.** The file tools' path is
  workspace-relative and *confined*; the command's is absolute and *outside* —
  the two spaces never cross-match. The engine is shared; the boundary policy
  (which accesses ask, and the exact-grant suppression) lives in the command
  tool.
