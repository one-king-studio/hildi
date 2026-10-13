# Component Specification: Request Retry v1

**Related Feature:** [FEATURE.md](FEATURE.md) (Agent Loop)

**Extends:** [Agent Loop v2](Agent_Loop_v2.SPEC.md) (the turn loop) and
[LLM Client v2](LLM_Client_v2.SPEC.md) (the error codes).

**Depends on:** `hildegard.helper.agent` (the loop and `TAgentConfig`),
`hildegard.helper.llm` (the error model and `TLLMErrorCode`),
`hildegard.helper.harness.turn` (the turn event stream).

## Purpose

A request that fails on a **transient** fault — a network or DNS failure, an
HTTP 429, a 5xx — currently ends the whole turn with a hardcoded, unhelpful
message (`leNetwork` → `'request failed'`). Nothing retries. This adds a bounded,
cancellable **retry policy** around each request, and makes every failure
**legible**: a short operator-facing phrase plus the raw cause.

## Problem Statement

The observed failure: six `leNetwork` turns over two days, each carrying
`Host name resolution for "api.fireworks.ai" failed.` as the *detail* — a
transient resolver hiccup (the network was fine minutes later). Each one ended
the turn, and the operator saw only `request failed`, because the UI renders the
message and not the detail. A transient fault was unrecoverable **and**
unexplainable.

The loop already owns the request lifecycle (`Complete` per request, `FailTurn`
per turn) and the turn event stream. The gaps are narrow: a classifier, a
backoff, an attempt record, and a message.

## Requirements

### Functional

- [ ] **Classify.** An error is **retryable** when it is `leNetwork` (transport,
      DNS, connection reset), `leRateLimit` (HTTP 429), or `leHttpStatus` with a
      **5xx** status. It is **terminal** otherwise: `leAuth`, `leConfig`,
      `leMalformedStream`, `leProvider`, `leCancelled`, `leLoop`, `leTruncated`.
- [ ] **Retry per request.** A retryable failure re-sends **the same request**
      (same messages, same body) up to `RetryMaxAttempts`, without ending the
      turn. A later attempt's success is the request's success.
- [ ] **Backoff.** Exponential with full jitter: `delay = random(0, base * 2^n)`,
      capped at `RetryMaxMs`, and never beyond the remaining `RetryBudgetMs`.
      Defaults: 3 attempts beyond the first, base 500 ms, cap 10 s, budget 30 s.
- [ ] **Honour `Retry-After`.** On a 429 (or 503) with a `Retry-After` header,
      wait at least that long, capped by the budget.
- [ ] **Cancellable.** The cancel check is honoured **during the wait** as well
      as the request: an operator interrupt stops a retry loop and reports
      `leCancelled`, not a network error.
- [ ] **Bounded.** The total wait never exceeds `RetryBudgetMs`; the attempts
      never exceed `RetryMaxAttempts`. A retry loop always terminates.
- [ ] **Recorded.** Each attempt is its own `requests` row (so the ledger shows
      the retries); a failed attempt carries its error, the successful attempt
      its usage. The turn's token totals count only the successful attempt.
- [ ] **Legible.** The turn's `ErrorMessage` is a short operator phrase
      (`network error`, `rate limited`, `authentication failed`, …) and
      `ErrorDetail` is the raw cause. On exhaustion the message says how many
      attempts were made.
- [ ] **Signalled.** A retryable failure emits a `teRetrying` turn event
      (attempt number, total, and the delay) so a client can show progress.
- [ ] **Not for truncation.** `leTruncated` is terminal here; a cut-off response
      is [Response Continuation](../Response_Continuation/FEATURE.md)'s job, and
      that feature keeps it out of retry.

### Non-Functional

- [ ] **Deterministic where it matters.** The *policy* (which errors retry, the
      attempt count, the budget) is pure and table-tested; only the jitter is
      random, and it is injectable so tests pin the delay.
- [ ] **Offline-testable.** A fake transport that fails N times then succeeds
      exercises every path with no network.
- [ ] **No new dependency.** Uses the loop's existing cancel check and the
      transport seam.
- [ ] Leak-clean; `make check` green.

## Contracts & Interfaces

```pascal
unit hildegard.helper.llm;   // extended

{ Whether a request error is worth retrying. True for leNetwork, leRateLimit,
  and leHttpStatus with a 5xx status. }
function IsRetryable(AError: TLLMErrorCode; AStatus: Integer): Boolean;

{ A short, operator-facing phrase for an error code ("network error",
  "rate limited", "authentication failed", "provider error", ...). }
function OperatorPhrase(AError: TLLMErrorCode): string;
```

```pascal
unit hildegard.helper.agent;   // extended

type
  TAgentConfig = record
    // ... existing ...
    { Transient-failure retry. 0 fields take the defaults below; a negative
      RetryMaxAttempts disables retry. }
    RetryMaxAttempts: Integer;   // default 3 (attempts beyond the first)
    RetryBaseMs: Integer;        // default 500
    RetryMaxMs: Integer;         // default 10000
    RetryBudgetMs: Integer;      // default 30000
  end;
```

