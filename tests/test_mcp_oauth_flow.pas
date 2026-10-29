unit test_mcp_oauth_flow;
{ fpcunit tests for hildi.mcp.oauth.flow. The pure parts
  (token-response parsing, URL decoding) here; the full flow is exercised
  against a fake authorization server in a separate, network-bound test. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, hildi.mcp.oauth.flow;

type
  TMcpOAuthFlowTest = class(TTestCase)
  published
    procedure TestParseTokenResponse;
    procedure TestParseTokenResponseErrors;
    procedure TestUrlDecode;
  end;

implementation

procedure TMcpOAuthFlowTest.TestParseTokenResponse;
var
  T: TOAuthTokens;
  Err: string;
begin
  AssertTrue('parsed', ParseTokenResponse(
    '{"access_token":"at","refresh_token":"rt","expires_in":3600,' +
    '"scope":"read"}', 'cid', 'csecret', T, Err));
  AssertEquals('access', 'at', T.AccessToken);
  AssertEquals('refresh', 'rt', T.RefreshToken);
  AssertEquals('scope', 'read', T.TokenScope);
  AssertEquals('client', 'cid', T.ClientId);
  AssertTrue('expiry set', T.ExpiresAt > 0);
end;

procedure TMcpOAuthFlowTest.TestParseTokenResponseErrors;
var
  T: TOAuthTokens;
  Err: string;
begin
  AssertFalse('not json', ParseTokenResponse('nope', '', '', T, Err));
  AssertFalse('no access token',
    ParseTokenResponse('{"refresh_token":"rt"}', '', '', T, Err));
end;

procedure TMcpOAuthFlowTest.TestUrlDecode;
begin
  AssertEquals('plain', 'abc', UrlDecode('abc'));
  AssertEquals('space', 'a b', UrlDecode('a+b'));
  AssertEquals('percent', 'a/b', UrlDecode('a%2Fb'));
end;

initialization
  RegisterTest(TMcpOAuthFlowTest);
end.
