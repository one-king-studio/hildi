# Component Specification: Local SQLite Store

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildegard.helper.store` is the helper's embedded persistence layer. It owns one
SQLite database file and exposes typed operations for four kinds of application
data: device credentials, request/audit history, a durable pending-request queue,
and key/value settings. It hides the SQL, the schema, migrations, and thread
serialization behind a single class so no other unit touches the database
directly.

The feature's [FEATURE.md](FEATURE.md) is the requirements source. This document
fixes the technical design: the vendored library build, the schema and migration
mechanism, the public contracts, and the test surface.

## Requirements

### Functional

- [ ] Open or create a database at a configured path, applying migrations.
- [ ] Persist, load, and clear a single device-credentials record.
- [ ] Record requests with a status lifecycle; query history by id and status.
- [ ] Provide a durable queue: enqueue, atomically claim the next pending item,
      and mark it complete/failed/cancelled.
- [ ] Persist, read, and delete string settings.
- [ ] Enable WAL journaling, foreign-key enforcement, and a busy timeout.
- [ ] Report all failures through a typed error contract; never leak or crash.

### Non-Functional

- Performance: open + migrate in under ~50 ms; single-row read/write under ~5 ms
  on a local SSD; no busy-waiting.
- Reliability: leak-clean under `make test-leak`; every write transactional;
  failed migrations rolled back with the schema version unchanged.
- Portability: macOS and Linux, FPC 3.3.1, `{$mode delphi}`; `cthreads` first on
  Unix; no `TSemaphore`.

## Contracts & Interfaces

> Contracts are expressed as Pascal type declarations. This section defines
> *what* crosses the boundary; the implementer decides the bodies.

### Public API

```pascal
unit hildegard.helper.store;

