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
  end;

  TAsyncJob = class(TInterfacedObject, IAsyncJob)
  private
    FLock: TSpinLock;
    FClosed: Boolean;
    FCancelled: Boolean;
    FWork: TNotify;
    FSnapshot: IContextSnapshot;
  public
    constructor Create(const AWork: TNotify);
    destructor Destroy; override;
    procedure Unsubscribe;
    function Closed: Boolean;
    function TakeWork: TNotify;
    function Snapshot: IContextSnapshot;
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

constructor TAsyncJob.Create(const AWork: TNotify);
begin
  inherited Create;
  { A spinlock needs no construction and no heap allocation. }
  FLock.Init;
  FWork := AWork;
  { Capture the current context at enqueue time; it travels with the job. }
  FSnapshot := ContextCurrent;
end;

destructor TAsyncJob.Destroy;
begin
  inherited;
end;

procedure TAsyncJob.Unsubscribe;
begin
  FLock.Acquire;
  try
    if FClosed then
      Exit;
    FCancelled := True;
    FClosed := True;
    FWork := nil;
  finally
    FLock.Release;
  end;
end;

function TAsyncJob.Closed: Boolean;
begin
  Result := FClosed;
end;

function TAsyncJob.TakeWork: TNotify;
begin
  FLock.Acquire;
  try
    if FCancelled then
      Result := nil
    else
      Result := FWork;
    FWork := nil;
    FClosed := True;
  finally
    FLock.Release;
  end;
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
