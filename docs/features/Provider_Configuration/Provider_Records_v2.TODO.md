# Implementation Plan: Provider Records v2

**Spec:** [Provider_Records_v2.SPEC.md](Provider_Records_v2.SPEC.md)
**Feature:** [FEATURE.md](FEATURE.md) — Stage 2 of 5
**Branch:** `agent/llm-params` in `.worktrees/llm-params`

## Phase 0 — Re-check the migration number

- [ ] `git log --oneline main -- src/HildiStore.pas` and confirm the highest
      `Version :=` on main. It is **21** as of `d4072f0`; the MCP lane claims 22.
      Re-check immediately before landing — two branches claiming one integer is
      silent, with no error and no red test.
      Files: none
      Done when: the number is confirmed and recorded in the commit message.

## Phase 1 — Schema

- [ ] Migration **23**: the `providers` table and the partial unique index that
      makes "exactly one active" a database invariant.
      Files: `src/HildiStore.pas`
      Done when: a fresh store and an existing store both migrate, and
      `StoreSchemaVersion` reports 23.

## Phase 2 — Typed store surface

- [ ] `TProviderRow` / `TProviderRowArray`, with a `Has*` boolean per nullable
      parameter so `NULL` is distinguishable from `0.0`.
      Files: `src/HildiStore.pas`
- [ ] `SaveProvider` (insert-or-update by name), `LoadProvider`, `ListProviders`,
      `DeleteProvider`.
- [ ] `SetActiveProvider` / `ActiveProvider`, the clear-old-and-set-new in one
      transaction.
- [ ] The secret accessor, keyed by provider name, reusing the existing
      secret-bearing table's shape.

## Phase 3 — Resolution

- [ ] `ResolveProviderConfig`: store → environment → built-in default.
      Files: `src/HildiHarnessSession.pas` (the session owns "which provider"),
      `src/HildiLLM.pas` only for the validation reuse.
      Done when: an install with no provider row produces byte-identical
      behaviour to today.
- [ ] A bad **stored** value is reported through the same `leConfig` path Stage 1
      uses; never clamped, never ignored.

## Phase 4 — Tests

- [ ] `tests/TestStore.pas`: the provider CRUD tests.
      - `TestProviderRowRoundTripsEveryParameter`
      - `TestZeroTemperatureSurvivesAsConfiguredNotNull` — the round-trip trap
      - `TestNullParameterComesBackAbsent`
      - `TestSaveProviderUpdatesByNameInsteadOfDuplicating`
      - `TestListProvidersIsStable`
      - `TestActivatingAProviderLeavesExactlyOneActive`
      - `TestDeleteActiveProviderLeavesNoActiveRow`
- [ ] `tests/TestLLM.pas` or a session test: resolution precedence.
      - `TestStoreValueBeatsTheEnvironment`
      - `TestEnvironmentFillsWhatTheStoreLeftEmpty`
      - `TestNoProviderRowBehavesExactlyAsBefore`
      - `TestOutOfRangeStoredParameterIsReportedNotClamped`
      - `TestSecretNeverAppearsInAnErrorMessage`

## Phase 5 — Gate

- [ ] `make check` green, both suite passes and both isolation checks.
- [ ] Update `FEATURE.md` stage 2 boxes and the `FEATURES.md` row (the row is
      integrator-owned; hand the edit over at merge time).

## Notes / deviations

- **Columns, not a JSON blob.** Stage 5 has to report on provider and model
  without joining or parsing, and Stage 3 edits individual fields. A JSON blob in
  `settings` would lose the `UNIQUE` constraint and every query.
- **Nullable columns are load-bearing.** `temperature REAL` with no NOT NULL is
  the SQL spelling of Stage 1's tri-state. A `NOT NULL DEFAULT 0` would make
  every provider a zero-temperature provider.
- **The secret is not a column on `providers`.** It goes in the secret-bearing
  table keyed by name, so a provider row can be listed and edited without ever
  loading a key.
- **Security gap, recorded not fixed.** `mcp_oauth_tokens` already stores secrets
  in plaintext and the store is not created `0600`. This stage adds another
  secret, so the gap gets more valuable to an attacker. Fixing it is a separate
  feature that must touch every secret table at once; it is named in the SPEC so
  the inheritance is deliberate.
- **`HildiLLM` must not learn SQL.** The session loads the row and hands
  `HildiLLM` a completed config; the request builder stays pure and testable
  without a database.
