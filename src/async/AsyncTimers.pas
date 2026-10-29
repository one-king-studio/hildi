unit AsyncTimers;
{ Timer schedulers: ordered delivery of continuations at a due time.

  TVirtualScheduler runs on a VIRTUAL clock - no wall time passes, and the owner
  decides when the clock moves (Advance). That is what makes every time-based
  operator testable without sleeps. TRealScheduler is the same queue driven by the
  monotonic wall clock.

  The queue holds entry OBJECTS, not records: TList<T>.Delete moves elements with
  a raw System.Move, which corrupts a managed field, so a record with an interface
  member cannot live in a TList.

  See docs/features/Async_Core/Async_Core_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, SyncObjs, Generics.Collections,
  AsyncBase, AsyncContext, AsyncScheduler;

type
  TTimerEntry = class
  public
    Due: Int64;
    Seq: Int64;
    Job: IAsyncJob;
  end;

  { The shared ordered timer queue. Subclasses supply the clock.

    FTimers is a binary MIN-HEAP keyed on (Due, Seq): the earliest due entry is
    at index 0. Push and pop are O(log T), so scheduling T timers is O(T log T),
    not the O(T^2) a linear "find the earliest" scan would cost. }
  TBaseTimerScheduler = class(TInterfacedObject, IAsyncScheduler)
  private
    FLock: TCriticalSection;
    FTimers: TList<TTimerEntry>;
    FSeq: Int64;
    { True when A is due earlier than B (ties broken by lower Seq, FIFO). }
    function Earlier(const A, B: TTimerEntry): Boolean;
    procedure SiftUp(AIndex: Integer);
    procedure SiftDown(AIndex: Integer);
    procedure HeapPush(const AEntry: TTimerEntry);
    { Remove and hand back the root (the earliest due), or nil. Ownership
      transfers to the caller. }
    function HeapPop: TTimerEntry;
  protected
    { The current time in milliseconds. }
    function Clock: Int64; virtual; abstract;
    { Remove and hand back the earliest timer due at or before AUntil, or nil.
      Ownership transfers to the caller. }
    function TakeEarliestDue(const AUntil: Int64): TTimerEntry;
    procedure RunDue(const AUntil: Int64);
  public
    constructor Create;
    destructor Destroy; override;
    function Schedule(const AWork: TNotify; const ADelayMs: Integer): ISubscription; virtual;
    procedure Drain; virtual;
    function HasPending: Boolean;
  end;

  { A virtual clock. Advance moves it and runs whatever became due, in due order
    (FIFO for equal due), including timers scheduled while it runs. Exposed via
    IVirtualScheduler so a test can hold it as a refcounted interface: an operator
    keeps an IAsyncScheduler reference to it, so a raw Free would double-free. }
  IVirtualScheduler = interface(IAsyncScheduler)
  ['{A1B2C3D4-1111-2222-3333-444455556666}']
    procedure Advance(const AMs: Int64);
    function Now: Int64;
  end;

  TVirtualScheduler = class(TBaseTimerScheduler, IVirtualScheduler)
  private
    FNow: Int64;
  protected
    function Clock: Int64; override;
  public
    procedure Advance(const AMs: Int64);
    function Now: Int64;
    property NowMs: Int64 read FNow;
  end;

  { The same queue on the monotonic wall clock. The owner drives it (Drain runs
    what is due); it never blocks. }
  TRealScheduler = class(TBaseTimerScheduler)
  protected
    function Clock: Int64; override;
  end;

implementation

{ TBaseTimerScheduler }

constructor TBaseTimerScheduler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FTimers := TList<TTimerEntry>.Create;
  FSeq := 0;
end;

destructor TBaseTimerScheduler.Destroy;
var
  I: Integer;
begin
  for I := 0 to FTimers.Count - 1 do
    FTimers[I].Free;
  FTimers.Free;
  FLock.Free;
  inherited;
end;

function TBaseTimerScheduler.Earlier(const A, B: TTimerEntry): Boolean;
begin
  Result := (A.Due < B.Due) or ((A.Due = B.Due) and (A.Seq < B.Seq));
end;

procedure TBaseTimerScheduler.SiftUp(AIndex: Integer);
var
  Parent: Integer;
  Tmp: TTimerEntry;
begin
  while AIndex > 0 do
  begin
    Parent := (AIndex - 1) div 2;
    if not Earlier(FTimers[AIndex], FTimers[Parent]) then
      Break;
    Tmp := FTimers[AIndex];
    FTimers[AIndex] := FTimers[Parent];
    FTimers[Parent] := Tmp;
    AIndex := Parent;
  end;
end;

procedure TBaseTimerScheduler.SiftDown(AIndex: Integer);
var
  N, Left, Right, Smallest: Integer;
  Tmp: TTimerEntry;
begin
  N := FTimers.Count;
  while True do
  begin
    Left := 2 * AIndex + 1;
    Right := 2 * AIndex + 2;
    Smallest := AIndex;
    if (Left < N) and Earlier(FTimers[Left], FTimers[Smallest]) then
      Smallest := Left;
    if (Right < N) and Earlier(FTimers[Right], FTimers[Smallest]) then
      Smallest := Right;
    if Smallest = AIndex then
      Break;
    Tmp := FTimers[AIndex];
    FTimers[AIndex] := FTimers[Smallest];
    FTimers[Smallest] := Tmp;
    AIndex := Smallest;
  end;
end;

procedure TBaseTimerScheduler.HeapPush(const AEntry: TTimerEntry);
begin
  FTimers.Add(AEntry);
  SiftUp(FTimers.Count - 1);
end;

function TBaseTimerScheduler.HeapPop: TTimerEntry;
var
  Last: Integer;
begin
  if FTimers.Count = 0 then
    Exit(nil);
  Result := FTimers[0];
  Last := FTimers.Count - 1;
  FTimers[0] := FTimers[Last];
  FTimers.Delete(Last);
  if FTimers.Count > 0 then
    SiftDown(0);
end;

function TBaseTimerScheduler.Schedule(const AWork: TNotify;
  const ADelayMs: Integer): ISubscription;
var
  Entry: TTimerEntry;
begin
  if ADelayMs < 0 then
    raise EArgumentException.Create('delay must not be negative');
  Entry := TTimerEntry.Create;
  Entry.Due := Clock + ADelayMs;
  Entry.Seq := FSeq;
  Entry.Job := TAsyncJob.Create(AWork);
  Inc(FSeq);
  FLock.Acquire;
  try
    HeapPush(Entry);
  finally
    FLock.Release;
  end;
  Result := Entry.Job;
end;

function TBaseTimerScheduler.TakeEarliestDue(
  const AUntil: Int64): TTimerEntry;
begin
  Result := nil;
  FLock.Acquire;
  try
    { The heap root is the earliest due; pop it only if it is due by AUntil. }
    if (FTimers.Count > 0) and (FTimers[0].Due <= AUntil) then
      Result := HeapPop;
  finally
    FLock.Release;
  end;
end;

procedure TBaseTimerScheduler.RunDue(const AUntil: Int64);
var
  Entry: TTimerEntry;
  Work: TNotify;
  Token: TContextToken;
begin
  Entry := TakeEarliestDue(AUntil);
  while Entry <> nil do
  begin
    Work := Entry.Job.TakeWork;
    if Assigned(Work) then
    begin
      Token := ContextEnter(Entry.Job.Snapshot);
      try
        Work();
      finally
        ContextLeave(Token);
      end;
    end;
    Entry.Free;
    Entry := TakeEarliestDue(AUntil);
  end;
end;

procedure TBaseTimerScheduler.Drain;
begin
  RunDue(Clock);
end;

function TBaseTimerScheduler.HasPending: Boolean;
begin
  FLock.Acquire;
  try
    Result := FTimers.Count > 0;
  finally
    FLock.Release;
  end;
end;

{ TVirtualScheduler }

function TVirtualScheduler.Clock: Int64;
begin
  Result := FNow;
end;

procedure TVirtualScheduler.Advance(const AMs: Int64);
var
  Target: Int64;
  Entry: TTimerEntry;
  Work: TNotify;
begin
  if AMs < 0 then
    raise EArgumentException.Create('advance must not be negative');
  Target := FNow + AMs;
  { Run due timers in order, moving the clock to each due time so a timer sees
    the right Now; nested timers become due as the clock moves. }
  Entry := TakeEarliestDue(Target);
  while Entry <> nil do
  begin
    FNow := Entry.Due;
    Work := Entry.Job.TakeWork;
    Entry.Free;
    if Assigned(Work) then
      Work();
    Entry := TakeEarliestDue(Target);
  end;
  FNow := Target;
end;

function TVirtualScheduler.Now: Int64;
begin
  Result := FNow;
end;

{ TRealScheduler }

function TRealScheduler.Clock: Int64;
begin
  Result := GetTickCount64;
end;

end.
