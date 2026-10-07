# Component Specification: MCP Admin — Test v1

**Related Feature:** [MCP_Admin_CLI_FEATURE.md](MCP_Admin_CLI_FEATURE.md)

**Depends on:** `hildegard.helper.mcp.cli` (the parser),
`hildegard.helper.mcp.client` (`TMcpClient`),
`hildegard.helper.mcp.config`, `hildegard.helper.store`.

## Purpose

`mcp test NAME` connects to a configured server — spawn, `initialize`,
`tools/list` — and reports what it found, then disconnects. It answers "is this
server wired up correctly?" without starting an agent or a turn.

This is the one admin command that *runs* a server; the others only edit config.

## Requirements

### Functional

- [x] The parser gains `mvTest` (`test NAME [--scope ...]`).
- [x] The dispatcher resolves the named server's effective row (by scope), builds
      a `TMcpClientConfig`, and `TMcpClient.Open`s it (bounded by the row's
      list timeout).
- [x] On success it prints: the server name, the negotiated protocol version,
      the tool count, and each tool's model-visible name and ref.
- [x] On failure it prints the client's error (spawn failure, refused protocol,
      list timeout) and exits non-zero.
- [x] It always closes the client (child teardown) before exiting.
- [x] A missing server name (no matching row) is a clear error.

### Non-Functional

- [x] Reuses `TMcpClient` unchanged; no new client code.
- [x] The connect/list wait is bounded (the row's `list_timeout_ms`, or the
      client default).
- [x] `make check` green.

## Contracts & Interfaces

```pascal
unit hildegard.helper.mcp.cli;   // addition

type
  TMcpVerb = (mvList, mvAdd, mvRemove, mvEnable, mvDisable, mvTest, mvHelp);
```

The dispatcher (`examples/agent_cli.pas`) implements `mvTest`:

```pascal
{ Load the effective row for Name/Scope, open a client, list tools, close. }
function RunMcpTest(const AName: string; AScope: TMcpScope;
  AStore: TSqliteStore; AWorkspaceId: Integer): Integer;
```

### Data Contracts

- **Row lookup.** The server must exist at the requested scope (or be effective
  for the workspace when `--scope workspace`). Its `Command`/`Args`/`Env`/`Cwd`/
  timeouts feed the `TMcpClientConfig` exactly as the manager would.
- **Output shape.**
  ```
  testing "playwright" ...
  OK: Playwright 1.64.0  protocol 2024-11-05  25 tools
    mcp_playwright_browser_navigate   [mcp/playwright/browser_navigate]
    ...
  ```
- **No approval.** `test` only lists tools; it never calls one, so no approval
  service is needed (pass nil).

### Event Contracts

- None.

## Architecture

### Prior Art & Reuse

- **`TMcpClient`** already does spawn → initialize → `tools/list` and exposes
  `Tools` (with `Name`/`Ref`) — `test` is `Open` + print.
- **`LoadMcpServers` + `ResolveMcpConfig`** give the effective row.
- **Genuine gap:** the verb and the report.

### Component Boundaries

- **Responsibilities:** the `mvTest` verb, the row lookup, the report.
- **Side effects:** spawns a child and closes it (no store writes).

## Validation Rules

### Input

- `test` requires `NAME`.

### Output Guarantees

- The client is closed on every path (success or failure).

## Error Handling

- No such server ⇒ error, exit 1.
- `Open` failure ⇒ print the error, exit 1; the client is closed.

## Testing Requirements

### Unit Tests (`tests/test_mcp_cli.pas`)

- [x] `ParseMcpCommand(['test', 'playwright'])` ⇒ `mvTest`, name, default scope.
- [x] `test` with `--scope workspace` parses the scope.
- [x] `test` without a name raises `EMcpCLIError`.

### Integration Tests

- [x] Manual: `mcp test` against a real configured server prints its tools
      (Playwright), and against a bogus command reports the spawn failure.

## Performance Targets

- Bounded by the server's initialize/list time.

## Security Considerations

- Spawns an operator-configured server (same trust as the manager). No approval
  needed (no tool is called).

## Success Criteria

- [x] `mcp test NAME` reports a server's tools; `make check` green.

## Future Considerations

- `--json` output; `mcp test --all`.
