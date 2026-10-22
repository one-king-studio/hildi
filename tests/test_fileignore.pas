unit test_fileignore;
{ Tests for the fileignore library: the gitignore pattern language plus the
  layering that makes another ignore file (`.agentignore`) meaningful. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  fileignore.rules;

type
  TFileIgnoreTest = class(TTestCase)
  published
    { The language, unchanged from git's. }
    procedure TestBasenameMatchesAtAnyDepth;
    procedure TestAnchoredPattern;
    procedure TestDirectoryOnly;
    procedure TestNegationReincludes;
    procedure TestStarDoesNotCrossSlash;
    procedure TestDoubleStarCrossesSlash;
    procedure TestParentExclusionCannotBeReincluded;
    procedure TestGitDirectorySkippedWhenAsked;
    { Layering: the point of generalising beyond git. }
    procedure TestAgentIgnoreIsItsOwnLayer;
    procedure TestHigherLayerWins;
    procedure TestNegationWithinAHigherLayerWins;
    procedure TestDecidingRuleNamesTheSource;
    procedure TestCountInReportsEachLayer;
  end;

implementation

const
  GitName = '.gitignore';
  AgentName = '.agentignore';

function Rules(AIgnoreGit: Boolean = False): TIgnoreRules;
begin
  Result := TIgnoreRules.Create(AIgnoreGit);
end;

{ --- the language ------------------------------------------------------ }

procedure TFileIgnoreTest.TestBasenameMatchesAtAnyDepth;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    R.AddFile('', '*.log');
    AssertTrue('root', R.IsIgnored('a.log', False));
    AssertTrue('nested', R.IsIgnored('x/y/a.log', False));
    AssertFalse('other', R.IsIgnored('a.txt', False));
  finally
    R.Free;
  end;
end;

procedure TFileIgnoreTest.TestAnchoredPattern;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    R.AddFile('', '/build');
    AssertTrue('at the root', R.IsIgnored('build', True));
    AssertFalse('not nested', R.IsIgnored('x/build', True));
  finally
    R.Free;
  end;
end;

procedure TFileIgnoreTest.TestDirectoryOnly;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    R.AddFile('', 'cache/');
    AssertTrue('a directory', R.IsIgnored('cache', True));
    AssertFalse('not a file of that name', R.IsIgnored('cache', False));
  finally
    R.Free;
  end;
end;

procedure TFileIgnoreTest.TestNegationReincludes;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    R.AddFile('', '*.log'#10'!keep.log');
    AssertTrue('ignored', R.IsIgnored('a.log', False));
    AssertFalse('re-included', R.IsIgnored('keep.log', False));
  finally
    R.Free;
  end;
end;

procedure TFileIgnoreTest.TestStarDoesNotCrossSlash;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    R.AddFile('', 'src/*.pas');
    AssertTrue('direct child', R.IsIgnored('src/a.pas', False));
    AssertFalse('deeper is not matched', R.IsIgnored('src/x/a.pas', False));
  finally
    R.Free;
  end;
end;

procedure TFileIgnoreTest.TestDoubleStarCrossesSlash;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    R.AddFile('', 'src/**/*.pas');
    AssertTrue('any depth', R.IsIgnored('src/x/y/a.pas', False));
  finally
    R.Free;
  end;
end;

procedure TFileIgnoreTest.TestParentExclusionCannotBeReincluded;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    R.AddFile('', 'build/'#10'!build/keep.txt');
    { git's rule: a file inside an excluded directory cannot be re-included. }
    AssertTrue('the parent is excluded', R.IsIgnored('build/keep.txt', False));
  finally
    R.Free;
  end;
end;

procedure TFileIgnoreTest.TestGitDirectorySkippedWhenAsked;
var
  R: TIgnoreRules;
begin
  R := Rules(True);
  try
    AssertTrue('.git is skipped', R.IsIgnored('.git/config', False));
  finally
    R.Free;
  end;
  R := Rules(False);
  try
    AssertFalse('.git is only a rule when asked', R.IsIgnored('.git/config', False));
  finally
    R.Free;
  end;
end;

{ --- layering ---------------------------------------------------------- }

procedure TFileIgnoreTest.TestAgentIgnoreIsItsOwnLayer;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    R.AddFile('', 'scratch/', ilAgent, AgentName);
    AssertEquals('one rule in the agent layer', 1, R.CountIn(ilAgent));
    AssertEquals('none in git', 0, R.CountIn(ilGit));
    AssertTrue('and it applies', R.IsIgnored('scratch', True));
  finally
    R.Free;
  end;
end;

procedure TFileIgnoreTest.TestHigherLayerWins;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    { git ignores *.log; the agent file re-includes one of them. The agent layer
      must win, so the file is NOT ignored. }
    R.AddFile('', '*.log', ilGit, GitName);
    R.AddFile('', '!important.log', ilAgent, AgentName);
    AssertTrue('an ordinary log is still ignored', R.IsIgnored('a.log', False));
    AssertFalse('the agent re-included this one',
      R.IsIgnored('important.log', False));
  finally
    R.Free;
  end;
end;

procedure TFileIgnoreTest.TestNegationWithinAHigherLayerWins;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    { A later rule in the SAME layer overrides an earlier one (git's rule), and
      the operator layer outranks both. }
    R.AddFile('', '*.tmp', ilGit, GitName);
    R.AddFile('', '!keep.tmp', ilOperator, 'operator.ignore');
    AssertFalse('the operator re-included it',
      R.IsIgnored('keep.tmp', False));
    AssertTrue('and the rest are still ignored', R.IsIgnored('a.tmp', False));
  finally
    R.Free;
  end;
end;

procedure TFileIgnoreTest.TestDecidingRuleNamesTheSource;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    R.AddFile('', 'scratch/', ilAgent, AgentName);
    AssertTrue(R.IsIgnored('scratch', True));
    AssertEquals('names the file and the pattern',
      AgentName + ': scratch', R.DecidingRule);
  finally
    R.Free;
  end;
end;

procedure TFileIgnoreTest.TestCountInReportsEachLayer;
var
  R: TIgnoreRules;
begin
  R := Rules;
  try
    R.AddFile('', 'a'#10'b', ilGit, GitName);
    R.AddFile('', 'c', ilAgent, AgentName);
    AssertEquals('git', 2, R.CountIn(ilGit));
    AssertEquals('agent', 1, R.CountIn(ilAgent));
    AssertEquals('operator', 0, R.CountIn(ilOperator));
    AssertEquals('total', 3, R.RuleCount);
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TFileIgnoreTest);
end.
