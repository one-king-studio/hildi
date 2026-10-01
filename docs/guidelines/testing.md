# Testing Guidelines

These guidelines cover how tests are written and run in hildegard-helper. The
workflow itself (red, green, refactor) lives in
`spec-driven-development.md`; this document is the practical companion: gates,
conventions, and hard-won FPC/FCL findings that cost us real debugging time.

## The loop

Every behaviour starts as a failing test:

1. Add a test in `tests/` expressing the next SPEC requirement.
2. `make test SUITE=<TestName>` - watch it fail (red).
3. Implement the minimum in `src/` to make it pass (green).
4. Refactor; rerun.
5. `make check` before moving on.

Useful commands:

- `make test SUITE=<suite-or-test>` - one suite or one method
- `make test SUITE=A,B` - a comma-separated list
- `make watch` - rerun on every save
- `make test-leak` - heaptrc run; fails (exit 203) on leaks
- `make check` - `test` + `test-leak`, the gate before considering work done

## Conventions

- One `tests/test_<unit>.pas` per source unit. Each `test_*.pas` must be added to
  the `uses` clause of `tests/hildegard_helper_tests.pas` - FPC does not
  auto-link test units.
- Suite and method names describe the behaviour; every acceptance criterion maps
  to at least one named test.
- Tests are hermetic: no network, no external services, no fixed paths. Use
  temporary directories and clean them up.
- Tests compile under `-Sew`, so warnings are errors. A test that does not
  compile is not a passing test.

## Leak testing (heaptrc)

`make test-leak` links heaptrc and fails with exit 203 if anything is still
allocated. Run a single suite under the leak build to localise a leak:

```sh
HEAPTRC=haltonnotreleased build/bin/hildegard-helper-tests-leak \
  --suite=TStoreTest --format=plain
```

With `haltonnotreleased` the report lists every unfreed block and its allocation
trace. `make test-leak` uses `haltonnotreleased:skipifnoleaks`, so a clean run is
silent.

### Finding: `FillChar` on a managed record leaks

**Symptom:** a thread or loop test leaks a fixed number of small blocks (for
example 16 blocks of 21 bytes) while equivalent single-call tests are clean.

**Cause:** `FillChar(Rec, SizeOf(Rec), 0)` zeroes a record that already holds
managed fields (strings, dynamic arrays, interfaces) *without* decrementing
their reference counts. When called more than once on the same record - for
example at the top of a loop - every previous allocation leaks. `FillChar` is
only safe the first time an otherwise-uninitialised record is used.

**Fix:** use `Default`:

```pascal
Rec := Default(TStoredRequest);   // finalises old fields, then zeroes
```

`Default(T)` finalises any existing managed fields before producing a zero value,
so it is safe in loops and on reused records.

### Finding: FPC does not initialise managed local variables

**Symptom (a warning-as-error):**

```
Warning: (treated as error) Local variable "Cred" of a managed type does not
seem to be initialized
```

or, worse, tests that pass locally but fail intermittently because an
uninitialised `Int64`/`Boolean` carried garbage.

**Fix:** initialise record locals explicitly:

```pascal
Cred := Default(TDeviceCredentials);
```

Records passed as `out` parameters are initialised by the compiler and do not
need this; records used as `const`/value inputs do.

### Finding: initialize managed function results

**Symptom (a warning-as-error) on a function that assigns via `SetLength`:**

```
Warning: (treated as error) Function result variable of a managed type does not
seem to be initialized
```

**Fix:** assign `Result := nil;` (or `Result := Default(T);`) before `SetLength`,
or before the first conditional assignment.

### Finding: non-ASCII source literals compile to `?`

**Symptom:** a test expecting a box-drawing, braille, or block glyph fails with
`expected: <?????     >` while the actual value is correct.

**Cause:** FPC reads source in the default codepage, so a literal such as `'█'`
(three UTF-8 bytes) is stored one code unit per byte; converting it to
`UnicodeString` yields mojibake, and the rendered/comparison value shows `?`.

**Fix:** add `{$codepage utf8}` to the unit (right after `{$mode delphi}{$H+}`),
or build the string from code points (`UnicodeString(WideChar($2588))`). Prefer
the directive in literal-heavy units (spinner frames, eighth blocks). Programs
that render such text already list `cwstring` second on Unix.

## Isolation and resources

- Create a unique temp directory per test (`GetTempDir` + a unique suffix) in
  `SetUp` and remove it in `TearDown`.
