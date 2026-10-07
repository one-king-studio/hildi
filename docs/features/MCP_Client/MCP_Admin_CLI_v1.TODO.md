# Implementation Plan: MCP Admin CLI v1

**Related Specification:** `MCP_Admin_CLI_v1.SPEC.md`
**Related Feature:** [MCP_Admin_CLI_FEATURE.md](MCP_Admin_CLI_FEATURE.md)

## Implementation Tasks

### Phase 1: Parser (`hildegard.helper.mcp.cli`)

- [ ] **Test**: `tests/test_mcp_cli.pas` — list/add(--split)/scope/env/cwd/
      disabled/remove/enable/disable/errors/format — red.
- [ ] **Implement**: `TMcpVerb`, `TMcpCommand`, `EMcpCLIError`,
      `ParseMcpCommand`, `FormatMcpServers`, `McpUsageText`.
- [ ] **Register** `test_mcp_cli` in `tests/hildegard_helper_tests.pas`.
- [ ] **Refactor**; `make check`.

### Phase 2: Dispatch (`examples/agent_cli.pas`)

- [ ] **Detect** `mcp` as the first arg before any LLM setup; parse and dispatch.
- [ ] **Implement**: `RunMcpAdmin` — open the store, resolve the workspace for
      `--scope workspace`, apply add/remove/enable/disable/list via the store.
- [ ] **Wire** `--help` to include the `mcp` subcommand.
- [ ] **Manual**: add/list/disable/remove a real server.

### Phase 3: Validation

- [ ] `make check` green.
- [ ] Manual smoke against the real store (a temp copy).

## Files to Create/Modify

```
src/hildegard.helper.mcp.cli.pas   (parser; pure)
tests/test_mcp_cli.pas
tests/hildegard_helper_tests.pas   (register)
examples/agent_cli.pas             (dispatch the mcp subcommand)
```

## Notes & Considerations

- The parser is pure (mirrors `hildegard.helper.cli`); only the dispatcher
  touches the store.
- Record deviations from the SPEC here.
