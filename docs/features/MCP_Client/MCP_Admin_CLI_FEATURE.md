# MCP Admin CLI

## Overview

Give the operator a command-line way to manage MCP servers — **add, list,
remove, enable, disable** — instead of hand-writing SQL into the `mcp_servers`
table. It is the "operator UI" that MCP v1 deliberately deferred: a thin,
scriptable front end over the store methods the client already uses.

Scope is deliberately small: it edits config; it does not run servers, connect,
or call tools. Listing a server is reading a row, not spawning a process.

## Problem Statement

MCP v1 stores servers in the scoped `mcp_servers` table, and the only way to add
one is an `INSERT` by hand (the operator preference recorded in `MCP_v1.DONE.md`:
"handle the UI later"). That is error-prone — the `args`/`env` columns are JSON
arrays, `scope`/`workspace_id`/`agent_id` must line up, and a typo silently
produces a server that never starts. Extending the tool surface should be one
command, not a SQL incantation.

Ponytail check: the store already exposes `SaveMcpServer` / `LoadMcpServers` /
`RemoveMcpServer` / `ListMcpServers`, and the agent CLI already resolves the
store path and workspace. The genuine gap is a **parser** (pure, testable) and a
small dispatcher. No new store code.

## Goals

- `mcp add NAME COMMAND -- [ARGS...]` writes a server row (scope global by
  default; `--scope workspace` for this workspace).
- `mcp list` prints the effective servers for a scope (name, command, scope,
  enabled).
- `mcp remove NAME`, `mcp enable NAME`, `mcp disable NAME` edit the row.
- The parser is pure (no I/O), so it is fully unit-tested; only the dispatcher
  touches the store.
- No LLM/network needed to run any `mcp` command.

## User Stories

- As an **operator**, I want to add a server in one command, so I can try new
  MCP tools without writing SQL.
- As an **operator**, I want to list what is configured, so I can see the
  effective set and spot a disabled or workspace-scoped entry.
- As an **operator**, I want to disable a server without deleting it, so I can
  turn a noisy integration off and back on.
- As a **developer**, I want the grammar unit-tested, so the CLI cannot silently
  misparse docker-style args (`-i`, `--rm`).

## Acceptance Criteria

### Functional Requirements

- [ ] `ParseMcpCommand` (pure) recognises: `list`, `add`, `remove`, `enable`,
      `disable`, and `help`; unknown ⇒ a clear error.
- [ ] `add`: `NAME COMMAND` are positional; the server args are everything after
      a `--` separator (so `-i`, `--rm`, `--init` are **not** mistaken for
      flags). Options: `--scope global|workspace` (default global), `--env
      NAME=VALUE` (repeatable), `--cwd DIR`, `--disabled`.
- [ ] `remove`/`enable`/`disable`: `NAME` positional; `--scope`.
- [ ] Validation mirrors `ValidateMcpServerRow` (name charset, non-empty
      command, env `NAME=VALUE`); the parser reports the error before any write.
- [ ] `FormatMcpServers` renders a stable, human-readable listing (name, scope,
      command, enabled) — no JSON required for v1.
- [ ] The dispatcher (agent CLI) opens the store, resolves the workspace id for
      `--scope workspace`, and calls the store methods; it never spawns a server.
- [ ] `add` on an existing `(scope, workspace, name)` upserts (the store already
      does), and the command reports which happened.
- [ ] Every command prints a clear success line or a non-zero-exit error.

### Non-Functional Requirements

- [ ] The parser is pure and unit-tested; no store/network in the parser tests.
- [ ] `make check` green.
- [ ] No new dependency.

## Success Metrics

### Quantitative

- Adding a server is one command (target: 0 SQL statements typed).
- A misparse (docker args) is impossible: a test asserts `-i`/`--rm` land in
  `Args`, not the option set.

### Qualitative

- The grammar is memorable and matches how the servers are described in docs.

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`; reuse `hildegard.helper.mcp.config`
  (`TMcpScope`, `TMcpServerRow`, validation) and `hildegard.helper.store`.
- POSIX (macOS/Linux); no dependency.

## Dependencies

### Internal

- `hildegard.helper.store` (`SaveMcpServer` etc.).
- `hildegard.helper.mcp.config` (`TMcpServerRow`, `TMcpScope`,
  `ValidateMcpServerRow`).
- `examples/agent_cli.pas` (the entry point; the `mcp` subcommand is handled
  before any LLM setup).

### External

- None.

## Risks

- **Flag/arg ambiguity** (docker args look like flags) — Mitigation: the `--`
  separator; tested.
- **Scope/workspace mix-up** — Mitigation: `--scope workspace` requires a
  resolvable workspace; the parser/dispatcher error clearly if none.

## Out of Scope

- **Running/connecting/testing a server** (`mcp test`). The CLI edits config.
- **Interactive/TUI management.** v1 is the CLI; a screen is later.
- **Agent-scoped rows** (reserved in the schema) — the CLI writes global and
  workspace only for now.
- **File import/export** (JSON/TOML) — a separate, deferred feature.

## Future Considerations

- `mcp test NAME` — connect, `initialize`, list tools, report (reuses the client).
- `mcp export`/`import` (JSON), the file-config seam.
- Agent-scope flags once agents can self-configure.
- A `--json` output for scripting.

## Notes

- **ICE score: Impact 6, Confidence 9, Ease 9.** Small, unblocked, immediately
  useful; the only real work is the parser grammar, which is why it is tested.
