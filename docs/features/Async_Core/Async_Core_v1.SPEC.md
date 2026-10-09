# Async Core v1 — Specification

Implements [`FEATURE.md`](FEATURE.md). A standalone, dependency-free Object
Pascal async/reactive stack. v1 delivers the **spine** (scheduler, context,
cancellation), the two fronts (`TFuture<T>`, `TObservable<T>`), subjects, the
scheduler family including the **executor**, and the **full RxJS operator
surface** against one operator contract. Nothing here depends on the harness or
any engine.

## Component boundaries

Namespace `async.*` (provisional). The dependency rule is one-way: `base` is
leaf-most; nothing in the library `uses` a `hildegard.helper.*` unit.

| Unit | Owns |
| --- | --- |
| `async.base` | `TUnit`, `ISubscription`, `ICancellationToken`, `IObserver<T>`, `ISubscribable<T>`, delegate types |
| `async.scheduler` | `IAsyncScheduler` and queue / asap / async / virtual / executor |
| `async.context` | the continuation-scoped context |
| `async.future` | `TFuture<T>` |
| `async.observable` | `TObservable<T>` subscribe plumbing (no operators) |
| `async.subject` | `TSubject<T>`, behavior / replay / async subjects |
| `async.operators` | the operators (may split by category later) |
| `async.sources` | timer sources and host pumps |

## Core types

```pascal
type
  TUnit = record end;

  TNotify  = procedure of object;
  TProduce<T>  = function: T of object;
  TTransform<T, U> = function(const AValue: T): U of object;
  TAction<T> = procedure(const AValue: T) of object;
  TFactory<T> = function(const AError: Exception): T of object;

  ISubscription = interface
    procedure Unsubscribe;
    function Closed: Boolean;
  end;

  ICancellationToken = interface
    function IsCancelled: Boolean;
    procedure OnCancel(const AAction: TNotify);
  end;

  IObserver<T> = interface
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  ISubscribable<T> = interface
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  IAsyncScheduler = interface
    function Schedule(const AWork: TNotify; const ADelayMs: Integer = 0): ISubscription;
  end;
```

Delegate types are declared here rather than taken from the RTL so the library
does not depend on FPC's `SysUtils` delegate surface (see *Open questions*).

## Scheduler semantics

`Schedule(work, delay)` returns a subscription; `Unsubscribe` cancels the work if
it has not run. `delay = 0` is "as soon as possible on this scheduler"; `delay > 0`
is a timer.

- **Queue (trampoline)** — runs on the calling thread, FIFO, re-entrant-safe: work
  scheduled *during* a drain runs in the same drain, after the current item.
- **Asap (microtask)** — FIFO with a head index advanced **before** each job runs,
  so a nested drain (an `Await` inside a handler) sees only remaining and newly
  enqueued jobs and never re-runs the in-flight one. Drains to quiescence.
- **Async (timer)** — `delay > 0` on the wall clock; a self-rescheduling job is
  bounded by a loop guard that raises a typed error rather than hanging.
- **Virtual (test)** — a virtual clock; `Advance(ms)` fires due timers in order and
  drains the microtask queue between them. No wall time passes.
- **Executor (bounded pool)** — runs work on a pool thread (see *Concurrency*).

**Ordering.** Within a scheduler, work runs in enqueue order. Across the spine,
microtasks (delay 0) always precede timers (delay > 0) at a given instant — the
macrotask-then-microtask rule, minus the loop.

**Re-entrancy.** `Drain` is re-entrant; nested drains must not re-run a job. This
is the head-index rule and it is a tested invariant, not an implementation detail.

## Context semantics

A continuation-scoped context carries values that must survive a deferred
boundary (logging, tracing, transactions) without leaking between unrelated
continuations.

- The context is an **immutable snapshot**; deriving a binding copies it.
- A snapshot is captured **when a reaction is registered**, travels with the job,
  and is installed while the job runs, then the previous one is restored.
- Enter/leave use a **depth token**, so an unbalanced leave cannot unwind past an
  enclosing frame.
- The current snapshot must be **rooted** for the whole time it is displaced.
- `Await` needs no seam: the drained jobs restore what they found, leaving the
  awaiting frame's own context in place across the await.

## Cancellation semantics

- `ICancellationToken` is threaded into sources and the executor.
- Unsubscribing a subscription cancels downstream and upstream, and stops any
  timer or worker the source owns.
- A cancelled future rejects with a typed cancellation error.
- `Await(token)` and `WaitForCompletion(token)` are interruptible; a future that
  nothing can settle raises a typed **unsettled** error rather than hanging.
- Cancellation is idempotent and safe after completion.

## Future contract

