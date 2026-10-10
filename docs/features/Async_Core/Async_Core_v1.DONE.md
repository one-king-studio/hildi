# Async Core v1 — TODO

Implement [`Async_Core_v1.SPEC.md`](Async_Core_v1.SPEC.md) TDD-first: a test
expresses the next requirement, watch it fail, implement the minimum, refactor,
`make check` before moving on. Mark tasks done as you go; rename this file to
`Async_Core_v1.DONE.md` when the parity sweep passes.

## Phase 0 — Build and test skeleton

- [x] **Build**: `src/async/` plus the `make async-standalone` target — it compiles
      the library with only `-Fu$(SRC)/async`, so a harness dependency breaks the
      build. That is the isolation gate (compile-time, stronger than a walk).
- [x] **Test**: the async suites run under `make test` / `make check`.

## Phase 1 — Core types and the queue/asap scheduler

- [x] **Implement**: `async.base` — `TUnit`, `ISubscription`,
      `ICancellationToken`, `IObserver<T>`, `ISubscribable<T>`, delegates.
- [x] **Test**: the queue trampoline runs work FIFO and is re-entrant-safe.
- [x] **Test**: asap is FIFO with a head index; a nested drain does not re-run the
      in-flight job.
- [x] **Implement**: `async.scheduler` queue + asap, with cancellable jobs.
- [x] **Implement**: `async.queue` — `TBoundedQueue<T>`, the thread-safe bounded
      mailbox (drop-oldest on overflow, with a `Dropped` count) the TUI needs.

## Phase 2 — Context

- [x] **Test**: a value set before a deferred boundary is visible inside its
      continuation and not outside it; nested scopes restore.
- [x] **Test**: an unbalanced leave cannot unwind past an enclosing frame.
- [x] **Implement**: `async.context` — immutable snapshots, save stack, depth token.
      The scheduler seam: a job captures `ContextCurrent` at enqueue and the
      scheduler installs it while the job runs, then restores (both
      `async.scheduler` and `async.timers`).

## Phase 3 — Virtual clock and the timer schedulers

- [x] **Implement**: `async.timers` — `TVirtualScheduler` (`Advance`) and
      `TRealScheduler`, on a shared ordered timer queue (entry objects, because
      `TList<T>.Delete` raw-moves a managed element).
- [x] **Test**: `Advance` fires due timers in due order (FIFO for equal due), runs
      timers scheduled while it runs, and moves the clock; a future timer does not
      run on `Drain`; negative delay/advance rejected; unsubscribe cancels.
- [ ] **Implement**: the self-rescheduling-timer loop guard (typed error).

## Phase 4 — Future

- [x] **Implement**: `TFuture<T>` — resolve/reject once, `AndThen`/`Catch`, and
      scheduler-ordered delivery. (`Then` is reserved in Pascal, hence `AndThen`.)
- [x] **Test**: resolve/reject once; callback ordering; settle-once; deferred
      delivery through a scheduler.
- [x] **Test**: `Await` returns the value and raises on a rejected future; a
      pending future with no scheduler raises rather than hanging.
- [x] **Implement**: `OnFinally` (named so because `Finally` is reserved).
- [x] **Implement**: `Run` (eager producer; a raise becomes a rejection).
- [x] **Test + Implement**: `Race`, `Any` (same-type; a `TFutureRacer<T>`
      coordinator). `All`/`AllSettled` are **deferred**: they would return
      `TFuture<TArray<T>>`, the generic-inside-generic wall (the same one that
      blocks `Buffer`/`GroupBy`).
- [x] **Test**: `AwaitToken(token)` interrupts (`EFutureCancelled`).
- [ ] **Deferred**: unhandled-rejection tracking.

## Phase 5 — Observable and subjects

- [x] **Test**: lazy subscribe; unsubscribe tears down downstream and upstream;
      terminal is once; late `OnNext` is ignored.
