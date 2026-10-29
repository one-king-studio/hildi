# Implementation Plan: Workspaces v1

**Related Specification:** `Workspaces_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Build `hildi.workspace`: selection, canonicalisation, access checks,
resolution, containment, and a persisted workspace identity. This lands first,
because approvals and sessions key off the workspace.

> `main`-only project: no feature branch.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [x] Add `tests/test_workspace.pas` to the uses clause of
      `tests/hildi_tests.pas`
- [x] Create `src/hildi.workspace.pas` with the interface from the SPEC
- [x] Create `tests/test_workspace.pas` with an empty `TTestCase`

### Phase 2: Pure path helpers (TDD)

- [x] **Test**: `TestCanonicalisesRelativeSegments` - red
- [x] **Implement**: `CanonicalWorkspacePath` (`ExpandFileName`, remove trailing
      delimiter; Unix `realpath` when available) - green
- [x] **Test**: `TestMissingDirectoryFails`, `TestFileInsteadOfDirectoryFails` -
      red
- [x] **Implement**: `WorkspaceAccessible` (exists, is directory, readable;
      writable when required) - green
- [x] **Test**: `TestContainsRootAndChild`, `TestDoesNotContainSiblingPrefix`,
      `TestDoesNotContainEscape` - red
- [x] **Implement**: containment via canonical prefix with a trailing separator
      guard - green

### Phase 3: TWorkspace (TDD)

- [x] **Test**: `TestSelectsGivenPath`, `TestDefaultsToCurrentDir`
- [x] **Test**: `TestResolveRelativeUsesRoot`
- [x] **Implement**: `TWorkspace.Open` / `Root` / `Resolve` / `Contains`

### Phase 4: Store identity

- [x] **Add** migration v2 `workspaces(id INTEGER PK, path TEXT UNIQUE NOT NULL,
      created_at INTEGER NOT NULL)`
- [x] **Test**: `TestEnsureWorkspaceIsIdempotent` - same canonical path returns
      the same id; a new path inserts one row - red
- [x] **Implement**: `TSqliteStore.EnsureWorkspace` and `FindWorkspace`

### Phase 5: CLI wiring

- [x] Add `--workspace DIR` (and `HILDI_WORKSPACE`) to `hildi.cli`
- [x] Open the workspace at startup in `examples/agent_cli.pas`; fail fatally if
      inaccessible; pass the root to the command tool's cwd
- [x] Resume session + policy wiring deferred to the Approvals/Sessions features

### Phase 6: Validation

- [x] `make test SUITE=TWorkspaceTest`
- [x] `make test`, `make test-leak`, `make check`

## Dependencies & Ordering

- Must precede Tool Approvals (workspace context) and Sessions (workspace id).
- Store migration v2 is independent of later migrations v3/v4.

## Files to Create/Modify

### New Files

```
src/hildi.workspace.pas
tests/test_workspace.pas
```

### Modified Files

```
src/hildi.store.pas      (migration v2, EnsureWorkspace/FindWorkspace)
src/hildi.cli.pas        (--workspace option)
examples/agent_cli.pas              (open workspace, use as cwd)
tests/hildi_tests.pas    (add test unit)
tests/test_cli.pas                  (workspace option)
```

## Success Criteria

- [x] All tasks checked; every SPEC acceptance criterion has a test
- [x] `make check` passes; no leaks
- [x] Agent fails clearly on an inaccessible workspace

## Notes & Considerations

- Canonicalisation may be best-effort for symlinks; document the limitation with
  a `ponytail:` comment.
- Access checks happen once at startup; containment is cheap and safe at runtime.
- Do not treat the workspace as a sandbox in code or comments.
- Deviations: canonicalisation uses `ExpandFileName` (no `realpath` symlink
  resolution) - best-effort per the spec. Writability is not probed (would mutate
  the filesystem); readable-directory access is checked at startup. The command
  tool's cwd now defaults to the workspace root; using the root for path checks
  arrives with the command approval adapter in Tool Approvals.
