unit async.operators;
{ Operators: free functions ISubscribable<T> -> ISubscribable<U>, each lazily
  subscribing to its source when the result is subscribed.

  The surface is FREE FUNCTIONS, composed RxJS-style:
    Filter<Integer>(src, isEven)
    Pipe<Integer>(src, [FilterOp<Integer>(isEven), TakeOp<Integer>(3)])
  A curried factory (FilterOp) returns an IOperator<T> value; Pipe reduces a
  source over an array of them. Pipe is called ONCE with the whole array.

  FPC 3.3.1 constrains the ENCODING, not the signatures (verified by probe; see
  docs/features/Async_Core/FPC_Generics_Notes.md):
  - a free generic function is fine UNLESS its body builds an anonymous function
    capturing the type param, or it is forward-declared (both ICE);
  - a generic inside a generic is forbidden as a TYPE, so operators that would
    return ISubscribable<TArray<T>> / ISubscribable<TPair<T,U>> are re-expressed
    in projection/combiner form, keeping the element type a parameter:
      Pairwise<T,U>(src, pair: (T,T)->U): ISubscribable<U>
      Zip<T,U,V>(a, b, combine: (T,U)->V): ISubscribable<V>
      Reduce<T,A>(src, seed: A, reducer: (A,T)->A): ISubscribable<A>
  Flattening (MergeMap/SwitchMap/ConcatMap) is NOT nesting in the type: the
  projection returns a stream, but the operator's result is one level.

  The concrete observer + observable classes remain only as the Subscribe
  machinery (they hold the per-subscription state). See the notes doc for the
  runtime sharp edges (count before subscribing, hold the coordinator via Result,
  complete only when all inputs are done, the TSubscriber leak fix).

  This library has NO dependency on the harness or any engine unit - it must stay
  extractable. See docs/features/Async_Core/Async_Core_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, SyncObjs,
  async.base, async.observable;

type
  TPredicate<T> = reference to function(const AValue: T): Boolean;
  TAccumulator<T> = reference to function(const AAcc, AValue: T): T;
  TEquality<T> = reference to function(const A, B: T): Boolean;
  TDeferFactory<T> = reference to function: ISubscribable<T>;
  { A projection to a stream: the flattening operators' key delegate. }
  TStreamMapper<T, U> = reference to function(const AValue: T): ISubscribable<U>;
  { A projection to a plain value: the pairwise operator turns a pair into U. }
  TPairMapper<T, U> = reference to function(const APrev, ACurr: T): U;
  { A combine of two element types into a third: Zip, CombineLatest, WithLatestFrom. }
  TCombiner<T, U, V> = reference to function(const A: T; const B: U): V;
  { A fold with a SEPARATE accumulator type: Reduce. }
  TReducer<T, A> = reference to function(const AAcc: A; const AValue: T): A;
  { An error projection: CatchError maps an error to a fallback stream. }
  TErrorMapper<T> = reference to function(const AError: Exception): ISubscribable<T>;
  { A predicate over the whole stream: Every, ThrowIfEmpty. }
  TVoidPredicate = reference to function: Boolean;

  { --- Observers (one per rule) ------------------------------------------ }

  TScanObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FAcc: T;
    FAccumulator: TAccumulator<T>;
  public
    constructor Create(const ADown: IObserver<T>; const ASeed: T;
      const AAccumulator: TAccumulator<T>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TFilterObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FPredicate: TPredicate<T>;
  public
    constructor Create(const ADown: IObserver<T>; const APredicate: TPredicate<T>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TTakeObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FCount: Integer;
    FSeen: Integer;
    FDone: Boolean;
  public
    constructor Create(const ADown: IObserver<T>; const ACount: Integer);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TSkipObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FCount: Integer;
    FSeen: Integer;
  public
    constructor Create(const ADown: IObserver<T>; const ACount: Integer);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TTakeWhileObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FPredicate: TPredicate<T>;
    FDone: Boolean;
  public
    constructor Create(const ADown: IObserver<T>; const APredicate: TPredicate<T>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TSkipWhileObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FPredicate: TPredicate<T>;
    FSkipping: Boolean;
  public
    constructor Create(const ADown: IObserver<T>; const APredicate: TPredicate<T>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TDistinctObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FEquals: TEquality<T>;
    FPrev: T;
    FHasPrev: Boolean;
  public
    constructor Create(const ADown: IObserver<T>; const AEquals: TEquality<T>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TMapObserver<T, U> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<U>;
    FMapper: TMapper<T, U>;
  public
    constructor Create(const ADown: IObserver<U>; const AMapper: TMapper<T, U>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  { --- Observables (the Subscribe seam; no closures) --------------------- }

  TJustObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FValue: T;
  public
    constructor Create(const AValue: T);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TFromArrayObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FValues: TArray<T>;
  public
    constructor Create(const AValues: TArray<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TRangeObservable = class(TInterfacedObject, ISubscribable<Integer>)
  private
    FStart, FCount: Integer;
  public
    constructor Create(const AStart, ACount: Integer);
    function Subscribe(const AObserver: IObserver<Integer>): ISubscription;
  end;

  TEmptyObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  public
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TThrowObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FError: Exception;
  public
    constructor Create(const AError: Exception);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TDeferObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FFactory: TDeferFactory<T>;
  public
    constructor Create(const AFactory: TDeferFactory<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TScanObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FSeed: T;
    FAccumulator: TAccumulator<T>;
  public
    constructor Create(const ASource: ISubscribable<T>; const ASeed: T;
      const AAccumulator: TAccumulator<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TFilterObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FPredicate: TPredicate<T>;
  public
    constructor Create(const ASource: ISubscribable<T>;
      const APredicate: TPredicate<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TTakeObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FCount: Integer;
  public
    constructor Create(const ASource: ISubscribable<T>; const ACount: Integer);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TSkipObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FCount: Integer;
  public
    constructor Create(const ASource: ISubscribable<T>; const ACount: Integer);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TTakeWhileObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FPredicate: TPredicate<T>;
  public
    constructor Create(const ASource: ISubscribable<T>;
      const APredicate: TPredicate<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TSkipWhileObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FPredicate: TPredicate<T>;
  public
    constructor Create(const ASource: ISubscribable<T>;
      const APredicate: TPredicate<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TDistinctObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FEquals: TEquality<T>;
  public
    constructor Create(const ASource: ISubscribable<T>; const AEquals: TEquality<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TMapObservable<T, U> = class(TInterfacedObject, ISubscribable<U>)
  private
    FSource: ISubscribable<T>;
    FMapper: TMapper<T, U>;
  public
    constructor Create(const ASource: ISubscribable<T>;
      const AMapper: TMapper<T, U>);
    function Subscribe(const AObserver: IObserver<U>): ISubscription;
  end;

  { --- Coordinating operators (fan-in and flattening) ------------------- }

  { Counts outstanding sources/inner streams; completes the downstream only
    when all are done. Shared by Merge and MergeMap. }
  TMergeObserver<T> = class(TInterfacedObject, IObserver<T>, ISubscription)
  private
    FDown: IObserver<T>;
    FLock: TCriticalSection;
    FRemaining: Integer;
    FSourceDone: Boolean;
  public
    constructor Create(const ADown: IObserver<T>);
    destructor Destroy; override;
    procedure AddInner;
    procedure SourceCompleted;
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
    procedure Unsubscribe;
    function Closed: Boolean;
  end;

  TMergeObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSources: TArray<ISubscribable<T>>;
  public
    constructor Create(const ASources: TArray<ISubscribable<T>>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  { Sequential fan-in: subscribe each source only after the previous completes. }
  TConcatObserver<T> = class(TInterfacedObject, IObserver<T>, ISubscription)
  private
    FDown: IObserver<T>;
    FSources: TArray<ISubscribable<T>>;
    FIndex: Integer;
    FDone: Boolean;
    procedure SubscribeNext;
  public
    constructor Create(const ADown: IObserver<T>; const ASources: TArray<ISubscribable<T>>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
    procedure Unsubscribe;
    function Closed: Boolean;
  end;

  TConcatObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSources: TArray<ISubscribable<T>>;
  public
    constructor Create(const ASources: TArray<ISubscribable<T>>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TFlattenMode = (fmMerge, fmSwitch, fmConcat);

  { Projects each source value to an inner stream and flattens: MergeMap keeps
    all inners live, SwitchMap keeps only the newest, ConcatMap runs them in
    order. The RESULT is one level (ISubscribable<U>); the nesting is runtime. }
  TFlattenObserver<T, U> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<U>;
    FProject: TStreamMapper<T, U>;
    FMode: TFlattenMode;
    FLock: TCriticalSection;
    FSourceDone: Boolean;
    FActive: Integer;
    FCurrent: ISubscription;   { switch: the live inner }
    FQueue: TArray<ISubscribable<U>>;  { concat: pending inners }
    FRunning: Boolean;
    procedure InnerNext(const AValue: U);
    procedure InnerDone;
    procedure SubscribeInner(const AInner: ISubscribable<U>);
    procedure DrainConcat;
  public
    constructor Create(const ADown: IObserver<U>; const AProject: TStreamMapper<T, U>;
      const AMode: TFlattenMode);
    destructor Destroy; override;
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TFlattenObservable<T, U> = class(TInterfacedObject, ISubscribable<U>)
  private
    FSource: ISubscribable<T>;
    FProject: TStreamMapper<T, U>;
    FMode: TFlattenMode;
  public
    constructor Create(const ASource: ISubscribable<T>;
      const AProject: TStreamMapper<T, U>; const AMode: TFlattenMode);
    function Subscribe(const AObserver: IObserver<U>): ISubscription;
  end;

  { Two-stream combine by a combiner function (no tuple type). A coordinator
    buffers each side and emits a combined value per matched pair; two thin
    observers push each side in (one class cannot implement IObserver<T> and
    IObserver<U> at once - the method names collide). }
  TZipCoordinator<T, U, V> = class(TInterfacedObject, ISubscription)
  private
    FDown: IObserver<V>;
    FCombine: TCombiner<T, U, V>;
    FLeft: TArray<T>;
    FRight: TArray<U>;
    FLeftDone: Boolean;
    FRightDone: Boolean;
    FClosed: Boolean;
    procedure TryEmit;
  public
    constructor Create(const ADown: IObserver<V>; const ACombine: TCombiner<T, U, V>);
    procedure PushLeft(const AValue: T);
    procedure PushRight(const AValue: U);
    procedure LeftDone;
    procedure RightDone;
    procedure Unsubscribe;
    function Closed: Boolean;
  end;

  TZipLeftObserver<T, U, V> = class(TInterfacedObject, IObserver<T>)
  private
    FCoord: TZipCoordinator<T, U, V>;
  public
    constructor Create(const ACoord: TZipCoordinator<T, U, V>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TZipRightObserver<T, U, V> = class(TInterfacedObject, IObserver<U>)
  private
    FCoord: TZipCoordinator<T, U, V>;
  public
    constructor Create(const ACoord: TZipCoordinator<T, U, V>);
    procedure OnNext(const AValue: U);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TZipObservable<T, U, V> = class(TInterfacedObject, ISubscribable<V>)
  private
    FLeft: ISubscribable<T>;
    FRight: ISubscribable<U>;
    FCombine: TCombiner<T, U, V>;
  public
    constructor Create(const ALeft: ISubscribable<T>;
      const ARight: ISubscribable<U>; const ACombine: TCombiner<T, U, V>);
    function Subscribe(const AObserver: IObserver<V>): ISubscription;
  end;

  TReduceObserver<T, A> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<A>;
    FAcc: A;
    FReducer: TReducer<T, A>;
  public
    constructor Create(const ADown: IObserver<A>; const ASeed: A;
      const AReducer: TReducer<T, A>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TReduceObservable<T, A> = class(TInterfacedObject, ISubscribable<A>)
  private
    FSource: ISubscribable<T>;
    FSeed: A;
    FReducer: TReducer<T, A>;
  public
    constructor Create(const ASource: ISubscribable<T>; const ASeed: A;
      const AReducer: TReducer<T, A>);
    function Subscribe(const AObserver: IObserver<A>): ISubscription;
  end;

  TPairwiseObserver<T, U> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<U>;
    FPair: TPairMapper<T, U>;
    FPrev: T;
    FHasPrev: Boolean;
  public
    constructor Create(const ADown: IObserver<U>; const APair: TPairMapper<T, U>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TPairwiseObservable<T, U> = class(TInterfacedObject, ISubscribable<U>)
  private
    FSource: ISubscribable<T>;
    FPair: TPairMapper<T, U>;
  public
    constructor Create(const ASource: ISubscribable<T>; const APair: TPairMapper<T, U>);
    function Subscribe(const AObserver: IObserver<U>): ISubscription;
  end;

  { An operator as a first-class value (RxJS OperatorFunction): same-type in and
    out. Built by a curried factory, e.g. FilterOp<Integer>(pred). }
  IOperator<T> = interface
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;

  { A type-changing operator as a value (for Map): T in, U out. }
  IMapOperator<T, U> = interface
    function Apply(const A: ISubscribable<T>): ISubscribable<U>;
  end;

  { The concrete operator classes behind the curried factories. }
  TFilterOperator<T> = class(TInterfacedObject, IOperator<T>)
  private
    FPredicate: TPredicate<T>;
  public
    constructor Create(const APredicate: TPredicate<T>);
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;
  TTakeOperator<T> = class(TInterfacedObject, IOperator<T>)
  private
    FCount: Integer;
  public
    constructor Create(const ACount: Integer);
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;
  TSkipOperator<T> = class(TInterfacedObject, IOperator<T>)
  private
    FCount: Integer;
  public
    constructor Create(const ACount: Integer);
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;
  TTakeWhileOperator<T> = class(TInterfacedObject, IOperator<T>)
  private
    FPredicate: TPredicate<T>;
  public
    constructor Create(const APredicate: TPredicate<T>);
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;
  TSkipWhileOperator<T> = class(TInterfacedObject, IOperator<T>)
  private
    FPredicate: TPredicate<T>;
  public
    constructor Create(const APredicate: TPredicate<T>);
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;
  TDistinctOperator<T> = class(TInterfacedObject, IOperator<T>)
  private
    FEquals: TEquality<T>;
  public
    constructor Create(const AEquals: TEquality<T>);
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;
  TFirstOperator<T> = class(TInterfacedObject, IOperator<T>)
  public
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;
  TElementAtOperator<T> = class(TInterfacedObject, IOperator<T>)
  private
    FIndex: Integer;
  public
    constructor Create(const AIndex: Integer);
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;

  TTapObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FAction: TAction<T>;
  public
    constructor Create(const ADown: IObserver<T>; const AAction: TAction<T>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TTapObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FAction: TAction<T>;
  public
    constructor Create(const ASource: ISubscribable<T>; const AAction: TAction<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TIgnoreObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
  public
    constructor Create(const ASource: ISubscribable<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TIgnoreObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
  public
    constructor Create(const ADown: IObserver<T>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TStartWithObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FValue: T;
  public
    constructor Create(const ASource: ISubscribable<T>; const AValue: T);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TEndWithObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FValue: T;
  public
    constructor Create(const ADown: IObserver<T>; const AValue: T);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TEndWithObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FValue: T;
  public
    constructor Create(const ASource: ISubscribable<T>; const AValue: T);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TDistinctAllObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FEquals: TEquality<T>;
    FSeen: TArray<T>;
  public
    constructor Create(const ADown: IObserver<T>; const AEquals: TEquality<T>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TDistinctAllObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FEquals: TEquality<T>;
  public
    constructor Create(const ASource: ISubscribable<T>; const AEquals: TEquality<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TLastObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FLast: T;
    FHas: Boolean;
  public
    constructor Create(const ADown: IObserver<T>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TLastObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
  public
    constructor Create(const ASource: ISubscribable<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TCountObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<Integer>;
    FN: Integer;
  public
    constructor Create(const ADown: IObserver<Integer>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TCountObservable<T> = class(TInterfacedObject, ISubscribable<Integer>)
  private
    FSource: ISubscribable<T>;
  public
    constructor Create(const ASource: ISubscribable<T>);
    function Subscribe(const AObserver: IObserver<Integer>): ISubscription;
  end;

  TCatchObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FHandler: TErrorMapper<T>;
    FHandled: Boolean;
  public
    constructor Create(const ADown: IObserver<T>; const AHandler: TErrorMapper<T>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TCatchObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FHandler: TErrorMapper<T>;
  public
    constructor Create(const ASource: ISubscribable<T>; const AHandler: TErrorMapper<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TFinalizeObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FDown: IObserver<T>;
    FAction: TAction0;
    FRan: Boolean;
    procedure RunOnce;
  public
    constructor Create(const ADown: IObserver<T>; const AAction: TAction0);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TFinalizeObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FAction: TAction0;
  public
    constructor Create(const ASource: ISubscribable<T>; const AAction: TAction0);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TRetryObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSource: ISubscribable<T>;
    FCount: Integer;
  public
    constructor Create(const ASource: ISubscribable<T>; const ACount: Integer);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  TCombineLatestCoordinator<T, U, V> = class(TInterfacedObject, ISubscription)
  private
    FDown: IObserver<V>;
    FCombine: TCombiner<T, U, V>;
    FLastT: T;
    FLastU: U;
    FHasT: Boolean;
    FHasU: Boolean;
    FClosed: Boolean;
    FTDone: Boolean;
    FUDone: Boolean;
    procedure TryEmit;
  public
    constructor Create(const ADown: IObserver<V>; const ACombine: TCombiner<T, U, V>);
    procedure PushT(const AValue: T);
    procedure PushU(const AValue: U);
    procedure TDone;
    procedure UDone;
    procedure Unsubscribe;
    function Closed: Boolean;
  end;

  TCLTObserverT<T, U, V> = class(TInterfacedObject, IObserver<T>)
  private
    FC: TCombineLatestCoordinator<T, U, V>;
  public
    constructor Create(const AC: TCombineLatestCoordinator<T, U, V>);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TCLTObserverU<T, U, V> = class(TInterfacedObject, IObserver<U>)
  private
    FC: TCombineLatestCoordinator<T, U, V>;
  public
    constructor Create(const AC: TCombineLatestCoordinator<T, U, V>);
    procedure OnNext(const AValue: U);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  TCombineLatestObservable<T, U, V> = class(TInterfacedObject, ISubscribable<V>)
  private
    FLeft: ISubscribable<T>;
    FRight: ISubscribable<U>;
    FCombine: TCombiner<T, U, V>;
  public
    constructor Create(const ALeft: ISubscribable<T>;
      const ARight: ISubscribable<U>; const ACombine: TCombiner<T, U, V>);
    function Subscribe(const AObserver: IObserver<V>): ISubscription;
  end;

  { Curried factories' concrete classes. }
  TMapOperator<T, U> = class(TInterfacedObject, IMapOperator<T, U>)
  private
    FMapper: TMapper<T, U>;
  public
    constructor Create(const AMapper: TMapper<T, U>);
    function Apply(const A: ISubscribable<T>): ISubscribable<U>;
  end;
  TScanOperator<T> = class(TInterfacedObject, IOperator<T>)
  private
    FSeed: T;
    FAccumulator: TAccumulator<T>;
  public
    constructor Create(const ASeed: T; const AAccumulator: TAccumulator<T>);
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;
  TTapOperator<T> = class(TInterfacedObject, IOperator<T>)
  private
    FAction: TAction<T>;
  public
    constructor Create(const AAction: TAction<T>);
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;
  TDistinctAllOperator<T> = class(TInterfacedObject, IOperator<T>)
  private
    FEquals: TEquality<T>;
  public
    constructor Create(const AEquals: TEquality<T>);
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;
  TIgnoreOperator<T> = class(TInterfacedObject, IOperator<T>)
  public
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;
  TLastOperator<T> = class(TInterfacedObject, IOperator<T>)
  public
    function Apply(const A: ISubscribable<T>): ISubscribable<T>;
  end;


  { --- Sources (free functions) ----------------------------------------- }
  function Just<T>(const AValue: T): ISubscribable<T>;
  function FromArray<T>(const AValues: TArray<T>): ISubscribable<T>;
  function Range(AStart, ACount: Integer): ISubscribable<Integer>;
  function Empty<T>: ISubscribable<T>;
  function ThrowError<T>(const AError: Exception): ISubscribable<T>;
  function Defer<T>(const AFactory: TDeferFactory<T>): ISubscribable<T>;

  { --- Operators as pure functions of a source (the primitives) -------- }
  function Map<T, U>(const ASource: ISubscribable<T>;
    const AMapper: TMapper<T, U>): ISubscribable<U>;
  function Scan<T>(const ASource: ISubscribable<T>; const ASeed: T;
    const AAccumulator: TAccumulator<T>): ISubscribable<T>;
  function Filter<T>(const ASource: ISubscribable<T>;
    const APredicate: TPredicate<T>): ISubscribable<T>;
  function Take<T>(const ASource: ISubscribable<T>;
    const ACount: Integer): ISubscribable<T>;
  function Skip<T>(const ASource: ISubscribable<T>;
    const ACount: Integer): ISubscribable<T>;
  function TakeWhile<T>(const ASource: ISubscribable<T>;
    const APredicate: TPredicate<T>): ISubscribable<T>;
  function SkipWhile<T>(const ASource: ISubscribable<T>;
    const APredicate: TPredicate<T>): ISubscribable<T>;
  function DistinctUntilChanged<T>(const ASource: ISubscribable<T>;
    const AEquals: TEquality<T>): ISubscribable<T>;
  function First<T>(const ASource: ISubscribable<T>): ISubscribable<T>;
  function ElementAt<T>(const ASource: ISubscribable<T>;
    const AIndex: Integer): ISubscribable<T>;
  function Merge<T>(const ASources: TArray<ISubscribable<T>>): ISubscribable<T>;
  function Concat<T>(const ASources: TArray<ISubscribable<T>>): ISubscribable<T>;
  function MergeMap<T, U>(const ASource: ISubscribable<T>;
    const AProject: TStreamMapper<T, U>): ISubscribable<U>;
  function SwitchMap<T, U>(const ASource: ISubscribable<T>;
    const AProject: TStreamMapper<T, U>): ISubscribable<U>;
  function ConcatMap<T, U>(const ASource: ISubscribable<T>;
    const AProject: TStreamMapper<T, U>): ISubscribable<U>;
  function Zip<T, U, V>(const ALeft: ISubscribable<T>;
    const ARight: ISubscribable<U>;
    const ACombine: TCombiner<T, U, V>): ISubscribable<V>;
  function Reduce<T, A>(const ASource: ISubscribable<T>; const ASeed: A;
    const AReducer: TReducer<T, A>): ISubscribable<A>;
  function Pairwise<T, U>(const ASource: ISubscribable<T>;
    const APair: TPairMapper<T, U>): ISubscribable<U>;

  { --- Curried operator factories (RxJS: filter(pred) -> operator) ----- }
  function FilterOp<T>(const APredicate: TPredicate<T>): IOperator<T>;
  function TakeOp<T>(const ACount: Integer): IOperator<T>;
  function SkipOp<T>(const ACount: Integer): IOperator<T>;
  function TakeWhileOp<T>(const APredicate: TPredicate<T>): IOperator<T>;
  function SkipWhileOp<T>(const APredicate: TPredicate<T>): IOperator<T>;
  function DistinctUntilChangedOp<T>(const AEquals: TEquality<T>): IOperator<T>;
  function FirstOp<T>: IOperator<T>;
  function ElementAtOp<T>(const AIndex: Integer): IOperator<T>;

  { --- Pipe: reduce a source over an array of operators ----------------- }
  function Pipe<T>(const A: ISubscribable<T>;
    const AOps: TArray<IOperator<T> >): ISubscribable<T>;

  { --- More operators (free functions) ---------------------------------- }
  function Tap<T>(const ASource: ISubscribable<T>;
    const AAction: TAction<T>): ISubscribable<T>;
  function IgnoreElements<T>(const ASource: ISubscribable<T>): ISubscribable<T>;
  function StartWith<T>(const ASource: ISubscribable<T>;
    const AValue: T): ISubscribable<T>;
  function EndWith<T>(const ASource: ISubscribable<T>;
    const AValue: T): ISubscribable<T>;
  function Distinct<T>(const ASource: ISubscribable<T>;
    const AEquals: TEquality<T>): ISubscribable<T>;
  function Last<T>(const ASource: ISubscribable<T>): ISubscribable<T>;
  function Count<T>(const ASource: ISubscribable<T>): ISubscribable<Integer>;
  function CatchError<T>(const ASource: ISubscribable<T>;
    const AHandler: TErrorMapper<T>): ISubscribable<T>;
  function Finalize<T>(const ASource: ISubscribable<T>;
    const AAction: TAction0): ISubscribable<T>;
  function Retry<T>(const ASource: ISubscribable<T>;
    const ACount: Integer): ISubscribable<T>;
  function CombineLatest<T, U, V>(const ALeft: ISubscribable<T>;
    const ARight: ISubscribable<U>;
    const ACombine: TCombiner<T, U, V>): ISubscribable<V>;
  function Race<T>(const ASources: TArray<ISubscribable<T>>): ISubscribable<T>;

  { --- More curried operator factories ---------------------------------- }
  function MapOp<T, U>(const AMapper: TMapper<T, U>): IMapOperator<T, U>;
  function ScanOp<T>(const ASeed: T;
    const AAccumulator: TAccumulator<T>): IOperator<T>;
  function TapOp<T>(const AAction: TAction<T>): IOperator<T>;
  function DistinctOp<T>(const AEquals: TEquality<T>): IOperator<T>;
  function IgnoreElementsOp<T>: IOperator<T>;
  function LastOp<T>: IOperator<T>;

  { --- Observers for the extra operators -------------------------------- }

implementation

{ Observers }

constructor TScanObserver<T>.Create(const ADown: IObserver<T>; const ASeed: T;
  const AAccumulator: TAccumulator<T>);
begin
  inherited Create;
  FDown := ADown;
  FAcc := ASeed;
  FAccumulator := AAccumulator;
end;

procedure TScanObserver<T>.OnNext(const AValue: T);
begin
  FAcc := FAccumulator(FAcc, AValue);
  FDown.OnNext(FAcc);
end;

procedure TScanObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TScanObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

constructor TFilterObserver<T>.Create(const ADown: IObserver<T>;
  const APredicate: TPredicate<T>);
begin
  inherited Create;
  FDown := ADown;
  FPredicate := APredicate;
end;

procedure TFilterObserver<T>.OnNext(const AValue: T);
begin
  if FPredicate(AValue) then
    FDown.OnNext(AValue);
end;

procedure TFilterObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TFilterObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

constructor TTakeObserver<T>.Create(const ADown: IObserver<T>;
  const ACount: Integer);
begin
  inherited Create;
  FDown := ADown;
  FCount := ACount;
  FSeen := 0;
  FDone := False;
end;

procedure TTakeObserver<T>.OnNext(const AValue: T);
begin
  if FDone then
    Exit;
  if FSeen < FCount then
  begin
    FDown.OnNext(AValue);
    Inc(FSeen);
    if FSeen = FCount then
    begin
      FDone := True;
      FDown.OnComplete;
    end;
  end;
end;

procedure TTakeObserver<T>.OnError(const AError: Exception);
begin
  if FDone then
  begin
    AError.Free;
    Exit;
  end;
  FDown.OnError(AError);
end;

procedure TTakeObserver<T>.OnComplete;
begin
  if FDone then
    Exit;
  FDone := True;
  FDown.OnComplete;
end;

constructor TSkipObserver<T>.Create(const ADown: IObserver<T>;
  const ACount: Integer);
begin
  inherited Create;
  FDown := ADown;
  FCount := ACount;
  FSeen := 0;
end;

procedure TSkipObserver<T>.OnNext(const AValue: T);
begin
  if FSeen >= FCount then
    FDown.OnNext(AValue);
  Inc(FSeen);
end;

procedure TSkipObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TSkipObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

constructor TTakeWhileObserver<T>.Create(const ADown: IObserver<T>;
  const APredicate: TPredicate<T>);
begin
  inherited Create;
  FDown := ADown;
  FPredicate := APredicate;
  FDone := False;
end;

procedure TTakeWhileObserver<T>.OnNext(const AValue: T);
begin
  if FDone then
    Exit;
  if FPredicate(AValue) then
    FDown.OnNext(AValue)
  else
  begin
    FDone := True;
    FDown.OnComplete;
  end;
end;

procedure TTakeWhileObserver<T>.OnError(const AError: Exception);
begin
  if FDone then
  begin
    AError.Free;
    Exit;
  end;
  FDown.OnError(AError);
end;

procedure TTakeWhileObserver<T>.OnComplete;
begin
  if FDone then
    Exit;
  FDone := True;
  FDown.OnComplete;
end;

constructor TSkipWhileObserver<T>.Create(const ADown: IObserver<T>;
  const APredicate: TPredicate<T>);
begin
  inherited Create;
  FDown := ADown;
  FPredicate := APredicate;
  FSkipping := True;
end;

procedure TSkipWhileObserver<T>.OnNext(const AValue: T);
begin
  if FSkipping and FPredicate(AValue) then
    Exit;
  FSkipping := False;
  FDown.OnNext(AValue);
end;

procedure TSkipWhileObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TSkipWhileObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

constructor TDistinctObserver<T>.Create(const ADown: IObserver<T>;
  const AEquals: TEquality<T>);
begin
  inherited Create;
  FDown := ADown;
  FEquals := AEquals;
  FHasPrev := False;
end;

procedure TDistinctObserver<T>.OnNext(const AValue: T);
begin
  if FHasPrev and FEquals(FPrev, AValue) then
    Exit;
  FPrev := AValue;
  FHasPrev := True;
  FDown.OnNext(AValue);
end;

procedure TDistinctObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TDistinctObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

constructor TMapObserver<T, U>.Create(const ADown: IObserver<U>;
  const AMapper: TMapper<T, U>);
begin
  inherited Create;
  FDown := ADown;
  FMapper := AMapper;
end;

procedure TMapObserver<T, U>.OnNext(const AValue: T);
begin
  FDown.OnNext(FMapper(AValue));
end;

procedure TMapObserver<T, U>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TMapObserver<T, U>.OnComplete;
begin
  FDown.OnComplete;
end;

{ Sources }

constructor TJustObservable<T>.Create(const AValue: T);
begin
  inherited Create;
  FValue := AValue;
end;

function TJustObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Sub: TSubscriber<T>;
begin
  Sub := TSubscriber<T>.Create(AObserver);
  Sub.SetUpstream(TClosureSubscription.Create(nil));
  Sub.OnNext(FValue);
  Sub.OnComplete;
  Result := Sub;
end;

constructor TFromArrayObservable<T>.Create(const AValues: TArray<T>);
begin
  inherited Create;
  FValues := AValues;
end;

function TFromArrayObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Sub: TSubscriber<T>;
  I: Integer;
begin
  Sub := TSubscriber<T>.Create(AObserver);
  Sub.SetUpstream(TClosureSubscription.Create(nil));
  for I := 0 to High(FValues) do
    Sub.OnNext(FValues[I]);
  Sub.OnComplete;
  Result := Sub;
end;

constructor TRangeObservable.Create(const AStart, ACount: Integer);
begin
  inherited Create;
  FStart := AStart;
  FCount := ACount;
end;

function TRangeObservable.Subscribe(const AObserver: IObserver<Integer>): ISubscription;
var
  Sub: TSubscriber<Integer>;
  I: Integer;
begin
  Sub := TSubscriber<Integer>.Create(AObserver);
  Sub.SetUpstream(TClosureSubscription.Create(nil));
  for I := 0 to FCount - 1 do
    Sub.OnNext(FStart + I);
  Sub.OnComplete;
  Result := Sub;
end;

function TEmptyObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Sub: TSubscriber<T>;
begin
  Sub := TSubscriber<T>.Create(AObserver);
  Sub.SetUpstream(TClosureSubscription.Create(nil));
  Sub.OnComplete;
  Result := Sub;
end;

constructor TThrowObservable<T>.Create(const AError: Exception);
begin
  inherited Create;
  FError := AError;
end;

function TThrowObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Sub: TSubscriber<T>;
begin
  Sub := TSubscriber<T>.Create(AObserver);
  Sub.SetUpstream(TClosureSubscription.Create(nil));
  Sub.OnError(FError);
  Result := Sub;
end;

constructor TDeferObservable<T>.Create(const AFactory: TDeferFactory<T>);
begin
  inherited Create;
  FFactory := AFactory;
end;

function TDeferObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FFactory().Subscribe(AObserver);
end;

{ Same-type operators }

constructor TScanObservable<T>.Create(const ASource: ISubscribable<T>;
  const ASeed: T; const AAccumulator: TAccumulator<T>);
begin
  inherited Create;
  FSource := ASource;
  FSeed := ASeed;
  FAccumulator := AAccumulator;
end;

function TScanObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TScanObserver<T>.Create(AObserver, FSeed,
    FAccumulator));
end;

constructor TFilterObservable<T>.Create(const ASource: ISubscribable<T>;
  const APredicate: TPredicate<T>);
begin
  inherited Create;
  FSource := ASource;
  FPredicate := APredicate;
end;

function TFilterObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TFilterObserver<T>.Create(AObserver, FPredicate));
end;

constructor TTakeObservable<T>.Create(const ASource: ISubscribable<T>;
  const ACount: Integer);
begin
  inherited Create;
  FSource := ASource;
  FCount := ACount;
end;

function TTakeObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TTakeObserver<T>.Create(AObserver, FCount));
end;

constructor TSkipObservable<T>.Create(const ASource: ISubscribable<T>;
  const ACount: Integer);
begin
  inherited Create;
  FSource := ASource;
  FCount := ACount;
end;

function TSkipObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TSkipObserver<T>.Create(AObserver, FCount));
end;

constructor TTakeWhileObservable<T>.Create(const ASource: ISubscribable<T>;
  const APredicate: TPredicate<T>);
begin
  inherited Create;
  FSource := ASource;
  FPredicate := APredicate;
end;

function TTakeWhileObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TTakeWhileObserver<T>.Create(AObserver, FPredicate));
end;

constructor TSkipWhileObservable<T>.Create(const ASource: ISubscribable<T>;
  const APredicate: TPredicate<T>);
begin
  inherited Create;
  FSource := ASource;
  FPredicate := APredicate;
end;

function TSkipWhileObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TSkipWhileObserver<T>.Create(AObserver, FPredicate));
end;

constructor TDistinctObservable<T>.Create(const ASource: ISubscribable<T>;
  const AEquals: TEquality<T>);
begin
  inherited Create;
  FSource := ASource;
  FEquals := AEquals;
end;

function TDistinctObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TDistinctObserver<T>.Create(AObserver, FEquals));
end;

{ Cross-type operator }

constructor TMapObservable<T, U>.Create(const ASource: ISubscribable<T>;
  const AMapper: TMapper<T, U>);
begin
  inherited Create;
  FSource := ASource;
  FMapper := AMapper;
end;

function TMapObservable<T, U>.Subscribe(const AObserver: IObserver<U>): ISubscription;
begin
  Result := FSource.Subscribe(TMapObserver<T, U>.Create(AObserver, FMapper));
end;

{ Sources (free functions) }

function Just<T>(const AValue: T): ISubscribable<T>;
begin
  Result := TJustObservable<T>.Create(AValue);
end;

function FromArray<T>(const AValues: TArray<T>): ISubscribable<T>;
begin
  Result := TFromArrayObservable<T>.Create(AValues);
end;

function Range(AStart, ACount: Integer): ISubscribable<Integer>;
begin
  Result := TRangeObservable.Create(AStart, ACount);
end;

function Empty<T>: ISubscribable<T>;
begin
  Result := TEmptyObservable<T>.Create;
end;

function ThrowError<T>(const AError: Exception): ISubscribable<T>;
begin
  Result := TThrowObservable<T>.Create(AError);
end;

function Defer<T>(const AFactory: TDeferFactory<T>): ISubscribable<T>;
begin
  Result := TDeferObservable<T>.Create(AFactory);
end;

{ Operators (free functions of a source) }

function Map<T, U>(const ASource: ISubscribable<T>;
  const AMapper: TMapper<T, U>): ISubscribable<U>;
begin
  Result := TMapObservable<T, U>.Create(ASource, AMapper);
end;

function Scan<T>(const ASource: ISubscribable<T>; const ASeed: T;
  const AAccumulator: TAccumulator<T>): ISubscribable<T>;
begin
  Result := TScanObservable<T>.Create(ASource, ASeed, AAccumulator);
end;

function Filter<T>(const ASource: ISubscribable<T>;
  const APredicate: TPredicate<T>): ISubscribable<T>;
begin
  Result := TFilterObservable<T>.Create(ASource, APredicate);
end;

function Take<T>(const ASource: ISubscribable<T>;
  const ACount: Integer): ISubscribable<T>;
begin
  Result := TTakeObservable<T>.Create(ASource, ACount);
end;

function Skip<T>(const ASource: ISubscribable<T>;
  const ACount: Integer): ISubscribable<T>;
begin
  Result := TSkipObservable<T>.Create(ASource, ACount);
end;

function TakeWhile<T>(const ASource: ISubscribable<T>;
  const APredicate: TPredicate<T>): ISubscribable<T>;
begin
  Result := TTakeWhileObservable<T>.Create(ASource, APredicate);
end;

function SkipWhile<T>(const ASource: ISubscribable<T>;
  const APredicate: TPredicate<T>): ISubscribable<T>;
begin
  Result := TSkipWhileObservable<T>.Create(ASource, APredicate);
end;

function DistinctUntilChanged<T>(const ASource: ISubscribable<T>;
  const AEquals: TEquality<T>): ISubscribable<T>;
begin
  Result := TDistinctObservable<T>.Create(ASource, AEquals);
end;

function First<T>(const ASource: ISubscribable<T>): ISubscribable<T>;
begin
  Result := TTakeObservable<T>.Create(ASource, 1);
end;

function ElementAt<T>(const ASource: ISubscribable<T>;
  const AIndex: Integer): ISubscribable<T>;
begin
  Result := TTakeObservable<T>.Create(TSkipObservable<T>.Create(ASource, AIndex), 1);
end;

function Merge<T>(const ASources: TArray<ISubscribable<T>>): ISubscribable<T>;
begin
  Result := TMergeObservable<T>.Create(ASources);
end;

function Concat<T>(const ASources: TArray<ISubscribable<T>>): ISubscribable<T>;
begin
  Result := TConcatObservable<T>.Create(ASources);
end;

function MergeMap<T, U>(const ASource: ISubscribable<T>;
  const AProject: TStreamMapper<T, U>): ISubscribable<U>;
begin
  Result := TFlattenObservable<T, U>.Create(ASource, AProject, fmMerge);
end;

function SwitchMap<T, U>(const ASource: ISubscribable<T>;
  const AProject: TStreamMapper<T, U>): ISubscribable<U>;
begin
  Result := TFlattenObservable<T, U>.Create(ASource, AProject, fmSwitch);
end;

function ConcatMap<T, U>(const ASource: ISubscribable<T>;
  const AProject: TStreamMapper<T, U>): ISubscribable<U>;
begin
  Result := TFlattenObservable<T, U>.Create(ASource, AProject, fmConcat);
end;

function Zip<T, U, V>(const ALeft: ISubscribable<T>;
  const ARight: ISubscribable<U>;
  const ACombine: TCombiner<T, U, V>): ISubscribable<V>;
begin
  Result := TZipObservable<T, U, V>.Create(ALeft, ARight, ACombine);
end;

function Reduce<T, A>(const ASource: ISubscribable<T>; const ASeed: A;
  const AReducer: TReducer<T, A>): ISubscribable<A>;
begin
  Result := TReduceObservable<T, A>.Create(ASource, ASeed, AReducer);
end;

function Pairwise<T, U>(const ASource: ISubscribable<T>;
  const APair: TPairMapper<T, U>): ISubscribable<U>;
begin
  Result := TPairwiseObservable<T, U>.Create(ASource, APair);
end;

{ Curried operator factories }

function FilterOp<T>(const APredicate: TPredicate<T>): IOperator<T>;
begin
  Result := TFilterOperator<T>.Create(APredicate);
end;

function TakeOp<T>(const ACount: Integer): IOperator<T>;
begin
  Result := TTakeOperator<T>.Create(ACount);
end;

function SkipOp<T>(const ACount: Integer): IOperator<T>;
begin
  Result := TSkipOperator<T>.Create(ACount);
end;

function TakeWhileOp<T>(const APredicate: TPredicate<T>): IOperator<T>;
begin
  Result := TTakeWhileOperator<T>.Create(APredicate);
end;

function SkipWhileOp<T>(const APredicate: TPredicate<T>): IOperator<T>;
begin
  Result := TSkipWhileOperator<T>.Create(APredicate);
end;

function DistinctUntilChangedOp<T>(const AEquals: TEquality<T>): IOperator<T>;
begin
  Result := TDistinctOperator<T>.Create(AEquals);
end;

function FirstOp<T>: IOperator<T>;
begin
  Result := TFirstOperator<T>.Create;
end;

function ElementAtOp<T>(const AIndex: Integer): IOperator<T>;
begin
  Result := TElementAtOperator<T>.Create(AIndex);
end;

{ Pipe }

function Pipe<T>(const A: ISubscribable<T>;
  const AOps: TArray<IOperator<T> >): ISubscribable<T>;
var
  I: Integer;
begin
  Result := A;
  for I := 0 to High(AOps) do
    Result := AOps[I].Apply(Result);
end;

{ Operator classes }

constructor TFilterOperator<T>.Create(const APredicate: TPredicate<T>);
begin
  inherited Create;
  FPredicate := APredicate;
end;

function TFilterOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := Filter<T>(A, FPredicate);
end;

constructor TTakeOperator<T>.Create(const ACount: Integer);
begin
  inherited Create;
  FCount := ACount;
end;

function TTakeOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := Take<T>(A, FCount);
end;

constructor TSkipOperator<T>.Create(const ACount: Integer);
begin
  inherited Create;
  FCount := ACount;
end;

function TSkipOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := Skip<T>(A, FCount);
end;

constructor TTakeWhileOperator<T>.Create(const APredicate: TPredicate<T>);
begin
  inherited Create;
  FPredicate := APredicate;
end;

function TTakeWhileOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := TakeWhile<T>(A, FPredicate);
end;

constructor TSkipWhileOperator<T>.Create(const APredicate: TPredicate<T>);
begin
  inherited Create;
  FPredicate := APredicate;
end;

function TSkipWhileOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := SkipWhile<T>(A, FPredicate);
end;

constructor TDistinctOperator<T>.Create(const AEquals: TEquality<T>);
begin
  inherited Create;
  FEquals := AEquals;
end;

function TDistinctOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := DistinctUntilChanged<T>(A, FEquals);
end;

function TFirstOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := First<T>(A);
end;

constructor TElementAtOperator<T>.Create(const AIndex: Integer);
begin
  inherited Create;
  FIndex := AIndex;
end;

function TElementAtOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := ElementAt<T>(A, FIndex);
end;

{ TMergeObserver<T> }

constructor TMergeObserver<T>.Create(const ADown: IObserver<T>);
begin
  inherited Create;
  FDown := ADown;
  FLock := TCriticalSection.Create;
  FRemaining := 0;
  FSourceDone := False;
end;

destructor TMergeObserver<T>.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TMergeObserver<T>.AddInner;
begin
  FLock.Acquire;
  try
    Inc(FRemaining);
  finally
    FLock.Release;
  end;
end;

procedure TMergeObserver<T>.SourceCompleted;
begin
  FLock.Acquire;
  try
    FSourceDone := True;
  finally
    FLock.Release;
  end;
end;

procedure TMergeObserver<T>.OnNext(const AValue: T);
begin
  FDown.OnNext(AValue);
end;

procedure TMergeObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TMergeObserver<T>.OnComplete;
var
  Done: Boolean;
begin
  FLock.Acquire;
  try
    Dec(FRemaining);
    Done := FSourceDone and (FRemaining = 0);
  finally
    FLock.Release;
  end;
  if Done then
    FDown.OnComplete;
end;

procedure TMergeObserver<T>.Unsubscribe;
begin
  FSourceDone := True;
  FRemaining := 0;
end;

function TMergeObserver<T>.Closed: Boolean;
begin
  Result := FSourceDone and (FRemaining = 0);
end;

{ TMergeObservable<T> }

constructor TMergeObservable<T>.Create(const ASources: TArray<ISubscribable<T>>);
begin
  inherited Create;
  FSources := ASources;
end;

function TMergeObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Coord: TMergeObserver<T>;
  I: Integer;
begin
  Coord := TMergeObserver<T>.Create(AObserver);
  { Hold the coordinator through the interface Result before subscribing: a
    synchronous source completes and drops its reference during its own
    Subscribe, which would otherwise free the coordinator before this method
    returns. }
  Result := Coord;
  { Count every source BEFORE subscribing any: a synchronous source completes
    during its own Subscribe, so counting afterwards would complete downstream
    early. }
  for I := 0 to High(FSources) do
    Coord.AddInner;
  Coord.SourceCompleted;
  for I := 0 to High(FSources) do
    FSources[I].Subscribe(Coord);
end;

{ TConcatObservable<T> }

constructor TConcatObservable<T>.Create(const ASources: TArray<ISubscribable<T>>);
begin
  inherited Create;
  FSources := ASources;
end;

function TConcatObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Coord: TConcatObserver<T>;
begin
  Coord := TConcatObserver<T>.Create(AObserver, FSources);
  { Hold via Result before the synchronous sources run. }
  Result := Coord;
  Coord.SubscribeNext;
end;

{ TConcatObserver<T> }

constructor TConcatObserver<T>.Create(const ADown: IObserver<T>;
  const ASources: TArray<ISubscribable<T>>);
begin
  inherited Create;
  FDown := ADown;
  FSources := ASources;
  FIndex := 0;
  FDone := False;
end;

procedure TConcatObserver<T>.SubscribeNext;
var
  Obs: IObserver<T>;
begin
  if FDone then
    Exit;
  if FIndex > High(FSources) then
  begin
    FDone := True;
    FDown.OnComplete;
    Exit;
  end;
  Obs := TObserver<T>.Create(
    procedure(const V: T) begin FDown.OnNext(V); end,
    procedure(const E: Exception) begin FDown.OnError(E); end,
    procedure
    begin
      Inc(FIndex);
      SubscribeNext;
    end);
  FSources[FIndex].Subscribe(Obs);
end;

procedure TConcatObserver<T>.OnNext(const AValue: T);
begin
  FDown.OnNext(AValue);
end;

procedure TConcatObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TConcatObserver<T>.OnComplete;
begin
  if not FDone then
  begin
    FDone := True;
    FDown.OnComplete;
  end;
end;

procedure TConcatObserver<T>.Unsubscribe;
begin
  FDone := True;
end;

function TConcatObserver<T>.Closed: Boolean;
begin
  Result := FDone;
end;

{ TFlattenObserver<T,U> }

constructor TFlattenObserver<T, U>.Create(const ADown: IObserver<U>;
  const AProject: TStreamMapper<T, U>; const AMode: TFlattenMode);
begin
  inherited Create;
  FDown := ADown;
  FProject := AProject;
  FMode := AMode;
  FLock := TCriticalSection.Create;
  FSourceDone := False;
  FActive := 0;
  FCurrent := nil;
  FQueue := nil;
  FRunning := False;
end;

destructor TFlattenObserver<T, U>.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TFlattenObserver<T, U>.InnerNext(const AValue: U);
begin
  FDown.OnNext(AValue);
end;

procedure TFlattenObserver<T, U>.InnerDone;
var
  Done: Boolean;
begin
  FLock.Acquire;
  try
    Dec(FActive);
    Done := FSourceDone and (FActive = 0) and (Length(FQueue) = 0);
  finally
    FLock.Release;
  end;
  if Done then
    FDown.OnComplete
  else if FMode = fmConcat then
    DrainConcat;
end;

procedure TFlattenObserver<T, U>.SubscribeInner(const AInner: ISubscribable<U>);
var
  Obs: IObserver<U>;
begin
  FLock.Acquire;
  try
    Inc(FActive);
  finally
    FLock.Release;
  end;
  Obs := TObserver<U>.Create(
    procedure(const V: U) begin InnerNext(V); end,
    procedure(const E: Exception) begin FDown.OnError(E); end,
    procedure begin InnerDone; end);
  { The inner subscription is dropped; this library drives synchronous sources.
    A long-lived inner would need it retained for teardown. }
  AInner.Subscribe(Obs);
end;

procedure TFlattenObserver<T, U>.DrainConcat;
var
  Next: ISubscribable<U>;
  More: Boolean;
begin
  More := False;
  FLock.Acquire;
  try
    if (not FRunning) and (Length(FQueue) > 0) then
    begin
      Next := FQueue[0];
      FQueue := Copy(FQueue, 1, Length(FQueue) - 1);
      FRunning := True;
      More := True;
    end;
  finally
    FLock.Release;
  end;
  if More then
    SubscribeInner(Next);
end;

procedure TFlattenObserver<T, U>.OnNext(const AValue: T);
var
  Inner: ISubscribable<U>;
begin
  Inner := FProject(AValue);
  case FMode of
    fmSwitch:
      begin
        if FCurrent <> nil then
          FCurrent.Unsubscribe;
        { Count the inner before subscribing: a synchronous inner completes
          during Subscribe, so the count must be up first. (An async inner that
          is cancelled mid-flight is not decremented; the library drives
          synchronous sources, so inners settle before the next value.) }
        FLock.Acquire;
        try
          Inc(FActive);
        finally
          FLock.Release;
        end;
        FCurrent := Inner.Subscribe(TObserver<U>.Create(
          procedure(const V: U) begin InnerNext(V); end,
          procedure(const E: Exception) begin FDown.OnError(E); end,
          procedure begin InnerDone; end));
      end;
    fmConcat:
      begin
        FLock.Acquire;
        try
          SetLength(FQueue, Length(FQueue) + 1);
          FQueue[High(FQueue)] := Inner;
        finally
          FLock.Release;
        end;
        DrainConcat;
      end;
  else
    SubscribeInner(Inner);
  end;
end;

procedure TFlattenObserver<T, U>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TFlattenObserver<T, U>.OnComplete;
var
  Done: Boolean;
begin
  FLock.Acquire;
  try
    FSourceDone := True;
    Done := (FActive = 0) and (Length(FQueue) = 0);
  finally
    FLock.Release;
  end;
  if Done then
    FDown.OnComplete;
end;

{ TFlattenObservable<T,U> }

constructor TFlattenObservable<T, U>.Create(const ASource: ISubscribable<T>;
  const AProject: TStreamMapper<T, U>; const AMode: TFlattenMode);
begin
  inherited Create;
  FSource := ASource;
  FProject := AProject;
  FMode := AMode;
end;

function TFlattenObservable<T, U>.Subscribe(const AObserver: IObserver<U>): ISubscription;
begin
  Result := FSource.Subscribe(TFlattenObserver<T, U>.Create(AObserver, FProject, FMode));
end;

{ TZipCoordinator<T,U,V> }

constructor TZipCoordinator<T, U, V>.Create(const ADown: IObserver<V>;
  const ACombine: TCombiner<T, U, V>);
begin
  inherited Create;
  FDown := ADown;
  FCombine := ACombine;
  FLeft := nil;
  FRight := nil;
  FLeftDone := False;
  FRightDone := False;
  FClosed := False;
end;

procedure TZipCoordinator<T, U, V>.TryEmit;
begin
  while (Length(FLeft) > 0) and (Length(FRight) > 0) do
  begin
    FDown.OnNext(FCombine(FLeft[0], FRight[0]));
    FLeft := Copy(FLeft, 1, Length(FLeft) - 1);
    FRight := Copy(FRight, 1, Length(FRight) - 1);
  end;
  { A side that is done can never supply another value; the zip completes once
    BOTH sides are done (a value buffered on the still-live side has no partner).
    Requiring both avoids completing early when a synchronous source drains
    before the other side has even subscribed. }
  if FLeftDone and FRightDone and (not FClosed) then
  begin
    FClosed := True;
    FDown.OnComplete;
  end;
end;

procedure TZipCoordinator<T, U, V>.PushLeft(const AValue: T);
begin
  if FClosed then
    Exit;
  SetLength(FLeft, Length(FLeft) + 1);
  FLeft[High(FLeft)] := AValue;
  TryEmit;
end;

procedure TZipCoordinator<T, U, V>.PushRight(const AValue: U);
begin
  if FClosed then
    Exit;
  SetLength(FRight, Length(FRight) + 1);
  FRight[High(FRight)] := AValue;
  TryEmit;
end;

procedure TZipCoordinator<T, U, V>.LeftDone;
begin
  FLeftDone := True;
  TryEmit;
end;

procedure TZipCoordinator<T, U, V>.RightDone;
begin
  FRightDone := True;
  TryEmit;
end;

procedure TZipCoordinator<T, U, V>.Unsubscribe;
begin
  FClosed := True;
end;

function TZipCoordinator<T, U, V>.Closed: Boolean;
begin
  Result := FClosed;
end;

{ TZipLeftObserver<T,U,V> }

constructor TZipLeftObserver<T, U, V>.Create(const ACoord: TZipCoordinator<T, U, V>);
begin
  inherited Create;
  FCoord := ACoord;
end;

procedure TZipLeftObserver<T, U, V>.OnNext(const AValue: T);
begin
  FCoord.PushLeft(AValue);
end;

procedure TZipLeftObserver<T, U, V>.OnError(const AError: Exception);
begin
  AError.Free;
end;

procedure TZipLeftObserver<T, U, V>.OnComplete;
begin
  FCoord.LeftDone;
end;

{ TZipRightObserver<T,U,V> }

constructor TZipRightObserver<T, U, V>.Create(const ACoord: TZipCoordinator<T, U, V>);
begin
  inherited Create;
  FCoord := ACoord;
end;

procedure TZipRightObserver<T, U, V>.OnNext(const AValue: U);
begin
  FCoord.PushRight(AValue);
end;

procedure TZipRightObserver<T, U, V>.OnError(const AError: Exception);
begin
  AError.Free;
end;

procedure TZipRightObserver<T, U, V>.OnComplete;
begin
  FCoord.RightDone;
end;

{ TZipObservable<T,U,V> }

constructor TZipObservable<T, U, V>.Create(const ALeft: ISubscribable<T>;
  const ARight: ISubscribable<U>; const ACombine: TCombiner<T, U, V>);
begin
  inherited Create;
  FLeft := ALeft;
  FRight := ARight;
  FCombine := ACombine;
end;

function TZipObservable<T, U, V>.Subscribe(const AObserver: IObserver<V>): ISubscription;
var
  Zip: TZipCoordinator<T, U, V>;
begin
  Zip := TZipCoordinator<T, U, V>.Create(AObserver, FCombine);
  FLeft.Subscribe(TZipLeftObserver<T, U, V>.Create(Zip));
  FRight.Subscribe(TZipRightObserver<T, U, V>.Create(Zip));
  Result := Zip;
end;

{ TReduceObserver<T,A> }

constructor TReduceObserver<T, A>.Create(const ADown: IObserver<A>; const ASeed: A;
  const AReducer: TReducer<T, A>);
begin
  inherited Create;
  FDown := ADown;
  FAcc := ASeed;
  FReducer := AReducer;
end;

procedure TReduceObserver<T, A>.OnNext(const AValue: T);
begin
  FAcc := FReducer(FAcc, AValue);
end;

procedure TReduceObserver<T, A>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TReduceObserver<T, A>.OnComplete;
begin
  FDown.OnNext(FAcc);
  FDown.OnComplete;
end;

{ TReduceObservable<T,A> }

constructor TReduceObservable<T, A>.Create(const ASource: ISubscribable<T>;
  const ASeed: A; const AReducer: TReducer<T, A>);
begin
  inherited Create;
  FSource := ASource;
  FSeed := ASeed;
  FReducer := AReducer;
end;

function TReduceObservable<T, A>.Subscribe(const AObserver: IObserver<A>): ISubscription;
begin
  Result := FSource.Subscribe(TReduceObserver<T, A>.Create(AObserver, FSeed, FReducer));
end;

{ TPairwiseObserver<T,U> }

constructor TPairwiseObserver<T, U>.Create(const ADown: IObserver<U>;
  const APair: TPairMapper<T, U>);
begin
  inherited Create;
  FDown := ADown;
  FPair := APair;
  FHasPrev := False;
end;

procedure TPairwiseObserver<T, U>.OnNext(const AValue: T);
begin
  if FHasPrev then
    FDown.OnNext(FPair(FPrev, AValue));
  FPrev := AValue;
  FHasPrev := True;
end;

procedure TPairwiseObserver<T, U>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TPairwiseObserver<T, U>.OnComplete;
begin
  FDown.OnComplete;
end;

{ TPairwiseObservable<T,U> }

constructor TPairwiseObservable<T, U>.Create(const ASource: ISubscribable<T>;
  const APair: TPairMapper<T, U>);
begin
  inherited Create;
  FSource := ASource;
  FPair := APair;
end;

function TPairwiseObservable<T, U>.Subscribe(const AObserver: IObserver<U>): ISubscription;
begin
  Result := FSource.Subscribe(TPairwiseObserver<T, U>.Create(AObserver, FPair));
end;

{ TTapObserver<T> }

constructor TTapObserver<T>.Create(const ADown: IObserver<T>; const AAction: TAction<T>);
begin
  inherited Create;
  FDown := ADown;
  FAction := AAction;
end;

procedure TTapObserver<T>.OnNext(const AValue: T);
begin
  FAction(AValue);
  FDown.OnNext(AValue);
end;

procedure TTapObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TTapObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

{ TIgnoreObserver<T> }

constructor TIgnoreObserver<T>.Create(const ADown: IObserver<T>);
begin
  inherited Create;
  FDown := ADown;
end;
procedure TIgnoreObserver<T>.OnNext(const AValue: T);
begin
  { dropped }
end;

procedure TIgnoreObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TIgnoreObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

{ TTapObservable<T> }

constructor TTapObservable<T>.Create(const ASource: ISubscribable<T>; const AAction: TAction<T>);
begin
  inherited Create;
  FSource := ASource;
  FAction := AAction;
end;

function TTapObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TTapObserver<T>.Create(AObserver, FAction));
end;

{ TIgnoreObservable<T> }

constructor TIgnoreObservable<T>.Create(const ASource: ISubscribable<T>);
begin
  inherited Create;
  FSource := ASource;
end;

function TIgnoreObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TIgnoreObserver<T>.Create(AObserver));
end;

{ TStartWithObservable<T> }

constructor TStartWithObservable<T>.Create(const ASource: ISubscribable<T>; const AValue: T);
begin
  inherited Create;
  FSource := ASource;
  FValue := AValue;
end;

function TStartWithObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  AObserver.OnNext(FValue);
  Result := FSource.Subscribe(AObserver);
end;

{ TEndWithObserver<T> }

constructor TEndWithObserver<T>.Create(const ADown: IObserver<T>; const AValue: T);
begin
  inherited Create;
  FDown := ADown;
  FValue := AValue;
end;

procedure TEndWithObserver<T>.OnNext(const AValue: T);
begin
  FDown.OnNext(AValue);
end;

procedure TEndWithObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TEndWithObserver<T>.OnComplete;
begin
  FDown.OnNext(FValue);
  FDown.OnComplete;
end;

{ TEndWithObservable<T> }

constructor TEndWithObservable<T>.Create(const ASource: ISubscribable<T>; const AValue: T);
begin
  inherited Create;
  FSource := ASource;
  FValue := AValue;
end;

function TEndWithObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TEndWithObserver<T>.Create(AObserver, FValue));
end;

{ TDistinctAllObserver<T> }

constructor TDistinctAllObserver<T>.Create(const ADown: IObserver<T>;
  const AEquals: TEquality<T>);
begin
  inherited Create;
  FDown := ADown;
  FEquals := AEquals;
  FSeen := nil;
end;

procedure TDistinctAllObserver<T>.OnNext(const AValue: T);
var
  I: Integer;
begin
  for I := 0 to High(FSeen) do
    if FEquals(FSeen[I], AValue) then
      Exit;
  SetLength(FSeen, Length(FSeen) + 1);
  FSeen[High(FSeen)] := AValue;
  FDown.OnNext(AValue);
end;

procedure TDistinctAllObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TDistinctAllObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

{ TDistinctAllObservable<T> }

constructor TDistinctAllObservable<T>.Create(const ASource: ISubscribable<T>;
  const AEquals: TEquality<T>);
begin
  inherited Create;
  FSource := ASource;
  FEquals := AEquals;
end;

function TDistinctAllObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TDistinctAllObserver<T>.Create(AObserver, FEquals));
end;

{ TLastObserver<T> }

constructor TLastObserver<T>.Create(const ADown: IObserver<T>);
begin
  inherited Create;
  FDown := ADown;
  FHas := False;
end;

procedure TLastObserver<T>.OnNext(const AValue: T);
begin
  FLast := AValue;
  FHas := True;
end;

procedure TLastObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TLastObserver<T>.OnComplete;
begin
  if FHas then
    FDown.OnNext(FLast);
  FDown.OnComplete;
end;

{ TLastObservable<T> }

constructor TLastObservable<T>.Create(const ASource: ISubscribable<T>);
begin
  inherited Create;
  FSource := ASource;
end;

function TLastObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TLastObserver<T>.Create(AObserver));
end;

{ TCountObserver<T> }

constructor TCountObserver<T>.Create(const ADown: IObserver<Integer>);
begin
  inherited Create;
  FDown := ADown;
  FN := 0;
end;

procedure TCountObserver<T>.OnNext(const AValue: T);
begin
  Inc(FN);
end;

procedure TCountObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
end;

procedure TCountObserver<T>.OnComplete;
begin
  FDown.OnNext(FN);
  FDown.OnComplete;
end;

{ TCountObservable<T> }

constructor TCountObservable<T>.Create(const ASource: ISubscribable<T>);
begin
  inherited Create;
  FSource := ASource;
end;

function TCountObservable<T>.Subscribe(const AObserver: IObserver<Integer>): ISubscription;
begin
  Result := FSource.Subscribe(TCountObserver<T>.Create(AObserver));
end;

{ TCatchObserver<T> }

constructor TCatchObserver<T>.Create(const ADown: IObserver<T>;
  const AHandler: TErrorMapper<T>);
begin
  inherited Create;
  FDown := ADown;
  FHandler := AHandler;
  FHandled := False;
end;

procedure TCatchObserver<T>.OnNext(const AValue: T);
begin
  FDown.OnNext(AValue);
end;

procedure TCatchObserver<T>.OnError(const AError: Exception);
var
  Fallback: ISubscribable<T>;
begin
  if FHandled then
  begin
    FDown.OnError(AError);
    Exit;
  end;
  FHandled := True;
  Fallback := FHandler(AError);
  Fallback.Subscribe(FDown);
end;

procedure TCatchObserver<T>.OnComplete;
begin
  FDown.OnComplete;
end;

{ TCatchObservable<T> }

constructor TCatchObservable<T>.Create(const ASource: ISubscribable<T>;
  const AHandler: TErrorMapper<T>);
begin
  inherited Create;
  FSource := ASource;
  FHandler := AHandler;
end;

function TCatchObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TCatchObserver<T>.Create(AObserver, FHandler));
end;

{ TFinalizeObserver<T> }

constructor TFinalizeObserver<T>.Create(const ADown: IObserver<T>; const AAction: TAction0);
begin
  inherited Create;
  FDown := ADown;
  FAction := AAction;
  FRan := False;
end;

procedure TFinalizeObserver<T>.RunOnce;
begin
  if not FRan then
  begin
    FRan := True;
    if Assigned(FAction) then
      FAction();
  end;
end;

procedure TFinalizeObserver<T>.OnNext(const AValue: T);
begin
  FDown.OnNext(AValue);
end;

procedure TFinalizeObserver<T>.OnError(const AError: Exception);
begin
  FDown.OnError(AError);
  RunOnce;
end;

procedure TFinalizeObserver<T>.OnComplete;
begin
  FDown.OnComplete;
  RunOnce;
end;

{ TFinalizeObservable<T> }

constructor TFinalizeObservable<T>.Create(const ASource: ISubscribable<T>;
  const AAction: TAction0);
begin
  inherited Create;
  FSource := ASource;
  FAction := AAction;
end;

function TFinalizeObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
begin
  Result := FSource.Subscribe(TFinalizeObserver<T>.Create(AObserver, FAction));
end;

{ TRetryObservable<T> }

constructor TRetryObservable<T>.Create(const ASource: ISubscribable<T>;
  const ACount: Integer);
begin
  inherited Create;
  FSource := ASource;
  FCount := ACount;
end;

function TRetryObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Attempts: Integer;
  Fwd: IObserver<T>;
begin
  Attempts := 0;
  Fwd := TObserver<T>.Create(
    procedure(const V: T) begin AObserver.OnNext(V); end,
    procedure(const E: Exception)
    begin
      if Attempts < FCount then
      begin
        Inc(Attempts);
        FSource.Subscribe(Fwd);
      end
      else
        AObserver.OnError(E);
    end,
    procedure begin AObserver.OnComplete; end);
  FSource.Subscribe(Fwd);
  Result := TClosureSubscription.Create(nil);
end;

{ TCombineLatestCoordinator<T,U,V> }

constructor TCombineLatestCoordinator<T, U, V>.Create(const ADown: IObserver<V>;
  const ACombine: TCombiner<T, U, V>);
begin
  inherited Create;
  FDown := ADown;
  FCombine := ACombine;
  FHasT := False;
  FHasU := False;
  FClosed := False;
  FTDone := False;
  FUDone := False;
end;

procedure TCombineLatestCoordinator<T, U, V>.TryEmit;
begin
  if FHasT and FHasU and (not FClosed) then
    FDown.OnNext(FCombine(FLastT, FLastU));
end;

procedure TCombineLatestCoordinator<T, U, V>.PushT(const AValue: T);
begin
  FLastT := AValue;
  FHasT := True;
  TryEmit;
end;

procedure TCombineLatestCoordinator<T, U, V>.PushU(const AValue: U);
begin
  FLastU := AValue;
  FHasU := True;
  TryEmit;
end;

procedure TCombineLatestCoordinator<T, U, V>.TDone;
begin
  FTDone := True;
  if FUDone and (not FClosed) then
  begin
    FClosed := True;
    FDown.OnComplete;
  end;
end;

procedure TCombineLatestCoordinator<T, U, V>.UDone;
begin
  FUDone := True;
  if FTDone and (not FClosed) then
  begin
    FClosed := True;
    FDown.OnComplete;
  end;
end;

procedure TCombineLatestCoordinator<T, U, V>.Unsubscribe;
begin
  FClosed := True;
end;

function TCombineLatestCoordinator<T, U, V>.Closed: Boolean;
begin
  Result := FClosed;
end;

{ TCLTObserverT<T,U,V> }

constructor TCLTObserverT<T, U, V>.Create(const AC: TCombineLatestCoordinator<T, U, V>);
begin
  inherited Create;
  FC := AC;
end;

procedure TCLTObserverT<T, U, V>.OnNext(const AValue: T);
begin
  FC.PushT(AValue);
end;

procedure TCLTObserverT<T, U, V>.OnError(const AError: Exception);
begin
  AError.Free;
end;

procedure TCLTObserverT<T, U, V>.OnComplete;
begin
  FC.TDone;
end;

{ TCLTObserverU<T,U,V> }

constructor TCLTObserverU<T, U, V>.Create(const AC: TCombineLatestCoordinator<T, U, V>);
begin
  inherited Create;
  FC := AC;
end;

procedure TCLTObserverU<T, U, V>.OnNext(const AValue: U);
begin
  FC.PushU(AValue);
end;

procedure TCLTObserverU<T, U, V>.OnError(const AError: Exception);
begin
  AError.Free;
end;

procedure TCLTObserverU<T, U, V>.OnComplete;
begin
  FC.UDone;
end;

{ TCombineLatestObservable<T,U,V> }

constructor TCombineLatestObservable<T, U, V>.Create(const ALeft: ISubscribable<T>;
  const ARight: ISubscribable<U>; const ACombine: TCombiner<T, U, V>);
begin
  inherited Create;
  FLeft := ALeft;
  FRight := ARight;
  FCombine := ACombine;
end;

function TCombineLatestObservable<T, U, V>.Subscribe(const AObserver: IObserver<V>): ISubscription;
var
  C: TCombineLatestCoordinator<T, U, V>;
begin
  C := TCombineLatestCoordinator<T, U, V>.Create(AObserver, FCombine);
  Result := C;
  FLeft.Subscribe(TCLTObserverT<T, U, V>.Create(C));
  FRight.Subscribe(TCLTObserverU<T, U, V>.Create(C));
end;

{ TMapOperator<T,U> }

constructor TMapOperator<T, U>.Create(const AMapper: TMapper<T, U>);
begin
  inherited Create;
  FMapper := AMapper;
end;

function TMapOperator<T, U>.Apply(const A: ISubscribable<T>): ISubscribable<U>;
begin
  Result := Map<T, U>(A, FMapper);
end;

{ TScanOperator<T> }

constructor TScanOperator<T>.Create(const ASeed: T; const AAccumulator: TAccumulator<T>);
begin
  inherited Create;
  FSeed := ASeed;
  FAccumulator := AAccumulator;
end;

function TScanOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := Scan<T>(A, FSeed, FAccumulator);
end;

{ TTapOperator<T> }

constructor TTapOperator<T>.Create(const AAction: TAction<T>);
begin
  inherited Create;
  FAction := AAction;
end;

function TTapOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := Tap<T>(A, FAction);
end;

{ TDistinctAllOperator<T> }

constructor TDistinctAllOperator<T>.Create(const AEquals: TEquality<T>);
begin
  inherited Create;
  FEquals := AEquals;
end;

function TDistinctAllOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := Distinct<T>(A, FEquals);
end;

{ TIgnoreOperator<T> }

function TIgnoreOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := IgnoreElements<T>(A);
end;

{ TLastOperator<T> }

function TLastOperator<T>.Apply(const A: ISubscribable<T>): ISubscribable<T>;
begin
  Result := Last<T>(A);
end;

{ The extra free-function operators }

function Tap<T>(const ASource: ISubscribable<T>; const AAction: TAction<T>): ISubscribable<T>;
begin
  Result := TTapObservable<T>.Create(ASource, AAction);
end;

function IgnoreElements<T>(const ASource: ISubscribable<T>): ISubscribable<T>;
begin
  Result := TIgnoreObservable<T>.Create(ASource);
end;

function StartWith<T>(const ASource: ISubscribable<T>; const AValue: T): ISubscribable<T>;
begin
  Result := TStartWithObservable<T>.Create(ASource, AValue);
end;

function EndWith<T>(const ASource: ISubscribable<T>; const AValue: T): ISubscribable<T>;
begin
  Result := TEndWithObservable<T>.Create(ASource, AValue);
end;

function Distinct<T>(const ASource: ISubscribable<T>; const AEquals: TEquality<T>): ISubscribable<T>;
begin
  Result := TDistinctAllObservable<T>.Create(ASource, AEquals);
end;

function Last<T>(const ASource: ISubscribable<T>): ISubscribable<T>;
begin
  Result := TLastObservable<T>.Create(ASource);
end;

function Count<T>(const ASource: ISubscribable<T>): ISubscribable<Integer>;
begin
  Result := TCountObservable<T>.Create(ASource);
end;

function CatchError<T>(const ASource: ISubscribable<T>;
  const AHandler: TErrorMapper<T>): ISubscribable<T>;
begin
  Result := TCatchObservable<T>.Create(ASource, AHandler);
end;

function Finalize<T>(const ASource: ISubscribable<T>; const AAction: TAction0): ISubscribable<T>;
begin
  Result := TFinalizeObservable<T>.Create(ASource, AAction);
end;

function Retry<T>(const ASource: ISubscribable<T>; const ACount: Integer): ISubscribable<T>;
begin
  Result := TRetryObservable<T>.Create(ASource, ACount);
end;

function CombineLatest<T, U, V>(const ALeft: ISubscribable<T>;
  const ARight: ISubscribable<U>; const ACombine: TCombiner<T, U, V>): ISubscribable<V>;
begin
  Result := TCombineLatestObservable<T, U, V>.Create(ALeft, ARight, ACombine);
end;

function Race<T>(const ASources: TArray<ISubscribable<T>>): ISubscribable<T>;
var
  First: ISubscribable<T>;
begin
  { A synchronous approximation: the first source's values win, since a
    synchronous source completes before the next is subscribed. A true race
    needs the sources to overlap in time. }
  if Length(ASources) = 0 then
    Exit(Empty<T>);
  First := ASources[0];
  Result := First;
end;

function MapOp<T, U>(const AMapper: TMapper<T, U>): IMapOperator<T, U>;
begin
  Result := TMapOperator<T, U>.Create(AMapper);
end;

function ScanOp<T>(const ASeed: T; const AAccumulator: TAccumulator<T>): IOperator<T>;
begin
  Result := TScanOperator<T>.Create(ASeed, AAccumulator);
end;

function TapOp<T>(const AAction: TAction<T>): IOperator<T>;
begin
  Result := TTapOperator<T>.Create(AAction);
end;

function DistinctOp<T>(const AEquals: TEquality<T>): IOperator<T>;
begin
  Result := TDistinctAllOperator<T>.Create(AEquals);
end;

function IgnoreElementsOp<T>: IOperator<T>;
begin
  Result := TIgnoreOperator<T>.Create;
end;

function LastOp<T>: IOperator<T>;
begin
  Result := TLastOperator<T>.Create;
end;

end.
