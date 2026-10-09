unit async.subject;
{ Subjects: the push side of the stream. A subject is both an IObserver<T> (it
  is fed values) and an ISubscribable<T> (subscribers attach), and it multicasts
  to its subscribers.

  - TSubject<T>          multicast, no replay; hot. Late subscribers see only
                         new values.
  - TBehaviorSubject<T>  holds a current value; a new subscriber gets it first.
  - TReplaySubject<T>    replays a bounded buffer to new subscribers.
  - TAsyncSubject<T>     emits only the LAST value, on completion.

  Subjects are the entry point for push sources (sockets, UI events) and for
  thread-confined state (BehaviorSubject<UiState>).

  This library has NO dependency on the harness or any engine unit - it must stay
  extractable. See docs/features/Async_Core/Async_Core_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, SyncObjs,
  async.base, async.observable;

type
  { Multicast, no replay. Once terminated, a new subscriber gets a closed
    subscription and no notification. }
  TSubject<T> = class(TInterfacedObject, IObserver<T>, ISubscribable<T>)
  private
    FLock: TCriticalSection;
    FObservers: TArray<IObserver<T>>;
    FStopped: Boolean;
    procedure Broadcast(const AValue: T);
  public
    constructor Create;
    destructor Destroy; override;
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  { Holds a current value; a new subscriber receives it before new values. }
  TBehaviorSubject<T> = class(TInterfacedObject, IObserver<T>, ISubscribable<T>)
  private
    FLock: TCriticalSection;
    FObservers: TArray<IObserver<T>>;
    FValue: T;
    FStopped: Boolean;
  public
    constructor Create(const AInitial: T);
    destructor Destroy; override;
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
    property Value: T read FValue;
  end;

  { Replays a bounded buffer of recent values to each new subscriber. ACapacity
    of 0 replays every value (unbounded). }
  TReplaySubject<T> = class(TInterfacedObject, IObserver<T>, ISubscribable<T>)
  private
    FLock: TCriticalSection;
    FObservers: TArray<IObserver<T>>;
    FBuffer: TArray<T>;
    FCapacity: Integer;      { 0 = unbounded }
    FStopped: Boolean;
    procedure Broadcast(const AValue: T);
  public
    constructor Create(const ACapacity: Integer = 0);
    destructor Destroy; override;
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
  end;

  { Emits only the last value, when it completes. An error is forwarded at once. }
  TAsyncSubject<T> = class(TInterfacedObject, IObserver<T>, ISubscribable<T>)
  private
    FLock: TCriticalSection;
    FObservers: TArray<IObserver<T>>;
    FValue: T;
    FHasValue: Boolean;
    FStopped: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Subscribe(const AObserver: IObserver<T>): ISubscription;
    procedure OnNext(const AValue: T);
    procedure OnError(const AError: Exception);
    procedure OnComplete;
    property Value: T read FValue;
  end;

implementation

{ TSubject<T> }

constructor TSubject<T>.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FObservers := nil;
  FStopped := False;
end;

destructor TSubject<T>.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TSubject<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Stopped: Boolean;
begin
  FLock.Acquire;
  try
    Stopped := FStopped;
    if not Stopped then
    begin
      SetLength(FObservers, Length(FObservers) + 1);
      FObservers[High(FObservers)] := AObserver;
    end;
  finally
    FLock.Release;
  end;
  if Stopped then
    Exit(TClosureSubscription.Create(nil));
  Result := TClosureSubscription.Create(
    procedure
    var
      I: Integer;
    begin
      FLock.Acquire;
      try
        for I := 0 to High(FObservers) do
          if FObservers[I] = AObserver then
          begin
            FObservers[I] := FObservers[High(FObservers)];
            SetLength(FObservers, Length(FObservers) - 1);
            Break;
          end;
      finally
        FLock.Release;
      end;
    end);
end;

procedure TSubject<T>.Broadcast(const AValue: T);
var
  Snapshot: TArray<IObserver<T>>;
  I: Integer;
begin
  FLock.Acquire;
  try
    Snapshot := FObservers;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Snapshot) do
    Snapshot[I].OnNext(AValue);
end;

procedure TSubject<T>.OnNext(const AValue: T);
begin
  Broadcast(AValue);
end;

procedure TSubject<T>.OnError(const AError: Exception);
var
  Snapshot: TArray<IObserver<T>>;
  I: Integer;
