unit test_tui_input;
{ fpcunit tests for hildegard.helper.tui.input.

  Only the scripted source is exercised here; the terminal adapter (keyboard +
  TIOCGWINSZ) is added in the terminal phase and is not needed by these tests. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input;

type
  TTuiInputTest = class(TTestCase)
  private
    function CharEvent(const ACh: UnicodeString): TInputEvent;
    function ResizeEvent(AW, AH: Integer): TInputEvent;
  published
    procedure TestScriptedSourceYieldsQueuedEvents;
    procedure TestScriptedSourceReportsResize;
  end;

implementation

function TTuiInputTest.CharEvent(const ACh: UnicodeString): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := ACh;
end;

function TTuiInputTest.ResizeEvent(AW, AH: Integer): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikResize;
  Result.NewSize.W := AW;
  Result.NewSize.H := AH;
end;

procedure TTuiInputTest.TestScriptedSourceYieldsQueuedEvents;
var
  Src: TInputSourceScripted;
  E: TInputEvent;
begin
  Src := TInputSourceScripted.Create;
  try
    Src.Push(CharEvent('a'));
    E := Default(TInputEvent);
    E.Kind := ikKey;
    E.Key.Kind := kkEnter;
    Src.Push(E);

    E := Default(TInputEvent);
    AssertTrue('first poll returns an event', Src.Poll(E));
    AssertTrue('first is a key', E.Kind = ikKey);
    AssertTrue('first is a char', E.Key.Kind = kkChar);
    AssertEquals('first char retained', 'a', E.Key.Ch);

    E := Default(TInputEvent);
    AssertTrue('second poll returns an event', Src.Poll(E));
    AssertTrue('second is enter', E.Key.Kind = kkEnter);

    AssertFalse('queue is empty afterwards', Src.Poll(E));
  finally
    Src.Free;
  end;
end;

procedure TTuiInputTest.TestScriptedSourceReportsResize;
var
  Src: TInputSourceScripted;
  E: TInputEvent;
begin
  Src := TInputSourceScripted.Create;
  try
    Src.Push(ResizeEvent(80, 24));
    E := Default(TInputEvent);
    AssertTrue('resize polled', Src.Poll(E));
    AssertTrue('kind is resize', E.Kind = ikResize);
    AssertEquals('new width', 80, E.NewSize.W);
    AssertEquals('new height', 24, E.NewSize.H);
  finally
    Src.Free;
  end;
end;

initialization
  RegisterTest(TTuiInputTest);
end.
