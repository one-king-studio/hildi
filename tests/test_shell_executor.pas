unit test_shell_executor;
{ The builtin executor: tier first, process fallback second, reasons passed
  through, and the observer fed. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testutils, testregistry,
  hildi.agent, hildi.approval,
  hildi.command.tool,
  hildi.shell.commands, hildi.shell.tier,
  hildi.shell.executor, hildi.shell.fs,
  hildi.workspace.changes;

type
  TFakeFallback = class(TNoRefCountObject, ICommandExecutor)
  public
    Calls: Integer;
    LastReason: string;
    LastCommand: string;
    LastMode: TCommandMode;
    function OwnsApproval(const ACommand: string; AMode: TCommandMode;
      out AWhy: string): Boolean;
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord; AObserver: TToolObserver;
      const AReason: string; AMode: TCommandMode; AChanges: TFileChangeSet;
      out AExecution: TCommandExecution): Boolean;
  end;

  TRecordObserver = class(TToolObserver)
  public
    Text: string;
    Completed: Boolean;
    procedure Next(const AText: string); override;
    procedure Complete; override;
  end;

  TAllowApproval = class(TInterfacedObject, IApprovalService)
  public
    Allow: Boolean;
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

  TShellExecutorTest = class(TTestCase)
  private
    FRoot: string;
    FFs: TWorkspaceShellFs;
    FFallback: TFakeFallback;
    FApproval: TAllowApproval;
    FExecutor: ICommandExecutor;
    function P(const AName: string): string;
    function RunExec(const ACommand: string; out AExecution: TCommandExecution;
      AObserver: TToolObserver = nil;
      AMode: TCommandMode = cmAuto): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestUsesTierWhenSupported;
    procedure TestFallsBackOnUnknownCommand;
    procedure TestFallsBackOnParseError;
    procedure TestFallbackReceivesTheReason;
    procedure TestObserverReceivesTierOutput;
    procedure TestRecordsFileChanges;
    procedure TestOwnsApprovalOnlyForTierScripts;
    procedure TestModeBashUsesTheFallback;
    procedure TestModeBuiltinRunsSupported;
    procedure TestModeBuiltinRefusesUnsupported;
    procedure TestDenialIsAResultNotAFallback;
  end;

implementation

function TFakeFallback.OwnsApproval(const ACommand: string;
  AMode: TCommandMode; out AWhy: string): Boolean;
begin
  AWhy := '';
  Result := False;
end;

function TFakeFallback.Execute(const AProfile: TShellProfile;
  const ACommand, AWorkDir: string; ATimeoutMs: QWord;
  AObserver: TToolObserver; const AReason: string; AMode: TCommandMode;
  AChanges: TFileChangeSet; out AExecution: TCommandExecution): Boolean;
begin
  Inc(Calls);
  LastReason := AReason;
  LastCommand := ACommand;
  LastMode := AMode;
  AExecution := Default(TCommandExecution);
  AExecution.Output := 'fallback output';
  AExecution.ExitCode := 0;
  AExecution.Started := True;
  Result := True;
end;

procedure TRecordObserver.Next(const AText: string);
begin
  Text := Text + AText;
end;

procedure TRecordObserver.Complete;
begin
  Completed := True;
end;

function TAllowApproval.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
begin
  AResult := Default(TApprovalBatchResult);
  AResult.Allowed := Allow;
  AResult.Denied := not Allow;
  AResult.Reason := 'test';
  Result := True;
end;

function TShellExecutorTest.P(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot) + AName;
end;

procedure TShellExecutorTest.SetUp;
var
  Cfg: TBuiltinShellConfig;
  E: string;
