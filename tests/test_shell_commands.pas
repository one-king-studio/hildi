unit test_shell_commands;
{ The builtin shell tier's command set: behaviour, options, error statuses, and
  the tool dispatch gateway. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  shell.types, hildegard.helper.shell.fs, hildegard.helper.shell.commands;

type
  TShellCommandsTest = class(TTestCase)
  private
    FRoot: string;
    FFs: TWorkspaceShellFs;
    FCmd: TBuiltinCommands;
    FInvokeName: string;
    FInvokeJson: string;
    FInvokeReason: string;
    FInvokeOk: Boolean;
    FInvokeResult: string;
    FInvokeError: string;
    function P(const AName: string): string;
    function RunCmd(const AName: string; const AArgs: array of string;
      const AStdin: string = ''): TShellResult;
    function Invoke(const AName, AArgumentsJson, AReason: string;
      out AResult, AError: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestEcho;
    procedure TestCat;
    procedure TestHeadAndTail;
    procedure TestWc;
    procedure TestGrep;
    procedure TestGrepRegex;
    procedure TestGrepMultipleFiles;
    procedure TestGrepRecursive;
    procedure TestLs;
    procedure TestMkdirAndRm;
    procedure TestMvAndCp;
    procedure TestTouch;
    procedure TestSort;
    procedure TestUniq;
    procedure TestBasenameDirname;
    procedure TestTest;
    procedure TestBracket;
    procedure TestTrueFalse;
    procedure TestOptionTable;
    procedure TestSed;
    procedure TestAwk;
    procedure TestToolDispatch;
    procedure TestToolGatewayRefusals;
    procedure TestMcpMapping;
  end;

implementation

function TShellCommandsTest.P(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot) + AName;
end;

procedure TShellCommandsTest.SetUp;
var
  E: string;
begin
  inherited SetUp;
  FRoot := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'shellcmd-' +
    IntToStr(Random(100000000));
  ForceDirectories(FRoot);
  FFs := TWorkspaceShellFs.Create(FRoot);
  FFs.WriteFile(P('a.txt'), 'alpha' + #10 + 'beta' + #10, False, E);
  FFs.WriteFile(P('b.txt'), 'beta' + #10 + 'gamma' + #10, False, E);
  FFs.WriteFile(P('c.log'), 'note' + #10, False, E);
  FFs.MakeDir(P('sub'), False, E);
  FInvokeOk := True;
  FInvokeResult := 'tool result';
  FInvokeError := '';
  FCmd := TBuiltinCommands.Create(FFs, Invoke, ['file_read', 'mcp_*']);
end;

procedure TShellCommandsTest.TearDown;
var
  Tmp: TWorkspaceShellFs;
  E: string;
begin
  FCmd.Free;
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

function TShellCommandsTest.RunCmd(const AName: string;
  const AArgs: array of string; const AStdin: string): TShellResult;
var
  Call: TShellCall;
  I: Integer;
begin
  Call := Default(TShellCall);
  Call.Name := AName;
  Call.Cwd := FRoot;
  Call.Stdin := AStdin;
  SetLength(Call.Args, Length(AArgs));
  for I := 0 to High(AArgs) do
    Call.Args[I] := AArgs[I];
  if AName = 'echo' then
    Result := FCmd.Echo(Call)
  else if AName = 'cat' then
    Result := FCmd.Cat(Call)
  else if AName = 'head' then
    Result := FCmd.Head(Call)
  else if AName = 'tail' then
    Result := FCmd.Tail(Call)
  else if AName = 'wc' then
    Result := FCmd.Wc(Call)
  else if AName = 'grep' then
    Result := FCmd.Grep(Call)
  else if AName = 'ls' then
    Result := FCmd.Ls(Call)
  else if AName = 'mkdir' then
    Result := FCmd.Mkdir(Call)
  else if AName = 'rm' then
    Result := FCmd.Rm(Call)
  else if AName = 'mv' then
    Result := FCmd.Mv(Call)
  else if AName = 'cp' then
    Result := FCmd.Cp(Call)
  else if AName = 'touch' then
    Result := FCmd.Touch(Call)
  else if AName = 'sort' then
    Result := FCmd.SortCmd(Call)
  else if AName = 'uniq' then
    Result := FCmd.Uniq(Call)
  else if AName = 'basename' then
    Result := FCmd.Basename(Call)
  else if AName = 'dirname' then
    Result := FCmd.Dirname(Call)
  else if AName = 'test' then
    Result := FCmd.TestCmd(Call)
  else if AName = '[' then
    Result := FCmd.Bracket(Call)
  else if AName = 'true' then
    Result := FCmd.TrueCmd(Call)
  else if AName = 'false' then
    Result := FCmd.FalseCmd(Call)
  else if AName = 'sed' then
    Result := FCmd.Sed(Call)
  else if AName = 'awk' then
    Result := FCmd.Awk(Call)
  else if AName = 'tool' then
    Result := FCmd.Tool(Call)
  else if AName = 'mcp' then
    Result := FCmd.Mcp(Call)
  else
    raise Exception.Create('unknown command in test: ' + AName);
end;

function TShellCommandsTest.Invoke(const AName, AArgumentsJson,
  AReason: string; out AResult, AError: string): Boolean;
begin
  FInvokeName := AName;
  FInvokeJson := AArgumentsJson;
  FInvokeReason := AReason;
  AResult := FInvokeResult;
  AError := FInvokeError;
  Result := FInvokeOk;
end;

procedure TShellCommandsTest.TestEcho;
begin
  AssertEquals('plain', 'a b' + #10, RunCmd('echo', ['a', 'b']).Stdout);
  AssertEquals('quoted spaces survive as one arg',
    'a  b' + #10, RunCmd('echo', ['a  b']).Stdout);
  AssertEquals('-n', 'a b', RunCmd('echo', ['-n', 'a', 'b']).Stdout);
  AssertEquals('empty', #10, RunCmd('echo', []).Stdout);
end;

procedure TShellCommandsTest.TestCat;
begin
  AssertEquals('file', 'alpha' + #10 + 'beta' + #10, RunCmd('cat', ['a.txt']).Stdout);
  AssertEquals('stdin', 'piped', RunCmd('cat', [], 'piped').Stdout);
  AssertEquals('concat', 'alpha' + #10 + 'beta' + #10 + 'note' + #10,
    RunCmd('cat', ['a.txt', 'c.log']).Stdout);
  AssertEquals('dash is stdin', 'x', RunCmd('cat', ['-'], 'x').Stdout);
  AssertEquals('missing status', 1, RunCmd('cat', ['nope']).ExitCode);
  AssertTrue('missing names the file', Pos('cat: nope', RunCmd('cat', ['nope']).Stderr) > 0);
end;

procedure TShellCommandsTest.TestHeadAndTail;
begin
  AssertEquals('head default', 'alpha' + #10 + 'beta' + #10, RunCmd('head', ['a.txt']).Stdout);
  AssertEquals('head 1', 'alpha' + #10, RunCmd('head', ['-n', '1', 'a.txt']).Stdout);
  AssertEquals('head -1 (BSD shorthand)', 'alpha' + #10,
    RunCmd('head', ['-1', 'a.txt']).Stdout);
  AssertEquals('tail -1 (BSD shorthand)', 'beta' + #10,
    RunCmd('tail', ['-1', 'a.txt']).Stdout);
  AssertEquals('head 0', '', RunCmd('head', ['-n', '0', 'a.txt']).Stdout);
  AssertEquals('tail 1', 'beta' + #10, RunCmd('tail', ['-n', '1', 'a.txt']).Stdout);
  AssertEquals('tail default', 'alpha' + #10 + 'beta' + #10,
    RunCmd('tail', ['a.txt']).Stdout);
  AssertEquals('head stdin', 'x' + #10 + 'y' + #10,
    RunCmd('head', [], 'x' + #10 + 'y' + #10).Stdout);
  AssertEquals('head usage', 2, RunCmd('head', ['-n']).ExitCode);
  AssertEquals('head missing', 1, RunCmd('head', ['nope']).ExitCode);
end;

procedure TShellCommandsTest.TestWc;
begin
  AssertEquals('lines', '2 a.txt' + #10, RunCmd('wc', ['-l', 'a.txt']).Stdout);
  AssertEquals('bytes', '11 a.txt' + #10, RunCmd('wc', ['-c', 'a.txt']).Stdout);
  AssertEquals('default three', '2 2 11 a.txt' + #10,
    RunCmd('wc', ['a.txt']).Stdout);
  AssertEquals('stdin', '1 1 2' + #10, RunCmd('wc', [], 'x' + #10).Stdout);
  AssertEquals('total', '2 a.txt' + #10 + '2 b.txt' + #10 + '4 total' + #10,
    RunCmd('wc', ['-l', 'a.txt', 'b.txt']).Stdout);
end;

procedure TShellCommandsTest.TestGrep;
var
  R: TShellResult;
begin
  R := RunCmd('grep', ['beta', 'a.txt']);
  AssertEquals('match status', 0, R.ExitCode);
  AssertEquals('match', 'beta' + #10, R.Stdout);
  R := RunCmd('grep', ['-n', 'beta', 'a.txt']);
  AssertEquals('line number', '2:beta' + #10, R.Stdout);
  R := RunCmd('grep', ['BETA', 'a.txt']);
  AssertEquals('case-sensitive miss', 1, R.ExitCode);
  R := RunCmd('grep', ['-i', 'BETA', 'a.txt']);
  AssertEquals('case-insensitive', 0, R.ExitCode);
  R := RunCmd('grep', ['-v', 'beta', 'a.txt']);
  AssertEquals('invert', 'alpha' + #10, R.Stdout);
  R := RunCmd('grep', ['-c', 'beta', 'a.txt']);
  AssertEquals('count', '1' + #10, R.Stdout);
  R := RunCmd('grep', ['-l', 'beta', 'a.txt', 'b.txt']);
  AssertEquals('list', 'a.txt' + #10 + 'b.txt' + #10, R.Stdout);
  R := RunCmd('grep', ['beta'], 'beta' + #10 + 'no' + #10);
  AssertEquals('stdin', 'beta' + #10, R.Stdout);
end;

procedure TShellCommandsTest.TestGrepRegex;
var
  R: TShellResult;
  E: string;
begin
  R := RunCmd('grep', ['a.*a', 'a.txt']);
  AssertEquals('BRE dot-star status', 0, R.ExitCode);
  AssertEquals('BRE dot-star output', 'alpha' + #10, R.Stdout);
  R := RunCmd('grep', ['-E', 'alpha|beta', 'a.txt']);
  AssertEquals('ERE alternation', 'alpha' + #10 + 'beta' + #10, R.Stdout);
  R := RunCmd('grep', ['-F', 'a.*a', 'a.txt']);
  AssertEquals('fixed is literal', 1, R.ExitCode);
  R := RunCmd('grep', ['^beta$', 'a.txt']);
  AssertEquals('anchors', 'beta' + #10, R.Stdout);
  R := RunCmd('grep', ['-i', 'ALPHA', 'a.txt']);
  AssertEquals('caseless regex', 'alpha' + #10, R.Stdout);
  R := RunCmd('grep', ['-c', '[[:alpha:]]', 'a.txt']);
  AssertEquals('POSIX class mapped', '2' + #10, R.Stdout);
  R := RunCmd('grep', ['b\{1\}', 'a.txt']);
  AssertEquals('BRE interval', 'beta' + #10, R.Stdout);
  R := RunCmd('grep', ['a\+', 'a.txt']);
  AssertEquals('BRE plus', 'alpha' + #10 + 'beta' + #10, R.Stdout);
  { A Perl-only escape must mean what bash means: \d is a literal "d". }
  FFs.WriteFile(P('d.txt'), 'dog' + #10 + '123' + #10, False, E);
  R := RunCmd('grep', ['\d', 'd.txt']);
  AssertEquals('unknown escape is literal', 'dog' + #10, R.Stdout);
  R := RunCmd('grep', ['a[', 'a.txt']);
  AssertEquals('invalid regex status', 2, R.ExitCode);
  AssertTrue('invalid regex message',
    Pos('invalid regular expression', R.Stderr) > 0);
end;

procedure TShellCommandsTest.TestGrepMultipleFiles;
var
  R: TShellResult;
begin
  R := RunCmd('grep', ['-n', 'beta', 'a.txt', 'b.txt']);
  AssertEquals('prefixes file', 'a.txt:2:beta' + #10 + 'b.txt:1:beta' + #10,
    R.Stdout);
end;

procedure TShellCommandsTest.TestGrepRecursive;
var
  R: TShellResult;
  E: string;
begin
  FFs.MakeDir(P('dir'), False, E);
  FFs.MakeDir(P('dir/sub'), False, E);
  FFs.WriteFile(P('dir/a.txt'), 'alpha' + #10 + 'beta' + #10, False, E);
  FFs.WriteFile(P('dir/sub/b.txt'), 'beta' + #10 + 'gamma' + #10, False, E);
  FFs.WriteFile(P('dir/c.txt'), 'nope' + #10, False, E);
  R := RunCmd('grep', ['-r', 'beta', 'dir']);
  AssertEquals('recursive prefixes every hit',
    'dir/a.txt:beta' + #10 + 'dir/sub/b.txt:beta' + #10, R.Stdout);
  R := RunCmd('grep', ['-rn', 'beta', 'dir']);
  AssertEquals('recursive -n',
    'dir/a.txt:2:beta' + #10 + 'dir/sub/b.txt:1:beta' + #10, R.Stdout);
  R := RunCmd('grep', ['-rl', 'beta', 'dir']);
  AssertEquals('recursive -l',
    'dir/a.txt' + #10 + 'dir/sub/b.txt' + #10, R.Stdout);
  R := RunCmd('grep', ['-rc', 'beta', 'dir']);
  AssertEquals('recursive -c lists every file',
    'dir/a.txt:1' + #10 + 'dir/c.txt:0' + #10 + 'dir/sub/b.txt:1' + #10, R.Stdout);
  R := RunCmd('grep', ['-r', 'beta', 'dir/a.txt']);
  AssertEquals('a file operand is still prefixed', 'dir/a.txt:beta' + #10,
    R.Stdout);
  R := RunCmd('grep', ['-r', 'beta', '.']);
  AssertTrue('cwd recursion', Pos('./dir/a.txt:beta', R.Stdout) > 0);
end;

procedure TShellCommandsTest.TestLs;
var
  R: TShellResult;
  E: string;
begin
  R := RunCmd('ls', []);
  AssertEquals('sorted names', 'a.txt' + #10 + 'b.txt' + #10 + 'c.log' + #10 +
    'sub' + #10, R.Stdout);
  AssertEquals('file arg', 'a.txt' + #10, RunCmd('ls', ['a.txt']).Stdout);
  AssertEquals('-d dir', 'sub' + #10, RunCmd('ls', ['-d', 'sub']).Stdout);
  FFs.WriteFile(P('.hidden'), 'x', False, E);
  AssertFalse('-a excluded by default', Pos('.hidden', RunCmd('ls', []).Stdout) > 0);
  AssertTrue('-a includes dotfiles', Pos('.hidden', RunCmd('ls', ['-a']).Stdout) > 0);
  AssertEquals('missing', 2, RunCmd('ls', ['nope']).ExitCode);
end;

procedure TShellCommandsTest.TestMkdirAndRm;
var
  E: string;
begin
  AssertEquals('mkdir status', 0, RunCmd('mkdir', ['newdir']).ExitCode);
  AssertTrue('created', DirectoryExists(P('newdir')));
  AssertEquals('mkdir -p', 0, RunCmd('mkdir', ['-p', 'x/y/z']).ExitCode);
  AssertTrue('nested', DirectoryExists(P('x/y/z')));
  AssertEquals('rm file', 0, RunCmd('rm', ['c.log']).ExitCode);
  AssertFalse('removed', FileExists(P('c.log')));
  AssertEquals('rm dir needs -r', 1, RunCmd('rm', ['sub']).ExitCode);
  AssertEquals('rm -r', 0, RunCmd('rm', ['-r', 'sub']).ExitCode);
  AssertFalse('dir removed', DirectoryExists(P('sub')));
  AssertEquals('-f missing is fine', 0, RunCmd('rm', ['-f', 'nope']).ExitCode);
  AssertEquals('missing without -f', 1, RunCmd('rm', ['nope']).ExitCode);
  E := '';
  AssertTrue('fixture still there', FileExists(P('a.txt')));
end;

procedure TShellCommandsTest.TestMvAndCp;
begin
  AssertEquals('cp', 0, RunCmd('cp', ['a.txt', 'd.txt']).ExitCode);
  AssertTrue('copied', FileExists(P('d.txt')));
  AssertEquals('mv', 0, RunCmd('mv', ['d.txt', 'e.txt']).ExitCode);
  AssertFalse('moved away', FileExists(P('d.txt')));
  AssertTrue('moved to', FileExists(P('e.txt')));
  AssertEquals('mv usage', 2, RunCmd('mv', ['onlyone']).ExitCode);
end;

procedure TShellCommandsTest.TestTouch;
begin
  AssertEquals('touch', 0, RunCmd('touch', ['new.txt']).ExitCode);
  AssertTrue('created', FileExists(P('new.txt')));
  AssertEquals('touch usage', 2, RunCmd('touch', []).ExitCode);
end;

procedure TShellCommandsTest.TestSort;
begin
  AssertEquals('sort', 'a' + #10 + 'b' + #10, RunCmd('sort', [], 'b' + #10 + 'a' + #10).Stdout);
  AssertEquals('sort -r', 'b' + #10 + 'a' + #10,
    RunCmd('sort', ['-r'], 'a' + #10 + 'b' + #10).Stdout);
  AssertEquals('sort -u', 'a' + #10 + 'b' + #10,
    RunCmd('sort', ['-u'], 'b' + #10 + 'a' + #10 + 'b' + #10).Stdout);
  AssertEquals('sort file', 'beta' + #10 + 'gamma' + #10,
    RunCmd('sort', ['b.txt']).Stdout);
end;

procedure TShellCommandsTest.TestUniq;
begin
  AssertEquals('uniq', 'a' + #10 + 'b' + #10 + 'a' + #10,
    RunCmd('uniq', [], 'a' + #10 + 'a' + #10 + 'b' + #10 + 'a' + #10).Stdout);
  AssertEquals('uniq -c', '2 a' + #10 + '1 b' + #10,
    RunCmd('uniq', ['-c'], 'a' + #10 + 'a' + #10 + 'b' + #10).Stdout);
  AssertEquals('uniq -d', 'a' + #10,
    RunCmd('uniq', ['-d'], 'a' + #10 + 'a' + #10 + 'b' + #10).Stdout);
  AssertEquals('uniq -u', 'b' + #10,
    RunCmd('uniq', ['-u'], 'a' + #10 + 'a' + #10 + 'b' + #10).Stdout);
end;

procedure TShellCommandsTest.TestBasenameDirname;
begin
  AssertEquals('basename', 'x.pas' + #10, RunCmd('basename', ['/a/b/x.pas']).Stdout);
  AssertEquals('basename suffix', 'x' + #10, RunCmd('basename', ['/a/x.pas', '.pas']).Stdout);
  AssertEquals('dirname', '/a/b' + #10, RunCmd('dirname', ['/a/b/c']).Stdout);
  AssertEquals('dirname bare', '.' + #10, RunCmd('dirname', ['c']).Stdout);
  AssertEquals('dirname root', '/' + #10, RunCmd('dirname', ['/']).Stdout);
end;

procedure TShellCommandsTest.TestTest;
begin
  AssertEquals('file', 0, RunCmd('test', ['-f', 'a.txt']).ExitCode);
  AssertEquals('dir', 0, RunCmd('test', ['-d', 'sub']).ExitCode);
  AssertEquals('not a dir', 1, RunCmd('test', ['-d', 'a.txt']).ExitCode);
  AssertEquals('exists', 0, RunCmd('test', ['-e', 'a.txt']).ExitCode);
  AssertEquals('missing', 1, RunCmd('test', ['-e', 'nope']).ExitCode);
  AssertEquals('empty string', 0, RunCmd('test', ['-z', '']).ExitCode);
  AssertEquals('non-empty', 0, RunCmd('test', ['-n', 'x']).ExitCode);
  AssertEquals('string equal', 0, RunCmd('test', ['a', '=', 'a']).ExitCode);
  AssertEquals('string not equal', 1, RunCmd('test', ['a', '=', 'b']).ExitCode);
  AssertEquals('numeric', 0, RunCmd('test', ['3', '-gt', '2']).ExitCode);
  AssertEquals('numeric false', 1, RunCmd('test', ['2', '-gt', '3']).ExitCode);
  AssertEquals('negation', 0, RunCmd('test', ['!', '-f', 'nope']).ExitCode);
  AssertEquals('unsupported', 2, RunCmd('test', ['-a', '-b', '-c', '-d']).ExitCode);
end;

procedure TShellCommandsTest.TestBracket;
begin
  AssertEquals('bracket true', 0, RunCmd('[', ['-f', 'a.txt', ']']).ExitCode);
  AssertEquals('bracket false', 1, RunCmd('[', ['-f', 'nope', ']']).ExitCode);
  AssertEquals('bracket missing', 2, RunCmd('[', ['-f', 'a.txt']).ExitCode);
end;

procedure TShellCommandsTest.TestTrueFalse;
begin
  AssertEquals('true', 0, RunCmd('true', []).ExitCode);
  AssertEquals('false', 1, RunCmd('false', []).ExitCode);
end;

procedure TShellCommandsTest.TestOptionTable;
var
  S: string;
begin
  AssertTrue('echo known', IsBuiltinCommand('echo'));
  AssertFalse('git unknown', IsBuiltinCommand('git'));
  AssertTrue('echo -n', BuiltinCommandOptions('echo', S));
  AssertEquals('echo options', '-n', S);
  AssertFalse('rm -rf ok', IsUnsupportedOption('-rf', '-rf'));
  AssertTrue('rm -z no', IsUnsupportedOption('-z', '-rf'));
  AssertTrue('long no', IsUnsupportedOption('--all', '-a'));
  AssertFalse('bare dash', IsUnsupportedOption('-', '-a'));
  AssertFalse('double dash', IsUnsupportedOption('--', '-a'));
  AssertFalse('triple dash is an argument', IsUnsupportedOption('---', '-n'));
  AssertTrue('long option with a name', IsUnsupportedOption('--all', '-a'));
  AssertTrue('no options at all', IsUnsupportedOption('-x', ''));
  AssertFalse('not an option', IsUnsupportedOption('x', ''));
  AssertFalse('numeric shorthand allowed', IsUnsupportedOption('-20', '-nN'));
  AssertTrue('numeric shorthand refused without N',
    IsUnsupportedOption('-20', '-n'));
  AssertTrue('numeric must be digits', IsUnsupportedOption('-2x', '-nN'));
end;

procedure TShellCommandsTest.TestSed;
var
  R: TShellResult;
  E, Data: string;
begin
  R := RunCmd('sed', ['-n', '1,2p', 'a.txt']);
  AssertEquals('range', 'alpha' + #10 + 'beta' + #10, R.Stdout);
  R := RunCmd('sed', ['-n', '2p', 'a.txt']);
  AssertEquals('single line', 'beta' + #10, R.Stdout);
  R := RunCmd('sed', ['-n', '$p', 'a.txt']);
  AssertEquals('last line', 'beta' + #10, R.Stdout);
  R := RunCmd('sed', ['-n', '/alpha/,/beta/p', 'a.txt']);
  AssertEquals('regex range', 'alpha' + #10 + 'beta' + #10, R.Stdout);
  R := RunCmd('sed', ['s/alpha/ALPHA/', 'a.txt']);
  AssertEquals('substitute', 'ALPHA' + #10 + 'beta' + #10, R.Stdout);
  R := RunCmd('sed', ['-n', 's/a/A/p', 'a.txt']);
  AssertEquals('s///p prints only on a match', 'Alpha' + #10 + 'betA' + #10,
    R.Stdout);
  R := RunCmd('sed', ['s/a/A/g', 'a.txt']);
  AssertEquals('global', 'AlphA' + #10 + 'betA' + #10, R.Stdout);
  R := RunCmd('sed', ['s/alpha/[&]/', 'a.txt']);
  AssertEquals('& is the match', '[alpha]' + #10 + 'beta' + #10, R.Stdout);
  R := RunCmd('sed', ['-E', 's/(a)lpha/\1LPHA/', 'a.txt']);
  AssertEquals('ERE group', 'aLPHA' + #10 + 'beta' + #10, R.Stdout);
  R := RunCmd('sed', ['1d', 'a.txt']);
  AssertEquals('delete', 'beta' + #10, R.Stdout);
  R := RunCmd('sed', ['-n', '/beta/q', 'a.txt']);
  AssertEquals('quit with -n prints nothing', '', R.Stdout);
  R := RunCmd('sed', ['/beta/q', 'a.txt']);
  AssertEquals('quit prints the current line',
    'alpha' + #10 + 'beta' + #10, R.Stdout);
  R := RunCmd('sed', ['-n', '/beta/,$p', 'a.txt']);
  AssertEquals('match to end', 'beta' + #10, R.Stdout);
  R := RunCmd('sed', ['s/a/A/', 'missing.txt']);
  AssertEquals('missing file', 2, R.ExitCode);
  R := RunCmd('sed', ['z', 'a.txt']);
  AssertEquals('unsupported command', 1, R.ExitCode);
  AssertTrue('names it', Pos('unsupported sed command', R.Stderr) > 0);
  R := RunCmd('sed', ['-i.bak', 's/alpha/ALPHA/', 'a.txt']);
  AssertEquals('in-place status', 0, R.ExitCode);
  AssertTrue('file rewritten', FFs.ReadFile(P('a.txt'), Data, E));
  AssertEquals('rewritten content', 'ALPHA' + #10 + 'beta' + #10, Data);
  AssertTrue('backup kept', FFs.ReadFile(P('a.txt.bak'), Data, E));
  AssertEquals('backup content', 'alpha' + #10 + 'beta' + #10, Data);
end;

procedure TShellCommandsTest.TestAwk;
var
  R: TShellResult;
  E: string;
begin
  FFs.WriteFile(P('cols.txt'), 'a:1:one' + #10 + 'b:2:two' + #10, False, E);
  R := RunCmd('awk', ['{print $1}', 'a.txt']);
  AssertEquals('first field', 'alpha' + #10 + 'beta' + #10, R.Stdout);
  R := RunCmd('awk', ['-F:', '{print $2}', 'cols.txt']);
  AssertEquals('-F field', '1' + #10 + '2' + #10, R.Stdout);
  R := RunCmd('awk', ['-F:', '{print $1, $3}', 'cols.txt']);
  AssertEquals('two fields', 'a one' + #10 + 'b two' + #10, R.Stdout);
  R := RunCmd('awk', ['/beta/', 'a.txt']);
  AssertEquals('regex on $0', 'beta' + #10, R.Stdout);
  R := RunCmd('awk', ['NR == 2 {print $1}', 'a.txt']);
  AssertEquals('NR', 'beta' + #10, R.Stdout);
  R := RunCmd('awk', ['{print NF}', 'cols.txt']);
  AssertEquals('NF', '1' + #10 + '1' + #10, R.Stdout);
  R := RunCmd('awk', ['-F:', '$2 > 1 {print $1}', 'cols.txt']);
  AssertEquals('numeric condition', 'b' + #10, R.Stdout);
  R := RunCmd('awk', ['$1 ~ /^a/ {print $1}', 'a.txt']);
  AssertEquals('match condition', 'alpha' + #10, R.Stdout);
  R := RunCmd('awk', ['$1 != "beta" {print $1}', 'b.txt']);
  AssertEquals('not equal', 'gamma' + #10, R.Stdout);
  R := RunCmd('awk', ['{print "x:", $1}', 'b.txt']);
  AssertEquals('string literal', 'x: beta' + #10 + 'x: gamma' + #10, R.Stdout);
  R := RunCmd('awk', ['{print}', 'b.txt']);
  AssertEquals('print alone', 'beta' + #10 + 'gamma' + #10, R.Stdout);
  R := RunCmd('awk', ['{print $1, $2}', 'c.log']);
  AssertEquals('missing field is empty', 'note ' + #10, R.Stdout);
  R := RunCmd('awk', ['BEGIN {print 1}', 'a.txt']);
  AssertEquals('BEGIN is unsupported', 1, R.ExitCode);
  AssertTrue('names it', Pos('unsupported', R.Stderr) > 0);
end;

procedure TShellCommandsTest.TestToolDispatch;
var
  R: TShellResult;
begin
  FCmd.Reason := 'the model reason';
  FInvokeResult := 'hello from tool';
  R := RunCmd('tool', ['file_read', '{"path":"a.txt"}']);
  AssertEquals('status', 0, R.ExitCode);
  AssertEquals('result', 'hello from tool' + #10, R.Stdout);
  AssertEquals('resolved name', 'file_read', FInvokeName);
  AssertEquals('reason passed', 'the model reason', FInvokeReason);
  AssertTrue('reason injected into JSON', Pos('reason', FInvokeJson) > 0);
  AssertTrue('reason value', Pos('the model reason', FInvokeJson) > 0);
  AssertTrue('original args kept', Pos('a.txt', FInvokeJson) > 0);
end;

procedure TShellCommandsTest.TestToolGatewayRefusals;
var
  R: TShellResult;
begin
  R := RunCmd('tool', ['run_command', '{"command":"ls"}']);
  AssertEquals('run_command refused', 1, R.ExitCode);
  AssertTrue('names it', Pos('run_command is not available', R.Stderr) > 0);
  R := RunCmd('tool', ['file_write', '{}']);
  AssertEquals('not allow-listed', 1, R.ExitCode);
  AssertTrue('says not allowed', Pos('not allowed', R.Stderr) > 0);
  FInvokeOk := False;
  FInvokeError := 'boom';
  R := RunCmd('tool', ['file_read', '{}']);
  AssertEquals('tool failure status', 1, R.ExitCode);
  AssertTrue('tool failure text', Pos('boom', R.Stderr) > 0);
  R := RunCmd('tool', ['file_read', 'not json']);
  AssertEquals('bad json is usage', 2, R.ExitCode);
end;

procedure TShellCommandsTest.TestMcpMapping;
begin
  RunCmd('mcp', ['my-server:read_file', '{}']);
  AssertEquals('tool name', 'mcp_my-server_read_file', FInvokeName);
  AssertEquals('usage without colon', 2, RunCmd('mcp', ['nope']).ExitCode);
end;

initialization
  RegisterTest(TShellCommandsTest);
end.
