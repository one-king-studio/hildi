# Component Specification: Workspaces

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildi.workspace` owns the active workspace: it selects and
canonicalises the directory, verifies access, resolves relative paths, decides
containment, and provides the persisted workspace identity that approvals and
sessions attach to.

The store gains a `workspaces` table and lookup by canonical path. The agent
instance holds one active `TWorkspace` and passes it to tools and the approval
subsystem.

## Requirements

### Functional

- [ ] Select the workspace from an explicit path, an environment override, or the
      process working directory.
- [ ] Canonicalise to an absolute path (resolve `.`, `..`, and symlinks where
      possible).
- [ ] Verify at startup that it exists, is a directory, and is readable; report a
      clear error otherwise. Verify writability when the caller requires it.
- [ ] Resolve relative paths against the workspace root.
- [ ] Decide containment: a path under the root is in-bounds; an escape is not.
- [ ] Persist a `workspaces` row keyed by the canonical path (unique) and return
      its id; reuse an existing row.
- [ ] Expose the root and id to tools, approvals, and sessions.

### Non-Functional

- [ ] Pure path logic is unit-testable without the store.
- [ ] Leak-clean; access checks happen once at startup.
- [ ] POSIX semantics for v1; no hidden platform assumptions in the path helpers.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

### Public API

```pascal
unit hildi.workspace;

interface

uses
  SysUtils, hildi.store;

type
  TWorkspace = class
  private
    FRoot: string;
  public
    { Canonicalises APath, verifies access, and returns an instance. On failure
      AError explains why. }
    class function Open(const APath: string;
      out AError: string): TWorkspace;
    function Root: string;                     // canonical absolute path
    { Resolves APath (relative or absolute) against the root. Does not require
      the result to exist. }
    function Resolve(const APath: string): string;
    { True when APath, resolved, is the root or lies under it. }
    function Contains(const APath: string): Boolean;
  end;

function CanonicalWorkspacePath(const APath: string): string;
function WorkspaceAccessible(const APath: string;
  out AError: string): Boolean;

{ Store additions (in hildi.store). }
function TSqliteStore.EnsureWorkspace(const APath: string; out AId: Integer;
  out AError: TStoreError): Boolean;
function TSqliteStore.FindWorkspace(const APath: string; out AId: Integer;
  out AError: TStoreError): Boolean;
```

### Data Contracts

```pascal
type
  { The persisted workspace identity. }
  TWorkspaceRecord = record
    Id: Integer;
    Path: string;        // canonical absolute path, unique
    CreatedAtMs: Int64;
  end;
```

### Event Contracts

None.

## Architecture

### Prior Art & Reuse

- `SysUtils` path helpers: `ExpandFileName`, `GetCurrentDir`,
  `IncludeTrailingPathDelimiter`, `ExtractFileDir`.
- Unix `realpath` (via `BaseUnix`/libc) may be used for symlink canonicalisation;
  an `{$ifdef unix}` block, with a documented fallback to `ExpandFileName`.
- `hildi.store` migrations and typed methods.

The gap: the workspace record, access verification, and containment logic.

### Component Boundaries

- **Responsibilities:** selection, canonicalisation, access check, resolution,
  containment, identity persistence.
- **Dependencies:** `SysUtils`; `hildi.store` for identity.
- **Side effects:** a workspace row may be inserted; no other filesystem writes.

### Data Flow

1. `Open(APath)` canonicalises, checks existence/readability, and stores `FRoot`.
2. `EnsureWorkspace(FRoot)` on the store returns the id (inserting if new).
3. Tools call `Resolve`/`Contains` for path decisions.
4. Approvals and sessions reference the id.

## Validation Rules

- An empty path uses the process working directory.
- A non-existent or non-directory workspace is an error.
- `Contains` compares canonical paths and treats the root itself as contained;
  it must not be fooled by a sibling with a common prefix (`/work` vs
  `/workshop`).
- Symlink escapes are best-effort; a documented limitation if `realpath` is
  unavailable.

## Error Handling

### Error Types

- **Config:** unreadable/missing workspace -> fatal at startup with a clear
  message.
- **Store:** row insert/lookup failure -> `TStoreError` returned to the caller.

### Error Contracts

Fatal startup errors terminate before the loop starts. Runtime containment
checks never raise; they return booleans.

## Testing Requirements

### Unit Tests (`tests/test_workspace.pas`)

- [ ] `TestSelectsGivenPath`
- [ ] `TestDefaultsToCurrentDir`
- [ ] `TestCanonicalisesRelativeSegments`
- [ ] `TestMissingDirectoryFails`
- [ ] `TestFileInsteadOfDirectoryFails`
- [ ] `TestResolveRelativeUsesRoot`
- [ ] `TestContainsRootAndChild`
- [ ] `TestDoesNotContainSiblingPrefix` (`/work` vs `/workshop`)
- [ ] `TestDoesNotContainEscape`
- [ ] `TestEnsureWorkspaceIsIdempotent` (store round trip)
- [ ] `TestNoLeaks`

## Performance Targets

- Startup canonicalisation once; containment is O(length of path).

## Security Considerations

- The workspace is a trust boundary for path checks, **not a sandbox**; state it.
- Access is verified before use so the agent does not operate blindly.
- Canonicalisation reduces symlink-based prefix tricks; unresolved symlinks are
  documented as a limitation.

## Success Criteria

### Functional

- [ ] Contracts implemented; workspace identity persisted and reused.
- [ ] `make check` passes.

### Quality

- [ ] Pure helpers tested without the store; store round trip tested.
- [ ] No leaks.

## Future Considerations

- Multiple named workspaces.
- Per-workspace configuration.
- Detecting a changed workspace and re-scoping.
