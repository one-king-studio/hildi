unit test_command_policy;
{ fpcunit tests for hildegard.helper.command.policy: the pure POSIX parser and
  allow/ask/deny classifier. No execution, no I/O. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, hildegard.helper.command.policy;

type
  TCommandPolicyTest = class(TTestCase)
  private
    function Policy(const AAllow, ADeny, ARoots: array of string;
      AInterpreters: Boolean): TCommandPolicy;
    function Parse(const ACommand: string): TCommandPlan;
    function Decide(const ACommand: string;
      const APolicy: TCommandPolicy): TPolicyDecision;
  published
    procedure TestEmptyCommandAsks;
    procedure TestSingleCommandParsed;
    procedure TestSingleQuotesAndDoubleQuotesStripped;
    procedure TestEscapedOperatorIsNotOperator;
    procedure TestSemicolonSplitsSegments;
    procedure TestAndOrPipeSplitSegments;
    procedure TestBackgroundOperator;
    procedure TestLeadingAssignmentSkipped;
    procedure TestExecutableWithPathKeepsTokenAndBasename;
    procedure TestRedirectionExtractedFromArgv;
    procedure TestRedirectTargetIsPath;
    procedure TestUnbalancedQuoteAsks;
    procedure TestUnresolvedVariablePathIsUnresolved;
    procedure TestHomeAndAbsoluteAndRelativePathKinds;
    procedure TestDenyBeatsAllow;
    procedure TestAllowWhenAllSegmentsAllowed;
    procedure TestAskWhenAnySegmentUnmatched;
    procedure TestDenyPatternMatchesBasename;
    procedure TestGlobPatternMatches;
    procedure TestInterpreterAsksUnlessAcknowledged;
    procedure TestInterpreterAllowedWhenAcknowledgedAndAllowed;
    procedure TestPathOutsideRootsAsks;
    procedure TestPathInsideRootsAllowed;
    procedure TestRelativeDotDotEscapeAsks;
    procedure TestClassifyCompoundCommandWithMixedSegments;
    procedure TestClassifySegmentsReturnsOnePerSegment;
    procedure TestSegmentTextJoinsExecutableAndArgs;
    procedure TestExactArgPatternAllowsOnlyThatArg;
    procedure TestWildcardArgPatternAllowsAnyArgs;
    procedure TestFullArgAllowBypassesArgPathCheck;
    procedure TestRedirectPathStillCheckedWithFullArgAllow;
    procedure TestDenyArgPatternMatches;
  end;

implementation

function TCommandPolicyTest.Policy(const AAllow, ADeny,
  ARoots: array of string; AInterpreters: Boolean): TCommandPolicy;
var
  I: Integer;
begin
  Result := Default(TCommandPolicy);
  SetLength(Result.Allow, Length(AAllow));
  for I := 0 to High(AAllow) do
    Result.Allow[I] := AAllow[I];
  SetLength(Result.Deny, Length(ADeny));
  for I := 0 to High(ADeny) do
    Result.Deny[I] := ADeny[I];
  SetLength(Result.AllowedRoots, Length(ARoots));
  for I := 0 to High(ARoots) do
    Result.AllowedRoots[I] := ARoots[I];
  Result.AllowInterpreters := AInterpreters;
end;

function TCommandPolicyTest.Parse(const ACommand: string): TCommandPlan;
begin
  Result := ParseCommand(ACommand, ssPosix);
end;

function TCommandPolicyTest.Decide(const ACommand: string;
  const APolicy: TCommandPolicy): TPolicyDecision;
begin
  Result := ClassifyCommand(Parse(ACommand), APolicy);
end;

procedure TCommandPolicyTest.TestEmptyCommandAsks;
var
  D: TPolicyDecision;
begin
  D := Decide('', DefaultCommandPolicy);
  AssertEquals('ask', Ord(cdAsk), Ord(D.Decision));
  AssertTrue('reason', D.Reason <> '');
end;

procedure TCommandPolicyTest.TestSingleCommandParsed;
var
  P: TCommandPlan;
begin
  P := Parse('ls -la /tmp');
  AssertEquals('one segment', 1, Length(P.Segments));
  AssertEquals('no parse error', '', P.ParseError);
  AssertEquals('exec', Ord(coExec), Ord(P.Segments[0].Op));
  AssertEquals('executable', 'ls', P.Segments[0].Executable);
  AssertEquals('arg count', 2, Length(P.Segments[0].Arguments));
  AssertEquals('arg 0', '-la', P.Segments[0].Arguments[0]);
  AssertEquals('arg 1', '/tmp', P.Segments[0].Arguments[1]);
end;

procedure TCommandPolicyTest.TestSingleQuotesAndDoubleQuotesStripped;
var
  P: TCommandPlan;
begin
  P := Parse('echo "hello world" ''single''');
  AssertEquals('executable', 'echo', P.Segments[0].Executable);
  AssertEquals('arg count', 2, Length(P.Segments[0].Arguments));
  AssertEquals('double', 'hello world', P.Segments[0].Arguments[0]);
  AssertEquals('single', 'single', P.Segments[0].Arguments[1]);
end;

procedure TCommandPolicyTest.TestEscapedOperatorIsNotOperator;
var
  P: TCommandPlan;
begin
  P := Parse('echo a\;b');
  AssertEquals('one segment', 1, Length(P.Segments));
  AssertEquals('arg', 'a;b', P.Segments[0].Arguments[0]);
end;

procedure TCommandPolicyTest.TestSemicolonSplitsSegments;
var
  P: TCommandPlan;
begin
  P := Parse('ls; pwd');
  AssertEquals('two segments', 2, Length(P.Segments));
  AssertEquals('first', 'ls', P.Segments[0].Executable);
  AssertEquals('second', 'pwd', P.Segments[1].Executable);
  AssertEquals('second op', Ord(coSeq), Ord(P.Segments[1].Op));
end;

procedure TCommandPolicyTest.TestAndOrPipeSplitSegments;
var
  P: TCommandPlan;
begin
  P := Parse('a && b || c | d');
  AssertEquals('four segments', 4, Length(P.Segments));
  AssertEquals('op1', Ord(coAnd), Ord(P.Segments[1].Op));
  AssertEquals('op2', Ord(coOr), Ord(P.Segments[2].Op));
  AssertEquals('op3', Ord(coPipe), Ord(P.Segments[3].Op));
end;

procedure TCommandPolicyTest.TestBackgroundOperator;
var
  P: TCommandPlan;
begin
  P := Parse('a & b');
  AssertEquals('two segments', 2, Length(P.Segments));
  AssertEquals('background op', Ord(coBackground), Ord(P.Segments[1].Op));
  AssertEquals('second exec', 'b', P.Segments[1].Executable);
end;

procedure TCommandPolicyTest.TestLeadingAssignmentSkipped;
var
  P: TCommandPlan;
begin
  P := Parse('FOO=bar ls');
  AssertEquals('executable', 'ls', P.Segments[0].Executable);
  AssertEquals('no args', 0, Length(P.Segments[0].Arguments));
end;

procedure TCommandPolicyTest.TestExecutableWithPathKeepsTokenAndBasename;
var
  P: TCommandPlan;
  D: TPolicyDecision;
begin
  P := Parse('/usr/bin/rm file');
  AssertEquals('token kept', '/usr/bin/rm', P.Segments[0].Executable);
  D := ClassifyCommand(P, Policy(['rm'], [], [], False));
  AssertEquals('basename allow matched', Ord(cdAllow), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestRedirectionExtractedFromArgv;
var
  P: TCommandPlan;
begin
  P := Parse('echo hi > out.txt');
  AssertEquals('one segment', 1, Length(P.Segments));
  AssertEquals('arg count', 1, Length(P.Segments[0].Arguments));
  AssertEquals('only hi', 'hi', P.Segments[0].Arguments[0]);
  AssertEquals('one redirect', 1, Length(P.Segments[0].Redirects));
  AssertEquals('redirect op', '>', P.Segments[0].Redirects[0].Operator);
  AssertEquals('redirect target', 'out.txt', P.Segments[0].Redirects[0].Target);
end;

procedure TCommandPolicyTest.TestRedirectTargetIsPath;
var
  P: TCommandPlan;
begin
  P := Parse('echo hi > out.txt');
  AssertEquals('one path', 1, Length(P.Segments[0].Paths));
  AssertEquals('path text', 'out.txt', P.Segments[0].Paths[0].Text);
end;

procedure TCommandPolicyTest.TestUnbalancedQuoteAsks;
var
  P: TCommandPlan;
  D: TPolicyDecision;
begin
  P := Parse('echo "unterminated');
  AssertTrue('parse error', P.ParseError <> '');
  D := ClassifyCommand(P, DefaultCommandPolicy);
  AssertEquals('ask', Ord(cdAsk), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestUnresolvedVariablePathIsUnresolved;
var
  P: TCommandPlan;
  I: Integer;
begin
  P := Parse('cat $HOME/x');
  AssertEquals('one path', 1, Length(P.Segments[0].Paths));
  AssertEquals('unresolved', Ord(pkUnresolved), Ord(P.Segments[0].Paths[0].Kind));
  P := Parse('cat `pwd`/x');
  AssertEquals('backtick unresolved', Ord(pkUnresolved),
    Ord(P.Segments[0].Paths[0].Kind));
  P := Parse('cat $(pwd)/x');
  AssertTrue('substitution has a path', Length(P.Segments[0].Paths) > 0);
  for I := 0 to High(P.Segments[0].Paths) do
    if Pos('$', P.Segments[0].Paths[I].Text) > 0 then
      AssertEquals('substitution unresolved', Ord(pkUnresolved),
        Ord(P.Segments[0].Paths[I].Kind));
end;

procedure TCommandPolicyTest.TestHomeAndAbsoluteAndRelativePathKinds;
var
  P: TCommandPlan;
begin
  P := Parse('cat ~/notes');
  AssertEquals('home', Ord(pkHome), Ord(P.Segments[0].Paths[0].Kind));
  P := Parse('cat /etc/hosts');
  AssertEquals('absolute', Ord(pkAbsolute), Ord(P.Segments[0].Paths[0].Kind));
  P := Parse('cat sub/file');
  AssertEquals('relative', Ord(pkRelative), Ord(P.Segments[0].Paths[0].Kind));
end;

procedure TCommandPolicyTest.TestDenyBeatsAllow;
var
  D: TPolicyDecision;
begin
  D := Decide('rm file', Policy(['rm', 'ls'], ['rm'], [], False));
  AssertEquals('deny', Ord(cdDeny), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestAllowWhenAllSegmentsAllowed;
var
  D: TPolicyDecision;
begin
  D := Decide('ls && pwd', Policy(['ls', 'pwd'], [], [], False));
  AssertEquals('allow', Ord(cdAllow), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestAskWhenAnySegmentUnmatched;
var
  D: TPolicyDecision;
begin
  D := Decide('ls && curl example.com', Policy(['ls'], [], [], False));
  AssertEquals('ask', Ord(cdAsk), Ord(D.Decision));
  AssertEquals('second segment', 1, D.SegmentIndex);
end;

procedure TCommandPolicyTest.TestDenyPatternMatchesBasename;
var
  D: TPolicyDecision;
begin
  D := Decide('/usr/bin/rm file', Policy([], ['rm'], [], False));
  AssertEquals('deny', Ord(cdDeny), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestGlobPatternMatches;
var
  D: TPolicyDecision;
begin
  D := Decide('git status', Policy(['git*'], [], [], False));
  AssertEquals('allow', Ord(cdAllow), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestInterpreterAsksUnlessAcknowledged;
var
  D: TPolicyDecision;
begin
  D := Decide('bash -c whoami', Policy(['bash'], [], [], False));
  AssertEquals('ask', Ord(cdAsk), Ord(D.Decision));
  AssertTrue('mentions interpreter', Pos('interpreter', D.Reason) > 0);
end;

procedure TCommandPolicyTest.TestInterpreterAllowedWhenAcknowledgedAndAllowed;
var
  D: TPolicyDecision;
begin
  D := Decide('bash -c whoami', Policy(['bash'], [], [], True));
  AssertEquals('allow', Ord(cdAllow), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestPathOutsideRootsAsks;
var
  D: TPolicyDecision;
begin
  D := Decide('cat /etc/passwd', Policy(['cat'], [], ['/srv/data'], False));
  AssertEquals('ask', Ord(cdAsk), Ord(D.Decision));
  AssertTrue('mentions path', Pos('/etc/passwd', D.Reason) > 0);
end;

procedure TCommandPolicyTest.TestPathInsideRootsAllowed;
var
  D: TPolicyDecision;
begin
  D := Decide('cat /srv/data/x', Policy(['cat'], [], ['/srv/data'], False));
  AssertEquals('allow', Ord(cdAllow), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestRelativeDotDotEscapeAsks;
var
  D: TPolicyDecision;
begin
  D := Decide('cat ../secret', Policy(['cat'], [], [], False));
  AssertEquals('ask', Ord(cdAsk), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestClassifyCompoundCommandWithMixedSegments;
var
  D: TPolicyDecision;
begin
  D := Decide('ls /srv/data && cat /etc/passwd',
    Policy(['ls', 'cat'], [], ['/srv/data'], False));
  AssertEquals('ask', Ord(cdAsk), Ord(D.Decision));
  AssertTrue('names offending path', Pos('/etc/passwd', D.Reason) > 0);
end;

procedure TCommandPolicyTest.TestClassifySegmentsReturnsOnePerSegment;
var
  P: TCommandPlan;
  D: TSegmentDecisionArray;
begin
  P := Parse('cat /etc/os-release && uname -a');
  D := ClassifySegments(P, DefaultCommandPolicy);
  AssertEquals('two decisions', 2, Length(D));
  AssertEquals('index 0', 0, D[0].SegmentIndex);
  AssertEquals('index 1', 1, D[1].SegmentIndex);
  AssertEquals('both ask', Ord(cdAsk), Ord(D[0].Decision));
  AssertEquals('both ask 2', Ord(cdAsk), Ord(D[1].Decision));
end;

procedure TCommandPolicyTest.TestSegmentTextJoinsExecutableAndArgs;
var
  P: TCommandPlan;
begin
  P := Parse('cat /etc/os-release && uname -a');
  AssertEquals('first segment text', 'cat /etc/os-release', P.Segments[0].Text);
  AssertEquals('second segment text', 'uname -a', P.Segments[1].Text);
end;

procedure TCommandPolicyTest.TestExactArgPatternAllowsOnlyThatArg;
var
  D: TPolicyDecision;
begin
  D := Decide('cat /etc/os-release',
    Policy(['cat /etc/os-release'], [], [], False));
  AssertEquals('exact use allowed', Ord(cdAllow), Ord(D.Decision));
  D := Decide('cat /etc/passwd',
    Policy(['cat /etc/os-release'], [], [], False));
  AssertEquals('other arg asks', Ord(cdAsk), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestWildcardArgPatternAllowsAnyArgs;
var
  D: TPolicyDecision;
begin
  D := Decide('cat /etc/passwd', Policy(['cat *'], [], [], False));
  AssertEquals('wildcard allows any arg', Ord(cdAllow), Ord(D.Decision));
  D := Decide('uname -r', Policy(['uname *'], [], [], False));
  AssertEquals('wildcard uname', Ord(cdAllow), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestFullArgAllowBypassesArgPathCheck;
var
  D: TPolicyDecision;
begin
  D := Decide('cat /etc/os-release',
    Policy(['cat /etc/os-release'], [], [], False));
  AssertEquals('allowed despite no roots', Ord(cdAllow), Ord(D.Decision));
end;

procedure TCommandPolicyTest.TestRedirectPathStillCheckedWithFullArgAllow;
var
  D: TPolicyDecision;
begin
  D := Decide('echo hi > /etc/x', Policy(['echo *'], [], [], False));
  AssertEquals('redirect still asks', Ord(cdAsk), Ord(D.Decision));
  AssertTrue('names redirect path', Pos('/etc/x', D.Reason) > 0);
end;

procedure TCommandPolicyTest.TestDenyArgPatternMatches;
var
  P: TCommandPlan;
  D: TSegmentDecision;
begin
  P := Parse('rm -rf /');
  D := ClassifySegment(P, 0, Policy([], ['rm -rf *'], [], False));
  AssertEquals('deny', Ord(cdDeny), Ord(D.Decision));
end;

initialization
  RegisterTest(TCommandPolicyTest);
end.