`TFuture<T>` is a one-emission stream: fulfilled **or** rejected, exactly once.

```pascal
TFuture<T> = class
  class function Run(const AWork: TProduce<T>): TFuture<T>; static;
  class function Resolve(const AValue: T): TFuture<T>; static;
  class function Reject(const AError: Exception): TFuture<T>; static;
  function Then(const AOnFulfilled: TTransform<T, T>): TFuture<T>;
  function Catch(const AOnRejected: TFactory<T>): TFuture<T>;
  function Finally(const AAction: TNotify): TFuture<T>;
  function Await: T; overload;
  function Await(const AToken: ICancellationToken): T; overload;
  class function All(const AFutures: array of TFuture<T>): TFuture<TArray<T>>; static;
  class function AllSettled(...): TFuture<...>; static;
  class function Race(const AFutures: array of TFuture<T>): TFuture<T>; static;
  class function Any(const AFutures: array of TFuture<T>): TFuture<T>; static;
end;
```

- **Eager**: `Run` starts immediately (on the current scheduler); `Resolve`/`Reject`
  are already settled.
- **Shared/hot**: one execution, many observers.
- **Uncancellable** by convention; `Await(token)` only stops the *wait*.
- `Then`/`Catch`/`Finally` are sugar over the observable operators, so ordering
  and context are identical.
- `Await` **blocks the calling thread and drives** the spine (drain microtasks →
  pump sources → repeat) until settled or cancelled. It must not be called from a
  thread that the awaited work needs (see *Concurrency*).

## Observable contract

`TObservable<T>` is zero-or-more `OnNext`, then exactly one `OnComplete` **or**
`OnError`.

- **Lazy/cold**: subscribing runs the source; two subscribers run it twice.
- `Subscribe` returns an `ISubscription`; `Unsubscribe` tears down downstream and
  upstream.
- After a terminal notification the subscription is closed; late `OnNext` is
  ignored.
- Errors are delivered as `OnError`, not raised into the producer.
- The observer's calls run on the scheduler in effect (`ObserveOn`).

## Subject semantics

- `TSubject<T>` — multicast, no replay; hot. Late subscribers see only new values.
- `TBehaviorSubject<T>` — holds a current value; a new subscriber gets it first.
- `TReplaySubject<T>` — replays a bounded buffer to new subscribers.
- `TAsyncSubject<T>` — emits only the **last** value, on completion.
- Subjects are the entry point for push sources (sockets, UI events) and for
  thread-confined state (`BehaviorSubject<UiState>`).

## Operator contract

Every operator is a pure function of `ISubscribable<T>` → `ISubscribable<U>`,
implemented as an `ISubscribable<U>` whose `Subscribe` subscribes to the source
with a forwarding observer that applies the operator's rule. Rules:

- Operators never subscribe until their result is subscribed (laziness is
  preserved).
- Teardown propagates: unsubscribing the result unsubscribes the source.
- Terminal state is forwarded once; a `OnComplete` from the source does not become
  an `OnNext`.
- Time-based operators use the **scheduler they are given** (default: the current
  one), never `Sleep`.
- Flattening operators (`MergeMap`/`ConcatMap`/`SwitchMap`/`ExhaustMap`) accept a
  projection returning either a `TFuture<U>` or an `ISubscribable<U>`; a future is
  adapted with `From`.

**Test contract.** Each operator has a table-driven test: a source of known
values on the virtual scheduler, the expected notification sequence, and the
teardown expectation. An operator without a test is not done.

### Operator surface (v1 = full parity)

- **Creation**: `Of`, `From` (value / array / future), `FromEvent`, `Interval`,
  `Timer`, `Range`, `Defer`, `Empty`, `ThrowError`, `Generate`, `Iif`, `Using`.
- **Transformation**: `Map`, `Scan`, `Pairwise`, `Buffer`, `BufferCount`,
  `BufferTime`, `ConcatMap`, `MergeMap`, `SwitchMap`, `ExhaustMap`, `Expand`,
  `GroupBy`, `Partition`, `Window`, `WindowCount`, `WindowTime`.
- **Filtering**: `Filter`, `Distinct`, `DistinctUntilChanged`,
  `DistinctUntilKeyChanged`, `Debounce`, `DebounceTime`, `Throttle`,
  `ThrottleTime`, `Audit`, `AuditTime`, `Sample`, `SampleTime`, `First`, `Last`,
  `Single`, `ElementAt`, `Skip`, `SkipLast`, `SkipUntil`, `SkipWhile`, `Take`,
  `TakeLast`, `TakeUntil`, `TakeWhile`, `IgnoreElements`.
