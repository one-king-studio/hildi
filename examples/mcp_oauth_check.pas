program mcp_oauth_check;
{ Calibrate the MCP OAuth flow against a fake authorization server (see
  tests/fake_oauth_as.py). Not a hermetic test — it needs the fake AS running:

    python3 tests/fake_oauth_as.py 8940 &
    ./build/bin/mcp-oauth-check http://127.0.0.1:8940/mcp

  Runs discovery → DCR → the PKCE code flow → token exchange, then a refresh. }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}
  SysUtils, Classes, fphttpclient,
  HildiMCPOAUTH, HildiMCPOAUTHFlow;

type
  { Fetches a URL on a background thread, so Open returns immediately (like a
    real browser that hands the URL to the OS). }
  TFetchThread = class(TThread)
  private
    FUrl: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AUrl: string);
  end;

  { A "browser" that fetches the authorize URL in the background, following the
    AS redirect into our localhost listener — which completes the flow. }
  TFakeBrowser = class
  private
    FThreads: TList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Open(const AUrl: string);
  end;

constructor TFetchThread.Create(const AUrl: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FUrl := AUrl;
end;

procedure TFetchThread.Execute;
var
  Client: TFPHTTPClient;
  S: TStringStream;
begin
  Client := TFPHTTPClient.Create(nil);
  S := TStringStream.Create('');
  try
    Client.AllowRedirect := True;
    try
      Client.Get(FUrl, S);
    except
      on E: Exception do ;   { the redirect completing is the point }
    end;
  finally
    S.Free;
    Client.Free;
  end;
end;

constructor TFakeBrowser.Create;
begin
  inherited Create;
  FThreads := TList.Create;
end;

destructor TFakeBrowser.Destroy;
var
  I: Integer;
begin
  for I := 0 to FThreads.Count - 1 do
  begin
    TFetchThread(FThreads[I]).WaitFor;
    TFetchThread(FThreads[I]).Free;
  end;
  FThreads.Free;
  inherited Destroy;
end;

procedure TFakeBrowser.Open(const AUrl: string);
var
  Th: TFetchThread;
begin
  WriteLn('  [browser] GET ', AUrl);
  Th := TFetchThread.Create(AUrl);
  FThreads.Add(Th);
  Th.Start;
end;

var
  ResourceURL: string;
  PRM: TProtectedResourceMeta;
  ASMeta: TAuthServerMeta;
  Flow: TOAuthFlow;
  Browser: TFakeBrowser;
  Tokens, Refreshed: TOAuthTokens;
  Err: string;
begin
  ResourceURL := 'http://127.0.0.1:8940/mcp';
  if ParamCount >= 1 then
    ResourceURL := ParamStr(1);

  WriteLn('discovering protected resource: ', ResourceURL);
  if not DiscoverProtectedResource(ResourceURL, PRM, Err) then
  begin
    WriteLn('DISCOVERY FAILED: ', Err);
    Halt(1);
  end;
  WriteLn('  authorization server: ', PRM.AuthorizationServers[0]);
  if not DiscoverAuthServer(PRM.AuthorizationServers[0], ASMeta, Err) then
  begin
    WriteLn('AS METADATA FAILED: ', Err);
    Halt(1);
  end;
  WriteLn('  authorize: ', ASMeta.AuthorizationEndpoint);
  WriteLn('  token:     ', ASMeta.TokenEndpoint);
  WriteLn('  register:  ', ASMeta.RegistrationEndpoint);

  Browser := TFakeBrowser.Create;
  Flow := TOAuthFlow.Create(ASMeta, ResourceURL);
  try
    WriteLn('running the code flow ...');
    if not Flow.Run('', '', 'read', Browser.Open, Tokens, Err) then
    begin
      WriteLn('FLOW FAILED: ', Err);
      Halt(1);
    end;
    WriteLn('  access_token:  ', Tokens.AccessToken);
    WriteLn('  refresh_token: ', Tokens.RefreshToken);
    WriteLn('  client_id:     ', Tokens.ClientId);

    WriteLn('refreshing ...');
    if not RefreshAccessToken(ASMeta, Tokens, ResourceURL, Refreshed, Err) then
    begin
      WriteLn('REFRESH FAILED: ', Err);
      Halt(1);
    end;
    WriteLn('  refreshed access_token: ', Refreshed.AccessToken);
    WriteLn('OK');
  finally
    Flow.Free;
    Browser.Free;
  end;
end.