begin
  FLock.Acquire;
  try
    if FStopped then
    begin
      AError.Free;
      Exit;
    end;
    FStopped := True;
    Snapshot := FObservers;
    FObservers := nil;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Snapshot) do
    Snapshot[I].OnError(AError);
end;

procedure TSubject<T>.OnComplete;
var
  Snapshot: TArray<IObserver<T>>;
  I: Integer;
begin
  FLock.Acquire;
  try
    if FStopped then
      Exit;
    FStopped := True;
    Snapshot := FObservers;
    FObservers := nil;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Snapshot) do
    Snapshot[I].OnComplete;
end;

{ TBehaviorSubject<T> }

constructor TBehaviorSubject<T>.Create(const AInitial: T);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FObservers := nil;
  FValue := AInitial;
  FStopped := False;
end;

destructor TBehaviorSubject<T>.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TBehaviorSubject<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Stopped: Boolean;
  Current: T;
begin
  FLock.Acquire;
  try
    Stopped := FStopped;
    Current := FValue;
    if not Stopped then
    begin
      SetLength(FObservers, Length(FObservers) + 1);
      FObservers[High(FObservers)] := AObserver;
    end;
  finally
    FLock.Release;
  end;
  if Stopped then
    Exit(TClosureSubscription.Create(nil));
  { The current value first, then new values. }
  AObserver.OnNext(Current);
  Result := TClosureSubscription.Create(
    procedure
    var
      I: Integer;
    begin
      FLock.Acquire;
      try
        for I := 0 to High(FObservers) do
          if FObservers[I] = AObserver then
          begin
            FObservers[I] := FObservers[High(FObservers)];
            SetLength(FObservers, Length(FObservers) - 1);
            Break;
          end;
      finally
        FLock.Release;
      end;
    end);
end;

procedure TBehaviorSubject<T>.OnNext(const AValue: T);
var
  Snapshot: TArray<IObserver<T>>;
  I: Integer;
begin
  FLock.Acquire;
  try
    if FStopped then
      Exit;
    FValue := AValue;
    Snapshot := FObservers;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Snapshot) do
    Snapshot[I].OnNext(AValue);
end;

procedure TBehaviorSubject<T>.OnError(const AError: Exception);
var
  Snapshot: TArray<IObserver<T>>;
  I: Integer;
begin
  FLock.Acquire;
  try
    if FStopped then
    begin
      AError.Free;
      Exit;
    end;
    FStopped := True;
    Snapshot := FObservers;
    FObservers := nil;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Snapshot) do
    Snapshot[I].OnError(AError);
end;

procedure TBehaviorSubject<T>.OnComplete;
var
  Snapshot: TArray<IObserver<T>>;
  I: Integer;
begin
  FLock.Acquire;
  try
    if FStopped then
      Exit;
    FStopped := True;
    Snapshot := FObservers;
    FObservers := nil;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Snapshot) do
    Snapshot[I].OnComplete;
end;

{ TReplaySubject<T> }

constructor TReplaySubject<T>.Create(const ACapacity: Integer);
begin
  inherited Create;
  if ACapacity < 0 then
    raise EArgumentException.Create('capacity must be >= 0');
  FLock := TCriticalSection.Create;
  FObservers := nil;
  FBuffer := nil;
  FCapacity := ACapacity;
  FStopped := False;
end;

destructor TReplaySubject<T>.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TReplaySubject<T>.Broadcast(const AValue: T);
var
  Snapshot: TArray<IObserver<T>>;
  I: Integer;
begin
  FLock.Acquire;
  try
    Snapshot := FObservers;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Snapshot) do
    Snapshot[I].OnNext(AValue);
end;

function TReplaySubject<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Stopped: Boolean;
  Replay: TArray<T>;
  I: Integer;
begin
  FLock.Acquire;
  try
    Stopped := FStopped;
    Replay := FBuffer;
    if not Stopped then
    begin
      SetLength(FObservers, Length(FObservers) + 1);
      FObservers[High(FObservers)] := AObserver;
    end;
  finally
    FLock.Release;
  end;
  if Stopped then
    Exit(TClosureSubscription.Create(nil));
  for I := 0 to High(Replay) do
    AObserver.OnNext(Replay[I]);
  Result := TClosureSubscription.Create(
    procedure
    var
      J: Integer;
    begin
      FLock.Acquire;
      try
        for J := 0 to High(FObservers) do
          if FObservers[J] = AObserver then
          begin
            FObservers[J] := FObservers[High(FObservers)];
            SetLength(FObservers, Length(FObservers) - 1);
            Break;
          end;
      finally
        FLock.Release;
      end;
    end);
