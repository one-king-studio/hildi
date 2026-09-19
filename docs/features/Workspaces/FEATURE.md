# Workspaces

## Overview

A **workspace** is the directory the agent is opened in, or one passed in
explicitly, identified by its canonical absolute path and held by the agent
instance. The workspace is the anchor for relative paths, the default working
directory for commands, and the trust boundary for path checks: subpaths inside
it are auto-trusted, while paths that escape it are flagged. It is also the
identity that workspace-scoped tool approvals and sessions attach to.

Workspaces are persisted so approvals and sessions can reference a stable
directory identity across runs.

## Problem Statement

The shell tool currently resolves paths against configured "allowed roots" that
are unrelated to where the agent is actually working, and the process working
directory is implicit. There is no single, verified notion of "the directory this
agent is operating in", which is needed both to resolve relative paths sensibly
and to scope approvals per project.

## Goals

- Define the active workspace: the directory passed with `--workspace`, else the
  process working directory.
- Canonicalise it to an absolute path and persist it as a stable identity.
- Verify at startup that the directory exists and is accessible (and writable),
  failing clearly otherwise.
- Use the workspace as the base for relative-path resolution and the default
  command working directory.
- Treat subpaths of the workspace as in-bounds for path checks; flag escapes.
- Provide the workspace identity to the approval and session subsystems.

## User Stories

- As an **operator**, I want the agent to operate in the directory I opened it in,
  so relative paths and commands make sense without configuration.
- As an **operator**, I want to point the agent at another directory explicitly,
  so I can run it from anywhere.
- As an **operator**, I want the agent to fail immediately if it cannot access
  the workspace, so it does not fail confusingly later.
- As an **operator**, I want approvals for a project to be tied to that project's
  directory, so a different checkout is not implicitly trusted.

## Acceptance Criteria

### Functional Requirements

- [ ] The active workspace is `--workspace DIR` (or `HILDEGARD_WORKSPACE`) when
      given, otherwise the process working directory.
- [ ] The workspace path is canonicalised to an absolute path (resolving `.`,
      `..` and symlinks where possible) before use and persistence.
- [ ] Startup verifies the workspace exists, is a directory, and is readable;
      lacking read access is a clear, fatal configuration error.
- [ ] If the agent must write within the workspace (for example for future
      actions), writability is verified too, with a clear error otherwise.
- [ ] Relative paths in commands and tool arguments resolve against the
      workspace, not the process working directory.
- [ ] Commands default their working directory to the workspace.
- [ ] Path checks treat any path under the workspace root as in-bounds;
      paths that escape it (absolute elsewhere, `..`, or symlink-out) are flagged.
- [ ] A workspace row is persisted with its canonical path, unique, so approvals
      and sessions can reference it by identity.
- [ ] A missing workspace row is created on first use; an existing row is reused.
- [ ] The active workspace is exposed to tools and to the approval subsystem.

### Non-Functional Requirements

- [ ] Reliability: leak-clean; workspace access checks are on startup only.
- [ ] Portability: macOS and Linux (POSIX paths); Windows is out of scope for v1
      but the path helpers stay platform-neutral where cheap.
- [ ] Security: the workspace is a trust boundary, not a sandbox; the docs say so.
- [ ] `make check` passes.

## Success Metrics

### Quantitative

- Table-driven tests for canonicalisation, containment, and access failure.
- A workspace round trip against a temporary directory in tests.

### Qualitative

- "Where is the agent working?" has a single, obvious answer.
- Approval scopes and cwd no longer need separate configuration.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- Must reuse `hildegard.helper.store`; a migration adds the workspaces table.
- Must not require the Sessions/Ledger feature to function.
- Symlink resolution may be best-effort; a documented limitation is acceptable.

### Business / Time

- Workspace identity gates approvals and sessions; it is foundational.

## Dependencies

### Internal

- `hildegard.helper.store` - workspaces table and lookup by canonical path.
- Tool Approvals - consumes the workspace identity and root.
- Sessions/Ledger - sessions are bound to a workspace.
- `hildegard.helper.process` - commands default their working directory here.

### External

- Host filesystem only.

## Risks

- **Canonicalisation mismatch.** Two routes to the same directory (symlink,
  relative) could create duplicate workspace rows. Mitigation: canonicalise and
  enforce uniqueness on the canonical path; document symlink limits.
- **Workspace treated as a sandbox.** In-bounds subpaths are trusted, but the
  workspace is not isolation. Mitigation: state it in the docs and keep the real
  sandbox a separate future feature.
- **Writability assumptions.** Verifying write access can mutate the filesystem.
  Mitigation: verify with a non-destructive probe or an access check, not a
  written file, or make write verification opt-in.

## Out of Scope

- Multi-root workspaces or a workspace set.
- A real OS sandbox.
- Windows path semantics (deferred with the shell profile).
- Watching or indexing the workspace.

## Future Considerations

- Multiple named workspaces per instance.
- Per-workspace default policies or config files.
- Detecting when the workspace changes and re-scoping approvals.

## Notes

- **ICE score: Impact 8, Confidence 8, Ease 8.** Small and concrete, and it
  removes configuration in favor of an obvious default.
- **Sequencing:** implement with or before Tool Approvals so workspace-scoped
  approvals have an identity.
- **Reuse note (Ponytail):** `SysUtils` has path helpers (`ExpandFileName`,
  `IncludeTrailingPathDelimiter`, `GetCurrentDir`), and the store has migrations.
  The new pieces are the workspace record, access verification, and containment
  checks.
