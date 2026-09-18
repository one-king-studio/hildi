# Local SQLite Store

## Overview

hildegard-helper needs somewhere durable to keep its own state. This feature adds
an embedded SQLite database as the single local store for application data:
device credentials, a request/audit history, a durable pending-request queue, and
settings. It is exposed as a focused `hildegard.helper.*` access layer - typed
operations over parameterized SQL - so other units never embed SQL strings or
depend on the schema directly.

SQLite is embedded: no server, no network, one file on disk. The SQLite library
is vendored under `deps/` and built by the project, so the helper carries a known
SQLite version rather than depending on whatever the host happens to provide.

## Problem Statement

The execution core is effectively stateless. Everything the helper must remember
across a restart - which account a device belongs to, what requests it has run,
what work is still waiting - currently has nowhere to live. Without a store, the
upcoming Remote Agent Link feature would have to invent ad-hoc file formats for
credentials, logs, and a queue, and each would lose data on crash or restart.

Applying the first rung of the Ponytail ladder (`docs/guidelines/ponytail.md`):
if the only need were a device token, a single file with restrictive permissions
would do, and a database would be over-engineering. What justifies SQLite is the
*combination* of durable queued work, queryable history, and transactional
updates under a multi-threaded helper. Those needs are real and recurring, and
SQLite is the smallest thing that satisfies all three without a server.

This feature therefore defines the store and the access layer. It deliberately
does **not** define tables for features that have not been specified yet.

## Goals

- Provide one embedded, transactional local store for helper state at a
  configurable path.
- Store device credentials, request/audit history, a durable request queue, and
  key/value settings.
- Expose a typed access layer over parameterized queries; no SQL in callers.
- Apply versioned schema migrations at startup, safely and idempotently.
- Allow concurrent access from worker and network threads without corruption or
  deadlock.
- Fail clearly and safely on an unopenable, corrupt, or missing library/database.
- Keep secrets out of logs and store the database with restrictive permissions.
- Remain testable in-process against a temporary database, with no server and no
  network.

## User Stories

- As an **operator**, I want the helper to remember its device credentials across
  restarts, so I only pair a device once.
- As an **operator**, I want a durable record of what requests the device has run
  and how they turned out, so I can audit its activity after the fact.
- As the **Hildegard agent**, I want requests that arrive when no worker is free
  (or while the helper is restarting) to be queued durably, so work is not
  silently dropped.
- As a **harness author**, I want a typed access layer rather than raw SQL in
  every unit, so changes to the schema do not ripple through the codebase.
- As an **operator**, I want the store to upgrade itself after a helper update
  without losing data, so upgrades are uneventful.
- As an **operator**, I want concurrent access from multiple threads to be safe,
  so a busy device does not corrupt its own database.
- As an **operator**, I want secrets stored with owner-only permissions and never
  written to logs, so local data is not casually exposed.

## Acceptance Criteria

### Functional Requirements

Store lifecycle

- [ ] Opening a configured path creates the database file if absent and leaves an
      existing file intact.
- [ ] The store enables WAL journaling, foreign-key enforcement, and a busy
      timeout on open.
- [ ] Opening a path that cannot be written returns a distinct, reported error
      and does not crash the process.
- [ ] The database file is created with owner-only permissions (0600).

Credentials

- [ ] Device credentials (device id, token, endpoint, account id) can be saved,
      loaded, and cleared, and the values survive closing and reopening the
      store.
- [ ] Loading credentials when none are stored returns a distinct "not found"
      result rather than an error or a default token.

Request history

- [ ] A request can be recorded with its id, kind, status, exit code, and
      timestamps.
- [ ] Recorded requests can be queried by id and by status, and the records
      survive closing and reopening the store.
- [ ] Updating a request's status (for example, from pending to completed)
      persists across reopen.

Durable queue

- [ ] A pending request can be enqueued and the enqueue survives a simulated
      restart (close and reopen) of the store.
- [ ] Claiming the next pending request is atomic: two threads claiming
      concurrently never receive the same item.
- [ ] A claimed request can be marked completed or failed, and once terminal it is
      not returned by a subsequent claim.

Settings

- [ ] A setting can be set, read back, overwritten, and deleted; values survive
      reopen.

Migrations

- [ ] A fresh database is brought to the latest schema version on first open.
- [ ] A database at an older version is upgraded to the latest version when
      opened.
- [ ] Applying migrations to an already-current database is a no-op.
- [ ] A migration that fails partway is rolled back, leaving the schema version
      and data unchanged, and the error is reported.

Access layer

- [ ] All values from callers are passed as query parameters; a value containing
      quotes or SQL metacharacters is stored and retrieved verbatim.
- [ ] No caller outside the store unit needs to construct SQL.

Concurrency

- [ ] Concurrent operations from multiple threads complete without corruption,
      deadlock, or lost updates.
