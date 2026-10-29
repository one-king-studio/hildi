# Implementation Plan: Local SQLite Store v1

**Related Specification:** `Store_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `hildi.store` as specified in `Store_v1.SPEC.md`.
Tasks are checkboxes; update them in real time. Each implementation task starts
with a failing test. This plan tracks Stage 3-5 of
`docs/guidelines/spec-driven-development.md`.

We work directly on `main` (project decision), so the usual feature branch step
is omitted.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [x] **Vendor SQLite**: add `scripts/fetch-sqlite.sh` (pinned version + checksum)
      and `deps/sqlite3/README.md`; gitignore the downloaded amalgamation
- [x] **Build target**: add Makefile `libsqlite` target producing
      `build/lib/libsqlite3.{dylib,so}`; wire `test`/`test-leak` to depend on it
- [x] **Test unit**: create `tests/test_store.pas` with an empty `TStoreTest`
      suite; add it to the `uses` clause of `tests/hildi_tests.pas`
- [x] **Types**: define the interface-section types from the SPEC in
      `src/hildi.store.pas` (no bodies yet)

### Phase 2: Open, Library Loading & Migrations

- [x] **Test** `TestOpenCreatesDatabase` - red
- [x] **Implement** `Create`/`Open`/`Close`/`IsOpen`, library resolution and
      `TSQLDBLibraryLoader` wiring, pragmas - green
- [x] **Test** `TestOpenAppliesMigrations`, `TestOpenIsIdempotent` - red/green
- [x] **Test** `TestOpenUnwritablePathFails`, `TestDatabaseFilePermissionsAreOwnerOnly`
- [x] **Test** `TestLibraryPathResolutionPrefersExplicit`,
      `TestStoreWorksWithVendoredLibrary`
- [x] **Test** `TestOperationsBeforeOpenReturnNotOpen`
- [x] **Test** `TestFailedMigrationRollsBackAndKeepsVersion` (needs a seeded,
      failing migration - use a test-only migration list injection seam)

### Phase 3: Credentials

- [x] **Test** `TestSaveLoadClearCredentialsRoundTrip` - red/green
- [x] **Test** `TestLoadCredentialsMissingReturnsNotFound`
- [x] **Test** `TestCredentialsPersistAcrossReopen`

### Phase 4: Requests & Durable Queue

- [x] **Test** `TestEnqueueThenClaimReturnsRequest` - red/green
- [x] **Test** `TestClaimEmptyQueueReturnsNotFound`
- [x] **Test** `TestFinishMarksTerminalAndIsNotReclaimable`
- [x] **Test** `TestFinishRejectsNonTerminalStatus`
- [x] **Test** `TestDuplicateRequestIdRejected`
- [x] **Test** `TestGetRequestById`
- [x] **Test** `TestQueryByStatusAndPagination`
- [x] **Test** `TestRequestHistoryPersistsAcrossReopen`

### Phase 5: Settings

- [x] **Test** `TestSettingSetGetOverwriteDelete` - red/green
- [x] **Test** `TestSettingMissingReturnsNotFound`

### Phase 6: Correctness, Concurrency & Security

- [x] **Test** `TestParameterizedValuesWithQuotesRoundTrip`
- [x] **Test** `TestClaimIsAtomicAcrossThreads`
- [x] **Test** `TestConcurrentOperationsDoNotCorruptOrDeadlock`
- [x] Guard all public methods with the critical section; convert
      `EDatabaseError` to `TStoreError`

### Phase 7: Example & Docs

- [x] **Update the example**: extend `examples/` (or add a small store demo) to
      open a temp database, enqueue a request, claim it, and finish it
- [x] **Doc comments**: `{** ... }` on the public interface (fpdoc style)
- [x] **Update the SPEC** if the implemented behaviour diverged

### Phase 8: Validation

- [x] **Run** `make test SUITE=TStoreTest` (green)
- [x] **Run** `make test` (whole suite)
- [x] **Run** `make test-leak` (no leaks; `make test-leak SUITE=TStoreTest`)
- [x] **Run** `make check` (all gates)
- [x] **Rename** this TODO to `Store_v1.DONE.md`; update `FEATURES.md` status

## Dependencies & Ordering

### Must Complete Before Starting

- Vendored library + `libsqlite` target before any open/migration test can run
- Interface types before tests that reference them

### Can Be Done in Parallel

- Credentials (Phase 3) and settings (Phase 5) are independent once open works
- Requests (Phase 4) is the largest, self-contained slice

### Critical Path

1. Vendored library and build target
2. Open + pragmas + migrations
3. Credentials
4. Requests/queue
5. Settings
6. Concurrency and parameterization
7. Example, docs, `make check`

## Files to Create/Modify

### New Files

```
src/hildi.store.pas
tests/test_store.pas
scripts/fetch-sqlite.sh
deps/sqlite3/README.md
examples/store_demo.pas        (small, if not folded into demo_harness)
```

### Modified Files

```
tests/hildi_tests.pas   (add test_store to uses)
Makefile                           (libsqlite target; dependencies; maybe store_demo)
.gitignore                         (deps/sqlite3 downloaded amalgamation)
docs/features/Local_SQLite_Store/  (SPEC/TODO status)
docs/features/FEATURES.md          (status -> In Progress / Implemented)
```

## Success Criteria

- [x] All tasks above checked
- [x] Every acceptance criterion in `FEATURE.md` maps to a passing test or is
      explicitly deferred
- [x] `make check` passes (tests + leak gate)
- [x] Example demonstrates open, enqueue, claim, finish
- [x] Implementation matches the specification

## Notes & Considerations

### Resolution of the open questions

- **Test-only injection seam for migration failure.** Chosen approach: a second
  constructor overload taking an explicit `TMigrationArray`. Tests inject a
  deliberately failing migration and assert `seMigrationFailed` plus a `PRAGMA
  user_version` read directly (through a separate connection) proving the version
  was unchanged. The overload is now documented in `Store_v1.SPEC.md`.
- **WAL and foreign keys cannot be set through SQLDB.** SQLDB wraps statements in
  a transaction, so `PRAGMA journal_mode=WAL` and `PRAGMA foreign_keys` fail
  there. WAL is applied to the raw database file before SQLDB connects (it
  persists in the header); `foreign_keys=ON` is passed at connect time via
  `TSQLite3Connection.Params`; `busy_timeout` is applied via `ExecuteDirect`.
  See `docs/guidelines/testing.md`.
- **Process-global library.** SQLDB has one set of sqlite3 function pointers; the
  store loads the library once and never unloads it. This is a `ponytail:`
  ceiling noted in the SPEC. `InitLibrary` takes the resolved path so the
  vendored library is actually used (not SQLDB's platform default).
- **Timestamps** default to `Now` only when zero; tests pass explicit timestamps
  for deterministic ordering.
- **Permissions** are Unix-only; the chmod assertion is compiled out elsewhere.

### Deviations from the specification

- The store gained a public `DefaultMigrations` function and a `TMigrationArray`
  type, and a second constructor overload for the migration test seam. The SPEC
  was updated to match.
- A `make store-demo` target and `examples/store_demo.pas` were added (the plan
  left this as "small, if not folded into demo_harness").

### Discovered work

- `docs/guidelines/testing.md` was created to capture the `FillChar`-on-managed-
  records leak, managed-local/result initialization, and the SQLDB transaction
  findings. Referenced from `AGENTS.md` and `spec-driven-development.md`.
