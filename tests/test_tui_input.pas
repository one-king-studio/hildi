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
    procedure TestDecodeKittyKeyboard;
    procedure TestDecodeKittyFunctionalKeysIgnored;
    procedure TestDecodeKittyShiftedAndTextKeys;
    procedure TestDecodeKittyEventTypes;
    procedure TestDecodeConsumesOscReply;
    procedure TestParseOsc11Background;
    procedure TestDecodeShiftEnter;
    procedure TestDecodeAltBackspace;
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

procedure TTuiInputTest.TestDecodeKittyKeyboard;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    { CSI 9 u = Tab press (kitty keyboard protocol). }
    D.Feed([27, Ord('['), Ord('9'), Ord('u')]);
    AssertTrue('tab press', D.Next(E) and (E.Key.Kind = kkTab));

    { CSI 113 u = 'q' press. }
    D.Feed([27, Ord('['), Ord('1'), Ord('1'), Ord('3'), Ord('u')]);
    AssertTrue('q press', D.Next(E));
    AssertTrue('is char', E.Key.Kind = kkChar);
    AssertEquals('char value', 'q', E.Key.Ch);

    { CSI 113;5 u = Ctrl+'q'; CSI 9;1:3 u is a release and is ignored. }
    D.Feed([27, Ord('['), Ord('1'), Ord('1'), Ord('3'), Ord(';'),
      Ord('5'), Ord('u')]);
    AssertTrue('ctrl q press', D.Next(E));
    AssertTrue('ctrl set', moCtrl in E.Key.Mods);

    D.Feed([27, Ord('['), Ord('9'), Ord(';'), Ord('1'), Ord(':'),
      Ord('3'), Ord('u')]);
    AssertFalse('release ignored', D.Next(E));
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeKittyFunctionalKeysIgnored;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    { CSI 57441;2 u = left shift press. Holding a modifier must not emit a
      private-use character. }
    D.Feed([27, Ord('['), Ord('5'), Ord('7'), Ord('4'), Ord('4'), Ord('1'),
      Ord(';'), Ord('2'), Ord('u')]);
    AssertFalse('left shift ignored', D.Next(E));

    { CSI 57441;2:2 u = left shift repeat. }
    D.Feed([27, Ord('['), Ord('5'), Ord('7'), Ord('4'), Ord('4'), Ord('1'),
      Ord(';'), Ord('2'), Ord(':'), Ord('2'), Ord('u')]);
    AssertFalse('left shift repeat ignored', D.Next(E));

    { CSI 57358 u = caps lock. }
    D.Feed([27, Ord('['), Ord('5'), Ord('7'), Ord('3'), Ord('5'), Ord('8'),
      Ord('u')]);
    AssertFalse('caps lock ignored', D.Next(E));

    { A following normal key still decodes. }
    D.Feed([27, Ord('['), Ord('1'), Ord('1'), Ord('3'), Ord('u')]);
    AssertTrue('q still decodes', D.Next(E) and (E.Key.Kind = kkChar));
    AssertEquals('char value', 'q', E.Key.Ch);
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeKittyShiftedAndTextKeys;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    { Shift+/ with alternate and associated text: base 47 '/', shifted 63 '?',
      text 63. Must produce '?', not '/' and not nothing. }
    D.Feed([27, Ord('['), Ord('4'), Ord('7'), Ord(':'), Ord('6'), Ord('3'),
      Ord(';'), Ord('2'), Ord(';'), Ord('6'), Ord('3'), Ord('u')]);
    AssertTrue('shift+/ decodes', D.Next(E));
    AssertTrue('is char', E.Key.Kind = kkChar);
    AssertEquals('shifted char', '?', E.Key.Ch);
    AssertTrue('shift modifier', moShift in E.Key.Mods);

    { Shift+a: base 97, shifted 65, text 65 -> 'A'. }
    D.Feed([27, Ord('['), Ord('9'), Ord('7'), Ord(':'), Ord('6'), Ord('5'),
      Ord(';'), Ord('2'), Ord(';'), Ord('6'), Ord('5'), Ord('u')]);
    AssertTrue('shift+a decodes', D.Next(E));
    AssertEquals('shifted letter', 'A', E.Key.Ch);

    { Alternate key with no associated text still resolves via the shifted key. }
    D.Feed([27, Ord('['), Ord('4'), Ord('7'), Ord(':'), Ord('6'), Ord('3'),
      Ord(';'), Ord('2'), Ord('u')]);
    AssertTrue('alt key decodes', D.Next(E));
    AssertEquals('alt char', '?', E.Key.Ch);

    { Plain key with associated text decodes to that text. }
    D.Feed([27, Ord('['), Ord('9'), Ord('7'), Ord(';'), Ord('1'), Ord(';'),
      Ord('9'), Ord('7'), Ord('u')]);
    AssertTrue('plain text key decodes', D.Next(E));
    AssertEquals('plain char', 'a', E.Key.Ch);

    { Ctrl+c: base 99 with ctrl; no control-code text field. }
    D.Feed([27, Ord('['), Ord('9'), Ord('9'), Ord(';'), Ord('5'), Ord('u')]);
    AssertTrue('ctrl c decodes', D.Next(E));
    AssertEquals('ctrl char', 'c', E.Key.Ch);
    AssertTrue('ctrl modifier', moCtrl in E.Key.Mods);
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeKittyEventTypes;
var
  D: TKeyDecoder;
  E: TInputEvent;
