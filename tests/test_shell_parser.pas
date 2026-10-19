unit test_shell_parser;
{ Tests for the standalone shell library: the lexer, the word parser, and the
  recursive-descent parser (the v1 subset and the subset gate). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  shell.types, shell.ast, shell.lexer, shell.words, shell.parser;

type
  TShellParserTest = class(TTestCase)
  private
    function ParseOk(const ASrc: string): TScript;
    function ParseErr(const ASrc: string): TShellParseError;
    function FirstCommand(AScript: TScript): TCommand;
    function WordAt(const AWord: TWord; AIndex: Integer): TWordPart;
  published
    { Lexer }
    procedure TestLexerTokens;
    procedure TestLexerComment;
    procedure TestLexerLineContinuation;
    procedure TestLexerFdRedirect;
    { Words }
    procedure TestWordQuotesAndVariables;
    procedure TestWordGlob;
    procedure TestWordTilde;
    { Parser }
    procedure TestSimpleCommand;
    procedure TestAssignmentPrefix;
    procedure TestPipeline;
    procedure TestPrecedence;
    procedure TestIf;
    procedure TestFor;
    procedure TestWhileUntil;
    procedure TestCase;
    procedure TestGroups;
    procedure TestFunction;
    procedure TestHereDoc;
    procedure TestHereDocQuoted;
    procedure TestHereDocStrip;
    { The subset gate }
    procedure TestCommandSubstitutionRejected;
    procedure TestBraceOperatorRejected;
    procedure TestBacktickRejected;
    procedure TestProcessSubstitutionRejected;
    procedure TestBraceExpansionRejected;
    procedure TestAnsiCQuotingRejected;
    procedure TestUnterminatedQuote;
  end;

implementation

function TShellParserTest.ParseOk(const ASrc: string): TScript;
var
  E: TShellParseError;
  Ok: Boolean;
begin
  E := Default(TShellParseError);
  Ok := ParseShellScript(ASrc, Result, E);
  AssertTrue('parse failed: ' + E.Message + ' (' + IntToStr(E.Line) + ':' +
    IntToStr(E.Column) + ') in: ' + ASrc, Ok);
end;

function TShellParserTest.ParseErr(const ASrc: string): TShellParseError;
var
  S: TScript;
  Ok: Boolean;
begin
  S := nil;
  Ok := ParseShellScript(ASrc, S, Result);
  if Ok then
    S.Free;
  AssertFalse('expected a parse error for: ' + ASrc, Ok);
end;

function TShellParserTest.FirstCommand(AScript: TScript): TCommand;
begin
  Result := AScript.Root.Items[0].Pipelines[0].Commands[0];
end;

function TShellParserTest.WordAt(const AWord: TWord; AIndex: Integer): TWordPart;
begin
  Result := AWord.Parts[AIndex];
end;

procedure TShellParserTest.TestLexerTokens;
var
  L: TLexer;
  T: TToken;
begin
  L := TLexer.Create('a | b > c');
  try
    T := L.Next;
    AssertEquals('word a', Ord(tkWord), Ord(T.Kind));
    AssertEquals('a', 'a', T.Text);
    T := L.Next;
    AssertEquals('pipe', Ord(opPipe), Ord(T.Op));
    T := L.Next;
    AssertEquals('word b', 'b', T.Text);
    T := L.Next;
    AssertEquals('gt', Ord(opGreat), Ord(T.Op));
    T := L.Next;
    AssertEquals('word c', 'c', T.Text);
    T := L.Next;
    AssertEquals('eof', Ord(tkEOF), Ord(T.Kind));
  finally
    L.Free;
  end;
end;

procedure TShellParserTest.TestLexerComment;
var
  L: TLexer;
  T: TToken;
begin
  L := TLexer.Create('a # ignored' + #10 + 'b');
  try
    T := L.Next;
    AssertEquals('a', 'a', T.Text);
    T := L.Next;
    AssertEquals('newline', Ord(tkNewline), Ord(T.Kind));
    T := L.Next;
    AssertEquals('b', 'b', T.Text);
  finally
    L.Free;
  end;
end;

procedure TShellParserTest.TestLexerLineContinuation;
var
  L: TLexer;
  T: TToken;
begin
  L := TLexer.Create('a \' + #10 + 'b');
  try
    T := L.Next;
    AssertEquals('a', 'a', T.Text);
    T := L.Next;
    AssertEquals('b joined', 'b', T.Text);
  finally
    L.Free;
  end;
end;

procedure TShellParserTest.TestLexerFdRedirect;
var
  L: TLexer;
  T: TToken;
begin
  L := TLexer.Create('2>&1');
  try
    T := L.Next;   // NOTE: the lexer folds the fd into the op token
    AssertEquals('op', Ord(tkOp), Ord(T.Kind));
    AssertEquals('gt-amp', Ord(opGreatAnd), Ord(T.Op));
    AssertEquals('fd 2', 2, T.FD);
    T := L.Next;
    AssertEquals('target 1', '1', T.Text);
  finally
    L.Free;
  end;
end;

procedure TShellParserTest.TestWordQuotesAndVariables;
var
  Parts: TWordPartArray;
  E: TShellParseError;
begin
  AssertTrue('parse', ParseWordParts('a"b $V"c', 1, 1, 1, Parts, E));
  AssertEquals('parts', 4, Length(Parts));
  AssertEquals('literal a', Ord(wpLiteral), Ord(Parts[0].Kind));
  AssertEquals('a', 'a', Parts[0].Text);
  AssertEquals('literal b ', Ord(wpLiteral), Ord(Parts[1].Kind));
  AssertEquals('b ', 'b ', Parts[1].Text);
  AssertTrue('quoted', Parts[1].Quoted);
  AssertEquals('variable', Ord(wpVariable), Ord(Parts[2].Kind));
  AssertEquals('V', 'V', Parts[2].Text);
  AssertTrue('variable quoted', Parts[2].Quoted);
  AssertEquals('literal c', 'c', Parts[3].Text);
end;

procedure TShellParserTest.TestWordGlob;
var
  Parts: TWordPartArray;
  E: TShellParseError;
begin
  AssertTrue('parse', ParseWordParts('*.pas', 1, 1, 1, Parts, E));
  AssertEquals('parts', 2, Length(Parts));
  AssertEquals('glob', Ord(wpGlob), Ord(Parts[0].Kind));
  AssertEquals('*', '*', Parts[0].Text);
  AssertEquals('suffix', '.pas', Parts[1].Text);
end;

procedure TShellParserTest.TestWordTilde;
var
  Parts: TWordPartArray;
  E: TShellParseError;
begin
  AssertTrue('parse', ParseWordParts('~/x', 1, 1, 1, Parts, E));
  AssertEquals('tilde', Ord(wpTilde), Ord(Parts[0].Kind));
  AssertEquals('/x', '/x', Parts[1].Text);
end;

procedure TShellParserTest.TestSimpleCommand;
var
  S: TScript;
  C: TCommand;
begin
  S := ParseOk('echo hello world');
  try
    C := FirstCommand(S);
    AssertEquals('kind', Ord(ckSimple), Ord(C.Kind));
    AssertEquals('words', 3, Length(C.Words));
    AssertEquals('arg 1', 'hello', C.Words[1].Parts[0].Text);
    AssertEquals('arg 2', 'world', C.Words[2].Parts[0].Text);
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestAssignmentPrefix;
var
  S: TScript;
  C: TCommand;
begin
  S := ParseOk('FOO=bar echo $FOO');
  try
    C := FirstCommand(S);
    AssertEquals('assignments', 1, Length(C.Assignments));
    AssertEquals('name', 'FOO', C.Assignments[0].Name);
    AssertEquals('value', 'bar', C.Assignments[0].Value.Parts[0].Text);
    AssertEquals('words', 2, Length(C.Words));
    AssertEquals('variable arg', Ord(wpVariable), Ord(C.Words[1].Parts[0].Kind));
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestPipeline;
var
  S: TScript;
begin
  S := ParseOk('a | b | c');
  try
    AssertEquals('three stages', 3, Length(S.Root.Items[0].Pipelines[0].Commands));
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestPrecedence;
var
  S: TScript;
  P: TAndOr;
begin
  { a && b | c ; d  ==  (a && (b|c)) ; d }
  S := ParseOk('a && b | c ; d');
  try
    AssertEquals('two statement items', 2, Length(S.Root.Items));
    P := S.Root.Items[0];
    AssertEquals('two and-or pipelines', 2, Length(P.Pipelines));
    AssertEquals('and op', Ord(aoAnd), Ord(P.Ops[0]));
    AssertEquals('b|c has two commands', 2, Length(P.Pipelines[1].Commands));
    AssertEquals('second item is d', 'd', S.Root.Items[1].Pipelines[0]
      .Commands[0].Words[0].Parts[0].Text);
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestIf;
var
  S: TScript;
  C: TCommand;
begin
  S := ParseOk('if true; then echo yes; else echo no; fi');
  try
    C := FirstCommand(S);
    AssertEquals('if', Ord(ckIf), Ord(C.Kind));
    AssertEquals('one clause', 1, Length(C.Clauses));
    AssertTrue('has else', C.ElseBody <> nil);
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestFor;
var
  S: TScript;
  C: TCommand;
begin
  S := ParseOk('for f in a b; do echo $f; done');
  try
    C := FirstCommand(S);
    AssertEquals('for', Ord(ckFor), Ord(C.Kind));
    AssertEquals('var', 'f', C.ForVar);
    AssertEquals('items', 2, Length(C.ForItems));
    AssertTrue('body', C.LoopBody <> nil);
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestWhileUntil;
var
  S: TScript;
begin
  S := ParseOk('while true; do echo x; done');
  try
    AssertEquals('while', Ord(ckWhile), Ord(FirstCommand(S).Kind));
  finally
    S.Free;
  end;
  S := ParseOk('until false; do echo x; done');
  try
    AssertEquals('until', Ord(ckUntil), Ord(FirstCommand(S).Kind));
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestCase;
var
  S: TScript;
  C: TCommand;
begin
  S := ParseOk('case $x in a|b) echo y;; *) echo z;; esac');
  try
    C := FirstCommand(S);
    AssertEquals('case', Ord(ckCase), Ord(C.Kind));
    AssertEquals('two items', 2, Length(C.CaseItems));
    AssertEquals('two patterns', 2, Length(C.CaseItems[0].Patterns));
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestGroups;
var
  S: TScript;
begin
  S := ParseOk('{ echo x; }');
  try
    AssertEquals('group', Ord(ckGroup), Ord(FirstCommand(S).Kind));
  finally
    S.Free;
  end;
  S := ParseOk('( echo x )');
  try
    AssertEquals('subshell', Ord(ckSubshell), Ord(FirstCommand(S).Kind));
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestFunction;
var
  S: TScript;
  C: TCommand;
begin
  S := ParseOk('f() { echo hi; }');
  try
    C := FirstCommand(S);
    AssertEquals('function', Ord(ckFunction), Ord(C.Kind));
    AssertEquals('name', 'f', C.FuncName);
    AssertTrue('body', C.FuncBody <> nil);
  finally
    S.Free;
  end;
  S := ParseOk('function g { echo hi; }');
  try
    AssertEquals('function keyword', 'g', FirstCommand(S).FuncName);
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestHereDoc;
var
  S: TScript;
  C: TCommand;
  R: TRedirect;
begin
  S := ParseOk('cat <<EOF' + #10 + 'hi' + #10 + 'EOF' + #10);
  try
    C := FirstCommand(S);
    AssertEquals('one redirect', 1, Length(C.Redirects));
    R := C.Redirects[0];
    AssertEquals('heredoc', Ord(roHeredoc), Ord(R.Op));
    AssertEquals('body', 'hi' + #10, R.Body);
    AssertTrue('expands', R.ExpandBody);
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestHereDocQuoted;
var
  S: TScript;
  R: TRedirect;
begin
  S := ParseOk('cat <<''EOF''' + #10 + '$x' + #10 + 'EOF' + #10);
  try
    R := FirstCommand(S).Redirects[0];
    AssertEquals('body', '$x' + #10, R.Body);
    AssertFalse('quoted: no expansion', R.ExpandBody);
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestHereDocStrip;
var
  S: TScript;
  R: TRedirect;
begin
  S := ParseOk('cat <<-EOF' + #10 + #9 + 'hi' + #10 + #9 + 'EOF' + #10);
  try
    R := FirstCommand(S).Redirects[0];
    AssertEquals('strip op', Ord(roHeredocStrip), Ord(R.Op));
    AssertEquals('tabs stripped', 'hi' + #10, R.Body);
  finally
    S.Free;
  end;
end;

procedure TShellParserTest.TestCommandSubstitutionRejected;
begin
  AssertEquals('names the construct', 'command substitution is not supported',
    ParseErr('echo $(date)').Message);
end;

procedure TShellParserTest.TestBraceOperatorRejected;
begin
  AssertEquals('names the construct', 'parameter-expansion operators are not supported',
    ParseErr('echo ${x:-y}').Message);
end;

procedure TShellParserTest.TestBacktickRejected;
begin
  AssertTrue('backticks are v1-unsupported',
    Pos('backquote', ParseErr('echo `date`').Message) > 0);
end;

procedure TShellParserTest.TestProcessSubstitutionRejected;
begin
  AssertTrue('process substitution names the construct',
    Pos('process substitution', ParseErr('cat <(ls)').Message) > 0);
end;

procedure TShellParserTest.TestBraceExpansionRejected;
begin
  AssertEquals('names the construct', 'brace expansion is not supported',
    ParseErr('echo {a,b}').Message);
end;

procedure TShellParserTest.TestAnsiCQuotingRejected;
begin
  AssertEquals('names the construct', 'ANSI-C quoting is not supported',
    ParseErr('echo $''a\nb''').Message);
end;

procedure TShellParserTest.TestUnterminatedQuote;
begin
  AssertTrue('unterminated double quote',
    Pos('unterminated double quote', ParseErr('echo "x').Message) > 0);
end;

initialization
  RegisterTest(TShellParserTest);
end.
