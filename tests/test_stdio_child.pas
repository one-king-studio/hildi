unit test_stdio_child;
{ fpcunit tests for hildi.stdio.child. POSIX-only: the fakes are
  /bin/sh scripts. Every child is closed in the test; the leak gate (make
  test-leak) is what proves teardown is clean. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildi.stdio.child, hildi.process;

type
  TStdioChildTest = class(TTestCase)
  published
    procedure TestSpawnEchoRoundTrip;
    procedure TestReadTimeout;
    procedure TestEofOnExit;
    procedure TestBrokenPipeOnWrite;
    procedure TestTooLongLine;
    procedure TestStderrDoesNotBlockStdout;
    procedure TestCloseKillsNonCooperativeChild;
    procedure TestCloseIsIdempotent;
    procedure TestNormalizeExitMapping;
  end;

implementation

{$ifdef unix}
function ShConfig(const AScript: string): TStdioChildConfig;
begin
  Result := Default(TStdioChildConfig);
  Result.Executable := '/bin/sh';
  Result.Args := ['-c', AScript];
end;

procedure TStdioChildTest.TestSpawnEchoRoundTrip;
var
  C: TStdioChild;
  Err, Line: string;
  Reason: TStdioReadResult;
begin
  C := TStdioChild.Create(ShConfig(
    'while IFS= read -r line; do printf "%s\n" "$line"; done'));
  try
    AssertTrue('started', C.Start(Err));
    AssertTrue('write', C.WriteLine('hello world', Err));
    AssertTrue('read ok', C.ReadLine(Line, 2000, Reason));
    AssertEquals('echoed', 'hello world', Line);
  finally
    C.Free;
  end;
end;

procedure TStdioChildTest.TestReadTimeout;
var
  C: TStdioChild;
  Err, Line: string;
  Reason: TStdioReadResult;
  Start: Int64;
begin
  C := TStdioChild.Create(ShConfig('sleep 30'));
  try
    AssertTrue('started', C.Start(Err));
    Start := GetTickCount64;
    AssertFalse('timed out', C.ReadLine(Line, 300, Reason));
    AssertEquals('reason', Ord(srTimeout), Ord(Reason));
    AssertTrue('waited ~300ms', GetTickCount64 - Start >= 250);
  finally
    C.Free;
  end;
end;

procedure TStdioChildTest.TestEofOnExit;
var
  C: TStdioChild;
  Err, Line: string;
  Reason: TStdioReadResult;
begin
  C := TStdioChild.Create(ShConfig('exit 3'));
  try
    AssertTrue('started', C.Start(Err));
    AssertFalse('eof', C.ReadLine(Line, 2000, Reason));
    AssertEquals('reason', Ord(srEof), Ord(Reason));
    AssertEquals('exit code normalized', 3, C.ExitCode);
  finally
    C.Free;
  end;
end;

procedure TStdioChildTest.TestBrokenPipeOnWrite;
var
  C: TStdioChild;
  Err, Line: string;
  Reason: TStdioReadResult;
begin
  C := TStdioChild.Create(ShConfig('exit 0'));
  try
    AssertTrue('started', C.Start(Err));
    { Observe the child's exit first (its stdout closes), then the write fails. }
    AssertFalse('eof', C.ReadLine(Line, 2000, Reason));
    AssertEquals('reason', Ord(srEof), Ord(Reason));
    AssertFalse('write fails on closed pipe', C.WriteLine('x', Err));
    AssertTrue('error text', Err <> '');
  finally
    C.Free;
  end;
end;

procedure TStdioChildTest.TestTooLongLine;
var
  C: TStdioChild;
  Cfg: TStdioChildConfig;
  Err, Line: string;
  Reason: TStdioReadResult;
begin
  Cfg := ShConfig('head -c 200 /dev/zero | tr "\000" "a"; printf "\n"');
  Cfg.MaxLineBytes := 32;
  C := TStdioChild.Create(Cfg);
  try
    AssertTrue('started', C.Start(Err));
    AssertFalse('too long', C.ReadLine(Line, 2000, Reason));
    AssertEquals('reason', Ord(srTooLong), Ord(Reason));
  finally
    C.Free;
  end;
end;

procedure TStdioChildTest.TestStderrDoesNotBlockStdout;
var
  C: TStdioChild;
  Err, Line: string;
  Reason: TStdioReadResult;
begin
  C := TStdioChild.Create(ShConfig('printf "warning\n" >&2; printf "out\n"'));
  try
    AssertTrue('started', C.Start(Err));
    AssertTrue('read stdout', C.ReadLine(Line, 2000, Reason));
    AssertEquals('stdout line', 'out', Line);
    AssertTrue('stderr captured', Pos('warning', C.StderrTail) > 0);
  finally
    C.Free;
  end;
end;

procedure TStdioChildTest.TestCloseKillsNonCooperativeChild;
var
  C: TStdioChild;
  Err: string;
  Start: Int64;
begin
  C := TStdioChild.Create(ShConfig('trap "" TERM; sleep 30'));
  try
    AssertTrue('started', C.Start(Err));
    Sleep(100);
    Start := GetTickCount64;
    C.Close;
    { Close must return within the grace (2s) + the SIGTERM grace (0.5s) plus a
      generous margin, even though the child ignores SIGTERM. }
    AssertTrue('closed promptly', GetTickCount64 - Start < 4000);
    AssertFalse('no longer alive', C.Alive);
  finally
    C.Free;
  end;
end;

procedure TStdioChildTest.TestCloseIsIdempotent;
var
  C: TStdioChild;
  Err: string;
begin
  C := TStdioChild.Create(ShConfig('sleep 30'));
  try
    AssertTrue('started', C.Start(Err));
    C.Close;
    C.Close;   { must not raise }
    AssertFalse('not alive', C.Alive);
  finally
    C.Free;
  end;
end;

{ The three TProcess.ExitStatus encodings all normalize to one convention. }
procedure TStdioChildTest.TestNormalizeExitMapping;
begin
  AssertEquals('plain exit code', 1, NormalizeExit(1));
  AssertEquals('zero', 0, NormalizeExit(0));
  AssertEquals('negative signal (-9)', 137, NormalizeExit(-9));
  AssertEquals('raw wait(): exit 3', 3, NormalizeExit(3 shl 8));
  AssertEquals('raw wait(): signalled 11', 139, NormalizeExit((11 shl 8) or 11));
end;
{$else}
{ Non-Unix: the fakes do not exist. Register nothing. }
{$endif}

initialization
  {$ifdef unix}
  RegisterTest(TStdioChildTest);
  {$endif}
end.
