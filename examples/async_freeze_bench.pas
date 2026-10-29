program async_freeze_bench;
{ The TUI freeze, isolated to the drain.

  A chatty command fills the mailbox with a burst of events. The OLD consumer
  drained until empty (while TryPop), so with a fast producer the loop never
  returned and the UI could not render or poll input. The NEW consumer drains a
  per-frame budget and returns. The metric is how long the consumer is
  unavailable - i.e. how long the UI is frozen.

  Run with `make async-freeze`. }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, AsyncBase, AsyncQueue;

const
  Burst = 1000000;   { one chatty command's worth of streamed events }
  Budget = 256;      { the frame-paced drain budget }

var
  Sink: Int64;

procedure Handle(const AValue: Integer);
begin
  Sink := Sink + AValue;
end;

function MsNow: Int64;
begin
  Result := GetTickCount64;
end;

procedure Fill(const Q: TBoundedQueue<Integer>; const ACount: Integer);
var
  I: Integer;
begin
  for I := 1 to ACount do
    Q.Push(I);
end;

procedure BenchUnbounded;
var
  Q: TBoundedQueue<Integer>;
  V: Integer;
  Start: Int64;
begin
  Q := TBoundedQueue<Integer>.Create(Burst);
  try
    Fill(Q, Burst);
    Start := MsNow;
    while Q.TryPop(V) do
      Handle(V);
    WriteLn(Format('unbounded drain : UI frozen for %6d ms  (one loop, no render, no input)',
      [MsNow - Start]));
  finally
    Q.Free;
  end;
end;

procedure BenchFramePaced;
var
  Q: TBoundedQueue<Integer>;
  V, I: Integer;
  LoopStart, Worst, Total, Loops: Int64;
begin
  Q := TBoundedQueue<Integer>.Create(Burst);
  try
    Fill(Q, Burst);
    Worst := 0;
    Total := 0;
    Loops := 0;
    while not Q.IsEmpty do
    begin
      LoopStart := MsNow;
      for I := 0 to Budget - 1 do
      begin
        if not Q.TryPop(V) then
          Break;
        Handle(V);
      end;
      Total := Total + (MsNow - LoopStart);
      Inc(Loops);
      { The loop returns here every frame: the UI would render and poll input. }
      if (MsNow - LoopStart) > Worst then
        Worst := MsNow - LoopStart;
    end;
    WriteLn(Format('frame-paced     : UI frozen for %6d ms max, %d ms total over %d loops',
      [Worst, Total, Loops]));
    WriteLn(Format('                  (render + input get a turn every %d events)',
      [Budget]));
  finally
    Q.Free;
  end;
end;

begin
  WriteLn(Format('freeze repro: %d events, budget %d', [Burst, Budget]));
  BenchUnbounded;
  BenchFramePaced;
  WriteLn(Format('(sink=%d)', [Sink]));
end.
