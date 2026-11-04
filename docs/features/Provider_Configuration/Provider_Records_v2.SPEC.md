# Component Specification: Provider Records v2

**Related Feature:** [FEATURE.md](FEATURE.md) — Stage 2.

## Purpose

Move the provider definition out of the environment and into the store: a named,
listable, selectable record holding the endpoint, the credential reference, the
default model, and the request parameters. The environment stops being the only
way to configure hildi and becomes the **fallback** for an install that has no
provider row yet.

Stages 3–5 all read from this table; none of them can start until it exists.

## Requirements

### Functional

- [ ] A provider record holds: name, endpoint, credential reference, default
      model, the seven optional request parameters, and timestamps.
- [ ] Records are listed, created, updated and deleted by name.
- [ ] Exactly one provider is **active**; the active one is what a new session
      resolves.
- [ ] Resolution order is **store → environment → built-in default**, and the
      stage is documented and tested at each layer.
- [ ] A parameter can be *absent* in a provider row, which means "omit the key
      from the request" — the same tri-state as Stage 1, expressed as SQL `NULL`
      rather than a sentinel.
- [ ] The existing behaviour is unchanged for an install with no provider row:
      the environment path answers exactly as it does today.

### Non-Functional

- [ ] No new dependency.
- [ ] The API key is never written to a log, an error detail, or a rendered
      surface.
- [ ] Existing stores migrate forward without data loss.

## Contracts & Interfaces

### Data model

```pascal
type
  { One row of the providers table. Fields are strings/pointers into the store's
    own lifetime; the API key is NOT part of this record - see Credential. }
  TProviderRow = record
    Id: Integer;
    Name: string;              // unique, human-chosen: 'fireworks', 'local'
    Endpoint: string;
    Model: string;             // the default model for this provider
    { Every parameter is nullable in the row, which is the SQL spelling of
      Stage 1's tri-state: NULL means "not configured, omit the key". A 0.0 is a
      configured zero and must survive the round trip. }
    Temperature: Double;  HasTemperature: Boolean;
    TopP: Double;         HasTopP: Boolean;
    MaxTokens: Integer;   HasMaxTokens: Boolean;
    FrequencyPenalty: Double;  HasFrequencyPenalty: Boolean;
    PresencePenalty: Double;   HasPresencePenalty: Boolean;
    Seed: Integer;        HasSeed: Boolean;
    Stop: TStringArray;        // empty => no stop key
    CreatedAt: Int64;
    UpdatedAt: Int64;
    LastUsedAt: Int64;         // 0 => never
  end;

  { Which provider a session talks to. 0 => active provider, else an explicit
    override recorded for the session. }
  TProviderRef = record
    ProviderId: Integer;
    Name: string;
  end;
```

### Store surface

```pascal
type
  ISqliteStore = interface
    { Provider records. AName is unique; Save inserts or updates by name. }
    function SaveProvider(const ARow: TProviderRow;
      out AError: TStoreError): Boolean;
    function LoadProvider(const AName: string; out ARow: TProviderRow;
      out AError: TStoreError): Boolean;
    function ListProviders(out ARows: TProviderRowArray;
      out AError: TStoreError): Boolean;
    function DeleteProvider(const AName: string;
      out AError: TStoreError): Boolean;
    { Exactly one row is active. Setting a new active clears the old one in the
      same transaction, so the invariant cannot be observed broken. }
    function SetActiveProvider(const AName: string;
      out AError: TStoreError): Boolean;
    function ActiveProvider(out ARow: TProviderRow;
      out AError: TStoreError): Boolean;
  end;
```

### The credential

The API key is **not** a column on `providers`. It is stored through the existing
secret-bearing table (`mcp_oauth_tokens` is the only current precedent) keyed by
provider name, and loaded only at the moment a client is built.

```pascal
{ The key for a named provider, or '' when none is stored. Never logged, never
  rendered, never included in a status line. }
function ProviderSecret(AProvider: string; out ASecret: string): Boolean;
```

### Resolution

```pascal
{ Fill a TLLMConfig from the store's active provider, then the environment, then
  the built-in defaults. Returns False only on an unusable stored value (an
  unparseable parameter), which is reported rather than coerced, as in Stage 1. }
function ResolveProviderConfig(AStore: ISqliteStore;
  const AOverrides: TLLMConfig; out AConfig: TLLMConfig;
  out AError: TLLMError): Boolean;
```

## Architecture

### Prior Art & Reuse

- **`mcp_servers`** is the direct model: `scope`, `workspace_id`, `agent_id`,
  `name`, a `UNIQUE` constraint, `created_at`, and `enabled`. It already solves
  "several named configurations of one kind", and its scope pattern is what a
  provider would follow if providers ever need workspace scoping.
- **`mcp_oauth_tokens`** is the precedent for storing a secret in the database.
  **It stores `client_secret` and the tokens in plaintext columns.** Any security
  claim this SPEC makes has to match that reality or fix it.
- **`settings`** (flat key/value) is too weak: a provider has structure and a
  list, and stuffing JSON into a value row would lose the `UNIQUE` constraint and
  every query a report needs.
