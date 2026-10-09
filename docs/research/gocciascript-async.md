# GocciaScript Async & Promises (research)

How the engine does `Promise`/`async`/`await`, and where a Pascal host plugs in —
read for the [Composed Tool Sandbox](../features/Composed_Tool_Sandbox/FEATURE.md),
whose tool calls must be awaitable so an approval can block them without the
script noticing. Everything here was read from the vendored tree at
`deps/goccia` (commit `531fb52…`).

## TL;DR

- **Real ES2026 promises, no event loop.** Promises, `async`/`await`,
  `queueMicrotask`, `Promise.withResolvers` all exist and follow the spec.
- **`await` blocks the awaiting frame.** It drives a fixed set of continuation
  sources to settlement — microtasks, `fetch`, `Atomics.waitAsync`, and a
  *virtual* timer queue — then throws if none of them settles the promise. There
  is no "return to the event loop"; the host *is* the event loop.
- **The host plugs in through a runtime extension** (`WaitForIdle` /
  `DiscardPending`) — `fetch` is the worked example — or by enqueuing jobs.
- **For our tool calls**, the simplest correct thing works today with no engine
  change: an async native function **blocks inside its callback** (that is where
  the approval wait happens) and returns an already-settled promise. The script
  sees an ordinary `await`.

## 1. Promise values

`Goccia.Values.PromiseValue.pas` — `TGocciaPromiseValue`:

- States `gpsPending` / `gpsFulfilled` / `gpsRejected`; `State`,
  `PromiseResult`, `IsHandled`.
- `Resolve(value)`, `Reject(reason)`, `SubscribeTo(promise)`, `InvokeThen`,
  `InvokeFinally`, `MarkHandled`.
- **Spec-faithful settle:** `Resolve` is a no-op once settled; resolving with a
  thenable enqueues a `prtThenableResolve` microtask (a two-tick adoption);
  resolving with self rejects with a `TypeError`. `Reject` on a promise with no
  handler calls `HostPromiseRejectionTracker` (`Queue.TrackRejection`).
- `TGocciaPromiseReactionCapability` is the resolve/reject pair a host can hold
  (`new Promise(executor)`, `Promise.withResolvers`). `PromiseResolveIntrinsic`
  is `Promise.resolve`.

A Pascal host can build a pending promise and settle it later:
`TGocciaPromiseValue.Create` then `.Resolve(v)` / `.Reject(r)` — **on the
runtime thread**, because settling touches that thread's microtask queue.

## 2. The microtask queue — the host's job queue

`Goccia.MicrotaskQueue.pas` — `TGocciaMicrotaskQueue`, a **thread-local
singleton** (`Instance`, `Initialize`, `Shutdown`), created alongside the GC.

- `Enqueue(microtask)` — a promise reaction (`Handler`, `Value`,
  `ResultPromise`, `ReactionType`).
- **`EnqueueJob(job: TGocciaMicrotaskJob)`** — the host hook. Subclass
  `TGocciaMicrotaskJob` (`Execute`; `CaptureRoots` to keep Pascal-side objects
  alive for the GC), enqueue it, and the drain runs it.
- `DrainOneJob: Boolean`, `DrainQueue`, `HasPending: Boolean`.
- **Scopes** (`EnterScope` / `LeaveScope`, `CurrentMicrotaskScope`): engines
  nest on one thread; a nested `Execute` runs in its own scope and neither runs
  nor discards the caller's jobs (ADR 0123).
- **Unhandled rejections:** `TrackRejection` / `UntrackRejection` /
  `TakeUnhandledRejection` / `UnhandledRejectionsInOrder` /
  `DiscardUnhandledRejections` (ES2026 §27.2.1.9).

## 3. `await` is a blocking drive loop

`Goccia.Values.Await.pas` — `AwaitValue(value)` (ES2026 §27.7.5.3 `Await`):

1. Coerce to a promise (`MarkHandled`).
2. Already settled → drain one microtask (a boundary), then return / throw.
3. Otherwise, **block and drive**, in order: `DrainMicrotasksUntilPromiseSettled`
   (microtasks only) → `WaitForFetchPromise` → `WaitForAtomicsPromise` → drain
   again → `RunTimersUntilPromiseSettled` (the *virtual* clock).
4. Still pending → `ThrowTypeError(SErrorAwaitPromiseUnsettled,
   SSuggestAwaitMicrotaskDrain)`.

`WaitForFetchPromise` is described in its own source as **"the host's general
'drive this promise to settlement' wait"** — the test runner uses it for every
async test's returned promise. It polls (`Sleep(FETCH_POLL_INTERVAL_MS)`) while
a fetch or an Atomics waiter is outstanding, and otherwise jumps the virtual
clock to the next timer. It knows **only** microtasks, fetch, atomics and
timers.