begin
  inherited SetUp;
  FRoot := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'shellexec-' +
    IntToStr(Random(100000000));
  ForceDirectories(FRoot);
  FFs := TWorkspaceShellFs.Create(FRoot);
  FFs.WriteFile(P('a.txt'), 'alpha' + #10, False, E);
  FFallback := TFakeFallback.Create;
  FApproval := TAllowApproval.Create;
  FApproval.Allow := True;
  Cfg := Default(TBuiltinShellConfig);
  Cfg.Root := FRoot;
  Cfg.MaxOutputBytes := 32768;
  FExecutor := TBuiltinCommandExecutor.Create(Cfg, FApproval, FFallback, nil);
end;

procedure TShellExecutorTest.TearDown;
var
  Tmp: TWorkspaceShellFs;
  E: string;
begin
  FExecutor := nil;
  FFallback.Free;
  FApproval := nil;
  FFs.Free;
  if DirectoryExists(FRoot) then
  begin
    Tmp := TWorkspaceShellFs.Create(FRoot);
    try
      Tmp.Delete(FRoot, True, E);
    finally
      Tmp.Free;
    end;
  end;
  inherited TearDown;
end;

function TShellExecutorTest.RunExec(const ACommand: string;
  out AExecution: TCommandExecution; AObserver: TToolObserver;
  AMode: TCommandMode): Boolean;
begin
  Result := FExecutor.Execute(DefaultShellProfile, ACommand, FRoot, 5000,
    AObserver, 'the reason', AMode, nil, AExecution);
end;

procedure TShellExecutorTest.TestUsesTierWhenSupported;
var
  Exec: TCommandExecution;
begin
  AssertTrue('ran', RunExec('echo hi > out.txt; cat out.txt', Exec));
  AssertEquals('fallback untouched', 0, FFallback.Calls);
  AssertEquals('output', 'hi' + #10, Exec.Output);
  AssertEquals('status', 0, Exec.ExitCode);
  AssertTrue('started', Exec.Started);
  AssertTrue('file written', FileExists(P('out.txt')));
end;

procedure TShellExecutorTest.TestFallsBackOnUnknownCommand;
var
  Exec: TCommandExecution;
begin
  AssertTrue('ran', RunExec('git status', Exec));
  AssertEquals('fallback used', 1, FFallback.Calls);
  AssertEquals('command passed unchanged', 'git status', FFallback.LastCommand);
  AssertEquals('fallback output', 'fallback output', Exec.Output);
end;

procedure TShellExecutorTest.TestFallsBackOnParseError;
var
  Exec: TCommandExecution;
begin
  AssertTrue('ran', RunExec('echo $(date)', Exec));
  AssertEquals('fallback used', 1, FFallback.Calls);
end;

procedure TShellExecutorTest.TestFallbackReceivesTheReason;
var
  Exec: TCommandExecution;
begin
  RunExec('git status', Exec);
  AssertEquals('reason', 'the reason', FFallback.LastReason);
end;

procedure TShellExecutorTest.TestRecordsFileChanges;
var
  Exec: TCommandExecution;
  Changes: TFileChangeSet;
  E: string;
  I: Integer;

  function Has(const APath: string; AKind: TFileChangeKind): Boolean;
  var
    K: Integer;
  begin
    Result := False;
    for K := 0 to Changes.Count - 1 do
      if (Changes[K].Path = APath) and (Changes[K].Kind = AKind) then
        Exit(True);
  end;

begin
  Changes := TFileChangeSet.Create;
  try
    AssertTrue('ran', FExecutor.Execute(DefaultShellProfile,
      'echo one > n.txt; echo two >> n.txt; sed -i s/one/ONE/ n.txt; ' +
      'cp n.txt copy.txt; mv copy.txt moved.txt; rm n.txt; mkdir newdir',
      FRoot, 5000, nil, 'the reason', cmAuto, Changes, Exec));
    AssertTrue('multi-change call: ' + Changes.Summary, Changes.Count >= 5);
    AssertTrue('created n.txt', Has('n.txt', fcCreated));
    AssertTrue('modified by append', Has('n.txt', fcModified));
    AssertTrue('copied', Has('copy.txt', fcCreated));
    AssertTrue('moved away', Has('copy.txt', fcDeleted));
    AssertTrue('moved to', Has('moved.txt', fcCreated));
    AssertTrue('removed', Has('n.txt', fcDeleted));
    AssertTrue('directory created', Has('newdir', fcCreated));
    { The before text rides along, so a consumer can diff. }
    for I := 0 to Changes.Count - 1 do
      if (Changes[I].Path = 'moved.txt') and (Changes[I].Kind = fcCreated) then
        AssertEquals('content captured', 'ONE' + #10 + 'two' + #10,
          Changes[I].After);
    AssertTrue('summary names a change', Pos('moved.txt', Changes.Summary) > 0);
  finally
    Changes.Free;
  end;
end;

procedure TShellExecutorTest.TestObserverReceivesTierOutput;
var
  Exec: TCommandExecution;
  Obs: TRecordObserver;
begin
  Obs := TRecordObserver.Create;
  try
    AssertTrue('ran', RunExec('cat a.txt', Exec, Obs));
    AssertEquals('observer saw the output', 'alpha' + #10, Obs.Text);
    AssertEquals('fallback untouched', 0, FFallback.Calls);
  finally
    Obs.Free;
  end;
end;

procedure TShellExecutorTest.TestOwnsApprovalOnlyForTierScripts;
var
  W: string;
begin
  AssertTrue('supported owns approval',
    FExecutor.OwnsApproval('echo hi', cmAuto, W));
  AssertFalse('unknown does not',
    FExecutor.OwnsApproval('git status', cmAuto, W));
  AssertFalse('parse error does not',
    FExecutor.OwnsApproval('echo $(date)', cmAuto, W));
  AssertFalse('unsupported option does not',
    FExecutor.OwnsApproval('ls -R', cmAuto, W));
  AssertFalse('bash mode never owns approval',
    FExecutor.OwnsApproval('echo hi', cmBash, W));
end;

procedure TShellExecutorTest.TestModeBashUsesTheFallback;
var
  Exec: TCommandExecution;
begin
  AssertTrue('ran', RunExec('echo hi', Exec, nil, cmBash));
  AssertEquals('fallback used', 1, FFallback.Calls);
  AssertEquals('mode passed', Ord(cmBash), Ord(FFallback.LastMode));
  AssertEquals('fallback output', 'fallback output', Exec.Output);
end;

procedure TShellExecutorTest.TestModeBuiltinRunsSupported;
var
  Exec: TCommandExecution;
begin
  AssertTrue('ran', RunExec('echo hi', Exec, nil, cmBuiltin));
  AssertEquals('fallback untouched', 0, FFallback.Calls);
  AssertEquals('tier output', 'hi' + #10, Exec.Output);
end;

procedure TShellExecutorTest.TestModeBuiltinRefusesUnsupported;
var
  Exec: TCommandExecution;
begin
  AssertFalse('refused', RunExec('git status', Exec, nil, cmBuiltin));
  AssertEquals('fallback untouched', 0, FFallback.Calls);
  AssertTrue('names the executor', Pos('cannot run', Exec.Error) > 0);
end;

procedure TShellExecutorTest.TestDenialIsAResultNotAFallback;
var
  Exec: TCommandExecution;
begin
  FApproval.Allow := False;
  AssertTrue('ran', RunExec('cat a.txt', Exec));
  AssertEquals('denied status', 126, Exec.ExitCode);
  AssertEquals('fallback untouched', 0, FFallback.Calls);
  AssertTrue('names the denial', Pos('denied', Exec.Output) > 0);
end;

initialization
  RegisterTest(TShellExecutorTest);
end.
