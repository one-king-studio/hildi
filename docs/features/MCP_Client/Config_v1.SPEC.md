# Component Specification: MCP Config v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** nothing (pure types + resolution).
**Depended on by:** `Mcp_Client_v1.SPEC.md`; persisted by
`hildi.store`.

## Purpose

The operator must be able to add an MCP server by **configuration, not code**,
and **the model must not be able to add one**. v1 stores server definitions in
the **SQLite store** (the same database as approvals, workspaces, and the
ledger), **scoped** as `global` / `workspace` / `agent`, so a helper-wide server
list, a per-project list, and (later) a per-agent list compose predictably.

This replaces the FEATURE's original "operator config file" assumption: config
is now a first-class, scoped, durable store row rather than a flat file. A file
source (JSON/JSONC/TOML) is a **future** alternative that produces the same rows
and reuses the same resolution — which is why this unit is pure and the seam is
the row array, not a file.

## Requirements

### Functional

- [ ] Define a server as: `name`, `command`, `args`, optional `env`, `cwd`,
      `enabled`, and per-server `list`/`call` timeouts.
- [ ] Persist servers in the store, **scoped** `global` / `workspace` / `agent`,
      with a uniqueness key of `(scope, workspace_id, agent_id, name)`.
- [ ] Resolve the **effective** server list for a context by precedence:
      `agent` overrides `workspace` overrides `global` on a name clash; distinct
      names union.
- [ ] Exclude disabled servers from the effective list.
- [ ] Validate strictly on write: unique name per scope, non-empty `command`,
      legal name characters, `args`/`env` are string arrays, size caps.
- [ ] Return a typed error naming the offending server/field; never crash.

### Non-Functional

- [ ] The resolution is a **pure function** (`ResolveMcpConfig`), unit-testable
      with no store and no filesystem.
- [ ] No new dependency (`fpjson` only for `args`/`env` (de)serialization at the
      store boundary).
- [ ] `make check` clean.

## Contracts & Interfaces

> Contracts are Pascal declarations, not bodies.

### Public API

```pascal
unit hildi.mcp.config;
{ Typed MCP server configuration and its scope resolution. Pure: no store, no
  files, no I/O. The SQLite store owns the rows (hildi.store); this
  unit decides which row wins for a context. A future file source produces the
  same rows and reuses the same resolution. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  { Where a server definition lives. Most specific wins on a name clash. }
  TMcpScope = (msGlobal, msWorkspace, msAgent);

  { A stored server definition, as read from any source. }
  TMcpServerRow = record
    Id: Integer;
    Scope: TMcpScope;
    WorkspaceId: Integer;   // 0 for global (and agent)
    AgentId: string;        // '' unless agent scope (reserved; agent support later)
    Name: string;
    Command: string;
    Args: array of string;
    Env: array of string;   // 'NAME=VALUE' additions (secrets stay out of argv)
    WorkingDir: string;     // '' => process cwd
    Enabled: Boolean;
    ListTimeoutMs: Integer; // 0 => client default
    CallTimeoutMs: Integer; // 0 => client default
    CreatedAt: Int64;
  end;

  TMcpServerRowArray = array of TMcpServerRow;

  { The effective server, after resolution. }
  TMcpServerConfig = record
    Name: string;
    Command: string;
    Args: array of string;
    Env: array of string;
    WorkingDir: string;
    Enabled: Boolean;
    ListTimeoutMs: Integer;
    CallTimeoutMs: Integer;
    Scope: TMcpScope;       // the scope the winning row came from
  end;

  TMcpServerArray = array of TMcpServerConfig;

  { The context a session resolves against. }
  TMcpConfigContext = record
    WorkspaceId: Integer;   // 0 = no workspace (global only)
    AgentId: string;        // '' today
  end;

  TMcpConfig = record
    Servers: TMcpServerArray;   // effective, enabled, name-sorted
    Context: TMcpConfigContext;
  end;

{ Merge rows for a context by precedence (agent > workspace > global): a more
  specific row overrides the same name; distinct names union. Returns the
  enabled servers only, sorted by name for determinism. }
function ResolveMcpConfig(const ARows: TMcpServerRowArray;
  const AContext: TMcpConfigContext): TMcpServerArray;

{ Validate one row's fields. Used by the store on write and by tests. }
function ValidateMcpServerRow(const ARow: TMcpServerRow;
  out AError: string): Boolean;

const
  MaxMcpServers = 32;      // a bound; more is almost certainly a mistake
  MaxMcpNameChars = 64;
```