type
  { Stable error codes. seOk is the success value. }
  TStoreErrorCode = (
    seOk,                 // success
    seCannotOpen,         // path not writable, library not loadable, or corrupt file
    seNotOpen,            // an operation ran before a successful Open
    seMigrationFailed,    // a migration failed; schema version unchanged
    seNotFound,           // requested row does not exist (credentials/setting/request)
    seConstraint,         // uniqueness or foreign-key violation
    seInvalidArgument,    // caller passed an empty required value
    seError               // unclassified SQL/serialization failure
  );

  TStoreError = record
    Code: TStoreErrorCode;
    Message: string;      // human readable
    Detail: string;       // diagnostic detail (SQL, path, library); never secrets
  end;

  { Open-time configuration. }
  TStoreConfig = record
    DatabasePath: string;     // required; the file is created if absent
    LibraryPath: string;      // vendored libsqlite3; '' resolves a default
    BusyTimeoutMs: Integer;   // 0 => default (5000)
  end;

  { Device credentials for the account this helper is registered to. }
  TDeviceCredentials = record
    DeviceId: string;
    Token: string;            // secret; never logged
    Endpoint: string;
    AccountId: string;
  end;

  { Request lifecycle. A request is both a queue item and a history row. }
  TRequestStatus = (rsPending, rsClaimed, rsCompleted, rsFailed, rsCancelled);

  TStoredRequest = record
    Id: string;               // caller-supplied unique id
    Kind: string;             // e.g. 'shell', 'script'
    Payload: string;          // opaque request body (expected JSON)
    Status: TRequestStatus;
    ExitCode: Integer;        // meaningful once terminal
    Result: string;           // optional result body
    CreatedAtMs: Int64;       // Unix epoch milliseconds
    UpdatedAtMs: Int64;       // Unix epoch milliseconds
  end;

  TStoredRequestArray = array of TStoredRequest;

  { Filter for history queries. UseStatus = False returns all statuses. }
  TRequestQuery = record
    UseStatus: Boolean;
    Status: TRequestStatus;
    Limit: Integer;           // <= 0 => no limit
    Offset: Integer;
  end;

  { The store's external surface. One instance owns one database file. }
  TSqliteStore = class
  public
    constructor Create(const AConfig: TStoreConfig); overload;
    { Test seam: run with an explicit migration list (e.g. to inject a failing
      migration and assert rollback). Production callers use the overload above,
      which uses DefaultMigrations. }
    constructor Create(const AConfig: TStoreConfig;
      const AMigrations: TMigrationArray); overload;
    destructor Destroy; override;

    { Opens/creates the database and applies migrations. Idempotent. }
    function Open(out AError: TStoreError): Boolean;
    procedure Close;
    function IsOpen: Boolean;

    { Credentials: a single row. }
    function SaveCredentials(const AValue: TDeviceCredentials;
      out AError: TStoreError): Boolean;
    function LoadCredentials(out AValue: TDeviceCredentials;
      out AError: TStoreError): Boolean;   // False + seNotFound when absent
    function ClearCredentials(out AError: TStoreError): Boolean;

    { Requests / durable queue. }
    function EnqueueRequest(const AValue: TStoredRequest;
      out AError: TStoreError): Boolean;
    function ClaimNextPending(out AValue: TStoredRequest;
      out AError: TStoreError): Boolean;   // atomic; False + seNotFound when empty
    function FinishRequest(const AId: string; AStatus: TRequestStatus;
      AExitCode: Integer; const AResult: string;
      out AError: TStoreError): Boolean;   // terminal statuses only
    function GetRequest(const AId: string; out AValue: TStoredRequest;
      out AError: TStoreError): Boolean;
    function QueryRequests(const AQuery: TRequestQuery;
      out AList: TStoredRequestArray; out AError: TStoreError): Boolean;

    { Settings: string key/value. }
    function SetSetting(const AKey, AValue: string;
      out AError: TStoreError): Boolean;
    function GetSetting(const AKey: string; out AValue: string;
      out AError: TStoreError): Boolean;   // False + seNotFound when absent
    function DeleteSetting(const AKey: string;
      out AError: TStoreError): Boolean;
  end;

  { Resolves the SQLite library path: returns AExplicit when non-empty,
    otherwise probes environment and locations relative to the executable,
    returning '' to let SQLDB use its platform default. }
function ResolveLibraryPath(const AExplicit: string): string;

{ Current schema version this build expects (the highest migration). }
function StoreSchemaVersion: Integer;
```

### Data Contracts

Schema (created by migration 1; each migration is a numbered set of DDL/DML
statements applied in ascending order inside one transaction):

```sql
-- credentials: a single row, enforced
CREATE TABLE credentials (
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  device_id  TEXT NOT NULL,
  token      TEXT NOT NULL,
  endpoint   TEXT NOT NULL,
  account_id TEXT NOT NULL
);

-- requests: durable queue + audit history in one table
CREATE TABLE requests (
  id           TEXT PRIMARY KEY,
  kind         TEXT NOT NULL,
  payload      TEXT NOT NULL,
  status       INTEGER NOT NULL,      -- ordinal of TRequestStatus
  exit_code    INTEGER NOT NULL DEFAULT 0,
  result       TEXT NOT NULL DEFAULT '',
  created_at   INTEGER NOT NULL,      -- Unix epoch milliseconds
  updated_at   INTEGER NOT NULL
);
CREATE INDEX idx_requests_status  ON requests (status, created_at);
CREATE INDEX idx_requests_created ON requests (created_at);

-- settings: string key/value
CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

Rules the schema relies on:

- `credentials.id` is fixed to `1`, so `SaveCredentials` is an upsert and
  `LoadCredentials` has at most one row.
- A request's `status` transitions are: `rsPending` -> `rsClaimed` ->
  (`rsCompleted` | `rsFailed` | `rsCancelled`). `FinishRequest` accepts only
  terminal target statuses and never revives a terminal row.
- Timestamps are Unix epoch milliseconds (`Int64`), supplied by the caller or set
  to the current time when zero.

### Event Contracts

None. This component is synchronous and emits no callbacks.

### Migration Contract

Migrations are data, not code paths: an ordered list of `(Version, Name,
Statements)`. The store applies only those above the database's current
`PRAGMA user_version`, each in its own transaction, then sets `user_version` to
that migration's version. A fresh database is at version `0`.

```pascal
type
  TMigration = record
    Version: Integer;               // 1-based, unique, ascending
    Name: string;                   // for diagnostics
    Statements: array of string;    // executed in order, one transaction
  end;
```

## Architecture

### Prior Art & Reuse

Apply the Ponytail ladder (`docs/guidelines/ponytail.md`) before writing code:

- **Rung 2/3 (codebase/RTL):** FPC ships the entire SQLite client. `sqlite3conn`
  provides `TSQLite3Connection`; `sqldb` provides `TSQLTransaction`/`TSQLQuery`;
  `sqldblib` provides `TSQLDBLibraryLoader` to point at a specific library;
  `fpjson` is available if callers need to build payloads. All are already on the
  default unit path (verified against FPC 3.3.1, aarch64-darwin). **Do not write
  a custom C binding or a file-format layer.**
- **Rung 4 (platform):** SQLite itself is the native facility; the project only
  vendors a pinned copy (see Vendored Library).
- **Rung 5 (deps):** no third-party unit is needed.

The genuine gap is small: a thin typed wrapper, the schema, the migration runner,
and the single-connection lock. Everything else is reuse.

### Vendored Library

SQLDB loads `libsqlite3` dynamically. To avoid depending on the host's version,
the project vendors a pinned SQLite amalgamation and builds a shared library:

- `scripts/fetch-sqlite.sh` downloads the pinned amalgamation release, verifies a
  published checksum, and extracts `sqlite3.c` / `sqlite3.h` into `deps/sqlite3/`.
  The downloaded sources are gitignored; a `deps/sqlite3/README.md` records the
  pinned version and checksum. (Alternative considered: commit the ~9 MB
  amalgamation; rejected to keep the repository light.)
- A Makefile target `libsqlite` compiles the amalgamation into
  `build/lib/libsqlite3.dylib` (macOS, `-dynamiclib`) or
  `build/lib/libsqlite3.so` (Linux, `-shared -fPIC`), with `-DSQLITE_THREADSAFE=1`.
- `Open` resolves the library via `ResolveLibraryPath`, then configures a
  `TSQLDBLibraryLoader` (`ConnectionType='SQLite3'`, `LibraryName=<resolved>`)
  before connecting. A missing/unloadable library yields `seCannotOpen` with the
  attempted path in `Detail`.

The library is process-global (SQLDB loads one set of function pointers). The
store loads it once and does **not** unload it on `Close`; v1 assumes a single
store per process. This is recorded as a `ponytail:` ceiling.

### Component Boundaries

- **Responsibilities:** schema ownership, migrations, SQL execution, parameter
  binding, transaction management, single-connection serialization, error
  mapping, file permissions.
- **Dependencies:** `sqlite3conn`, `sqldb`, `sqldblib` (FPC); `Classes`,
  `SysUtils`; `BaseUnix` on Unix for `fpChmod`.
- **Side effects:** creates/mutates one database file (and its `-wal`/`-shm`
  companions), creates `build/lib/libsqlite3.*` at build time.

### Data Flow

1. **Construction:** `Create` validates configuration shape only; no I/O.
2. **Open:** resolve the library, load it, open the connection, apply pragmas,
   read `user_version`, apply migrations in ascending order (each in a
   transaction), then restrict file permissions to owner-only on Unix. `Open` is
   idempotent while open. Pragma application has FCL-specific mechanics:
   `journal_mode=WAL` is set on the raw file before SQLDB connects (it cannot be
   changed inside SQLDB's transaction and persists in the database header),
   `foreign_keys=ON` is passed at connect time through
   `TSQLite3Connection.Params`, and `busy_timeout` is applied with
   `ExecuteDirect` (allowed inside a transaction).
3. **Operation:** acquire the lock, ensure open, bind parameters, execute inside a
   transaction where the operation is multi-statement (claim, finish), release the
   lock, map any `EDatabaseError` to a `TStoreError`.
4. **Close:** release the lock, close the connection, mark closed. The loaded
   library stays loaded.
5. **Error handling:** every public method returns `Boolean` and fills
   `out AError`; non-success codes carry a human-readable `Message` and a
   diagnostic `Detail`. No exception escapes the public surface.

### Integration Patterns

- **Synchronous, single-threaded access model.** `TSQLite3Connection` is not
  thread-safe, so one connection is serialized by one `TCriticalSection`. Every
  public method takes the lock; `Open`/`Close` do too.
- **Ownership:** the store owns the connection, transaction, queries, and lock,
  and frees them in `Destroy`. Callers own returned arrays/records (value types).
- **No background threads.** The store starts none and assumes none of its callers
  run reentrantly on the same instance.

## Validation Rules

### Input

- `DatabasePath` must be non-empty; otherwise `Create`/`Open` yields
  `seInvalidArgument`.
- `TStoredRequest.Id` must be non-empty and unique; a duplicate yields
  `seConstraint`.
- `Kind` must be non-empty.
- Setting `AKey` must be non-empty.
- `FinishRequest` accepts only `rsCompleted`, `rsFailed`, or `rsCancelled`; any
  other target yields `seInvalidArgument`.
- Timestamps of `0` are replaced with the current time; negative values are
  rejected as `seInvalidArgument`.

### Output Guarantees

- `QueryRequests` returns rows ordered by `created_at` ascending, then `id`, and
  applies `Offset`/`Limit` when positive.
- `LoadCredentials` returns `True` only with a fully populated record, or `False`
  with `seNotFound`.
- Returned records are self-contained value copies; no live dataset is exposed.
- `Detail` never contains the credential token.

## Error Handling

### Error Types

- **Validation errors:** empty required values, invalid status transition ->
  `seInvalidArgument`.
- **Business errors:** duplicate id -> `seConstraint`; absent row -> `seNotFound`.
- **System errors:** unwritable path, unloadable library, corrupt file ->
  `seCannotOpen`; SQL failures -> `seError`.
- **Migration errors:** any migration statement failure -> `seMigrationFailed`,
  with the schema version unchanged (transaction rolled back).

### Error Contracts

`TStoreError` above. Harness-wide exit-code conventions (`0`, `124`, `130`,
`128+signal`) live in `hildegard.helper.process`; the store's `ExitCode` field on
requests carries those values through unchanged but does not interpret them.

## Testing Requirements

Each item becomes a named fpcunit `TTestCase`. All tests run against a temporary
database path created in `SetUp` and removed in `TearDown`; no network.

### Unit Tests (`test_store.pas`)

- [ ] `TestOpenCreatesDatabase`
- [ ] `TestOpenAppliesMigrations` (fresh db reaches `StoreSchemaVersion`)
- [ ] `TestOpenIsIdempotent`
- [ ] `TestOpenUnwritablePathFails` (`seCannotOpen`, no crash)
- [ ] `TestDatabaseFilePermissionsAreOwnerOnly` (Unix)
- [ ] `TestSaveLoadClearCredentialsRoundTrip`
- [ ] `TestLoadCredentialsMissingReturnsNotFound`
- [ ] `TestCredentialsPersistAcrossReopen`
- [ ] `TestEnqueueThenClaimReturnsRequest`
- [ ] `TestClaimEmptyQueueReturnsNotFound`
- [ ] `TestClaimIsAtomicAcrossThreads` (N threads, no duplicate ids)
- [ ] `TestFinishMarksTerminalAndIsNotReclaimable`
- [ ] `TestFinishRejectsNonTerminalStatus`
- [ ] `TestDuplicateRequestIdRejected`
- [ ] `TestGetRequestById`
- [ ] `TestQueryByStatusAndPagination`
- [ ] `TestRequestHistoryPersistsAcrossReopen`
- [ ] `TestSettingSetGetOverwriteDelete`
- [ ] `TestSettingMissingReturnsNotFound`
- [ ] `TestParameterizedValuesWithQuotesRoundTrip`
- [ ] `TestOperationsBeforeOpenReturnNotOpen`
- [ ] `TestFailedMigrationRollsBackAndKeepsVersion`
- [ ] `TestConcurrentOperationsDoNotCorruptOrDeadlock`
- [ ] `TestNoLeaks` (implicitly enforced by `make test-leak`)

### Integration Tests

- [ ] `TestLibraryPathResolutionPrefersExplicit`
- [ ] `TestStoreWorksWithVendoredLibrary` (uses the built `build/lib` library)

## Performance Targets

- `Open` + migration on a fresh database: < 50 ms on a local SSD.
- Single-row write and read: < 5 ms.
- Claim under contention: bounded by lock hold time; no busy-spin.
- Memory: bounded by result set size; no unbounded caches.

## Security Considerations

- **Injection:** all caller values are bound as query parameters; no value is
  concatenated into SQL.
- **Secrets at rest:** the database file is chmod'd to `0600` on Unix; the token
  is never written to logs, errors, or `Detail`.
- **File location:** WAL requires local, shared-memory-capable storage; network
  filesystems are unsupported (documented, and the resolved journal mode is
  logged).
- **No encryption in v1:** data is plaintext on disk, protected only by file
  permissions. Encryption is explicitly out of scope (see FEATURE.md).

## Success Criteria

### Functional

- [ ] All contracts implemented and all validation rules enforced.
- [ ] All error scenarios return the documented codes.
- [ ] `make check` passes (functional tests plus the leak gate).

### Quality

- [ ] Contract compliance verified by the tests above.
- [ ] Performance targets met.
- [ ] No memory leaks.
- [ ] `FEATURE.md` acceptance criteria mapped to tests or explicitly deferred.

## Future Considerations

- A second `(Version, Statements)` migration for new tables, exercised by the
  upgrade-path test.
- Encryption at rest and OS-keychain key storage (would change `TStoreConfig`).
- Retention/pruning for `requests`.
- Possibly splitting migrations into their own unit once the list grows.
- A conversation-store adapter that implements the Agent Loop's store interface
  on top of this component.
