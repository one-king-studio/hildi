unit test_shell_interpreter;
{ Tests for the shell interpreter against an in-memory filesystem: expansion,
  redirection, pipelines, control flow, functions, builtins, the gate, and the
  limits. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Generics.Collections, fpcunit, testregistry,
  shell.types, shell.ast, shell.fs, shell.registry, shell.interpreter,
  test_shell_memfs;

type
  TShellInterpreterTest = class(TTestCase)
  private
    FMem: TMemoryFs;
    FReg: TShellRegistry;
    FShell: TShell;
    FEnv: TShellEnv;
    FOut: string;
    FErr: string;
    FGateOpen: Boolean;
    FLastCall: TShellCall;
    function RunSrc(const ASource: string): Integer;
    function StatusOf(const ASource: string): Integer;
    function Echo(const ACall: TShellCall): TShellResult;
    function Cat(const ACall: TShellCall): TShellResult;
    function Boom(const ACall: TShellCall): TShellResult;
    function Yes(const ACall: TShellCall): TShellResult;
    function No(const ACall: TShellCall): TShellResult;
    function Gate(const ACall: TShellCall): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestEcho;
    procedure TestPipeline;
    procedure TestPipelineStagesDoNotLeakState;
    procedure TestAndOr;
    procedure TestAssignmentAndExpansion;
    procedure TestExportAndUnset;
    procedure TestForLoop;
    procedure TestForGlob;
    procedure TestIfAndElse;
    procedure TestWhileAndUntil;
    procedure TestCase;
    procedure TestFunction;
    procedure TestFunctionReturn;
    procedure TestRedirectWriteAndAppend;
    procedure TestRedirectRead;
    procedure TestStderrRedirect;
    procedure TestStderrToStdout;
    procedure TestHereDoc;
    procedure TestHereDocQuoted;
    procedure TestCdAndSubshell;
    procedure TestGateDenied;
    procedure TestCommandNotFound;
    procedure TestStatusPropagation;
    procedure TestCommandLimit;
    procedure TestOutputCapDoesNotSplitUtf8;
    procedure TestParseError;
  end;

implementation

procedure TShellInterpreterTest.SetUp;
begin
  inherited SetUp;
  FMem := TMemoryFs.Create;
  FMem.AddDir('/work');
  FMem.AddDir('/work/sub');
  FReg := TShellRegistry.Create;
  FReg.Register('echo', Echo);
  FReg.Register('cat', Cat);
  FReg.Register('boom', Boom);
  FReg.Register('yes', Yes);
  FReg.Register('no', No);
  FEnv := TShellEnv.Create;
  FEnv.SetValue('HOME', '/work');
  FGateOpen := True;
  FShell := TShell.Create(FReg, FMem, '/work', Gate, DefaultShellLimits, FEnv);
  FOut := '';
  FErr := '';
  FLastCall := Default(TShellCall);
end;

procedure TShellInterpreterTest.TearDown;
begin
  FShell.Free;
  FReg.Free;
  FEnv.Free;
  FMem := nil;
  inherited TearDown;
end;

function TShellInterpreterTest.RunSrc(const ASource: string): Integer;
begin
  Result := FShell.RunSource(ASource, FOut, FErr);
end;

function TShellInterpreterTest.StatusOf(const ASource: string): Integer;
begin
  Result := RunSrc(ASource);
end;

function TShellInterpreterTest.Echo(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  S: string;
begin
  S := '';
  for I := 0 to High(ACall.Args) do
  begin
    if S <> '' then
      S := S + ' ';
    S := S + ACall.Args[I];
  end;
  Result := ShellResultOk(S + #10);
end;

function TShellInterpreterTest.Cat(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  Data, E: string;
begin
  FLastCall := ACall;
  if Length(ACall.Args) = 0 then
    Exit(ShellResultOk(ACall.Stdin));
  Result := ShellResultOk('');
  for I := 0 to High(ACall.Args) do
  begin
    if not FMem.ReadFile(FMem.Resolve(ACall.Cwd, ACall.Args[I]), Data, E) then
      Exit(ShellResultErr('cat: ' + ACall.Args[I] + ': ' + E + #10, 1));
    Result.Stdout := Result.Stdout + Data;
  end;
end;

function TShellInterpreterTest.Boom(const ACall: TShellCall): TShellResult;
begin
  Result := ShellResultErr('boom' + #10, 7);
end;

function TShellInterpreterTest.Yes(const ACall: TShellCall): TShellResult;
begin
  Result := ShellResultOk('');
end;

function TShellInterpreterTest.No(const ACall: TShellCall): TShellResult;
begin
  Result := ShellResultErr('', 1);
end;

function TShellInterpreterTest.Gate(const ACall: TShellCall): Boolean;
begin
  FLastCall := ACall;
  Result := FGateOpen;
end;

procedure TShellInterpreterTest.TestEcho;
begin
  AssertEquals('status', 0, RunSrc('echo hello world'));
  AssertEquals('output', 'hello world' + #10, FOut);
end;

procedure TShellInterpreterTest.TestPipeline;
begin
  AssertEquals('status', 0, RunSrc('echo a b | cat'));
  AssertEquals('piped stdin', 'a b' + #10, FOut);
end;

procedure TShellInterpreterTest.TestPipelineStagesDoNotLeakState;
begin
  RunSrc('cd sub | cat; pwd');
  AssertEquals('cwd unchanged', '/work' + #10, FOut);
  FOut := '';
  RunSrc('X=1 | cat; echo [$X]');
  AssertEquals('variable unchanged', '[]' + #10, FOut);
end;

procedure TShellInterpreterTest.TestAndOr;
begin
  AssertEquals('and', 0, RunSrc('yes && echo second'));
  AssertEquals('and output', 'second' + #10, FOut);
  FOut := '';
  AssertEquals('or recovers', 0, RunSrc('boom || echo recovered'));
  AssertEquals('or output', 'recovered' + #10, FOut);
  AssertEquals('stderr kept', 'boom' + #10, FErr);
  FOut := '';
  AssertEquals('and does not run after failure', 7, RunSrc('boom && echo no'));
  AssertEquals('no output', '', FOut);
end;

procedure TShellInterpreterTest.TestAssignmentAndExpansion;
begin
  AssertEquals('status', 0, RunSrc('X=1; echo $X'));
  AssertEquals('expanded', '1' + #10, FOut);
  FOut := '';
  AssertEquals('quoted', 0, RunSrc('Y="a b"; echo "$Y"'));
  AssertEquals('quoted output', 'a b' + #10, FOut);
end;

procedure TShellInterpreterTest.TestExportAndUnset;
begin
  AssertEquals('status', 0, RunSrc('export X=2; echo $X; unset X; echo [$X]'));
  AssertEquals('output', '2' + #10 + '[]' + #10, FOut);
end;

procedure TShellInterpreterTest.TestForLoop;
begin
  AssertEquals('status', 0, RunSrc('for f in a b c; do echo $f; done'));
  AssertEquals('output', 'a' + #10 + 'b' + #10 + 'c' + #10, FOut);
end;

procedure TShellInterpreterTest.TestForGlob;
begin
  FMem.AddFile('/work/b.txt', 'b');
  FMem.AddFile('/work/a.txt', 'a');
  FMem.AddFile('/work/c.md', 'c');
  AssertEquals('status', 0, RunSrc('for f in *.txt; do echo $f; done'));
  AssertEquals('sorted, matched', 'a.txt' + #10 + 'b.txt' + #10, FOut);
end;

procedure TShellInterpreterTest.TestIfAndElse;
begin
  AssertEquals('then', 0, RunSrc('if yes; then echo y; else echo n; fi'));
  AssertEquals('then output', 'y' + #10, FOut);
  FOut := '';
  AssertEquals('else', 0, RunSrc('if no; then echo y; else echo n; fi'));
  AssertEquals('else output', 'n' + #10, FOut);
  FOut := '';
  AssertEquals('elif', 0, RunSrc('if no; then echo a; elif yes; then echo b; fi'));
  AssertEquals('elif output', 'b' + #10, FOut);
end;

procedure TShellInterpreterTest.TestWhileAndUntil;
begin
  AssertEquals('while false', 0, RunSrc('while no; do echo never; done; echo done'));
  AssertEquals('while output', 'done' + #10, FOut);
  FOut := '';
  AssertEquals('until true', 0, RunSrc('until yes; do echo never; done; echo done'));
  AssertEquals('until output', 'done' + #10, FOut);
end;

procedure TShellInterpreterTest.TestCase;
begin
  FMem.AddFile('/work/x.txt', '');
  AssertEquals('status', 0, RunSrc('case x.txt in *.md) echo md;; *.txt) echo txt;; esac'));
  AssertEquals('matched txt', 'txt' + #10, FOut);
  FOut := '';
  AssertEquals('no match', 0, RunSrc('case nope in *.md) echo md;; esac'));
  AssertEquals('no output', '', FOut);
end;

procedure TShellInterpreterTest.TestFunction;
begin
  AssertEquals('status', 0, RunSrc('greet() { echo hi $1; }; greet there'));
  AssertEquals('output', 'hi there' + #10, FOut);
end;

procedure TShellInterpreterTest.TestFunctionReturn;
begin
  AssertEquals('return status', 3,
    RunSrc('f() { return 3; }; f; '));
  AssertEquals('status visible', 0, RunSrc('f() { return 3; }; f || echo failed'));
  AssertEquals('recovered', 'failed' + #10, FOut);
end;

procedure TShellInterpreterTest.TestRedirectWriteAndAppend;
begin
  AssertEquals('status', 0, RunSrc('echo one > out.txt'));
  AssertEquals('written', 'one' + #10, FMem.FileText('/work/out.txt'));
  RunSrc('echo two >> out.txt');
  AssertEquals('appended', 'one' + #10 + 'two' + #10, FMem.FileText('/work/out.txt'));
  RunSrc('echo replaced > out.txt');
  AssertEquals('truncated', 'replaced' + #10, FMem.FileText('/work/out.txt'));
end;

procedure TShellInterpreterTest.TestRedirectRead;
begin
  FMem.AddFile('/work/in.txt', 'from file' + #10);
  AssertEquals('status', 0, RunSrc('cat < in.txt'));
  AssertEquals('stdin from file', 'from file' + #10, FOut);
end;

procedure TShellInterpreterTest.TestStderrRedirect;
begin
  AssertEquals('status', 7, RunSrc('boom 2> err.txt'));
  AssertEquals('stderr file', 'boom' + #10, FMem.FileText('/work/err.txt'));
  AssertEquals('stderr not mixed', '', FOut);
end;

procedure TShellInterpreterTest.TestStderrToStdout;
begin
  AssertEquals('status', 7, RunSrc('boom 2>&1'));
  AssertEquals('merged into stdout', 'boom' + #10, FOut);
end;

procedure TShellInterpreterTest.TestHereDoc;
var
  Src: string;
begin
  RunSrc('X=there');
  Src := 'cat <<EOF' + #10 + 'hi $X' + #10 + 'EOF' + #10;
  AssertEquals('status', 0, RunSrc(Src));
  AssertEquals('expanded body', 'hi there' + #10, FOut);
end;

procedure TShellInterpreterTest.TestHereDocQuoted;
var
  Src: string;
begin
  RunSrc('X=there');
  Src := 'cat <<''EOF''' + #10 + 'hi $X' + #10 + 'EOF' + #10;
  AssertEquals('status', 0, RunSrc(Src));
  AssertEquals('literal body', 'hi $X' + #10, FOut);
end;

procedure TShellInterpreterTest.TestCdAndSubshell;
begin
  AssertEquals('pwd', 0, RunSrc('pwd'));
  AssertEquals('cwd', '/work' + #10, FOut);
  FOut := '';
  RunSrc('cd sub; pwd');
  AssertEquals('changed', '/work/sub' + #10, FOut);
  FOut := '';
  AssertEquals('subshell status', 0, RunSrc('( cd /; pwd )'));
  AssertEquals('subshell cwd', '/' + #10, FOut);
  AssertEquals('outer unchanged', '/work/sub', FShell.Cwd);
end;

procedure TShellInterpreterTest.TestGateDenied;
begin
  FGateOpen := False;
  AssertEquals('denied status', 126, RunSrc('echo hidden'));
  AssertEquals('denied message', 'echo: denied' + #10, FErr);
  AssertEquals('no output', '', FOut);
end;

procedure TShellInterpreterTest.TestCommandNotFound;
begin
  AssertEquals('status', 127, RunSrc('nosuchcommand'));
  AssertEquals('message', 'nosuchcommand: command not found' + #10, FErr);
end;

procedure TShellInterpreterTest.TestStatusPropagation;
begin
  AssertEquals('status', 7, RunSrc('boom'));
  AssertEquals('status of the last command', 0, RunSrc('boom; yes'));
end;

procedure TShellInterpreterTest.TestCommandLimit;
var
  Env: TShellEnv;
  Reg: TShellRegistry;
  Sh: TShell;
  OutText, ErrText: string;
  Status, I: Integer;
  Src: string;
  Limits: TShellLimits;
begin
  Env := TShellEnv.Create;
  Reg := TShellRegistry.Create;
  Reg.Register('yes', Yes);
  Src := '';
  for I := 1 to 20 do
    Src := Src + 'yes; ';
  Limits := DefaultShellLimits;
  Limits.MaxCommands := 5;
  Sh := TShell.Create(Reg, FMem, '/work', nil, Limits, Env);
  try
    Status := Sh.RunSource(Src, OutText, ErrText);
    AssertEquals('limit status', 2, Status);
    AssertTrue('says which limit', Pos('command limit', ErrText) > 0);
  finally
    Sh.Free;
    Reg.Free;
    Env.Free;
  end;
end;

procedure TShellInterpreterTest.TestOutputCapDoesNotSplitUtf8;
var
  Shell: TShell;
  Limits: TShellLimits;
  OutText, ErrText: string;
begin
  { 'echo <éé>' writes four bytes plus a newline; a three-byte cap lands inside
    the second character. The cut must back up to the boundary. }
  Limits := DefaultShellLimits;
  Limits.MaxOutputBytes := 3;
  Shell := TShell.Create(FReg, FMem, '/work', Gate, Limits, FEnv);
  try
    Shell.RunSource('echo ' + #$C3#$A9#$C3#$A9, OutText, ErrText);
    AssertEquals('cut on a boundary',
      #$C3#$A9 + #10 + '[output truncated]' + #10, OutText);
  finally
    Shell.Free;
  end;
end;

procedure TShellInterpreterTest.TestParseError;
begin
  AssertEquals('parse status', 2, RunSrc('echo $(date)'));
  AssertTrue('names the construct', Pos('command substitution', FErr) > 0);
  AssertEquals('nothing ran', '', FOut);
end;

initialization
  RegisterTest(TShellInterpreterTest);
end.
