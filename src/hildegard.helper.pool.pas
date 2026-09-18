unit hildegard.helper.pool;
{ A tiny bounded-concurrency agent pool. Jobs are shell commands; each job runs
  as a TCommandRunner on the first free worker, so up to `Concurrency` subagents
  execute in parallel. Output from every subagent is forwarded, unchanged, to a
  shared TOutputEvent.

  Implementation notes (macOS/FPC 3.3.1):
    * Unix programs MUST pull in the cthreads driver as their first unit.
    * TSemaphore is unusable on macOS (it calls sem_init, which returns ENOSYS),
      so this pool uses TCriticalSection for the queue and TSimpleEvent to wake
      idle workers. Workers also poll, so a collapsed/consumed event can never
      stall the pool. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Generics.Collections, hildegard.helper.process;

const
  WorkerPollMs = 25;

type
  TAgentJob = record
    Id: string;
    Command: string;
    TimeoutMs: QWord;
  end;

  TAgentPool = class;

  TPoolWorker = class(TThread)
  private
    FPool: TAgentPool;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TAgentPool);
  end;

  TAgentPool = class
  private
    FLock: TCriticalSection;
    FWake: TSimpleEvent;
    FQueue: TQueue<TAgentJob>;
    FWorkers: TObjectList<TPoolWorker>;
    FOnOutput: TOutputEvent;
    FPending: Integer;
    function TryPop(out AJob: TAgentJob): Boolean;
    procedure RunJob(const AJob: TAgentJob);
    procedure JobFinished;
  public
    constructor Create(AConcurrency: Integer; AOnOutput: TOutputEvent);
    destructor Destroy; override;
    procedure Submit(const AId, ACommand: string; ATimeoutMs: QWord = 0);
    procedure WaitAll;
    property OnOutput: TOutputEvent read FOnOutput write FOnOutput;
  end;

implementation

{ TPoolWorker }

constructor TPoolWorker.Create(APool: TAgentPool);
begin
  inherited Create(True);
  FPool := APool;
  FreeOnTerminate := False;
end;

procedure TPoolWorker.Execute;
var
  Job: TAgentJob;
begin
  while not Terminated do
  begin
    if FPool.TryPop(Job) then
      FPool.RunJob(Job)
    else
      FPool.FWake.WaitFor(WorkerPollMs);
  end;
end;

{ TAgentPool }

constructor TAgentPool.Create(AConcurrency: Integer; AOnOutput: TOutputEvent);
var
  I: Integer;
  W: TPoolWorker;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWake := TSimpleEvent.Create;
  FQueue := TQueue<TAgentJob>.Create;
  FWorkers := TObjectList<TPoolWorker>.Create(True);
  FOnOutput := AOnOutput;
  if AConcurrency < 1 then
    AConcurrency := 1;
  for I := 1 to AConcurrency do
  begin
    W := TPoolWorker.Create(Self);
    FWorkers.Add(W);
    W.Start;
  end;
end;

destructor TAgentPool.Destroy;
var
  I: Integer;
begin
  for I := 0 to FWorkers.Count - 1 do
    FWorkers[I].Terminate;
  for I := 0 to FWorkers.Count - 1 do
    FWorkers[I].WaitFor;
  FWorkers.Free;
  FQueue.Free;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

function TAgentPool.TryPop(out AJob: TAgentJob): Boolean;
begin
  FLock.Acquire;
  try
    Result := FQueue.Count > 0;
    if Result then
      AJob := FQueue.Dequeue;
  finally
    FLock.Release;
  end;
end;

procedure TAgentPool.Submit(const AId, ACommand: string; ATimeoutMs: QWord);
var
  Job: TAgentJob;
begin
  Job.Id := AId;
  Job.Command := ACommand;
  Job.TimeoutMs := ATimeoutMs;
  FLock.Acquire;
  try
    Inc(FPending);
    FQueue.Enqueue(Job);
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TAgentPool.RunJob(const AJob: TAgentJob);
var
  Runner: TCommandRunner;
begin
  Runner := TCommandRunner.Create(AJob.Id, AJob.Command, AJob.TimeoutMs,
    '', FOnOutput);
  try
    Runner.Start;
    Runner.WaitFor;
  finally
    Runner.Free;
  end;
  JobFinished;
end;

procedure TAgentPool.JobFinished;
begin
  FLock.Acquire;
  try
    Dec(FPending);
  finally
    FLock.Release;
  end;
end;

procedure TAgentPool.WaitAll;
var
  Done: Boolean;
begin
  repeat
    FLock.Acquire;
    try
      Done := FPending = 0;
    finally
      FLock.Release;
    end;
    if not Done then
      Sleep(10);
  until Done;
end;

end.