### Store additions (`hildi.store`)

The store owns the SQL. A new migration (**v3**, additive) creates the table;
the store exposes typed operations; the store stays free of MCP *semantics*
(resolution lives in `mcp.config`), mirroring how approvals split matching
(`approval.pas`) from SQL (`store.pas`).

```pascal
type
  TSqliteStore = class
    // ... existing ...
    { Rows applicable to a context: every global row, the workspace's rows, and
      the agent's rows (agent reserved). No resolution — the caller merges. }
    function LoadMcpServers(const AContext: TMcpConfigContext;
      out ARows: TMcpServerRowArray; out AError: TStoreError): Boolean;
    { Upsert by (scope, workspace_id, agent_id, name). }
    function SaveMcpServer(const ARow: TMcpServerRow;
      out AError: TStoreError): Boolean;
    function RemoveMcpServer(const ARow: TMcpServerRow;
      out AError: TStoreError): Boolean;
    { Every row, for management/UI. }
    function ListMcpServers(out ARows: TMcpServerRowArray;
      out AError: TStoreError): Boolean;
  end;
```

Migration v3 (statements, following the house style):

```sql
CREATE TABLE mcp_servers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  scope INTEGER NOT NULL,                       -- 0 global, 1 workspace, 2 agent
  workspace_id INTEGER NOT NULL DEFAULT 0,
  agent_id TEXT NOT NULL DEFAULT '',
  name TEXT NOT NULL,
  command TEXT NOT NULL,
  args TEXT NOT NULL DEFAULT '[]',              -- JSON array of strings
  env TEXT NOT NULL DEFAULT '[]',               -- JSON array of 'NAME=VALUE'
  cwd TEXT NOT NULL DEFAULT '',
  enabled INTEGER NOT NULL DEFAULT 1,
  list_timeout_ms INTEGER NOT NULL DEFAULT 0,
  call_timeout_ms INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  UNIQUE (scope, workspace_id, agent_id, name));
CREATE INDEX idx_mcp_servers_scope
  ON mcp_servers (scope, workspace_id, agent_id);
```

### Data Contracts

- **Scope semantics.** `msGlobal` ⇒ `workspace_id = 0`, `agent_id = ''`;
  `msWorkspace` ⇒ a real `workspace_id`; `msAgent` ⇒ a real `agent_id`
  (reserved — no agent rows are written in v1).
- **Resolution.** For each name, the winning row is the one from the most
  specific applicable scope (agent > workspace > global); ties within a scope
  are impossible (the `UNIQUE` key). Only `Enabled` winners are returned.
- **`args`/`env`** are stored as JSON string arrays and decoded at the store
  boundary; `env` entries are `NAME=VALUE`.
- **Ordering.** The effective list is sorted by `Name` so startup and tests are
  deterministic.

### Event Contracts

- None. Resolution is synchronous and side-effect-free.

## Architecture

### Prior Art & Reuse

- **The approvals stack is the exact template.** `approval.pas` holds the pure
  matching/decision logic; `store.pas` holds the SQL and a scoped table
  (`scope`, `workspace_id`, `session_id`, `UNIQUE(...)`); `approval.store.pas`
  adapts the store to the engine. MCP config follows the same three-way split:
  `mcp.config` (pure) ↔ `store.pas` (SQL) ↔ the client (consumer).
- **`hildi.store`** already has the migration mechanism
  (`TMigration`, `DefaultMigrations`, `StoreSchemaVersion`), the
  `UNIQUE`-table upsert idiom, and single-connection serialization. The new
  table is one migration and four methods.
- **`fpjson`** (rung 3) encodes/decodes the `args`/`env` arrays.
- **Genuine gap:** a scoped, durable server registry and its resolution. Small,
  but nothing covers it (the `settings` table is flat key/value; `.env` cannot
  express it).

### Component Boundaries

- **Responsibilities:** typed rows/config, scope precedence, validation.
- **Dependencies:** `SysUtils` only (the store depends on *this*, not the
  reverse).
- **Side effects:** none.

### Data Flow

1. Operator writes a row (see "Operator management" below) via the store.
2. At session open, `store.LoadMcpServers(context)` returns applicable rows.
3. `ResolveMcpConfig(rows, context)` yields the effective, enabled, sorted list.
4. `TMcpManager` (client) spawns one child per effective server.

