unit test_mcp_cli;
{ fpcunit tests for hildegard.helper.mcp.cli. The parser is pure; only formatting
  and parsing are exercised here. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.mcp.cli, hildegard.helper.mcp.config;

type
  TMcpCliTest = class(TTestCase)
  published
    procedure TestList;
    procedure TestAddSplitsArgsAfterDashDash;
    procedure TestAddDockerArgsAreNotOptions;
    procedure TestAddOptions;
    procedure TestRemoveEnableDisable;
    procedure TestTestVerb;
    procedure TestImportExportVerbs;
    procedure TestUnknownVerbRaises;
    procedure TestUnknownOptionRaises;
    procedure TestMissingOperandsRaise;
    procedure TestBadScopeRaises;
    procedure TestBadEnvRaises;
    procedure TestFormatIsSortedAndStable;
    procedure TestFormatEmpty;
  end;

implementation

function A(const S: string): string;
begin
  Result := S;
end;

procedure TMcpCliTest.TestList;
var
  C: TMcpCommand;
begin
  C := ParseMcpCommand(['list']);
  AssertEquals('verb', Ord(mvList), Ord(C.Verb));
  AssertEquals('scope default', Ord(msGlobal), Ord(C.Scope));
end;

procedure TMcpCliTest.TestAddSplitsArgsAfterDashDash;
var
  C: TMcpCommand;
begin
  C := ParseMcpCommand(['add', 'playwright', 'docker', '--', 'run', '-i',
    '--rm', '--init', 'mcr.microsoft.com/playwright/mcp']);
  AssertEquals('verb', Ord(mvAdd), Ord(C.Verb));
  AssertEquals('name', 'playwright', C.Name);
  AssertEquals('command', 'docker', C.Command);
  AssertEquals('args count', 5, Length(C.Args));
  AssertEquals('arg0', 'run', C.Args[0]);
  AssertEquals('arg1', '-i', C.Args[1]);
  AssertEquals('arg2', '--rm', C.Args[2]);
  AssertEquals('arg3', '--init', C.Args[3]);
  AssertEquals('arg4', 'mcr.microsoft.com/playwright/mcp', C.Args[4]);
end;

procedure TMcpCliTest.TestAddDockerArgsAreNotOptions;
var
  C: TMcpCommand;
begin
  { `-i` and `--rm` after `--` must be args, never parsed as options. }
  C := ParseMcpCommand(['add', 'x', 'docker', '--', '-i', '--rm']);
  AssertEquals('two args', 2, Length(C.Args));
  AssertEquals('a0', '-i', C.Args[0]);
  AssertEquals('a1', '--rm', C.Args[1]);
end;

procedure TMcpCliTest.TestAddOptions;
var
  C: TMcpCommand;
begin
  C := ParseMcpCommand(['add', 'fs', 'mcp-fs', '--scope', 'workspace',
    '--env', 'TOKEN=abc', '--env', 'OTHER=x', '--cwd', '/data', '--disabled',
    '--', '/data']);
  AssertEquals('scope', Ord(msWorkspace), Ord(C.Scope));
  AssertEquals('env count', 2, Length(C.Env));
  AssertEquals('env0', 'TOKEN=abc', C.Env[0]);
  AssertEquals('env1', 'OTHER=x', C.Env[1]);
  AssertEquals('cwd', '/data', C.WorkingDir);
  AssertTrue('disabled', C.Disabled);
  AssertEquals('one arg', 1, Length(C.Args));
  AssertEquals('arg', '/data', C.Args[0]);
end;

procedure TMcpCliTest.TestRemoveEnableDisable;
var
  C: TMcpCommand;
begin
  C := ParseMcpCommand(['remove', 'gh']);
  AssertEquals('remove', Ord(mvRemove), Ord(C.Verb));
  AssertEquals('name', 'gh', C.Name);
  C := ParseMcpCommand(['enable', 'gh', '--scope', 'workspace']);
  AssertEquals('enable', Ord(mvEnable), Ord(C.Verb));
  AssertEquals('scope', Ord(msWorkspace), Ord(C.Scope));
  C := ParseMcpCommand(['disable', 'gh']);
  AssertEquals('disable', Ord(mvDisable), Ord(C.Verb));
end;

procedure TMcpCliTest.TestTestVerb;
var
  C: TMcpCommand;
  Raised: Boolean;
begin
  C := ParseMcpCommand(['test', 'playwright']);
  AssertEquals('verb', Ord(mvTest), Ord(C.Verb));
  AssertEquals('name', 'playwright', C.Name);
  C := ParseMcpCommand(['test', 'playwright', '--scope', 'workspace']);
  AssertEquals('scope', Ord(msWorkspace), Ord(C.Scope));
  Raised := False;
  try
    ParseMcpCommand(['test']);
  except
    on E: EMcpCLIError do Raised := True;
  end;
  AssertTrue('test needs a name', Raised);
end;

procedure TMcpCliTest.TestImportExportVerbs;
var
  C: TMcpCommand;
  Raised: Boolean;
begin
  C := ParseMcpCommand(['import', '/tmp/servers.json']);
  AssertEquals('import', Ord(mvImport), Ord(C.Verb));
  AssertEquals('path', '/tmp/servers.json', C.Path);
  C := ParseMcpCommand(['export', '--scope', 'workspace', '--out', '/tmp/o.json']);
  AssertEquals('export', Ord(mvExport), Ord(C.Verb));
  AssertEquals('scope', Ord(msWorkspace), Ord(C.Scope));
  AssertEquals('out', '/tmp/o.json', C.Path);
  Raised := False;
  try
    ParseMcpCommand(['import']);
  except
    on E: EMcpCLIError do Raised := True;
  end;
  AssertTrue('import needs a file', Raised);
end;

procedure TMcpCliTest.TestUnknownVerbRaises;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    ParseMcpCommand(['frobnicate']);
  except
    on E: EMcpCLIError do Raised := True;
  end;
  AssertTrue('raised', Raised);
end;

procedure TMcpCliTest.TestUnknownOptionRaises;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    ParseMcpCommand(['add', 'x', 'cmd', '--bogus']);
  except
    on E: EMcpCLIError do Raised := True;
  end;
  AssertTrue('raised', Raised);
end;

procedure TMcpCliTest.TestMissingOperandsRaise;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    ParseMcpCommand(['add', 'onlyname']);
  except
    on E: EMcpCLIError do Raised := True;
  end;
  AssertTrue('add needs NAME+COMMAND', Raised);
  Raised := False;
  try
    ParseMcpCommand(['remove']);
  except
    on E: EMcpCLIError do Raised := True;
  end;
  AssertTrue('remove needs NAME', Raised);
end;

procedure TMcpCliTest.TestBadScopeRaises;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    ParseMcpCommand(['list', '--scope', 'galaxy']);
  except
    on E: EMcpCLIError do Raised := True;
  end;
  AssertTrue('raised', Raised);
end;

procedure TMcpCliTest.TestBadEnvRaises;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    ParseMcpCommand(['add', 'x', 'cmd', '--env', 'NOEQUALS']);
  except
    on E: EMcpCLIError do Raised := True;
  end;
  AssertTrue('raised', Raised);
end;

procedure TMcpCliTest.TestFormatIsSortedAndStable;
var
  Rows: TMcpServerRowArray;
  S: string;
begin
  SetLength(Rows, 3);
  Rows[0] := Default(TMcpServerRow);
  Rows[0].Scope := msWorkspace;
  Rows[0].Name := 'zeta';
  Rows[0].Command := 'z';
  Rows[0].Enabled := True;
  Rows[1] := Default(TMcpServerRow);
  Rows[1].Scope := msGlobal;
  Rows[1].Name := 'beta';
  Rows[1].Command := 'b';
  Rows[1].Enabled := True;
  Rows[2] := Default(TMcpServerRow);
  Rows[2].Scope := msGlobal;
  Rows[2].Name := 'alpha';
  Rows[2].Command := 'a';
  Rows[2].Enabled := False;
  S := FormatMcpServers(Rows);
  { Global before workspace; alpha before beta within global. }
  AssertTrue('alpha first', Pos('alpha', S) < Pos('beta', S));
  AssertTrue('beta before workspace zeta', Pos('beta', S) < Pos('zeta', S));
  AssertTrue('disabled shown', Pos('[disabled]', S) > 0);
end;

procedure TMcpCliTest.TestFormatEmpty;
begin
  AssertTrue('mentions none', Pos('no MCP servers', FormatMcpServers(nil)) > 0);
end;

initialization
  RegisterTest(TMcpCliTest);
end.
