unit test_tls;
{ fpcunit tests for hildegard.helper.tls and the vendored mbedTLS shim. The
  loopback tests drive the real handler against a test-only mbedTLS server
  (tests/tls_test_server.c) on 127.0.0.1: no network, no committed key. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, ctypes, fpcunit, testregistry,
  sslsockets, ssockets, fphttpclient, hildegard.helper.tls;

type
  TTlsTest = class(TTestCase)
  private
    function StartServer: Integer;
    function ServerCaFile: string;
    function TempFile(const AContent: string): string;
    function ConnectSocket(const AHost: string; APort: Integer;
      const ACaPath: string): TInetSocket;
    procedure SetEnvVar(const AName, AValue: string);
    procedure ClearEnvVar(const AName: string);
  published
    procedure TestHandlerIsRegisteredDefault;
    procedure TestEmbeddedBundleIsPresent;
    procedure TestBundleOverrideResolves;
    procedure TestUnreadableOverrideIsConfigError;
    procedure TestLoopbackHandshake;
    procedure TestLoopbackRejectsUnknownCa;
    procedure TestLoopbackRejectsWrongHost;
    procedure TestBadCaFileFails;
    procedure TestHandlerDrivesTFPHTTPClient;
  end;

implementation

{$ifdef unix}
function c_setenv(Name, Value: PAnsiChar; Overwrite: cint): cint; cdecl;
  external 'c' name 'setenv';
function c_unsetenv(Name: PAnsiChar): cint; cdecl; external 'c' name 'unsetenv';
{$endif}

{ Test-only C helpers, linked from build/libstatic. }
function tls_test_server_start: Integer; cdecl; external;
function tls_test_server_port: Integer; cdecl; external;
procedure tls_test_server_stop; cdecl; external;
function tls_test_server_error: PAnsiChar; cdecl; external;
function tls_test_server_ca_pem(buf: PAnsiChar; buflen: Cardinal): Integer;
  cdecl; external;
function hildegard_tls_live_count: Integer; cdecl; external;
function hildegard_ca_pem_len: Cardinal; cdecl; external;

const
  CAVar = 'HILDEGARD_CA_BUNDLE';

procedure TTlsTest.SetEnvVar(const AName, AValue: string);
begin
  {$ifdef unix}
  c_setenv(PAnsiChar(AnsiString(AName)), PAnsiChar(AnsiString(AValue)), 1);
  {$endif}
end;

procedure TTlsTest.ClearEnvVar(const AName: string);
begin
  {$ifdef unix}
  c_unsetenv(PAnsiChar(AnsiString(AName)));
  {$endif}
end;

function TTlsTest.StartServer: Integer;
begin
  Result := 0;
  if tls_test_server_start <> 0 then
    Fail('test server failed to start: ' +
      string(AnsiString(tls_test_server_error)));
  Result := tls_test_server_port;
end;

function TTlsTest.ServerCaFile: string;
var
  Buf: array[0..8191] of AnsiChar;
  N: Integer;
  F: TFileStream;
begin
  N := tls_test_server_ca_pem(@Buf[0], SizeOf(Buf));
  if N <= 0 then
    Fail('test server produced no certificate');
  Result := TempFile('');
  F := TFileStream.Create(Result, fmCreate);
  try
    F.WriteBuffer(Buf[0], N);
  finally
    F.Free;
  end;
end;

function TTlsTest.TempFile(const AContent: string): string;
var
  F: TFileStream;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) +
    'hildegard_tls_' + IntToStr(Random(MaxInt)) + '.pem';
  F := TFileStream.Create(Result, fmCreate);
  try
    if AContent <> '' then
      F.WriteBuffer(AContent[1], Length(AContent));
  finally
    F.Free;
  end;
end;

{ --- configuration ------------------------------------------------------ }

procedure TTlsTest.TestHandlerIsRegisteredDefault;
var
  H: TSSLSocketHandler;
begin
  H := TSSLSocketHandler.GetDefaultHandler;
  try
    AssertTrue('default handler is the mbedTLS handler',
      H is TMbedTLSSocketHandler);
  finally
    H.Free;
  end;
end;

procedure TTlsTest.TestEmbeddedBundleIsPresent;
begin
  AssertTrue('embedded CA bundle is non-empty', hildegard_ca_pem_len > 0);
end;

procedure TTlsTest.TestBundleOverrideResolves;
var
  Err, Path: string;
begin
  ClearEnvVar(CAVar);
  AssertEquals('unset override is empty', '', TLSBundleOverride);
  AssertTrue('unset override is valid', ValidateTLSConfig(Err));

  Path := TempFile('a readable file is enough for the config check');
  try
    SetEnvVar(CAVar, Path);
    AssertEquals('override is read', Path, TLSBundleOverride);
    AssertTrue('readable override is valid', ValidateTLSConfig(Err));
  finally
    ClearEnvVar(CAVar);
    DeleteFile(Path);
  end;
end;

