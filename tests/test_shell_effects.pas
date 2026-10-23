unit test_shell_effects;
{ The per-command effect table: which expanded arguments are reads and which
  are writes, positionally (grep's first operand is a pattern, cp's second is
  the destination). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, hildegard.helper.shell.effects;

type
  TShellEffectsTest = class(TTestCase)
  private
    function Reads(const AName: string; const AArgs: array of string): string;
    function Writes(const AName: string; const AArgs: array of string): string;
    function Known(const AName: string; const AArgs: array of string): Boolean;
  published
    procedure TestPureCommands;
    procedure TestReadCommands;
    procedure TestPatternCommands;
    procedure TestWriteCommands;
    procedure TestMixed;
    procedure TestUnknownIsNotKnown;
    { An option's SEPARATE value is not a path. `grep -A 1 pat file` must read
      `file`, not the regex and not the number. }
    procedure TestSeparateOptionValuesAreNotPaths;
    { /dev/null is a sink, not a file to be read or written. }
    procedure TestDevNullIsNotAReadOrAWrite;
    { The matrix: every supported command's effect class, so a new command cannot
      arrive without a decision about what it does. }
    procedure TestEverySupportedCommandHasAClass;
  end;

implementation

function Join(const A: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + A[I];
  end;
end;

function TShellEffectsTest.Reads(const AName: string;
  const AArgs: array of string): string;
var
  R, W: TStringArray;
  K: Boolean;
  Args: TStringArray;
  I: Integer;
begin
  SetLength(Args, Length(AArgs));
  for I := 0 to High(AArgs) do
    Args[I] := AArgs[I];
  ComputeEffects(AName, Args, R, W, K);
  Result := Join(R);
end;

function TShellEffectsTest.Writes(const AName: string;
  const AArgs: array of string): string;
var
  R, W: TStringArray;
  K: Boolean;
  Args: TStringArray;
  I: Integer;
begin
  SetLength(Args, Length(AArgs));
  for I := 0 to High(AArgs) do
    Args[I] := AArgs[I];
  ComputeEffects(AName, Args, R, W, K);
  Result := Join(W);
end;

function TShellEffectsTest.Known(const AName: string;
  const AArgs: array of string): Boolean;
var
  R, W: TStringArray;
  Args: TStringArray;
  I: Integer;
begin
  SetLength(Args, Length(AArgs));
  for I := 0 to High(AArgs) do
    Args[I] := AArgs[I];
  ComputeEffects(AName, Args, R, W, Result);
end;

procedure TShellEffectsTest.TestPureCommands;
begin
  AssertEquals('echo', '', Reads('echo', ['x']));
  AssertEquals('echo writes', '', Writes('echo', ['x']));
  AssertTrue('echo known', Known('echo', ['x']));
  AssertEquals('basename', '', Reads('basename', ['/a/b']));
end;

procedure TShellEffectsTest.TestReadCommands;
begin
  AssertEquals('cat', 'a.txt,b.txt', Reads('cat', ['a.txt', 'b.txt']));
  AssertEquals('cat writes', '', Writes('cat', ['a.txt']));
  AssertEquals('head', 'f', Reads('head', ['-n', '3', 'f']));
  AssertEquals('tail', 'f', Reads('tail', ['-5', 'f']));
  AssertEquals('wc', 'f', Reads('wc', ['-l', 'f']));
  AssertEquals('ls default', '.', Reads('ls', []));
  AssertEquals('ls path', 'dir', Reads('ls', ['-la', 'dir']));
  AssertEquals('find default', '.', Reads('find', []));
  AssertEquals('find roots', 'a,b', Reads('find', ['a', 'b', '-name', 'x']));
  AssertEquals('sort', 'f', Reads('sort', ['-r', 'f']));
  AssertEquals('uniq', 'f', Reads('uniq', ['-c', 'f']));
  AssertEquals('tr stdin only', '', Reads('tr', ['a-z', 'A-Z']));
end;

procedure TShellEffectsTest.TestPatternCommands;
begin
  AssertEquals('grep', 'f,g', Reads('grep', ['-n', 'pat', 'f', 'g']));
  AssertEquals('grep no file', '', Reads('grep', ['pat']));
  { -m's count is a value, not the pattern, attached or separate. }
  AssertEquals('grep -m1', 'a.txt',
    Reads('grep', ['-m1', 'pat', 'a.txt']));
  AssertEquals('grep -m 1', 'a.txt',
    Reads('grep', ['-m', '1', 'pat', 'a.txt']));
  AssertEquals('rg default', '.', Reads('rg', ['pat']));
  AssertEquals('rg paths', 'src', Reads('rg', ['-n', 'pat', 'src']));
  AssertEquals('jq', 'd.json', Reads('jq', ['-r', '.a', 'd.json']));
  AssertEquals('awk', 'f', Reads('awk', ['{print $1}', 'f']));
  AssertEquals('awk -F', 'f', Reads('awk', ['-F:', '{print $2}', 'f']));
end;

procedure TShellEffectsTest.TestWriteCommands;
begin
  AssertEquals('tee', 'a,b', Writes('tee', ['a', 'b']));
  AssertEquals('tee -a', 'a', Writes('tee', ['-a', 'a']));
  AssertEquals('rm', 'a,b', Writes('rm', ['-rf', 'a', 'b']));
  AssertEquals('mkdir', 'd', Writes('mkdir', ['-p', 'd']));
  AssertEquals('touch', 'a,b', Writes('touch', ['a', 'b']));
  AssertEquals('sed -i', 'f', Writes('sed', ['-i', 's/a/b/', 'f']));
  AssertEquals('sed -i reads nothing', '', Reads('sed', ['-i', 's/a/b/', 'f']));
  AssertEquals('sed plain reads', 'f', Reads('sed', ['s/a/b/', 'f']));
  AssertEquals('sed -n range reads', 'f', Reads('sed', ['-n', '1,2p', 'f']));
end;

procedure TShellEffectsTest.TestMixed;
begin
  AssertEquals('cp reads the source', 'src', Reads('cp', ['src', 'dst']));
  AssertEquals('cp writes the destination', 'dst', Writes('cp', ['src', 'dst']));
  AssertEquals('mv writes both', 'src,dst', Writes('mv', ['src', 'dst']));
  AssertEquals('test -f reads', 'f', Reads('test', ['-f', 'f']));
  AssertEquals('test string has no effect', '', Reads('test', ['a', '=', 'b']));
end;

procedure TShellEffectsTest.TestUnknownIsNotKnown;
begin
  AssertFalse('tool', Known('tool', ['file_read']));
  AssertFalse('mcp', Known('mcp', ['s:t']));
  AssertFalse('unknown', Known('git', ['status']));
end;

procedure TShellEffectsTest.TestSeparateOptionValuesAreNotPaths;
begin
  { The reported bug: an option's value was read as a path, so a regular
    expression got asked about as if it were a directory. }
  AssertEquals('grep -A 1', 'f', Reads('grep', ['-A', '1', 'pat', 'f']));
  AssertEquals('grep -B 2', 'f', Reads('grep', ['-B', '2', 'pat', 'f']));
  AssertEquals('grep -C 3', 'f', Reads('grep', ['-C', '3', 'pat', 'f']));
  AssertEquals('grep -e', 'f', Reads('grep', ['-e', 'a.*b', 'f']));
  AssertEquals('grep -m', '', Reads('grep', ['-m', '5', 'pat']));
  { A regex that looks like a path is still a pattern, not a file. }
  AssertEquals('regex operand', 'f', Reads('grep', ['^/var/log/', 'f']));
  { sort/uniq/cut values. }
  AssertEquals('sort -k', 'f', Reads('sort', ['-k', '2', 'f']));
  AssertEquals('sort -t', 'f', Reads('sort', ['-t', ':', 'f']));
  AssertEquals('cut -d', 'f', Reads('cut', ['-d', ':', '-f', '1', 'f']));
  { awk -v is a variable assignment, not a file. }
  AssertEquals('awk -v', 'f', Reads('awk', ['-v', 'n=1', '{print}', 'f']));
  { sed -e takes the script, so no positional script is consumed. }
  AssertEquals('sed -e', 'f', Reads('sed', ['-e', 's/a/b/', 'f']));
end;

procedure TShellEffectsTest.TestDevNullIsNotAReadOrAWrite;
begin
  { /dev/null is a sink and a source of nothing. Asking the operator to approve
    writing to it is pure noise, and reading it names no file. }
  AssertEquals('cat /dev/null read', '', Reads('cat', ['/dev/null']));
  AssertEquals('tee /dev/null write', '', Writes('tee', ['/dev/null']));
  AssertEquals('> style: cp to /dev/null', '', Writes('cp', ['a.txt',
    '/dev/null']));
  AssertEquals('rm /dev/null', '', Writes('rm', ['/dev/null']));
  { A real file alongside it is still counted. }
  AssertEquals('cat f /dev/null', 'f', Reads('cat', ['f', '/dev/null']));
  AssertEquals('tee f /dev/null', 'f', Writes('tee', ['f', '/dev/null']));
end;

procedure TShellEffectsTest.TestEverySupportedCommandHasAClass;
begin
  { The matrix, asserted: every command the tier admits must either be known to
    this table or deliberately unknown. A new command that forgets to declare its
    effects would otherwise fall through to "not known" and be asked about as an
    opaque command - safe, but it would hide a missing decision. }
  AssertTrue('echo', Known('echo', []));
  AssertTrue('printf', Known('printf', []));
  AssertTrue('cat', Known('cat', []));
  AssertTrue('head', Known('head', []));
  AssertTrue('tail', Known('tail', []));
  AssertTrue('wc', Known('wc', []));
  AssertTrue('grep', Known('grep', []));
  AssertTrue('sed', Known('sed', []));
  AssertTrue('awk', Known('awk', []));
  AssertTrue('find', Known('find', []));
  AssertTrue('jq', Known('jq', []));
  AssertTrue('cut', Known('cut', []));
  AssertTrue('tr', Known('tr', []));
  AssertTrue('tee', Known('tee', []));
  AssertTrue('rg', Known('rg', []));
  AssertTrue('ls', Known('ls', []));
  AssertTrue('mkdir', Known('mkdir', []));
  AssertTrue('rm', Known('rm', []));
  AssertTrue('sort', Known('sort', []));
  AssertTrue('uniq', Known('uniq', []));
  AssertTrue('mv', Known('mv', []));
  AssertTrue('cp', Known('cp', []));
  AssertTrue('touch', Known('touch', []));
  AssertTrue('basename', Known('basename', []));
  AssertTrue('dirname', Known('dirname', []));
  AssertTrue('test', Known('test', []));
  AssertTrue('[', Known('[', []));
  AssertTrue('true', Known('true', []));
  AssertTrue('false', Known('false', []));
  { These two are deliberately opaque: they call other tools, whose gates apply. }
  AssertFalse('tool is opaque', Known('tool', []));
  AssertFalse('mcp is opaque', Known('mcp', []));
end;

initialization
  RegisterTest(TShellEffectsTest);
end.
