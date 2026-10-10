unit async.base;
{ The Async Core spine: the shared types every other unit builds on.

  This library has NO dependency on the harness or any engine unit - it must stay
  extractable. See docs/features/Async_Core/Async_Core_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, SyncObjs, Generics.Collections;

type
  { A value-less completion. }
  TUnit = record end;

  { A continuation: a bound method to run later. }
  TNotify = procedure of object;

  { A parameterless anonymous callback (a `reference to`), so an inline closure
    matches it even inside a class method (where an anonymous procedure is a
    "class anonymous procedure", not a `procedure of object`). }
  TAction0 = reference to procedure;

  { Generic delegates. FPC forbids a generic method inside a generic class, so
    these are declared here and operators are free functions over them. }
  TAction<T> = reference to procedure(const AValue: T);
  TMapper<T, U> = reference to function(const AValue: T): U;
  TProducer<T> = reference to function: T;
  TFactory<T> = reference to function(const AError: Exception): T;

  { A cancellable handle on work. Unsubscribe is idempotent and safe after the
    work has already run. }
  ISubscription = interface
    procedure Unsubscribe;
    function Closed: Boolean;
  end;

  { A one-shot cancellation signal. }
  ICancellationToken = interface
    function IsCancelled: Boolean;
    procedure OnCancel(const AAction: TNotify);
  end;

  { A subscription that runs its teardown action exactly once, when first
    unsubscribed. Dropping the last reference does NOT run it (only an explicit
    Unsubscribe does). }
  TSubscription = class(TInterfacedObject, ISubscription)
  private
    FLock: TCriticalSection;
    FClosed: Boolean;
    FOnUnsubscribe: TNotify;
  public
    constructor Create(const AOnUnsubscribe: TNotify = nil);
    destructor Destroy; override;
    procedure Unsubscribe;
    function Closed: Boolean;
  end;

  { A one-shot cancellation source and the token it hands out. Cancel runs every
    registered action once, in registration order; an action registered after
    cancellation runs immediately. }
  TCancellationSource = class(TInterfacedObject, ICancellationToken)
  private
    FLock: TCriticalSection;
    FCancelled: Boolean;
    FActions: TList<TNotify>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Cancel;
    function IsCancelled: Boolean;
    procedure OnCancel(const AAction: TNotify);
  end;

  { A tiny lock-free spinlock. Unlike a TCriticalSection it needs no heap
    allocation, which matters on a per-job / per-future hot path. Acquire spins
    on InterlockedExchange until it observes 0, then leaves 1. It is a LOCK
    (never a barrier on a single thread): hold it only for a few instructions.
    On a single-threaded program Acquire is uncontended and returns at once. }
  TSpinLock = record
  private
    FLocked: Integer;
  public
    { A record has no constructor here; call Init once (a fresh local is already
      zeroed, but be explicit). }
    procedure Init;
    procedure Acquire;
    procedure Release;
  end;

implementation

{ TSpinLock }

procedure TSpinLock.Init;
begin
  FLocked := 0;
end;

procedure TSpinLock.Acquire;
begin
  while InterlockedExchange(FLocked, 1) <> 0 do
    ;   { spin: the holder is about to Release }
end;

procedure TSpinLock.Release;
begin
  InterlockedExchange(FLocked, 0);
end;

{ TSubscription }

constructor TSubscription.Create(const AOnUnsubscribe: TNotify);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FOnUnsubscribe := AOnUnsubscribe;
end;

destructor TSubscription.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TSubscription.Unsubscribe;
var
  Action: TNotify;
begin
  FLock.Acquire;
  try
    if FClosed then
      Exit;
    FClosed := True;
    Action := FOnUnsubscribe;
    FOnUnsubscribe := nil;
  finally
    FLock.Release;
  end;
  if Assigned(Action) then
    Action();
end;

function TSubscription.Closed: Boolean;
begin
  Result := FClosed;
end;

{ TCancellationSource }

constructor TCancellationSource.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FActions := TList<TNotify>.Create;
end;

destructor TCancellationSource.Destroy;
begin
  FActions.Free;
  FLock.Free;
  inherited;
end;

function TCancellationSource.IsCancelled: Boolean;
begin
  Result := FCancelled;
end;

procedure TCancellationSource.OnCancel(const AAction: TNotify);
var
  RunNow: Boolean;
begin
  RunNow := False;
  FLock.Acquire;
  try
    if FCancelled then
      RunNow := True
    else
      FActions.Add(AAction);
  finally
    FLock.Release;
  end;
  if RunNow then
    AAction();
end;

procedure TCancellationSource.Cancel;
var
  Actions: TArray<TNotify>;
  I: Integer;
begin
  FLock.Acquire;
  try
    if FCancelled then
      Exit;
    FCancelled := True;
    Actions := FActions.ToArray;
    FActions.Clear;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Actions) do
    Actions[I]();
end;

end.
