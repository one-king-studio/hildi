unit test_command_policy;
{ fpcunit tests for hildi.command.policy: the pure POSIX command
  parser. Classification now lives in the Tool Approvals feature. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, hildi.command.policy;

type
  TCommandPolicyTest = class(TTestCase)
  private
    function Parse(const ACommand: string): TCommandPlan;
  published
    procedure TestSingleCommandParsed;
    procedure TestSingleQuotesAndDoubleQuotesStripped;
    procedure TestEscapedOperatorIsNotOperator;
    procedure TestSemicolonSplitsSegments;
    procedure TestAndOrPipeSplitSegments;
    procedure TestBackgroundOperator;
    procedure TestLeadingAssignmentSkipped;
    procedure TestExecutableWithPathKeepsToken;
    procedure TestRedirectionExtractedFromArgv;
    procedure TestRedirectTargetIsPath;
    procedure TestUnbalancedQuoteSetsParseError;
    procedure TestUnresolvedVariablePathIsUnresolved;
    procedure TestHomeAndAbsoluteAndRelativePathKinds;
    procedure TestSegmentTextJoinsExecutableAndArgs;
    procedure TestStructuralWordsAreRecognized;
    procedure TestSegmentCommandStripsStructure;
    procedure TestSegmentCommandHeadersNameNoCommand;
    procedure TestRedirectionWithoutTargetSetsParseError;
    { A here-document is a redirect whose target is a delimiter and whose body is
      DATA. The body must never reach the segment list: an ask set built from it
      would carry commands the operator never wrote on the command line. }
    procedure TestHereDocIsARedirectWithADelimiterTarget;
    procedure TestHereDocBodyIsNotReadAsCommands;
    procedure TestHereDocStripKeepsTheDash;
    procedure TestUnterminatedHereDocSetsParseError;
  end;

implementation

function TCommandPolicyTest.Parse(const ACommand: string): TCommandPlan;
begin
  Result := ParseCommand(ACommand, ssPosix);
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

procedure TCommandPolicyTest.TestExecutableWithPathKeepsToken;
var
  P: TCommandPlan;
begin
  P := Parse('/usr/bin/rm file');
  AssertEquals('token kept', '/usr/bin/rm', P.Segments[0].Executable);
  AssertEquals('arg', 'file', P.Segments[0].Arguments[0]);
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
  AssertTrue('is redirect', P.Segments[0].Paths[0].IsRedirect);
end;

procedure TCommandPolicyTest.TestUnbalancedQuoteSetsParseError;
var
  P: TCommandPlan;
begin
  P := Parse('echo "unterminated');
  AssertTrue('parse error', P.ParseError <> '');
end;

procedure TCommandPolicyTest.TestUnresolvedVariablePathIsUnresolved;
var
  P: TCommandPlan;
begin
  P := Parse('cat $HOME/x');
  AssertEquals('one path', 1, Length(P.Segments[0].Paths));
  AssertEquals('unresolved', Ord(pkUnresolved), Ord(P.Segments[0].Paths[0].Kind));
  P := Parse('cat `pwd`/x');
  AssertEquals('backtick unresolved', Ord(pkUnresolved),
    Ord(P.Segments[0].Paths[0].Kind));
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

procedure TCommandPolicyTest.TestSegmentTextJoinsExecutableAndArgs;
var
  P: TCommandPlan;
begin
  P := Parse('cat /etc/os-release && uname -a');
  AssertEquals('first segment text', 'cat /etc/os-release', P.Segments[0].Text);
  AssertEquals('second segment text', 'uname -a', P.Segments[1].Text);
end;

procedure TCommandPolicyTest.TestStructuralWordsAreRecognized;
begin
  AssertTrue('if', IsShellKeyword('if'));
  AssertTrue('fi', IsShellKeyword('fi'));
  AssertTrue('done', IsShellKeyword('done'));
  AssertTrue('brace', IsShellKeyword('{'));
  AssertTrue('bang', IsShellKeyword('!'));
  AssertFalse('a program', IsShellKeyword('cat'));
  AssertFalse('a path', IsShellKeyword('./if'));
end;

procedure TCommandPolicyTest.TestSegmentCommandStripsStructure;
var
  Plan: TCommandPlan;
  Name: string;
  Args: TCommandArgArray;
begin
  Plan := Parse('if [ -f a ]; then cat a; fi');
  AssertTrue('condition', SegmentCommand(Plan.Segments[0], Name, Args));
  AssertEquals('condition name', '[', Name);
  AssertEquals('condition arg', '-f', Args[0]);
  AssertTrue('body', SegmentCommand(Plan.Segments[1], Name, Args));
  AssertEquals('body name', 'cat', Name);
  AssertEquals('body arg', 'a', Args[0]);
  AssertFalse('the closer names no command',
    SegmentCommand(Plan.Segments[2], Name, Args));
end;

procedure TCommandPolicyTest.TestSegmentCommandHeadersNameNoCommand;
var
  Plan: TCommandPlan;
  Name: string;
  Args: TCommandArgArray;
begin
  Plan := Parse('for x in a b; do echo x; done');
  AssertFalse('for header', SegmentCommand(Plan.Segments[0], Name, Args));
  AssertTrue('do echo', SegmentCommand(Plan.Segments[1], Name, Args));
  AssertEquals('body', 'echo', Name);
  AssertFalse('done', SegmentCommand(Plan.Segments[2], Name, Args));
  Plan := Parse('case $x in');
  AssertFalse('case header', SegmentCommand(Plan.Segments[0], Name, Args));
end;

procedure TCommandPolicyTest.TestRedirectionWithoutTargetSetsParseError;
var
  P: TCommandPlan;
begin
  P := Parse('echo hi >');
  AssertTrue('parse error', P.ParseError <> '');
end;

procedure TCommandPolicyTest.TestHereDocIsARedirectWithADelimiterTarget;
var
  P: TCommandPlan;
begin
  { `cat <<EOF` is one command with one redirect whose target is the delimiter.
    Before this, the tokenizer read `<<` as two separate '<' operators, so the
    first had no target and the whole line failed to parse - the command never
    ran, and no ask was ever built. }
  P := Parse('cat <<EOF' + #10 + 'hello' + #10 + 'EOF');
  AssertEquals('parses', '', P.ParseError);
  AssertEquals('one segment', 1, Length(P.Segments));
  AssertEquals('the executable', 'cat', P.Segments[0].Executable);
  AssertEquals('no arguments: the delimiter is not argv', 0,
    Length(P.Segments[0].Arguments));
  AssertEquals('one redirect', 1, Length(P.Segments[0].Redirects));
  AssertEquals('operator', '<<', P.Segments[0].Redirects[0].Operator);
  AssertEquals('target is the delimiter', 'EOF',
    P.Segments[0].Redirects[0].Target);
end;

procedure TCommandPolicyTest.TestHereDocBodyIsNotReadAsCommands;
var
  P: TCommandPlan;
begin
  { The body is DATA. A body line that looks like a command must not become a
    segment, or the approval dialog would ask for permission to run something the
    operator never wrote as a command. }
  P := Parse('cat <<EOF' + #10 + 'rm -rf /' + #10 + 'echo pwned' + #10 + 'EOF');
  AssertEquals('parses', '', P.ParseError);
  AssertEquals('still one segment', 1, Length(P.Segments));
  AssertEquals('and it is cat', 'cat', P.Segments[0].Executable);
end;

procedure TCommandPolicyTest.TestHereDocStripKeepsTheDash;
var
  P: TCommandPlan;
begin
  { `<<-` strips leading tabs; the operator stays distinguishable so a display
    can show what was written. }
  P := Parse('cat <<-EOF' + #10 + #9 + 'body' + #10 + #9 + 'EOF');
  AssertEquals('parses', '', P.ParseError);
  AssertEquals('one redirect', 1, Length(P.Segments[0].Redirects));
  AssertEquals('operator keeps the dash', '<<-',
    P.Segments[0].Redirects[0].Operator);
  AssertEquals('target', 'EOF', P.Segments[0].Redirects[0].Target);
end;

procedure TCommandPolicyTest.TestUnterminatedHereDocSetsParseError;
var
  P: TCommandPlan;
begin
  { Fail closed: a heredoc with no closing delimiter is ambiguous, and an ask set
    built from a guess would be worse than a refusal. }
  P := Parse('cat <<EOF' + #10 + 'no closing delimiter');
  AssertTrue('parse error names it',
    Pos('here-document', LowerCase(P.ParseError)) > 0);
end;

initialization
  RegisterTest(TCommandPolicyTest);
end.
