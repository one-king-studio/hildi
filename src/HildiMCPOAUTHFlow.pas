unit HildiMCPOAUTHFlow;
{ The stateful half of MCP OAuth: Dynamic Client Registration, the PKCE
  authorization-code flow (browser + localhost redirect), token exchange,
  refresh, and feeding a valid token to the HTTP transport.
  See docs/features/MCP_Client/MCP_OAuth_Flow_v1.SPEC.md.

  The browser and the clock are injectable so the whole flow is testable against
  a fake authorization server with no real browser. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, HildiMCPOAUTH, HildiMCPConfig,
  HildiStore;

type
  TOAuthBrowser = procedure(const AUrl: string) of object;

  TOAuthTokens = record
    AccessToken: string;
    RefreshToken: string;
    ExpiresAt: Int64;      // ms epoch; 0 = unknown
    TokenScope: string;
    ClientId: string;
    ClientSecret: string;
  end;
  { The authorization-code flow. AMeta is the discovered AS metadata; AResource
    is the MCP server URL (the RFC 8707 resource). }
  TOAuthFlow = class
  private
    FMeta: TAuthServerMeta;
    FResource: string;
    FRedirectPort: Integer;   // 0 => ephemeral
    FTimeoutMs: Integer;
  public
    constructor Create(const AMeta: TAuthServerMeta; const AResource: string;
      ARedirectPort: Integer = 0; ATimeoutMs: Integer = 120000);
    { Register a client (DCR) when AClientId is '' and the AS supports it, then
      run the code flow: build the authorize URL, hand it to ABrowser, catch the
      redirect on localhost, verify state, and exchange the code. }
    function Run(const AClientId, AClientSecret, AScope: string;
      ABrowser: TOAuthBrowser; out ATokens: TOAuthTokens;
      out AError: string): Boolean;
  end;

{ Dynamic Client Registration (RFC 7591). Returns a client id (and secret). }
function RegisterClient(const AMeta: TAuthServerMeta;
  const ARedirectUri, AClientName: string; out AClientId, AClientSecret: string;
  out AError: string): Boolean;

{ Exchange an authorization code for tokens. }
function ExchangeCode(const AMeta: TAuthServerMeta; const ACode, ARedirectUri,
  AClientId, AClientSecret, ACodeVerifier, AResource: string;
  out ATokens: TOAuthTokens; out AError: string): Boolean;

{ Refresh an access token. }
function RefreshAccessToken(const AMeta: TAuthServerMeta;
  const ARow: TOAuthTokens; const AResource: string;
  out ATokens: TOAuthTokens; out AError: string): Boolean;

{ Parse a token-endpoint response into tokens (shared by exchange + refresh). }
function ParseTokenResponse(const AJson, AClientId, AClientSecret: string;
  out ATokens: TOAuthTokens; out AError: string): Boolean;

{ URL-decode a query value. }
function UrlDecode(const AValue: string): string;

{ A store-backed OAuth token provider: loads the stored token for a server and
  refreshes it when expired. Its GetToken matches TMcpTokenSource, so it plugs
  straight into the HTTP transport. }
type
  TOAuthTokenProvider = class
  private
    FStore: TSqliteStore;
    FScope: TMcpScope;
    FWorkspaceId: Integer;
    FServerName: string;
    FResource: string;
    FMeta: TAuthServerMeta;
    FHasMeta: Boolean;
  public
    constructor Create(AStore: TSqliteStore; AScope: TMcpScope;
      AWorkspaceId: Integer; const AServerName, AResource: string);
    { Returns a valid access token, refreshing if needed. False + AError when
      there is no token (run `mcp auth`) or a refresh fails. }
    function GetToken(out AToken, AError: string): Boolean;
  end;

const
  DefaultRefreshSkewMs = 60000;

implementation

uses
  Classes, BaseUnix, Sockets, fpjson, jsonparser, fphttpclient,
  HildiMCPTransport;

{ --- HTTP helpers --- }

function HttpPostForm(const AUrl, ABody: string;
  out AStatusCode: Integer; out AError: string): string;
var
  Client: TFPHTTPClient;
  ReqBody, RespBody: TStringStream;
begin
  Result := '';
  AError := '';
  AStatusCode := 0;
  Client := TFPHTTPClient.Create(nil);
  ReqBody := TStringStream.Create(ABody);
  RespBody := TStringStream.Create('');
  try
    Client.ConnectTimeout := 10000;
    Client.IOTimeout := 30000;
    Client.AddHeader('Content-Type', 'application/x-www-form-urlencoded');
    Client.AddHeader('Accept', 'application/json');
    try
      Client.RequestBody := ReqBody;
      Client.Post(AUrl, RespBody);
      AStatusCode := Client.ResponseStatusCode;
      Result := RespBody.DataString;
      if (AStatusCode < 200) or (AStatusCode >= 300) then
        AError := 'HTTP ' + IntToStr(AStatusCode) + ': ' +
          Copy(Result, 1, 200);
    except
      on E: Exception do
        AError := E.Message;
    end;
  finally
    RespBody.Free;
    ReqBody.Free;
    Client.Free;
  end;
end;

function HttpPostJson(const AUrl, AJson: string;
  out AStatusCode: Integer; out AError: string): string;
var
  Client: TFPHTTPClient;
  ReqBody, RespBody: TStringStream;
begin
  Result := '';
  AError := '';
  AStatusCode := 0;
  Client := TFPHTTPClient.Create(nil);
  ReqBody := TStringStream.Create(AJson);
  RespBody := TStringStream.Create('');
  try
    Client.ConnectTimeout := 10000;
    Client.IOTimeout := 30000;
    Client.AddHeader('Content-Type', 'application/json');
    Client.AddHeader('Accept', 'application/json');
    try
      Client.RequestBody := ReqBody;
      Client.Post(AUrl, RespBody);
      AStatusCode := Client.ResponseStatusCode;
      Result := RespBody.DataString;
      if (AStatusCode < 200) or (AStatusCode >= 300) then
        AError := 'HTTP ' + IntToStr(AStatusCode) + ': ' +
          Copy(Result, 1, 200);
    except
      on E: Exception do
        AError := E.Message;
    end;
  finally
    RespBody.Free;
    ReqBody.Free;
    Client.Free;
  end;
end;

{ --- URL decode --- }

function HexVal(C: Char): Integer;
begin
  if (C >= '0') and (C <= '9') then Result := Ord(C) - Ord('0')
  else if (C >= 'a') and (C <= 'f') then Result := Ord(C) - Ord('a') + 10
  else if (C >= 'A') and (C <= 'F') then Result := Ord(C) - Ord('A') + 10
  else Result := 0;
end;

function UrlDecode(const AValue: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  I := 1;
  while I <= Length(AValue) do
  begin
    C := AValue[I];
    if (C = '%') and (I + 2 <= Length(AValue)) then
    begin
      Result := Result + Chr(HexVal(AValue[I + 1]) * 16 + HexVal(AValue[I + 2]));
      Inc(I, 3);
    end
    else if C = '+' then
    begin
      Result := Result + ' ';
      Inc(I);
    end
    else
    begin
      Result := Result + C;
      Inc(I);
    end;
  end;
end;

{ --- token response --- }

function ParseTokenResponse(const AJson, AClientId, AClientSecret: string;
  out ATokens: TOAuthTokens; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  ExpiresIn: Int64;
begin
  AError := '';
  ATokens := Default(TOAuthTokens);
  ATokens.ClientId := AClientId;
  ATokens.ClientSecret := AClientSecret;
  Data := nil;
  try
    try
      Data := GetJSON(AJson);
    except
      on E: Exception do
      begin
        AError := 'token response is not valid JSON';
        Exit(False);
      end;
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'token response is not an object';
      Exit(False);
    end;
    Root := TJSONObject(Data);
    if Root.Find('access_token') is TJSONString then
      ATokens.AccessToken := Root.Find('access_token').AsString;
    if Root.Find('refresh_token') is TJSONString then
      ATokens.RefreshToken := Root.Find('refresh_token').AsString;
    if Root.Find('scope') is TJSONString then
      ATokens.TokenScope := Root.Find('scope').AsString;
    if Root.Find('expires_in') is TJSONNumber then
    begin
      ExpiresIn := Root.Find('expires_in').AsInt64;
      ATokens.ExpiresAt := (ExpiresIn * 1000) +
        Trunc((Now - EncodeDate(1970, 1, 1)) * MSecsPerDay);
    end;
    if ATokens.AccessToken = '' then
    begin
      AError := 'token response has no access_token';
      Exit(False);
    end;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ --- DCR --- }

function RegisterClient(const AMeta: TAuthServerMeta;
  const ARedirectUri, AClientName: string; out AClientId, AClientSecret: string;
  out AError: string): Boolean;
var
  Meta, Auth: TJSONObject;
  Body, Resp: string;
  Status: Integer;
  Data: TJSONData;
  Root: TJSONObject;
begin
  AClientId := '';
  AClientSecret := '';
  AError := '';
  if AMeta.RegistrationEndpoint = '' then
  begin
    AError := 'authorization server does not support dynamic registration';
    Exit(False);
  end;
  Meta := TJSONObject.Create;
  try
    Meta.Add('client_name', AClientName);
    Meta.Add('redirect_uris', TJSONArray.Create([ARedirectUri]));
    Meta.Add('grant_types', TJSONArray.Create(['authorization_code',
      'refresh_token']));
    Meta.Add('response_types', TJSONArray.Create(['code']));
    Meta.Add('token_endpoint_auth_method', 'none');
    Body := Meta.AsJSON;
  finally
    Meta.Free;
  end;
  Resp := HttpPostJson(AMeta.RegistrationEndpoint, Body, Status, AError);
  if Resp = '' then
    Exit(False);
  Data := nil;
  try
    try
      Data := GetJSON(Resp);
    except
      on E: Exception do
      begin
        AError := 'registration response is not valid JSON';
        Exit(False);
      end;
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'registration response is not an object';
      Exit(False);
    end;
    Root := TJSONObject(Data);
    if Root.Find('client_id') is TJSONString then
      AClientId := Root.Find('client_id').AsString;
    if Root.Find('client_secret') is TJSONString then
      AClientSecret := Root.Find('client_secret').AsString;
    if AClientId = '' then
    begin
      AError := 'registration response has no client_id';
      Exit(False);
    end;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ --- exchange / refresh --- }

function ExchangeCode(const AMeta: TAuthServerMeta; const ACode, ARedirectUri,
  AClientId, AClientSecret, ACodeVerifier, AResource: string;
  out ATokens: TOAuthTokens; out AError: string): Boolean;
var
  Body, Resp: string;
  Status: Integer;
begin
  AError := '';
  Body := 'grant_type=authorization_code' +
    '&code=' + UrlEncode(ACode) +
    '&redirect_uri=' + UrlEncode(ARedirectUri) +
    '&client_id=' + UrlEncode(AClientId) +
    '&code_verifier=' + UrlEncode(ACodeVerifier);
  if AClientSecret <> '' then
    Body := Body + '&client_secret=' + UrlEncode(AClientSecret);
  if AResource <> '' then
    Body := Body + '&resource=' + UrlEncode(AResource);
  Resp := HttpPostForm(AMeta.TokenEndpoint, Body, Status, AError);
  if Resp = '' then
    Exit(False);
  Result := ParseTokenResponse(Resp, AClientId, AClientSecret, ATokens, AError);
end;

function RefreshAccessToken(const AMeta: TAuthServerMeta;
  const ARow: TOAuthTokens; const AResource: string;
  out ATokens: TOAuthTokens; out AError: string): Boolean;
var
  Body, Resp: string;
  Status: Integer;
begin
  AError := '';
  if ARow.RefreshToken = '' then
  begin
    AError := 'no refresh token; re-authorize';
    Exit(False);
  end;
  Body := 'grant_type=refresh_token' +
    '&refresh_token=' + UrlEncode(ARow.RefreshToken) +
    '&client_id=' + UrlEncode(ARow.ClientId);
  if ARow.ClientSecret <> '' then
    Body := Body + '&client_secret=' + UrlEncode(ARow.ClientSecret);
  if AResource <> '' then
    Body := Body + '&resource=' + UrlEncode(AResource);
  Resp := HttpPostForm(AMeta.TokenEndpoint, Body, Status, AError);
  if Resp = '' then
    Exit(False);
  Result := ParseTokenResponse(Resp, ARow.ClientId, ARow.ClientSecret, ATokens,
    AError);
  { Keep the refresh token when the AS does not rotate it. }
  if (ATokens.RefreshToken = '') and (ARow.RefreshToken <> '') then
    ATokens.RefreshToken := ARow.RefreshToken;
end;

{ --- the redirect listener --- }

type
  TRedirectResult = record
    Code: string;
    State: string;
    Error: string;
  end;

{ Accept one localhost HTTP request on AFd, parse its query, reply, and return
  the code/state. Bounded by ATimeoutMs. }
function WaitForRedirect(AFd: Integer; ATimeoutMs: Integer;
  out AResult: TRedirectResult): Boolean;
var
  Addr: TUnixSockAddr;   // reused as a generic sockaddr buffer
  Len: TSockLen;
  Client: Integer;
  FD: TFDSet;
  TV: TTimeVal;
  Buf: array[0..8191] of Byte;
  N, I: Integer;
  ReqLine, Query, Body: AnsiString;
  Q: Integer;

  function Param(const AName: string): string;
  var
    Seg: string;
    P, Amp: Integer;
  begin
    Result := '';
    P := Pos(AName + '=', Query);
    if P = 0 then
      Exit;
    Seg := Copy(Query, P + Length(AName) + 1, MaxInt);
    Amp := Pos('&', Seg);
    if Amp > 0 then
      Seg := Copy(Seg, 1, Amp - 1);
    Result := UrlDecode(Seg);
  end;

begin
  Result := False;
  AResult := Default(TRedirectResult);
  Len := SizeOf(Addr);
  fpFD_ZERO(FD);
  fpFD_SET(AFd, FD);
  TV.tv_sec := ATimeoutMs div 1000;
  TV.tv_usec := (ATimeoutMs mod 1000) * 1000;
  if fpSelect(AFd + 1, @FD, nil, nil, @TV) <= 0 then
  begin
    AResult.Error := 'redirect timeout';
    Exit;
  end;
  Client := fpAccept(AFd, PSockAddr(@Addr), @Len);
  if Client < 0 then
  begin
    AResult.Error := 'accept failed';
    Exit;
  end;
  try
    N := fpRecv(Client, @Buf, SizeOf(Buf), 0);
    if N <= 0 then
    begin
      AResult.Error := 'no request';
      Exit;
    end;
    SetString(ReqLine, PAnsiChar(@Buf[0]), N);
    { The request line is "GET /callback?code=...&state=... HTTP/1.1". }
    Q := Pos('?', ReqLine);
    if Q > 0 then
    begin
      Query := Copy(ReqLine, Q + 1, MaxInt);
      I := Pos(' ', Query);
      if I > 0 then
        Query := Copy(Query, 1, I - 1);
    end;
    AResult.Code := Param('code');
    AResult.State := Param('state');
    if AResult.Code = '' then
      AResult.Error := Param('error');
    Body := 'HTTP/1.1 200 OK' + #13#10 + 'Content-Type: text/html' + #13#10 +
      'Connection: close' + #13#10#13#10 +
      '<html><body>Authorization complete. You can close this window.</body></html>';
    fpSend(Client, @Body[1], Length(Body), 0);
    Result := AResult.Code <> '';
  finally
    CloseSocket(Client);
  end;
end;

{ --- TOAuthFlow --- }

constructor TOAuthFlow.Create(const AMeta: TAuthServerMeta;
  const AResource: string; ARedirectPort, ATimeoutMs: Integer);
begin
  inherited Create;
  FMeta := AMeta;
  FResource := AResource;
  FRedirectPort := ARedirectPort;
  FTimeoutMs := ATimeoutMs;
end;

function TOAuthFlow.Run(const AClientId, AClientSecret, AScope: string;
  ABrowser: TOAuthBrowser; out ATokens: TOAuthTokens; out AError: string): Boolean;
var
  ClientId, ClientSecret, Verifier, State, Challenge, RedirectUri, AuthUrl: string;
  ListenFd: Integer;
  Addr: TInetSockAddr;
  Len: TSockLen;
  Opt: Integer;
  Redir: TRedirectResult;
  Port: Integer;
  AParams: TAuthorizeParams;
begin
  Result := False;
  ATokens := Default(TOAuthTokens);
  AError := '';
  ClientId := AClientId;
  ClientSecret := AClientSecret;

  { Bind the redirect listener first, so the port is known for the URI. }
  ListenFd := fpSocket(AF_INET, SOCK_STREAM, 0);
  if ListenFd < 0 then
  begin
    AError := 'could not create the redirect socket';
    Exit;
  end;
  try
    Opt := 1;
    fpSetSockOpt(ListenFd, SOL_SOCKET, SO_REUSEADDR, @Opt, SizeOf(Opt));
    FillChar(Addr, SizeOf(Addr), 0);
    {$ifdef darwin}
    Addr.sin_len := SizeOf(Addr);
    {$endif}
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(FRedirectPort);
    Addr.sin_addr.s_addr := htonl($7F000001);   // 127.0.0.1
    if fpBind(ListenFd, PSockAddr(@Addr), SizeOf(Addr)) <> 0 then
    begin
      AError := 'could not bind the redirect socket';
      Exit;
    end;
    if fpListen(ListenFd, 1) <> 0 then
    begin
      AError := 'could not listen for the redirect';
      Exit;
    end;
    Len := SizeOf(Addr);
    if fpGetsockname(ListenFd, PSockAddr(@Addr), @Len) <> 0 then
    begin
      AError := 'could not read the redirect port';
      Exit;
    end;
    Port := ntohs(Addr.sin_port);
    RedirectUri := 'http://127.0.0.1:' + IntToStr(Port) + '/callback';

    if (ClientId = '') and (FMeta.RegistrationEndpoint <> '') then
      if not RegisterClient(FMeta, RedirectUri, 'hildi',
        ClientId, ClientSecret, AError) then
        Exit;

    Verifier := GenerateCodeVerifier;
    Challenge := CodeChallengeS256(Verifier);
    State := GenerateState;
    AParams := Default(TAuthorizeParams);
    AParams.AuthorizationEndpoint := FMeta.AuthorizationEndpoint;
    AParams.ClientId := ClientId;
    AParams.RedirectUri := RedirectUri;
    AParams.Scope := AScope;
    AParams.State := State;
    AParams.CodeChallenge := Challenge;
    AParams.Resource := FResource;
    AuthUrl := BuildAuthorizeURL(AParams);

    if Assigned(ABrowser) then
      ABrowser(AuthUrl);

    if not WaitForRedirect(ListenFd, FTimeoutMs, Redir) then
    begin
      AError := 'redirect failed: ' + Redir.Error;
      Exit;
    end;
    if Redir.State <> State then
    begin
      AError := 'state mismatch (possible CSRF); aborting';
      Exit;
    end;
    if not ExchangeCode(FMeta, Redir.Code, RedirectUri, ClientId, ClientSecret,
      Verifier, FResource, ATokens, AError) then
      Exit;
    ATokens.ClientId := ClientId;
    ATokens.ClientSecret := ClientSecret;
    Result := True;
  finally
    CloseSocket(ListenFd);
  end;
end;

{ --- TOAuthTokenProvider --- }

constructor TOAuthTokenProvider.Create(AStore: TSqliteStore; AScope: TMcpScope;
  AWorkspaceId: Integer; const AServerName, AResource: string);
begin
  inherited Create;
  FStore := AStore;
  FScope := AScope;
  FWorkspaceId := AWorkspaceId;
  FServerName := AServerName;
  FResource := AResource;
  FHasMeta := False;
end;

function NowEpochMs: Int64;
begin
  Result := Trunc((Now - EncodeDate(1970, 1, 1)) * MSecsPerDay);
end;

function TOAuthTokenProvider.GetToken(out AToken, AError: string): Boolean;
var
  Row: TOAuthTokenRow;
  StoreErr: TStoreError;
  PRM: TProtectedResourceMeta;
  ASMeta: TAuthServerMeta;
  Cur, Fresh: TOAuthTokens;
begin
  AToken := '';
  AError := '';
  if FStore = nil then
  begin
    AError := 'no store';
    Exit(False);
  end;
  if not FStore.LoadOAuthToken(FScope, FWorkspaceId, FServerName, Row, StoreErr)
  then
  begin
    AError := 'not authorized; run: mcp auth ' + FServerName;
    Exit(False);
  end;
  { A token with no known expiry, or one still valid, is used as-is. }
  if (Row.ExpiresAt = 0) or
    (NowEpochMs < Row.ExpiresAt - DefaultRefreshSkewMs) then
  begin
    AToken := Row.AccessToken;
    Exit(AToken <> '');
  end;
  { Expired: refresh. Needs the AS metadata (discovered once). }
  if not FHasMeta then
  begin
    if not DiscoverProtectedResource(FResource, PRM, AError) then
      Exit(False);
    if (Length(PRM.AuthorizationServers) = 0) or
      not DiscoverAuthServer(PRM.AuthorizationServers[0], ASMeta, AError) then
      Exit(False);
    FMeta := ASMeta;
    FHasMeta := True;
  end;
  Cur := Default(TOAuthTokens);
  Cur.AccessToken := Row.AccessToken;
  Cur.RefreshToken := Row.RefreshToken;
  Cur.ClientId := Row.ClientId;
  Cur.ClientSecret := Row.ClientSecret;
  Cur.ExpiresAt := Row.ExpiresAt;
  Cur.TokenScope := Row.TokenScope;
  if not RefreshAccessToken(FMeta, Cur, FResource, Fresh, AError) then
  begin
    AError := 'refresh failed (' + AError + '); re-run: mcp auth ' + FServerName;
    Exit(False);
  end;
  Row.AccessToken := Fresh.AccessToken;
  Row.RefreshToken := Fresh.RefreshToken;
  Row.ExpiresAt := Fresh.ExpiresAt;
  if Fresh.TokenScope <> '' then
    Row.TokenScope := Fresh.TokenScope;
  FStore.SaveOAuthToken(Row, StoreErr);
  AToken := Row.AccessToken;
  Result := AToken <> '';
end;

end.
