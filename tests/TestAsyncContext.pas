unit TestAsyncContext;
{ Tests for the continuation-scoped context (docs/features/Async_Core). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  AsyncBase, AsyncContext, AsyncScheduler;

type
  TAsyncContextTest = class(TTestCase)
  private
    FSeen: string;
    procedure CaptureContext;
  published
    procedure SnapshotIsImmutable;
    procedure ValueSurvivesADeferredBoundary;
    procedure NestedScopesRestore;
    procedure UnbalancedLeaveRaises;
  end;

implementation

procedure TAsyncContextTest.CaptureContext;
var
  V: string;
begin
  if ContextCurrent.TryGet('trace', V) then
    FSeen := V;
end;

procedure TAsyncContextTest.SnapshotIsImmutable;
var
  Base, Derived: IContextSnapshot;
  V: string;
begin
  Base := ContextCurrent;
  Derived := Base.Bind('trace', 'abc');
  AssertFalse('base does not see the binding', Base.TryGet('trace', V));
  AssertTrue('derived sees it', Derived.TryGet('trace', V));
  AssertEquals('value', 'abc', V);
end;

procedure TAsyncContextTest.ValueSurvivesADeferredBoundary;
var
  Sched: TQueueScheduler;
  Snapshot: IContextSnapshot;
  Seen: string;
  Outer: string;
  Token: TContextToken;
begin
  Sched := TQueueScheduler.Create;
  try
    FSeen := '<none>';
    Snapshot := ContextCurrent.Bind('trace', 'req-42');
    Token := ContextEnter(Snapshot);
    try
      { Schedule work while the context is installed; the job captures it. }
      Sched.Schedule(CaptureContext, 0);
    finally
      ContextLeave(Token);
    end;
    { Outside the scope now, but the scheduled job still saw the value. }
    AssertEquals('continuation saw the bound value', 'req-42', FSeen);
    AssertFalse('the binding is not visible outside its scope',
      ContextCurrent.TryGet('trace', Outer));
  finally
    Sched.Free;
  end;
end;

procedure TAsyncContextTest.NestedScopesRestore;
var
  V: string;
  T1, T2: TContextToken;
begin
  T1 := ContextEnter(ContextCurrent.Bind('k', 'outer'));
  try
    AssertTrue(ContextCurrent.TryGet('k', V));
    AssertEquals('outer', V);
    T2 := ContextEnter(ContextCurrent.Bind('k', 'inner'));
    try
      AssertTrue(ContextCurrent.TryGet('k', V));
      AssertEquals('inner', V);
    finally
      ContextLeave(T2);
    end;
    AssertTrue(ContextCurrent.TryGet('k', V));
    AssertEquals('restored to outer', 'outer', V);
  finally
    ContextLeave(T1);
  end;
  AssertFalse('gone after the outermost leave', ContextCurrent.TryGet('k', V));
end;

procedure TAsyncContextTest.UnbalancedLeaveRaises;
var
  T1: TContextToken;
  Raised: Boolean;
  Stale: TContextToken;
begin
  T1 := ContextEnter(ContextCurrent.Bind('k', 'outer'));
  Stale.Depth := 99;   { a token from another (deeper) frame }
  Raised := False;
  try
    ContextLeave(Stale);
  except
    on E: EInvalidOp do
      Raised := True;
  end;
  AssertTrue('a mismatched leave is rejected', Raised);
  { The real leave still works. }
  ContextLeave(T1);
end;

initialization
  RegisterTest(TAsyncContextTest);
end.
