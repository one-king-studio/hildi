# FPC Generics: what works, what ICEs, and why the operators look the way they do

**Audience:** anyone implementing or extending `async.operators` (or any generic
code) on this project's toolchain.

**Toolchain:** Free Pascal 3.3.1, delphi mode, `{$H+}`, macOS arm64. Every claim
here was verified by compiling a standalone probe.

## TL;DR

FPC 3.3.1's support for **generic functions and generic methods is incomplete**,
but the surface we want — **operators as free functions**, composed by a `Pipe`
reducer — **does compile**. The one rule that matters:

> A **free generic function** is fine **as long as its body has no anonymous
> function** and it is **not forward-declared**. (A unit's
> interface/implementation split is a definition, not a forward declaration, so
> normal unit structure is fine.)

The only thing that still needs a class is the **concrete observable + observer**
that `Subscribe` wires up — that is where the per-subscription state (the
accumulator, buffer, counter) lives. The *surface* is pure free functions.

## The rules (all probe-verified)

| Construct | Result |
| --- | --- |
| **Free generic function**, plain body (no closure), not forward-declared | ✅ **works** |
| Free generic function whose body builds an **anonymous function capturing the type param** | **ICE** |
| Free generic function **forward-declared** (`function F<T>(…);` then a body) | **ICE** `200511173` |
| Generic method **inside a generic class** (`TOp<T>.Map<U>`) | **rejected**: "generic inside another generic" |
| Method on a **two-parameter generic class** (`TOp2<T,U>.M`) | **ICE** |
| Generic method **returning a concrete type** (`ISubscribable<Integer>`) | **ICE** |
| Generic method taking an **open array** `array of TFoo<T>` | **rejected**: use `TArray<TFoo<T>>` |
| Nested generic close `>>` | **rejected**: write `> >` with a space |

Two language limits that are not about methods:

- **A generic inside a generic is forbidden as a *type***: `ISubscribable<TArray<T>>`
  and `ISubscribable<ISubscribable<U>>` do not compile. This is the real ceiling
  (see below), and it is why tuple/array-returning operators are re-expressed in
  projection/combiner form.
- **`{$mode delphi}` in a comment is parsed as a directive** — write "delphi
  mode", not the braced form. A backtick in a comment is an illegal character.

### Two traps specific to *anonymous functions*

- Inside a **class method**, an anonymous procedure is a **"class anonymous
  procedure"**, which does **not** match `procedure of object` (`TNotify`). Use a
  `reference to` type instead — that is why `async.base` defines
  `TAction0 = reference to procedure` and `TObserver` uses it.
- A generic function/method whose body *builds* an anonymous function capturing
  the type parameter ICEs. Operators therefore do **not** use closures in the
  surface functions; each rule is a concrete observer class.

### The case-collision trap

FPC is **case-insensitive**: a class `TFilterOp<T>` and a function `FilterOp<T>`
collide. Name the classes distinctly (e.g. `TFilterOperator<T>`).

## How the operators are implemented

Every operator is a **free function** `ISubscribable<T> → ISubscribable<U>`, a
thin wrapper over a small **class pair** (the class pair is where the
per-subscription state lives):

```pascal
// The observable: holds the source + the rule, wires them on Subscribe.
TFilterObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  constructor Create(const ASource: ISubscribable<T>; const APredicate: TPredicate<T>);
  function Subscribe(const AObserver: IObserver<T>): ISubscription;
end;

function TFilterObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TFilterObserver<T>.Create(AObserver, FPredicate));
end;

// The observer: applies the rule to each value.
TFilterObserver<T> = class(TInterfacedObject, IObserver<T>)
  procedure OnNext(const AValue: T);  // if FPredicate(AValue) then FDown.OnNext(AValue)
  procedure OnError(const AError: Exception);   // forward
  procedure OnComplete;                          // forward
end;
```

The **surface is a free generic function** — no class needed:

```pascal
function Filter<T>(const ASource: ISubscribable<T>;
  const APredicate: TPredicate<T>): ISubscribable<T>;
begin
  Result := TFilterObservable<T>.Create(ASource, APredicate);
end;
```

Call sites read 1:1 with the pipeline:

```pascal
Filter<Integer>(src, isEven)
Map<Integer, string>(src, toStr)
```

### The RxJS-style composition surface

Two more free-function layers make pipelines first-class values — the shape RxJS
settled on (pure-function operators, not operator classes):

- **Curried operator factories** — `FilterOp<Integer>(pred)` takes the
  *configuration* and returns an `IOperator<Integer>` (a partial application;
  `IOperator<T>.Apply(source)` runs it). This is the RxJS
  `filter(predicate) → OperatorFunction` pattern.
- **`Pipe`** — one free function that reduces a source over an **array** of
  operators:

```pascal
S := Pipe<Integer>(Range(1, 10), [
  FilterOp<Integer>(isEven),
  TakeOp<Integer>(3)]);            // => 2,4,6
```

