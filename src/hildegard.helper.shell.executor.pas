unit hildegard.helper.shell.executor;
{ The builtin tier as an ICommandExecutor.

  It is the first choice in front of the process executor: a fully supported
  script runs in-process; anything else delegates to the fallback with the same
  arguments, so the process tier's behaviour and asks are unchanged. A new
  TBuiltinShell is built per call, so concurrent run_command calls cannot share
  a reason or an environment. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes,
  hildegard.helper.agent,
  hildegard.helper.command.tool, hildegard.helper.approval,
  hildegard.helper.shell.commands, hildegard.helper.shell.tier,
  hildegard.helper.workspace.changes;

type
  { Bridges the FS observer to the call's change set. }
  TChangeCollector = class
  private
    FSet: TFileChangeSet;
  public
    constructor Create(ASet: TFileChangeSet);
    procedure Add(const AChange: TFileChange);
  end;

  TBuiltinCommandExecutor = class(TInterfacedObject, ICommandExecutor)
  private
    FConfig: TBuiltinShellConfig;
    FApproval: IApprovalService;
    FFallback: ICommandExecutor;
    FInvoke: TShellToolInvoke;
  public
    constructor Create(const AConfig: TBuiltinShellConfig;
      AApproval: IApprovalService; AFallback: ICommandExecutor;
      AInvoke: TShellToolInvoke = nil);
    function OwnsApproval(const ACommand: string; AMode: TCommandMode;
      out AWhy: string): Boolean;
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord; AObserver: TToolObserver;
      const AReason: string; AMode: TCommandMode; AChanges: TFileChangeSet;
      out AExecution: TCommandExecution): Boolean;
  end;

implementation

constructor TChangeCollector.Create(ASet: TFileChangeSet);
begin
  inherited Create;
  FSet := ASet;
end;

procedure TChangeCollector.Add(const AChange: TFileChange);
begin
  if FSet <> nil then
    FSet.Add(AChange);
end;

constructor TBuiltinCommandExecutor.Create(const AConfig: TBuiltinShellConfig;
  AApproval: IApprovalService; AFallback: ICommandExecutor;
  AInvoke: TShellToolInvoke);
begin
  inherited Create;
  FConfig := AConfig;
  FApproval := AApproval;
  FFallback := AFallback;
  FInvoke := AInvoke;
end;

function TBuiltinCommandExecutor.OwnsApproval(const ACommand: string;
  AMode: TCommandMode; out AWhy: string): Boolean;
begin
  AWhy := '';
  if AMode = cmBash then
    Exit(False);   // the process tier's splitter asks are the gate
  Result := TierSupportsCommand(ACommand, AWhy);
end;

function TBuiltinCommandExecutor.Execute(const AProfile: TShellProfile;
  const ACommand, AWorkDir: string; ATimeoutMs: QWord;
  AObserver: TToolObserver; const AReason: string; AMode: TCommandMode;
  AChanges: TFileChangeSet; out AExecution: TCommandExecution): Boolean;
var
  Tier: TBuiltinShell;
  Collector: TChangeCollector;
  Output, TierError, Why: string;
  ExitCode: Integer;
  Owned: Boolean;
begin
  AExecution := Default(TCommandExecution);
  { mode=bash is the explicit escalation: the process tier, with its asks.
    NO change set is passed: the process tier captures by walking the tree before
    and after, and by the after-walk the old bytes are gone - so it can record
    sizes but never a patch, which makes its rows un-revertible noise in the log.
    A side-effect check that cannot produce a usable record is not worth the walk.
    The file tools and the builtin tier capture exactly, and they are where a
    revertible record comes from. }
  if AMode = cmBash then
    Exit(FFallback.Execute(AProfile, ACommand, AWorkDir, ATimeoutMs,
      AObserver, AReason, AMode, nil, AExecution));
  Owned := OwnsApproval(ACommand, AMode, Why);
  TierError := '';
  Collector := TChangeCollector.Create(AChanges);
  try
    try
      Tier := TBuiltinShell.Create(FConfig, FApproval, FInvoke, Collector.Add);
      try
        if Tier.TryRun(ACommand, AWorkDir, AReason, ATimeoutMs, Output,
          ExitCode) then
        begin
          AExecution.Output := Output;
          AExecution.ExitCode := ExitCode;
          AExecution.TimedOut := False;
          AExecution.Cancelled := False;
          AExecution.Started := True;
          AExecution.Error := '';
          if (AObserver <> nil) and (Output <> '') then
            AObserver.Next(Output);
          Exit(True);
        end;
        TierError := Tier.LastError;
      finally
        Tier.Free;
      end;
    except
      on E: Exception do
        TierError := E.Message;
    end;
  finally
    Collector.Free;
  end;
  { mode=builtin is a requirement: declining is an error, never a fallback. }
  if AMode = cmBuiltin then
  begin
    AExecution.Error := 'the builtin shell cannot run this command: ' + TierError;
    Exit(False);
  end;
  { When the tool skipped its own asks because the tier owns approval, a tier
    failure must NOT fall through to the ungated process path. Fail closed. }
  if Owned then
  begin
    AExecution.Error := 'builtin shell failed: ' + TierError;
    Exit(False);
  end;
  Result := FFallback.Execute(AProfile, ACommand, AWorkDir, ATimeoutMs,
    AObserver, AReason, AMode, nil, AExecution);
end;

end.
