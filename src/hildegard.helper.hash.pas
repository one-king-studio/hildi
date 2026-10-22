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

end.
