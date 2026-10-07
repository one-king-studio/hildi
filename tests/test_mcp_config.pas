unit test_mcp_config;
{ fpcunit tests for hildegard.helper.mcp.config. Pure resolution and validation;
  no store, no files. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, hildegard.helper.mcp.config;

type
  TMcpConfigTest = class(TTestCase)
  private
    function Row(const AName: string; AScope: TMcpScope;
      AWorkspaceId: Integer = 0; const AAgentId: string = '';
      AEnabled: Boolean = True): TMcpServerRow;
  published
    procedure TestResolveGlobalOnly;
    procedure TestResolveWorkspaceOverridesGlobal;
    procedure TestResolveUnionsDistinctNames;
    procedure TestResolveExcludesDisabled;
    procedure TestResolveAgentOverridesAll;
    procedure TestResolveSkipsOtherWorkspaceRows;
    procedure TestResolveIsNameSorted;
    procedure TestValidateAcceptsValidRow;
    procedure TestValidateRejectsBadName;
    procedure TestValidateRejectsEmptyCommand;
    procedure TestValidateRejectsBadEnvEntry;
    procedure TestValidateRejectsTooManyServers;
    procedure TestIsValidMcpName;
    procedure TestParseJsonValid;
    procedure TestParseJsonHttpServer;
    procedure TestValidateHttpNeedsUrl;
    procedure TestParseJsonEnvObject;
    procedure TestParseJsonErrors;
    procedure TestJsonRoundTrip;
  end;

implementation

function TMcpConfigTest.Row(const AName: string; AScope: TMcpScope;
  AWorkspaceId: Integer; const AAgentId: string;
  AEnabled: Boolean): TMcpServerRow;
begin
  Result := Default(TMcpServerRow);
  Result.Name := AName;
  Result.Scope := AScope;
  Result.WorkspaceId := AWorkspaceId;
  Result.AgentId := AAgentId;
  Result.Command := '/bin/echo';
  Result.Enabled := AEnabled;
end;

function Ctx(AWorkspaceId: Integer; const AAgentId: string): TMcpConfigContext;
begin
  Result := Default(TMcpConfigContext);
  Result.WorkspaceId := AWorkspaceId;
  Result.AgentId := AAgentId;
end;

procedure TMcpConfigTest.TestResolveGlobalOnly;
var
  Rows: TMcpServerRowArray;
  Servers: TMcpServerArray;
begin
  SetLength(Rows, 2);
  Rows[0] := Row('github', msGlobal);
  Rows[1] := Row('fs', msGlobal);
  Servers := ResolveMcpConfig(Rows, Ctx(0, ''));
  AssertEquals('two servers', 2, Length(Servers));
  AssertEquals('sorted first', 'fs', Servers[0].Name);
  AssertEquals('sorted second', 'github', Servers[1].Name);
  AssertEquals('scope', Ord(msGlobal), Ord(Servers[0].Scope));
end;

procedure TMcpConfigTest.TestResolveWorkspaceOverridesGlobal;
var
  Rows: TMcpServerRowArray;
  Servers: TMcpServerArray;
begin
  SetLength(Rows, 2);
  Rows[0] := Row('fs', msGlobal);
  Rows[0].Command := '/global/fs';
  Rows[1] := Row('fs', msWorkspace, 7);
  Rows[1].Command := '/workspace/fs';
  Servers := ResolveMcpConfig(Rows, Ctx(7, ''));
  AssertEquals('one server', 1, Length(Servers));
  AssertEquals('workspace wins', '/workspace/fs', Servers[0].Command);
  AssertEquals('scope', Ord(msWorkspace), Ord(Servers[0].Scope));
end;

procedure TMcpConfigTest.TestResolveUnionsDistinctNames;
var
  Rows: TMcpServerRowArray;
  Servers: TMcpServerArray;
begin
  SetLength(Rows, 2);
  Rows[0] := Row('global-a', msGlobal);
  Rows[1] := Row('ws-b', msWorkspace, 7);
  Servers := ResolveMcpConfig(Rows, Ctx(7, ''));
  AssertEquals('both present', 2, Length(Servers));
  AssertEquals('a', 'global-a', Servers[0].Name);
  AssertEquals('b', 'ws-b', Servers[1].Name);
end;

procedure TMcpConfigTest.TestResolveExcludesDisabled;
var
  Rows: TMcpServerRowArray;
  Servers: TMcpServerArray;
begin
  SetLength(Rows, 2);
  Rows[0] := Row('on', msGlobal, 0, '', True);
  Rows[1] := Row('off', msGlobal, 0, '', False);
  Servers := ResolveMcpConfig(Rows, Ctx(0, ''));
  AssertEquals('only enabled', 1, Length(Servers));
  AssertEquals('name', 'on', Servers[0].Name);
end;

procedure TMcpConfigTest.TestResolveAgentOverridesAll;
var
  Rows: TMcpServerRowArray;
  Servers: TMcpServerArray;
begin
  SetLength(Rows, 3);
  Rows[0] := Row('srv', msGlobal);
  Rows[0].Command := '/global';
  Rows[1] := Row('srv', msWorkspace, 7);
  Rows[1].Command := '/workspace';
  Rows[2] := Row('srv', msAgent, 0, 'agent-x');
  Rows[2].Command := '/agent';
  Servers := ResolveMcpConfig(Rows, Ctx(7, 'agent-x'));
  AssertEquals('one server', 1, Length(Servers));
  AssertEquals('agent wins', '/agent', Servers[0].Command);
  AssertEquals('scope', Ord(msAgent), Ord(Servers[0].Scope));
end;

procedure TMcpConfigTest.TestResolveSkipsOtherWorkspaceRows;
var
  Rows: TMcpServerRowArray;
  Servers: TMcpServerArray;
begin
  SetLength(Rows, 1);
  Rows[0] := Row('other', msWorkspace, 99);
  Servers := ResolveMcpConfig(Rows, Ctx(7, ''));
  AssertEquals('not applicable', 0, Length(Servers));
end;

procedure TMcpConfigTest.TestResolveIsNameSorted;
var
  Rows: TMcpServerRowArray;
  Servers: TMcpServerArray;
begin
  SetLength(Rows, 3);
  Rows[0] := Row('zebra', msGlobal);
  Rows[1] := Row('alpha', msGlobal);
  Rows[2] := Row('mango', msGlobal);
  Servers := ResolveMcpConfig(Rows, Ctx(0, ''));
  AssertEquals('a', 'alpha', Servers[0].Name);
  AssertEquals('m', 'mango', Servers[1].Name);
  AssertEquals('z', 'zebra', Servers[2].Name);
end;

procedure TMcpConfigTest.TestValidateAcceptsValidRow;
var
  R: TMcpServerRow;
  Err: string;
begin
  R := Row('good_name-1', msGlobal);
  R.Env := ['TOKEN=abc'];
  AssertTrue('valid', ValidateMcpServerRow(R, Err));
  AssertEquals('no error', '', Err);
end;

procedure TMcpConfigTest.TestValidateRejectsBadName;
var
  R: TMcpServerRow;
  Err: string;
begin
  R := Row('bad name!', msGlobal);
  AssertFalse('rejected', ValidateMcpServerRow(R, Err));
  AssertTrue('names the field', Err <> '');
end;

procedure TMcpConfigTest.TestValidateRejectsEmptyCommand;
var
  R: TMcpServerRow;
  Err: string;
begin
  R := Row('srv', msGlobal);
  R.Command := '';
  AssertFalse('rejected', ValidateMcpServerRow(R, Err));
  AssertTrue('error', Err <> '');
end;

procedure TMcpConfigTest.TestValidateRejectsBadEnvEntry;
var
  R: TMcpServerRow;
  Err: string;
begin
  R := Row('srv', msGlobal);
  R.Env := ['NOEQUALS'];
  AssertFalse('rejected', ValidateMcpServerRow(R, Err));
  AssertTrue('error', Err <> '');
end;

procedure TMcpConfigTest.TestValidateRejectsTooManyServers;
var
  Servers: TMcpServerArray;
  Err: string;
begin
  SetLength(Servers, MaxMcpServers + 1);
  AssertFalse('rejected', ValidateMcpConfig(Servers, Err));
  AssertTrue('error', Err <> '');
end;

procedure TMcpConfigTest.TestIsValidMcpName;
begin
  AssertTrue('simple', IsValidMcpName('github'));
  AssertTrue('with dash', IsValidMcpName('my-server_1'));
  AssertFalse('empty', IsValidMcpName(''));
  AssertFalse('slash', IsValidMcpName('a/b'));
  AssertFalse('space', IsValidMcpName('a b'));
  AssertFalse('too long', IsValidMcpName(StringOfChar('a', MaxMcpNameChars + 1)));
end;

procedure TMcpConfigTest.TestParseJsonValid;
var
  Rows: TMcpServerRowArray;
  Err: string;
begin
  AssertTrue('parsed', ParseMcpServersJson(
    '{"mcpServers":{"pw":{"command":"docker","args":["run","-i","--rm"]}}}',
    msGlobal, 0, Rows, Err));
  AssertEquals('one row', 1, Length(Rows));
  AssertEquals('name', 'pw', Rows[0].Name);
  AssertEquals('command', 'docker', Rows[0].Command);
  AssertEquals('args', 3, Length(Rows[0].Args));
  AssertEquals('arg0', 'run', Rows[0].Args[0]);
  AssertTrue('enabled default', Rows[0].Enabled);
end;

procedure TMcpConfigTest.TestParseJsonHttpServer;
var
  Rows: TMcpServerRowArray;
  Err: string;
begin
  AssertTrue('parsed', ParseMcpServersJson(
    '{"mcpServers":{"remote":{"url":"https://mcp.example.com/rpc",' +
    '"headers":{"Authorization":"Bearer xyz"}}}}', msGlobal, 0, Rows, Err));
  AssertEquals('one row', 1, Length(Rows));
  AssertEquals('http kind', Ord(mtHttp), Ord(Rows[0].Transport));
  AssertEquals('url', 'https://mcp.example.com/rpc', Rows[0].Url);
  AssertEquals('header', 1, Length(Rows[0].Headers));
  AssertEquals('header text', 'Authorization: Bearer xyz', Rows[0].Headers[0]);
end;

procedure TMcpConfigTest.TestValidateHttpNeedsUrl;
var
  R: TMcpServerRow;
  Err: string;
begin
  R := Default(TMcpServerRow);
  R.Name := 'x';
  R.Transport := mtHttp;
  AssertFalse('no url', ValidateMcpServerRow(R, Err));
  R.Url := 'https://x/rpc';
  AssertTrue('with url', ValidateMcpServerRow(R, Err));
end;

procedure TMcpConfigTest.TestParseJsonEnvObject;
var
  Rows: TMcpServerRowArray;
  Err: string;
begin
  AssertTrue('parsed', ParseMcpServersJson(
    '{"mcpServers":{"x":{"command":"c","env":{"TOKEN":"abc"},"cwd":"/d",' +
    '"enabled":false}}}', msWorkspace, 7, Rows, Err));
  AssertEquals('scope', Ord(msWorkspace), Ord(Rows[0].Scope));
  AssertEquals('workspace', 7, Rows[0].WorkspaceId);
  AssertEquals('env', 1, Length(Rows[0].Env));
  AssertEquals('env pair', 'TOKEN=abc', Rows[0].Env[0]);
  AssertEquals('cwd', '/d', Rows[0].WorkingDir);
  AssertFalse('disabled', Rows[0].Enabled);
end;

procedure TMcpConfigTest.TestParseJsonErrors;
var
  Rows: TMcpServerRowArray;
  Err: string;
begin
  AssertFalse('not json', ParseMcpServersJson('nope', msGlobal, 0, Rows, Err));
  AssertFalse('no mcpServers',
    ParseMcpServersJson('{"other":{}}', msGlobal, 0, Rows, Err));
  AssertFalse('entry not object',
    ParseMcpServersJson('{"mcpServers":{"x":5}}', msGlobal, 0, Rows, Err));
  AssertFalse('missing command',
    ParseMcpServersJson('{"mcpServers":{"x":{"args":[]}}}', msGlobal, 0, Rows,
      Err));
end;

procedure TMcpConfigTest.TestJsonRoundTrip;
var
  Rows, Rows2: TMcpServerRowArray;
  Err: string;
  J: string;
begin
  AssertTrue('parse', ParseMcpServersJson(
    '{"mcpServers":{"pw":{"command":"docker","args":["run","-i"],' +
    '"env":{"A":"1"},"cwd":"/w"}}}', msGlobal, 0, Rows, Err));
  J := FormatMcpServersJson(Rows);
  AssertTrue('reparse', ParseMcpServersJson(J, msGlobal, 0, Rows2, Err));
  AssertEquals('one row', 1, Length(Rows2));
  AssertEquals('name', 'pw', Rows2[0].Name);
  AssertEquals('command', 'docker', Rows2[0].Command);
  AssertEquals('args', 2, Length(Rows2[0].Args));
  AssertEquals('env', 'A=1', Rows2[0].Env[0]);
  AssertEquals('cwd', '/w', Rows2[0].WorkingDir);
end;

initialization
  RegisterTest(TMcpConfigTest);
end.
