unit test_mcp_client;
{ fpcunit tests for hildegard.helper.mcp.client. The mappers are pure; the
  lifecycle is exercised against a scripted /bin/sh fake server over real pipes.
  POSIX-only. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  hildegard.helper.mcp.client, hildegard.helper.mcp.config,
  hildegard.helper.agent, hildegard.helper.llm, hildegard.helper.approval;

type
  { An approval service that allows or denies everything. }
  TFakeApproval = class(TInterfacedObject, IApprovalService)
  private
    FAllow: Boolean;
  public
    constructor Create(AAllow: Boolean);
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

  TMcpClientTest = class(TTestCase)
  private
    function ClientConfig(const AScript: string;
      AListTimeoutMs: Integer = 5000): TMcpClientConfig;
  published
    procedure TestMcpRefIsStable;
    procedure TestMcpToolNameIsProviderSafe;
    procedure TestMcpUniqueToolNameResolvesCollision;
    procedure TestSchemaStripsReasonAndRejectsNonObject;
    procedure TestResultMapsTextNonTextAndStructured;
    procedure TestOpenRegistersToolsAndCallSucceeds;
    procedure TestCallDeniedByApproval;
    procedure TestUnsupportedProtocolRefused;
    procedure TestListTimeoutDropsServer;
    procedure TestServerRequestAnsweredAndIgnored;
  end;

implementation

{$ifdef unix}
const
  Q = #39;   // single quote
  InitJson =
    '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05",' +
    '"capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}';
  ListJson =
    '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo",' +
    '"description":"Echo a message","inputSchema":{"type":"object",' +
    '"properties":{"message":{"type":"string"}}}}]}}';
  CallJson =
    '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text",' +
    '"text":"echoed"}]}}';

{ printf '%s\n' 'JSON'; — one framed line on stdout. }
function Line(const AJson: string): string;
begin
  Result := 'printf ' + Q + '%s\n' + Q + ' ' + Q + AJson + Q + '; ';
end;

{ The standard fake: initialize, ignore the notification, list, then answer
  every tools/call with CallJson. }
function StandardScript: string;
begin
  Result :=
    'read line; ' + Line(InitJson) +
    'read line; read line; ' + Line(ListJson) +
    'while IFS= read -r line; do ' + Line(CallJson) + 'done';
end;
{$endif}

constructor TFakeApproval.Create(AAllow: Boolean);
begin
  inherited Create;
  FAllow := AAllow;
end;

function TFakeApproval.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
begin
  AResult := Default(TApprovalBatchResult);
  AResult.Allowed := FAllow;
  AResult.Denied := not FAllow;
  Result := True;
end;

function TMcpClientTest.ClientConfig(const AScript: string;
  AListTimeoutMs: Integer): TMcpClientConfig;
begin
  Result := Default(TMcpClientConfig);
  Result.Server.Name := 'fake';
  Result.Server.Command := '/bin/sh';
  Result.Server.Args := ['-c', AScript];
  Result.Server.Enabled := True;
  Result.ListTimeoutMs := AListTimeoutMs;
  Result.CallTimeoutMs := 3000;
end;

procedure TMcpClientTest.TestMcpRefIsStable;
begin
  AssertEquals('ref', 'mcp/github/create_issue',
    McpRef('GitHub', 'Create_Issue'));
  AssertEquals('slash sanitized', 'mcp/a_b/c_d', McpRef('a/b', 'c/d'));
end;

procedure TMcpClientTest.TestMcpToolNameIsProviderSafe;
var
  N: string;
begin
  N := McpToolName('github', 'create_issue');
  AssertEquals('name', 'mcp_github_create_issue', N);
  AssertTrue('no slash', Pos('/', N) = 0);
  AssertTrue('length bounded', Length(N) <= MaxToolNameChars);
end;

procedure TMcpClientTest.TestMcpUniqueToolNameResolvesCollision;
var
  Taken: TStringList;
begin
  Taken := TStringList.Create;
  try
    Taken.Add('mcp_x');
    AssertEquals('free name unchanged', 'mcp_y', McpUniqueToolName('mcp_y', Taken));
    AssertEquals('collision suffixed', 'mcp_x_2', McpUniqueToolName('mcp_x', Taken));
  finally
    Taken.Free;
  end;
end;

procedure TMcpClientTest.TestSchemaStripsReasonAndRejectsNonObject;
var
  Params, Err: string;
begin
  AssertTrue('valid schema',
    McpSchemaToParams('{"type":"object","properties":{"message":{"type":"string"},' +
      '"reason":{"type":"string"}},"required":["message","reason"]}',
      Params, Err));
  AssertTrue('reason stripped from properties', Pos('"reason"', Params) = 0);
  AssertFalse('non-object rejected', McpSchemaToParams('[]', Params, Err));
  AssertFalse('bad json rejected', McpSchemaToParams('nope', Params, Err));
end;

procedure TMcpClientTest.TestResultMapsTextNonTextAndStructured;
var
  T: string;
begin
  T := McpResultToText('{"content":[{"type":"text","text":"a"},' +
    '{"type":"text","text":"b"},{"type":"image","data":"x"}]}');
  AssertTrue('has a', Pos('a', T) > 0);
  AssertTrue('has b', Pos('b', T) > 0);
  AssertTrue('marks non-text', Pos('[non-text content: image]', T) > 0);

  T := McpResultToText('{"content":[],"structuredContent":{"k":1}}');
  AssertTrue('structured note', Pos('[structured content omitted]', T) > 0);

  AssertTrue('is error', McpResultIsError('{"content":[],"isError":true}'));
  AssertFalse('not error', McpResultIsError('{"content":[]}'));
end;

procedure TMcpClientTest.TestOpenRegistersToolsAndCallSucceeds;
var
  Client: TMcpClient;
  Reg: TToolRegistry;
  Tool: TRegisteredTool;
  Approval: IApprovalService;
  Res, Err: string;
begin
  Approval := TFakeApproval.Create(True);
  Client := TMcpClient.Create(ClientConfig(StandardScript), Approval, nil);
  Reg := TToolRegistry.Create;
  try
    AssertTrue('open', Client.Open(Reg, Err));
    AssertTrue('registered', Reg.Find('mcp_fake_echo', Tool));
    AssertTrue('call', Tool.Handler('{"message":"hi","reason":"testing"}', Res, Err));
    AssertEquals('result', 'echoed', Res);
  finally
    Reg.Free;
    Client.Free;
  end;
end;

procedure TMcpClientTest.TestCallDeniedByApproval;
var
  Client: TMcpClient;
  Reg: TToolRegistry;
  Tool: TRegisteredTool;
  Approval: IApprovalService;
  Res, Err: string;
begin
  Approval := TFakeApproval.Create(False);   // deny
  Client := TMcpClient.Create(ClientConfig(StandardScript), Approval, nil);
  Reg := TToolRegistry.Create;
  try
    AssertTrue('open', Client.Open(Reg, Err));
    AssertTrue('registered', Reg.Find('mcp_fake_echo', Tool));
    AssertFalse('denied', Tool.Handler('{"message":"hi","reason":"x"}', Res, Err));
    AssertEquals('reason', 'denied by operator', Err);
  finally
    Reg.Free;
    Client.Free;
  end;
end;

procedure TMcpClientTest.TestUnsupportedProtocolRefused;
var
  Client: TMcpClient;
  Reg: TToolRegistry;
  Approval: IApprovalService;
  Err: string;
  Script: string;
begin
  Script := 'read line; ' + Line(
    '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"1999-01-01"}}');
  Approval := TFakeApproval.Create(True);
  Client := TMcpClient.Create(ClientConfig(Script), Approval, nil);
  Reg := TToolRegistry.Create;
  try
    AssertFalse('refused', Client.Open(Reg, Err));
    AssertEquals('no tools registered', 0, Reg.Count);
    AssertTrue('names the version', Pos('1999-01-01', Err) > 0);
  finally
    Reg.Free;
    Client.Free;
  end;
end;

procedure TMcpClientTest.TestListTimeoutDropsServer;
var
  Client: TMcpClient;
  Reg: TToolRegistry;
  Approval: IApprovalService;
  Err: string;
  Script: string;
  Start: Int64;
begin
  { Answer initialize, then hang on tools/list. }
  Script := 'read line; ' + Line(InitJson) + 'read line; read line; sleep 30';
  Approval := TFakeApproval.Create(True);
  Client := TMcpClient.Create(ClientConfig(Script, 400), Approval, nil);
  Reg := TToolRegistry.Create;
  try
    Start := GetTickCount64;
    AssertFalse('dropped', Client.Open(Reg, Err));
    AssertTrue('bounded', GetTickCount64 - Start < 3000);
    AssertEquals('no tools', 0, Reg.Count);
  finally
    Reg.Free;
    Client.Free;
  end;
end;

procedure TMcpClientTest.TestServerRequestAnsweredAndIgnored;
var
  Client: TMcpClient;
  Reg: TToolRegistry;
  Approval: IApprovalService;
  Err: string;
  Script: string;
begin
  { A server->client request arrives before the tools/list response; the client
    must answer it (so we do not hang) and still adopt the tools. }
  Script := 'read line; ' + Line(InitJson) +
    'read line; read line; ' +
    Line('{"jsonrpc":"2.0","id":99,"method":"sampling/createMessage"}') +
    Line(ListJson);
  Approval := TFakeApproval.Create(True);
  Client := TMcpClient.Create(ClientConfig(Script), Approval, nil);
  Reg := TToolRegistry.Create;
  try
    AssertTrue('open despite server request', Client.Open(Reg, Err));
    AssertEquals('one tool', 1, Reg.Count);
  finally
    Reg.Free;
    Client.Free;
  end;
end;

initialization
  {$ifdef unix}
  RegisterTest(TMcpClientTest);
  {$endif}
end.