`Goccia.Timers.pas` makes the "no event loop" concrete: timers are records on a
**virtual** clock and run only when something advances it — fake-timer `vi`
advances, or the engine's own idle/await points. No wall time passes (ADR 0113).

## 4. The engine drains after every run

`Goccia.Engine.pas`:

- `Execute` / `ExecuteProgram` **drain the microtask queue before returning**
  (`WaitForRuntimeIdle`), so embedders do not manage it. A run that fails clears
  its own scope's jobs; a nested run discards only its own.
- Unhandled rejections: `Engine.UnhandledRejections` (`urThrow` default, or
  `urIgnore`) plus the `OnUnhandledRejection` hook; `Execute` clears its queue
  before returning, so `TakeUnhandledRejection` is a during-run tool (call it
  from a native callback) or the route for `ExecuteProgram` / `RunModule`
  (ADR 0125).

See `docs/interpreter.md` §*Synchronous Microtask Queue* and
`docs/embedding.md` §*Microtask Queue (Promises)*.

## 5. Where a Pascal host plugs in

**A runtime extension.** `TGocciaRuntimeExtension` (`Goccia.Runtime.pas`) is the
seam: `WaitForIdle` and `DiscardPending` are virtual, and
`TGocciaRuntime.WaitForIdle` runs every installed extension's `WaitForIdle` in
insertion order. `fetch` is the worked example
(`Goccia.RuntimeExtensions.Fetch.pas`):

```
TGocciaFetchRuntimeExtension.WaitForIdle → WaitForFetchIdle(realm)
```

and the manager underneath (`Goccia.FetchManager.pas`) does the real work
**off-thread** (`TGocciaFetchWorker : TThread`), then the runtime thread's
`PumpCompletions` settles the fetch promise. `DrainMicrotasksAndFetchCompletions`
is the exported pump (microtasks + fetch completions + `Atomics.waitAsync`).

So the host-async contract is: *do the work off the runtime thread; settle the
promise on the runtime thread; expose a pump/idle hook so the engine can drive
it.*

## 6. What this means for the Composed Tool Sandbox

The `await` drive loop pumps microtasks/fetch/atomics/timers but does **not**
call a runtime extension's `WaitForIdle`. So a host-created pending promise that
only the host can settle will make `await` throw *"unsettled"* — unless one of
the paths below is taken.

- **Path A — block inside the native callback (works today, recommended).** The
  injected `tools.*` callback performs the tool call **and its approval**
  synchronously (waiting on a `TSimpleEvent`/critical section the approval side
  signals), then returns an **already-settled** `TGocciaPromiseValue` (rejects on
  denial). The script's `await` is a one-microtask no-op and it **cannot tell the
  difference** — which is exactly the requirement. This matches the harness's
  existing threading: the agent worker already blocks on approval while the TUI
  answers. No engine change.
- **Path B — return a pending promise and be pumped.** Model it like `fetch`: a
  host completion pump wired into the drive loop. That needs a seam the engine
  does not have today — either an upstream change so `AwaitValue` calls the
  runtime extensions' `WaitForIdle`, or a `WaitForHostPromise` alongside
  `WaitForFetchPromise`. This is the upgrade if we ever want true concurrency
  (the script's other work continues while a tool call is in flight).
- **Path B′ — a self-rescheduling job (works today, busy).** Enqueue a
  `TGocciaMicrotaskJob` that checks whether the host's work is done, re-enqueues
  itself if not, and settles the promise when it is. The queue stays non-empty,
  so the drive loop keeps draining. It works, but it spins the drain thread
  (`CheckExecutionTimeout`/`CheckInstructionLimit` bound it).
- **Path C — the idle point.** A runtime extension's `WaitForIdle` settles
  promises left pending when the run goes idle. Good for fire-and-forget
  promises, not for a mid-script `await`.

**Recommendation:** Path A for approval-gated tool calls. It gives the async
signature the design wants, needs no engine change, and keeps the approval wait
on the same thread the direct tool call already blocks on. Record Path B as the
future upgrade (true overlap), gated on an upstream seam.

## Sources

- `deps/goccia/source/units/` — `Goccia.Values.PromiseValue.pas`,
  `Goccia.MicrotaskQueue.pas`, `Goccia.Values.Await.pas`,
  `Goccia.Values.AsyncFunctionValue.pas`, `Goccia.Timers.pas`,
  `Goccia.FetchManager.pas`, `Goccia.RuntimeExtensions.Fetch.pas`,
  `Goccia.Runtime.pas`, `Goccia.Engine.pas`, `Goccia.AsyncContext.pas`.
- `deps/goccia/docs/` — `interpreter.md` (§Synchronous Microtask Queue),
  `embedding.md` (§Microtask Queue), `errors.md` (unhandled rejections).
- ADRs: 0113 (virtual timer queue), 0123 (per-execution microtask scopes),
  0125 (unhandled-rejection hook).