end;

procedure TReplaySubject<T>.OnNext(const AValue: T);
begin
  FLock.Acquire;
  try
    if FStopped then
      Exit;
    if FCapacity = 0 then
    begin
      SetLength(FBuffer, Length(FBuffer) + 1);
      FBuffer[High(FBuffer)] := AValue;
    end
    else if Length(FBuffer) < FCapacity then
    begin
      SetLength(FBuffer, Length(FBuffer) + 1);
      FBuffer[High(FBuffer)] := AValue;
    end
    else
    begin
      { Ring: drop the oldest, append the newest. }
      Move(FBuffer[1], FBuffer[0], (FCapacity - 1) * SizeOf(T));
      FBuffer[FCapacity - 1] := AValue;
    end;
  finally
    FLock.Release;
  end;
  Broadcast(AValue);
end;

procedure TReplaySubject<T>.OnError(const AError: Exception);
var
  Snapshot: TArray<IObserver<T>>;
  I: Integer;
begin
  FLock.Acquire;
  try
    if FStopped then
    begin
      AError.Free;
      Exit;
    end;
    FStopped := True;
    Snapshot := FObservers;
    FObservers := nil;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Snapshot) do
    Snapshot[I].OnError(AError);
end;

procedure TReplaySubject<T>.OnComplete;
var
  Snapshot: TArray<IObserver<T>>;
  I: Integer;
begin
  FLock.Acquire;
  try
    if FStopped then
      Exit;
    FStopped := True;
    Snapshot := FObservers;
    FObservers := nil;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Snapshot) do
    Snapshot[I].OnComplete;
end;

{ TAsyncSubject<T> }

constructor TAsyncSubject<T>.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FObservers := nil;
  FHasValue := False;
  FStopped := False;
end;

destructor TAsyncSubject<T>.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TAsyncSubject<T>.Subscribe(const AObserver: IObserver<T>): ISubscription;
var
  Stopped: Boolean;
  Has: Boolean;
  V: T;
begin
  FLock.Acquire;
  try
    Stopped := FStopped;
    Has := FHasValue;
    V := FValue;
    if not Stopped then
    begin
      SetLength(FObservers, Length(FObservers) + 1);
      FObservers[High(FObservers)] := AObserver;
    end;
  finally
    FLock.Release;
  end;
  { A completed async subject delivers its last value to a late subscriber. }
  if Stopped then
  begin
    if Has then
      AObserver.OnNext(V);
    AObserver.OnComplete;
    Exit(TClosureSubscription.Create(nil));
  end;
  Result := TClosureSubscription.Create(
    procedure
    var
      I: Integer;
    begin
      FLock.Acquire;
      try
        for I := 0 to High(FObservers) do
          if FObservers[I] = AObserver then
          begin
            FObservers[I] := FObservers[High(FObservers)];
            SetLength(FObservers, Length(FObservers) - 1);
            Break;
          end;
      finally
        FLock.Release;
      end;
    end);
end;

procedure TAsyncSubject<T>.OnNext(const AValue: T);
begin
  FLock.Acquire;
  try
    if FStopped then
      Exit;
    FValue := AValue;
    FHasValue := True;
  finally
    FLock.Release;
  end;
end;

procedure TAsyncSubject<T>.OnError(const AError: Exception);
var
  Snapshot: TArray<IObserver<T>>;
  I: Integer;
begin
  FLock.Acquire;
  try
    if FStopped then
    begin
      AError.Free;
      Exit;
    end;
    FStopped := True;
    Snapshot := FObservers;
    FObservers := nil;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Snapshot) do
    Snapshot[I].OnError(AError);
end;

procedure TAsyncSubject<T>.OnComplete;
var
  Snapshot: TArray<IObserver<T>>;
  Has: Boolean;
  V: T;
  I: Integer;
begin
  FLock.Acquire;
  try
    if FStopped then
      Exit;
    FStopped := True;
    Has := FHasValue;
    V := FValue;
    Snapshot := FObservers;
    FObservers := nil;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Snapshot) do
  begin
    if Has then
      Snapshot[I].OnNext(V);
    Snapshot[I].OnComplete;
  end;
end;

end.
