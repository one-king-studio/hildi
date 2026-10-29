unit test_hildi;
{ fpcunit tests for the hildi units. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpcunit, testregistry,
  hildi.process, hildi.pool;

type
  { Thread-safe sink shared by all subagent callbacks. Because TCommandRunner
    invokes its callback from the runner thread, every mutation of the shared
    strings/counters below is guarded by FLock. }
  TOutputSink = class
  private
    FLock: TCriticalSection;
    FStdout: string;
    FFinished: Integer;
    FLastExit: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnOutput(const AId: string; AKind: TOutputKind;
      const AText: string; AExitCode: Integer);
    function Stdout: string;
    function FinishedCount: Integer;
    function LastExitCode: Integer;
  end;

  TCommandRunnerTest = class(TTestCase)
  private
    FSink: TOutputSink;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestCapturesStdout;
    procedure TestReportsExitCode;
    procedure TestStderrIsMerged;
    procedure TestTimeoutKillsProcess;
    procedure TestShellIsConfigurable;
  end;

  TAgentPoolTest = class(TTestCase)
  private
    FSink: TOutputSink;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestAllJobsComplete;
    procedure TestConcurrencyIsRespected;
  end;

implementation

{ TOutputSink }

constructor TOutputSink.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TOutputSink.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TOutputSink.OnOutput(const AId: string; AKind: TOutputKind;
  const AText: string; AExitCode: Integer);
begin
  FLock.Acquire;
  try
    case AKind of
      okStdout:
        FStdout := FStdout + AText;
      okFinished:
        begin
          Inc(FFinished);
          FLastExit := AExitCode;
        end;
      okStarted, okStderr: ;   // not needed by these tests
    end;
  finally
    FLock.Release;
  end;
end;

function TOutputSink.Stdout: string;
begin
  FLock.Acquire;
  try
    Result := FStdout;
  finally
    FLock.Release;
  end;
end;

function TOutputSink.FinishedCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FFinished;
  finally
    FLock.Release;
  end;
end;

function TOutputSink.LastExitCode: Integer;
begin
  FLock.Acquire;
  try
    Result := FLastExit;
  finally
    FLock.Release;
  end;
end;

{ Helpers }

function RunSync(const ACommand: string; ATimeoutMs: QWord;
  ASink: TOutputSink): TCommandRunner;
begin
  Result := TCommandRunner.Create('t', ACommand, ATimeoutMs, '', ASink.OnOutput);
  Result.Start;
  Result.WaitFor;
end;

{ TCommandRunnerTest }

procedure TCommandRunnerTest.SetUp;
begin
  FSink := TOutputSink.Create;
end;

procedure TCommandRunnerTest.TearDown;
begin
  FSink.Free;
end;

procedure TCommandRunnerTest.TestCapturesStdout;
var
  R: TCommandRunner;
begin
  R := RunSync('printf "hello world"', 0, FSink);
  try
    AssertEquals('exit code', 0, R.ExitCode);
    AssertTrue('stdout contains greeting', Pos('hello world', FSink.Stdout) > 0);
  finally
    R.Free;
  end;
end;

procedure TCommandRunnerTest.TestReportsExitCode;
var
  R: TCommandRunner;
begin
  R := RunSync('exit 3', 0, FSink);
  try
    AssertEquals('exit code', 3, R.ExitCode);
  finally
    R.Free;
  end;
end;

procedure TCommandRunnerTest.TestStderrIsMerged;
var
  R: TCommandRunner;
begin
  R := RunSync('echo oops >&2', 0, FSink);
  try
    AssertTrue('stderr merged into stream', Pos('oops', FSink.Stdout) > 0);
  finally
    R.Free;
  end;
end;

procedure TCommandRunnerTest.TestTimeoutKillsProcess;
var
  R: TCommandRunner;
  Started: QWord;
begin
  Started := GetTickCount64;
  R := RunSync('sleep 10', 250, FSink);
  try
    AssertTrue('timed-out flag set', R.TimedOut);
    AssertEquals('timeout exit sentinel', 124, R.ExitCode);
    AssertTrue('did not wait the full sleep', GetTickCount64 - Started < 5000);
  finally
    R.Free;
  end;
end;

procedure TCommandRunnerTest.TestShellIsConfigurable;
var
  R: TCommandRunner;
begin
  { printf '%s' marker only works if both the executable and the switch are
    honoured; a hard-coded `bash -c` would fail. }
  R := TCommandRunner.Create('t', 'marker', 0, '', FSink.OnOutput,
    '/usr/bin/printf', '%s');
  try
    R.Start;
    R.WaitFor;
    AssertTrue('custom shell and switch used', Pos('marker', FSink.Stdout) > 0);
  finally
    R.Free;
  end;
end;

{ TAgentPoolTest }

procedure TAgentPoolTest.SetUp;
begin
  FSink := TOutputSink.Create;
end;

procedure TAgentPoolTest.TearDown;
begin
  FSink.Free;
end;

procedure TAgentPoolTest.TestAllJobsComplete;
var
  Pool: TAgentPool;
begin
  Pool := TAgentPool.Create(2, FSink.OnOutput);
  try
    Pool.Submit('a', 'echo aaa');
    Pool.Submit('b', 'echo bbb');
    Pool.Submit('c', 'echo ccc');
    Pool.WaitAll;
  finally
    Pool.Free;
  end;
  AssertEquals('all three reported finished', 3, FSink.FinishedCount);
  AssertTrue('got aaa', Pos('aaa', FSink.Stdout) > 0);
  AssertTrue('got bbb', Pos('bbb', FSink.Stdout) > 0);
  AssertTrue('got ccc', Pos('ccc', FSink.Stdout) > 0);
end;

procedure TAgentPoolTest.TestConcurrencyIsRespected;
var
  Pool: TAgentPool;
  Started, Elapsed: QWord;
begin
  { Three 300ms jobs on two workers must run in two waves (>= 600ms), never
    all at once (~300ms). The 550ms floor leaves scheduling margin. }
  Started := GetTickCount64;
  Pool := TAgentPool.Create(2, FSink.OnOutput);
  try
    Pool.Submit('a', 'sleep 0.3');
    Pool.Submit('b', 'sleep 0.3');
    Pool.Submit('c', 'sleep 0.3');
    Pool.WaitAll;
  finally
    Pool.Free;
  end;
  Elapsed := GetTickCount64 - Started;
  AssertEquals('all finished', 3, FSink.FinishedCount);
  AssertTrue('ran in at least two waves', Elapsed >= 550);
end;

initialization
  RegisterTest(TCommandRunnerTest);
  RegisterTest(TAgentPoolTest);
end.