- **`ResolveLLMConfig` / `ResolveLLMParams`** (Stage 1) already own the
  environment layer and the validation policy. This stage prepends a store layer
  and reuses that validation for the values it reads back.
- **`requests.model`** already exists, so per-request model identity is recorded.
  Stage 5 needs the provider identity and the parameters, which this table
  supplies.

### Component Boundaries

- **`HildiStore`** owns the table, the migration, and the invariant that exactly
  one provider is active.
- **`HildiLLM`** gains `ResolveProviderConfig`, but must not learn SQL: it takes
  a store interface, or the session passes it a completed `TLLMConfig`. The
  cleaner boundary is the session doing the load and `HildiLLM` staying a pure
  request builder.
- **The session** (`HildiHarnessSession`) is where "which provider does this
  session use" belongs, because it is the thing that builds the client.

### Data Flow

1. A session opens and resolves its provider: explicit session override, else the
   active provider row, else nothing.
2. If a row is found, its non-null fields fill a `TLLMConfig`; the secret is
   loaded; the environment fills only what the row left empty.
3. `ResolveLLMParams` validates whatever combination results. A bad **stored**
   value is reported the same way a bad environment value is.
4. The client is constructed from the filled config. Nothing about the request
   path changes.

## Validation Rules

- A provider `name` is non-empty, unique, and trimmed; it is used as a key and
  appears in the UI.
- `endpoint` must be an absolute URL; an empty one falls through to the
  environment and then the built-in default.
- Stored parameters are range-checked with the **same** rules as Stage 1. A
  stored value that is out of range is reported, never clamped, and never
  silently ignored.
- Deleting the active provider is allowed and leaves no active row; resolution
  then falls through to the environment. It does not fail the session.

## Error Handling

- A store failure is a `TStoreError` at the boundary and becomes `leConfig` when
  it prevents building a client, so the operator sees one failure rather than
  two systems talking.
- A missing secret for a named provider is `leConfig` with the provider named —
  not "authentication failed", because no request was made.

## Testing Requirements

### Unit Tests

- [ ] A row round-trips every parameter, including `0.0` temperature surviving as
      configured rather than becoming NULL.
- [ ] A NULL parameter comes back absent, and the built request omits the key.
- [ ] `SaveProvider` on an existing name updates rather than duplicating.
- [ ] `ListProviders` is ordered and stable.
- [ ] Setting a new active provider leaves exactly one active row, even when the
      update fails partway.
- [ ] An out-of-range stored parameter is reported, not clamped.
- [ ] An install with no provider row behaves exactly as before (the
      backward-compatibility test).
- [ ] The secret never appears in an error message.

### Integration Tests

- [ ] A session resolves the active provider and its request body carries that
      provider's model and parameters.

## Migrations

**Migration 23.** Main is at 21; the MCP lane holds 22. Re-check `main`
immediately before landing, because two branches claiming the same integer is
silent — no error, no red test, just a skipped migration.

```sql
CREATE TABLE providers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  endpoint TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT '',
  temperature REAL,
  top_p REAL,
  max_tokens INTEGER,
  frequency_penalty REAL,
  presence_penalty REAL,
  seed INTEGER,
  stop TEXT NOT NULL DEFAULT '[]',
  active INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX idx_providers_one_active ON providers (active) WHERE active = 1;
```

Every parameter column is **nullable on purpose**. `NULL` is the SQL spelling of
Stage 1's tri-state; `0.0` is a configured zero and must round-trip. The partial
unique index is what makes "exactly one active" a database invariant rather than
a convention the code has to remember.

## Security Considerations

- **The store is the security boundary today, and that is a gap.** `mcp_oauth_tokens`
  already stores a client secret and refresh token in plaintext, and the store
  file is not created with restrictive permissions by the code. Adding provider
  keys makes the database more valuable to an attacker, which raises the stakes
  on a weakness that already exists. This SPEC does **not** fix it; it names it so
  the decision is deliberate rather than accidental. **Recommended follow-up:**
  create the database with `0600` and document it, or encrypt secret columns.
- The API key must never be a CLI flag (existing rule), never rendered, never
  logged, and never included in the turn summary that Stage 5 records.
- A stored endpoint is attacker-influenceable if a store is shared. The existing
  rule that a URL change is a visible action applies.

## Success Criteria

- [ ] Migration 23 applies cleanly to an existing store and to a fresh one.
- [ ] A store with no provider row is byte-for-byte behaviour-identical.
- [ ] All parameters round-trip with NULL distinct from zero.
- [ ] `make check` green.
- [ ] The security gap is recorded rather than silently inherited.

## Future Considerations

- **Workspace scoping.** `mcp_servers` carries `scope`/`workspace_id`; providers
  do not, because a provider is an account-level fact rather than a project one.
  If that changes, mirror the MCP columns exactly.
- **Stage 4 (model discovery)** wants a per-provider model cache; a
  `provider_models` table keyed by provider name and a fetch timestamp is the
  natural shape, and is out of scope here.
- **Encryption at rest** would change every secret-bearing table at once. Do it
  once, as its own feature, rather than per table.
