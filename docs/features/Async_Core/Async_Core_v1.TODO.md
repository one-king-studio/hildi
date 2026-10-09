# Async Core v1 — TODO

Implement [`Async_Core_v1.SPEC.md`](Async_Core_v1.SPEC.md) TDD-first: a test
expresses the next requirement, watch it fail, implement the minimum, refactor,
`make check` before moving on. Mark tasks done as you go; rename this file to
`Async_Core_v1.DONE.md` when the parity sweep passes.

## Phase 0 — Build and test skeleton

- [ ] **Build**: add the `src/async/` tree and a build target that compiles the
      library and its tests **standalone** (no harness units in the closure).
- [ ] **Test**: a runner for the async suites, wired into `make test` / `make check`.
- [ ] **Test**: isolation — walk the library's transitive `uses` closure and assert
      it contains no `hildegard.helper.*` unit.

## Phase 1 — Core types and the queue/asap scheduler

- [ ] **Test**: the queue trampoline runs work FIFO and is re-entrant-safe (work
      scheduled during a drain runs in the same drain, after the current item).
- [ ] **Implement**: `async.base` — `TUnit`, `ISubscription`,
      `ICancellationToken`, `IObserver<T>`, `ISubscribable<T>`, delegates.
- [ ] **Test**: asap is FIFO with a head index; a nested drain does not re-run the
      in-flight job.
- [ ] **Implement**: `async.scheduler` queue + asap.

## Phase 2 — Context

- [ ] **Test**: a value set before a deferred boundary is visible inside its
      continuation and not outside it; nested scopes restore.
- [ ] **Test**: an unbalanced leave cannot unwind past an enclosing frame.
- [ ] **Implement**: `async.context` — immutable snapshots, save stack, depth token.

## Phase 3 — Virtual clock and the async scheduler

- [ ] **Test**: `Advance` fires due timers in order and drains microtasks between
      them; no wall time passes.
- [ ] **Test**: a self-rescheduling timer hits the loop guard (typed error).
- [ ] **Implement**: virtual + async schedulers and timer sources.

## Phase 4 — Future

- [ ] **Test**: resolve/reject once; `Then`/`Catch`/`Finally` ordering; an
      unhandled rejection is tracked.
- [ ] **Implement**: `TFuture<T>`.
- [ ] **Test**: `All`, `AllSettled`, `Race`, `Any`.
- [ ] **Implement**: the combinators.
- [ ] **Test**: `Await` drives to settlement; `Await(token)` interrupts; an
      unsettleable future raises the typed "unsettled" error.

## Phase 5 — Observable and subjects

- [ ] **Test**: lazy subscribe; unsubscribe tears down downstream and upstream;
      terminal is once; late `OnNext` is ignored.
- [ ] **Implement**: `TObservable<T>`.
- [ ] **Test**: `Subject`, `BehaviorSubject`, `ReplaySubject`, `AsyncSubject`.
- [ ] **Implement**: `async.subject`.

## Phase 6 — Operators: creation, transformation, filtering

- [ ] **Test**: the operator test-contract helper (source of known values on the
      virtual clock → expected notification sequence + teardown expectation).
- [ ] **Test + Implement**: creation — `Of`, `From`, `Range`, `Defer`, `Empty`,
      `ThrowError`, `Iif`, `Timer`, `Interval`, `Generate`, `Using`, `FromEvent`.
- [ ] **Test + Implement**: transformation — `Map`, `Scan`, `Pairwise`, `Buffer`,
      `BufferCount`, `BufferTime`.
- [ ] **Test + Implement**: filtering — `Filter`, `Distinct`, `DistinctUntilChanged`,
      `DistinctUntilKeyChanged`, `First`, `Last`, `Single`, `ElementAt`, `Skip`,
      `SkipLast`, `SkipUntil`, `SkipWhile`, `Take`, `TakeLast`, `TakeUntil`,
      `TakeWhile`, `IgnoreElements`, `Debounce`, `DebounceTime`, `Throttle`,
      `ThrottleTime`, `Audit`, `AuditTime`, `Sample`, `SampleTime`.

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
