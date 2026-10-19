# TUI Event Graph (RxPascal)

## Overview

The TUI is **one drain on one thread** — a single-threaded UI with a mailbox, which
is correct. What is wrong is that the drain is **unbounded**: a streaming
`run_command` keeps the UI thread inside `DrainQueue` until the queue empties, so
it never renders and never polls input — the "UI freezes" symptom.

This feature captures two things:

1. **The decision (v1).** Make the drain **frame-paced and bounded**, coalesce
   the streamed signals, and bound the queue and retained output. Small, targeted.
2. **The direction (future).** The whole TUI becomes an **event graph** on the
   Async Core library — "RxPascal": every source is a stream, state is a `Scan`
   over the command lane, and rendering is a frame-paced subscription to the
   latest state. The conversion table below is the roadmap.

The fix does **not** require the conversion. The conversion is what makes the
policy explicit and composable afterwards.

## Problem Statement

`run_command` streams its output live as many `teToolOutput` events. The runtime
sends them; `TClientReader` pushes them onto `TTurnQueue`; the UI's `OnLoop` calls
`DrainQueue`:

```
while FDriver.PopEvent(E) do HandleTurnEvent(E);   // harness.app.pas
```

If the producer outpaces the consumer, the queue **never empties**, so this loop
never returns: no `Present`, no `FInput.Wait`, no frame. Three compounding causes:

- **Unbounded drain** — the loop drains until empty, not for a budget.
- **No coalescing** — one `teToolOutput` per read chunk; a chatty command is
  thousands of events, each appended (`FTool.AppendText`) and each dirtying layout.
- **Unbounded retention** — the tool block grows without limit, and its per-chunk
  re-measure is the layout trap the project already documented.

Plus `TTurnQueue.Push` grows the backing array by one under the same lock the UI
pops with.

## Decision

1. **The TUI stays one drain on one thread.** That is the scheduler; everything
   funnels into it. No second UI thread.
2. **The drain is frame-paced.** Each loop drains a **bounded budget** (N events or
   M milliseconds), then renders and polls input — never "until empty".
3. **Two lanes.** Sources are split by their contract:
   - **Commands** — terminal input, approval answers, interrupt, queued prompts,
     subagent abort/release: **lossless and ordered**. Never coalesced.
   - **Signals** — tool output, assistant/reasoning deltas, progress, subagent
     status, ambient: **coalescible** (batched/concatenated, or latest-wins).
   Coalescing a command would deadlock the runtime (an unanswered ask) — the lane
   split is load-bearing, not cosmetic.
4. **Bounded throughout.** A bounded queue, bounded retained output (truncate,
   keep the tail), and the bounded drain budget.
5. **The frame clock is the `Sample` tick.** Rendering happens once per frame from
   the latest state, not once per event.
6. **The full conversion is the direction, not the price of the fix.** v1 is the
   four changes above; the event-graph model lands incrementally.

## v1 — the fix

**Implemented.** All four landed in the harness (commits `da1f42b`, `4993577`,
`32ee607`, `d4381cc`); the checklist is kept for the record.

- [x] **Bound the drain**: `THarnessApp.DrainQueue` processes at most
      `DrainBudget` (256) events per frame, then returns so the loop can render
      and poll input (`harness.app.pas`). A dropped-output warning is surfaced
      once when the bound is first hit. (Count-bounded; a wall-clock bound was
      not needed — 256 events is well under a frame.)
- [x] **Coalesce signals**: streamed `teToolOutput` is buffered in the app and
      appended to the live block once per frame (`THarnessApp.FlushToolOutput`),
      so a chatty command costs one layout, not one per chunk.
- [x] **Bound retention**: the live tool block keeps only its tail
      (`MaxLiveChars` = 65536, older text trimmed with a marker), and the queue is
      bounded (`TTurnQueue` over `TBoundedQueue`, capacity 4096).
- [x] **Fix `TTurnQueue.Push` growth**: the queue is a fixed-capacity ring
      (`TBoundedQueue`, O(1) push, no grow-by-one), and a control event is never
      dropped — it evicts the oldest streamed event to make room.

**Still ahead (v2/v3, see *Phasing*):** state as a stream (`Scan` + frame-paced
render), then the graph itself on Async Core.

## The conversion table

Today's TUI constructs and their RxPascal equivalents. This is the roadmap for the
future conversion, not a v1 requirement.

