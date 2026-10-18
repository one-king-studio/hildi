# Implementation Plan: Runtime Replay Budget v1

**Related Specification:** `Runtime_Replay_Budget_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Make the runtime's replay buffer a ring capped at `MaxReplayEvents`, emit an
`ekGap` for a client whose `FromSeq` predates the window, and release the
retained strings at the turn boundary. TDD-first; `make check` before moving on.
`main` only.

## Implementation Tasks

### Phase 1: The ring

- [x] **Test**: `TestReplayRingDoesNotGrow` — after pushing past the cap, the
      allocated capacity equals the cap.
- [x] **Implement**: `FReplayHead`/`FReplayFirstSeq`; `ReplayPush` writes at the
      head-relative slot and, when full, advances the head (no growth).
- [x] **Test**: `TestReplayCapDropsOldest` — the oldest seqs are gone; the
      newest are present; `ReplayLen = Cap`.
- [x] **Implement**: allocate the buffer once to the resolved cap in `Create`.
- [x] **Test**: `TestTurnResetReleasesStrings` — a reset leaves the buffer empty
      and the cap unchanged.
- [x] **Implement**: `ReplayReset` clears live entries to `Default`.
- [x] **Refactor**; `make check`; `make test-leak`.

### Phase 2: The gap

- [x] **Test**: `TestAttachOlderThanWindowGetsGap` — one `ekGap` covering the
      dropped range, then the retained events.
- [x] **Implement**: `ReplayTo` emits the gap and replays from
      `Max(FromSeq, FReplayFirstSeq)`.
- [x] **Test**: `TestAttachWithinWindowNoGap` — no `ekGap`.
- [x] **Refactor**; `make check`.

### Phase 3: Config & validation

- [x] **Test**: `MaxReplayEvents = 0` resolves to the default; the existing
      mid-turn attach and slow-observer tests still pass.
- [x] **Implement**: the config field and its resolution.
- [x] `make test`, `make test-leak`, `make check` — green.
- [x] **Measured** (in place of the live manual check, which needs provider
      credentials): `build/script-check/rss_probe.pas` builds the same event
      stream the runtime would and compares the buffer shapes — 65,625 KiB
      retained before, 1,344 KiB after, flat in turn length. A live headless
      RSS sign-off remains for the operator.
- [x] **Update** `FEATURES.md`; rename this TODO to
      `Runtime_Replay_Budget_v1.DONE.md`.

## Files to Create/Modify

```
src/hildegard.helper.session.runtime.pas   (ring + gap + reset)
tests/test_session_runtime.pas             (extended)
docs/features/FEATURES.md
```

## Critical Path

1 (ring) → 2 (gap) → 3 (config & validation).

## Success Criteria

- [x] All tasks checked.
- [x] Every SPEC acceptance criterion maps to a passing test.
- [x] `make check` passes (tests + leak gate).
- [x] The buffer holds at most `MaxReplayEvents` events, ever.

## Notes & Considerations

- **Default is deliberately generous.** `TestSlowObserverGetsGap` pushes 6002
  events in one turn; the default cap must exceed a realistic turn so no
  existing behaviour changes. 4096 may be too low for that test — check it and
  set the default so the test passes unchanged, or give that test an explicit
  higher cap.
- **`ekGap` already exists** and `Broadcast` already refuses to buffer it, so
  no protocol change.
- Record deviations from the SPEC here.
