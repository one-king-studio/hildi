# Component Specification: MCP Config JSON v1

**Related Feature:** [MCP_Admin_CLI_FEATURE.md](MCP_Admin_CLI_FEATURE.md)

**Depends on:** `hildi.mcp.config`, `hildi.mcp.cli`,
`hildi.store`.

## Purpose

Read and write MCP server config in the **standard `mcpServers` JSON** that the
rest of the ecosystem uses (Claude Desktop, and most server READMEs):

```json
{ "mcpServers": {
    "playwright": { "command": "docker",
                    "args": ["run","-i","--rm","--init",
                             "mcr.microsoft.com/playwright/mcp"] } } }
```

`mcp import FILE` turns that into `mcp_servers` rows; `mcp export` emits it from
the rows. This lets an operator paste a server definition from a README instead
of transcribing it, and version/share configs.

This is the "file source produces the same rows" seam that `Config_v1.SPEC.md`
reserved: the JSON maps onto `TMcpServerRowArray`, and the store is unchanged.

## Requirements

### Functional

- [x] `ParseMcpServersJson(const AJson; AScope; AWorkspaceId; out ARows;
      out AError): Boolean` — parses the `mcpServers` object into rows. Each
      entry: `command` (string, required), `args` (array of strings, optional),
      `env` (object of string→string, optional; converted to `NAME=VALUE`
      array), `cwd` (string, optional), `enabled` (bool, optional; default
      true).
- [x] `FormatMcpServersJson(const ARows): string` — the inverse: a pretty
      `{"mcpServers": {...}}` with `env` as an object.
- [x] `mcp import FILE [--scope global|workspace]` — read FILE, parse, upsert
      each row, report how many were added/updated.
- [x] `mcp export [--scope ...] [--out FILE]` — write the (effective) rows as
      JSON to stdout or FILE.
- [x] A malformed file, a missing `mcpServers`, a non-object entry, or a
      missing `command` ⇒ a clear error, no partial write (validate all, then
      write).
- [x] Names/commands are validated by `ValidateMcpServerRow` before any write.

### Non-Functional

- [x] `fpjson` (already used) does the parsing; no new dependency.
- [x] `make check` green.

## Contracts & Interfaces

```pascal
unit hildi.mcp.config;   // additions

{ Parse the standard `mcpServers` JSON into rows at a scope. Validates each
  entry. False + AError on malformed input; ARows untouched on failure. }
function ParseMcpServersJson(const AJson: string; AScope: TMcpScope;
  AWorkspaceId: Integer; out ARows: TMcpServerRowArray;
  out AError: string): Boolean;

{ Render rows as a pretty `mcpServers` JSON document. }
function FormatMcpServersJson(const ARows: TMcpServerRowArray): string;
```

```pascal
unit hildi.mcp.cli;   // additions

type
  TMcpVerb = (mvList, mvAdd, mvRemove, mvEnable, mvDisable, mvTest,
              mvImport, mvExport, mvHelp);

  TMcpCommand = record
    // ... existing ...
    Path: string;                 // import: the file; export: --out target
  end;
```

### Data Contracts

- **`env` shape.** On import, `{"K":"V"}` → `["K=V", ...]` (object order
  preserved). On export, the array → an object. A duplicate `NAME` keeps the
  last.
- **Unknown keys** in a server entry are ignored (forward compatible).
- **`import` merge.** Each entry upserts by `(scope, workspace, name)` — the
  store's existing behaviour. The command reports `added N, updated M`.
- **`export` scope.** Default: all rows. `--scope workspace` limits to the
  effective set for the current workspace.

### Event Contracts

- None.

## Architecture

### Prior Art & Reuse

- **`fpjson`** (rung 3) parses/emits; this is a mapping layer.
- **`ValidateMcpServerRow`** validates before write.
- **The store's upsert** (`SaveMcpServer`) does the merge.
- **Genuine gap:** the JSON↔row mapping and the two verbs.

### Component Boundaries

- **Responsibilities:** JSON↔rows, the import/export verbs, file I/O (the
  dispatcher, not the pure units).
- **Dependencies:** `fpjson`; the dispatcher also uses `store`.

## Validation Rules

### Input

- Top-level must be an object with an `mcpServers` object (empty is valid).
- Each entry must be an object with a string `command`.

### Output Guarantees

- A failed import writes nothing (parse + validate all first).

## Error Handling

- Unreadable file / malformed JSON / bad entry ⇒ error, exit non-zero, no write.

## Testing Requirements

### Unit Tests (`tests/test_mcp_config.pas`)

- [x] `ParseMcpServersJson` on a valid document yields the expected rows (args,
      env object→array, cwd, enabled).
- [x] A missing `command`, a non-object entry, a malformed document, or a
      missing `mcpServers` ⇒ False + error.
- [x] `FormatMcpServersJson` round-trips through `ParseMcpServersJson`.

### Unit Tests (`tests/test_mcp_cli.pas`)

- [x] `import FILE` and `export` parse (Path captured); `import` without a path
      raises.

### Integration Tests

- [x] Manual: `mcp export` prints JSON; `mcp import` of that JSON recreates the
      rows.

## Performance Targets

- Instant; no network.

## Security Considerations

- Imported `command`/`args` are operator-supplied (same trust as `mcp add`).
- Secrets belong in `env`, not `args` (unchanged).

## Success Criteria

- [x] Import/export round-trip; `make check` green.

## Future Considerations

- JSONC/TOML; `--merge` vs `--replace`; `--all-workspaces` export.
