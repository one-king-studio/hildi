program async_standalone;
{ The isolation gate for the Async Core library.

  This program uses ONLY the async.* units, so it must compile with
  -Fu$(SRC)/async and no harness unit on the search path. If the library ever
  reaches into the harness, this target stops compiling - which is what keeps
  the library extractable. See the Makefile's `async-standalone` target. }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, async.base, async.scheduler, async.future, async.queue, async.timers;

type
  TCounter = class
  public
    Count: Integer;
    procedure Bump;
  end;

procedure TCounter.Bump;
begin
  Inc(Count);
end;

var
  Sched: IAsyncScheduler;
  Counter: TCounter;
  Fut: TFuture<Integer>;
  Mail: TBoundedQueue<Integer>;
  Popped: Integer;
  Clock: TVirtualScheduler;
begin
  Sched := TQueueScheduler.Create;
  Counter := TCounter.Create;
  try
    Sched.Schedule(Counter.Bump, 0);
    Sched.Schedule(Counter.Bump, 0);
    if Counter.Count <> 2 then
      raise Exception.CreateFmt('expected 2 runs, got %d', [Counter.Count]);
    Fut := TFuture<Integer>.Resolve(3);
    try
      Fut.AndThen(procedure(const AValue: Integer)
        begin
          Counter.Count := Counter.Count + AValue;
        end);
      if Counter.Count <> 5 then
        raise Exception.CreateFmt('expected 5, got %d', [Counter.Count]);
    finally
      Fut.Free;
    end;
    Mail := TBoundedQueue<Integer>.Create(2);
    try
      Mail.Push(1);
      Mail.Push(2);
      if Mail.Push(3) then
        raise Exception.Create('expected the bound to drop the oldest');
      if not Mail.TryPop(Popped) or (Popped <> 2) then
        raise Exception.Create('expected 2 after the drop');
    finally
      Mail.Free;
    end;
    Clock := TVirtualScheduler.Create;
    try
      Clock.Schedule(Counter.Bump, 10);
      if Counter.Count <> 5 then
        raise Exception.Create('a future timer must not run yet');
      Clock.Advance(10);
      if Counter.Count <> 6 then
        raise Exception.Create('advance must run the due timer');
    finally
      Clock.Free;
    end;
    WriteLn('async standalone ok');
  finally
    Counter.Free;
  end;
end.
