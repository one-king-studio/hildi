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

initialization
  RegisterTest(TShellEffectsTest);
end.
