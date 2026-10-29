unit AsyncQueue;
{ TBoundedQueue<T>: a thread-safe, fixed-capacity FIFO - the mailbox a producer
  thread fills and a consumer thread drains.

  It is BOUNDED on purpose: an unbounded mailbox is how a fast producer starves
  the consumer (the TUI freeze). When full, Push drops the OLDEST item and counts
  it, so the consumer always sees the most recent window and can report the loss.
  DropOldest lets a caller evict the oldest explicitly, to make room for a
  priority item.

  See docs/features/Async_Core/Async_Core_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, SyncObjs;

type
  TBoundedQueue<T> = class
  private
    FLock: TCriticalSection;
    FItems: TArray<T>;
    FCapacity: Integer;
    FHead: Integer;
    FTail: Integer;
    FCount: Integer;
    FDropped: Int64;
    procedure ReleaseAt(const AIndex: Integer);
  public
    constructor Create(const ACapacity: Integer);
    destructor Destroy; override;

    { Adds AItem; on overflow drops the oldest and returns False. Never blocks. }
    function Push(const AItem: T): Boolean;
    { Removes the oldest item, returning False when empty. Lets a caller make
      room for a priority item. Counts as a drop. }
    function DropOldest: Boolean;
    function TryPop(out AItem: T): Boolean;
    function TryPeek(out AItem: T): Boolean;
    procedure Clear;

    function IsEmpty: Boolean;
    property Count: Integer read FCount;
    property Capacity: Integer read FCapacity;
    { How many items have been dropped to honour the bound. }
    property Dropped: Int64 read FDropped;
  end;

implementation

{ TBoundedQueue<T> }

constructor TBoundedQueue<T>.Create(const ACapacity: Integer);
begin
  inherited Create;
  if ACapacity <= 0 then
    raise EArgumentException.Create('capacity must be positive');
  FLock := TCriticalSection.Create;
  FCapacity := ACapacity;
  SetLength(FItems, ACapacity);
  FHead := 0;
  FTail := 0;
  FCount := 0;
  FDropped := 0;
end;

destructor TBoundedQueue<T>.Destroy;
begin
  { A Create that raises (bad capacity) leaves FLock unset; guard it. }
  if FLock <> nil then
  begin
    Clear;
    FLock.Free;
  end;
  inherited;
end;

procedure TBoundedQueue<T>.ReleaseAt(const AIndex: Integer);
var
  Empty: T;
begin
  { Assign a fresh default so a managed element's reference is released. }
  Empty := Default(T);
  FItems[AIndex] := Empty;
end;

function TBoundedQueue<T>.Push(const AItem: T): Boolean;
begin
  FLock.Acquire;
  try
    if FCount = FCapacity then
    begin
      { Full: overwrite the oldest slot, then both cursors advance together. }
      ReleaseAt(FTail);
      FItems[FTail] := AItem;
      FTail := (FTail + 1) mod FCapacity;
      FHead := FTail;
      Inc(FDropped);
      Exit(False);
    end;
    FItems[FTail] := AItem;
    FTail := (FTail + 1) mod FCapacity;
    Inc(FCount);
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TBoundedQueue<T>.DropOldest: Boolean;
begin
  FLock.Acquire;
  try
    Result := FCount > 0;
    if not Result then
      Exit;
    ReleaseAt(FHead);
    FHead := (FHead + 1) mod FCapacity;
    Dec(FCount);
    Inc(FDropped);
  finally
    FLock.Release;
  end;
end;

function TBoundedQueue<T>.TryPop(out AItem: T): Boolean;
begin
  FLock.Acquire;
  try
    Result := FCount > 0;
    if not Result then
      Exit;
    AItem := FItems[FHead];
    ReleaseAt(FHead);
    FHead := (FHead + 1) mod FCapacity;
    Dec(FCount);
  finally
    FLock.Release;
  end;
end;

function TBoundedQueue<T>.TryPeek(out AItem: T): Boolean;
begin
  FLock.Acquire;
  try
    Result := FCount > 0;
    if Result then
      AItem := FItems[FHead];
  finally
    FLock.Release;
  end;
end;

procedure TBoundedQueue<T>.Clear;
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FCapacity - 1 do
      ReleaseAt(I);
    FHead := 0;
    FTail := 0;
    FCount := 0;
  finally
    FLock.Release;
  end;
end;

function TBoundedQueue<T>.IsEmpty: Boolean;
begin
  FLock.Acquire;
  try
    Result := FCount = 0;
  finally
    FLock.Release;
  end;
end;

end.
