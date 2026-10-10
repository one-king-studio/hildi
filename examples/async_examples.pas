program async_examples;
{ Three worked examples for the Async Core library, one per consumption mode.

  1. CLI Await      - a synchronous program blocks on a future and drives the
                      spine to completion (Future.Await).
  2. UI ObserveOn   - a synchronous source's effects are marshalled onto another
                      scheduler; the "UI" thread subscribes and drains, it never
                      awaits (the rule this whole model exists to enforce).
  3. Virtual clock  - a time-based operator is tested with no real waiting: a
                      virtual scheduler's Advance fires the timer deterministically.

  Uses ONLY the async.* units, so it doubles as a worked tour of the surface and
  a second isolation check (see the Makefile's `async-examples` target). }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils,
  async.base, async.scheduler, async.future, async.observable,
  async.operators, async.timers, async.time, async.concurrency;

{ 1. CLI Await: a future runs on the asap scheduler; Await blocks the calling
  thread and drives the microtask queue until the value is delivered. }
procedure ExampleCliAwait;
var
  Sched: IAsyncScheduler;
  Fut: TFuture<Integer>;
begin
  Sched := TAsapScheduler.Create;
  Fut := TFuture<Integer>.Run(function: Integer
    begin
      Result := 21 * 2;   { the "async" work }
    end, Sched);
  try
    WriteLn('  await -> ', Fut.Await);
  finally
    Fut.Free;
  end;
end;

{ 2. UI ObserveOn: the source is synchronous, but ObserveOn moves every
  notification onto the given scheduler. Here that scheduler stands in for the
  UI thread's mailbox: the effects run on it (off the caller), and the owner
  drains per frame. The UI thread never calls Await. }
procedure ExampleUiObserveOn;
var
  Ui: IAsyncScheduler;
  Exec: TExecutorScheduler;
begin
  Exec := TExecutorScheduler.Create(1);
  Ui := Exec;
  ObserveOn<Integer>(Range(1, 3), Ui).Subscribe(
    TObserver<Integer>.Create(
      procedure(const V: Integer)
      begin
        WriteLn('  ui effect ', V);   { runs on the UI scheduler, not the caller }
      end));
  Exec.Drain;   { a real UI drains its mailbox once per frame }
end;

{ 3. Virtual clock: Delay is driven by an explicit scheduler. With the virtual
  clock nothing happens until Advance; then the due timer fires in order. No
  Sleep, so the behaviour is exact and instant. }
procedure ExampleVirtualClock;
var
  Clock: IVirtualScheduler;
begin
  Clock := TVirtualScheduler.Create as IVirtualScheduler;
  Delay<Integer>(Range(1, 3), Clock, 50).Subscribe(
    TObserver<Integer>.Create(
      procedure(const V: Integer) begin WriteLn('  delayed ', V); end));
  WriteLn('  (nothing yet - the delay has not elapsed)');
  Clock.Advance(50);
end;

begin
  WriteLn('1. CLI Await');
  ExampleCliAwait;
  WriteLn('2. UI ObserveOn side effect');
  ExampleUiObserveOn;
  WriteLn('3. Virtual-clock operator');
  ExampleVirtualClock;
  WriteLn('async examples ok');
end.
