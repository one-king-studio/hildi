# Component Specification: MCP Admin CLI v1

**Related Feature:** [MCP_Admin_CLI_FEATURE.md](MCP_Admin_CLI_FEATURE.md)

**Depends on:** `hildegard.helper.mcp.config`, `hildegard.helper.store`.
**Depended on by:** `examples/agent_cli.pas` (the `mcp` subcommand).

## Purpose

A pure parser for the `mcp` subcommand and a thin dispatcher that applies the
parsed command to the store. The parser is the testable core; the dispatcher is
the only part that touches I/O.

## Requirements

### Functional

- [ ] `ParseMcpCommand(const AArgs: array of string): TMcpCommand` — pure;
      recognises `list`, `add`, `remove`, `enable`, `disable`, `help`; raises
      `EMcpCLIError` with a clear message on an unknown verb or bad option.
- [ ] `add` grammar: `add NAME COMMAND [OPTIONS] -- [ARGS...]`; the `--`
      separator splits options from server args (so server args may start with
      `-`).
- [ ] Options: `--scope global|workspace`, `--env NAME=VALUE` (repeatable),
      `--cwd DIR`, `--disabled`. `remove`/`enable`/`disable` take `NAME` and
      `--scope`.
- [ ] `FormatMcpServers(const ARows: TMcpServerRowArray): string` — a stable
      table (name, scope, command, enabled), sorted by scope then name.
- [ ] `McpUsageText` — the sub-help.
- [ ] The dispatcher applies the command via `TSqliteStore`; `list` uses
      `LoadMcpServers` (effective for the scope) or `ListMcpServers` (all).

### Non-Functional

- [ ] Parser pure and unit-tested; `make check` green; no dependency.

## Contracts & Interfaces

```pascal
unit hildegard.helper.mcp.cli;
{ Pure parsing for the `mcp` admin subcommand. No store, no I/O. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, hildegard.helper.mcp.config;

type
  TMcpVerb = (mvList, mvAdd, mvRemove, mvEnable, mvDisable, mvHelp);

  { A parsed `mcp` command. Fields are meaningful per Verb. }
  TMcpCommand = record
    Verb: TMcpVerb;
    Name: string;                 // add/remove/enable/disable
    Command: string;              // add: the executable
    Args: array of string;        // add: server argv (after --)
    Scope: TMcpScope;             // default msGlobal
    Env: array of string;         // add: NAME=VALUE (repeatable)
    WorkingDir: string;           // add: --cwd
    Disabled: Boolean;            // add: --disabled
  end;

  EMcpCLIError = class(Exception);

function ParseMcpCommand(const AArgs: array of string): TMcpCommand;
function FormatMcpServers(const ARows: TMcpServerRowArray): string;
function McpUsageText: string;
```

### Data Contracts

- **`--` separator.** Everything before `--` is options/positionals; everything
  after is `Args` verbatim. `mcp add playwright docker -- run -i --rm --init
  mcr.microsoft.com/playwright/mcp` ⇒ `Command='docker'`,
  `Args=['run','-i','--rm','--init','mcr.microsoft.com/playwright/mcp']`.
- **Scope.** `--scope workspace` sets `Scope=msWorkspace`; the dispatcher fills
  `WorkspaceId` from the resolved workspace. Default `msGlobal`.
- **Validation.** `add` validates name/command/env with
  `ValidateMcpServerRow` before the dispatcher writes.
- **Formatting.** One line per server: `SCOPE  NAME  COMMAND [args...]  (state)`.

### Event Contracts

- None.

## Architecture

### Prior Art & Reuse

- **`hildegard.helper.cli`** is the precedent for a pure, unit-tested parser;
  this mirrors its shape (`Parse*` + `UsageText` + `ECLIError`).
- **`hildegard.helper.mcp.config`** supplies the types and `ValidateMcpServerRow`.
- **`TSqliteStore`** already has the four methods; the dispatcher is a thin map.
- **Genuine gap:** the grammar and the dispatcher wiring.

### Component Boundaries

- **Responsibilities:** grammar, validation-before-write, formatting, dispatch.
- **Dependencies:** `mcp.config` (pure); the dispatcher also uses `store`.
- **Side effects:** only the dispatcher (store writes).

## Validation Rules

### Input

- `add` requires a name and a command; a missing `--` with server args present
  is an error (args before `--` are options).
- `--scope` value must be `global` or `workspace` (agent is reserved).
- `--env` value must contain `=`.

### Output Guarantees

- A parsed command is internally consistent; `list`/`help` carry no name.

## Error Handling

- Unknown verb / option / missing operand ⇒ `EMcpCLIError` with a message that
  names the offending token; the dispatcher prints it and exits non-zero.
- Store errors surface as the store's message; exit non-zero.

## Testing Requirements

### Unit Tests (`tests/test_mcp_cli.pas`)

- [ ] `ParseMcpCommand(['list'])` ⇒ `mvList`.
- [ ] `add` with `--` splits options from args; docker args (`-i`, `--rm`) land
      in `Args`, not options.
- [ ] `add` `--scope workspace`, `--env A=1 --env B=2`, `--cwd`, `--disabled`.
- [ ] `remove`/`enable`/`disable` parse the name and scope.
- [ ] Unknown verb, unknown option, missing name/command, bad `--scope`,
      bad `--env` all raise `EMcpCLIError`.
- [ ] `FormatMcpServers` renders deterministically (sorted, stable columns).

### Integration Tests

- [ ] Dispatcher: `add` writes a row; `list` shows it; `disable` flips it;
      `remove` deletes it (against a temp store).

## Performance Targets

- Instant; no network or server spawn.

## Security Considerations

- Operator-only (a local CLI). The name/command are validated before writing.
- No secret handling beyond `--env` (which stores `NAME=VALUE`, same as the
  table; the feature notes secrets belong in `env`, not argv).

## Success Criteria

- [ ] All contracts implemented; `make check` green.
- [ ] A server is added, listed, disabled, and removed entirely from the CLI.

## Future Considerations

- `mcp test NAME` (connect + list tools) reusing the client.
- `--json` output; `export`/`import`.
