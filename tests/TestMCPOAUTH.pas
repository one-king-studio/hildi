unit TestMCPOAUTH;
{ fpcunit tests for HildiMCPOAUTH: discovery parsing, PKCE, and the
  authorize URL. Pure; no network. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, HildiMCPOAUTH;

type
  TMcpOAuthTest = class(TTestCase)
  published
    procedure TestParseProtectedResource;
    procedure TestParseProtectedResourceErrors;
    procedure TestParseAuthServerMetadata;
    procedure TestParseAuthServerMetadataErrors;
    procedure TestCodeVerifierCharsetAndLength;
    procedure TestStateDiffers;
    procedure TestCodeChallengeKnownVector;
    procedure TestBuildAuthorizeURL;
    procedure TestUrlEncode;
    procedure TestUrlOrigin;
  end;

implementation

procedure TMcpOAuthTest.TestParseProtectedResource;
var
  M: TProtectedResourceMeta;
  Err: string;
begin
  AssertTrue('parsed', ParseProtectedResource(
    '{"resource":"https://mcp.example.com/rpc",' +
    '"authorization_servers":["https://auth.example.com"],' +
    '"scopes_supported":["read","write"]}', M, Err));
  AssertEquals('resource', 'https://mcp.example.com/rpc', M.Resource);
  AssertEquals('one as', 1, Length(M.AuthorizationServers));
  AssertEquals('as', 'https://auth.example.com', M.AuthorizationServers[0]);
  AssertEquals('scopes', 2, Length(M.ScopesSupported));
end;

procedure TMcpOAuthTest.TestParseProtectedResourceErrors;
var
  M: TProtectedResourceMeta;
  Err: string;
begin
  AssertFalse('not json', ParseProtectedResource('nope', M, Err));
  AssertFalse('no servers', ParseProtectedResource('{"resource":"x"}', M, Err));
  AssertFalse('empty servers',
    ParseProtectedResource('{"authorization_servers":[]}', M, Err));
end;

procedure TMcpOAuthTest.TestParseAuthServerMetadata;
var
  M: TAuthServerMeta;
  Err: string;
begin
  AssertTrue('parsed', ParseAuthServerMetadata(
    '{"issuer":"https://auth.example.com",' +
    '"authorization_endpoint":"https://auth.example.com/authorize",' +
    '"token_endpoint":"https://auth.example.com/token",' +
    '"registration_endpoint":"https://auth.example.com/register",' +
    '"code_challenge_methods_supported":["S256"]}', M, Err));
  AssertEquals('authorize', 'https://auth.example.com/authorize',
    M.AuthorizationEndpoint);
  AssertEquals('token', 'https://auth.example.com/token', M.TokenEndpoint);
  AssertEquals('register', 'https://auth.example.com/register',
    M.RegistrationEndpoint);
  AssertEquals('methods', 1, Length(M.CodeChallengeMethods));
end;

procedure TMcpOAuthTest.TestParseAuthServerMetadataErrors;
var
  M: TAuthServerMeta;
  Err: string;
begin
  AssertFalse('no token endpoint',
    ParseAuthServerMetadata('{"authorization_endpoint":"x"}', M, Err));
end;

procedure TMcpOAuthTest.TestCodeVerifierCharsetAndLength;
var
  V: string;
  I: Integer;
  Ok: Boolean;
begin
  V := GenerateCodeVerifier;
  AssertTrue('length >= 43', Length(V) >= 43);
  AssertTrue('length <= 128', Length(V) <= 128);
  Ok := True;
  for I := 1 to Length(V) do
    if not (V[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~']) then
      Ok := False;
  AssertTrue('charset', Ok);
end;

procedure TMcpOAuthTest.TestStateDiffers;
begin
  AssertTrue('two states differ', GenerateState <> GenerateState);
end;

{ RFC 7636 Appendix B: the verifier hashes to the known challenge. }
procedure TMcpOAuthTest.TestCodeChallengeKnownVector;
begin
  AssertEquals('known vector',
    'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    CodeChallengeS256('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'));
end;

procedure TMcpOAuthTest.TestBuildAuthorizeURL;
var
  P: TAuthorizeParams;
  U: string;
begin
  P := Default(TAuthorizeParams);
  P.AuthorizationEndpoint := 'https://auth.example.com/authorize';
  P.ClientId := 'client-1';
  P.RedirectUri := 'http://127.0.0.1:9999/callback';
  P.Scope := 'read write';
  P.State := 'abc';
  P.CodeChallenge := 'challenge';
  P.Resource := 'https://mcp.example.com/rpc';
  U := BuildAuthorizeURL(P);
  AssertTrue('response_type', Pos('response_type=code', U) > 0);
  AssertTrue('client_id', Pos('client_id=client-1', U) > 0);
  AssertTrue('redirect encoded', Pos('redirect_uri=http%3A%2F%2F127.0.0.1', U) > 0);
  AssertTrue('scope encoded', Pos('scope=read%20write', U) > 0);
  AssertTrue('pkce', Pos('code_challenge_method=S256', U) > 0);
  AssertTrue('resource', Pos('resource=', U) > 0);
end;

procedure TMcpOAuthTest.TestUrlEncode;
begin
  AssertEquals('unreserved pass', 'aZ0-._~', UrlEncode('aZ0-._~'));
  AssertEquals('space', 'a%20b', UrlEncode('a b'));
  AssertEquals('slash', 'a%2Fb', UrlEncode('a/b'));
end;

procedure TMcpOAuthTest.TestUrlOrigin;
begin
  AssertEquals('with path', 'https://mcp.example.com',
    UrlOrigin('https://mcp.example.com/wearables'));
  AssertEquals('bare', 'https://x.com', UrlOrigin('https://x.com'));
end;

initialization
  RegisterTest(TMcpOAuthTest);
end.
