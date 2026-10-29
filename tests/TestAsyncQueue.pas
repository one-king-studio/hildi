unit TestAsyncQueue;
{ Tests for TBoundedQueue<T> (docs/features/Async_Core). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  AsyncQueue;

type
  TAsyncQueueTest = class(TTestCase)
  published
    procedure FifoOrder;
    procedure BoundedDropsOldest;
    procedure TryPopOnEmptyReturnsFalse;
    procedure TryPeekDoesNotRemove;
    procedure ClearEmpties;
    procedure RejectsNonPositiveCapacity;
    procedure WrapsAround;
    procedure ManagedElementsRoundTrip;
    procedure DropOldestRemovesHead;
  end;

implementation

procedure TAsyncQueueTest.FifoOrder;
var
  Q: TBoundedQueue<Integer>;
  V: Integer;
begin
  Q := TBoundedQueue<Integer>.Create(4);
  try
    Q.Push(1);
    Q.Push(2);
    Q.Push(3);
    AssertEquals('count', 3, Q.Count);
    AssertTrue(Q.TryPop(V));
    AssertEquals(1, V);
    AssertTrue(Q.TryPop(V));
    AssertEquals(2, V);
    AssertTrue(Q.TryPop(V));
    AssertEquals(3, V);
    AssertFalse('drained', Q.TryPop(V));
  finally
    Q.Free;
  end;
end;

procedure TAsyncQueueTest.BoundedDropsOldest;
var
  Q: TBoundedQueue<Integer>;
  V: Integer;
begin
  Q := TBoundedQueue<Integer>.Create(2);
  try
    AssertTrue(Q.Push(1));
    AssertTrue(Q.Push(2));
    AssertFalse('overflow reports the drop', Q.Push(3));
    AssertEquals('still at capacity', 2, Q.Count);
    AssertEquals('one dropped', 1, Q.Dropped);
    AssertTrue(Q.TryPop(V));
    AssertEquals('oldest (1) was dropped, 2 survives', 2, V);
    AssertTrue(Q.TryPop(V));
    AssertEquals(3, V);
  finally
    Q.Free;
  end;
end;

procedure TAsyncQueueTest.TryPopOnEmptyReturnsFalse;
var
  Q: TBoundedQueue<Integer>;
  V: Integer;
begin
  Q := TBoundedQueue<Integer>.Create(1);
  try
    AssertTrue(Q.IsEmpty);
    AssertFalse(Q.TryPop(V));
  finally
    Q.Free;
  end;
end;

procedure TAsyncQueueTest.TryPeekDoesNotRemove;
var
  Q: TBoundedQueue<Integer>;
  V: Integer;
begin
  Q := TBoundedQueue<Integer>.Create(2);
  try
    Q.Push(7);
    AssertTrue(Q.TryPeek(V));
    AssertEquals(7, V);
    AssertEquals('peek leaves the item', 1, Q.Count);
    AssertTrue(Q.TryPop(V));
    AssertEquals(7, V);
  finally
    Q.Free;
  end;
end;

procedure TAsyncQueueTest.ClearEmpties;
var
  Q: TBoundedQueue<Integer>;
begin
  Q := TBoundedQueue<Integer>.Create(3);
  try
    Q.Push(1);
    Q.Push(2);
    Q.Clear;
    AssertTrue(Q.IsEmpty);
    AssertEquals(0, Q.Count);
  finally
    Q.Free;
  end;
end;

procedure TAsyncQueueTest.RejectsNonPositiveCapacity;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    TBoundedQueue<Integer>.Create(0);
  except
    on E: EArgumentException do
      Raised := True;
  end;
  AssertTrue('capacity must be positive', Raised);
end;

procedure TAsyncQueueTest.WrapsAround;
var
  Q: TBoundedQueue<Integer>;
  V: Integer;
begin
  Q := TBoundedQueue<Integer>.Create(3);
  try
    Q.Push(1);
    Q.Push(2);
    AssertTrue(Q.TryPop(V));
    AssertEquals(1, V);
    Q.Push(3);
    Q.Push(4);
    AssertEquals('wrapped to full', 3, Q.Count);
    AssertTrue(Q.TryPop(V));
    AssertEquals(2, V);
    AssertTrue(Q.TryPop(V));
    AssertEquals(3, V);
    AssertTrue(Q.TryPop(V));
    AssertEquals(4, V);
    AssertFalse(Q.TryPop(V));
  finally
    Q.Free;
  end;
end;

procedure TAsyncQueueTest.ManagedElementsRoundTrip;
var
  Q: TBoundedQueue<string>;
  S: string;
begin
  Q := TBoundedQueue<string>.Create(2);
  try
    Q.Push('alpha');
    Q.Push('beta');
    AssertTrue(Q.TryPop(S));
    AssertEquals('alpha', S);
    AssertTrue(Q.TryPop(S));
    AssertEquals('beta', S);
    Q.Push('gamma');
    AssertTrue(Q.TryPeek(S));
    AssertEquals('gamma', S);
  finally
    Q.Free;
  end;
end;

procedure TAsyncQueueTest.DropOldestRemovesHead;
var
  Q: TBoundedQueue<Integer>;
  V: Integer;
begin
  Q := TBoundedQueue<Integer>.Create(3);
  try
    Q.Push(1);
    Q.Push(2);
    AssertTrue('dropped the head', Q.DropOldest);
    AssertEquals('count fell', 1, Q.Count);
    AssertEquals('counted', 1, Q.Dropped);
    AssertTrue(Q.TryPop(V));
    AssertEquals('2 survives', 2, V);
    AssertFalse('empty', Q.DropOldest);
  finally
    Q.Free;
  end;
end;

initialization
  RegisterTest(TAsyncQueueTest);
end.
