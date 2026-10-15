unit test_workspace;
{ fpcunit tests for hildegard.helper.workspace. Pure path logic plus a store
  round trip against a temporary database. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  {$ifdef unix}BaseUnix,{$endif}
  hildegard.helper.store, hildegard.helper.workspace;

{$ifdef unix}
function c_symlink(ATarget, ALinkPath: PAnsiChar): cint; cdecl;
  external 'c' name 'symlink';
{$endif}

type
  TWorkspaceTest = class(TTestCase)
  private
    FBase, FWork, FWorkshop, FFile, FDbPath: string;
    function OpenStore: TSqliteStore;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSelectsGivenPath;
    procedure TestDefaultsToCurrentDir;
    procedure TestCanonicalisesRelativeSegments;
    procedure TestMissingDirectoryFails;
    procedure TestFileInsteadOfDirectoryFails;
    procedure TestResolveRelativeUsesRoot;
    procedure TestContainsRootAndChild;
    procedure TestDoesNotContainSiblingPrefix;
    procedure TestDoesNotContainEscape;
    procedure TestEnsureWorkspaceIsIdempotent;
    procedure TestPhysicalContainsAcceptsInside;
    procedure TestPhysicalContainsRefusesOutside;
    procedure TestSymlinkOutOfTheWorkspaceIsRefused;
    procedure TestNonExistentTailUsesTheNearestExistingAncestor;
    procedure TestBoundarySiblingIsNotUnder;
  end;

implementation

procedure TWorkspaceTest.SetUp;
begin
  FBase := IncludeTrailingPathDelimiter(GetTempDir) + 'hhws_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  CreateDir(FBase);
  FWork := IncludeTrailingPathDelimiter(FBase) + 'work';
  FWorkshop := IncludeTrailingPathDelimiter(FBase) + 'workshop';
  FFile := IncludeTrailingPathDelimiter(FBase) + 'afile';
  CreateDir(FWork);
  CreateDir(FWorkshop);
  with TFileStream.Create(FFile, fmCreate) do
    Free;
  FDbPath := IncludeTrailingPathDelimiter(FBase) + 'store.db';
end;

procedure TWorkspaceTest.TearDown;
begin
  DeleteFile(FDbPath);
  DeleteFile(FDbPath + '-wal');
  DeleteFile(FDbPath + '-shm');
  DeleteFile(FFile);
  RemoveDir(FWork);
  RemoveDir(FWorkshop);
  RemoveDir(FBase);
end;

function TWorkspaceTest.OpenStore: TSqliteStore;
var
  Cfg: TStoreConfig;
  Err: TStoreError;
begin
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  Result := TSqliteStore.Create(Cfg);
  if not Result.Open(Err) then
  begin
    Result.Free;
    raise Exception.Create('store failed to open: ' + Err.Message);
  end;
end;

procedure TWorkspaceTest.TestSelectsGivenPath;
var
  W: TWorkspace;
  E: string;
begin
  W := TWorkspace.Open(FWork, E);
  try
    AssertTrue('opened', W <> nil);
    AssertEquals('root', CanonicalWorkspacePath(FWork), W.Root);
  finally
    W.Free;
  end;
end;

procedure TWorkspaceTest.TestDefaultsToCurrentDir;
var
  W: TWorkspace;
  E: string;
begin
  W := TWorkspace.Open('', E);
  try
    AssertTrue('opened', W <> nil);
    AssertEquals('cwd', CanonicalWorkspacePath(GetCurrentDir), W.Root);
  finally
    W.Free;
  end;
end;

procedure TWorkspaceTest.TestCanonicalisesRelativeSegments;
var
  Messy, Clean: string;
begin
  Messy := IncludeTrailingPathDelimiter(FBase) + 'work' + PathDelim + '.' +
    PathDelim + 'sub' + PathDelim + '..';
  Clean := IncludeTrailingPathDelimiter(FBase) + 'work';
  AssertEquals('normalised', CanonicalWorkspacePath(Clean),
    CanonicalWorkspacePath(Messy));
end;

procedure TWorkspaceTest.TestMissingDirectoryFails;
var
  E: string;
begin
  AssertFalse('missing fails',
    WorkspaceAccessible(IncludeTrailingPathDelimiter(FBase) + 'nope', E));
  AssertTrue('error set', E <> '');
end;

procedure TWorkspaceTest.TestFileInsteadOfDirectoryFails;
var
  E: string;
begin
  AssertFalse('file fails', WorkspaceAccessible(FFile, E));
end;

procedure TWorkspaceTest.TestResolveRelativeUsesRoot;
var
  W: TWorkspace;
  E: string;
begin
  W := TWorkspace.Open(FWork, E);
  try
    AssertEquals('resolved', ExpandFileName(IncludeTrailingPathDelimiter(FWork) +
      'a' + PathDelim + 'b'), W.Resolve('a/b'));
  finally
    W.Free;
  end;
end;

procedure TWorkspaceTest.TestContainsRootAndChild;
var
  W: TWorkspace;
  E: string;
begin
  W := TWorkspace.Open(FWork, E);
  try
    AssertTrue('root contained', W.Contains(FWork));
    AssertTrue('child contained', W.Contains('sub'));
  finally
    W.Free;
  end;
end;

procedure TWorkspaceTest.TestDoesNotContainSiblingPrefix;
var
  W: TWorkspace;
  E: string;
begin
  W := TWorkspace.Open(FWork, E);
  try
    AssertFalse('sibling prefix not contained', W.Contains(FWorkshop));
    AssertFalse('sibling relative not contained', W.Contains('../workshop'));
  finally
    W.Free;
  end;
end;

procedure TWorkspaceTest.TestDoesNotContainEscape;
var
  W: TWorkspace;
  E: string;
begin
  W := TWorkspace.Open(FWork, E);
  try
    AssertFalse('parent not contained', W.Contains('..'));
    AssertFalse('absolute elsewhere not contained', W.Contains('/etc'));
  finally
    W.Free;
  end;
end;

procedure TWorkspaceTest.TestEnsureWorkspaceIsIdempotent;
var
  S: TSqliteStore;
  Err: TStoreError;
  A, B: Integer;
begin
  S := OpenStore;
  try
    AssertTrue('first', S.EnsureWorkspace(FWork, A, Err));
    AssertTrue('second', S.EnsureWorkspace(FWork, B, Err));
    AssertEquals('same id', A, B);
    AssertTrue('found', S.FindWorkspace(FWork, B, Err));
    AssertEquals('found id', A, B);
    AssertFalse('unknown path not found',
      S.FindWorkspace(FWorkshop, B, Err));
    AssertEquals('not found code', Ord(seNotFound), Ord(Err.Code));
  finally
    S.Free;
  end;
end;

procedure TWorkspaceTest.TestPhysicalContainsAcceptsInside;
begin
  { A path under the root is in-bounds, existing or not. }
  AssertTrue('existing child',
    PhysicalContains(FWork, IncludeTrailingPathDelimiter(FWork) + 'a.txt'));
  AssertTrue('the root itself', PhysicalContains(FWork, FWork));
  AssertTrue('non-existent nested',
    PhysicalContains(FWork, 'sub/deep/a.txt'));
end;

procedure TWorkspaceTest.TestPhysicalContainsRefusesOutside;
begin
  AssertFalse('absolute outside',
    PhysicalContains(FWork, '/etc/hosts'));
  AssertFalse('escape with ..',
    PhysicalContains(FWork, '../../etc/hosts'));
end;

procedure TWorkspaceTest.TestSymlinkOutOfTheWorkspaceIsRefused;
var
  Link: string;
  Ws: TWorkspace;
  Err: string;
begin
  { A symlink INSIDE the workspace that points OUTSIDE: the lexical reading
    says "inside" (the link path is under the root), but the physical reading
    resolves it out. The two-readings rule refuses it. }
  Link := IncludeTrailingPathDelimiter(FWork) + 'escape';
  if c_symlink(PAnsiChar(AnsiString(FWorkshop)),
    PAnsiChar(AnsiString(Link))) <> 0 then
    Exit;   { no symlink support: skip }
  Ws := TWorkspace.Open(FWork, Err);
  try
    AssertTrue('lexical says inside', Ws.Contains('escape/secret.txt'));
  finally
    Ws.Free;
  end;
  AssertFalse('physical refuses it',
    PhysicalContains(FWork, 'escape/secret.txt'));
  AssertFalse('physical refuses the link too',
    PhysicalContains(FWork, 'escape'));
end;

procedure TWorkspaceTest.TestNonExistentTailUsesTheNearestExistingAncestor;
var
  R: string;
begin
  { The tail does not exist; the nearest existing ancestor (FWork) is
    realpath-resolved and the tail re-appended. }
  R := PhysicalResolve(FWork, 'a/b/c.txt');
  AssertTrue('kept the tail', Pos('a' + PathDelim + 'b' + PathDelim + 'c.txt',
    R) > 0);
end;

procedure TWorkspaceTest.TestBoundarySiblingIsNotUnder;
begin
  { `work` must not be considered under `workshop` (the separator boundary). }
  AssertFalse('sibling prefix',
    PhysicalContains(FWorkshop, FWork));
  AssertFalse('sibling prefix with a child',
    PhysicalContains(FWorkshop, IncludeTrailingPathDelimiter(FWork) + 'x'));
end;

initialization
  RegisterTest(TWorkspaceTest);
end.
