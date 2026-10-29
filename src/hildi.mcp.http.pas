unit hildi.mcp.http;
{ The MCP streamable-HTTP transport: POSTs JSON-RPC messages to a remote server
  and yields the response body (a JSON object, or an SSE stream carrying it).
  An IMcpTransport, so the client is unchanged.
  See docs/features/MCP_Client/MCP_HTTP_Transport_v1.SPEC.md.

  v1 is request/response: one POST per request; the response body carries the
  JSON-RPC message. Server-initiated streams and OAuth are deferred. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, hildi.mcp.transport;

type
  THttpTransportConfig = record
    URL: string;
    Headers: array of string;   // 'Name: value'
    ConnectTimeoutMs: Integer;  // 0 => default
    ReadTimeoutMs: Integer;     // 0 => default
  end;

  THttpTransport = class(TInterfacedObject, IMcpTransport)
  private
    FConfig: THttpTransportConfig;
    FSessionId: string;         // Mcp-Session-Id, echoed on later requests
    FPending: TStringList;      // response messages not yet delivered
    FDead: Boolean;
    FLastError: string;
    FTokenSource: TMcpTokenSource;   // OAuth: a fresh bearer token per request
    procedure Post(const ABody: string; out AStatusCode: Integer);
    procedure BufferBody(const ABody, AContentType: string);
  public
    constructor Create(const AConfig: THttpTransportConfig);
    destructor Destroy; override;
    function Open(out AError: string): Boolean;
    function Send(const ALine: string; out AError: string): Boolean;
    function Receive(out ALine: string; ATimeoutMs: Integer;
      out AReason: TMcpRecvResult): Boolean;
    procedure Close;
    function Dead: Boolean;
    { When set, each request obtains a bearer token from this source. }
    property TokenSource: TMcpTokenSource read FTokenSource write FTokenSource;
  end;

{ Split a response body into JSON-RPC message strings: a plain JSON body is one
  message; a text/event-stream body yields one message per `data:` payload.
  Pure; exposed for testing. }
function ParseHttpMessages(const ABody, AContentType: string): TStringArray;

const
  DefaultHttpConnectTimeoutMs = 10000;
  DefaultHttpReadTimeoutMs = 60000;

implementation

uses
  fphttpclient, hildi.tls;

constructor THttpTransport.Create(const AConfig: THttpTransportConfig);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.ConnectTimeoutMs <= 0 then
    FConfig.ConnectTimeoutMs := DefaultHttpConnectTimeoutMs;
  if FConfig.ReadTimeoutMs <= 0 then
    FConfig.ReadTimeoutMs := DefaultHttpReadTimeoutMs;
  FPending := TStringList.Create;
  FDead := False;
end;

destructor THttpTransport.Destroy;
begin
  FPending.Free;
  inherited Destroy;
end;

function THttpTransport.Open(out AError: string): Boolean;
begin
  AError := '';
  if FConfig.URL = '' then
  begin
    AError := 'HTTP transport has no url';
    Exit(False);
  end;
  Result := True;
end;

procedure THttpTransport.Post(const ABody: string; out AStatusCode: Integer);
var
  Client: TFPHTTPClient;
  ReqBody, RespBody: TStringStream;
  I: Integer;
  Hdr, Name, Tok, TokErr: string;
begin
  AStatusCode := 0;
  FLastError := '';
  Client := TFPHTTPClient.Create(nil);
  ReqBody := TStringStream.Create(ABody);
  RespBody := TStringStream.Create('');
  try
    Client.ConnectTimeout := FConfig.ConnectTimeoutMs;
    Client.IOTimeout := FConfig.ReadTimeoutMs;
    Client.AddHeader('Content-Type', 'application/json');
    Client.AddHeader('Accept', 'application/json, text/event-stream');
    for I := 0 to High(FConfig.Headers) do
    begin
      Hdr := FConfig.Headers[I];
      if Pos(':', Hdr) > 1 then
      begin
        Name := Trim(Copy(Hdr, 1, Pos(':', Hdr) - 1));
        Client.AddHeader(Name, Trim(Copy(Hdr, Pos(':', Hdr) + 1, MaxInt)));
      end;
    end;
    if FSessionId <> '' then
      Client.AddHeader('Mcp-Session-Id', FSessionId);
    { OAuth: obtain a fresh bearer token for this request. }
    if Assigned(FTokenSource) then
    begin
      if FTokenSource(Tok, TokErr) and (Tok <> '') then
        Client.AddHeader('Authorization', 'Bearer ' + Tok)
      else
      begin
        FLastError := 'no OAuth token: ' + TokErr;
        FDead := True;
        Exit;
      end;
    end;
    try
      Client.RequestBody := ReqBody;
      Client.Post(FConfig.URL, RespBody);
      AStatusCode := Client.ResponseStatusCode;
      { Capture a session id the server assigns, to echo on later requests. }
      if Client.ResponseHeaders.Values['Mcp-Session-Id'] <> '' then
        FSessionId := Client.ResponseHeaders.Values['Mcp-Session-Id'];
      if (AStatusCode >= 200) and (AStatusCode < 300) then
        BufferBody(RespBody.DataString,
          Client.ResponseHeaders.Values['Content-Type'])
      else
      begin
        FLastError := 'HTTP ' + IntToStr(AStatusCode) + ': ' +
          Copy(RespBody.DataString, 1, 200);
        FDead := True;
      end;
    except
      on E: Exception do
      begin
        FLastError := E.Message;
        FDead := True;
      end;
    end;
  finally
    RespBody.Free;
    ReqBody.Free;
    Client.Free;
  end;
end;

{ Split a response body into JSON-RPC messages. A plain JSON body is one
  message; an SSE body yields one message per `data:` payload. }
function ParseHttpMessages(const ABody, AContentType: string): TStringArray;
var
  Lines: TStringList;
  I, N: Integer;
  Line, Payload: string;
begin
  Result := nil;
  if Pos('text/event-stream', AContentType) = 0 then
  begin
    if Trim(ABody) <> '' then
    begin
      SetLength(Result, 1);
      Result[0] := Trim(ABody);
    end;
    Exit;
  end;
  Lines := TStringList.Create;
  try
    Lines.Text := StringReplace(ABody, #13#10, #10, [rfReplaceAll]);
    N := 0;
    Payload := '';
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if Copy(Line, 1, 5) = 'data:' then
        Payload := Payload + Trim(Copy(Line, 6, MaxInt))
      else if Line = '' then
      begin
        if Trim(Payload) <> '' then
        begin
          SetLength(Result, N + 1);
          Result[N] := Trim(Payload);
          Inc(N);
        end;
        Payload := '';
      end;
    end;
    if Trim(Payload) <> '' then
    begin
      SetLength(Result, N + 1);
      Result[N] := Trim(Payload);
    end;
  finally
    Lines.Free;
  end;
end;

procedure THttpTransport.BufferBody(const ABody, AContentType: string);
var
  Msgs: TStringArray;
  I: Integer;
begin
  Msgs := ParseHttpMessages(ABody, AContentType);
  for I := 0 to High(Msgs) do
    FPending.Add(Msgs[I]);
end;

function THttpTransport.Send(const ALine: string; out AError: string): Boolean;
var
  Status: Integer;
begin
  AError := '';
  if FDead then
  begin
    AError := 'transport is dead';
    Exit(False);
  end;
  Post(ALine, Status);
  if FLastError <> '' then
  begin
    AError := FLastError;
    Exit(False);
  end;
  Result := True;
end;

function THttpTransport.Receive(out ALine: string; ATimeoutMs: Integer;
  out AReason: TMcpRecvResult): Boolean;
begin
  ALine := '';
  if FPending.Count > 0 then
  begin
    ALine := FPending[0];
    FPending.Delete(0);
    AReason := mrOk;
    Exit(True);
  end;
  if FDead then
    AReason := mrError
  else
    AReason := mrTimeout;   { nothing buffered; HTTP is request/response }
  Result := False;
end;

procedure THttpTransport.Close;
begin
  FPending.Clear;
  FSessionId := '';
end;

function THttpTransport.Dead: Boolean;
begin
  Result := FDead;
end;

end.
