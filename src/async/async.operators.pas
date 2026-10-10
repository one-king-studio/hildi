unit async.operators;
{ Operators: pure functions ISubscribable<T> -> ISubscribable<U>, each lazily
  subscribing to its source when the result is subscribed.

  FPC 3.3.1's generic support is too incomplete for the idiomatic implementation
  (a generic method that builds an anonymous function capturing its type
  parameter, or that returns a concrete generic type, is an internal compiler
  error). The one shape PROVEN to compile is: concrete observer and concrete
  observable CLASSES, and a generic METHOD on a single NON-generic class that
  only constructs those classes (no closure).

  So every operator is TStreamOps.<Op> with a matching concrete class pair:
    TStreamOps.Map<Integer,string>(src, mapper)
    TStreamOps.Filter<Integer>(src, predicate)
  The call sites compose cleanly even though each operator carries two small
  helper classes.

  Still blocked (generic-inside-generic is forbidden): operators returning
  ISubscribable<TArray<T>> / ISubscribable<ISubscribable<...>> - Buffer, Window,
  GroupBy, Partition, Pairwise, and the flattening family. Deferred.

  This library has NO dependency on the harness or any engine unit - it must stay
  extractable. See docs/features/Async_Core/Async_Core_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils,
  async.base, async.observable;

type
  TPredicate<T> = reference to function(const AValue: T): Boolean;
  TAccumulator<T> = reference to function(const AAcc, AValue: T): T;
  TEquality<T> = reference to function(const A, B: T): Boolean;
  TDeferFactory<T> = reference to function: ISubscribable<T>;

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

  { The operator surface: generic METHODS on a non-generic class, each only
    constructing a concrete observable (the one shape FPC 3.3.1 compiles). }
  TStreamOps = class
    class function Just<T>(const AValue: T): ISubscribable<T>;
    class function FromArray<T>(const AValues: TArray<T>): ISubscribable<T>;
    class function Range(AStart, ACount: Integer): ISubscribable<Integer>;
    class function Empty<T>: ISubscribable<T>;
    class function ThrowError<T>(const AError: Exception): ISubscribable<T>;
    class function Defer<T>(const AFactory: TDeferFactory<T>): ISubscribable<T>;
    class function Map<T, U>(const ASource: ISubscribable<T>;
      const AMapper: TMapper<T, U>): ISubscribable<U>;
    class function Scan<T>(const ASource: ISubscribable<T>; const ASeed: T;
      const AAccumulator: TAccumulator<T>): ISubscribable<T>;
    class function Filter<T>(const ASource: ISubscribable<T>;
      const APredicate: TPredicate<T>): ISubscribable<T>;
    class function Take<T>(const ASource: ISubscribable<T>;
      const ACount: Integer): ISubscribable<T>;
    class function Skip<T>(const ASource: ISubscribable<T>;
      const ACount: Integer): ISubscribable<T>;
    class function TakeWhile<T>(const ASource: ISubscribable<T>;
      const APredicate: TPredicate<T>): ISubscribable<T>;
    class function SkipWhile<T>(const ASource: ISubscribable<T>;
      const APredicate: TPredicate<T>): ISubscribable<T>;
    class function DistinctUntilChanged<T>(const ASource: ISubscribable<T>;
      const AEquals: TEquality<T>): ISubscribable<T>;
    class function First<T>(const ASource: ISubscribable<T>): ISubscribable<T>;
    class function ElementAt<T>(const ASource: ISubscribable<T>;
      const AIndex: Integer): ISubscribable<T>;
  end;

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

{ TStreamOps }

class function TStreamOps.Just<T>(const AValue: T): ISubscribable<T>;
begin
  Result := TJustObservable<T>.Create(AValue);
end;

class function TStreamOps.FromArray<T>(const AValues: TArray<T>): ISubscribable<T>;
begin
  Result := TFromArrayObservable<T>.Create(AValues);
end;

class function TStreamOps.Range(AStart, ACount: Integer): ISubscribable<Integer>;
begin
  Result := TRangeObservable.Create(AStart, ACount);
end;

class function TStreamOps.Empty<T>: ISubscribable<T>;
begin
  Result := TEmptyObservable<T>.Create;
end;

class function TStreamOps.ThrowError<T>(const AError: Exception): ISubscribable<T>;
begin
  Result := TThrowObservable<T>.Create(AError);
end;

class function TStreamOps.Defer<T>(const AFactory: TDeferFactory<T>): ISubscribable<T>;
begin
  Result := TDeferObservable<T>.Create(AFactory);
end;

class function TStreamOps.Map<T, U>(const ASource: ISubscribable<T>;
  const AMapper: TMapper<T, U>): ISubscribable<U>;
begin
  Result := TMapObservable<T, U>.Create(ASource, AMapper);
end;

class function TStreamOps.Scan<T>(const ASource: ISubscribable<T>; const ASeed: T;
  const AAccumulator: TAccumulator<T>): ISubscribable<T>;
begin
  Result := TScanObservable<T>.Create(ASource, ASeed, AAccumulator);
end;

class function TStreamOps.Filter<T>(const ASource: ISubscribable<T>;
  const APredicate: TPredicate<T>): ISubscribable<T>;
begin
  Result := TFilterObservable<T>.Create(ASource, APredicate);
end;

class function TStreamOps.Take<T>(const ASource: ISubscribable<T>;
  const ACount: Integer): ISubscribable<T>;
begin
  Result := TTakeObservable<T>.Create(ASource, ACount);
end;

class function TStreamOps.Skip<T>(const ASource: ISubscribable<T>;
  const ACount: Integer): ISubscribable<T>;
begin
  Result := TSkipObservable<T>.Create(ASource, ACount);
end;

class function TStreamOps.TakeWhile<T>(const ASource: ISubscribable<T>;
  const APredicate: TPredicate<T>): ISubscribable<T>;
begin
  Result := TTakeWhileObservable<T>.Create(ASource, APredicate);
end;

class function TStreamOps.SkipWhile<T>(const ASource: ISubscribable<T>;
  const APredicate: TPredicate<T>): ISubscribable<T>;
begin
  Result := TSkipWhileObservable<T>.Create(ASource, APredicate);
end;

class function TStreamOps.DistinctUntilChanged<T>(const ASource: ISubscribable<T>;
  const AEquals: TEquality<T>): ISubscribable<T>;
begin
  Result := TDistinctObservable<T>.Create(ASource, AEquals);
end;

class function TStreamOps.First<T>(const ASource: ISubscribable<T>): ISubscribable<T>;
begin
  Result := TTakeObservable<T>.Create(ASource, 1);
end;

class function TStreamOps.ElementAt<T>(const ASource: ISubscribable<T>;
  const AIndex: Integer): ISubscribable<T>;
begin
  Result := TTakeObservable<T>.Create(TSkipObservable<T>.Create(ASource, AIndex), 1);
end;

end.