`Pipe` is called **once** with the whole array — **not** once per operator. The
array is a plain value you can build, store, and reuse.

## The nesting workaround: projection and combiner forms

Operators that would return a *nested generic* (a tuple or an array) are instead
expressed so the **element type stays a type parameter**:

| Wanted | Blocked form | Working form |
| --- | --- | --- |
| `Pairwise` | `ISubscribable<TPair<T>>` | `Pairwise<T,U>(src, pair: (T,T)→U): ISubscribable<U>` |
| `Zip` | `ISubscribable<TPair<T,U>>` | `Zip<T,U,V>(a, b, combine: (T,U)→V): ISubscribable<V>` |
| `Reduce` | `ISubscribable<A>` with `TAcc<T>` | `Reduce<T,A>(src, seed: A, reducer: (A,T)→A): ISubscribable<A>` |
| `Buffer`/`ToArray` | `ISubscribable<TArray<T>>` | **not yet expressible** — needs a non-nesting container |
| `MergeAll` | `ISubscribable<ISubscribable<T>>` | use `MergeMap<T,U>(src, project: T→ISubscribable<U>)` instead |

**Flattening is NOT nesting in the type.** `MergeMap`/`SwitchMap`/`ConcatMap`
have the signature `ISubscribable<T> × (T→ISubscribable<U>) → ISubscribable<U>`
— the result is **one level**, identical in shape to `Map`. The inner stream is
only the *projection's return type*; the nesting is a **runtime** concern (inner
subscriptions live inside `OnNext`), never a type. These compile and run.

## Runtime notes (synchronous sources)

This library drives **synchronous** sources (a source emits and completes inside
`Subscribe`). That produces three sharp edges the operator implementations must
respect:

1. **Count before subscribing.** A fan-in coordinator (Merge) must register every
   source's outstanding count *before* subscribing any, or a synchronous source
   completes the whole thing during its own `Subscribe`. Same for a flattening
   inner: increment the active count before `Inner.Subscribe`.
2. **Hold the coordinator via the interface `Result` first.** A synchronous
   source drops its reference to the coordinator when it completes; if the only
   reference is a local `TInterfacedObject`, the coordinator is freed before
   `Subscribe` returns. Assign `Result := Coord;` **before** subscribing.
3. **Complete only when *all* inputs are done** (Merge) or **both sides** (Zip),
   never on the first completion.

Reference cycles are the leak hazard: a forwarding observer holding its downstream
while the downstream holds it. The concrete sources wrap the observer in a
`TSubscriber` (which clears its references on terminal) — that is what keeps the
chain from leaking. Any new operator should do the same.

## What the constraints cost us

- **Expressible:** creation (`Just`, `FromArray`, `Range`, `Empty`, `ThrowError`,
  `Defer`); transformation (`Map`, `Scan`, `Pairwise`, `Reduce`); filtering
  (`Filter`, `Take`, `Skip`, `TakeWhile`, `SkipWhile`, `DistinctUntilChanged`,
  `Distinct`, `First`, `Last`, `ElementAt`, `IgnoreElements`); fan-in (`Merge`,
  `Concat`, `Race`); flattening (`MergeMap`, `SwitchMap`, `ConcatMap`); combine
  (`Zip`, `CombineLatest`); utility (`Tap`, `StartWith`, `EndWith`); aggregation
  (`Count`); error (`CatchError`, `Finalize`, `Retry`); composition
  (`IOperator<T>` factories + `Pipe`).
- **Not yet expressible** (need a non-nesting container type): `Buffer`,
  `ToArray`, `Window`, `GroupBy`, and a true `MergeAll` over
  `ISubscribable<ISubscribable<T>>`. `Race` here is a synchronous approximation
  (the first source wins because synchronous sources complete in order); a true
  race needs overlapping sources.
- **Implemented (unit `async.time`)**: the time-based operators `Delay`,
  `DebounceTime`, `ThrottleTime`, `SampleTime`, `AuditTime`, `Timeout`, and the
  creation operators `Timer` and `Interval`. Each takes an explicit
  `IAsyncScheduler` — a `TVirtualScheduler` in tests (driven by `Advance`, no
  sleeps) or a `TRealScheduler` in production — per the spec's rule that a
  time-based operator uses the scheduler it is given. The scheduled work is a
  concrete object method (a `TNotify`), never a closure, and a one-shot action
  frees itself after it runs.
- **Not yet implemented**: `TimeoutWith`, `DelayWhen` (small additions on the
  same pattern).

## Reproducing the probes

Each rule above was checked with a ~20-line standalone program compiled with:

```
fpc -Fu./src/async -FE./build/bin -FU./build/units/dbg <probe>.pas
```

and run under the leak checker with
`HEAPTRC=haltonnotreleased:skipifnoleaks`. When extending the operators, add a
probe for any new *shape* before writing the real unit — the compiler's answers
here are non-obvious and version-specific.