- SQLite in WAL mode creates sibling `-wal` and `-shm` files; delete those as
  well as the database file so `TearDown` actually cleans up.
- Own every thread and object: `WaitFor` and `Free` in `TearDown`, and free
  objects in `try/finally` so a failed assertion cannot leak.
- Test threads must guard shared state with a lock and be joined; the leak gate
  will not forgive an orphaned thread's allocations.

## Testing failure paths with seams

Some behaviour cannot be triggered through the public API without corrupting
state (for example, a mid-migration failure). Add a narrow, testable seam rather
than weakening a shipped path:

- The SQLite store takes an explicit migration list through an overloaded
  constructor, so a test can inject a deliberately failing migration and assert
  the rollback and the unchanged schema version.
- Prefer injecting data or collaborators (a transport, a migration list, a
  clock) over reaching into private fields.

Verify externally observable state, not internals. When the public API does not
expose something a test needs (such as `PRAGMA user_version`), read it through a
separate direct connection in the test rather than widening the production API.

## Concurrency tests

- Assert on outcomes, not timing, wherever possible; when timing is unavoidable,
  leave generous margin (the pool test asserts "at least two waves", not an exact
  duration).
- N threads claiming from a shared queue must produce exactly N distinct claims;
  assert count and uniqueness, not order.
- Avoid `Sleep` to "wait for" a thread; use `WaitFor`.

## Don't touch the network

- Never call a real LLM provider, API, or remote service from a test.
- Inject the transport at the boundary and exercise the logic against a fake,
  including malformed and error responses.
- HTTP and SSE parsing must be tested against in-memory streams so the suite
  stays fast and deterministic.

## Database-specific notes (SQLite)

> **Superseded (SQLDB removed).** The store no longer uses SQLDB; it binds the
> vendored SQLite directly (`hildegard.helper.sqlite`) and links it statically
> (`-k<archive>`). The SQLDB notes below are kept for historical context only.
> Current hard-won points: `external 'sqlite3'` pulls no library by itself;
> `-Fl`+`-lsqlite3` resolves to the *system* dylib (FPC's search order), so link
> the archive with `-k`; SQLite placeholders are 1-based and indices shift when
> optional clauses add binds (a real bug we hit).

Hard-won FPC `fcl-db` behaviours that affect both implementation and tests:

- **`PRAGMA journal_mode=WAL` cannot be set through SQLDB.** SQLDB wraps
  statements in a transaction, and SQLite refuses the change inside one. Set WAL
  on the raw file before connecting (it persists in the database header), or use
  the connection handle and `sqlite3_exec` directly.
- **`PRAGMA foreign_keys` is set at connect time** via
  `TSQLite3Connection.Params` (`foreign_keys=ON`); like WAL, it is a no-op inside
  a transaction.
- **`TSQLDBLibraryLoader`** (`ConnectionType := 'SQLite3'`, `LibraryName := path`)
  is how the vendored library is loaded. The library is process-global; load it
  once and do not unload it.
- **`TSQLite3Connection` is not thread-safe.** Serialize all access - the store
  uses a single connection behind one critical section. Tests that drive SQL from
  several threads exercise that serialization.
- **Always `Commit`/`Rollback` before starting another transaction;** SQLDB's
  implicit transactions can otherwise collide with explicit `StartTransaction`.
- `sqlite3conn`, `sqldb`, and `sqldblib` are already on the default unit path for
  FPC 3.3.1; no extra `-Fu` is required.

## Hard-won findings, in brief

- `FillChar` on a reused managed record leaks strings; use `Default(T)`.
- FPC does not auto-initialise managed local variables; initialise them, or the
  `-Sew` build fails (and if it compiled, you would have uninitialised
  non-managed fields).
- Managed function results assigned only via `SetLength` must be initialised
  first.
- Non-ASCII source literals need `{$codepage utf8}` (or `WideChar($XXXX)`), or
  they compile to `?`.
- A leak gate is only useful if tests run under it: `make test-leak` is part of
  `make check`, not optional.
- "Compatible" APIs have edge cases: verify the exact call path (transactions,
  connect-time vs statement-time pragmas) with a small probe before writing the
  spec or the code.

## Related

- `spec-driven-development.md` - the five-stage workflow and the TDD loop
- `ponytail.md` - reuse before building; test at trust boundaries
- `source-control.md` - run `make check` before committing code changes
- `AGENTS.md` - commands and FPC/platform constraints
