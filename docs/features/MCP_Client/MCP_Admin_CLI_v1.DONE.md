# Implementation Plan: MCP Admin CLI v1

**Related Specification:** `MCP_Admin_CLI_v1.SPEC.md`
**Related Feature:** [MCP_Admin_CLI_FEATURE.md](MCP_Admin_CLI_FEATURE.md)

## Implementation Tasks

### Phase 1: Parser (`hildi.mcp.cli`)

- [x] **Test**: `tests/test_mcp_cli.pas` — list/add(--split)/scope/env/cwd/
      disabled/remove/enable/disable/errors/format — red.
- [x] **Implement**: `TMcpVerb`, `TMcpCommand`, `EMcpCLIError`,
      `ParseMcpCommand`, `FormatMcpServers`, `McpUsageText`.
- [x] **Register** `test_mcp_cli` in `tests/hildi_tests.pas`.
- [x] **Refactor**; `make check`.

### Phase 2: Dispatch (`examples/agent_cli.pas`)

- [x] **Detect** `mcp` as the first arg before any LLM setup; parse and dispatch.
- [x] **Implement**: `RunMcpAdmin` — open the store, resolve the workspace for
      `--scope workspace`, apply add/remove/enable/disable/list via the store.
- [x] **Wire** `--help` to include the `mcp` subcommand.
- [x] **Manual**: add/list/disable/remove a real server.

### Phase 3: Validation

- [x] `make check` green.
- [x] Manual smoke against the real store (a temp copy).

## Files to Create/Modify

```
src/hildi.mcp.cli.pas   (parser; pure)
tests/test_mcp_cli.pas
tests/hildi_tests.pas   (register)
examples/agent_cli.pas             (dispatch the mcp subcommand)
```

## Notes & Considerations

- The parser is pure (mirrors `hildi.cli`); only the dispatcher
  touches the store.
- Record deviations from the SPEC here.