- [x] **Implement**: `TObservable<T>`.
- [x] **Test**: `Subject`, `BehaviorSubject`, `ReplaySubject`, `AsyncSubject`.
- [x] **Implement**: `async.subject`.

## Phase 6 — Operators: creation, transformation, filtering

**FPC 3.3.1 generics constrain the ENCODING, not the signatures.** See
[FPC_Generics_Notes.md](FPC_Generics_Notes.md) for the full rules, the probes, and
the runtime sharp edges. In brief: the surface is **free functions** (a free
generic function is fine unless its body builds a closure capturing the type
param, or it is forward-declared). The concrete observer + observable classes
remain only as the `Subscribe` machinery. A *type* cannot nest a generic, so
tuple/array-returning operators are re-expressed in projection/combiner form
(their element type stays a type parameter).

Composition is RxJS-style: **curried operator factories** (`FilterOp<Integer>(p)`
returns an `IOperator<Integer>`) and a free **`Pipe<T>(src, AOps)`** that reduces
a source over an array of operators (called once with the whole array).

- [x] **Implement**: the operator pattern (free functions over concrete
      observer + observable classes).
- [x] **Implement**: the composition surface — `IOperator<T>` factories + `Pipe`.
- [x] **Test**: creation — `Just`, `FromArray`, `Range`, `Empty`, `ThrowError`,
      `Defer`.
- [x] **Test + Implement**: transformation — `Map`, `Scan`, `Pairwise`, `Reduce`.
- [x] **Test + Implement**: filtering — `Filter`, `Take`, `Skip`, `TakeWhile`,
      `SkipWhile`, `DistinctUntilChanged`, `First`, `ElementAt`.
- [x] **Test + Implement**: fan-in — `Merge`, `Concat`.
- [x] **Test + Implement**: flattening — `MergeMap`, `SwitchMap`, `ConcatMap`
      (projection form; the result is one level, so no nesting).
- [x] **Test + Implement**: combine — `Zip` (combiner form).
- [x] **Test**: composability (`Map` → `Filter`), laziness, `Pipe`.
- [ ] **Deferred — needs a non-nesting container**: `Buffer`, `BufferCount`,
      `BufferTime`, `ToArray`, `Window`, `WindowCount`, `WindowTime`, `GroupBy`,
      `Partition`, `ForkJoin`, and a true `MergeAll`/`ConcatAll`/`SwitchAll`/
      `CombineLatestAll` over `ISubscribable<ISubscribable<T>>`.
- [x] **Test + Implement**: utility — `Tap`, `IgnoreElements`, `StartWith`,
      `EndWith`, `Distinct`, `Last`.
- [x] **Test + Implement**: aggregation — `Count` (and `Reduce<T,A>` with a
      separate accumulator).
- [x] **Test + Implement**: error — `CatchError`, `Finalize`, `Retry`.
- [x] **Test + Implement**: combine — `Zip`, `CombineLatest` (combiner form).
- [x] **Test + Implement**: fan-in — `Merge`, `Concat`, `Race` (Race is a
      synchronous approximation: the first source wins).
- [x] **Test + Implement**: time-based (unit `async.time`, virtual clock) —
      `Delay`, `DelayWhen`, `DebounceTime`, `ThrottleTime`, `SampleTime`,
      `AuditTime`, `Timeout`, `TimeoutWith`, `Timer`, `Interval`. Each takes an
      explicit `IAsyncScheduler` (a `TVirtualScheduler` in tests). The full time
      set is done.

## Phase 7 — Flattening and combination

The phase overlaps Phase 6 (the flattening and combine cores landed there); this
is the remainder, split by what is actually buildable under FPC 3.3.1.

- [x] **Test + Implement**: flattening — `MergeMap`, `ConcatMap`, `SwitchMap`
      (done under Phase 6), `ExhaustMap` (new: ignores source values while an
      inner is in flight).
