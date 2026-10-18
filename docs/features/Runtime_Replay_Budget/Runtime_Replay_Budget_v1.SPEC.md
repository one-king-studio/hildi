# Component Specification: Runtime Replay Budget v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.session.runtime` (the replay buffer and
`Broadcast`), `hildegard.helper.session.protocol` (`ekGap`, `TSessionEvent`).

## Purpose

Bound the runtime's per-session replay buffer: a ring of at most
`MaxReplayEvents` events, dropping the oldest on overflow, with an `ekGap` to a
client whose `FromSeq` predates the retained window, and string release at the
turn boundary.

## Requirements

### Functional

- [ ] **Config.** `TSessionRuntimeConfig` gains `MaxReplayEvents: Integer`
      (0 → `DefaultMaxReplayEvents`). A negative value is treated as the default
      (there is no "unbounded" — the point is a ceiling).
- [ ] **Ring buffer.** `FReplay` holds at most `MaxReplayEvents` entries.
      `ReplayPush` writes at `(FReplayHead + FReplayLen) mod Cap`; when full it
      advances the head instead of growing. Capacity is allocated once to the
      cap. No `SetLength` growth after the first fill.
- [ ] **Dropped-range tracking.** The runtime remembers the seq range it still
      holds (`FReplayFirstSeq`). A push that drops the oldest raises
      `FReplayFirstSeq` to the new oldest.
- [ ] **`ReplayTo` gap.** For a client whose `FromSeq` is below
      `FReplayFirstSeq`, `ReplayTo` emits an `ekGap` with `FromSeq` =
      the requested start and `ToSeq` = `FReplayFirstSeq - 1`, then replays the
      retained events from `FReplayFirstSeq`. A `FromSeq` at or above the window
      replays normally (no gap).
- [ ] **Reset releases strings.** `ReplayReset` clears each live entry to
      `Default(TSessionEvent)` (freeing `Text`/`Detail`/`ToolArguments`/
      `ToolReason`), resets length and head, and keeps the allocation.
- [ ] **Mid-turn attach unchanged.** A client attaching within the window still
      receives the live turn's events in order, exactly as today.

### Non-Functional

- [ ] `ReplayPush` is O(1) — no growth, no shift.
- [ ] Memory is bounded by `MaxReplayEvents * SizeOf(TSessionEvent)` plus the
      strings of at most that many events.
- [ ] `make check` green; leak-clean (the reset must not strand strings).

## Contracts & Interfaces

```pascal
{ hildegard.helper.session.runtime }
const
  DefaultMaxReplayEvents = 4096;

TSessionRuntimeConfig = record
  ...
  { Most turn events the replay buffer retains for a late-attaching client.
    0 => DefaultMaxReplayEvents. A negative value also selects the default. }
  MaxReplayEvents: Integer;
end;

TSessionRuntime = class
private
  FReplay: array of TSessionEvent;
  FReplayCap: Integer;    { allocated slots; == the resolved cap }
  FReplayLen: Integer;    { live entries, <= FReplayCap }
  FReplayHead: Integer;   { index of the oldest live entry }
  FReplayFirstSeq: Int64; { seq of the oldest live entry; 0 when empty }
  ...
end;
```

### Behaviour

- `ReplayPush(AEvent)`: if `FReplayLen < FReplayCap` write at
  `(FReplayHead + FReplayLen) mod Cap`, `Inc(FReplayLen)`. Else overwrite the
  head's slot, `FReplayHead := (FReplayHead + 1) mod Cap`, and set
  `FReplayFirstSeq := AEvent.Seq - (FReplayCap - 1)`.
- `ReplayTo(AClient, AFromSeq)`: if `AFromSeq < FReplayFirstSeq` (and the buffer
  is non-empty), emit the gap first; then walk the live ring in order and send
  every event with `Seq >= Max(AFromSeq, FReplayFirstSeq)`.
- `ReplayReset`: for each live slot, `FReplay[..] := Default(TSessionEvent)`;
  `FReplayLen := 0`; `FReplayHead := 0`; `FReplayFirstSeq := 0`.

### Data Contracts

- `ekGap` carries `FromSeq` (first missing) and `ToSeq` (last missing), both
  already in `TSessionEvent`.
- The ring holds events in seq order; iteration from `FReplayHead` yields
  ascending seq.

## Architecture

The buffer stays in `TSessionRuntime`; no new unit. `ReplayPush`/`ReplayTo`/
`ReplayReset` change in place. `Broadcast` is unchanged (it still pushes every
non-`ekGap` event); the ring does the bounding.

## Validation and error handling

- An empty buffer (`FReplayLen = 0`) replays nothing and emits no gap.
- A `FromSeq` of 0 (the whole live turn) replays everything retained; if the
  window has already dropped the start, the client gets a gap for the head.
- The cap is resolved once at `Create`; a config of 0/negative resolves to the
  default.

## Testing requirements

### Unit tests (`tests/test_session_runtime.pas`)

- [ ] `TestReplayCapDropsOldest`: push `Cap + N` events; `ReplayLen = Cap`; the
      oldest `N` seqs are gone and the newest are present.
- [ ] `TestReplayRingDoesNotGrow`: after pushing far past the cap, the allocated
      capacity equals the cap (no doubling).
- [ ] `TestAttachOlderThanWindowGetsGap`: attach with a `FromSeq` below the
      window; the sink sees one `ekGap` whose range covers exactly the dropped
      seqs, then the retained events.
- [ ] `TestAttachWithinWindowNoGap`: attach with a `FromSeq` inside the window;
      no `ekGap`.
- [ ] `TestTurnResetReleasesStrings`: a long turn then a reset leaves the buffer
      empty and the cap unchanged.

### Integration tests

- [ ] The existing `TestAttachMidTurnReplaysLiveTurn` and
      `TestSlowObserverGetsGap` still pass (the cap must exceed a normal turn's
      events, so the default is high enough).

## Performance targets

- `ReplayPush` O(1); a turn of 100k events allocates no more than the cap.

## Security considerations

- The cap bounds a runtime's memory against a chatty or hostile turn.
- No protocol change; a client cannot request more than the retained window.

## Success criteria

- [ ] All contracts implemented; `make check` green; leak-clean.
- [ ] The replay buffer holds at most `MaxReplayEvents` events, ever.
- [ ] A client attaching outside the window is told, not silently truncated.

## Out of scope

- Persisting the replay buffer.
- Changing the client's fallback (it already has `History`).
- A memory audit of the rest of the runtime.
