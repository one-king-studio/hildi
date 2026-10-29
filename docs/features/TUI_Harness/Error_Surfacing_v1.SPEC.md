# Component Specification: Error Surfacing v1

**Related Feature:** [FEATURE.md](FEATURE.md) (TUI Harness)

**Depends on:** `hildi.harness.turn` (`teError`/`teRetrying`),
`hildi.harness.app` (the transcript and status bar),
`hildi.llm` (`OperatorPhrase`).

**Pairs with:** [Request Retry
v1](../Agent_Loop/Request_Retry_v1.SPEC.md) — the loop's half of the same
problem. This is the client's half.

## Purpose

A failed turn must say **what happened** and, where the loop is recovering,
**show it recovering**. Today the app renders only the turn event's `Text` — the
generic `'request failed'` — and drops `Detail`, the actual cause. The data is
already on the wire; this makes the client use it.

> **Status (2026-10-13).** The **error-detail half has landed**: `ErrorText`, the
> live and resumed block text, and the CLI. The **retry line waits** on Request
> Retry v1 — `RetryText` and `teRetrying` are the client's half of a signal that
> does not exist yet, so implementing them now would be dead code.

## Problem Statement

The loop sends `teError` with `Text` (`'request failed'`) and `Detail`
(`Host name resolution for "api.fireworks.ai" failed.`). `harness.app` renders
`AppendError(E.Text)` and nothing else, so the operator sees a generic failure
while the actionable text sits unread in the ledger. There is no retry line
either, so a recovered blip is invisible and an unrecovered one is unexplained.

## Requirements

### Functional

- [ ] **Show the detail.** An error block renders the message **and**, when
      present, the detail — `network error: Host name resolution for
      "api.fireworks.ai" failed.` — not the bare message.
- [ ] **Persist what is shown.** The stored error block carries the same text, so
      a resumed session reads identically to the live one (the standing
      live-equals-resume invariant).
- [ ] **Show a retry.** On `teRetrying`, a dimmed status line reads
      `retrying in 2s (2/4)…`, replaced by the next attempt's stream; it clears
      on `teDone`/`teError`.
- [ ] **Phrase per code.** The block's lead phrase comes from the loop's
      `OperatorPhrase` (network / rate limited / authentication / provider …), so
      the operator gets an actionable label, not a code.
- [ ] **Distinguish cancel.** `leCancelled` still draws **no** error block (a
      user interrupt is not an error); `tsFailed`/`tsCancelled` keep their
      existing status-bar labels.
- [ ] **The CLI mirrors it.** The line-based client prints the same message +
      detail (it is not TUI-only).

### Non-Functional

- [ ] **No new event plumbing beyond `teRetrying`/`ekRetrying`** (defined in
      Request Retry v1); the client renders what it already receives.
- [ ] **Testable without a terminal**: the error text is a pure function of the
      event (`ErrorText(Text, Detail)`), unit-tested; the block render is tested
      on a memory surface.
- [ ] Leak-clean; `make check` green.

## Contracts & Interfaces

```pascal
unit hildi.harness.app;   // extended

{ The block text for a turn failure: the message, plus the detail when present.
  Pure, so the format is pinned without a surface. }
function ErrorText(const AMessage, ADetail: string): string;

{ The retry line for a teRetrying event. Pure. }
function RetryText(AAttempt, AAttempts: Integer; ADelayMs: Int64): string;
```

### Data Contracts

- **Error block text.** `AMessage`; if `ADetail <> ''`, `AMessage + ': ' +
  ADetail`. Both are already carried by `teError`; no protocol change.
- **Retry line.** `'retrying in ' + <delay> + ' (' + attempt + '/' + attempts +
  ')…'`, where `<delay>` is a rounded seconds/ms form.
- **`teRetrying` fields.** `Attempt`, `Attempts`, and `ElapsedMs` (the delay),
  as defined by Request Retry v1.

## Architecture

### Prior Art & Reuse

- **`AppendError`** already exists and already receives the text; the change is
  the text it is given and the call sites that build it.
- **`teError`** already carries `Text` and `Detail`; the `ekError` protocol event
  already carries both (`ErrorMessage`/`Detail`), so no wire change for the
  failure path.
- **The status bar / CTA hints** already exist for the retry line.
- **Genuine gap:** using `Detail`, the `teRetrying` line, and the two pure
  formatters.

### Component Boundaries

- **Responsibilities:** render the failure and the retry progress.
- **Dependencies:** the turn event stream only.
- **Side effects:** none beyond the transcript.

## Validation Rules

- An error with an empty detail renders the message alone (no trailing `: `).
- A `teRetrying` with no delay renders `retrying (2/4)…`.
- The error block is not drawn for `leCancelled`.

## Error Handling

- A malformed or missing field degrades to the message; the client never raises
  on an event.

## Testing Requirements

### Unit Tests (`tests/test_harness_app.pas`)

- [ ] `TestErrorTextIncludesDetail` — `network error` + a detail renders both.
- [ ] `TestErrorTextWithoutDetail` — the message alone, no trailing separator.
- [ ] `TestRetryTextFormatsAttemptsAndDelay`.
- [ ] `TestFailedTurnShowsTheDetail` — a `teError` with a detail draws a block
      containing it.
- [ ] `TestRetryingLineShownThenCleared` — `teRetrying` draws the line;
      `teDone`/`teError` removes it.
- [ ] `TestCancelledDrawsNoErrorBlock` — unchanged.

### Unit Tests (`tests/test_cli.pas`)

- [ ] `TestCliPrintsMessageAndDetail`.

  *Deviation:* the CLI's error formatting is `ErrorText`, unit-tested in
  `test_llm.pas`; the CLI's session observer lives in the example, not a unit, so
  a dedicated test is not reachable. The call site is a one-liner over the tested
  function.

## Performance Targets

- Negligible; one extra string per error and one status line per retry.

## Security Considerations

- The detail is transport text (a resolver or TLS message). It is rendered as
  **plain text** in the error block, never markdown — so a hostile detail cannot
  inject markup. (Error blocks already render as plain spans, not markdown.)

## Success Criteria

- [ ] A failed turn reads `network error: Host name resolution for
      "api.fireworks.ai" failed.`
- [ ] A retry shows `retrying in 2s (2/4)…` and clears when the turn resumes.
- [ ] A resumed session shows the same error text as the live one.
- [ ] `make check` green, leak-clean.

## Future Considerations

- A "copy the error" yank (reuses TUI Clipboard).
- A structured error detail (a cause chain) once providers return more.
