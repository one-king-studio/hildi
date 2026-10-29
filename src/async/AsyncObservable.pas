unit AsyncObservable;
{ TObservable<T>: a lazy, cancellable stream of zero or more values, then exactly
  one terminal notification (complete or error) - the front the spec calls "a
  stream of values", sharing the spine with TFuture<T>.

  Subscribe runs the source (cold): two subscribers run it twice. The returned
  ISubscription tears down downstream and upstream. A terminal notification
  closes the subscription; a late OnNext is ignored. Errors are delivered as
  OnError, never raised into the producer.

  This library has NO dependency on the harness or any engine unit - it must stay
  extractable. See docs/features/Async_Core/Async_Core_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, SyncObjs,
  AsyncBase, AsyncScheduler;

type
  { The receiving end of a stream. At most one of OnError/OnComplete is called,
    and no OnNext after it. }
  IObserver<T> = interface
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  { A source of values: Subscribe runs it and returns the teardown handle. }
  ISubscribable<T> = interface
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  { The source function behind a concrete TObservable: wire the stream to the
    observer and return its teardown. Called once per subscriber (cold). }
  TSubscribeProc<T> = reference to function(
    const AObserver: IObserver<T>): ISubscription;

  { A safe observer: forwards to a downstream observer but enforces the contract
    - at most one terminal notification and no OnNext after it. It owns the
      upstream subscription and tears it down on terminal or Unsubscribe. }
  TSubscriber<T> = class(TInterfacedObject, IObserver<T>, ISubscription)
  private
    FLock: TCriticalSection;
    FDownstream: IObserver<T>;
    FUpstream: ISubscription;
    FClosed: Boolean;
    FUpstreamSet: Boolean;
  public
    constructor Create(const ADownstream: IObserver<T>);
    destructor Destroy; override;
    { Given the upstream teardown once the source's Subscribe returns. If the
      source already terminated synchronously, the upstream is torn down now. }
    procedure SetUpstream(const AUpstream: ISubscription);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
    procedure Unsubscribe;
    function Closed: Boolean;
  end;

  { A concrete lazy observable built from a subscribe function. }
  TObservable<T> = class(TInterfacedObject, ISubscribable<T>)
  private
    FSubscribe: TSubscribeProc<T>;
  public
    constructor Create(const ASubscribe: TSubscribeProc<T>);
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
  end;

  { A plain observer from delegates, for ergonomics; any may be nil. }
  TObserver<T> = class(TInterfacedObject, IObserver<T>)
  private
    FOnNext: TAction<T>;
    FOnError: TAction<Exception>;
    FOnComplete: TAction0;
  public
    constructor Create(const AOnNext: TAction<T>;
      const AOnError: TAction<Exception> = nil;
      const AOnComplete: TAction0 = nil);
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  { A teardown closure, so a source can return a subscription that captures what
    it must remove. }
  TUnsubscriber = reference to procedure;

  { A subscription that runs a closure once, when first unsubscribed. }
  TClosureSubscription = class(TInterfacedObject, ISubscription)
  private
    FLock: TCriticalSection;
    FClosed: Boolean;
    FAction: TUnsubscriber;
  public
    constructor Create(const AAction: TUnsubscriber);
    destructor Destroy; override;
    procedure Unsubscribe;
    function Closed: Boolean;
  end;

implementation

{ TSubscriber<T> }

constructor TSubscriber<T>.Create(const ADownstream: IObserver<T>);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FDownstream := ADownstream;
  FClosed := False;
  FUpstreamSet := False;
end;

destructor TSubscriber<T>.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TSubscriber<T>.SetUpstream(const AUpstream: ISubscription);
var
  ClosedNow: Boolean;
begin
  ClosedNow := False;
  FLock.Acquire;
  try
    if FUpstreamSet then
      Exit;
    FUpstream := AUpstream;
    FUpstreamSet := True;
    ClosedNow := FClosed;
  finally
    FLock.Release;
  end;
  { A synchronous source may have already terminated; tear its upstream down. }
  if ClosedNow and (AUpstream <> nil) then
    AUpstream.Unsubscribe;
end;

procedure TSubscriber<T>.OnNext(const AValue: T);
var
  Go: Boolean;
begin
  FLock.Acquire;
  try
    Go := not FClosed;
  finally
    FLock.Release;
  end;
  if Go then
    FDownstream.OnNext(AValue);
end;

procedure TSubscriber<T>.OnError(const AError: Exception);
var
  Go: Boolean;
  Down: IObserver<T>;
  Up: ISubscription;
begin
  FLock.Acquire;
  try
    Go := not FClosed;
    if Go then
    begin
      FClosed := True;
      Down := FDownstream;
      Up := FUpstream;
      { Break the subscriber<->operator-observer cycle, or the chain never
        reaches a zero refcount. }
      FDownstream := nil;
      FUpstream := nil;
    end;
  finally
    FLock.Release;
  end;
  if Go then
  begin
    Down.OnError(AError);
    if Up <> nil then
      Up.Unsubscribe;
  end
  else
    { The contract is already broken; the error is the caller's to free, but a
      dropped error would leak, so free it here. }
    AError.Free;
end;

procedure TSubscriber<T>.OnComplete;
var
  Go: Boolean;
  Down: IObserver<T>;
  Up: ISubscription;
begin
  FLock.Acquire;
  try
    Go := not FClosed;
    if Go then
    begin
      FClosed := True;
      Down := FDownstream;
      Up := FUpstream;
      FDownstream := nil;
      FUpstream := nil;
    end;
  finally
    FLock.Release;
  end;
  if Go then
  begin
    Down.OnComplete;
    if Up <> nil then
      Up.Unsubscribe;
  end;
end;

procedure TSubscriber<T>.Unsubscribe;
var
  Go: Boolean;
  Up: ISubscription;
begin
  FLock.Acquire;
  try
    Go := not FClosed;
    FClosed := True;
    Up := FUpstream;
    FDownstream := nil;
    FUpstream := nil;
  finally
    FLock.Release;
  end;
  if Go and (Up <> nil) then
    Up.Unsubscribe;
end;

function TSubscriber<T>.Closed: Boolean;
begin
  Result := FClosed;
end;

{ TObservable<T> }

constructor TObservable<T>.Create(const ASubscribe: TSubscribeProc<T>);
begin
  inherited Create;
  FSubscribe := ASubscribe;
end;

function TObservable<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Sub: TSubscriber<T>;
begin
  Sub := TSubscriber<T>.Create(AObserver);
  { The source may emit and even terminate synchronously; the subscriber handles
    the upstream being set late. }
  Sub.SetUpstream(FSubscribe(Sub));
  Result := Sub;
end;

{ TObserver<T> }

constructor TObserver<T>.Create(const AOnNext: TAction<T>;
  const AOnError: TAction<Exception>; const AOnComplete: TAction0);
begin
  inherited Create;
  FOnNext := AOnNext;
  FOnError := AOnError;
  FOnComplete := AOnComplete;
end;

procedure TObserver<T>.OnNext(const AValue: T);
begin
  if Assigned(FOnNext) then
    FOnNext(AValue);
end;

procedure TObserver<T>.OnError(const AError: Exception);
begin
  if Assigned(FOnError) then
    FOnError(AError)
  else
    AError.Free;
end;

procedure TObserver<T>.OnComplete;
begin
  if Assigned(FOnComplete) then
    FOnComplete();
end;

{ TClosureSubscription }

constructor TClosureSubscription.Create(const AAction: TUnsubscriber);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FAction := AAction;
end;

destructor TClosureSubscription.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TClosureSubscription.Unsubscribe;
var
  Action: TUnsubscriber;
begin
  FLock.Acquire;
  try
    if FClosed then
      Exit;
    FClosed := True;
    Action := FAction;
    FAction := nil;
  finally
    FLock.Release;
  end;
  if Assigned(Action) then
    Action();
end;

function TClosureSubscription.Closed: Boolean;
begin
  Result := FClosed;
end;

end.
