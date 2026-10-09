# Pascal Async & Reactive Streams (research)

What a general Pascal program can take from GocciaScript's async machinery, and
how promises and RxJS-style streams fit together on top of it. This is *outside*
the Composed Tool Sandbox — for the VM-facing view (async tool calls) see
[`gocciascript-async.md`](gocciascript-async.md).

## Why GocciaScript is a useful reference

- **MIT** — the code is liftable, unlike the GPL/Windows `TVersions` prior art.
- It implements the **whole async stack in Object Pascal**: promises, a microtask
  queue, `async`/`await`, continuation-scoped context, cancellation, and a virtual
  timer queue — tested against test262 and Vitest.
- Its central decision is unusual and worth copying: **there is no event loop.**
  `await` blocks the awaiting frame and *drives* a set of registered continuation
  sources to settlement.

## The transferable model

1. **A scheduler, not an event loop.** Work is deferred into an ordered queue
   (`Goccia.MicrotaskQueue`) and drained to quiescence. There is no `while true`
   reactor; the consumer's own call *is* the driver. A synchronous program can
   therefore consume async APIs without a transform.
2. **Pluggable continuation sources.** The driver is generic over "pumps" —
   microtasks, `fetch`, `Atomics.waitAsync`, virtual timers. The host registers
   more. Generalises to *any* async source: sockets, subprocesses, approval
   prompts.
3. **Continuation-scoped context** (`Goccia.AsyncContext`). The context snapshot
   travels **with the continuation** (recorded when a reaction is registered,
   installed while the job runs, restored after), not on the thread. This is
   Node's `AsyncLocalStorage`, and it is correct across deferred boundaries and
   nested drivers. Gold for logging, tracing, and transactions.
4. **Per-run scopes** (`EnterScope`/`LeaveScope`). A nested run neither executes
   nor discards the outer run's jobs. Structured-concurrency-lite for "a library
   runs its own async internally".
5. **Virtual time** (`Goccia.Timers`). Timers live on a virtual clock and run
   only when the driver advances it; no wall time passes. Async code becomes
   unit-testable without sleeps.
6. **Cancellation as a token.** `AbortSignal`/`AbortController` flow into the
   sources, so a cancel actually stops work rather than orphaning it.
7. **Unhandled-failure tracking + a hook.** Rejected futures with no handler are
   tracked and reported at the idle point, oldest first, with an opt-in hook and
   a `throw`/`ignore` policy.

## The gotchas — the real gold

Things you would otherwise rediscover by crashing:

- **Root the saved context stack.** A displaced snapshot held in a bare Pascal
  local was collected mid-call → dangling pointer. Use a refcounted/interfaced
  snapshot, or an explicit root.
- **The enter-token is the stack *depth*, not a pop count**, so an unbalanced
  leave cannot unwind past an enclosing frame.
- **Drain with a head index, advanced *before* running a job.** A nested drain
  (an `await` inside a handler) then sees only remaining/new jobs instead of
  re-running the in-flight one — that re-run was a stack overflow.
- **Thenable adoption is a deliberate two-tick deferral** (a resolve job, then
  the reaction job).
- **Guard self-rescheduling timers** (a `setInterval(0)` hangs; abort with a
  diagnosis).
- **Track rejections in a dictionary** so "now handled" is O(1) with thousands
  pending.

## A minimal port

The engine-specific parts (JS values, GC roots) become interfaces; the shapes
stay.

```pascal
IAsyncScheduler = interface
  { Delay 0 = microtask (FIFO, same turn); > 0 = timer. }
  function Schedule(const AWork: TProc; const ADelayMs: Integer = 0): ISubscription;
end;

IContextScope = interface   { an immutable snapshot; Enter/Leave brackets a job }
ISubscription = interface   { procedure Unsubscribe; function Closed: Boolean; end;

TFuture<T> = class      { single value: fulfilled | rejected, eager, shared }
TObservable<T> = class  { zero-or-more values: Next* then Complete | Error, lazy, cancellable }
```

Sources: `TMicrotaskScheduler` (delay 0), `TVirtualTimerScheduler` (delay > 0),
`TRealTimerScheduler` (wall clock), and host pumps for I/O. A synchronous
consumer blocks via `Future.Await` / `Observable.WaitForCompletion`, which drives
the scheduler exactly like `AwaitValue` does.

## Promises and streams: one spine, two fronts

**A promise is a stream of exactly one value.** Both are "continuations delivered
by a scheduler". That is the whole unification: share the spine, keep two fronts.

```
                 ┌─────────────────────────────────────────┐
                 │  spine: scheduler · cancellation · context │
                 └───────────────┬─────────────┬────────────┘
                        TFuture<T>        TObservable<T>
                     (1 value, eager,    (N values, lazy,
                      shared, hot)        cancellable, cold)
```

