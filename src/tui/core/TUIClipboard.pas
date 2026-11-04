unit TUIClipboard;
{ Writing text to the terminal's clipboard with OSC 52.

  The application emits `ESC ] 52 ; c ; <base64> ST` and the terminal applies it
  - locally, or on the user's machine over SSH, where no other mechanism in the
  app's power can reach. This is the ONE reason the feature exists: terminal
  selection copies on the remote display's terms, and over SSH there is no
  shared clipboard at all.

  Pure: bytes in, bytes out. No terminal handle, no surface, no widget, so the
  sequence is unit-tested at the byte level and a caller decides where to send
  it. `ISurface.SetClipboard` is that caller.

  Note the FEATURE document claimed the encoder was "already equipped to emit"
  OSC. It was not - TUIEncoder emits SGR only, and the only OSC in the tree was
  INPUT (the OSC 11 theme reply). This unit is that missing emission path. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils;

{ Standard base64 (RFC 4648, with padding). OSC 52 requires it; the URL-safe
  variant used for OAuth tokens is a different alphabet and would be rejected. }
function Base64Encode(const AData: RawByteString): string;

{ The complete OSC 52 write: ESC ] 52 ; c ; <base64> ESC \

  `c` selects the system clipboard (as opposed to primary or select). ST rather
  than BEL as the terminator: it is the standard form and is unambiguous inside
  a stream that already contains BEL-free content.

  The payload is UTF-8, so non-ASCII text survives. An empty text yields an
  empty string: there is nothing to write, and emitting a sequence that CLEARS
  the operator's clipboard would be a surprising side effect of copying nothing. }
function Osc52Clipboard(const AText: UnicodeString): RawByteString;

implementation

const
  Base64Alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function Base64Encode(const AData: RawByteString): string;
var
  I, N: Integer;
  B0, B1, B2: Cardinal;
begin
  Result := '';
  N := Length(AData);
  I := 1;
  while I <= N do
  begin
    B0 := Byte(AData[I]);
    if I + 1 <= N then B1 := Byte(AData[I + 1]) else B1 := 0;
    if I + 2 <= N then B2 := Byte(AData[I + 2]) else B2 := 0;

    Result := Result + Base64Alphabet[1 + (B0 shr 2)];
    Result := Result + Base64Alphabet[1 + (((B0 and 3) shl 4) or (B1 shr 4))];
    if I + 1 <= N then
      Result := Result + Base64Alphabet[1 + (((B1 and 15) shl 2) or (B2 shr 6))]
    else
      Result := Result + '=';
    if I + 2 <= N then
      Result := Result + Base64Alphabet[1 + (B2 and 63)]
    else
      Result := Result + '=';

    Inc(I, 3);
  end;
end;

function Osc52Clipboard(const AText: UnicodeString): RawByteString;
var
  Payload: RawByteString;
begin
  Result := '';
  if AText = '' then
    Exit;
  Payload := UTF8Encode(AText);
  Result := #27']52;c;' + RawByteString(Base64Encode(Payload)) + #27'\';
end;

end.
