unit hildi.tls;
{ A TSSLSocketHandler backed by the vendored mbedTLS shim, registered as the
  process default TLS handler so TFPHTTPClient uses it with no HTTP-client
  change. This is the only Pascal unit that knows about mbedTLS; it holds an
  opaque shim handle and never mirrors a C struct. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, sslbase, sslsockets;

type
  { Client TLS over the vendored mbedTLS shim. Client certificates are not used
    in v1 (the shim verifies the server chain and hostname only). }
  TMbedTLSSocketHandler = class(TSSLSocketHandler)
  private
    FHandle: Pointer;
    FLastErrorString: string;
    FLastErrorCode: Integer;
    function EnsureHandle: Pointer;
    procedure RecordError;
  protected
    function GetLastSSLErrorString: String; override;
    function GetLastSSLErrorCode: Integer; override;
  public
    destructor Destroy; override;
    { No certificate generation: this handler is client-only, and the base
      CreateCertGenerator raises when unimplemented. }
    function CreateCertGenerator: TX509Certificate; override;
    function Connect: Boolean; override;
    function Close: Boolean; override;
    function Shutdown(BiDirectional: Boolean): Boolean; override;
    function Send(const Buffer; Count: Integer): Integer; override;
    function Recv(const Buffer; Count: Integer): Integer; override;
    function BytesAvailable: Integer; override;
  end;

{ The CA bundle override from HILDI_CA_BUNDLE, or '' when unset (the
  embedded bundle is used). }
function TLSBundleOverride: string;

{ True when the resolved CA source is usable. AError is a distinct, actionable
  message when an override is set but unreadable; '' on success. }
function ValidateTLSConfig(out AError: string): Boolean;

const
  { Shim result codes (see src/hildi_tls_shim.h). }
  HILDI_TLS_WOULD_BLOCK = -1;
  HILDI_TLS_ERROR = -2;

implementation

uses
  ssockets;

{ The native shim (src/hildi_tls_shim.c), linked from build/libstatic. }
function hildi_tls_new: Pointer; cdecl; external;
procedure hildi_tls_free(h: Pointer); cdecl; external;
function hildi_tls_set_ca_mem(h: Pointer; pem: Pointer;
  len: Cardinal): Integer; cdecl; external;
function hildi_tls_set_ca_file(h: Pointer; path: PAnsiChar): Integer;
  cdecl; external;
function hildi_tls_connect(h: Pointer; fd: Integer; host: PAnsiChar): Integer;
  cdecl; external;
function hildi_tls_read(h: Pointer; buf: Pointer; len: Integer): Integer;
  cdecl; external;
function hildi_tls_write(h: Pointer; buf: Pointer; len: Integer): Integer;
  cdecl; external;
function hildi_tls_pending(h: Pointer): Integer; cdecl; external;
function hildi_tls_close(h: Pointer): Integer; cdecl; external;
function hildi_tls_last_error(h: Pointer; buf: PAnsiChar;
  buflen: Cardinal): Integer; cdecl; external;
function hildi_ca_pem: Pointer; cdecl; external;
function hildi_ca_pem_len: Cardinal; cdecl; external;

{ --- handler ------------------------------------------------------------ }

function TMbedTLSSocketHandler.CreateCertGenerator: TX509Certificate;
begin
  Result := nil;
end;

function TMbedTLSSocketHandler.EnsureHandle: Pointer;
begin
  if FHandle = nil then
    FHandle := hildi_tls_new;
  Result := FHandle;
end;

procedure TMbedTLSSocketHandler.RecordError;
var
  Buf: array[0..255] of AnsiChar;
begin
  FLastErrorCode := 0;
  FLastErrorString := '';
  if FHandle = nil then
    Exit;
  FLastErrorCode := hildi_tls_last_error(FHandle, @Buf[0], SizeOf(Buf));
  FLastErrorString := string(AnsiString(PAnsiChar(@Buf[0])));
end;

destructor TMbedTLSSocketHandler.Destroy;
begin
  if FHandle <> nil then
  begin
    hildi_tls_free(FHandle);
    FHandle := nil;
  end;
  inherited Destroy;
end;

function TMbedTLSSocketHandler.Connect: Boolean;
var
  CAPath, Host: string;
begin
  Result := False;
  if (Socket = nil) or (EnsureHandle = nil) then
    Exit;

  { CA source, in order: the FPC-native CertificateData path (set by
    TFPHTTPClient from CertCAFileName), the HILDI_CA_BUNDLE override, then
    the embedded bundle. }
  CAPath := CertificateData.CertCA.FileName;
  if CAPath = '' then
    CAPath := TLSBundleOverride;
  if CAPath <> '' then
  begin
    if hildi_tls_set_ca_file(FHandle, PAnsiChar(AnsiString(CAPath))) <> 0 then
    begin
      RecordError;
      Exit;
    end;
  end
  else if hildi_tls_set_ca_mem(FHandle, hildi_ca_pem,
    hildi_ca_pem_len) <> 0 then
  begin
    RecordError;
    Exit;
  end;

  if Socket is TInetSocket then
    Host := TInetSocket(Socket).Host
  else
    Host := CertificateData.HostName;

  if hildi_tls_connect(FHandle, Integer(Socket.Handle),
    PAnsiChar(AnsiString(Host))) <> 0 then
  begin
    RecordError;
    Exit;
  end;

  SetSSLActive(True);
  Result := True;
end;

function TMbedTLSSocketHandler.Close: Boolean;
begin
  if FHandle <> nil then
    hildi_tls_close(FHandle);
  SetSSLActive(False);
  Result := True;
end;

function TMbedTLSSocketHandler.Shutdown(BiDirectional: Boolean): Boolean;
begin
  Result := Close;
end;

function TMbedTLSSocketHandler.Recv(const Buffer; Count: Integer): Integer;
var
  N: Integer;
begin
  FLastError := 0;
  FLastErrorCode := 0;
  FLastErrorString := '';
  if FHandle = nil then
    Exit(0);
  N := hildi_tls_read(FHandle, @Buffer, Count);
  if N = HILDI_TLS_WOULD_BLOCK then
  begin
    { A read that would block means the socket timeout expired; the OpenSSL
      handler treats this as EOF when IOTimeout is set. Match it, and never
      busy-spin. }
    Exit(0);
  end;
  if N = HILDI_TLS_ERROR then
  begin
    RecordError;
    FLastError := FLastErrorCode;
    Exit(-1);
  end;
  Result := N;
end;

function TMbedTLSSocketHandler.Send(const Buffer; Count: Integer): Integer;
var
  N: Integer;
begin
  FLastError := 0;
  FLastErrorCode := 0;
  FLastErrorString := '';
  if FHandle = nil then
    Exit(-1);
  N := hildi_tls_write(FHandle, @Buffer, Count);
  if N = HILDI_TLS_WOULD_BLOCK then
  begin
    FLastErrorString := 'TLS write would block';
    Exit(-1);
  end;
  if N = HILDI_TLS_ERROR then
  begin
    RecordError;
    FLastError := FLastErrorCode;
    Exit(-1);
  end;
  Result := N;
end;

function TMbedTLSSocketHandler.BytesAvailable: Integer;
begin
  if FHandle = nil then
    Exit(0);
  Result := hildi_tls_pending(FHandle);
end;

function TMbedTLSSocketHandler.GetLastSSLErrorString: String;
begin
  Result := FLastErrorString;
end;

function TMbedTLSSocketHandler.GetLastSSLErrorCode: Integer;
begin
  Result := FLastErrorCode;
end;

{ --- configuration ------------------------------------------------------ }

function TLSBundleOverride: string;
begin
  Result := GetEnvironmentVariable('HILDI_CA_BUNDLE');
end;

function ValidateTLSConfig(out AError: string): Boolean;
var
  Path: string;
  F: TFileStream;
begin
  Result := False;
  AError := '';
  Path := TLSBundleOverride;
  if Path = '' then
    Exit(True);                       // the embedded bundle is always present
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Result := True;
    finally
      F.Free;
    end;
  except
    on E: Exception do
      AError := 'CA bundle is not readable: ' + Path;
  end;
end;

initialization
  TSSLSocketHandler.SetDefaultHandlerClass(TMbedTLSSocketHandler);

end.
