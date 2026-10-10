unit async.context;
{ A continuation-scoped context: ambient values that survive a deferred boundary
  (a scheduler hop) without leaking between unrelated continuations.

  A snapshot is IMMUTABLE; deriving a binding copies it. Enter installs a
  snapshot and returns a depth token; Leave restores the previous snapshot and
  rejects an unbalanced leave (a mismatched token cannot unwind past an enclosing
  frame). The snapshot that is displaced is rooted on a save stack for as long as
  it is displaced.

  The scheduler captures the current snapshot when a job is enqueued and installs
  it while the job runs (see async.scheduler / async.timers), so a value set
  before a deferred boundary is visible inside the continuation and not outside
  it.

  THREAD-LOCAL, NOT GLOBAL. The installed snapshot, the save stack, and the depth
  live in THREADVARS, not module-level globals. A continuation runs on one
  thread, so its context must not be shared across threads; the executor runs
  jobs on many worker threads concurrently, and a process-global save stack (a
  managed dynamic array) raced under that load - concurrent SetLength corrupted
  the heap and wedged the pool. threadvar makes each thread own its context, and
  the managed threadvar is released when the thread exits. A worker thread starts
  with GCurrent = nil (the initialization block runs only on the main thread), so
  ContextCurrent lazily creates an empty snapshot.

  This library has NO dependency on the harness or any engine unit. See
  docs/features/Async_Core/Async_Core_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils,
  async.base;

type
  { An immutable snapshot of ambient values. Deriving copies it. }
  IContextSnapshot = interface
    { A new snapshot with AKey bound to AValue (a copy plus the binding). }
    function Bind(const AKey, AValue: string): IContextSnapshot;
    function TryGet(const AKey: string; out AValue: string): Boolean;
    function Count: Integer;
  end;

  { A depth token: proves that a Leave matches its Enter. }
  TContextToken = record
    Depth: Integer;
  end;

{ The current snapshot (an empty one when none is installed). }
function ContextCurrent: IContextSnapshot;
{ Install a snapshot; returns a token for the matching Leave. }
function ContextEnter(const ASnapshot: IContextSnapshot): TContextToken;
{ Restore the previous snapshot; raises on an unbalanced (mismatched) leave. }
procedure ContextLeave(const AToken: TContextToken);
{ Run AWork with ASnapshot installed, restoring the previous one afterwards. }
procedure ContextRun(const ASnapshot: IContextSnapshot; const AWork: TNotify);

implementation

type
  TContextSnapshot = class(TInterfacedObject, IContextSnapshot)
  private
    FKeys: TArray<string>;
    FValues: TArray<string>;
    function IndexOfKey(const AKey: string): Integer;
  public
    function Bind(const AKey, AValue: string): IContextSnapshot;
    function TryGet(const AKey: string; out AValue: string): Boolean;
    function Count: Integer;
  end;

threadvar
  { Per-thread: a continuation runs on one thread, so the installed snapshot and
    the save stack must not be shared across threads (the executor runs jobs on
    many). A managed threadvar is freed when the thread exits. }
  GCurrent: IContextSnapshot;
  GStack: TArray<IContextSnapshot>;
  GDepth: Integer;

function TContextSnapshot.IndexOfKey(const AKey: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FKeys) do
    if FKeys[I] = AKey then
      Exit(I);
  Result := -1;
end;

function TContextSnapshot.Bind(const AKey, AValue: string): IContextSnapshot;
var
  New: TContextSnapshot;
  I: Integer;
begin
  { Copy, then add (or replace) the binding. Immutable: the receiver is untouched. }
  New := TContextSnapshot.Create;
  SetLength(New.FKeys, Length(FKeys));
  SetLength(New.FValues, Length(FValues));
  for I := 0 to High(FKeys) do
  begin
    New.FKeys[I] := FKeys[I];
    New.FValues[I] := FValues[I];
  end;
  I := New.IndexOfKey(AKey);
  if I >= 0 then
    New.FValues[I] := AValue
  else
  begin
    SetLength(New.FKeys, Length(New.FKeys) + 1);
    SetLength(New.FValues, Length(New.FValues) + 1);
    New.FKeys[High(New.FKeys)] := AKey;
    New.FValues[High(New.FValues)] := AValue;
  end;
  Result := New;
end;

function TContextSnapshot.TryGet(const AKey: string; out AValue: string): Boolean;
var
  I: Integer;
begin
  I := IndexOfKey(AKey);
  Result := I >= 0;
  if Result then
    AValue := FValues[I];
end;

function TContextSnapshot.Count: Integer;
begin
  Result := Length(FKeys);
end;

function ContextCurrent: IContextSnapshot;
begin
  { A worker thread starts with GCurrent = nil (the initialization block runs
    only on the main thread); lazily give it an empty snapshot. }
  if GCurrent = nil then
    GCurrent := TContextSnapshot.Create;
  Result := GCurrent;
end;

function ContextEnter(const ASnapshot: IContextSnapshot): TContextToken;
begin
  { Root the displaced snapshot on the save stack, then install the new one. }
  SetLength(GStack, Length(GStack) + 1);
  GStack[High(GStack)] := GCurrent;
  GCurrent := ASnapshot;
  Inc(GDepth);
  Result.Depth := GDepth;
end;

procedure ContextLeave(const AToken: TContextToken);
begin
  { The token must match the current depth; a stale token cannot unwind past an
    enclosing frame. }
  if AToken.Depth <> GDepth then
    raise EInvalidOp.Create('unbalanced context leave: token depth ' +
      IntToStr(AToken.Depth) + ' at depth ' + IntToStr(GDepth));
  GCurrent := GStack[High(GStack)];
  SetLength(GStack, Length(GStack) - 1);
  Dec(GDepth);
end;

procedure ContextRun(const ASnapshot: IContextSnapshot; const AWork: TNotify);
var
  Token: TContextToken;
begin
  Token := ContextEnter(ASnapshot);
  try
    AWork();
  finally
    ContextLeave(Token);
  end;
end;

initialization
  GCurrent := TContextSnapshot.Create;
  GDepth := 0;

end.
