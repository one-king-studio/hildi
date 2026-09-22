unit test_tui_input;
{ fpcunit tests for hildegard.helper.tui.input.

  Only the scripted source is exercised here; the terminal adapter (keyboard +
  TIOCGWINSZ) is added in the terminal phase and is not needed by these tests. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.input.decode;

type
  TTuiInputTest = class(TTestCase)
  private
    function CharEvent(const ACh: UnicodeString): TInputEvent;
    function ResizeEvent(AW, AH: Integer): TInputEvent;
  published
    procedure TestScriptedSourceYieldsQueuedEvents;
    procedure TestScriptedSourceReportsResize;
    procedure TestDecodePrintableChar;
    procedure TestDecodeControlKeys;
    procedure TestDecodeEscape;
    procedure TestDecodeArrowsAndModifiers;
    procedure TestDecodePageHomeEndDelete;
    procedure TestDecodeFunctionKeys;
    procedure TestDecodeUtf8;
    procedure TestDecodeIncompleteSequenceBuffers;
    procedure TestDecodeIgnoresUnknownSequence;
    procedure TestDecodeMouseWheel;
    procedure TestDecodeMouseMotionAndRelease;
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

procedure TTuiInputTest.TestDecodePrintableChar;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    D.Feed([Ord('a')]);
    AssertTrue('decoded', D.Next(E));
    AssertTrue('char kind', E.Key.Kind = kkChar);
    AssertEquals('char value', 'a', E.Key.Ch);
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeControlKeys;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    D.Feed([13]);
    AssertTrue('enter', D.Next(E) and (E.Key.Kind = kkEnter));
    D.Feed([9]);
    AssertTrue('tab', D.Next(E) and (E.Key.Kind = kkTab));
    D.Feed([127]);
    AssertTrue('backspace (DEL)', D.Next(E) and (E.Key.Kind = kkBackspace));
    D.Feed([8]);
    AssertTrue('backspace (BS)', D.Next(E) and (E.Key.Kind = kkBackspace));
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeEscape;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    D.Feed([27]);
    AssertTrue('escape', D.Next(E) and (E.Key.Kind = kkEscape));
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeArrowsAndModifiers;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    D.Feed([27, Ord('['), Ord('A')]);
    AssertTrue('up', D.Next(E) and (E.Key.Kind = kkUp));
    D.Feed([27, Ord('['), Ord('B')]);
    AssertTrue('down', D.Next(E) and (E.Key.Kind = kkDown));
    D.Feed([27, Ord('['), Ord('1'), Ord(';'), Ord('5'), Ord('A')]);
    AssertTrue('ctrl+up', D.Next(E) and (E.Key.Kind = kkUp));
    AssertTrue('ctrl modifier', moCtrl in E.Key.Mods);
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodePageHomeEndDelete;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    D.Feed([27, Ord('['), Ord('5'), Ord('~')]);
    AssertTrue('page up', D.Next(E) and (E.Key.Kind = kkPageUp));
    D.Feed([27, Ord('['), Ord('6'), Ord('~')]);
    AssertTrue('page down', D.Next(E) and (E.Key.Kind = kkPageDown));
    D.Feed([27, Ord('['), Ord('H')]);
    AssertTrue('home', D.Next(E) and (E.Key.Kind = kkHome));
    D.Feed([27, Ord('['), Ord('F')]);
    AssertTrue('end', D.Next(E) and (E.Key.Kind = kkEnd));
    D.Feed([27, Ord('['), Ord('3'), Ord('~')]);
    AssertTrue('delete', D.Next(E) and (E.Key.Kind = kkDelete));
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeFunctionKeys;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    D.Feed([27, Ord('O'), Ord('P')]);
    AssertTrue('F1', D.Next(E) and (E.Key.Kind = kkFunction));
    AssertEquals('F1 index', 1, E.Key.FuncIndex);
    D.Feed([27, Ord('['), Ord('2'), Ord('4'), Ord('~')]);
    AssertTrue('F12', D.Next(E) and (E.Key.Kind = kkFunction));
    AssertEquals('F12 index', 12, E.Key.FuncIndex);
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeUtf8;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    D.Feed([$C3, $A9]);  { U+00E9 e-acute }
    AssertTrue('utf8 decoded', D.Next(E));
    AssertTrue('char kind', E.Key.Kind = kkChar);
    AssertEquals('code point', UnicodeString(WideChar($E9)), E.Key.Ch);
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeIncompleteSequenceBuffers;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    D.Feed([27, Ord('[')]);
    AssertFalse('incomplete CSI waits', D.Next(E));
    AssertEquals('bytes buffered', 2, D.Buffered);
    D.Feed([Ord('A')]);
    AssertTrue('completed', D.Next(E));
    AssertTrue('is up', E.Key.Kind = kkUp);
    AssertEquals('buffer drained', 0, D.Buffered);
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeIgnoresUnknownSequence;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    { A terminal DA1 report ESC[?1;2c followed by a real key 'q': the report must
      be consumed, not decoded as stray characters. }
    D.Feed([27, Ord('['), Ord('?'), Ord('1'), Ord(';'), Ord('2'),
      Ord('c'), Ord('q')]);
    AssertTrue('next event after report', D.Next(E));
    AssertTrue('is char', E.Key.Kind = kkChar);
    AssertEquals('the real key', 'q', E.Key.Ch);
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeMouseWheel;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    { SGR mouse: ESC [ < Cb ; Cx ; Cy M ; wheel up Cb=64 at (10,5) }
    D.Feed([27, Ord('['), Ord('<'), Ord('6'), Ord('4'), Ord(';'),
      Ord('1'), Ord('0'), Ord(';'), Ord('5'), Ord('M')]);
    AssertTrue('wheel decoded', D.Next(E));
    AssertTrue('is mouse', E.Kind = ikMouse);
    AssertTrue('wheel up', E.Mouse.Button = mbWheelUp);
    AssertEquals('mouse x', 9, E.Mouse.X);
    AssertEquals('mouse y', 4, E.Mouse.Y);
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeMouseMotionAndRelease;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    { Motion with the left button held: Cb has the 0x20 motion bit. }
    D.Feed([27, Ord('['), Ord('<'), Ord('3'), Ord('2'), Ord(';'),
      Ord('5'), Ord(';'), Ord('5'), Ord('M')]);
    AssertTrue('motion decoded', D.Next(E));
    AssertTrue('is mouse', E.Kind = ikMouse);
    AssertTrue('left button held', E.Mouse.Button = mbLeft);

    { Release (final 'm') ends the button. }
    D.Feed([27, Ord('['), Ord('<'), Ord('0'), Ord(';'),
      Ord('5'), Ord(';'), Ord('5'), Ord('m')]);
    AssertTrue('release decoded', D.Next(E));
    AssertTrue('button released', E.Mouse.Button = mbNone);
  finally
    D.Free;
  end;
end;

initialization
  RegisterTest(TTuiInputTest);
end.
