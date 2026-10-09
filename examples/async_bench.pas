program async_bench;
{ A quick throughput check for the Async Core primitives: the bounded mailbox,
  the scheduler, and future delivery. Run with `make async-bench` (release). }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, async.base, async.scheduler, async.queue, async.future;

type
  TCounter = class
  public
    N: Int64;
    procedure Bump;
  end;

procedure TCounter.Bump;
begin
  Inc(N);
end;

const
  N = 1000000;

var
  Start, Elapsed: Int64;

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

begin
  WriteLn(Format('async core benchmark, N = %d', [N]));
  BenchQueue;
  BenchScheduler;
  BenchFuture;
end.