- **Combination**: `CombineLatest`, `Concat`, `ForkJoin`, `Merge`, `Race`, `Zip`,
  `StartWith`, `WithLatestFrom`, `MergeAll`, `ConcatAll`, `SwitchAll`,
  `CombineLatestAll`.
- **Error handling**: `CatchError`, `Retry`, `RetryWhen`, `Repeat`, `RepeatWhen`,
  `OnErrorResumeNext`, `ThrowIfEmpty`, `Finalize`.
- **Multicasting**: `Multicast`, `Publish`, `PublishReplay`, `PublishLast`,
  `PublishBehavior`, `Share`, `ShareReplay`, `RefCount`, `Connect`.
- **Utility / aggregation**: `Tap`, `Delay`, `DelayWhen`, `Timeout`, `TimeoutWith`,
  `ObserveOn`, `SubscribeOn`, `Materialize`, `Dematerialize`, `ToArray`, `Reduce`,
  `Count`, `Max`, `Min`, `Every`, `Find`, `FindIndex`, `IsEmpty`, `DefaultIfEmpty`,
  `SequenceEqual`, `EndWith`.

## Concurrency

Concurrency is **which scheduler runs the work** (see the FEATURE's *Concurrency
model*). v1 provides:

- **`TExecutorScheduler`** — a bounded thread pool. `Schedule` runs the work on a
  pool thread; the returned subscription cancels the task and the token reaches
  the worker. Threads are joined on shutdown.
- **`RunOn(scheduler, work)`** — run `work` on `scheduler`, returning a
  subscription (fire-and-forget when ignored).
- **`SubscribeOn(scheduler)`** — the source's work (its `Subscribe`) runs on
  `scheduler`.
- **`ObserveOn(scheduler)`** — the observer's notifications run on `scheduler`.

Rules: state is thread-confined (the owning thread owns it; workers post mutations
through the owning scheduler); the library offers no implicit shared state;
`Await` is never called on a UI thread; posting wakes the target loop; every
thread is joined on teardown.

## Error model

- An `OnError` with no `CatchError` downstream is an **unhandled failure**. It is
  tracked and reported at the driver's idle point, oldest first, subject to a
  policy (`throw` default / `ignore`) and an optional hook — the
  HostPromiseRejectionTracker shape.
- `Await` re-raises a rejected future's error at the await site.
- Engine-integrity-class faults (out-of-memory, access violations) are not
  converted into stream errors; they propagate.

## Validation and limits

- Non-negative delays; a negative delay is a typed error.
- Re-entrant drains bounded by an instruction/iteration guard that raises a typed
  error rather than hanging.
- A pool is created with a positive bound; zero or negative is a typed error.
- Subscribing after a terminal notification is a no-op returning a closed
  subscription.

## Test plan

- **Unit, no threads**: scheduler ordering and re-entrancy; context install/restore
  across a deferred boundary; future combinators; each operator against the
  operator test contract on the virtual clock.
- **Determinism**: all time-based tests use the virtual scheduler; no `Sleep`.
- **Concurrency**: executor tests use `TSimpleEvent`/`TCriticalSection` (never
  `TSemaphore`); a test asserts every worker thread is joined and every object
  freed.
- **Isolation**: a test asserts the library's transitive `uses` closure contains no
  `hildegard.helper.*` unit.
- **Leak gate**: the whole suite runs under `heaptrc` (`make test-leak`).

## Open questions

- **Delegate types — resolved.** Declare our own generic `reference to` delegates
  (`TAction<T>`, `TMapper<T, U>`, `TProducer<T>`, `TFactory<T>`) in `async.base`.
  FPC supports them, including capture, and they keep the library off `SysUtils`.
- **FPC generic constraints — resolved (measured, FPC 3.3.1):**
  - A **generic method inside a generic class is forbidden** ("Declaration of
    generic inside another generic is not allowed"), so operators are **free
    functions**, not methods — the Rx "pipeable" shape.
  - Nested generic brackets need a **space**: `TList<TAction<T> >`, or `>>` parses
    as a shift.
  - `TList<TAction<T>>` cannot be **specialised** inside a generic class method
    (it reports `TList` not found), though the field type itself is fine — use a
    dynamic array (`TArray<TAction<T> >`) for the callback list.
  - `Then` is a Pascal **reserved word**; the future's method is `AndThen`.
- **Operator units.** One `async.operators` unit will get large; splitting by
  category is expected once the contract is proven.
- **Context backing store.** Interface-keyed dictionary vs. a small association
  list — chosen by measurement once the core is in.
- **`Await` on a pool thread.** Whether the executor may run an `Await` internally
  (a nested driver) is deferred; v1 keeps `Await` for non-UI callers.
