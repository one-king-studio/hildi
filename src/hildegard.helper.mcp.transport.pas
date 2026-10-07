unit hildegard.helper.mcp.transport;
{ The byte-transport seam for the MCP client: framed JSON-RPC lines in and out.
  Implementations: stdio (a child's pipes) and, later, HTTP (a remote endpoint).
  The client depends only on IMcpTransport, so the transport can change without
  touching the JSON-RPC codec, correlation, tool mapping, or dispatch.
  See docs/features/MCP_Client/MCP_Transport_Seam_v1.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, hildegard.helper.stdio.child;

type
  { Why a Receive returned False (mirrors TStdioReadResult). }
  TMcpRecvResult = (mrOk, mrTimeout, mrEof, mrTooLong, mrError);

  { Supplies a current bearer token (refreshing if needed), or '' when none is
    available. Set on THttpTransport for OAuth-authenticated servers. }
  TMcpTokenSource = function(out AToken, AError: string): Boolean of object;

  { A bidirectional, line-framed JSON-RPC transport. One implementation per
    connection. Not thread-safe; driven on the loop's thread. }
  IMcpTransport = interface
    { Establish the connection. False + AError on failure. Idempotent. }
    function Open(out AError: string): Boolean;
    { Send one framed line (no trailing newline). False + AError on a broken
      transport. }
    function Send(const ALine: string; out AError: string): Boolean;
    { Receive one line within ATimeoutMs. True (mrOk) or False + AReason. }
    function Receive(out ALine: string; ATimeoutMs: Integer;
      out AReason: TMcpRecvResult): Boolean;
    { Tear down. Idempotent. }
    procedure Close;
    { True once a failure marked the transport unusable (drives reconnect). }
    function Dead: Boolean;
  end;

  { The stdio child as a transport: a thin wrapper, behaviour unchanged. }
  TStdioTransport = class(TInterfacedObject, IMcpTransport)
  private
    FConfig: TStdioChildConfig;
    FChild: TStdioChild;
    FDead: Boolean;
  public
    constructor Create(const AConfig: TStdioChildConfig);
    destructor Destroy; override;
    function Open(out AError: string): Boolean;
    function Send(const ALine: string; out AError: string): Boolean;
    function Receive(out ALine: string; ATimeoutMs: Integer;
      out AReason: TMcpRecvResult): Boolean;
    procedure Close;
    function Dead: Boolean;
  end;

implementation

constructor TStdioTransport.Create(const AConfig: TStdioChildConfig);
begin
  inherited Create;
  FConfig := AConfig;
  FDead := False;
end;

destructor TStdioTransport.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TStdioTransport.Open(out AError: string): Boolean;
begin
  AError := '';
  if FChild <> nil then
    Exit(True);
  FDead := False;
  FChild := TStdioChild.Create(FConfig);
  Result := FChild.Start(AError);
  if not Result then
  begin
    FreeAndNil(FChild);
    FDead := True;
  end;
end;

function TStdioTransport.Send(const ALine: string; out AError: string): Boolean;
begin
  AError := '';
  if FChild = nil then
  begin
    AError := 'transport not open';
    Exit(False);
  end;
  Result := FChild.WriteLine(ALine, AError);
  if not Result then
    FDead := True;
end;

function TStdioTransport.Receive(out ALine: string; ATimeoutMs: Integer;
  out AReason: TMcpRecvResult): Boolean;
var
  Reason: TStdioReadResult;
begin
  ALine := '';
  AReason := mrError;
  if FChild = nil then
  begin
    AReason := mrEof;
    Exit(False);
  end;
  Result := FChild.ReadLine(ALine, ATimeoutMs, Reason);
  { TStdioReadResult and TMcpRecvResult have the same order. }
  AReason := TMcpRecvResult(Ord(Reason));
  if not Result and (AReason <> mrTimeout) then
    FDead := True;
end;

procedure TStdioTransport.Close;
begin
  if FChild <> nil then
  begin
    FChild.Close;
    FreeAndNil(FChild);
  end;
end;

function TStdioTransport.Dead: Boolean;
begin
  Result := FDead or ((FChild <> nil) and (not FChild.Alive));
end;

end.