- [x] **Test + Implement**: combination — `Merge`, `Concat`, `CombineLatest`,
      `Zip`, `Race`, `StartWith` (done under Phase 6), `WithLatestFrom` (new:
      each left value paired with the latest right).
- [x] **Test + Implement**: `Expand` (new: a bounded breadth-first unfold; the
      element type stays `T`, so it is one level and not blocked).
- [ ] **Blocked — nested generic type**: `MergeAll`, `ConcatAll`, `SwitchAll`,
      `CombineLatestAll`, `GroupBy`, `Partition`, `Window`, `WindowCount`,
      `WindowTime`, `ForkJoin` — each needs a generic inside a generic as a
      *type*, which FPC 3.3.1 forbids (the `Buffer`/`ToArray` wall).
- [ ] **Open — buildable**: `Single` (a `First`-like filter that also errors on a
      second element).

## Phase 8 — Error handling, multicasting, utility

- [x] **Test + Implement**: error — `CatchError`, `Retry`, `RetryWhen`,
      `RepeatCount`, `Finalize`, `ThrowIfEmpty`.
      Remaining: `RepeatWhen`, `OnErrorResumeNext`.
- [x] **Test + Implement**: multicasting — `Multicast`, `Publish`,
      `PublishReplay`, `PublishLast`, `PublishBehavior`, `Share`, `ShareReplay`
      (a `TConnectableObservable<T>` with `Connect`; `Share`/`ShareReplay` are
      ref-counted auto-connect). `ISubject<T>` in `async.subject` is the seam.
      Remaining: an explicit `RefCount`.
- [x] **Test + Implement**: utility / aggregation — `Tap`, `Delay`, `DelayWhen`,
      `Timeout`, `TimeoutWith`, `Reduce`, `Count`, `EndWith`, `Distinct`, `Last`,
      `Every`, `IsEmpty`, `DefaultIfEmpty`, `Materialize`, `Dematerialize`.
      Remaining: `ToArray` (blocked by generic-inside-generic), `Max`, `Min`,
      `Find`, `FindIndex`, `SequenceEqual`.

## Phase 9 — Concurrency

- [x] **Test**: the executor runs work on a pool thread; every thread is joined
      on shutdown.
- [x] **Implement**: `TExecutorScheduler` (a bounded thread pool; a
      lock-guarded queue + `TSimpleEvent` wake, workers also poll; the job
      captures the context and the token reaches the worker).
- [x] **Test**: `SubscribeOn` moves the work; `ObserveOn` moves the
      notifications; `RunOn` fires and forgets.
- [x] **Implement**: `RunOn`, `SubscribeOn`, `ObserveOn` (unit
      `async.concurrency`).
- [ ] **Deferred**: `Schedule`/`Unsubscribe` cancelling a *running* job (the
      subscription cancels a job that has not started; cooperative cancellation
      of an in-flight worker is a follow-up).

## Phase 10 — Parity sweep and docs

- [x] **Test**: walk the SPEC's operator list and assert every operator has a test.
      `test_async_parity` enumerates the live registry: every async suite is
      registered, every implemented operator has a named test that exists, and the
      structurally-blocked set is documented. It found `ConcatMap`/`Retry`/`Race`
      and the `PublishReplay`/`PublishLast`/`PublishBehavior`/`ShareReplay` family
      implemented but untested — and, once tested, two real bugs (a `ConcatMap`
      stall and a `ReplaySubject` late-subscriber no-op) plus a `Retry` observer
      reference-cycle leak.
- [x] **Check**: `make check` green — 1182 tests, 0 errors, 0 failures, leak-clean
      (functional suite + `heaptrc` gate); `make async-standalone` still builds.
- [x] **Docs**: `examples/async_examples.pas` (`make async-examples`) — a CLI
      `Await`, a UI `ObserveOn` side effect, and a virtual-clock operator, each run.
- [x] Rename this file to `Async_Core_v1.DONE.md`.
