unit test_shell_harness_fs;
{ The workspace-bounded filesystem of the builtin shell tier: operations inside
  the root, refusals outside it (including through a symlink), and the extra
  operations the commands need. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, BaseUnix, fpcunit, testregistry,
  shell.fs, hildi.shell.fs;

type
  TShellHarnessFsTest = class(TTestCase)
  private
    FRoot: string;
    FFs: TWorkspaceShellFs;
    function P(const AName: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestReadWriteAppend;
    procedure TestListAndStat;
    procedure TestCwdResolution;
    procedure TestOutsideRefused;
    procedure TestSymlinkEscapeRefused;
    procedure TestRecursiveDelete;
    procedure TestMoveAndCopy;
    procedure TestMakeDirAndTouch;
    procedure TestReadCap;
  end;

implementation

function TShellHarnessFsTest.P(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot) + AName;
end;

procedure TShellHarnessFsTest.SetUp;
begin
  inherited SetUp;
  FRoot := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'shellfs-' +
    IntToStr(Random(100000000));
  ForceDirectories(FRoot);

  FFs := TWorkspaceShellFs.Create(FRoot);
end;

procedure TShellHarnessFsTest.TearDown;
var
  Tmp: TWorkspaceShellFs;
  E: string;
begin
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

procedure TShellHarnessFsTest.TestReadWriteAppend;
var
  E, Data: string;
begin
  AssertTrue('write', FFs.WriteFile(P('a.txt'), 'one', False, E));
  AssertTrue('read', FFs.ReadFile(P('a.txt'), Data, E));
  AssertEquals('content', 'one', Data);
  AssertTrue('append', FFs.WriteFile(P('a.txt'), 'two', True, E));
  AssertTrue('read again', FFs.ReadFile(P('a.txt'), Data, E));
  AssertEquals('appended', 'onetwo', Data);
  AssertTrue('truncate', FFs.WriteFile(P('a.txt'), 'x', False, E));
  AssertTrue('read truncated', FFs.ReadFile(P('a.txt'), Data, E));
  AssertEquals('truncated', 'x', Data);
  AssertFalse('missing read fails', FFs.ReadFile(P('nope.txt'), Data, E));
  AssertTrue('missing names the error', Pos('no such file', E) > 0);
end;

procedure TShellHarnessFsTest.TestListAndStat;
const
  Expected: array[0..2] of string = ('a.txt', 'b.txt', 'sub');
var
  E: string;
  Entries: TStringArray;
  Kind: TShellFileKind;
  I: Integer;
begin
  FFs.WriteFile(P('a.txt'), 'a', False, E);
  FFs.WriteFile(P('b.txt'), 'b', False, E);
  FFs.MakeDir(P('sub'), False, E);
  AssertTrue('list', FFs.ListDir(FRoot, Entries, E));
  AssertEquals('three entries', 3, Length(Entries));
  for I := 0 to 2 do
    AssertEquals('entry ' + IntToStr(I), Expected[I], Entries[I]);
  AssertTrue('stat file', FFs.Stat(P('a.txt'), Kind, E));
  AssertEquals('file kind', Ord(sfkFile), Ord(Kind));
  AssertTrue('stat dir', FFs.Stat(P('sub'), Kind, E));
  AssertEquals('dir kind', Ord(sfkDirectory), Ord(Kind));
  AssertFalse('stat missing', FFs.Stat(P('nope'), Kind, E));
  AssertEquals('missing kind', Ord(sfkMissing), Ord(Kind));
  AssertFalse('list a file', FFs.ListDir(P('a.txt'), Entries, E));
end;

procedure TShellHarnessFsTest.TestCwdResolution;
begin
  AssertEquals('relative', '/work/a', FFs.Resolve('/work', 'a'));
  AssertEquals('absolute', '/x/y', FFs.Resolve('/work', '/x/y'));
  AssertEquals('dotdot', '/x/y', FFs.Resolve('/work', '/x/./z/../y'));
  AssertEquals('empty is cwd', '/work', FFs.Resolve('/work', ''));
  AssertEquals('duplicate slashes', '/x/y', FFs.Resolve('/work', '/x//y'));
end;

procedure TShellHarnessFsTest.TestOutsideRefused;
var
  E, Data: string;
  Kind: TShellFileKind;
  Entries: TStringArray;
begin
  AssertFalse('read outside', FFs.ReadFile('/etc/hosts', Data, E));
  AssertTrue('read says escape', Pos('escapes the workspace', E) > 0);
  AssertFalse('write outside', FFs.WriteFile('/tmp/shellfs-escape', 'x', False, E));
  AssertTrue('write says escape', Pos('escapes the workspace', E) > 0);
  AssertFalse('list outside', FFs.ListDir('/etc', Entries, E));
  AssertFalse('stat outside', FFs.Stat('/etc', Kind, E));
  E := '';
  AssertFalse('dotdot write outside', FFs.WriteFile(P('../shellfs-escape'), 'x', False, E));
  AssertTrue('dotdot says escape', Pos('escapes the workspace', E) > 0);
end;

procedure TShellHarnessFsTest.TestSymlinkEscapeRefused;
var
  E, Data: string;
  Link: string;
  Entries: TStringArray;
begin
  Link := P('escape');
  if fpSymlink('/etc', PChar(Link)) <> 0 then
    Exit;   // the platform refused the symlink; nothing to test here
  AssertFalse('list through symlink', FFs.ListDir(Link, Entries, E));
  AssertTrue('names the escape', Pos('escapes the workspace', E) > 0);
  AssertFalse('read through symlink', FFs.ReadFile(Link + '/hosts', Data, E));
end;

procedure TShellHarnessFsTest.TestRecursiveDelete;
var
  E: string;
begin
  FFs.MakeDir(P('sub'), False, E);
  FFs.WriteFile(P('sub/child.txt'), 'x', False, E);
  AssertFalse('non-recursive refuses a full dir', FFs.Delete(P('sub'), False, E));
  AssertTrue('still there', DirectoryExists(P('sub')));
  AssertTrue('recursive delete', FFs.Delete(P('sub'), True, E));
  AssertFalse('gone', DirectoryExists(P('sub')));
  FFs.WriteFile(P('f.txt'), 'x', False, E);
  AssertTrue('file delete', FFs.Delete(P('f.txt'), False, E));
  AssertFalse('file gone', FileExists(P('f.txt')));
  AssertFalse('missing delete fails', FFs.Delete(P('nope'), False, E));
  AssertFalse('root delete refused', FFs.Delete(FRoot, True, E));
end;

procedure TShellHarnessFsTest.TestMoveAndCopy;
var
  E, Data: string;
begin
  FFs.WriteFile(P('a.txt'), 'alpha', False, E);
  AssertTrue('copy', FFs.Copy(P('a.txt'), P('b.txt'), E));
  AssertTrue('copy read', FFs.ReadFile(P('b.txt'), Data, E));
  AssertEquals('copy content', 'alpha', Data);
  AssertTrue('move', FFs.Move(P('b.txt'), P('c.txt'), E));
  AssertFalse('source gone', FileExists(P('b.txt')));
  AssertTrue('target exists', FileExists(P('c.txt')));
  { mv overwrites an existing file (Windows needs the explicit delete). }
  FFs.WriteFile(P('dest.txt'), 'old', False, E);
  AssertTrue('move over an existing file', FFs.Move(P('c.txt'), P('dest.txt'), E));
  AssertTrue('overwritten content', FFs.ReadFile(P('dest.txt'), Data, E));
  AssertEquals('new content', 'alpha', Data);
  AssertFalse('move missing', FFs.Move(P('nope'), P('d.txt'), E));
  FFs.MakeDir(P('dir'), False, E);
  AssertFalse('copy a directory', FFs.Copy(P('dir'), P('e'), E));
end;

procedure TShellHarnessFsTest.TestMakeDirAndTouch;
var
  E: string;
begin
  AssertTrue('mkdir -p', FFs.MakeDir(P('a/b/c'), True, E));
  AssertTrue('created', DirectoryExists(P('a/b/c')));
  AssertFalse('mkdir without -p on a missing parent',
    FFs.MakeDir(P('x/y'), False, E));
  AssertTrue('touch creates', FFs.Touch(P('t.txt'), E));
  AssertTrue('touched', FileExists(P('t.txt')));
  AssertTrue('touch existing is fine', FFs.Touch(P('t.txt'), E));
end;

procedure TShellHarnessFsTest.TestReadCap;
var
  E, Data: string;
begin
  FFs.WriteFile(P('big.txt'), '0123456789', False, E);
  FFs.MaxFileBytes := 4;
  AssertFalse('over the cap', FFs.ReadFile(P('big.txt'), Data, E));
  AssertTrue('says so', Pos('read cap', E) > 0);
  FFs.MaxFileBytes := 100;
  AssertTrue('under the cap', FFs.ReadFile(P('big.txt'), Data, E));
  AssertEquals('content', '0123456789', Data);
end;

initialization
  RegisterTest(TShellHarnessFsTest);
end.
