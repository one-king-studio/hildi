# Async Core

## Overview

A standalone, dependency-free Object Pascal library for **async and reactive**
programming: **futures** (one asynchronous value) and **observables** (a stream
of values) over **one shared spine** — a scheduler, a continuation-scoped
context, and cancellation.

The design is taken from GocciaScript's async machinery (MIT; see
`docs/research/pascal-async-await.md` and `docs/research/gocciascript-async.md`)
and reimplemented with **no dependency on the harness or any JS engine**, so it
can be extracted to its own repository and used by any FPC program.

## Problem Statement

Object Pascal has no first-class way to write async or event-driven code. The
options are all bad in a different way:

- **Threads + synchronisation** (`TThread`, `TEvent`, `Synchronize`): correct but
  heavy; ordering and error propagation are manual; cancellation leaks unless
  every worker is torn down by hand.
- **A source/state-machine transform** (Delphi's `AsyncAwait`): a build-time
  transform that is opaque in a debugger and hostile to FPC.
- **An event loop**: a reactor you must run and own, which infects every caller.

And none of them give **streams** — many values over time, cancellable,
composable — which is what UI events, sockets, and pipelines actually are.

What is missing is a small library that (a) makes a single async value ergonomic,
(b) makes a stream of values first-class, and (c) runs both on the same
substrate so ordering, context, and teardown are defined once.

## Decision

1. **One spine, two fronts.** A scheduler (ordered delivery), a
   continuation-scoped context, and cancellation. `TFuture<T>` and
   `TObservable<T>` both sit on it; neither owns its own delivery or teardown.
2. **A scheduler, not an event loop.** Work is deferred into an ordered queue and
   drained to quiescence; a synchronous consumer drives it
   (`Future.Await` / `Observable.WaitForCompletion`). There is no reactor loop to
   run — the GocciaScript model. A real-time source is a scheduler implementation,
   not a global loop.
3. **A promise is a stream of one value.** Observables are the general case.
   Keep the semantic differences **explicit** rather than aliasing them away:
   a future is eager, shared/hot and uncancellable; a cold observable is lazy,
   per-subscriber and cancellable.
4. **Full RxJS operator parity is the target surface.** The delivery is phased
   (see *The surface*), but the feature is not "a subset and we'll see" — the
   parity list is the acceptance bar.
5. **Standalone.** FPC RTL only (plus `cthreads`/`cwstring` where a program
   needs them); `{$mode delphi}`; no harness or engine units; buildable and
   testable on its own.
6. **Concurrency is a scheduler choice, not a program mode.** A thread-backed
   **executor** scheduler runs work off the calling thread; a **queue** scheduler
   runs it on a chosen thread (the UI's mailbox). `RunOn` plus
   `SubscribeOn`/`ObserveOn` are the whole concurrency API — no `async` coloring,
   no runtime to start, and no locks if state stays thread-confined.

## Goals

- A `TFuture<T>`: one async value, `Then`/`Catch`/`Finally`, and the combinators
  (`All`, `AllSettled`, `Race`, `Any`).
- A `TObservable<T>`: zero-or-more values with `OnNext`/`OnError`/`OnComplete`,
  `Subscribe`/`Unsubscribe`, and the full operator set.
- **Subjects** for multicast: `Subject`, `BehaviorSubject`, `ReplaySubject`,
  `AsyncSubject`.
- **Schedulers**: a queue (trampoline), an `asap` (microtask), an `async` (timer),
  a **virtual/test** scheduler, and an **executor** (bounded thread pool).
- **Continuation-scoped context** (`AsyncLocalStorage`-like): values that travel
  with the continuation, correct across deferred boundaries.
- **Cancellation** as a token threaded into sources, so unsubscribing stops work.
- **Determinism**: a virtual clock so every time operator is testable without
  sleeps.
- **No external dependencies**; a small, readable codebase that doubles as the
  reference for the model.

## User Stories

- As an **application author**, I want `Future.Await` in a synchronous program so
  I can consume an async API without restructuring into callbacks.
- As a **UI author**, I want an observable of events with `DebounceTime` and
  `SwitchMap`, so a keystroke cancels the previous search.
- As a **library author**, I want to return a `TFuture<T>` from an async API and
  let the caller choose to `await` it or stream it.
- As a **pipeline author**, I want `MergeMap`/`ConcatMap`/`SwitchMap` so an inner
  future or observable flattens into the outer stream.
- As a **tester**, I want a virtual clock so `Interval`/`DebounceTime`/`Timeout`
  are deterministic and instant.
- As a **reviewer**, I want the unhandled-failure and cancellation rules stated
  once, on the spine, not re-derived per operator.

## Acceptance Criteria

### Functional Requirements

- [ ] `TFuture<T>`: `Resolve`/`Reject`, `Then`/`Catch`/`Finally`, `Await` (drive
      to completion), and `All`/`AllSettled`/`Race`/`Any`.
- [ ] `TObservable<T>`: `Subscribe` returns a subscription; `OnNext`/`OnError`/
      `OnComplete`; `Unsubscribe` cancels downstream **and** upstream.
- [ ] Subjects: `Subject`, `BehaviorSubject`, `ReplaySubject`, `AsyncSubject`,
      with the standard multicast semantics.
- [ ] Schedulers: `Queue` (synchronous trampoline), `Asap` (microtask), `Async`
      (timer), `Virtual` (test). Delivery order and re-entrancy are defined.
- [ ] The **full operator surface** (see *The surface*) is implemented and tested,
      including the flattening operators (`MergeMap`, `ConcatMap`, `SwitchMap`,
      `ExhaustMap`) and the bridges (`From(future)`, `FirstValueFrom`,
      `LastValueFrom`, `ForkJoin`).
- [ ] Continuation-scoped context: a value set before a deferred boundary is
      visible inside its continuation and not outside it; nested scopes restore.
- [ ] Cancellation: unsubscribing a subscription backed by a timer or a source
      stops that work; a cancelled future rejects with a cancellation error; the
      token reaches an executor worker so a task can be stopped.
- [ ] An **executor scheduler** backed by a bounded thread pool, with `RunOn` and
      `SubscribeOn`/`ObserveOn` moving work between it and a queue scheduler.
- [ ] A UI (or any) thread never calls `Await`; it subscribes and drains its
      queue. State is thread-confined: workers post mutations to the owning
      thread's scheduler, and the library offers no implicit shared state.
- [ ] Unhandled failures are tracked and reported at the driver's idle point
      (oldest first), with a policy (throw/ignore) and an optional hook.
- [ ] `Await`/`WaitForCompletion` on a stream that never completes is
      interruptible by a cancellation token; a future that nothing will settle
      raises a typed "unsettled" error rather than hanging.

### Non-Functional Requirements

- [ ] **No external dependencies**; FPC 3.3.1, `{$mode delphi}`, no harness or
      engine units in the `uses` closure (asserted by a test).
- [ ] Portability: macOS and Linux, arm64 and x86-64.
- [ ] Deterministic: every time operator is testable on the virtual clock with no
      real waiting.
- [ ] Leak-clean under `heaptrc`; every subscription, source and thread is freed.
- [ ] Thread-safety is stated per type: the scheduler and subjects are safe to use
      from the thread that owns them; cross-thread delivery goes through a
      scheduler, never a bare shared queue.
- [ ] The library builds and its tests run **without the harness**, so it can be
      extracted.

## The surface (full RxJS parity)

The target is the RxJS operator set, grouped. The SPEC enumerates the exact list;
this is the acceptance bar.

- **Creation** — `Of`, `From`, `FromEvent`, `Interval`, `Timer`, `Range`, `Defer`,
  `Empty`, `ThrowError`, `Generate`, `Iif`, `Using`.
- **Transformation** — `Map`, `Scan`, `Pairwise`, `Buffer`, `BufferCount`,
  `BufferTime`, `ConcatMap`, `MergeMap`, `SwitchMap`, `ExhaustMap`, `Expand`,
  `GroupBy`, `Partition`, `Window`, `WindowCount`, `WindowTime`.
- **Filtering** — `Filter`, `Distinct`, `DistinctUntilChanged`,
  `DistinctUntilKeyChanged`, `Debounce`, `DebounceTime`, `Throttle`,
  `ThrottleTime`, `Audit`, `AuditTime`, `Sample`, `SampleTime`, `First`, `Last`,
  `Single`, `ElementAt`, `Skip`, `SkipLast`, `SkipUntil`, `SkipWhile`, `Take`,
  `TakeLast`, `TakeUntil`, `TakeWhile`, `IgnoreElements`.
- **Combination** — `CombineLatest`, `Concat`, `ForkJoin`, `Merge`, `Race`,
  `Zip`, `StartWith`, `WithLatestFrom`, `MergeAll`, `ConcatAll`, `SwitchAll`,
  `CombineLatestAll`.
- **Error handling** — `CatchError`, `Retry`, `RetryWhen`, `Repeat`,
  `RepeatWhen`, `OnErrorResumeNext`, `ThrowIfEmpty`, `Finalize`.
- **Multicasting** — `Multicast`, `Publish`, `PublishReplay`, `PublishLast`,
  `PublishBehavior`, `Share`, `ShareReplay`, `RefCount`, `Connect`.
- **Utility / aggregation** — `Tap`, `Delay`, `DelayWhen`, `Timeout`,
  `TimeoutWith`, `ObserveOn`, `SubscribeOn`, `Materialize`, `Dematerialize`,
  `ToArray`, `Reduce`, `Count`, `Max`, `Min`, `Every`, `Find`, `FindIndex`,
  `IsEmpty`, `DefaultIfEmpty`, `SequenceEqual`, `EndWith`.

## Architecture

```
                    ┌───────────────────────────────────────────────┐
   spine ─────────► │  scheduler · context · cancellation · failure  │
                    └───────────────┬───────────────┬───────────────┘
                         TFuture<T>            TObservable<T>
                      (1 value, eager,        (N values, lazy,
                       shared, hot)            cancellable, cold)
```

- **Core** — `IObserver<T>` (`OnNext`/`OnError`/`OnComplete`),
  `ISubscribable<T>` (subscribe → `ISubscription`), `ISubscription`
  (`Unsubscribe`/`Closed`), `ICancellationToken`.
- **Scheduler** — `IAsyncScheduler.Schedule(work, delay)`; implementations:
  queue (trampoline), asap (microtask, FIFO with a head index), async (timer),
  virtual (test clock), and **executor** (bounded thread pool). The one place the
  GocciaScript queue shape is reused — scopes and O(1) head index included.
- **Context** — immutable snapshots, a save stack, a depth token; installed while
  a job runs and restored after.
- **Fronts** — `TFuture<T>` (a one-emission contract, eager/shared/uncancellable)
  and `TObservable<T>` (zero-or-more, lazy/cold/cancellable); `Subject` for
  multicast. Bridges: `From`, `FirstValueFrom`, `LastValueFrom`, `ForkJoin`.
- **Driver** — a synchronous "run to completion" that drains the scheduler and
  pumps the registered sources, plus an optional real-time scheduler for I/O.
- **Sources** — pluggable continuation pumps (timers, host I/O) register with the
  driver, exactly as `fetch`/`Atomics`/timers do in GocciaScript.

## Concurrency model

Concurrency is **which scheduler runs the work**, not a program-wide mode. There
is no `async` coloring and no runtime to start; a program is synchronous until it
names a scheduler.

Two schedulers carry it:

- **Executor** (bounded thread pool) — "run this on another thread".
  Calculations, blocking I/O, anything the UI must not do.
- **Queue** — "run this on *this* thread's mailbox" (the UI thread's). Everything
  that touches UI-owned state or renders.

One primitive moves work between them: `RunOn(scheduler, work)`. Fire-and-forget
is `RunOn(Pool, …)`; a side effect on the UI is `RunOn(Ui, …)`.

`SubscribeOn` and `ObserveOn` are the stream-shaped form — *where the work runs*
vs *where the notifications land*:

```pascal
source
  .SubscribeOn(Pool)     // the work happens off the UI thread
  .ObserveOn(Ui)         // the effects are delivered on the UI thread
  .Subscribe(onNext);    // the mutation runs on the UI thread
```

**The UI never awaits.** `Await` is for headless/CLI/batch code that wants to
block. A UI thread subscribes and drains its queue per frame; calling `Await` on
it freezes it — the bug this model exists to prevent.

**State is thread-confined, not shared.** The owning thread owns the state;
workers post mutations to it. No locks, one writer. The reactive form is a
`BehaviorSubject<UiState>`: workers push new states on the UI scheduler and the UI
renders each. Sharing mutable state across threads directly is possible, but the
library does not default to it.

**Rules:**

- Bound the pool — a thread per task exhausts the process; reuse the harness's
  bounded pool when in-repo.
- Cancellation must reach the worker, or teardown hangs; thread the token in.
- Posting must **wake** the target loop, or the side effect waits for the next
  input event.
- Join every thread on teardown (`make test-leak` enforces it).
- No `TSemaphore` on macOS — `TCriticalSection` + `TSimpleEvent`.
- Never touch a widget off the UI thread; rendering goes through the UI scheduler.

## Strategy

The library is foundational, so it is built early — but architecture earns its
keep by being *used*, so each step is proven by a real consumer before the next:

1. **Core, single-threaded** — a scheduler (queue/asap), a bounded subject, a
   future, a cancellation token, and a virtual clock. Tested standalone.
2. **First vertical: the TUI drain** ([`TUI_Event_Graph`](../TUI_Event_Graph/FEATURE.md)
   v1) — the core under real load, fixing the unbounded-drain freeze. **This is
   the proof.**
3. **Observables and `Scan`** — the TUI's state-as-a-stream (v2).
4. **The executor** — when a consumer needs work off the calling thread (the
   Remote Agent Link, or parallel tools); it then subsumes the hand-rolled
   `TAgentPool`.
5. **The operator surface** — the long tail, added as consumers need it. Full
   parity is the target, not the entry price.

**Extractability is the point.** The library must stay dependency-free (no harness
or engine units; asserted by a test) so it can be lifted into the other apps.

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`; `cthreads` first in any program that uses threads;
  `cwstring` where non-ASCII text crosses the boundary.
- No `TSemaphore` on macOS — `TCriticalSection` + `TSimpleEvent`, as the harness
  already does.
- No dependency on `hildegard.helper.*` or any engine unit; the library must
  build standalone.
- The virtual clock is the only time source in tests; no `Sleep` in the suite.

### Business / Time

- No deadline. **Foundational, started early**: the library is the architecture
  for concurrency here and the base for other Pascal apps, so it is built
  up-front rather than after the critical path. Its progress is gated by a real
  consumer at each step (see *Strategy*).

## Dependencies

### Internal

- None. The library is self-contained; the harness may *consume* it later, but it
  must not depend on the harness.

### External

- None beyond the FPC RTL/FCL.

## Risks

- **Scope.** Full RxJS parity is ~100 operators; it is a large surface for one
  feature. Mitigation: the spine and the operator contract land first, then the
  operator set in phases; the SPEC enumerates and the TODO sequences.
- **No async/await syntax.** Pascal functions cannot suspend mid-body, so "async"
  is explicit continuations and the blocking boundary is `Await`. Mitigation:
  state it plainly; do not promise a transform.
- **Backpressure.** The model is push; a fast producer outruns a slow consumer.
  Mitigation: out of scope for v1; a bounded scheduler queue plus a pull operator
  is the noted upgrade.
- **Re-entrancy and ordering.** Deferred delivery, nested drivers and
  self-rescheduling jobs are where the GocciaScript bugs lived. Mitigation: port
  its rules (advance-before-run, scopes, depth tokens, timer guard) and test them.
- **Cancellation leaks.** A subscription that does not reach its source leaks.
  Mitigation: teardown is a spine responsibility with a leak test.
- **Thread-safety expectations.** Users will assume more than is offered.
  Mitigation: state the per-type contract and keep cross-thread delivery on a
  scheduler.

## Out of Scope

- A compiler transform or `async`/`await` syntax.
- An event-loop thread as the default execution model (an optional real-time
  scheduler only).
- Backpressure / pull-based streams.
- Distributed or process-boundary async (that is the harness's Remote Agent Link).
- Any dependency on the harness, the JS engine, or a network stack.

## Future Considerations

- **An event-loop scheduler** with a worker thread, for real I/O concurrency.
- **A pull/backpressure layer** (`Buffer`/`Window` with a bounded queue).
- **Interop** with the harness's `IApprovalService` and process pool, once the
  library exists.
- **Code generation** for `async`/`await` syntax as a *later, optional* front-end
  over the same spine.

## Notes

- **Origin.** The model is GocciaScript's (MIT): a synchronous microtask queue,
  `await` as a blocking drive loop, continuation-scoped context, a virtual timer
  queue. See `docs/research/pascal-async-await.md` for the reusable pieces, the
  port sketch, and the promise/stream unification; `docs/research/gocciascript-async.md`
  for the engine-level view.
- **Naming.** The feature is *Async Core*; the proposed namespace is `async.*`
  (e.g. `async.scheduler`, `async.future`, `async.observable`,
  `async.operators.*`). Both are provisional and cheap to change before the SPEC.
- **A promise is a stream of one** — the sentence the whole architecture rests
  on. Keep the two fronts distinct anyway (eager/lazy, hot/cold, cancellable) and
  bridge them explicitly.
- **Reuse note (Ponytail).** The engine is the prior art, not a dependency: this
  is a re-implementation against the FPC RTL, not a vendoring.
