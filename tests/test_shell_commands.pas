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
    procedure TestDiff;
    procedure TestHashCommands;
    procedure TestOd;
    procedure TestGrep;
    procedure TestGrepRegex;
    procedure TestGrepMultipleFiles;
    procedure TestGrepRecursive;
    procedure TestLs;
    procedure TestLsLong;
    procedure TestMkdirAndRm;
    procedure TestMvAndCp;
    procedure TestTouch;
    procedure TestSort;
    procedure TestUniq;
    procedure TestBasenameDirname;
    procedure TestPwdStatSeq;
    procedure TestTest;
    procedure TestBracket;
    procedure TestTrueFalse;
    procedure TestOptionTable;
    procedure TestSed;
    procedure TestAwk;
    procedure TestFind;
    procedure TestJq;
    procedure TestCutTrPrintfTee;
    procedure TestRg;
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
  else if AName = 'find' then
    Result := FCmd.Find(Call)
  else if AName = 'jq' then
    Result := FCmd.Jq(Call)
  else if AName = 'cut' then
    Result := FCmd.Cut(Call)
  else if AName = 'tr' then
    Result := FCmd.Tr(Call)
  else if AName = 'tee' then
    Result := FCmd.Tee(Call)
  else if AName = 'printf' then
    Result := FCmd.Printf(Call)
  else if AName = 'rg' then
    Result := FCmd.Rg(Call)
  else if AName = 'tool' then
    Result := FCmd.Tool(Call)
  else if AName = 'mcp' then
    Result := FCmd.Mcp(Call)
  else if AName = 'od' then
    Result := FCmd.Od(Call)
  else if AName = 'sha256sum' then
    Result := FCmd.Sha256Sum(Call)
  else if AName = 'diff' then
    Result := FCmd.Diff(Call)
  else if AName = 'pwd' then
    Result := FCmd.Pwd(Call)
  else if AName = 'stat' then
    Result := FCmd.StatCmd(Call)
  else if AName = 'seq' then
    Result := FCmd.Seq(Call)
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

procedure TShellCommandsTest.TestDiff;
var
  R: TShellResult;
  E: string;
