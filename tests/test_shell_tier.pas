unit test_shell_tier;
{ The builtin shell tier: whole-script pre-flight, the gate's asks and reason
  inheritance, tool dispatch, and the filesystem bound. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  shell.types, hildegard.helper.approval, hildegard.helper.shell.fs,
  hildegard.helper.shell.commands, hildegard.helper.shell.tier;

type
  TFakeApproval = class(TInterfacedObject, IApprovalService)
  public
    Allow: Boolean;
    Asked: TApprovalAskArray;
    BatchReason: string;
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

  TShellTierTest = class(TTestCase)
  private
    FRoot: string;
    FFs: TWorkspaceShellFs;
    FApproval: TFakeApproval;
    FTier: TBuiltinShell;
    FInvokedName: string;
    FInvokedJson: string;
    FInvokedReason: string;
    FInvokeOk: Boolean;
    function P(const AName: string): string;
    function RunTier(const ACommand: string; out AOutput: string): Boolean;
    function Invoke(const AName, AArgumentsJson, AReason: string;
      out AResult, AError: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSupportedScriptRuns;
    procedure TestLoopAndPipeline;
    procedure TestFunctionsAreKnown;
    procedure TestUnknownCommandDeclines;
    procedure TestUnsupportedOptionDeclines;
    procedure TestGrepRegexRuns;
    procedure TestParseErrorDeclines;
    procedure TestGateAskedPerCommand;
    procedure TestAskShapeMatchesRunCommand;
    procedure TestGateDenial;
    procedure TestOutsidePathRefused;
    procedure TestToolDispatch;
    procedure TestToolRefusals;
    procedure TestCdPersists;
  end;

implementation

function TFakeApproval.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
var
  I, N: Integer;
begin
  N := Length(Asked);
  SetLength(Asked, N + Length(AAsks));
  for I := 0 to High(AAsks) do
    Asked[N + I] := AAsks[I];
  AResult := Default(TApprovalBatchResult);
  AResult.Allowed := Allow;
  AResult.Denied := not Allow;
  AResult.Reason := BatchReason;
  Result := True;
end;

function TShellTierTest.P(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot) + AName;
end;

procedure TShellTierTest.SetUp;
var
  E: string;
  Cfg: TBuiltinShellConfig;
begin
  inherited SetUp;
  FRoot := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'shelltier-' +
    IntToStr(Random(100000000));
  ForceDirectories(FRoot);
  FFs := TWorkspaceShellFs.Create(FRoot);
  FFs.WriteFile(P('a.txt'), 'alpha' + #10 + 'beta' + #10, False, E);
  FFs.WriteFile(P('b.txt'), 'gamma' + #10, False, E);
  FFs.MakeDir(P('sub'), False, E);
  FApproval := TFakeApproval.Create;
  FApproval.Allow := True;
  FInvokeOk := True;
  Cfg := Default(TBuiltinShellConfig);
  Cfg.Root := FRoot;
  Cfg.MaxOutputBytes := 32768;
  Cfg.AllowedTools := ['file_read', 'mcp_*'];
  FTier := TBuiltinShell.Create(Cfg, FApproval, Invoke);
end;

procedure TShellTierTest.TearDown;
var
  Tmp: TWorkspaceShellFs;
  E: string;
begin
  FTier.Free;
  FApproval := nil;
  FFs.Free;
  if DirectoryExists(FRoot) then
  begin
    Tmp := TWorkspaceShellFs.Create(FRoot);
    try
      Tmp.Delete(FRoot, True, E);
    finally
      Tmp.Free;
    end;
  end;
  inherited TearDown;
end;

function TShellTierTest.RunTier(const ACommand: string; out AOutput: string): Boolean;
var
  Status: Integer;
begin
  Result := FTier.TryRun(ACommand, FRoot, 'the model reason', 0, AOutput, Status);
  if Result then
    AOutput := AOutput + '#' + IntToStr(Status);
end;

function TShellTierTest.Invoke(const AName, AArgumentsJson,
  AReason: string; out AResult, AError: string): Boolean;
begin
  FInvokedName := AName;
  FInvokedJson := AArgumentsJson;
  FInvokedReason := AReason;
  AResult := 'tool output';
  AError := '';
  Result := FInvokeOk;
end;

procedure TShellTierTest.TestSupportedScriptRuns;
var
  OutText: string;
begin
  AssertTrue('ran', RunTier('echo hi > out.txt; cat out.txt', OutText));
  AssertEquals('output', 'hi' + #10 + '#0', OutText);
  AssertTrue('file written', FileExists(P('out.txt')));
end;

procedure TShellTierTest.TestLoopAndPipeline;
var
  OutText: string;
begin
  AssertTrue('ran', RunTier('for f in *.txt; do cat $f; done | sort', OutText));
  AssertEquals('pipeline output',
    'alpha' + #10 + 'beta' + #10 + 'gamma' + #10 + '#0', OutText);
end;

procedure TShellTierTest.TestFunctionsAreKnown;
var
  OutText: string;
begin
  AssertTrue('ran', RunTier('greet() { echo hi $1; }; greet there', OutText));
  AssertEquals('output', 'hi there' + #10 + '#0', OutText);
end;

procedure TShellTierTest.TestUnknownCommandDeclines;
var
  OutText: string;
begin
  AssertFalse('declined', RunTier('echo x > out.txt; git status', OutText));
  AssertTrue('names the command', Pos('does not know "git"', FTier.LastError) > 0);
  AssertFalse('nothing ran', FileExists(P('out.txt')));
end;

procedure TShellTierTest.TestUnsupportedOptionDeclines;
var
  OutText: string;
begin
  AssertFalse('declined', RunTier('ls -l', OutText));
  AssertTrue('names the option', Pos('-l', FTier.LastError) > 0);
  AssertTrue('supported option runs', RunTier('ls -a', OutText));
end;

procedure TShellTierTest.TestGrepRegexRuns;
var
  OutText: string;
begin
  AssertTrue('regex runs in the tier', RunTier('grep a.*a a.txt', OutText));
  AssertTrue('matched the regex', Pos('alpha', OutText) > 0);
  AssertTrue('fixed form still runs', RunTier('grep -F a.txt a.txt', OutText));
  { A POSIX class the tier cannot express declines to the process tier. }
  AssertFalse('unsupported class declines',
    RunTier('grep "[[:punct:]]" a.txt', OutText));
  AssertTrue('says why', Pos('POSIX character class', FTier.LastError) > 0);
end;

procedure TShellTierTest.TestParseErrorDeclines;
var
  OutText: string;
begin
  AssertFalse('declined', RunTier('echo $(date)', OutText));
  AssertTrue('names the construct', Pos('command substitution', FTier.LastError) > 0);
end;

procedure TShellTierTest.TestGateAskedPerCommand;
var
  OutText: string;
begin
  AssertTrue('ran', RunTier('echo a; echo b', OutText));
  AssertEquals('two asks', 2, Length(FApproval.Asked));
  AssertEquals('first ref', 'run_command:echo', FApproval.Asked[0].Subject.Ref);
  AssertEquals('first arg', 'a', FApproval.Asked[0].Subject.Params[0]);
  AssertEquals('second arg', 'b', FApproval.Asked[1].Subject.Params[0]);
  AssertEquals('reason inherited', 'the model reason', FApproval.Asked[0].Reason);
end;

procedure TShellTierTest.TestAskShapeMatchesRunCommand;
var
  OutText: string;
begin
  AssertTrue('ran', RunTier('echo a', OutText));
  AssertEquals('one ask', 1, Length(FApproval.Asked));
  AssertEquals('ref', 'run_command:echo', FApproval.Asked[0].Subject.Ref);
  AssertEquals('four options', 4, Length(FApproval.Asked[0].Options));
  AssertEquals('once', 'once', FApproval.Asked[0].Options[0].Key);
  AssertEquals('exact', 'exact', FApproval.Asked[0].Options[1].Key);
  AssertEquals('exact persists', True, FApproval.Asked[0].Options[1].Persists);
  AssertEquals('exact params', 'a', FApproval.Asked[0].Options[1].Rule.Params[0]);
  AssertEquals('exact rule ref', 'run_command:echo',
    FApproval.Asked[0].Options[1].Rule.Ref);
  AssertEquals('any', 'any', FApproval.Asked[0].Options[2].Key);
  AssertEquals('prefix', 'prefix', FApproval.Asked[0].Options[3].Key);
end;

procedure TShellTierTest.TestGateDenial;
var
  OutText: string;
begin
  FApproval.Allow := False;
  AssertTrue('the script ran (denials are results)', RunTier('echo hidden', OutText));
  AssertTrue('denied status', Pos('#126', OutText) > 0);
  AssertFalse('no stdout from the command', Pos('hidden', OutText) > 0);
  AssertEquals('asked once', 1, Length(FApproval.Asked));
end;

procedure TShellTierTest.TestOutsidePathRefused;
var
  OutText: string;
begin
  AssertTrue('ran', RunTier('echo x > /tmp/shelltier-escape.txt', OutText));
  AssertTrue('status 1', Pos('#1', OutText) > 0);
  AssertTrue('says escape', Pos('escapes the workspace', OutText) > 0);
  AssertFalse('no file written', FileExists('/tmp/shelltier-escape.txt'));
end;

procedure TShellTierTest.TestToolDispatch;
var
  OutText: string;
begin
  AssertTrue('ran', RunTier('tool file_read ''{"path":"a.txt"}''', OutText));
  AssertEquals('output', 'tool output' + #10 + '#0', OutText);
  AssertEquals('name', 'file_read', FInvokedName);
  AssertEquals('reason', 'the model reason', FInvokedReason);
  AssertTrue('reason in json', Pos('the model reason', FInvokedJson) > 0);
end;

procedure TShellTierTest.TestToolRefusals;
var
  OutText: string;
begin
  AssertTrue('ran', RunTier('tool run_command ''{"command":"ls"}''', OutText));
  AssertTrue('refused status', Pos('#1', OutText) > 0);
  AssertTrue('names it', Pos('run_command is not available', OutText) > 0);
  AssertTrue('disallowed runs', RunTier('tool file_write {}', OutText));
  AssertTrue('not allowed', Pos('not allowed', OutText) > 0);
end;

procedure TShellTierTest.TestCdPersists;
var
  OutText: string;
begin
  AssertTrue('ran', RunTier('cd sub; pwd', OutText));
  AssertTrue('cwd changed', Pos(P('sub'), OutText) > 0);
end;

initialization
  RegisterTest(TShellTierTest);
end.
