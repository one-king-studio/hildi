# Implementation Plan: Request Retry v1

**Related Specification:** `Request_Retry_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

A bounded, cancellable retry around each request for transient failures
(network, 429, 5xx), plus an accurate operator-facing message. TDD-first;
`make check` before moving on. `main` only.

## Implementation Tasks

### Phase 1: Classification and phrasing (`hildegard.helper.llm`)

- [ ] **Test**: `TestIsRetryable` — the exhaustive table: `leNetwork` yes;
      `leRateLimit` yes; `leHttpStatus` 5xx yes, 400/401/403/404 no; everything
      else no.
- [ ] **Implement**: `IsRetryable(AError, AStatus)`.
- [ ] **Test**: `TestOperatorPhrase` — one short phrase per code.
- [ ] **Implement**: `OperatorPhrase`.
- [ ] **Refactor**; `make check`.

### Phase 2: The retry loop (`hildegard.helper.agent`)

- [ ] **Test**: `TestRetryOnNetworkThenSucceed` — a fake transport fails
      `leNetwork` twice, succeeds third; the turn completes.
- [ ] **Implement**: `TAgentConfig.RetryMaxAttempts`/`RetryBaseMs`/`RetryMaxMs`/
      `RetryBudgetMs` (defaults; negative disables); the retry wrapper around
      `Complete` in the request loop.
- [ ] **Test**: `TestRetryExhaustionFailsWithAnAccurateMessage` — the turn fails
      with `'network error after N attempts'` and the raw detail.
- [ ] **Implement**: the message/detail split on exhaustion.
- [ ] **Test**: `TestCancelDuringBackoffReportsCancelled` (an injected cancel
      during the wait).
- [ ] **Implement**: the cancel check during the backoff wait.
- [ ] **Test**: `TestBudgetStopsTheRetryLoop`,
      `TestRetryDisabledWhenMaxAttemptsNegative`.
- [ ] **Implement**: the budget bound and the disable flag.
- [ ] **Test**: `TestRetryDisabledWhenMaxAttemptsNegative` covers the flag.
- [ ] **Refactor**; `make check`.

### Phase 3: Backoff and `Retry-After`

- [ ] **Test**: `TestBackoffIsExponentialWithJitter` (an injected RNG pins the
      delays), `TestBackoffCapsAtRetryMaxMs`.
- [ ] **Implement**: `random(0, base * 2^n)`, capped, budget-bounded; the RNG
      injectable for tests.
- [ ] **Test**: `TestRateLimitHonoursRetryAfter` — a 429 with `Retry-After`
      waits at least that long; a `Retry-After` beyond the budget fails at once
      with a detail naming the wait.
- [ ] **Implement**: read `Retry-After` from the failed response and apply it.
- [ ] **Refactor**; `make check`.

### Phase 4: The ledger and the event

- [ ] **Test**: `TestEachAttemptIsARequestRow` — three attempts record three
      `requests` rows; the failed ones carry their error; the turn's token
      totals count only the success.
- [ ] **Implement**: one `requests` row per attempt.
- [ ] **Test**: `TestRetryingEventEmitted` — attempt/total/delay carried.
- [ ] **Implement**: `teRetrying` in `hildegard.helper.harness.turn` (appended
      last) and `ekRetrying` in `hildegard.helper.session.protocol`; the loop
      emits it per failed attempt.
- [ ] **Refactor**; `make check`.

### Phase 5: Validation & docs

- [ ] `make test`, `make test-leak`, `make check` — green.
- [ ] **Manual**: force a DNS failure (a bad host in a scratch config) and
      confirm the retry and the message.
- [ ] **Update** `FEATURES.md`; rename this TODO to `Request_Retry_v1.DONE.md`.

## Files to Create/Modify

```
src/hildegard.helper.llm.pas              (IsRetryable, OperatorPhrase)
src/hildegard.helper.agent.pas            (the retry loop, config, the message)
src/hildegard.helper.harness.turn.pas     (teRetrying)
src/hildegard.helper.session.protocol.pas (ekRetrying)
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
