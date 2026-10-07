unit hildegard.helper.mcp.oauth;
{ OAuth 2.1 for MCP: discovery (RFC 9728 protected-resource + RFC 8414 auth
  server metadata), PKCE (RFC 7636), and the authorize-URL builder. Discovery
  parsing and PKCE are pure; the discovery fetch is a thin HTTP wrapper.
  See docs/features/MCP_Client/MCP_OAuth_Discovery_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TProtectedResourceMeta = record
    Resource: string;
    AuthorizationServers: array of string;
    ScopesSupported: array of string;
  end;

  TAuthServerMeta = record
    Issuer: string;
    AuthorizationEndpoint: string;
    TokenEndpoint: string;
    RegistrationEndpoint: string;            // '' when the server has no DCR
    CodeChallengeMethods: array of string;   // e.g. ['S256']
  end;

{ --- pure parsing --- }
function ParseProtectedResource(const AJson: string;
  out AMeta: TProtectedResourceMeta; out AError: string): Boolean;
function ParseAuthServerMetadata(const AJson: string;
  out AMeta: TAuthServerMeta; out AError: string): Boolean;

{ --- pure PKCE --- }
function GenerateCodeVerifier: string;
function GenerateState: string;
function CodeChallengeS256(const AVerifier: string): string;

{ --- authorize URL --- }
type
  TAuthorizeParams = record
    AuthorizationEndpoint: string;
    ClientId: string;
    RedirectUri: string;
    Scope: string;
    State: string;
    CodeChallenge: string;
    Resource: string;
  end;
function BuildAuthorizeURL(const AParams: TAuthorizeParams): string;

{ --- discovery fetch --- }
function DiscoverProtectedResource(const AResourceURL: string;
  out AMeta: TProtectedResourceMeta; out AError: string): Boolean;
function DiscoverAuthServer(const AIssuerURL: string;
  out AMeta: TAuthServerMeta; out AError: string): Boolean;

{ URL-encode a query value (unreserved characters pass through). }
function UrlEncode(const AValue: string): string;
{ BASE64URL without padding. }
function Base64Url(const AData: TBytes): string;
{ The origin (scheme://host[:port]) of a URL. }
function UrlOrigin(const AUrl: string): string;
{ SHA-256 of a string (via the vendored mbedTLS shim). }
function Sha256(const AData: string): TBytes;

implementation

uses
  Classes, StrUtils, fpjson, jsonparser, fphttpclient, hildegard.helper.tls;

function hildegard_sha256(data: PByte; len: Cardinal;
  out_: PByte): Integer; cdecl; external;

{ --- parsing --- }

function ParseProtectedResource(const AJson: string;
  out AMeta: TProtectedResourceMeta; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  AError := '';
  AMeta := Default(TProtectedResourceMeta);
  Data := nil;
  try
    try
      Data := GetJSON(AJson);
    except
      on E: Exception do
      begin
        AError := 'protected-resource metadata is not valid JSON';
        Exit(False);
      end;
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'protected-resource metadata is not an object';
      Exit(False);
    end;
    Root := TJSONObject(Data);
    if Root.Find('resource') is TJSONString then
      AMeta.Resource := Root.Find('resource').AsString;
    if not (Root.Find('authorization_servers') is TJSONArray) then
    begin
      AError := 'protected-resource metadata lists no authorization_servers';
      Exit(False);
    end;
    Arr := TJSONArray(Root.Find('authorization_servers'));
    if Arr.Count = 0 then
    begin
      AError := 'protected-resource metadata lists no authorization_servers';
      Exit(False);
    end;
    SetLength(AMeta.AuthorizationServers, Arr.Count);
    for I := 0 to Arr.Count - 1 do
      AMeta.AuthorizationServers[I] := Arr.Strings[I];
    if Root.Find('scopes_supported') is TJSONArray then
    begin
      Arr := TJSONArray(Root.Find('scopes_supported'));
      SetLength(AMeta.ScopesSupported, Arr.Count);
      for I := 0 to Arr.Count - 1 do
        AMeta.ScopesSupported[I] := Arr.Strings[I];
    end;
    Result := True;
  finally
    Data.Free;
  end;
end;

function ParseAuthServerMetadata(const AJson: string;
  out AMeta: TAuthServerMeta; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  AError := '';
  AMeta := Default(TAuthServerMeta);
  Data := nil;
  try
    try
      Data := GetJSON(AJson);
    except
      on E: Exception do
      begin
        AError := 'authorization-server metadata is not valid JSON';
        Exit(False);
      end;
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'authorization-server metadata is not an object';
      Exit(False);
    end;
    Root := TJSONObject(Data);
    if Root.Find('issuer') is TJSONString then
      AMeta.Issuer := Root.Find('issuer').AsString;
    if Root.Find('authorization_endpoint') is TJSONString then
      AMeta.AuthorizationEndpoint := Root.Find('authorization_endpoint').AsString;
    if Root.Find('token_endpoint') is TJSONString then
      AMeta.TokenEndpoint := Root.Find('token_endpoint').AsString;
    if Root.Find('registration_endpoint') is TJSONString then
      AMeta.RegistrationEndpoint := Root.Find('registration_endpoint').AsString;
    if Root.Find('code_challenge_methods_supported') is TJSONArray then
    begin
      Arr := TJSONArray(Root.Find('code_challenge_methods_supported'));
      SetLength(AMeta.CodeChallengeMethods, Arr.Count);
      for I := 0 to Arr.Count - 1 do
        AMeta.CodeChallengeMethods[I] := Arr.Strings[I];
    end;
    if (AMeta.AuthorizationEndpoint = '') or (AMeta.TokenEndpoint = '') then
    begin
      AError := 'authorization-server metadata lacks an endpoint';
      Exit(False);
    end;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ --- URL helpers --- }

function UrlEncode(const AValue: string): string;
const
  Unreserved = ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'];
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    if C in Unreserved then
      Result := Result + C
    else
      Result := Result + '%' + IntToHex(Ord(C), 2);
  end;
end;

function UrlOrigin(const AUrl: string): string;
var
  P, Slash: Integer;
begin
  P := Pos('://', AUrl);
  if P = 0 then
    Exit(AUrl);
  Slash := PosEx('/', AUrl, P + 3);
  if Slash = 0 then
    Result := AUrl
  else
    Result := Copy(AUrl, 1, Slash - 1);
end;

function Base64Url(const AData: TBytes): string;
const
  Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
var
  I: Integer;
  B0, B1, B2: Integer;
  N: Integer;
begin
  Result := '';
  I := 0;
  N := Length(AData);
  while I < N do
  begin
    B0 := AData[I];
    if I + 1 < N then B1 := AData[I + 1] else B1 := 0;
    if I + 2 < N then B2 := AData[I + 2] else B2 := 0;
    Result := Result + Alphabet[(B0 shr 2) + 1];
    Result := Result + Alphabet[(((B0 and 3) shl 4) or (B1 shr 4)) + 1];
    if I + 1 < N then
      Result := Result + Alphabet[(((B1 and 15) shl 2) or (B2 shr 6)) + 1];
    if I + 2 < N then
      Result := Result + Alphabet[(B2 and 63) + 1];
    Inc(I, 3);
  end;
end;

{ --- crypto / random --- }

function Sha256(const AData: string): TBytes;
begin
  Result := nil;
  SetLength(Result, 32);
  if Length(AData) > 0 then
    hildegard_sha256(PByte(@AData[1]), Length(AData), PByte(@Result[0]))
  else
    hildegard_sha256(nil, 0, PByte(@Result[0]));
end;

function RandomUnreserved(ACount: Integer): string;
const
  Charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
var
  I: Integer;
  Stream: TFileStream;
  B: array[0..255] of Byte;
  N: Integer;
begin
  Result := '';
  Stream := TFileStream.Create('/dev/urandom', fmOpenRead);
  try
    while Length(Result) < ACount do
    begin
      N := Stream.Read(B, SizeOf(B));
      if N <= 0 then
        Break;
      for I := 0 to N - 1 do
      begin
        if Length(Result) >= ACount then
          Break;
        Result := Result + Charset[(B[I] mod 64) + 1];
      end;
    end;
  finally
    Stream.Free;
  end;
end;

function GenerateCodeVerifier: string;
begin
  Result := RandomUnreserved(64);
end;

function GenerateState: string;
begin
  Result := RandomUnreserved(32);
end;

function CodeChallengeS256(const AVerifier: string): string;
begin
  Result := Base64Url(Sha256(AVerifier));
end;

{ --- authorize URL --- }

function BuildAuthorizeURL(const AParams: TAuthorizeParams): string;
begin
  Result := AParams.AuthorizationEndpoint;
  if Pos('?', Result) = 0 then
    Result := Result + '?'
  else
    Result := Result + '&';
  Result := Result + 'response_type=code';
  Result := Result + '&client_id=' + UrlEncode(AParams.ClientId);
  Result := Result + '&redirect_uri=' + UrlEncode(AParams.RedirectUri);
  if AParams.Scope <> '' then
    Result := Result + '&scope=' + UrlEncode(AParams.Scope);
  Result := Result + '&state=' + UrlEncode(AParams.State);
  Result := Result + '&code_challenge=' + UrlEncode(AParams.CodeChallenge);
  Result := Result + '&code_challenge_method=S256';
  if AParams.Resource <> '' then
    Result := Result + '&resource=' + UrlEncode(AParams.Resource);
end;

{ --- discovery fetch --- }

function HttpGetJson(const AUrl: string; out AError: string): string;
var
  Client: TFPHTTPClient;
  Body: TStringStream;
begin
  Result := '';
  AError := '';
  Client := TFPHTTPClient.Create(nil);
  Body := TStringStream.Create('');
  try
    Client.ConnectTimeout := 10000;
    Client.IOTimeout := 20000;
    Client.AddHeader('Accept', 'application/json');
    try
      Client.Get(AUrl, Body);
      if (Client.ResponseStatusCode >= 200) and (Client.ResponseStatusCode < 300)
      then
        Result := Body.DataString
      else
        AError := 'HTTP ' + IntToStr(Client.ResponseStatusCode) + ' for ' + AUrl;
    except
      on E: Exception do
        AError := E.Message;
    end;
  finally
    Body.Free;
    Client.Free;
  end;
end;

function DiscoverProtectedResource(const AResourceURL: string;
  out AMeta: TProtectedResourceMeta; out AError: string): Boolean;
var
  Origin, Body: string;
begin
  AError := '';
  AMeta := Default(TProtectedResourceMeta);
  Origin := UrlOrigin(AResourceURL);
  Body := HttpGetJson(Origin + '/.well-known/oauth-protected-resource', AError);
  if Body = '' then
    Exit(False);
  Result := ParseProtectedResource(Body, AMeta, AError);
end;

function DiscoverAuthServer(const AIssuerURL: string;
  out AMeta: TAuthServerMeta; out AError: string): Boolean;
var
  Body: string;
begin
  AError := '';
  AMeta := Default(TAuthServerMeta);
  Body := HttpGetJson(UrlOrigin(AIssuerURL) +
    '/.well-known/oauth-authorization-server', AError);
  if Body = '' then
    Exit(False);
  Result := ParseAuthServerMetadata(Body, AMeta, AError);
end;

end.
