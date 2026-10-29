# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0, the minor version is bumped when a batch of features reaches
*Implemented* in [`docs/features/FEATURES.md`](docs/features/FEATURES.md) — the
feature count is the trigger, not the version number itself, so the version
never moves backwards when a feature is parked or superseded.

## [Unreleased]

### Added

- MIT licence, held by One King Studio, LLC.
- README, CONTRIBUTING, SECURITY, and this changelog — the project is
  publishable.

### Changed

- **Renamed to Hildi.** `hildegard-helper` is gone from the codebase:
  binaries are `hildi`, `hildi-agent`, and `hildi-dash`; the unit namespace is
  `Hildi*`; environment variables are `HILDI_*`.
- **Units use Delphi-style PascalCase names**, with no dotted namespace:
  `HildiHarnessApp.pas`, not `hildegard.helper.harness.app.pas`.
- **The store moved to XDG**: `$XDG_DATA_HOME/hildi/store.db`, defaulting to
  `~/.local/share/hildi/store.db`. Both older locations (`~/.hildi`,
  `~/.hildegard-helper`) are still read if the new one is absent, so upgrading
  does not present an empty database as a lost history.

### Fixed

- `TSplitBoundaryTest` was verifying nothing: its `uses`-scanner collected only
  tokens containing a dot, which matched every unit when they were dotted and
  none once they were not. The dependency closure is now 77/23/22 units per
  root rather than 1.

### Deprecated

- `HILDEGARD_*` environment variables are aliased to `HILDI_*` and will be
  removed. The new spelling always wins.

## [0.1.0] — unreleased baseline

The first tagged baseline, taken at 845 commits, with **37 features marked
Implemented** in the feature index and the full gate green.

### Added

- Terminal UI (`hildi`) with streaming markdown, a conversation view, and an
  approval modal that groups asks by direction and scopes grants by path.
- Headless runtime (`hildi-agent`) driving a session over a local socket.
- Gated shell with 55+ builtin commands, classified pure/read/write by effect.
- Tool approvals: durable, scoped rules with coarse-grained buckets, plus a
  per-ask dialog showing the command, the working directory, and the scope.
- File tools with workspace confinement, including a YAML subset and a
  unified-diff applier.
- SQLite-backed sessions, turns, requests, messages, and a change log with
  per-call anchoring.
- Revert and undo: `/undo` and `/revert` restore a turn's files and transcript
  together, verified against before-hashes.
- Subagents: delegated sessions with lineage, a depth cap, and approval relay.
- MCP client: stdio and HTTP transports, OAuth refresh, per-workspace servers.
- Board, task list, and presence — durable coordination state for multiple
  sessions.
- Workspace snapshots and a turn summary with a per-file diff viewer.

[Unreleased]: https://github.com/one-king-studio/hildi/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/one-king-studio/hildi/releases/tag/v0.1.0
