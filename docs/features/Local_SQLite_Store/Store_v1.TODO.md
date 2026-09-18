# Implementation Plan: Local SQLite Store v1

**Related Specification:** `Store_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for `hildegard.helper.store` as specified in `Store_v1.SPEC.md`.
Tasks are checkboxes; update them in real time. Each implementation task starts
with a failing test. This plan tracks Stage 3-5 of
`docs/guidelines/spec-driven-development.md`.

We work directly on `main` (project decision), so the usual feature branch step
is omitted.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [ ] **Vendor SQLite**: add `scripts/fetch-sqlite.sh` (pinned version + checksum)
      and `deps/sqlite3/README.md`; gitignore the downloaded amalgamation
- [ ] **Build target**: add Makefile `libsqlite` target producing
      `build/lib/libsqlite3.{dylib,so}`; wire `test`/`test-leak` to depend on it
- [ ] **Test unit**: create `tests/test_store.pas` with an empty `TStoreTest`
      suite; add it to the `uses` clause of `tests/hildegard_helper_tests.pas`
- [ ] **Types**: define the interface-section types from the SPEC in
      `src/hildegard.helper.store.pas` (no bodies yet)

### Phase 2: Open, Library Loading & Migrations

- [ ] **Test** `TestOpenCreatesDatabase` - red
- [ ] **Implement** `Create`/`Open`/`Close`/`IsOpen`, library resolution and
      `TSQLDBLibraryLoader` wiring, pragmas - green
- [ ] **Test** `TestOpenAppliesMigrations`, `TestOpenIsIdempotent` - red/green
- [ ] **Test** `TestOpenUnwritablePathFails`, `TestDatabaseFilePermissionsAreOwnerOnly`
- [ ] **Test** `TestLibraryPathResolutionPrefersExplicit`,
      `TestStoreWorksWithVendoredLibrary`
- [ ] **Test** `TestOperationsBeforeOpenReturnNotOpen`
- [ ] **Test** `TestFailedMigrationRollsBackAndKeepsVersion` (needs a seeded,
      failing migration - use a test-only migration list injection seam)

### Phase 3: Credentials

- [ ] **Test** `TestSaveLoadClearCredentialsRoundTrip` - red/green
- [ ] **Test** `TestLoadCredentialsMissingReturnsNotFound`
- [ ] **Test** `TestCredentialsPersistAcrossReopen`

### Phase 4: Requests & Durable Queue

- [ ] **Test** `TestEnqueueThenClaimReturnsRequest` - red/green
- [ ] **Test** `TestClaimEmptyQueueReturnsNotFound`
- [ ] **Test** `TestFinishMarksTerminalAndIsNotReclaimable`
- [ ] **Test** `TestFinishRejectsNonTerminalStatus`
- [ ] **Test** `TestDuplicateRequestIdRejected`
- [ ] **Test** `TestGetRequestById`
- [ ] **Test** `TestQueryByStatusAndPagination`
- [ ] **Test** `TestRequestHistoryPersistsAcrossReopen`

### Phase 5: Settings

- [ ] **Test** `TestSettingSetGetOverwriteDelete` - red/green
- [ ] **Test** `TestSettingMissingReturnsNotFound`

### Phase 6: Correctness, Concurrency & Security

- [ ] **Test** `TestParameterizedValuesWithQuotesRoundTrip`
- [ ] **Test** `TestClaimIsAtomicAcrossThreads`
- [ ] **Test** `TestConcurrentOperationsDoNotCorruptOrDeadlock`
- [ ] Guard all public methods with the critical section; convert
      `EDatabaseError` to `TStoreError`

### Phase 7: Example & Docs

- [ ] **Update the example**: extend `examples/` (or add a small store demo) to
      open a temp database, enqueue a request, claim it, and finish it
- [ ] **Doc comments**: `{** ... }` on the public interface (fpdoc style)
- [ ] **Update the SPEC** if the implemented behaviour diverged

### Phase 8: Validation

- [ ] **Run** `make test SUITE=TStoreTest` (green)
- [ ] **Run** `make test` (whole suite)
- [ ] **Run** `make test-leak` (no leaks; `make test-leak SUITE=TStoreTest`)
- [ ] **Run** `make check` (all gates)
- [ ] **Rename** this TODO to `Store_v1.DONE.md`; update `FEATURES.md` status

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
src/hildegard.helper.store.pas
tests/test_store.pas
scripts/fetch-sqlite.sh
deps/sqlite3/README.md
examples/store_demo.pas        (small, if not folded into demo_harness)
```

### Modified Files

```
tests/hildegard_helper_tests.pas   (add test_store to uses)
Makefile                           (libsqlite target; dependencies; maybe store_demo)
.gitignore                         (deps/sqlite3 downloaded amalgamation)
docs/features/Local_SQLite_Store/  (SPEC/TODO status)
docs/features/FEATURES.md          (status -> In Progress / Implemented)
```

## Success Criteria

- [ ] All tasks above checked
- [ ] Every acceptance criterion in `FEATURE.md` maps to a passing test or is
      explicitly deferred
- [ ] `make check` passes (tests + leak gate)
- [ ] Example demonstrates open, enqueue, claim, finish
- [ ] Implementation matches the specification

## Notes & Considerations

- **Test-only injection seam for migration failure.** To test
  `seMigrationFailed` without a broken shipped migration, the store needs a way
  for tests to supply an extra migration list (e.g. an optional constructor
  parameter or a protected hook). Record the chosen approach here.
- **Process-global library.** SQLDB has one set of sqlite3 function pointers; the
  store loads the library once and never unloads it. This is a `ponytail:`
  ceiling noted in the SPEC.
- **Timestamps** default to `Now` only when zero; tests should pass explicit
  timestamps for deterministic ordering.
- **Permissions** are Unix-only; skip the chmod assertion on non-Unix.
- Record any spec deviations here as they occur.
