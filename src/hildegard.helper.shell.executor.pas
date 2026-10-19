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
  hildegard.helper.shell.commands, hildegard.helper.shell.tier;

type
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
    function OwnsApproval(const ACommand: string): Boolean;
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord; AObserver: TToolObserver;
      const AReason: string; out AExecution: TCommandExecution): Boolean;
  end;

implementation

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

function TBuiltinCommandExecutor.OwnsApproval(const ACommand: string): Boolean;
var
  Why: string;
begin
  Result := TierSupportsCommand(ACommand, Why);
end;

function TBuiltinCommandExecutor.Execute(const AProfile: TShellProfile;
  const ACommand, AWorkDir: string; ATimeoutMs: QWord;
  AObserver: TToolObserver; const AReason: string;
  out AExecution: TCommandExecution): Boolean;
var
  Tier: TBuiltinShell;
  Output, TierError: string;
  ExitCode: Integer;
  Owned: Boolean;
begin
  AExecution := Default(TCommandExecution);
  Owned := OwnsApproval(ACommand);
  TierError := '';
  try
    try
      Tier := TBuiltinShell.Create(FConfig, FApproval, FInvoke);
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
    { Fall through to the decision below. }
  end;
  { When the tool skipped its own asks because the tier owns approval, a tier
    failure must NOT fall through to the ungated process path. Fail closed. }
  if Owned then
  begin
    AExecution.Error := 'builtin shell failed: ' + TierError;
    Exit(False);
  end;
  Result := FFallback.Execute(AProfile, ACommand, AWorkDir, ATimeoutMs,
    AObserver, AReason, AExecution);
end;

end.
