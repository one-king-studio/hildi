# Runtime Replay Budget

## Overview

Bound the session runtime's event **replay buffer** so a long-running runtime
does not hold its largest turn's events — and their string payloads — for the
life of the process. The buffer exists so a client that attaches mid-turn (or
reconnects) can be caught up from `FromSeq`; today it grows to the peak turn and
never gives the memory back.

## Problem Statement

`TSessionRuntime` keeps every turn event it broadcasts in `FReplay`, so an
attaching client can be replayed from `FromSeq` (`ReplayTo`). Two properties of
that buffer make a long run's memory usage track the **largest single turn**, not
a fixed ceiling:

1. **It grows to the peak and never shrinks.** `ReplayPush` doubles capacity
   (`FReplayCap` only ever rises), and `ReplayReset` — called at each turn's end
   — drops only the *length*:

   ```pascal
   procedure TSessionRuntime.ReplayReset;
   begin
     { Keep the allocated capacity; just drop the logical length. }
     FReplayLen := 0;
   end;
   ```

2. **Dropping the length does not release the strings.** `FReplay[i]` still
   holds the `TSessionEvent`, and its `Text`/`Detail`/`ToolArguments`/
   `ToolReason` are refcounted heap strings. They stay alive until a later turn
   overwrites those slots.

A `TSessionEvent` is **336 bytes** of record plus its strings, and one event is
emitted **per streamed chunk**:

- `teReasoningDelta` → `ekReasoningDelta` (one per reasoning fragment),
- `teAssistantDelta` → `ekAssistantDelta`,
- `teToolOutput` → `ekToolOutput` (one per ~8 KiB read from a command).

`Broadcast` pushes **unconditionally**, whether or not a client is attached —
the send loop is a no-op with zero clients, but `ReplayPush` has already run. So
a **headless** runtime with no listener buffers the whole turn for a client that
may never arrive.

The user-visible symptom: a headless agent's RSS rises over a long run and does
not come back down. Reasoning is the bulk of it, and reasoning is exactly the
data the runtime does not need — it is display-only, persisted for the TUI, and
never resubmitted to the provider.

## Decision

**Cap the replay buffer at a configurable number of events, drop the oldest on
overflow, and tell a client that asks for a dropped range via the existing
`ekGap`.** Release the retained strings on reset.

- `ReplayPush` becomes a **ring buffer**: at the cap it overwrites the oldest
  slot in O(1) (no `memmove`, no growth).
- `ReplayTo` sends an `ekGap` for any range the client asked for that has been
  dropped, then replays what remains. A client already falls back to
  `History`/`HistoryPage` for anything it missed; `ekGap` is the signal.
- `ReplayReset` clears the live entries (`Default(TSessionEvent)`), so the
  previous turn's strings are released at the turn boundary rather than pinned
  until overwritten.

The cap is a config field (`MaxReplayEvents`, 0 → a default), so an operator can
raise it for a long-attach observer or lower it for a headless run.

## Goals

- A runtime's replay memory is bounded by the cap, independent of turn length.
- The previous turn's event strings are released at the turn boundary.
- A client that attaches with a `FromSeq` older than the retained window gets an
  `ekGap` naming the missing range — never silence, never a partial replay
  presented as complete.
- No change to the wire protocol; `ekGap` already exists.

## Non-Goals

- **Not buffering nothing.** A mid-turn attach must still replay the live turn;
  that is the buffer's purpose.
- **Not the persisted history.** Reasoning stays in SQLite for the TUI to render
  on resume; that is a separate, bounded store.
- **Not the client's own queue.** `TTurnQueue` is already bounded (the
  TUI_Event_Graph repair).
- **Not a general memory audit.** This fixes the one unbounded array in the
  runtime; other components are out of scope.

## User Stories

- As an **operator** running a headless agent for days, I want its memory to
  plateau, so a long run does not grow without bound.
- As an **operator**, I want a client that attaches after a busy turn to be told
  what it missed, so I am not shown a partial transcript as if it were whole.
- As a **reviewer**, I want the runtime's per-session memory to have a stated
  ceiling, so "how much does a session cost?" has an answer.

## Acceptance Criteria

- [ ] The replay buffer never holds more than the configured cap of events.
- [ ] At the cap, the oldest event is dropped in O(1); the buffer does not grow.
- [ ] `ReplayTo` emits an `ekGap` naming the dropped range when `FromSeq` is
      older than the retained window, then replays the retained events.
- [ ] A turn boundary releases the previous turn's event strings.
- [ ] A mid-turn attach within the cap still replays the live turn (unchanged).
- [ ] `MaxReplayEvents` is configurable; 0 selects the default.
- [ ] `make check` green (tests + leak gate).

## Success Metrics

- The runtime's replay memory is bounded by `MaxReplayEvents`, not by the
  largest turn's event count.
- No behavioral change for an observer attaching within the cap.

## Constraints

- No wire-protocol change (`ekGap` exists).
- The buffer stays per-session and in-memory; no persistence.
- Portability: macOS + Linux, FPC 3.3.1.
