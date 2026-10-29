unit AsyncBase;
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
    { Trip the token. Idempotent. }
    procedure Cancel;
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

  { A lock-free cancellation token. Cancel and IsCancelled are a single
    InterlockedExchange/read, so a worker polling IsCancelled pays no lock. }
  TSpinFreeCancellation = class(TInterfacedObject, ICancellationToken)
  private
    FCancelled: Integer;
  public
    procedure Cancel;
    function IsCancelled: Boolean;
    procedure OnCancel(const AAction: TNotify);
  end;

implementation

{ TSpinFreeCancellation }

procedure TSpinFreeCancellation.Cancel;
begin
  InterlockedExchange(FCancelled, 1);
end;

function TSpinFreeCancellation.IsCancelled: Boolean;
begin
  Result := FCancelled <> 0;
end;

procedure TSpinFreeCancellation.OnCancel(const AAction: TNotify);
begin
  { Best-effort: run now if already cancelled; otherwise the token has no
    callback list (a poller checks IsCancelled). }
  if IsCancelled then
    AAction();
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