| Today (harness / TUI) | RxPascal | Notes |
| --- | --- | --- |
| `TTurnQueue` (locked FIFO) | `Subject<TTurnEvent>` (bounded) | the mailbox; the tail is `ObserveOn(Ui)` |
| `TTurnEvent` + `TTurnEventKind` | `ISubscribable<TTurnEvent>`; per-kind `Filter` | or one subject per kind |
| `TClientReader` (reader thread) | the socket **producer** | `OnNext` per decoded message |
| `TRemoteDriver` | the **source adapter** | wire event → `TTurnEvent` |
| `TTurnWorker` (local path) | `SubscribeOn(Pool)` | the loop runs on an executor |
| `DrainQueue` (`while PopEvent`) | `Sample(Frame)` on the UI scheduler | **the drain, frame-paced** |
| `HandleTurnEvent` (big `case`) | `Scan(reducer, initialState)` | event → `UiState` |
| `FBusy` / `SyncBusy` | derived in the reducer (`Map(state → busy)`) | no separate flag |
| `teToolOutput` | the **signal** lane (`Buffer`/`Sample`/`Throttle`) | coalescible |
| `teApprovalAsk`, input, interrupt | the **command** lane (lossless) | never dropped or reordered |
| `TApprovalGate` (worker blocks on the UI) | a request **future** | the answer completes it |
| `FInput.Wait` / `Poll` | an input source (`FromEvent` on the fd) | the terminal as a stream |
| frame clock (`FrameIntervalMs`, `NextFrameDelayMs`) | `Interval(frame)` — the `Sample` tick | one clock for animation and render |
| `Animating` / `AdvanceTree` | `Interval` → `Advance` | animation as a stream |
| `FLayoutDirty` / `FNeedsRepaint` | `DistinctUntilChanged` on `UiState` | repaint only on change |
| `RenderFrame` / `Present` | the terminal `Subscribe` | render from the latest state |
| `Measure` / `Arrange` | `Map(state → layout)` (pure) | widgets as functions of state |
| `FSidebar`, `FPanel`, `FCompose` | component subscriptions (`Map`/`Select` per slice) | each renders its slice |
| subagent spy / `TSubagentSpy` | `Merge` of subagent streams | |
| modal stack (`CloseModal`, …) | state + transitions in the reducer | |
| `Checkpoint`, `NeedOlderHistory` | an async request (a future) + a stream | pagination as `Scan` |
| `Step` / `Run` | the **driver** (`Run` = drive the scheduler) | tests step deterministically |
| `TSimpleEvent` wake | the scheduler's **wake** | posting wakes the loop |

## Phasing

- **v1 — the fix.** The four changes above; the TUI behaves as it does today, but
  under a stream it stays live. No new dependency.
- **v2 — state as a stream.** Replace the `case`/flags with `Scan` + a
  frame-paced render; the command/signal split becomes explicit. Still no
  dependency.
- **v3 — the graph on Async Core.** Port the sources, subjects and operators onto
  the library (`SubscribeOn`/`ObserveOn`, `Sample`, `Merge`), so adding a source
  is a `Merge` and the coalescing policy is stated per source.

## Risks

- **Coalescing a command deadlocks.** The lane split must be enforced by type or
  by construction, not by discipline.
- **Ordering within a signal.** Coalescing deltas means concatenating in order,
  not dropping; only latest-wins streams (progress) may drop.
- **Rewriting for the fix.** v1 must not depend on v2/v3; the bounded drain and
  coalescing stand alone.
- **Two clocks.** The frame clock and any animation clock must be one source, or
  frames double.

## Out of Scope

- A second UI thread (the UI stays single-threaded).
- The full Async Core conversion (v3) — this feature records the direction.
- Changing the wire protocol; v1 coalesces in the runtime and bounds in the UI.

## Notes

- **This is a reframing of what exists** — queue, loop hook, frame clock, `FBusy`
  cadence, dirty flags — not a rewrite. The event graph names the policy the TUI
  already implies.
- **"RxPascal"** is the working name for the TUI built on the
  [`Async_Core`](../Async_Core/FEATURE.md) library (futures + observables
  over one scheduler spine).
- **The immediate repair is small**: a bounded drain, coalescing, and a bounded
  queue. Observables supply the vocabulary, not the fix.
