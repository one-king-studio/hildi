program async_standalone;
{ The isolation gate for the Async Core library.

  This program uses ONLY the async.* units, so it must compile with
  -Fu$(SRC)/async and no harness unit on the search path. If the library ever
  reaches into the harness, this target stops compiling - which is what keeps
  the library extractable. See the Makefile's `async-standalone` target. }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, async.base, async.scheduler, async.future;

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
    WriteLn('async standalone ok');
  finally
    Counter.Free;
  end;
end.