### The differences you must *preserve*, not paper over

| | `TFuture<T>` (promise) | `TObservable<T>` (stream) |
| --- | --- | --- |
| Cardinality | exactly one | zero-or-more |
| Eagerness | eager (runs at creation) | lazy (runs on subscribe) |
| Multiplicity | shared, hot | per-subscriber, cold |
| Termination | fulfilled/rejected | `Complete` / `Error` |
| Cancellation | by convention none | `Unsubscribe` |
| Backpressure | n/a | push (needs an operator) |

Naively aliasing one to the other changes semantics (`shareReplay`/`Subject` in
RxJS is exactly that patch). Keep them distinct types over one core.

### The bridges

- `From(future) → Observable<T>` — emit once, complete.
- `FirstValueFrom` / `LastValueFrom(observable) → Future<T>`.
- `ForkJoin(observables) → Future<TArray>` — this *is* `Promise.all`.
- `Race(observables) → Future<T>` — `Promise.race`; `Any` — `Promise.any`.
- `ToObservable(subject) → hot stream`.

### Where they meet: the flattening operators

The operators that take a function returning a future *or* an observable are
where `await` and streams compose — the heart of "putting the two together":

- **`ConcatMap`** — one at a time, in order. This is `await` in a loop.
- **`SwitchMap`** — cancel the previous inner when a new value arrives. The
  killer feature promises cannot express; it is "debounced async".
- **`MergeMap`** — run all inner concurrently.
- **`ExhaustMap`** — ignore new values while one is in flight.

Time-based operators (`Delay`, `DebounceTime`, `ThrottleTime`, `Interval`,
`Timer`) run on the **virtual clock**, so they are deterministic in tests.

### Subjects (multicast)

`Subject` (hot, no replay), `BehaviorSubject` (current value), `ReplaySubject`
(buffer). A future is essentially a `BehaviorSubject` with one value and a
completion, shared. Subjects are how a push source (a socket, a UI event) enters
the graph.

## Architecture sketch

- **Core:** `ISubscribable<T>` (subscribe → `ISubscription`); `IObserver<T>`
  (`OnNext`/`OnError`/`OnComplete`). `TFuture<T>` and `TObservable<T>` are the
  two fronts; `Subject` is the multicast front.
- **Scheduler interface** with two implementations: the microtask queue
  (`asap`-like, delay 0) and the virtual/real timer queue (`async`-like,
  delay > 0). This is the single place the GocciaScript queue shape is reused —
  including its scopes and its O(1) head index.
- **Cancellation:** an `ICancellationToken` threaded into sources; `Unsubscribe`
  cancels downstream and upstream.
- **Context:** every `OnNext`/reaction runs under the context captured at
  subscription (the continuation-scoped snapshot).
- **Driver:** either (a) a single-threaded "run to completion" driver — the
  GocciaScript pattern, deterministic and test-friendly — or (b) an optional
  event-loop thread for real I/O concurrency. The same operators run under both.
- **Backpressure:** out of scope initially (push model). If needed, a bounded
  scheduler queue plus a pull operator (`Buffer`/`Window`) — noted, not designed.

## What to lift from GocciaScript, concretely

- The **microtask queue shape**: FIFO with a head index, advance-before-run,
  scopes for nesting, a rejection tracker — `Goccia.MicrotaskQueue.pas`.
- The **continuation-scoped context**: immutable snapshots, a collector-marked
  save stack, a depth token — `Goccia.AsyncContext.pas`.
- The **virtual timer algorithm** (ordered queue, due-time arithmetic, loop
  guard) — `Goccia.Timers.pas`.
- The **blocking drive loop** (`await` = drain microtasks, pump each source,
  error if nothing settles) — `Goccia.Values.Await.pas`.
- The **worker + completion-pump pattern** for real I/O — `Goccia.FetchManager.pas`.

None of the *ideas* are new (JS semantics, `AsyncLocalStorage`, sinon's virtual
clock). What is rare is a **worked, tested, MIT Object Pascal implementation** of
the whole stack, plus the decisions above — a credible third path next to
"threads" and "a source transform", and readable instead of rediscoverable.

## Sources

- `deps/goccia/source/units/` — `Goccia.MicrotaskQueue.pas`,
  `Goccia.AsyncContext.pas`, `Goccia.Timers.pas`, `Goccia.Values.Await.pas`,
  `Goccia.Values.PromiseValue.pas`, `Goccia.FetchManager.pas`,
  `Goccia.Builtins.AsyncHooks.pas`.
- `deps/goccia/docs/interpreter.md` (§Synchronous Microtask Queue), ADRs 0113,
  0123, 0125.
- RxJS for the stream vocabulary (`Observable`, `Subject`, schedulers,
  `mergeMap`/`concatMap`/`switchMap`, `forkJoin`) — the design above maps its
  concepts onto the same spine.
