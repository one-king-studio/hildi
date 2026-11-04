unit TestTUIClipboard;
{ fpcunit tests for TUIClipboard: the OSC 52 sequence and its base64 payload.

  Checked against RFC 4648 vectors and exact byte strings. "It round-trips" is
  not enough for a clipboard: the terminal either accepts the sequence or
  silently does nothing, so the bytes have to be right the first time and there
  is no error to observe. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIClipboard;

type
  TClipboardTest = class(TTestCase)
  published
    { Base64, against the RFC 4648 test vectors. }
    procedure TestBase64Empty;
    procedure TestBase64OneByte;
    procedure TestBase64TwoBytes;
    procedure TestBase64ThreeBytes;
    procedure TestBase64KnownVectors;
    procedure TestBase64NonAsciiBytes;

    { The OSC 52 sequence itself. }
    procedure TestOsc52EmptyTextEmitsNothing;
    procedure TestOsc52AsciiPayload;
    procedure TestOsc52IsTerminatedWithSt;
    procedure TestOsc52SurroundsThePayloadWithTheCsSelector;
    procedure TestOsc52EncodesAsUtf8;
  end;

implementation

procedure TClipboardTest.TestBase64Empty;
begin
  AssertEquals('nothing in, nothing out', '', Base64Encode(''));
end;

procedure TClipboardTest.TestBase64OneByte;
begin
  { 'f' = 0x66 -> one quantum, two pad characters. }
  AssertEquals('one byte pads twice', 'Zg==', Base64Encode('f'));
end;

procedure TClipboardTest.TestBase64TwoBytes;
begin
  { 'fo' -> one pad character. }
  AssertEquals('two bytes pad once', 'Zm8=', Base64Encode('fo'));
end;

procedure TClipboardTest.TestBase64ThreeBytes;
begin
  { Three bytes is exactly one quantum: no padding. }
  AssertEquals('three bytes need no padding', 'Zm9v', Base64Encode('foo'));
  { Six bytes, two full quanta. }
  AssertEquals('six bytes', 'Zm9vYmFy', Base64Encode('foobar'));
end;

procedure TClipboardTest.TestBase64KnownVectors;
begin
  { RFC 4648 section 10, the two canonical long vectors. }
  AssertEquals('rfc4648 vector 1',
    'cGxlYXN1cmUu', Base64Encode('pleasure.'));
  AssertEquals('rfc4648 vector 2',
    'bGVhc3VyZS4=', Base64Encode('leasure.'));
  AssertEquals('rfc4648 vector 3',
    'ZWFzdXJlLg==', Base64Encode('easure.'));
end;

procedure TClipboardTest.TestBase64NonAsciiBytes;
var
  Src: RawByteString;
begin
  { 0x00 and 0xFF are the two extremes; base64 must handle both, and must not
    treat the payload as text. }
  Src := #0#255;
  AssertEquals('raw bytes are encoded as bytes', 'AP8=', Base64Encode(Src));
end;

procedure TClipboardTest.TestOsc52EmptyTextEmitsNothing;
begin
  { Writing an empty selection would CLEAR the operator's clipboard, which is a
    surprising consequence of copying nothing. Emit nothing instead. }
  AssertEquals('empty text emits no sequence', '', Osc52Clipboard(''));
end;

procedure TClipboardTest.TestOsc52AsciiPayload;
var
  Got: RawByteString;
begin
  Got := Osc52Clipboard('foo');
  AssertTrue('contains the base64 payload', Pos('Zm9v', Got) > 0);
end;

procedure TClipboardTest.TestOsc52IsTerminatedWithSt;
var
  Got: RawByteString;
begin
  Got := Osc52Clipboard('foo');
  AssertTrue('starts with ESC ]', Copy(Got, 1, 2) = #27']');
  AssertTrue('ends with ESC backslash (ST)',
    Copy(Got, Length(Got) - 1, 2) = #27'\');
  AssertTrue('does not use BEL as the terminator',
    Got[Length(Got)] <> #7);
end;

procedure TClipboardTest.TestOsc52SurroundsThePayloadWithTheCsSelector;
var
  Got: RawByteString;
begin
  { ESC ] 52 ; c ; <payload> ESC \  - the 'c' selector is what makes it the
    system clipboard rather than primary. Position 2, because byte 1 is the ESC
    that introduces the OSC introducer itself. }
  Got := Osc52Clipboard('foo');
  AssertEquals('the introducer is ESC ]', #27']', Copy(Got, 1, 2));
  AssertEquals('then the c selector', '52;c;', Copy(Got, 3, 5));
end;

procedure TClipboardTest.TestOsc52EncodesAsUtf8;
var
  Got: RawByteString;
begin
  { A non-ASCII character must survive as UTF-8. U+00E9 is C3 A9, which is
    'w6k=' in base64. }
  Got := Osc52Clipboard(WideChar($00E9));
  AssertTrue('the UTF-8 bytes were encoded', Pos('w6k=', Got) > 0);
end;

initialization
  RegisterTest(TClipboardTest);
end.
