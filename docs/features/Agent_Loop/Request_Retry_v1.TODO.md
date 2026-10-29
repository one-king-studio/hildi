# Implementation Plan: Request Retry v1

**Related Specification:** `Request_Retry_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

A bounded, cancellable retry around each request for transient failures
(network, 429, 5xx), plus an accurate operator-facing message. TDD-first;
`make check` before moving on. `main` only.

## Implementation Tasks

### Phase 1: Classification and phrasing (`hildi.llm`)

- [x] **Test**: `TestIsRetryable` — the exhaustive table: `leNetwork` yes;
      `leRateLimit` yes; `leHttpStatus` 5xx yes, 400/401/403/404 no; everything
      else no.
- [x] **Implement**: `IsRetryable(AError)` (`TLLMError` gained `Status`).
- [x] **Test**: `TestOperatorPhrase` — one short phrase per code.
- [x] **Implement**: `OperatorPhrase`.
- [x] **Refactor**; `make check`.

### Phase 2: The retry loop (`hildi.agent`)

- [x] **Test**: `TestRetryOnNetworkThenSucceed` — a fake transport fails
      `leNetwork` twice, succeeds third; the turn completes.
- [x] **Implement**: `TAgentConfig.RetryMaxAttempts`/`RetryBaseMs`/`RetryMaxMs`/
      `RetryBudgetMs` (defaults; negative disables); the retry wrapper around
      `Complete` in the request loop.
- [x] **Test**: `TestRetryExhaustionReportsAttempts` — the turn fails with
      `'network error after N attempts'` and the raw detail.
- [x] **Implement**: the message/detail split on exhaustion.
- [x] **Test**: `TestRetryDisabledWhenNegative`.
- [x] **Implement**: the disable flag.
- [ ] **Test**: `TestCancelDuringBackoffReportsCancelled` (an injected cancel
      during the wait) — the code path exists (`SleepCancellable`); the test is
      not written.
- [x] **Implement**: the cancel check during the backoff wait.

### Phase 3: Backoff and `Retry-After`

- [x] **Test**: `TestRetryBackoffIsExponentialAndCapped` (the ceiling; the loop
      applies jitter within it).
- [x] **Implement**: exponential from the base, capped, budget-bounded.
- [ ] **Deferred**: `TestRateLimitHonoursRetryAfter` — needs the transport to
      return the response header (`PostStream` returns only the status).

### Phase 4: The ledger and the event

- [x] **Implement**: one `requests` row per attempt (the loop's inner
      `BeginRequest`/`FinishRequest`).
- [ ] **Test**: `TestEachAttemptIsARequestRow` — not written; the accounting is
      exercised indirectly by the retry tests.
- [ ] **Deferred**: `teRetrying`/`ekRetrying` and the live progress line, with
      the mid-stream rollback they would enable.

### Phase 5: Validation & docs

- [x] `make check` — green (1312 tests, leak-clean).
- [ ] **Manual**: force a DNS failure (a bad host in a scratch config) and
      confirm the retry and the message.
- [ ] **Update** `FEATURES.md`; rename this TODO to `Request_Retry_v1.DONE.md`.

## Files to Create/Modify

```
src/hildi.llm.pas              (IsRetryable, OperatorPhrase)
src/hildi.agent.pas            (the retry loop, config, the message)
src/hildi.harness.turn.pas     (teRetrying)
src/hildi.session.protocol.pas (ekRetrying)
tests/test_llm.pas                        (the classifier, the phrases)
tests/test_agent.pas                      (the retry cases)
docs/features/FEATURES.md
```

## Dependencies & Ordering

- Phase 1 before Phase 2 (the loop needs the classifier).
- Phase 3 after Phase 2 (backoff refines the wait).
- Phase 4 after Phase 2 (the ledger/event record the attempts).

## Success Criteria

- [ ] All tasks checked.
- [ ] Every SPEC acceptance criterion maps to a passing test.
- [ ] `make check` passes (tests + leak gate).
- [ ] A transient failure recovers silently; an exhausted one is explained.

## Notes & Considerations

- **Truncation stays out.** `leTruncated` is terminal here; Response
  Continuation owns it and explicitly keeps it out of retry.
- **Terminal errors never retry** — a bad key must not be hammered into a rate
  limit.
- **The partial response is dropped** between attempts, as Response Continuation
  already specifies; nothing partial is persisted.
- **The wait must be cancellable**, or an operator cannot stop a retry storm.
- Record deviations from the SPEC here.
