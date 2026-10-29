program async_bench;
{ A quick throughput check for the Async Core primitives: the bounded mailbox,
  the scheduler, future delivery, the observable operators, the virtual clock,
  and the executor. Run with `make async-bench` (release). }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, SyncObjs,
  AsyncBase, AsyncScheduler, AsyncQueue, AsyncFuture,
  AsyncObservable, AsyncOperators, AsyncTimers, AsyncTime,
  AsyncConcurrency;

type
  TCounter = class
  public
    N: Int64;
    Lock: TCriticalSection;
    constructor Create;
    destructor Destroy; override;
    procedure Bump;
  end;

  TSink = class
  public
    Total: Int64;
    procedure Note(const AValue: Integer);
  end;

constructor TCounter.Create;
begin
  inherited Create;
  Lock := TCriticalSection.Create;
end;

destructor TCounter.Destroy;
begin
  Lock.Free;
  inherited;
end;

procedure TCounter.Bump;
begin
  { The executor runs Bump from several workers; guard the shared counter or it
    loses increments (the "ran N" line would read low). }
  Lock.Acquire;
  try
    Inc(N);
  finally
    Lock.Release;
  end;
end;

procedure TSink.Note(const AValue: Integer);
begin
  Inc(Total, AValue);
end;

const
  N = 1000000;
  PipelineN = 100000;

var
  Start, Elapsed: Int64;
  GSink: TSink;

function MsNow: Int64;
begin
  Result := GetTickCount64;
end;

function PerOp(const AOps: Int64): Double;
begin
  { Elapsed ms -> ns per op. }
  Result := (Elapsed * 1000000.0) / AOps;
end;

procedure BenchQueue;
var
  Q: TBoundedQueue<Integer>;
  I, V: Integer;
begin
  Q := TBoundedQueue<Integer>.Create(1024);
  try
    Start := MsNow;
    for I := 1 to N do
    begin
      Q.Push(I);
      Q.TryPop(V);
    end;
    Elapsed := MsNow - Start;
    WriteLn(Format('bounded queue  push+pop   : %8.1f ns/op', [PerOp(N)]));
  finally
    Q.Free;
  end;
end;

procedure BenchScheduler;
var
  S: IAsyncScheduler;
  C: TCounter;
  I: Integer;
begin
  S := TAsapScheduler.Create;
  C := TCounter.Create;
  try
    Start := MsNow;
    for I := 1 to N do
      S.Schedule(C.Bump, 0);
    S.Drain;
    Elapsed := MsNow - Start;
    WriteLn(Format('scheduler  schedule+drain: %8.1f ns/op (ran %d)',
      [PerOp(N), C.N]));
  finally
    C.Free;
  end;
end;

procedure BenchFuture;
var
  F: TFuture<Integer>;
  I, Sink: Integer;
begin
  Start := MsNow;
  for I := 1 to N do
  begin
    F := TFuture<Integer>.Resolve(I);
    try
      F.AndThen(
        procedure(const AValue: Integer)
        begin
          Sink := AValue;
        end);
    finally
      F.Free;
    end;
  end;
  Elapsed := MsNow - Start;
  WriteLn(Format('future     resolve+then : %8.1f ns/op', [PerOp(N)]));
end;

procedure BenchObservable;
var
  I: Integer;
begin
  { A 10-value source, subscribed N/10 times, so the op count is N and the
    1 ms clock registers. }
  Start := MsNow;
  for I := 1 to (N div 10) do
    FromArray<Integer>([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]).Subscribe(
      TObserver<Integer>.Create(
        procedure(const AValue: Integer) begin GSink.Note(AValue); end));
  Elapsed := MsNow - Start;
  WriteLn(Format('observable subscribe     : %8.1f ns/op', [PerOp(N)]));
end;

procedure BenchPipeline;
var
  I: Integer;
  S: ISubscribable<Integer>;
begin
  { Filter -> Map -> Take, composed once, run over PipelineN values. }
  S := Pipe<Integer>(Range(1, PipelineN), [
    FilterOp<Integer>(function(const V: Integer): Boolean
      begin Result := V mod 2 = 0; end),
    TakeOp<Integer>(PipelineN)]);
  Start := MsNow;
  S.Subscribe(TObserver<Integer>.Create(
    procedure(const AValue: Integer) begin GSink.Note(AValue); end));
  Elapsed := MsNow - Start;
  WriteLn(Format('pipeline   filter (Range %d): %8.1f ns/op', [PipelineN,
    PerOp(PipelineN)]));
end;

procedure BenchMap;
var
  S: ISubscribable<Integer>;
begin
  S := Map<Integer, Integer>(Range(1, PipelineN),
    function(const V: Integer): Integer begin Result := V * 2; end);
  Start := MsNow;
  S.Subscribe(TObserver<Integer>.Create(
    procedure(const AValue: Integer) begin GSink.Note(AValue); end));
  Elapsed := MsNow - Start;
  WriteLn(Format('map        Range %d     : %8.1f ns/op', [PipelineN,
    PerOp(PipelineN)]));
end;

procedure BenchVirtualClock;
var
  Sched: TVirtualScheduler;
  C: TCounter;
  I: Integer;
begin
  { The timer queue is a binary min-heap, so scheduling T timers is O(T log T). }
  Sched := TVirtualScheduler.Create;
  C := TCounter.Create;
  try
    Start := MsNow;
    for I := 1 to 200000 do
      Sched.Schedule(C.Bump, 1);
    Sched.Advance(1);
    Elapsed := MsNow - Start;
    WriteLn(Format('virtual clock schedule   : %8.1f ns/op (ran %d, O(T log T))',
      [PerOp(200000), C.N]));
  finally
    C.Free;
    Sched.Free;
  end;
end;

procedure BenchExecutor;
var
  Exec: IAsyncScheduler;
  C: TCounter;
  I: Integer;
begin
  Exec := TExecutorScheduler.Create(4);
  C := TCounter.Create;
  try
    Start := MsNow;
    for I := 1 to 100000 do
      Exec.Schedule(C.Bump, 0);
    Exec.Drain;
    Elapsed := MsNow - Start;
    WriteLn(Format('executor   schedule+drain: %8.1f ns/op (ran %d)',
      [PerOp(100000), C.N]));
  finally
    C.Free;
    { Release the pool so its threads join before the program exits. }
    Exec := nil;
  end;
end;

begin
  GSink := TSink.Create;
  try
    WriteLn(Format('async core benchmark, N = %d', [N]));
    BenchQueue;
    BenchScheduler;
    BenchFuture;
    BenchObservable;
    BenchMap;
    BenchPipeline;
    BenchVirtualClock;
    BenchExecutor;
  finally
    GSink.Free;
  end;
end.
