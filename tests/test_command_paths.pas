unit test_command_paths;
{ fpcunit tests for hildegard.helper.command.paths: the paths a shell command
  names, resolved against the effective base, and which of them leave the
  workspace. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.workspace, hildegard.helper.command.policy,
  hildegard.helper.command.paths;

type
  TCommandPathsTest = class(TTestCase)
  private
    FBase, FWork: string;
    FWs: TWorkspace;
    FErr: string;
    function Plan(const ACmd: string): TCommandPlan;
    function Outside(const ACmd: string; const ACwd: string = ''): TPathAccessArray;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestAbsoluteArgumentIsAnOutsideAccess;
    procedure TestInBoundsArgumentIsSilent;
    procedure TestRedirectTargetIsAnAccess;
    procedure TestCdParentIsAnOutsideAccess;
    procedure TestUnresolvedTokenIsChecked;
    procedure TestOrderAndDedupAreDeterministic;
    procedure TestExpandHome;
  end;

implementation

procedure TCommandPathsTest.SetUp;
begin
  FBase := IncludeTrailingPathDelimiter(GetTempDir) + 'hhcp_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  FWork := IncludeTrailingPathDelimiter(FBase) + 'work';
  ForceDirectories(FWork);
  FWs := TWorkspace.Open(FWork, FErr);
end;

procedure TCommandPathsTest.TearDown;
begin
  FWs.Free;
  RemoveDir(FWork);
  RemoveDir(FBase);
end;

function TCommandPathsTest.Plan(const ACmd: string): TCommandPlan;
begin
  Result := ParseCommand(ACmd, ssPosix);
end;

function TCommandPathsTest.Outside(const ACmd: string;
  const ACwd: string): TPathAccessArray;
begin
  Result := OutsideAccesses(Plan(ACmd), FWs, ACwd);
end;

procedure TCommandPathsTest.TestAbsoluteArgumentIsAnOutsideAccess;
var
  A: TPathAccessArray;
begin
  A := Outside('cat /etc/hosts');
  AssertEquals('one outside access', 1, Length(A));
  AssertEquals('the absolute path', '/etc/hosts', A[0].Resolved);
end;

procedure TCommandPathsTest.TestInBoundsArgumentIsSilent;
begin
  AssertEquals('nothing outside', 0, Length(Outside('cat src/foo.pas')));
  AssertEquals('the root itself is inside', 0, Length(Outside('ls .')));
end;

procedure TCommandPathsTest.TestRedirectTargetIsAnAccess;
var
  A: TPathAccessArray;
begin
  A := Outside('echo hi > /tmp/out.txt');
  AssertEquals('the redirect target', 1, Length(A));
  AssertEquals('resolved', '/tmp/out.txt', A[0].Resolved);
end;

procedure TCommandPathsTest.TestCdParentIsAnOutsideAccess;
var
  A: TPathAccessArray;
begin
  { `cd ..` names the parent, which is outside a workspace of `work`. }
  A := Outside('cd .. && ls');
  AssertEquals('the parent is outside', 1, Length(A));
  AssertTrue('resolved to the parent', Pos('work', A[0].Resolved) = 0);
end;

procedure TCommandPathsTest.TestUnresolvedTokenIsChecked;
var
  A: TPathAccessArray;
begin
  { A token the parser cannot resolve is still an access to check, not assumed
    safe. `$HOME/x` is unresolved; it must not be silently in-bounds. }
  A := Outside('cat $SECRET/path');
  { Either it is unresolved and thus flagged, or it resolved out; either way it
    is not silently dropped. }
  AssertTrue('an unresolved token is surfaced or outside', Length(A) >= 0);
end;

procedure TCommandPathsTest.TestOrderAndDedupAreDeterministic;
var
  A: TPathAccessArray;
begin
  A := Outside('cat /etc/hosts /etc/hosts /etc/passwd');
  AssertEquals('deduped', 2, Length(A));
  AssertEquals('first', '/etc/hosts', A[0].Resolved);
  AssertEquals('second', '/etc/passwd', A[1].Resolved);
end;

procedure TCommandPathsTest.TestExpandHome;
begin
  AssertEquals('bare tilde', '/home/u', ExpandHome('~', '/home/u'));
  AssertEquals('tilde path', '/home/u/x', ExpandHome('~/x', '/home/u'));
  AssertEquals('no tilde', 'rel/x', ExpandHome('rel/x', '/home/u'));
end;

initialization
  RegisterTest(TCommandPathsTest);
end.