begin
  D := TKeyDecoder.Create;
  try
    { Down press `CSI 1;1B`, repeat `CSI 1;1:2B`, release `CSI 1;1:3B`. Only the
      press and repeat are events; the release must be ignored, or one tap moves
      the selection twice. }
    D.Feed([27, Ord('['), Ord('1'), Ord(';'), Ord('1'), Ord('B')]);
    AssertTrue('press is Down', D.Next(E) and (E.Key.Kind = kkDown));

    D.Feed([27, Ord('['), Ord('1'), Ord(';'), Ord('1'), Ord(':'), Ord('2'),
      Ord('B')]);
    AssertTrue('repeat is Down', D.Next(E) and (E.Key.Kind = kkDown));

    D.Feed([27, Ord('['), Ord('1'), Ord(';'), Ord('1'), Ord(':'), Ord('3'),
      Ord('B')]);
    AssertFalse('release ignored', D.Next(E));

    { Shift+Up release `CSI 1;2:3A` is ignored; a repeat carries its modifier. }
    D.Feed([27, Ord('['), Ord('1'), Ord(';'), Ord('2'), Ord(':'), Ord('3'),
      Ord('A')]);
    AssertFalse('shift release ignored', D.Next(E));
    D.Feed([27, Ord('['), Ord('1'), Ord(';'), Ord('5'), Ord(':'), Ord('2'),
      Ord('A')]);
    AssertTrue('ctrl repeat is Up', D.Next(E) and (E.Key.Kind = kkUp));
    AssertTrue('ctrl modifier kept', moCtrl in E.Key.Mods);

    { A `~`-form release is ignored too. }
    D.Feed([27, Ord('['), Ord('5'), Ord(';'), Ord('1'), Ord(':'), Ord('3'),
      Ord('~')]);
    AssertFalse('page-up release ignored', D.Next(E));
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeConsumesOscReply;
var
  D: TKeyDecoder;
  E: TInputEvent;
  S: AnsiString;
  I: Integer;
  Data: array of Byte;
begin
  D := TKeyDecoder.Create;
  try
    { An OSC 11 background reply followed by a real key: the reply must be
      consumed whole (a bare ESC used to leak it as stray characters). }
    S := #27']11;rgb:1e1e/1e1e/1e1e'#27'\' + 'a';
    SetLength(Data, Length(S));
    for I := 1 to Length(S) do
      Data[I - 1] := Ord(S[I]);
    D.Feed(Data);
    AssertTrue('the OSC reply is consumed, then the key decodes',
      D.Next(E) and (E.Key.Kind = kkChar) and (E.Key.Ch = 'a'));
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestParseOsc11Background;
var
  R, G, B: Byte;
begin
  AssertTrue('xterm reply',
    ParseOsc11Background(']11;rgb:1e1e/2a2a/3b3b', R, G, B));
  AssertEquals('red', Integer($1e), Integer(R));
  AssertEquals('green', Integer($2a), Integer(G));
  AssertEquals('blue', Integer($3b), Integer(B));
  AssertTrue('short channels', ParseOsc11Background(']11;rgb:ff/00/80', R, G, B));
  AssertEquals('short red', 255, Integer(R));
  AssertEquals('short blue', 128, Integer(B));
  AssertFalse('not a reply', ParseOsc11Background(']11;rgb:zz', R, G, B));
  AssertFalse('not present', ParseOsc11Background('rgb:ff/ff/ff', R, G, B));
end;

procedure TTuiInputTest.TestDecodeShiftEnter;
var
  D: TKeyDecoder;
  E: TInputEvent;
  S: AnsiString;
  I: Integer;
  Data: array of Byte;
begin
  D := TKeyDecoder.Create;
  try
    S := #27'[13;2u';
    SetLength(Data, Length(S));
    for I := 1 to Length(S) do
      Data[I - 1] := Ord(S[I]);
    D.Feed(Data);
    AssertTrue('shift+enter is enter', D.Next(E) and (E.Key.Kind = kkEnter));
    AssertTrue('with the shift modifier', moShift in E.Key.Mods);
  finally
    D.Free;
  end;
end;

procedure TTuiInputTest.TestDecodeAltBackspace;
var
  D: TKeyDecoder;
  E: TInputEvent;
  S: AnsiString;
  I: Integer;
  Data: array of Byte;
begin
  { A plain terminal sends ESC DEL for Alt+Backspace; both bytes are consumed. }
  D := TKeyDecoder.Create;
  try
    S := #27#127;
    SetLength(Data, Length(S));
    for I := 1 to Length(S) do
      Data[I - 1] := Ord(S[I]);
    D.Feed(Data);
    AssertTrue('alt+backspace decoded', D.Next(E));
    AssertTrue('is a backspace', E.Key.Kind = kkBackspace);
    AssertTrue('with the alt modifier', moAlt in E.Key.Mods);
    AssertFalse('and nothing is left behind', D.Next(E));
  finally
    D.Free;
  end;
end;

initialization
  RegisterTest(TTuiInputTest);
end.