procedure TTlsTest.TestUnreadableOverrideIsConfigError;
var
  Err: string;
begin
  SetEnvVar(CAVar, '/no/such/hildegard/ca.pem');
  try
    AssertFalse('unreadable override is rejected', ValidateTLSConfig(Err));
    AssertTrue('a distinct message is returned', Err <> '');
  finally
    ClearEnvVar(CAVar);
  end;
end;

{ --- loopback ----------------------------------------------------------- }

{ A socket that owns its handler: TSocketStream frees the handler on destroy,
  so the caller must not free it separately. ACaPath '' uses the embedded
  bundle. }
function TTlsTest.ConnectSocket(const AHost: string; APort: Integer;
  const ACaPath: string): TInetSocket;
var
  H: TMbedTLSSocketHandler;
begin
  H := TMbedTLSSocketHandler.Create;
  try
    if ACaPath <> '' then
      H.CertificateData.CertCA.FileName := ACaPath;
    Result := TInetSocket.Create(AHost, APort, H);
  except
    H.Free;
    raise;
  end;
end;

procedure TTlsTest.TestLoopbackHandshake;
var
  Port: Integer;
  Path: string;
  Sock: TInetSocket;
  Buf: array[0..1023] of AnsiChar;
  Req: AnsiString;
  N: Integer;
begin
  ClearEnvVar(CAVar);
  Port := StartServer;
  Path := ServerCaFile;
  Sock := ConnectSocket('localhost', Port, Path);
  try
    Sock.Connect;
    Req := 'GET / HTTP/1.0'#13#10#13#10;
    Sock.WriteBuffer(Req[1], Length(Req));
    N := Sock.Read(Buf[0], SizeOf(Buf));
    AssertTrue('a response was read', N > 0);
    Buf[N] := #0;
    AssertTrue('the body is present',
      Pos('hello', string(AnsiString(PAnsiChar(@Buf[0])))) > 0);
  finally
    Sock.Free;
    DeleteFile(Path);
    tls_test_server_stop;
  end;
  AssertEquals('no shim handle leaked', 0, hildegard_tls_live_count);
end;

procedure TTlsTest.TestLoopbackRejectsUnknownCa;
var
  Port: Integer;
  Sock: TInetSocket;
  Raised: Boolean;
begin
  { No CertCA and no override: the embedded Mozilla bundle does not trust the
    test server's self-signed certificate, so verification must fail. }
  ClearEnvVar(CAVar);
  Port := StartServer;
  Sock := ConnectSocket('localhost', Port, '');
  try
    Raised := False;
    try
      Sock.Connect;
    except
      on E: Exception do
        Raised := True;
    end;
    AssertTrue('an untrusted certificate must fail verification', Raised);
  finally
    Sock.Free;
    tls_test_server_stop;
  end;
  AssertEquals('no shim handle leaked after a failure', 0,
    hildegard_tls_live_count);
end;

procedure TTlsTest.TestLoopbackRejectsWrongHost;
var
  Port: Integer;
  Path: string;
  Sock: TInetSocket;
  Raised: Boolean;
begin
  ClearEnvVar(CAVar);
  Port := StartServer;
  Path := ServerCaFile;
  { 127.0.0.1 connects, but the certificate is only for DNS:localhost. }
  Sock := ConnectSocket('127.0.0.1', Port, Path);
  try
    Raised := False;
    try
      Sock.Connect;
    except
      on E: Exception do
        Raised := True;
    end;
    AssertTrue('a hostname mismatch must fail verification', Raised);
  finally
    Sock.Free;
    DeleteFile(Path);
    tls_test_server_stop;
  end;
end;

procedure TTlsTest.TestBadCaFileFails;
const
  Garbage = 'this is not a certificate';
var
  Port: Integer;
  Path: string;
  Sock: TInetSocket;
  Raised: Boolean;
begin
  ClearEnvVar(CAVar);
  Port := StartServer;
  Path := TempFile(Garbage);
  Sock := ConnectSocket('localhost', Port, Path);
  try
    Raised := False;
    try
      Sock.Connect;
    except
      on E: Exception do
        Raised := True;
    end;
    AssertTrue('a garbage CA file must fail', Raised);
  finally
    Sock.Free;
    DeleteFile(Path);
    tls_test_server_stop;
  end;
end;

procedure TTlsTest.TestHandlerDrivesTFPHTTPClient;
var
  Port: Integer;
  Path, Body: string;
  Client: TFPHTTPClient;
begin
  ClearEnvVar(CAVar);
  Port := StartServer;
  Path := ServerCaFile;
  Client := TFPHTTPClient.Create(nil);
  try
    Client.CertCAFileName := Path;
    Body := Client.Get('https://localhost:' + IntToStr(Port) + '/');
    AssertEquals('the handler drove a real HTTPS GET', 'hello', Body);
  finally
    Client.Free;
    DeleteFile(Path);
    tls_test_server_stop;
  end;
end;

initialization
  RegisterTest(TTlsTest);
end.