- [ ] An operation that fails mid-transaction leaves no partial writes.

### Non-Functional Requirements

- [ ] Reliability: leak-clean under the heaptrc gate; transactions roll back on
      error; no unbounded growth in connections or statements.
- [ ] Portability: builds and runs on macOS and Linux with Free Pascal 3.3.1;
      `cthreads` first on Unix; the vendored library is resolved on both
      platforms.
- [ ] Performance: migration checks and simple reads/writes are fast enough to
      run at startup and per request without noticeable cost; no busy-waiting.
- [ ] Security: secrets are never logged; parameterized queries only; database
      file permissions are restrictive.
- [ ] Testability: the full store is exercised in-process against a temporary
      database path, with no external server or network.

## Success Metrics

### Quantitative

- We can add a new column and a migration with a single numbered migration and
  no data loss (demonstrated by a test that seeds a vN database and opens it at
  vN+1).
- The full store test suite runs in well under the existing suite's runtime, in
  a temp directory, with no network access.
- No leaks reported by `make test-leak`.

### Qualitative

- Callers read as typed operations (`SaveCredentials`, `ClaimNextRequest`), not
  SQL.
- Failure modes (cannot open, corrupt, migration failed) are unambiguous and
  actionable in logs.
- Adding a table for a future feature is a local, reviewable change: one
  migration plus typed methods.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- Must use FPC's SQLDB (`TSQLite3Connection`, `TSQLQuery`, `TSQLTransaction`);
  do not write a custom C binding.
- The SQLite library is vendored under `deps/` and built by the project; the
  pinned version and build steps live in the build system, not in caller code.
- The store must be usable without a network and without a database server.
- Database contents are not encrypted in v1; secrets at rest rely on file
  permissions only, and this limitation must be documented.

### Business / Time

- This feature should land before or alongside Remote Agent Link, which depends
  on it for credentials, history, and the queue.

## Dependencies

### Internal

- A new `hildegard.helper.*` store unit (plus a small migration list) - exact
  boundaries decided in the SPEC.
- Consumers: Remote Agent Link (credentials, history, queue) and future features
  that need settings.

### External

- SQLite amalgamation source vendored under `deps/`, compiled to a shared library
  by the Makefile.
- FPC's SQLDB / fcl-db (`sqlite3conn`) which loads the SQLite library at runtime.

## Risks

- **Vendoring SQLite adds build and packaging complexity** - cross-platform
  shared-library naming, flags, and binary artifacts. Mitigation: pin one SQLite
  version, add a dedicated Makefile target, and verify on macOS and Linux.
- **Runtime library resolution** - SQLDB must load the vendored library, not a
  system one, and not fail silently if it is absent. Mitigation: explicit library
  path configuration and a clear startup error, covered by a test.
- **SQLDB objects are not thread-safe** - sharing one connection across threads
  can corrupt state. Mitigation: a single connection serialized by a lock (and
  WAL), as chosen for v1; revisit only if contention is measured.
- **WAL needs local, shared-memory-capable storage** - the `-wal`/`-shm` files
  do not work on some network filesystems. Mitigation: document the local-
  filesystem requirement and detect/log the journal mode in use.
- **Migration bugs can lose data** - Mitigation: run migrations in a transaction,
  snapshot before upgrading, and test the upgrade path with seeded data.
- **Unencrypted secrets at rest** - Mitigation: 0600 permissions and never
  logging secrets now; encryption/keychain noted as future work.
- **Over-engineering** - pulling in a database before features need it.
  Mitigation: only implement tables justified by specified features; question
  each addition against the Ponytail ladder.

## Out of Scope

- Encryption of the database file (SQLCipher or column-level), and key
  management.
- Any client/server database, replication, or multi-process access.
- An ORM or schema-to-code generation.
- Full-text search.
- Storing file contents or large binary blobs (that is a file/VFS concern).
- Tables for features that have not yet been specified.
- Prebuilt binary distribution or CI packaging of the vendored library.

## Future Considerations

- Encryption at rest, with the key held in the OS keychain/secret service.
- Log/queue retention and pruning policy.
- Optional query/reporting tooling over the audit history.
- A migration to a different store only if the helper ever needs multi-process or
  server-backed persistence.

## Notes

- **ICE score: Impact 8, Confidence 8, Ease 5.** Impact is high because Remote
  Agent Link depends on durable state. Confidence is high: SQLite is
  ubiquitous and FPC's SQLDB is standard. Ease is moderate: vendoring the
  library, migrations, and thread-safe access all add real work.
- Sequencing: this is a building block for Remote Agent Link. It can be
  implemented first and tested entirely on its own.
- Reuse note (Ponytail): SQLite and SQLDB exist and are already reachable through
  FPC; the only new code is the access layer and migrations. A custom file format
  or a hand-rolled C binding would be climbing past the available rung.