begin
  { diff is how an agent verifies its own edit landed. Without it the only route
    was a perl or python3 escalation out of the gated tier. }
  FFs.WriteFile(P('same1.txt'), 'a' + #10 + 'b' + #10, False, E);
  FFs.WriteFile(P('same2.txt'), 'a' + #10 + 'b' + #10, False, E);
  FFs.WriteFile(P('chg.txt'), 'a' + #10 + 'c' + #10, False, E);

  R := RunCmd('diff', ['same1.txt', 'same2.txt']);
  AssertEquals('identical exits 0', 0, R.ExitCode);
  AssertEquals('and says nothing', '', R.Stdout);

  R := RunCmd('diff', ['same1.txt', 'chg.txt']);
  AssertEquals('different exits 1', 1, R.ExitCode);
  { DiffText emits unified format, so the removed line is prefixed '-' and the
    added one '+'. This is also the form patch_apply consumes. }
  AssertTrue('shows the old line: ' + R.Stdout, Pos('-b', R.Stdout) > 0);
  AssertTrue('shows the new line: ' + R.Stdout, Pos('+c', R.Stdout) > 0);

  { -q reports without the diff itself - what a script wants to branch on. }
  R := RunCmd('diff', ['-q', 'same1.txt', 'chg.txt']);
  AssertEquals('brief exits 1', 1, R.ExitCode);
  AssertTrue('brief names them: ' + R.Stdout, Pos('differ', R.Stdout) > 0);
  AssertTrue('and prints no hunks', Pos('-b', R.Stdout) = 0);
  R := RunCmd('diff', ['-q', 'same1.txt', 'same2.txt']);
  AssertEquals('brief identical exits 0', 0, R.ExitCode);

  { -u is the unified form, which is what patch_apply consumes. }
  R := RunCmd('diff', ['-u', 'same1.txt', 'chg.txt']);
  AssertEquals('unified exits 1', 1, R.ExitCode);
  AssertTrue('has the --- header: ' + R.Stdout, Pos('---', R.Stdout) > 0);
  AssertTrue('has the +++ header', Pos('+++', R.Stdout) > 0);
  AssertTrue('has a hunk header', Pos('@@', R.Stdout) > 0);

  { A missing file is an error, not "no differences". }
  R := RunCmd('diff', ['same1.txt', 'missing.txt']);
  AssertEquals('missing exits 2', 2, R.ExitCode);
  AssertTrue('names it', Pos('missing.txt', R.Stderr) > 0);
end;

procedure TShellCommandsTest.TestHashCommands;
var
  R: TShellResult;
  E: string;
begin
  { Hashing is how an agent checks a write landed and compares two files without
    reading them. }
  R := RunCmd('sha256sum', ['a.txt']);
  AssertEquals('sha256 exit', 0, R.ExitCode);
  { Cross-checked against `shasum -a 256` for the same content, so this asserts
    the algorithm rather than our own output shape. }
  AssertEquals('sha256 of a.txt',
    'e49c81e2d2f84e259d40e2fb8192f3bcd198b355184845d76d8f58807d0d78ee' +
      '  a.txt' + #10, R.Stdout);
  { Deterministic: the same bytes give the same digest. }
  AssertEquals('stable', R.Stdout, RunCmd('sha256sum', ['a.txt']).Stdout);
  { Different content, different digest. }
  AssertTrue('differs', R.Stdout <> RunCmd('sha256sum', ['b.txt']).Stdout);
  { The empty string's SHA-256 is a known constant, so this is a real check of
    the algorithm rather than of its own output. }
  FFs.WriteFile(P('empty.txt'), '', False, E);
  R := RunCmd('sha256sum', ['empty.txt']);
  AssertTrue('empty digest: ' + R.Stdout,
    Pos('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      LowerCase(R.Stdout)) > 0);
  { Missing file is an error, not an empty digest. }
  R := RunCmd('sha256sum', ['missing.txt']);
  AssertEquals('missing exit', 2, R.ExitCode);
  AssertTrue('names it', Pos('missing.txt', R.Stderr) > 0);
  { Stdin works, as `echo x | sha256sum`. }
  R := RunCmd('sha256sum', [], 'x' + #10);
  AssertEquals('stdin', 0, R.ExitCode);
end;

procedure TShellCommandsTest.TestOd;
var
  R: TShellResult;
  E: string;
begin
  { od is the hex viewer: how an agent inspects bytes it cannot read as text,
    which no other command in the tier can do. Reported missing when an agent
    reached for `od -c` and silently escalated to the process tier. }
  FFs.WriteFile(P('bin.dat'), 'AB' + #0 + #1, False, E);
  R := RunCmd('od', ['-An', '-tx1', 'bin.dat']);
  AssertEquals('od exit', 0, R.ExitCode);
  { Two spaces between bytes, matching real od: `41  42  00  01`. }
  AssertTrue('shows hex bytes: ' + R.Stdout,
    Pos('41  42  00  01', R.Stdout) > 0);
  { -c puts non-printables as escapes, the readable form. }
  R := RunCmd('od', ['-c', 'bin.dat']);
  AssertTrue('od -c names the nul: ' + R.Stdout, Pos('\0', R.Stdout) > 0);
  AssertTrue('and prints the letters', Pos('A', R.Stdout) > 0);
  { A missing file is an error. }
  R := RunCmd('od', ['missing.bin']);
  AssertEquals('missing exit', 2, R.ExitCode);
end;

procedure TShellCommandsTest.TestGrep;
var
  R: TShellResult;
begin
  R := RunCmd('grep', ['-m', '1', 'a', 'a.txt']);
  AssertEquals('max count', 'alpha' + #10, R.Stdout);
  R := RunCmd('grep', ['-m1', 'a', 'a.txt']);
  AssertEquals('attached -m1', 'alpha' + #10, R.Stdout);
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
  { -q says nothing and sets the status - what a script branches on. }
  R := RunCmd('grep', ['-q', 'beta', 'a.txt']);
  AssertEquals('quiet hit status', 0, R.ExitCode);
  AssertEquals('quiet says nothing', '', R.Stdout);
  R := RunCmd('grep', ['-q', 'nomatch', 'a.txt']);
  AssertEquals('quiet miss status', 1, R.ExitCode);
  { -h drops the filename a multi-file search would otherwise print. }
  R := RunCmd('grep', ['beta', 'a.txt', 'b.txt']);
  AssertEquals('multi-file names', 'a.txt:beta' + #10 + 'b.txt:beta' + #10,
    R.Stdout);
  R := RunCmd('grep', ['-h', 'beta', 'a.txt', 'b.txt']);
  AssertEquals('no names', 'beta' + #10 + 'beta' + #10, R.Stdout);
  { -o prints only the match, once per occurrence. }
  R := RunCmd('grep', ['-o', 'al', 'a.txt']);
  AssertEquals('only the match', 'al' + #10, R.Stdout);
  R := RunCmd('grep', ['-o', 'a', 'a.txt']);
  AssertEquals('one per match', 'a' + #10 + 'a' + #10 + 'a' + #10, R.Stdout);
  { -w needs whole words: 'bet' must not match 'beta'. }
  R := RunCmd('grep', ['-w', 'bet', 'a.txt']);
  AssertEquals('word miss', 1, R.ExitCode);
  R := RunCmd('grep', ['-w', 'alpha', 'a.txt']);
  AssertEquals('word hit', 'alpha' + #10, R.Stdout);
  { -x needs the whole line. }
  R := RunCmd('grep', ['-x', 'alph', 'a.txt']);
  AssertEquals('line miss', 1, R.ExitCode);
  R := RunCmd('grep', ['-x', 'alpha', 'a.txt']);
  AssertEquals('line hit', 'alpha' + #10, R.Stdout);
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

procedure TShellCommandsTest.TestLsLong;
var
  R: TShellResult;
  E, Line: string;
  Lines: TStringList;
  I: Integer;
  FoundDir, FoundMode: Boolean;
begin
  R := RunCmd('ls', ['-l', 'a.txt']);
  AssertTrue('mode column', Pos('-rw', R.Stdout) > 0);
  AssertTrue('size column', Pos('11', R.Stdout) > 0);
  AssertTrue('name column', Pos('a.txt', R.Stdout) > 0);
  R := RunCmd('ls', ['-l']);
  Lines := TStringList.Create;
  try
    Lines.Text := R.Stdout;
    FoundDir := False;
    FoundMode := False;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if (Length(Line) > 0) and (Line[1] = 'd') and
        (Pos(' sub', Line) > 0) then
        FoundDir := True;
      if (Length(Line) > 0) and (Line[1] = '-') and (Pos(' a.txt', Line) > 0) then
        FoundMode := True;
    end;
    AssertTrue('directory line starts with d', FoundDir);
    AssertTrue('file line starts with -', FoundMode);
  finally
    Lines.Free;
  end;
  FFs.WriteFile(P('.hidden'), 'x', False, E);
  R := RunCmd('ls', ['-l']);
  AssertFalse('hidden excluded without -a', Pos('.hidden', R.Stdout) > 0);
  R := RunCmd('ls', ['-la']);
  AssertTrue('hidden included with -a', Pos('.hidden', R.Stdout) > 0);
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
  { -n is the consequential one: without it "10" sorts before "9", so a numeric
    sort silently produces a WRONG ANSWER rather than an error. }
  AssertEquals('sort -n', '9' + #10 + '10' + #10 + '100' + #10,
    RunCmd('sort', ['-n'], '100' + #10 + '9' + #10 + '10' + #10).Stdout);
  AssertEquals('sort -nr', '100' + #10 + '10' + #10 + '9' + #10,
    RunCmd('sort', ['-nr'], '9' + #10 + '100' + #10 + '10' + #10).Stdout);
  { Negative and decimal numbers, which a lexical compare also gets wrong. }
  AssertEquals('sort -n handles signs', '-5' + #10 + '2' + #10 + '10' + #10,
    RunCmd('sort', ['-n'], '10' + #10 + '-5' + #10 + '2' + #10).Stdout);
  { -k picks a field, -t sets the separator. }
  AssertEquals('sort -t: -k2', 'x:1' + #10 + 'y:2' + #10,
    RunCmd('sort', ['-t:', '-k2'], 'y:2' + #10 + 'x:1' + #10).Stdout);
  AssertEquals('sort -k2 default blanks', 'b 1' + #10 + 'a 2' + #10,
    RunCmd('sort', ['-k2'], 'a 2' + #10 + 'b 1' + #10).Stdout);
  { -f folds case; without it upper-case sorts first. }
  AssertEquals('sort -f', 'apple' + #10 + 'Banana' + #10,
    RunCmd('sort', ['-f'], 'Banana' + #10 + 'apple' + #10).Stdout);
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
  { -i folds case in the comparison only; the printed line is the first of the
    run, as uniq(1) does. }
  AssertEquals('without -i case matters', 'A' + #10 + 'a' + #10,
    RunCmd('uniq', [], 'A' + #10 + 'a' + #10).Stdout);
  AssertEquals('uniq -i folds', 'A' + #10,
    RunCmd('uniq', ['-i'], 'A' + #10 + 'a' + #10).Stdout);
end;

procedure TShellCommandsTest.TestPwdStatSeq;
var
  R: TShellResult;
  E: string;
begin
  { pwd: the working directory. Trivial, but an agent reaches for it reflexively
    and its absence escalated the whole script. }
  R := RunCmd('pwd', []);
  AssertEquals('pwd exit', 0, R.ExitCode);
  AssertTrue('pwd says something: ' + R.Stdout, Trim(R.Stdout) <> '');

  { stat names a real file's size. }
  FFs.WriteFile(P('statme.txt'), 'abcdef', False, E);
  R := RunCmd('stat', ['statme.txt']);
  AssertEquals('stat exit', 0, R.ExitCode);
  AssertTrue('names the file: ' + R.Stdout, Pos('statme.txt', R.Stdout) > 0);
  { The SAME size wc -c reports, so the two cannot disagree. }
  AssertTrue('reports the size: ' + R.Stdout, Pos('6', R.Stdout) > 0);
  { A missing file is an error. }
  R := RunCmd('stat', ['nope.txt']);
  AssertEquals('stat missing exit', 1, R.ExitCode);

  { seq generates a range - the usual reason to reach for a loop. }
  R := RunCmd('seq', ['3']);
  AssertEquals('seq 3', '1' + #10 + '2' + #10 + '3' + #10, R.Stdout);
  R := RunCmd('seq', ['2', '4']);
  AssertEquals('seq from to', '2' + #10 + '3' + #10 + '4' + #10, R.Stdout);
  R := RunCmd('seq', ['1', '2', '5']);
  AssertEquals('seq with step', '1' + #10 + '3' + #10 + '5' + #10, R.Stdout);
  { A descending range needs a negative step, as seq(1) does. }
  R := RunCmd('seq', ['5', '-2', '1']);
  AssertEquals('seq descending', '5' + #10 + '3' + #10 + '1' + #10, R.Stdout);
  { Bad arguments are an error, not an empty range. }
  R := RunCmd('seq', ['x']);
  AssertTrue('seq rejects junk', R.ExitCode <> 0);
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
  { `\n` in a replacement is a newline, not the letter n. This was reported from
    another project: the agent kept seeing a literal 'n' where a line break
    belonged, because the escape handler emitted the escaped character verbatim
    for anything it did not recognise. }
  FFs.WriteFile(P('n.txt'), 'a-b' + #10, False, E);
  R := RunCmd('sed', ['s/-/\n/', 'n.txt']);
  AssertEquals('backslash-n is a newline', 'a' + #10 + 'b' + #10, R.Stdout);
  AssertTrue('and never a literal n', Pos('anb', R.Stdout) = 0);
  { `\t` likewise, and a real tab is what lands. }
  R := RunCmd('sed', ['s/-/\t/', 'n.txt']);
  AssertEquals('backslash-t is a tab', 'a' + #9 + 'b' + #10, R.Stdout);
  { An unknown escape stays literal, which is what sed does: `\q` is `q`. }
  R := RunCmd('sed', ['s/-/\q/', 'n.txt']);
  AssertEquals('unknown escape keeps the char', 'aqb' + #10, R.Stdout);
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

procedure TShellCommandsTest.TestFind;
var
  R: TShellResult;
  E: string;
begin
  R := RunCmd('find', ['.', '-name', '*.txt']);
  AssertEquals('name match', './a.txt' + #10 + './b.txt' + #10, R.Stdout);
  R := RunCmd('find', ['.', '-name', '*.log']);
  AssertEquals('log', './c.log' + #10, R.Stdout);
  R := RunCmd('find', ['.', '-type', 'd']);
  AssertEquals('directories', '.' + #10 + './sub' + #10, R.Stdout);
  R := RunCmd('find', ['sub']);
  AssertEquals('operand itself', 'sub' + #10, R.Stdout);
  R := RunCmd('find', ['.', '-maxdepth', '1', '-name', '*.txt']);
  AssertEquals('maxdepth', './a.txt' + #10 + './b.txt' + #10, R.Stdout);
  R := RunCmd('find', ['.', '-name', 'nope']);
  AssertEquals('no match status', 0, R.ExitCode);
  AssertEquals('no match output', '', R.Stdout);
  R := RunCmd('find', ['.', '-name', '*.txt', '-type', 'd']);
  AssertEquals('type filters names', '', R.Stdout);
  R := RunCmd('find', ['missing']);
  AssertEquals('missing operand', 1, R.ExitCode);
end;

procedure TShellCommandsTest.TestJq;
var
  R: TShellResult;
  E: string;
begin
  FFs.WriteFile(P('d.json'), '{"a":1,"b":[2,3]}', False, E);
  R := RunCmd('jq', ['.', 'd.json']);
  AssertEquals('pretty identity',
    '{' + #10 + '  "a": 1,' + #10 + '  "b": [' + #10 + '    2,' + #10 +
    '    3' + #10 + '  ]' + #10 + '}' + #10, R.Stdout);
  R := RunCmd('jq', ['-c', '.', 'd.json']);
  AssertEquals('compact', '{"a":1,"b":[2,3]}' + #10, R.Stdout);
  R := RunCmd('jq', ['.a', 'd.json']);
  AssertEquals('key', '1' + #10, R.Stdout);
  R := RunCmd('jq', ['.b[0]', 'd.json']);
  AssertEquals('index', '2' + #10, R.Stdout);
  R := RunCmd('jq', ['.b[-1]', 'd.json']);
  AssertEquals('negative index', '3' + #10, R.Stdout);
  R := RunCmd('jq', ['.b[]', 'd.json']);
  AssertEquals('iterate', '2' + #10 + '3' + #10, R.Stdout);
  R := RunCmd('jq', ['.missing', 'd.json']);
  AssertEquals('missing key is null', 'null' + #10, R.Stdout);
  FFs.WriteFile(P('s.json'), '{"s":"hi"}', False, E);
  R := RunCmd('jq', ['-r', '.s', 's.json']);
  AssertEquals('raw string', 'hi' + #10, R.Stdout);
  R := RunCmd('jq', ['.s', 's.json']);
  AssertEquals('quoted string', '"hi"' + #10, R.Stdout);
  FFs.WriteFile(P('bad.json'), 'not json', False, E);
  R := RunCmd('jq', ['.', 'bad.json']);
  AssertEquals('parse error status', 5, R.ExitCode);
  R := RunCmd('jq', ['.a | .b', 'd.json']);
  AssertEquals('unsupported filter status', 3, R.ExitCode);
end;

procedure TShellCommandsTest.TestCutTrPrintfTee;
var
  R: TShellResult;
  E, Data: string;
begin
  FFs.WriteFile(P('cols.txt'), 'a:1:one' + #10 + 'b:2:two' + #10, False, E);
  R := RunCmd('cut', ['-d:', '-f2', 'cols.txt']);
  AssertEquals('field', '1' + #10 + '2' + #10, R.Stdout);
  R := RunCmd('cut', ['-d:', '-f1,3', 'cols.txt']);
  AssertEquals('two fields', 'a:one' + #10 + 'b:two' + #10, R.Stdout);
  R := RunCmd('cut', ['-c1-3', 'a.txt']);
  AssertEquals('chars', 'alp' + #10 + 'bet' + #10, R.Stdout);
  FFs.WriteFile(P('mixed.txt'), 'x:1' + #10 + 'nocolon' + #10, False, E);
  R := RunCmd('cut', ['-s', '-d:', '-f2', 'mixed.txt']);
  AssertEquals('suppress', '1' + #10, R.Stdout);
  R := RunCmd('cut', ['-f2'], 'a' + #9 + 'b' + #9 + 'c' + #10);
  AssertEquals('tab is the default delimiter', 'b' + #10, R.Stdout);
  R := RunCmd('tr', ['a-z', 'A-Z'], 'abc');
  AssertEquals('tr maps', 'ABC', R.Stdout);
  R := RunCmd('tr', ['-d', 'a'], 'banana');
  AssertEquals('tr deletes', 'bnn', R.Stdout);
  R := RunCmd('tr', ['-s', ' '], 'a   b');
  AssertEquals('tr squeezes', 'a b', R.Stdout);
  R := RunCmd('printf', ['%s\n', 'one', 'two']);
  AssertEquals('printf recycles', 'one' + #10 + 'two' + #10, R.Stdout);
  R := RunCmd('printf', ['%d-%s\n', '3', 'x']);
  AssertEquals('printf directives', '3-x' + #10, R.Stdout);
  R := RunCmd('printf', ['a\tb\n']);
  AssertEquals('printf escapes', 'a' + #9 + 'b' + #10, R.Stdout);
  R := RunCmd('tee', ['t.txt'], 'data');
  AssertEquals('tee echoes', 'data', R.Stdout);
  AssertTrue('tee writes', FFs.ReadFile(P('t.txt'), Data, E));
  AssertEquals('tee content', 'data', Data);
end;

procedure TShellCommandsTest.TestRg;
var
  R: TShellResult;
  E: string;
begin
  FFs.MakeDir(P('.git'), False, E);
  FFs.WriteFile(P('.gitignore'), 'ignored/' + #10 + '*.log' + #10, False, E);
  FFs.MakeDir(P('ignored'), False, E);
  FFs.WriteFile(P('ignored/c.txt'), 'beta' + #10, False, E);
  FFs.WriteFile(P('d.log'), 'beta' + #10, False, E);
  FFs.WriteFile(P('.hidden'), 'beta' + #10, False, E);
  R := RunCmd('rg', ['beta']);
  AssertEquals('gitignore and hidden honoured', 'a.txt:beta' + #10 + 'b.txt:beta' + #10,
    R.Stdout);
  R := RunCmd('rg', ['-n', 'beta']);
  AssertEquals('line numbers', 'a.txt:2:beta' + #10 + 'b.txt:1:beta' + #10,
    R.Stdout);
  R := RunCmd('rg', ['-l', 'beta']);
  AssertEquals('files', 'a.txt' + #10 + 'b.txt' + #10, R.Stdout);
  R := RunCmd('rg', ['-c', 'beta']);
  AssertEquals('counts only for matches', 'a.txt:1' + #10 + 'b.txt:1' + #10,
    R.Stdout);
  R := RunCmd('rg', ['--hidden', 'beta']);
  AssertTrue('hidden included', Pos('.hidden:beta', R.Stdout) > 0);
  R := RunCmd('rg', ['-g', '*.log', 'beta']);
  AssertEquals('the ignore file still excludes logs', '', R.Stdout);
  R := RunCmd('rg', ['nothing-here']);
  AssertEquals('no match status', 1, R.ExitCode);
  { Without .git, ripgrep does not consult .gitignore either. }
  FFs.Delete(P('.git'), True, E);
  R := RunCmd('rg', ['beta']);
  AssertTrue('no repo means no ignore rules', Pos('d.log:beta', R.Stdout) > 0);
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
