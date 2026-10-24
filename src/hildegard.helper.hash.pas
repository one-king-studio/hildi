unit hildegard.helper.hash;
{ Content hashing, over the vendored mbedTLS shim.

  Its own unit because a hash is a primitive several subsystems want (the OAuth
  flow, the change log's compare-and-swap) and none of them should have to link
  the OAuth implementation to get one. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils;

{ SHA-256 of AData as a 32-byte array. }
function Sha256(const AData: string): TBytes;

{ The same, as 64 lowercase hex characters - the form a change record stores and
  compares. }
function Sha256Hex(const AData: string): string;

{ SHA-256 of a file's contents. False + AError when it cannot be read. A file is
  read whole: the caller is expected to have capped its size already. }
function Sha256File(const APath: string; out ADigest, AError: string): Boolean;

{ MD5, as 32 lowercase hex characters.

  Not a secure hash and must never be used where a digest is a security claim.
  It is here because `md5sum` is what a great many shell scripts and published
  checksums ask for, and refusing it pushed the whole script out of the gated
  tier. A cryptographic reading of an MD5 is a reader's mistake, not this unit's.

  Pure Pascal: the vendored shim exposes SHA-256 only. }
function Md5Hex(const AData: string): string;

implementation

{ The native shim (src/hildegard_tls_shim.c), linked from build/libstatic. }
function hildegard_sha256(data: PByte; len: Cardinal;
  out_: PByte): Integer; cdecl; external;

function Sha256(const AData: string): TBytes;
begin
  Result := nil;
  SetLength(Result, 32);
  if Length(AData) > 0 then
    hildegard_sha256(PByte(@AData[1]), Length(AData), PByte(@Result[0]))
  else
    hildegard_sha256(nil, 0, PByte(@Result[0]));
end;

function Sha256Hex(const AData: string): string;
const
  Hex = '0123456789abcdef';
var
  Digest: TBytes;
  I: Integer;
begin
  Digest := Sha256(AData);
  Result := '';
  for I := 0 to High(Digest) do
    Result := Result + Hex[(Digest[I] shr 4) + 1] + Hex[(Digest[I] and $0F) + 1];
end;

function Sha256File(const APath: string; out ADigest, AError: string): Boolean;
var
  Fs: TFileStream;
  Data: string;
  Size: Int64;
begin
  Result := False;
  ADigest := '';
  AError := '';
  if not FileExists(APath) then
  begin
    AError := 'no such file: ' + APath;
    Exit;
  end;
  try
    Fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      Size := Fs.Size;
      SetLength(Data, Size);
      if Size > 0 then
        Fs.ReadBuffer(Data[1], Size);
    finally
      Fs.Free;
    end;
  except
    on E: Exception do
    begin
      AError := 'could not read ' + APath + ': ' + E.Message;
      Exit;
    end;
  end;
  ADigest := Sha256Hex(Data);
  Result := True;
end;

{ 32-bit rotate left.

  Locally unchecked because the build enables range and overflow checking (-Cr
  -Co) and this shift is 32-bit arithmetic: FPC range-checks the result of an
  unsigned shift, which MD5 needs to wrap. Same reasoning and the same directive
  pair as the FNV hasher in tests/test_changes.pas. }
function Rotl32(V: LongWord; N: Byte): LongWord;
begin
  {$push}{$Q-}{$R-}
  Result := (V shl N) or (V shr (32 - N));
  {$pop}
end;

{ MD5 (RFC 1321). Pure Pascal because the vendored shim exposes SHA-256 only.

  NOT A SECURE HASH. Collisions are trivial to construct; it is here for script
  compatibility, never as a security claim. }
function Md5Hex(const AData: string): string;
const
  S: array[0..63] of Byte = (
    7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21);
  K: array[0..63] of LongWord = (
    $d76aa478,$e8c7b756,$242070db,$c1bdceee,$f57c0faf,$4787c62a,$a8304613,
    $fd469501,$698098d8,$8b44f7af,$ffff5bb1,$895cd7be,$6b901122,$fd987193,
    $a679438e,$49b40821,$f61e2562,$c040b340,$265e5a51,$e9b6c7aa,$d62f105d,
    $02441453,$d8a1e681,$e7d3fbc8,$21e1cde6,$c33707d6,$f4d50d87,$455a14ed,
    $a9e3e905,$fcefa3f8,$676f02d9,$8d2a4c8a,$fffa3942,$8771f681,$6d9d6122,
    $fde5380c,$a4beea44,$4bdecfa9,$f6bb4b60,$bebfbc70,$289b7ec6,$eaa127fa,
    $d4ef3085,$04881d05,$d9d4d039,$e6db99e5,$1fa27cf8,$c4ac5665,$f4292244,
    $432aff97,$ab9423a7,$fc93a039,$655b59c3,$8f0ccc92,$ffeff47d,$85845dd1,
    $6fa87e4f,$fe2ce6e0,$a3014314,$4e0811a1,$f7537e82,$bd3af235,$2ad7d2bb,
    $eb86d391);
  Hex = '0123456789abcdef';
var
  Msg: TBytes;
  H: array[0..3] of LongWord;
  M: array[0..15] of LongWord;
  I, J, Chunk: Integer;
  A, B, C, D, F, Tmp: LongWord;
  G, OrigLen: Int64;
  Padded, Digest: TBytes;
  BitLen: array[0..7] of Byte;
  W: LongWord;
begin
  // Pad: original bytes, 0x80, zeros to 56 mod 64, then the bit length LE.
  OrigLen := Length(AData);
  G := (OrigLen + 9 + 63) div 64 * 64;
  SetLength(Padded, G);
  if OrigLen > 0 then
    Move(AData[1], Padded[0], OrigLen);
  Padded[OrigLen] := $80;
  FillChar(BitLen, SizeOf(BitLen), 0);
  Tmp := LongWord(OrigLen * 8);
  for I := 0 to 3 do
    BitLen[I] := Byte((Tmp shr (8 * I)) and $FF);
  W := LongWord(OrigLen shr 29);
  for I := 0 to 3 do
    BitLen[4 + I] := Byte((W shr (8 * I)) and $FF);
  Move(BitLen[0], Padded[G - 8], 8);

  H[0] := $67452301; H[1] := $efcdab89;
  H[2] := $98badcfe; H[3] := $10325476;

  { MD5 is DEFINED on 32-bit modular arithmetic: every add below is meant to wrap,
    and both the rotate and the additions overflow by design. The build enables
    range and overflow checking (-Cr -Co), so the whole compression loop is
    compiled unchecked - otherwise every call raises ERangeError on the first
    addition. The rotates need this even for an empty input, because a single
    padding block is always compressed. }
  {$push}{$Q-}{$R-}
  Chunk := 0;
  while Chunk < G do
  begin
    for I := 0 to 15 do
    begin
      M[I] := LongWord(Padded[Chunk + I * 4]) or
        (LongWord(Padded[Chunk + I * 4 + 1]) shl 8) or
        (LongWord(Padded[Chunk + I * 4 + 2]) shl 16) or
        (LongWord(Padded[Chunk + I * 4 + 3]) shl 24);
    end;
    A := H[0]; B := H[1]; C := H[2]; D := H[3];
    for I := 0 to 63 do
    begin
      case I div 16 of
        0: F := (B and C) or ((not B) and D);
        1: F := (D and B) or ((not D) and C);
        2: F := B xor C xor D;
      else
        F := C xor (B or (not D));
      end;
      case I div 16 of
        0: J := I;
        1: J := (5 * I + 1) mod 16;
        2: J := (3 * I + 5) mod 16;
      else
        J := (7 * I) mod 16;
      end;
      Tmp := D;
      D := C;
      C := B;
      B := B + Rotl32(A + F + K[I] + M[J], S[I]);
      A := Tmp;
    end;
    Inc(H[0], A); Inc(H[1], B); Inc(H[2], C); Inc(H[3], D);
    Inc(Chunk, 64);
  end;
  {$pop}

  SetLength(Digest, 16);
  for I := 0 to 3 do
    for J := 0 to 3 do
      Digest[I * 4 + J] := Byte((H[I] shr (8 * J)) and $FF);

  Result := '';
  for I := 0 to 15 do
    Result := Result + Hex[(Digest[I] shr 4) + 1] +
      Hex[(Digest[I] and $0F) + 1];
end;

end.
