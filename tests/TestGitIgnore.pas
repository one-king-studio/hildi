unit TestGitIgnore;
{ The reusable .gitignore parser. The expectations were recorded from
  `git check-ignore` on the same rules (git 2.54). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, HildiGitIgnore;

type
  TGitignoreTest = class(TTestCase)
  private
    FRules: TIgnoreRules;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRulesFromGit;
    procedure TestGitDirectory;
    procedure TestPatternLanguage;
  end;

implementation

const
  RootGitignore =
    '*.log' + #10 + '!important.log' + #10 + '/rootonly.txt' + #10 +
    'build/' + #10 + 'docs/**/draft.md' + #10 + 'temp/' + #10;
  SubGitignore = 'local.txt' + #10 + '!keep.log' + #10;

procedure TGitignoreTest.SetUp;
begin
  inherited SetUp;
  FRules := TIgnoreRules.Create(False);
  FRules.AddFile('', RootGitignore);
  FRules.AddFile('sub', SubGitignore);
end;

procedure TGitignoreTest.TearDown;
begin
  FRules.Free;
  inherited TearDown;
end;

procedure TGitignoreTest.TestRulesFromGit;
  procedure Expect(const APath: string; AIsDir, AIgnored: Boolean);
  begin
    AssertEquals(APath, AIgnored, FRules.IsIgnored(APath, AIsDir));
  end;
begin
  Expect('a.log', False, True);
  Expect('important.log', False, False);
  Expect('sub/a.log', False, True);
  Expect('sub/important.log', False, False);
  Expect('sub/keep.log', False, False);
  Expect('rootonly.txt', False, True);
  Expect('sub/rootonly.txt', False, False);
  Expect('build', True, True);
  Expect('build/x.txt', False, True);
  Expect('docs/draft.md', False, True);
  Expect('docs/a/draft.md', False, True);
  Expect('docs/a/b/other.md', False, False);
  Expect('temp/x', False, True);
  Expect('sub/local.txt', False, True);
  Expect('sub/sub2/local.txt', False, True);
  Expect('local.txt', False, False);
end;

procedure TGitignoreTest.TestGitDirectory;
var
  WithGit: TIgnoreRules;
begin
  AssertFalse('git does not report .git as a rule',
    FRules.IsIgnored('.git/config', False));
  WithGit := TIgnoreRules.Create(True);
  try
    WithGit.AddFile('', RootGitignore);
    AssertTrue('.git opt-in', WithGit.IsIgnored('.git/config', False));
    AssertTrue('nested .git opt-in', WithGit.IsIgnored('sub/.git', True));
  finally
    WithGit.Free;
  end;
end;

procedure TGitignoreTest.TestPatternLanguage;
begin
  AssertTrue('star does not cross a slash',
    not MatchIgnore('a/*.txt', 'a/b/c.txt'));
  AssertTrue('single star', MatchIgnore('a/*.txt', 'a/b.txt'));
  AssertTrue('double star crosses',
    MatchIgnore('a/**/c.txt', 'a/b/x/c.txt'));
  AssertTrue('double star matches zero dirs',
    MatchIgnore('a/**/c.txt', 'a/c.txt'));
  AssertTrue('question mark', MatchIgnore('a?.txt', 'ab.txt'));
  AssertFalse('question mark is one char', MatchIgnore('a?.txt', 'a.txt'));
  AssertTrue('class', MatchIgnore('a[0-9].txt', 'a7.txt'));
  AssertTrue('negated class', MatchIgnore('a[!0-9].txt', 'ab.txt'));
  AssertTrue('escape', MatchIgnore('a\*.txt', 'a*.txt'));
  AssertFalse('escape is literal only', MatchIgnore('a\*.txt', 'ab.txt'));
end;

initialization
  RegisterTest(TGitignoreTest);
end.