## Validation Rules

### Input

- `name` non-empty, `<= MaxMcpNameChars`, matching `^[A-Za-z0-9_-]+$`, unique
  within its `(scope, workspace_id, agent_id)`.
- `command` non-empty.
- `Args`/`Env` entries are strings; an `env` entry has a non-empty `NAME` before
  `=`.
- Effective server count `<= MaxMcpServers` (checked after resolution).

### Output Guarantees

- On success every returned server is fully validated and enabled.
- On failure `AError` names the server and field; nothing is written.

## Operator management

**Resolved.** The model cannot add a server in v1. There is **no operator UI in
v1** — the operator configures servers by **writing directly to the SQLite
database** (the `mcp_servers` table). A user-facing interface (CLI subcommand or
TUI screen) is deferred to a later feature.

**Future — agent self-configuration (direction recorded).** An agent should
eventually be able to configure **its own** MCP servers, **scoped only to that
agent** (`scope = msAgent`, `agent_id = <self>`). The schema, the enum, and the
precedence already reserve this; enabling it means (a) an agent-scoped write
path and (b) a session that knows its agent id — no schema change. Guardrail: an
agent may write **only** agent-scoped rows for itself, never `workspace` or
`global`; that isolation is the whole point of the scope, and it is the trust
boundary to enforce when the write path is built.

## Error Handling

- **Write validation failure** ⇒ `seInvalidArgument` with a field-specific
  message; no row written.
- **Duplicate** ⇒ upsert (update in place), not an error.
- **Read failure** ⇒ `seError`; the caller treats it as "no MCP configured"
  and logs it, so a corrupt row cannot wedge startup.

## Testing Requirements

### Unit Tests (`tests/test_mcp_config.pas`)

- [ ] `ResolveMcpConfig` merges global + workspace, workspace overrides global
      on a name clash, and unions distinct names.
- [ ] An agent row overrides both (using a hand-built row; no agent writes yet).
- [ ] Disabled winners are excluded; the result is name-sorted.
- [ ] `ValidateMcpServerRow` accepts a valid row and rejects: empty/illegal
      name, empty command, non-string `args`, bad `env` entry, too many servers.
- [ ] Effective count over `MaxMcpServers` ⇒ error.

### Store Tests (`tests/test_store.pas` additions)

- [ ] Migration v3 applies; `StoreSchemaVersion` is 3; a v2 database upgrades
      additively (v1/v2 data intact).
- [ ] `SaveMcpServer` upserts on `(scope, workspace_id, agent_id, name)`;
      `LoadMcpServers` returns global + the matching workspace's rows;
      `RemoveMcpServer` deletes; `ListMcpServers` returns all.
- [ ] `args`/`env` round-trip through JSON intact.
- [ ] Leak-clean under `make test-leak`.

### Integration Tests

- [ ] `TMcpManager` consumes a resolved `TMcpConfig` and spawns exactly the
      enabled servers (covered in the client suite).

## Performance Targets

- Resolution is O(rows); loading is one indexed query. Negligible at startup.

## Security Considerations

- **Operator-only, durable.** Config lives in the store the operator controls;
  the model has no tool that writes `mcp_servers`, so it cannot add a server.
  This is the trust boundary the FEATURE calls out. (When agent self-config
  arrives, an agent may write only agent-scoped rows for itself — never global
  or workspace.)
- **Secrets in `env`, not argv** — a token in `args` would be visible in `ps`.
- `command`/`args` are passed directly to `TProcess` (no shell), so a config
  value is never re-parsed by a shell.

## Success Criteria

### Functional

- [ ] A row written at any scope resolves into the effective list correctly;
      every documented error is reported with a field name.
- [ ] `make check` passes.

### Quality

- [ ] Resolution is pure and fully unit-tested; store methods leak-clean.

## Future Considerations

- **File sources (JSON/JSONC/TOML):** a future loader parses a file into the
  same `TMcpServerRowArray` and reuses `ResolveMcpConfig` unchanged; a file
  source could be a lower-precedence or operator-chosen alternative to the
  store. The seam (rows) is chosen so this is additive.
- **Agent scope** is reserved in the schema and enum; enabling it is writing
  rows with `scope = msAgent` and an `agent_id`, plus teaching the session which
  agent it is — no schema change.
- **Per-server trust** (a configurable default-allow for a trusted server) is a
  future field; v1 stays `adAsk`.
