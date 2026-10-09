program async_standalone;
{ The isolation gate for the Async Core library.

  This program uses ONLY the async.* units, so it must compile with
  -Fu$(SRC)/async and no harness unit on the search path. If the library ever
  reaches into the harness, this target stops compiling - which is what keeps
  the library extractable. See the Makefile's `async-standalone` target. }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, async.base, async.scheduler;

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
begin
  Sched := TQueueScheduler.Create;
  Counter := TCounter.Create;
  try
    Sched.Schedule(Counter.Bump, 0);
    Sched.Schedule(Counter.Bump, 0);
    if Counter.Count <> 2 then
      raise Exception.CreateFmt('expected 2 runs, got %d', [Counter.Count]);
    WriteLn('async standalone ok');
  finally
    Counter.Free;
  end;
end.
