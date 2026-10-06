unit test_tui_clock;
{ fpcunit tests for hildegard.helper.tui.clock: the monotonic source and the
  animation registry that negotiates the app's frame rate. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.clock;

type
  TTuiClockTest = class(TTestCase)
  protected
    procedure SetUp; override;
  published
    procedure TestRegisterAndCount;
    procedure TestMinIntervalIsTheFastest;
    procedure TestRegisterReplacesTheInterval;
    procedure TestNonPositiveUnregisters;
    procedure TestUnregisterUnknownIsANoOp;
    procedure TestEmptyRegistryHasNoInterval;
  end;

implementation

procedure TTuiClockTest.SetUp;
begin
  { The registry is a process singleton; start each test clean. }
  AnimationClock.Reset;
end;

procedure TTuiClockTest.TestRegisterAndCount;
var
  A, B: TObject;
begin
  A := TObject.Create;
  B := TObject.Create;
  try
    AnimationClock.Register(A, 100);
    AnimationClock.Register(B, 50);
    AssertEquals('two registered', 2, AnimationClock.Count);
  finally
    AnimationClock.Reset;
    A.Free;
    B.Free;
  end;
end;

procedure TTuiClockTest.TestMinIntervalIsTheFastest;
var
  A, B, C: TObject;
begin
  A := TObject.Create;
  B := TObject.Create;
  C := TObject.Create;
  try
    AnimationClock.Register(A, 250);
    AnimationClock.Register(B, 30);
    AnimationClock.Register(C, 100);
    AssertEquals('fastest wins', 30, AnimationClock.MinIntervalMs);
  finally
    AnimationClock.Reset;
    A.Free;
    B.Free;
    C.Free;
  end;
end;

procedure TTuiClockTest.TestRegisterReplacesTheInterval;
var
  A: TObject;
begin
  A := TObject.Create;
  try
    AnimationClock.Register(A, 250);
    AssertEquals('first', 250, AnimationClock.MinIntervalMs);
    AnimationClock.Register(A, 40);
    AssertEquals('replaced', 40, AnimationClock.MinIntervalMs);
    AssertEquals('still one entry', 1, AnimationClock.Count);
  finally
    AnimationClock.Reset;
    A.Free;
  end;
end;

procedure TTuiClockTest.TestNonPositiveUnregisters;
var
  A: TObject;
begin
  A := TObject.Create;
  try
    AnimationClock.Register(A, 100);
    AnimationClock.Register(A, 0);
    AssertEquals('gone', 0, AnimationClock.Count);
    AssertEquals('no interval', 0, AnimationClock.MinIntervalMs);
  finally
    AnimationClock.Reset;
    A.Free;
  end;
end;

procedure TTuiClockTest.TestUnregisterUnknownIsANoOp;
var
  A: TObject;
begin
  A := TObject.Create;
  try
    AnimationClock.Unregister(A);   // never registered
    AssertEquals('no interval', 0, AnimationClock.MinIntervalMs);
    AssertEquals('no entries', 0, AnimationClock.Count);
  finally
    AnimationClock.Reset;
    A.Free;
  end;
end;

procedure TTuiClockTest.TestEmptyRegistryHasNoInterval;
begin
  AssertEquals('no interval', 0, AnimationClock.MinIntervalMs);
  AssertEquals('no entries', 0, AnimationClock.Count);
end;

initialization
  RegisterTest(TTuiClockTest);
end.
