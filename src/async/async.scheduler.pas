unit async.scheduler;
{ Schedulers: ordered, deferred delivery of continuations.

  A scheduler is not an event loop. Work is enqueued and drained to quiescence,
  and a consumer drives it. The queue scheduler is a trampoline (work scheduled
  during a drain runs in the same drain, after the current item); the asap
  scheduler always defers and is drained by its owner.

  See docs/features/Async_Core/Async_Core_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, SyncObjs, Generics.Collections,
  async.base, async.context;

type
  { Ordered delivery of continuations. A delay of 0 is "as soon as possible on
    this scheduler"; a positive delay is only valid on a timer scheduler and
    raises here. }
  IAsyncScheduler = interface
    function Schedule(const AWork: TNotify; const ADelayMs: Integer): ISubscription;
    procedure Drain;
    function HasPending: Boolean;
  end;

  { One unit of scheduled work. It is also the subscription: Unsubscribe cancels
    it if it has not run. }
  IAsyncJob = interface(ISubscription)
    { The work to run, or nil when it was cancelled or already taken. }
    function TakeWork: TNotify;
    { The continuation-scoped context captured when the job was enqueued. }
    function Snapshot: IContextSnapshot;
    { A cancellation token for IN-FLIGHT cancellation: a running job polls it.
      Unsubscribe trips it, so a long job can stop cooperatively. }
    function Token: ICancellationToken;
  end;

  { A job is claimed by exactly one thread (a worker) or cancelled by exactly
    one other (the UI). Both transitions are a SINGLE InterlockedCompareExchange
    on a state word, so no lock is needed: whoever CASes 0 -> its own state wins,
    and the loser sees the state and does nothing. (A spinlock-as-mutex is NOT
    safe here on ARM64 without acquire/release barriers; a single CAS is.) }
  TAsyncJob = class(TInterfacedObject, IAsyncJob)
  private
    const Pending = 0; Taken = 1; Cancelled = 2;
  private
    FState: Integer;
    FWork: TNotify;
    FSnapshot: IContextSnapshot;
    FToken: ICancellationToken;
  public
    { AToken may be nil (the job makes its own). A caller that wants to poll the
      token inside the work supplies one. }
    constructor Create(const AWork: TNotify; const AToken: ICancellationToken = nil);
    procedure Unsubscribe;
    function Closed: Boolean;
    function TakeWork: TNotify;
    function Snapshot: IContextSnapshot;
    function Token: ICancellationToken;
  end;

  { Shared machinery: a FIFO of jobs with a head index advanced before each job
    runs, so a nested drain never re-runs the in-flight job. Compaction happens
    only when the outermost drain finishes. }
  TBaseScheduler = class(TInterfacedObject, IAsyncScheduler)
  private
    FJobs: TList<IAsyncJob>;
    FHead: Integer;
  protected
    FDraining: Boolean;
    function Enqueue(const AWork: TNotify): ISubscription;
    procedure RunPending;
  public
    constructor Create;
    destructor Destroy; override;
    function Schedule(const AWork: TNotify; const ADelayMs: Integer): ISubscription; virtual;
    procedure Drain; virtual;
    function HasPending: Boolean;
  end;

  { A trampoline: Schedule runs the job inline when the scheduler is not already
    draining, so a recursive Schedule flattens into the outer drain. }
  TQueueScheduler = class(TBaseScheduler)
  public
    function Schedule(const AWork: TNotify; const ADelayMs: Integer): ISubscription; override;
  end;

  { Always defers: Schedule only enqueues; the owner drains. }
  TAsapScheduler = class(TBaseScheduler)
  end;

implementation

{ TAsyncJob }

constructor TAsyncJob.Create(const AWork: TNotify; const AToken: ICancellationToken);
begin
  inherited Create;
  FState := Pending;
  FWork := AWork;
  if AToken <> nil then
    FToken := AToken
  else
    FToken := TSpinFreeCancellation.Create;
  { Capture the current context at enqueue time; it travels with the job. }
  FSnapshot := ContextCurrent;
end;

procedure TAsyncJob.Unsubscribe;
begin
  { Trip the token first: this stops a RUNNING job that polls it. Then claim the
    job as cancelled (CAS Pending -> Cancelled) so a not-yet-started job is
    skipped. }
  FToken.Cancel;
  if InterlockedCompareExchange(FState, Cancelled, Pending) = Pending then
    FWork := nil;
end;

function TAsyncJob.Closed: Boolean;
begin
  Result := FState <> Pending;
end;

function TAsyncJob.TakeWork: TNotify;
begin
  { Claim the job: CAS Pending -> Taken. If a cancel won, there is no work. }
  if InterlockedCompareExchange(FState, Taken, Pending) = Pending then
    Result := FWork
  else
    Result := nil;
  FWork := nil;
end;

function TAsyncJob.Token: ICancellationToken;
begin
  Result := FToken;
end;

function TAsyncJob.Snapshot: IContextSnapshot;
begin
  Result := FSnapshot;
end;

{ TBaseScheduler }

constructor TBaseScheduler.Create;
begin
  inherited Create;
  FJobs := TList<IAsyncJob>.Create;
  FHead := 0;
  FDraining := False;
end;

destructor TBaseScheduler.Destroy;
begin
  FJobs.Free;
  inherited;
end;

function TBaseScheduler.Enqueue(const AWork: TNotify): ISubscription;
var
  Job: IAsyncJob;
begin
  Job := TAsyncJob.Create(AWork);
  FJobs.Add(Job);
  Result := Job;
end;

procedure TBaseScheduler.RunPending;
var
  Job: IAsyncJob;
  Work: TNotify;
  Snap: IContextSnapshot;
  Token: TContextToken;
begin
  while FHead < FJobs.Count do
  begin
    Job := FJobs[FHead];
    Inc(FHead);
    Work := Job.TakeWork;
    if Assigned(Work) then
    begin
      { Install the job's captured context, run, then restore. }
      Snap := Job.Snapshot;
      Token := ContextEnter(Snap);
      try
        Work();
      finally
        ContextLeave(Token);
      end;
    end;
  end;
end;

procedure TBaseScheduler.Drain;
begin
  if FDraining then
  begin
    { Nested drain: run the new jobs but do not compact - the outer drain owns
      the list. }
    RunPending;
    Exit;
  end;
  FDraining := True;
  try
    RunPending;
  finally
    FDraining := False;
  end;
  if FHead >= FJobs.Count then
  begin
    FJobs.Clear;
    FHead := 0;
  end;
end;

function TBaseScheduler.Schedule(const AWork: TNotify;
  const ADelayMs: Integer): ISubscription;
begin
  if ADelayMs <> 0 then
    raise EArgumentException.Create(
      'this scheduler has no timer: delay must be 0');
  Result := Enqueue(AWork);
end;

function TBaseScheduler.HasPending: Boolean;
begin
  Result := FHead < FJobs.Count;
end;

{ TQueueScheduler }

function TQueueScheduler.Schedule(const AWork: TNotify;
  const ADelayMs: Integer): ISubscription;
begin
  Result := inherited Schedule(AWork, ADelayMs);
  if not FDraining then
    Drain;
end;

end.