```pascal
unit hildegard.helper.harness.turn;   // extended

type
  TTurnEventKind = (
    // ... existing, appended last so stored ordinals are unchanged ...
    teRetrying);   // an attempt failed retryably; Attempt/Attempts + the delay
```

```pascal
unit hildegard.helper.session.protocol;   // extended (Headless Sessions)

type
  TSessionEventKind = (
    // ... existing, appended last ...
    ekRetrying);   // { attempt, attempts, delay_ms }
```

### Data Contracts

- **Retryable set.** `leNetwork` (any), `leRateLimit` (429), `leHttpStatus` with
  `Status div 100 = 5`. Everything else is terminal. A `leHttpStatus` 4xx other
  than 401/403/429 is terminal (a bad request will not improve).
- **Attempt accounting.** `RetryMaxAttempts = N` means up to `N` *additional*
  requests after the first. Attempts stop early on success, on a terminal error,
  on cancel, on the budget, or when a `Retry-After` exceeds the remaining budget
  (the attempt is not made and the 429 is reported).
- **Message shape.** On exhaustion:
  `ErrorMessage = 'network error after 4 attempts'`,
  `ErrorDetail = 'Host name resolution for "api.fireworks.ai" failed.'`.
  On a terminal error, no attempt count.

## Architecture

### Prior Art & Reuse

- **`TAgentLoop`** already loops per request and owns `FailTurn`; the retry is a
  bounded inner loop around `Complete`, before the failure reaches `FailTurn`.
- **The cancel check** (`FCancel`) already exists; the retry reuses it, including
  during the backoff wait.
- **The transport seam** (`TLLMTransport`) is unchanged: retrying re-calls
  `PostStream`. The `Retry-After` header is read from the failed response.
- **The turn event stream** carries `teRetrying` to clients like any other event.
- **The ledger** already records a `requests` row per `Complete`; the retry
  records one per attempt.
- **Genuine gap:** the classifier, the backoff, the attempt accounting, the
  phrase, and the event.

### Component Boundaries

- **Responsibilities:** decide retryability, wait, re-send, count, and report.
- **Dependencies:** the transport (re-call), the cancel check, the ledger.
- **Side effects:** extra HTTP requests and `requests` rows; nothing else.

## Validation Rules

- A retryable error with `RetryMaxAttempts < 0` (retry disabled) fails the turn
  immediately, as today.
- An empty/whitespace provider response is not retryable (it is
  `leMalformedStream`, terminal).
- A cancel during the backoff wait reports `leCancelled`, and the turn is
  `tsCancelled` (not `tsFailed`), matching the existing cancel semantics.

## Error Handling

- The final failure (attempts exhausted, terminal error, or budget) is reported
  through `FailTurn` exactly as today, with the improved message.
- A `Retry-After` beyond the budget fails immediately with the 429 and a detail
  naming the wait, rather than silently waiting past the budget.

## Testing Requirements

### Unit Tests (`tests/test_agent.pas`)

- [ ] `TestRetryOnNetworkThenSucceed` — a fake transport fails with `leNetwork`
      twice, succeeds on the third; the turn completes and the ledger shows
      three `requests` rows.
- [ ] `TestRetryExhaustionFailsWithAnAccurateMessage` — always `leNetwork`; the
      turn fails with `'network error after N attempts'` and the raw detail.
- [ ] `TestRateLimitHonoursRetryAfter` — a 429 with `Retry-After` waits at least
      that long (injected clock), then succeeds.
- [ ] `TestFiveHundredRetries`, `TestFourHundredDoesNotRetry`
      (401/403/400 terminal), `TestProviderErrorDoesNotRetry`.
- [ ] `TestCancelDuringBackoffReportsCancelled` — a cancel fires during the wait.
- [ ] `TestBudgetStopsTheRetryLoop` — the total wait never exceeds the budget.
- [ ] `TestRetryDisabledWhenMaxAttemptsNegative`.
- [ ] `TestRetryingEventEmitted` — attempt/total/delay are carried.

### Unit Tests (`tests/test_llm.pas`)

- [ ] `TestIsRetryable` — the table, exhaustively.
- [ ] `TestOperatorPhrase` — one phrase per code.

## Performance Targets

- The happy path adds no work. A retry adds one request plus the backoff; the
  budget bounds the worst case.

## Security Considerations

- A retried POST is **not** idempotent — a partial response is discarded and the
  request re-sent. The provider's streaming API makes a partial response
  un-resumable, so this is the only option; the discarded partial is never
  persisted (the pending response is dropped, as
  [Response Continuation](../Response_Continuation/FEATURE.md) already specifies).
- A retry must never mask a **terminal** error (auth, config, malformed): those
  fail immediately, so a bad key is not retried into a rate limit.
- The cancel check bounds a retry loop, so an operator can always stop it.

## Success Criteria

- [ ] A transient DNS failure no longer ends the turn: it is retried and, on
      success, the operator never sees an error.
- [ ] When it cannot recover, the operator sees `network error after 4 attempts:
      Host name resolution for "api.fireworks.ai" failed.` — not `request failed`.
- [ ] `make check` green, leak-clean.

## Future Considerations

- A circuit breaker across turns; provider-specific backoff hints.
- Retrying at the *turn* level (re-running a tool call) once tools are
  idempotent — out of scope here.
