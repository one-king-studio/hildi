# Implementation Plan: Workspaces v1

**Related Specification:** `Workspaces_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Build `hildegard.helper.workspace`: selection, canonicalisation, access checks,
resolution, containment, and a persisted workspace identity. This lands first,
because approvals and sessions key off the workspace.

> `main`-only project: no feature branch.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [ ] Add `tests/test_workspace.pas` to the uses clause of
      `tests/hildegard_helper_tests.pas`
- [ ] Create `src/hildegard.helper.workspace.pas` with the interface from the SPEC
- [ ] Create `tests/test_workspace.pas` with an empty `TTestCase`

### Phase 2: Pure path helpers (TDD)

- [ ] **Test**: `TestCanonicalisesRelativeSegments` - red
- [ ] **Implement**: `CanonicalWorkspacePath` (`ExpandFileName`, remove trailing
      delimiter; Unix `realpath` when available) - green
- [ ] **Test**: `TestMissingDirectoryFails`, `TestFileInsteadOfDirectoryFails` -
      red
- [ ] **Implement**: `WorkspaceAccessible` (exists, is directory, readable;
      writable when required) - green
- [ ] **Test**: `TestContainsRootAndChild`, `TestDoesNotContainSiblingPrefix`,
      `TestDoesNotContainEscape` - red
- [ ] **Implement**: containment via canonical prefix with a trailing separator
      guard - green

### Phase 3: TWorkspace (TDD)

- [ ] **Test**: `TestSelectsGivenPath`, `TestDefaultsToCurrentDir`
- [ ] **Test**: `TestResolveRelativeUsesRoot`
- [ ] **Implement**: `TWorkspace.Open` / `Root` / `Resolve` / `Contains`

### Phase 4: Store identity

- [ ] **Add** migration v2 `workspaces(id INTEGER PK, path TEXT UNIQUE NOT NULL,
      created_at INTEGER NOT NULL)`
- [ ] **Test**: `TestEnsureWorkspaceIsIdempotent` - same canonical path returns
      the same id; a new path inserts one row - red
- [ ] **Implement**: `TSqliteStore.EnsureWorkspace` and `FindWorkspace`

### Phase 5: CLI wiring

- [ ] Add `--workspace DIR` (and `HILDEGARD_WORKSPACE`) to `hildegard.helper.cli`
- [ ] Open the workspace at startup in `examples/agent_cli.pas`; fail fatally if
      inaccessible; pass the root to the command tool's cwd
- [ ] Resume session + policy wiring deferred to the Approvals/Sessions features

### Phase 6: Validation

- [ ] `make test SUITE=TWorkspaceTest`
- [ ] `make test`, `make test-leak`, `make check`

## Dependencies & Ordering

- Must precede Tool Approvals (workspace context) and Sessions (workspace id).
- Store migration v2 is independent of later migrations v3/v4.

## Files to Create/Modify

### New Files

```
src/hildegard.helper.workspace.pas
tests/test_workspace.pas
```

### Modified Files

```
src/hildegard.helper.store.pas      (migration v2, EnsureWorkspace/FindWorkspace)
src/hildegard.helper.cli.pas        (--workspace option)
examples/agent_cli.pas              (open workspace, use as cwd)
tests/hildegard_helper_tests.pas    (add test unit)
tests/test_cli.pas                  (workspace option)
```

## Success Criteria

- [ ] All tasks checked; every SPEC acceptance criterion has a test
- [ ] `make check` passes; no leaks
- [ ] Agent fails clearly on an inaccessible workspace

## Notes & Considerations

- Canonicalisation may be best-effort for symlinks; document the limitation with
  a `ponytail:` comment.
- Access checks happen once at startup; containment is cheap and safe at runtime.
- Do not treat the workspace as a sandbox in code or comments.
