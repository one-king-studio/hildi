unit TestMCPProvider;
{ fpcunit tests for HildiMCPProvider - MCP servers as a tool provider rather
  than as skills.

  These tests deliberately do NOT need a live MCP server. They cover the parts
  that were the reason for the split: the declaration (no body), the stable
  catalogue versus the volatile status, the load_mcp argument handling, and the
  no-servers case contributing nothing at all. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  HildiMCPClient, HildiMCPConfig, HildiMCPProvider,
  HildiAgent, HildiLLM, HildiApproval;

type
  TMcpProviderTest = class(TTestCase)
  private
    function CfgOf(const ANames: array of string): TMcpConfig;
  published
    { The split's whole point: an MCP server contributes a catalogue line and a
      live status, and NO instructions. }
    procedure TestNoServersContributesNothing;
    procedure TestDeclaredServersAppearClosed;
    procedure TestStableTextCarriesTheCatalogue;
    procedure TestStatusTextTracksOpenState;
    procedure TestLoadMcpIsAlwaysOffered;
    procedure TestUnknownServerIsRefusedWithoutOpening;
    procedure TestLoadMcpRequiresAName;
    procedure TestCuratedMetaIsOursNotTheServers;
  end;

function McpConfigFor(const ANames: array of string): TMcpConfig;

implementation

function McpConfigFor(const ANames: array of string): TMcpConfig;
var
  I: Integer;
  S: TMcpServerConfig;
begin
  Result := Default(TMcpConfig);
  SetLength(Result.Servers, Length(ANames));
  for I := 0 to High(ANames) do
  begin
    S := Default(TMcpServerConfig);
    S.Name := ANames[I];
    S.Command := '/bin/sh';
    S.Args := ['-c', 'true'];
    S.Enabled := True;
    Result.Servers[I] := S;
  end;
end;

function TMcpProviderTest.CfgOf(const ANames: array of string): TMcpConfig;
begin
  Result := McpConfigFor(ANames);
end;

procedure TMcpProviderTest.TestNoServersContributesNothing;
var
  P: TMcpProvider;
begin
  { A session with no MCP configured must be byte-identical to one that never
    had this provider: no tools, no prompt fragment, no status. }
  P := TMcpProvider.Create(nil, Default(TMcpConfig));
  try
    AssertEquals('no tools', 0, Length(P.Specs));
    AssertEquals('no fragment', '', P.PromptFragment);
    AssertEquals('no catalogue', '', P.StableText);
    AssertEquals('no status', '', P.StatusText);
  finally
    P.Free;
  end;
end;

procedure TMcpProviderTest.TestDeclaredServersAppearClosed;
var
  P: TMcpProvider;
  Names: TStringArray;
begin
  { Declaration is lazy: the names are known, nothing is connected. }
  P := TMcpProvider.Create(nil, CfgOf(['browser', 'github']));
  try
    Names := P.Names;
    AssertEquals('both declared', 2, Length(Names));
    AssertEquals('first', 'browser', Names[0]);
    AssertEquals('second', 'github', Names[1]);
    AssertEquals('nothing open', 0, Length(P.OpenNames));
  finally
    P.Free;
  end;
end;

procedure TMcpProviderTest.TestStableTextCarriesTheCatalogue;
var
  P: TMcpProvider;
  S: string;
begin
  { The catalogue is stable text: it belongs in the system prompt. It must name
    each server and carry OUR curated description. }
  P := TMcpProvider.Create(nil, CfgOf(['playwright']));
  try
    S := P.StableText;
    AssertTrue('names the server: ' + S, Pos('playwright', S) > 0);
    AssertTrue('carries the curated description',
      Pos('Browser automation', S) > 0);
    AssertTrue('says how to open it', Pos('load_mcp', S) > 0);
  finally
    P.Free;
  end;
end;

procedure TMcpProviderTest.TestStatusTextTracksOpenState;
var
  P: TMcpProvider;
  S: string;
begin
  { The status is the volatile half: the only part that changes per request. }
  P := TMcpProvider.Create(nil, CfgOf(['github']));
  try
    S := P.PromptFragment;
    AssertTrue('wrapped: ' + S, Pos('<mcp_servers>', S) > 0);
    AssertTrue('closed to begin with: ' + S,
      Pos('name="github" state="closed"', S) > 0);
    AssertFalse('not open', Pos('state="open"', S) > 0);
  finally
    P.Free;
  end;
end;

procedure TMcpProviderTest.TestLoadMcpIsAlwaysOffered;
var
  P: TMcpProvider;
  Specs: TToolSpecArray;
begin
  { load_mcp is present once there is something to open, so the agent can name
    a server even before any is connected. }
  P := TMcpProvider.Create(nil, CfgOf(['github']));
  try
    Specs := P.Specs;
    AssertEquals('load_mcp plus nothing open', 1, Length(Specs));
    AssertEquals('the load tool', LoadMcpToolName, Specs[0].Name);
  finally
    P.Free;
  end;
end;

procedure TMcpProviderTest.TestUnknownServerIsRefusedWithoutOpening;
var
  P: TMcpProvider;
  T: TRegisteredTool;
  Res, Err: string;
begin
  P := TMcpProvider.Create(nil, CfgOf(['github']));
  try
    AssertTrue('load_mcp resolves', P.Find(LoadMcpToolName, T));
    AssertFalse('refused', T.Handler('{"name":"nope"}', Res, Err));
    AssertEquals('says why', 'unknown MCP server: nope', Err);
    AssertEquals('nothing opened', 0, Length(P.OpenNames));
  finally
    P.Free;
  end;
end;

procedure TMcpProviderTest.TestLoadMcpRequiresAName;
var
  P: TMcpProvider;
  T: TRegisteredTool;
  Res, Err: string;
begin
  P := TMcpProvider.Create(nil, CfgOf(['github']));
  try
    AssertTrue('load_mcp resolves', P.Find(LoadMcpToolName, T));
    AssertFalse('refused', T.Handler('{}', Res, Err));
    AssertEquals('says why', 'name is required', Err);
  finally
    P.Free;
  end;
end;

procedure TMcpProviderTest.TestCuratedMetaIsOursNotTheServers;
var
  Desc, When: string;
begin
  { A known service gets real text; an unknown one gets an honest generic line
    rather than a guess. Neither ever comes from the server. }
  McpCuratedMeta('playwright', Desc, When);
  AssertTrue('playwright described', Pos('Browser automation', Desc) > 0);
  McpCuratedMeta('totally-unknown-service', Desc, When);
  AssertTrue('unknown still described honestly',
    Pos('totally-unknown-service', Desc) > 0);
end;

initialization
  RegisterTest(TMcpProviderTest);
end.
