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

- [ ] **Test**: a value set before a deferred boundary is visible inside its
      continuation and not outside it; nested scopes restore.
- [ ] **Test**: an unbalanced leave cannot unwind past an enclosing frame.
- [ ] **Implement**: `async.context` — immutable snapshots, save stack, depth token.

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
- [ ] **Implement**: `Finally`.
- [ ] **Test + Implement**: `All`, `AllSettled`, `Race`, `Any`.
- [ ] **Test**: `Await(token)` interrupts.
- [ ] **Implement**: unhandled-rejection tracking.

## Phase 5 — Observable and subjects

- [x] **Test**: lazy subscribe; unsubscribe tears down downstream and upstream;
      terminal is once; late `OnNext` is ignored.
- [x] **Implement**: `TObservable<T>`.
- [x] **Test**: `Subject`, `BehaviorSubject`, `ReplaySubject`, `AsyncSubject`.
- [x] **Implement**: `async.subject`.

## Phase 6 — Operators: creation, transformation, filtering

**FPC 3.3.1 generics constrain the surface** (all verified by compile probe). The
compiler cannot build the idiomatic implementation:
- A free generic function is an internal compiler error.
- A generic method inside a generic class is rejected ("generic inside another
  generic"), and a method on a two-parameter generic class is also an ICE.
- A generic method whose body builds an anonymous function capturing its type
  parameter is an ICE, and so is one returning a concrete type (e.g.
  `ISubscribable<Integer>`).

The one shape that compiles is: **concrete observer and concrete observable
CLASSES, and a generic METHOD on a single non-generic class (`TStreamOps`) that
only constructs them (no closure)**. Call sites compose 1:1 with the pipeline
(`TStreamOps.Map<A,B>(src, f)`, `TStreamOps.Filter<A>(src, p)`).

Still blocked (generic-inside-generic is forbidden): operators returning
`ISubscribable<TArray<T>>` / `ISubscribable<ISubscribable<...>>` — `Buffer`,
`Window`, `GroupBy`, `Partition`, `Pairwise`, and the flattening family.

- [x] **Implement**: the operator pattern (concrete observer + observable per
      operator; `TStreamOps` generic methods).
- [x] **Test**: creation — `Just`, `FromArray`, `Range`, `Empty`, `ThrowError`,
      `Defer`.
- [x] **Test + Implement**: transformation — `Map`, `Scan`.
- [x] **Test + Implement**: filtering — `Filter`, `Take`, `Skip`, `TakeWhile`,
      `SkipWhile`, `DistinctUntilChanged`, `First`, `ElementAt`.
- [x] **Test**: composability (`Map` → `Filter`), laziness.
- [ ] **Deferred** (see the constraint above): `Buffer`, `Window`, `GroupBy`,
      `Partition`, `Pairwise`, the flattening family, `Count`, and the
      cross-type combinators. Record them for a future non-nesting
      representation.
- [ ] **Deferred**: the time-based operators (`DebounceTime`, `ThrottleTime`,
      `SampleTime`, `AuditTime`, `Delay`, `Timeout`, `Timer`, `Interval`) — they
      need the virtual clock wired into the operator set.

## Phase 7 — Flattening and combination

- [ ] **Test + Implement**: flattening — `MergeMap`, `ConcatMap`, `SwitchMap`,
      `ExhaustMap`, `MergeAll`, `ConcatAll`, `SwitchAll`, `Expand`, `GroupBy`,
      `Partition`, `Window`, `WindowCount`, `WindowTime`, `CombineLatestAll`.
- [ ] **Test + Implement**: combination — `Merge`, `Concat`, `CombineLatest`,
      `Zip`, `ForkJoin`, `Race`, `StartWith`, `WithLatestFrom`.

## Phase 8 — Error handling, multicasting, utility

- [ ] **Test + Implement**: error — `CatchError`, `Retry`, `RetryWhen`, `Repeat`,
      `RepeatWhen`, `OnErrorResumeNext`, `ThrowIfEmpty`, `Finalize`.
- [ ] **Test + Implement**: multicasting — `Multicast`, `Publish`, `PublishReplay`,
      `PublishLast`, `PublishBehavior`, `Share`, `ShareReplay`, `RefCount`,
      `Connect`.
- [ ] **Test + Implement**: utility / aggregation — `Tap`, `Delay`, `DelayWhen`,
      `Timeout`, `TimeoutWith`, `Materialize`, `Dematerialize`, `ToArray`, `Reduce`,
      `Count`, `Max`, `Min`, `Every`, `Find`, `FindIndex`, `IsEmpty`,
      `DefaultIfEmpty`, `SequenceEqual`, `EndWith`.

## Phase 9 — Concurrency

- [ ] **Test**: the executor runs work on a pool thread; `Schedule`/`Unsubscribe`
      cancels; every thread is joined on shutdown.
- [ ] **Implement**: `TExecutorScheduler` (bounded pool, token into the worker).
- [ ] **Test**: `SubscribeOn` moves the work; `ObserveOn` moves the notifications;
      `RunOn` fires and forgets.
- [ ] **Implement**: `RunOn`, `SubscribeOn`, `ObserveOn`.

## Phase 10 — Parity sweep and docs

- [ ] **Test**: walk the SPEC's operator list and assert every operator has a test.
- [ ] **Check**: `make check` green (functional suite + leak gate).
- [ ] **Docs**: an example each of a CLI `Await`, a UI `ObserveOn` side effect, and
      a virtual-clock operator test.
- [ ] Rename this file to `Async_Core_v1.DONE.md`.
