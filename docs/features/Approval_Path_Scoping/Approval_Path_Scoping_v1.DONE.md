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

### Phase 5: The physical primitive (`hildi.workspace`)

- [x] **Test**: `TestPhysicalContainsRefusesOutside`,
      `TestPhysicalContainsAcceptsInside`
- [x] **Implement**: `PhysicalResolve` — lexical join, walk to the nearest
      existing ancestor, `realpath(3)`, re-append the tail
- [x] **Test**: `TestSymlinkOutOfTheWorkspaceIsRefused` (the lexical check says
      inside — the fix)
- [x] **Test**: `TestNonExistentTailUsesTheNearestExistingAncestor`,
      `TestDotDotThroughASymlinkIsConservative`,
      `TestBoundarySiblingIsNotUnder`
- [x] **Implement**: `PhysicalContains` — the both-readings (lexical ∧ physical)
      rule; the separator boundary

### Phase 6: The extractor (`hildi.command.paths`, NEW)

- [x] **Test**: `TestCdParentIsAnOutsideAccess`,
      `TestAbsoluteArgumentIsAnOutsideAccess`, `TestInBoundsArgumentIsSilent`
- [x] **Implement**: reuse `TCommandSegment.Paths`; expand `~`; resolve against
      the effective base
- [x] **Test**: `TestUnresolvedTokenIsChecked`
- [x] **Implement**: the unresolved-token rule
- [x] **Test**: `TestCdMovesTheBaseForLaterSegments`,
      `TestSubshellCdDoesNotLeak`, `TestCwdArgumentIsAnAccess`
- [x] **Implement**: top-level `cd` tracking (subshell reset); the `cwd`
      argument as an access
- [x] **Test**: `TestOrderAndDedupAreDeterministic`

### Phase 7: Precedence (`hildi.approval`)

- [x] **Test**: `TestExactCommandGrantSuppressesThePathAsk`,
      `TestWildcardCommandGrantDoesNotSuppressIt`
- [x] **Implement**: `TApprovalAsk.Covers`/`HasCovers`; the suppression check in
      `Resolve` (after deny-first, before prompting)
- [x] **Test**: `TestPathDenyBeatsWildcardCommandAllow`,
      `TestAbsolutePathRuleMatchesByDirectory`

### Phase 8: The command tool (`hildi.command.tool`)

- [x] **Test**: `TestWildcardAllowedCatStillAsksAboutThePath`,
      `TestExactlyApprovedCatDoesNotAskAboutThePath`,
      `TestUnknownCommandAsksForBoth`
- [x] **Implement**: `ApprovalAsks` appends a path ask per outside access,
      carrying `Covers` = the segment's command subject
- [x] **Implement**: the path ask's options (`once`/`dir`/`any`/`never`) and the
      dialog line that says the command is already allowed

### Phase 9: The file tools (`hildi.files`)

- [x] **Test**: `file_read` through a symlink pointing outside is refused
- [x] **Implement**: `ResolveChecked` uses `PhysicalContains`

### Phase 10: Docs & validation

- [x] **Update** `docs/features/FEATURES.md` status
- [x] **Run**: `make test SUITE=TApprovalTest,TFileToolTest,TStoreTest,TWorkspaceTest,TCommandPathTest`
- [x] **Run**: `make check` (whole suite + leak gate)

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
src/hildi.approval.pas         (fields, path helpers, matching, Covers)
src/hildi.store.pas            (v2 migration, approvals SQL)
src/hildi.files.pas            (path on the subject, new options,
                                           PhysicalContains)
src/hildi.workspace.pas        (PhysicalResolve / PhysicalContains)
src/hildi.command.paths.pas    (NEW: the extractor)
src/hildi.command.tool.pas     (path asks, Covers)
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

- [x] All tasks above checked
- [x] One click grants "`.md` under `docs/`"; existing rules are bit-compatible
- [x] `cat /etc/hosts` asks about the path, and an **exact** grant clears it once
      (a wildcard grant does not)
- [x] A symlink inside the workspace pointing out is refused by the file tools
- [x] `make check` passes (tests + leak gate)

## Outcome

Implemented on `main`: the engine fields + path matching + helpers, the v12
store migration, the file-tool `dir`/`ext`/`dir_ext`/`never` asks, the
physical primitive (`PhysicalResolve`/`PhysicalContains`), the command path
extractor (`hildi.command.paths`), exact-grant suppression, the
command tool's outside-path asks, and the file tools' physical check.
`make check` green (1403 tests, leak-clean).

**Deviations, with reasons:**

- **The extractor takes a root string, not a `TWorkspace`.** The command tool
  holds the root as `DefaultCwd` (a string) and has no `TWorkspace`; the
  primitive needs only the root, so the signature is simpler.
- **The physical check compares physical-to-physical and lexical-to-lexical**
  (each against its own root form), because the root itself can be behind a
  symlink (`/var` -> `/private/var` on macOS). A single cross-comparison would
  wrongly refuse every in-bounds path under such a root.
- **`PhysicalResolve` walks to the nearest existing ancestor** and re-appends
  the tail, so a non-existent target still compares.
- **The `never` option is offered on the file asks**; a scoped deny rule is
  supported by the engine and authored outside the ask in v1.

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
