unit hildegard.helper.command.tool;
{ The gated shell tool. `run_command` parses the model's arguments, classifies
  the command through hildegard.helper.command.policy, obtains operator approval
  when the policy asks, executes synchronously through an injectable executor
  (a thin wrapper over TCommandRunner), caps the output returned to the model,
  and records an audit entry.

  The policy source, executor, and approver are all injectable, so the tool is
  tested with fakes: no SQLite, no network, and no real process. A store-backed
  policy source and audit log live in this unit too (TStoreCommandPolicySource).

  v1 is Unix-first: DefaultShellProfile is POSIX bash. The shell is a value, so a
  future cmd.exe profile is additive. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  hildegard.helper.agent, hildegard.helper.llm,
  hildegard.helper.command.policy,
  hildegard.helper.process, hildegard.helper.store;

type
  { Shell description. v1 ships DefaultShellProfile (POSIX). }
  TShellProfile = record
    Executable: string;   // '/bin/bash'
    Switch: string;       // '-c'
    Syntax: TShellSyntax; // ssPosix
  end;

  TCommandToolConfig = record
    Shell: TShellProfile;
    DefaultCwd: string;        // '' => process cwd
    DefaultTimeoutMs: QWord;   // 0 => ProfileDefaultTimeoutMs
    MaxOutputBytes: Integer;   // 0 => DefaultMaxOutputBytes
  end;

  { Outcome of one execution. Started=False means the runner could not begin. }
  TCommandExecution = record
    Output: string;
    ExitCode: Integer;
    TimedOut: Boolean;
    Cancelled: Boolean;
    Started: Boolean;
    Error: string;
  end;

  { Execution seam. The real implementation wraps TCommandRunner; tests use a
    fake. Returns False only on infrastructure failure. }
  ICommandExecutor = interface
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord;
      out AExecution: TCommandExecution): Boolean;
  end;

  TCommandAuditEntry = record
    Id: string;
    Command: string;
    Reason: string;        // the model's stated reason for the call
    Decision: TCommandDecision;
    Approval: string;      // 'policy' | 'once' | 'always' | 'denied' | ''
    ExitCode: Integer;
    TimedOut: Boolean;
    OutputBytes: Integer;
    CreatedAtMs: Int64;
  end;

  { Policy persistence seam. The store-backed implementation reads/writes
    settings and audit; tests use an in-memory fake. }
  ICommandPolicySource = interface
    function LoadPolicy(out APolicy: TCommandPolicy; out AError: string): Boolean;
    { Persists an allow pattern; see TCommandPolicy for pattern forms. }
    function SaveApproval(const APattern: string; out AError: string): Boolean;
    procedure RecordAudit(const AEntry: TCommandAuditEntry);
  end;

  TApprovalRequest = record
    Command: string;          // the whole command line
    SegmentCommand: string;   // the individual simple command being approved
    Segment: TCommandSegment;
    Reason: string;           // the model's stated reason for the call
    Decision: TSegmentDecision;
  end;

  { aoAllowOnce: run only now. aoAllowSpecific: persist this exact command
    (executable + arguments). aoAllowWildcard: persist the executable with any
    arguments. aoDeny: refuse. }
  TApprovalOutcome = (aoAllowOnce, aoAllowSpecific, aoAllowWildcard, aoDeny);

  { Called by the tool on the loop's (calling) thread. Return the outcome. }
  TApprovalHandler = function(const ARequest: TApprovalRequest):
    TApprovalOutcome of object;

  { Runs one command through TCommandRunner, collecting combined output. }
  TProcessCommandExecutor = class(TInterfacedObject, ICommandExecutor)
  public
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord;
      out AExecution: TCommandExecution): Boolean;
  end;

  TCommandTool = class
  private
    FConfig: TCommandToolConfig;
    FSource: ICommandPolicySource;
    FApprover: TApprovalHandler;
    FExecutor: ICommandExecutor;
    FSeq: Integer;
    function MakeAudit(const ACommand, AReason: string;
      const ADecision: TSegmentDecision; const AApproval: string;
      AExitCode: Integer; ATimedOut: Boolean;
      AOutputBytes: Integer): TCommandAuditEntry;
  public
    constructor Create(const AConfig: TCommandToolConfig;
      ASource: ICommandPolicySource; AApprover: TApprovalHandler = nil;
      AExecutor: ICommandExecutor = nil);
    { Registers run_command with the registry. }
    procedure Register(ATools: TToolRegistry);
    { Matches TToolHandler; registered by Register. Public for direct testing. }
    function Run(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
  end;

  { Session-only source for when no store is available. It never persists:
    "allow always" lasts for the process lifetime and audits are discarded. The
    intended use is DefaultCommandPolicy (ask everything, deny nothing), so the
    shell tool is enabled but every command is approved by hand. }
  TMemoryCommandPolicySource = class(TInterfacedObject, ICommandPolicySource)
  private
    FPolicy: TCommandPolicy;
    FApproved: TCommandArgArray;
  public
    constructor Create(const APolicy: TCommandPolicy);
    function LoadPolicy(out APolicy: TCommandPolicy;
      out AError: string): Boolean;
    function SaveApproval(const APattern: string;
      out AError: string): Boolean;
    procedure RecordAudit(const AEntry: TCommandAuditEntry);
  end;

  { Reuses the existing requests table for audit (Kind='command'); policy lives
    in settings. The store is opened by the owner; this source never opens it. }
  TStoreCommandPolicySource = class(TInterfacedObject, ICommandPolicySource)
  private
    FStore: TSqliteStore;
  public
    constructor Create(AStore: TSqliteStore);
    function LoadPolicy(out APolicy: TCommandPolicy;
      out AError: string): Boolean;
    function SaveApproval(const APattern: string;
      out AError: string): Boolean;
    procedure RecordAudit(const AEntry: TCommandAuditEntry);
  end;

function DefaultShellProfile: TShellProfile;

const
  CommandToolName = 'run_command';
  ProfileDefaultTimeoutMs = 30000;
  DefaultMaxOutputBytes = 32768;
  SettingPolicyAllow = 'command.policy.allow';
  SettingPolicyDeny = 'command.policy.deny';
  SettingPolicyRoots = 'command.policy.roots';
  SettingPolicyAllowInterpreters = 'command.policy.allow_interpreters';
  SettingPolicyApproved = 'command.policy.approved';

implementation

uses
  fpjson, jsonparser;

{ --- helpers ------------------------------------------------------------ }

function ReadStringArg(ARoot: TJSONObject; const AName: string;
  out AValue: string): Boolean;
var
  D: TJSONData;
begin
  D := ARoot.Find(AName);
  Result := (D <> nil) and (D.JSONType = jtString);
  if Result then
    AValue := D.AsString
  else
    AValue := '';
end;

function ReadOptionalUInt(ARoot: TJSONObject; const AName: string;
  ADefault: QWord): QWord;
var
  D: TJSONData;
begin
  Result := ADefault;
  D := ARoot.Find(AName);
  if (D <> nil) and (D.JSONType = jtNumber) and (D.AsInt64 > 0) then
    Result := D.AsInt64;
end;

procedure AppendAllow(var APolicy: TCommandPolicy; const APattern: string);
begin
  SetLength(APolicy.Allow, Length(APolicy.Allow) + 1);
  APolicy.Allow[High(APolicy.Allow)] := APattern;
end;

{ Summarises per-segment approval modes for the audit: the broadest wins. }
function ApprovalSummary(const AModes: TCommandArgArray): string;
var
  Mode: string;
  HasOnce, HasSpecific, HasWildcard, HasPolicy: Boolean;
begin
  HasOnce := False;
  HasSpecific := False;
  HasWildcard := False;
  HasPolicy := False;
  for Mode in AModes do
  begin
    if Mode = 'wildcard' then HasWildcard := True
    else if Mode = 'specific' then HasSpecific := True
    else if Mode = 'once' then HasOnce := True
    else if Mode = 'policy' then HasPolicy := True;
  end;
  if HasWildcard then Result := 'wildcard'
  else if HasSpecific then Result := 'specific'
  else if HasOnce then Result := 'once'
  else if HasPolicy then Result := 'policy'
  else Result := 'policy';
end;

function EncodeArgArray(const AList: TCommandArgArray): string;
var
  Arr: TJSONArray;
  I: Integer;
begin
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(AList) do
      Arr.Add(AList[I]);
    Result := Arr.AsJSON;
  finally
    Arr.Free;
  end;
end;

function StoreErrText(const AError: TStoreError): string;
begin
  Result := AError.Message;
  if AError.Detail <> '' then
    Result := Result + ' (' + AError.Detail + ')';
end;

function DecisionName(ADecision: TCommandDecision): string;
begin
  Result := 'unknown';
  case ADecision of
    cdAllow: Result := 'allow';
    cdAsk: Result := 'ask';
    cdDeny: Result := 'deny';
  end;
end;

function EncodeAudit(const AEntry: TCommandAuditEntry): string;
var
  Root: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('reason', AEntry.Reason);
    Root.Add('decision', DecisionName(AEntry.Decision));
    Root.Add('approval', AEntry.Approval);
    Root.Add('timed_out', AEntry.TimedOut);
    Root.Add('output_bytes', AEntry.OutputBytes);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

function DefaultShellProfile: TShellProfile;
begin
  Result.Executable := '/bin/bash';
  Result.Switch := '-c';
  Result.Syntax := ssPosix;
end;

{ --- TProcessCommandExecutor -------------------------------------------- }

type
  { Collects runner output under a lock; the runner callback fires on its own
    thread. The executor joins the runner before reading. }
  TOutputCollector = class
  private
    FLock: TCriticalSection;
    FData: string;
    FExit: Integer;
    FTimedOut: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnOutput(const AId: string; AKind: TOutputKind;
      const AText: string; AExitCode: Integer);
    function Take(out AExit: Integer; out ATimedOut: Boolean): string;
  end;

constructor TOutputCollector.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TOutputCollector.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TOutputCollector.OnOutput(const AId: string; AKind: TOutputKind;
  const AText: string; AExitCode: Integer);
begin
  FLock.Acquire;
  try
    case AKind of
      okStarted: ;
      okStdout, okStderr: FData := FData + AText;
      okFinished: FExit := AExitCode;
    end;
  finally
    FLock.Release;
  end;
end;

function TOutputCollector.Take(out AExit: Integer;
  out ATimedOut: Boolean): string;
begin
  FLock.Acquire;
  try
    Result := FData;
    AExit := FExit;
    ATimedOut := FTimedOut;
  finally
    FLock.Release;
  end;
end;

function TProcessCommandExecutor.Execute(const AProfile: TShellProfile;
  const ACommand, AWorkDir: string; ATimeoutMs: QWord;
  out AExecution: TCommandExecution): Boolean;
var
  Collector: TOutputCollector;
  Runner: TCommandRunner;
  ExitCode: Integer;
  TimedOut: Boolean;
begin
  AExecution := Default(TCommandExecution);
  Collector := TOutputCollector.Create;
  try
    Runner := TCommandRunner.Create('cmd', ACommand, ATimeoutMs, AWorkDir,
      Collector.OnOutput, AProfile.Executable, AProfile.Switch);
    try
      Runner.Start;
      Runner.WaitFor;
      AExecution.Output := Collector.Take(ExitCode, TimedOut);
      AExecution.ExitCode := ExitCode;
      AExecution.TimedOut := TimedOut;
      AExecution.Cancelled := False;
      AExecution.Started := True;
      AExecution.Error := '';
      Result := True;
    finally
      Runner.Free;
    end;
  finally
    Collector.Free;
  end;
end;

{ --- TCommandTool ------------------------------------------------------- }

constructor TCommandTool.Create(const AConfig: TCommandToolConfig;
  ASource: ICommandPolicySource; AApprover: TApprovalHandler;
  AExecutor: ICommandExecutor);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.Shell.Executable = '' then
    FConfig.Shell := DefaultShellProfile;
  if FConfig.DefaultTimeoutMs = 0 then
    FConfig.DefaultTimeoutMs := ProfileDefaultTimeoutMs;
  if FConfig.MaxOutputBytes <= 0 then
    FConfig.MaxOutputBytes := DefaultMaxOutputBytes;
  FSource := ASource;
  FApprover := AApprover;
  if AExecutor = nil then
    FExecutor := TProcessCommandExecutor.Create
  else
    FExecutor := AExecutor;
  FSeq := 0;
end;

function TCommandTool.MakeAudit(const ACommand, AReason: string;
  const ADecision: TSegmentDecision; const AApproval: string;
  AExitCode: Integer; ATimedOut: Boolean;
  AOutputBytes: Integer): TCommandAuditEntry;
begin
  Inc(FSeq);
  Result := Default(TCommandAuditEntry);
  Result.Id := IntToStr(GetTickCount64) + '-' + IntToStr(FSeq);
  Result.Command := ACommand;
  Result.Reason := AReason;
  Result.Decision := ADecision.Decision;
  Result.Approval := AApproval;
  Result.ExitCode := AExitCode;
  Result.TimedOut := ATimedOut;
  Result.OutputBytes := AOutputBytes;
  Result.CreatedAtMs := 0;
end;

procedure TCommandTool.Register(ATools: TToolRegistry);
var
  Spec: TToolSpec;
begin
  Spec.Name := CommandToolName;
  Spec.Description :=
    'Run a shell command on the host and return its output. Requires a short ' +
    'reason. Commands are checked against the operator policy and may need ' +
    'approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"command":{"type":"string","description":"Shell command to run."},' +
    '"reason":{"type":"string","description":"Short reason this command is needed."},' +
    '"cwd":{"type":"string","description":"Working directory."},' +
    '"timeout_ms":{"type":"integer","description":"Timeout in ms (0 = default)."}' +
    '},"required":["command","reason"]}';
  ATools.Add(Spec, Run);
end;

function TCommandTool.Run(const AArgumentsJson: string;
  out AResult: string; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Command, Reason, Cwd, SErr, Approval, EffectiveCwd: string;
  TimeoutMs: QWord;
  Policy: TCommandPolicy;
  Plan: TCommandPlan;
  SD: TSegmentDecision;
  Modes: TCommandArgArray;
  Outcome: TApprovalOutcome;
  Request: TApprovalRequest;
  Execution: TCommandExecution;
  Audit: TCommandAuditEntry;
  Truncated: Boolean;
  I: Integer;
  Pattern: string;
begin
  AResult := '';
  AError := '';
  Result := False;
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      AError := 'invalid arguments JSON';
      Exit(False);
    end;
    try
      if not (Data is TJSONObject) then
      begin
        AError := 'arguments must be a JSON object';
        Exit(False);
      end;
      Root := TJSONObject(Data);

      if not ReadStringArg(Root, 'command', Command) or (Trim(Command) = '') then
      begin
        AError := 'missing required "command"';
        Exit(False);
      end;
      if not ReadStringArg(Root, 'reason', Reason) or (Trim(Reason) = '') then
      begin
        AError := 'missing required "reason"';
        Exit(False);
      end;
      ReadStringArg(Root, 'cwd', Cwd);
      TimeoutMs := ReadOptionalUInt(Root, 'timeout_ms', FConfig.DefaultTimeoutMs);

      if FSource = nil then
      begin
        AError := 'no policy source configured';
        Exit(False);
      end;
      if not FSource.LoadPolicy(Policy, SErr) then
      begin
        AError := 'policy error: ' + SErr;
        Exit(False);
      end;

      Plan := ParseCommand(Command, FConfig.Shell.Syntax);
      if (Plan.ParseError <> '') or (Length(Plan.Segments) = 0) then
      begin
        SD := Default(TSegmentDecision);
        SD.SegmentIndex := -1;
        SD.Decision := cdAsk;
        if Plan.ParseError <> '' then
          SD.Reason := 'could not parse command: ' + Plan.ParseError
        else
          SD.Reason := 'empty command';
        Audit := MakeAudit(Command, Reason, SD, 'denied', 0, False, 0);
        FSource.RecordAudit(Audit);
        AError := SD.Reason;
        Exit(False);
      end;

      { Never prompt if any segment is denied: refuse the whole command. }
      for I := 0 to High(Plan.Segments) do
      begin
        SD := ClassifySegment(Plan, I, Policy);
        if SD.Decision = cdDeny then
        begin
          Audit := MakeAudit(Command, Reason, SD, 'denied', 0, False, 0);
          FSource.RecordAudit(Audit);
          AError := 'denied by policy: ' + SD.Reason;
          Exit(False);
        end;
      end;

      { Evaluate each segment separately and approve only the ones the policy
        asks about. Persisting an approval updates the in-run policy, so a
        wildcard covers later matching segments without another prompt. }
      Modes := nil;
      for I := 0 to High(Plan.Segments) do
      begin
        SD := ClassifySegment(Plan, I, Policy);
        if SD.Decision = cdAllow then
        begin
          SetLength(Modes, Length(Modes) + 1);
          Modes[High(Modes)] := 'policy';
          Continue;
        end;

        Outcome := aoDeny;
        if Assigned(FApprover) then
        begin
          Request := Default(TApprovalRequest);
          Request.Command := Command;
          Request.SegmentCommand := Plan.Segments[I].Text;
          Request.Segment := Plan.Segments[I];
          Request.Reason := Reason;
          Request.Decision := SD;
          Outcome := FApprover(Request);
        end;

        case Outcome of
          aoAllowOnce:
            begin
              SetLength(Modes, Length(Modes) + 1);
              Modes[High(Modes)] := 'once';
            end;
          aoAllowSpecific:
            begin
              Pattern := Plan.Segments[I].Text;
              if not FSource.SaveApproval(Pattern, SErr) then
              begin
                AError := 'could not persist approval: ' + SErr;
                Exit(False);
              end;
              AppendAllow(Policy, Pattern);
              SetLength(Modes, Length(Modes) + 1);
              Modes[High(Modes)] := 'specific';
            end;
          aoAllowWildcard:
            begin
              Pattern := ExtractFileName(Plan.Segments[I].Executable);
              if Pattern = '' then
                Pattern := Plan.Segments[I].Executable;
              Pattern := Pattern + ' *';
              if not FSource.SaveApproval(Pattern, SErr) then
              begin
                AError := 'could not persist approval: ' + SErr;
                Exit(False);
              end;
              AppendAllow(Policy, Pattern);
              SetLength(Modes, Length(Modes) + 1);
              Modes[High(Modes)] := 'wildcard';
            end;
          aoDeny:
            begin
              Audit := MakeAudit(Command, Reason, SD, 'denied', 0, False, 0);
              FSource.RecordAudit(Audit);
              AError := 'denied by operator: ' + Plan.Segments[I].Text;
              Exit(False);
            end;
        end;
      end;
      Approval := ApprovalSummary(Modes);

      SD := Default(TSegmentDecision);
      SD.Decision := cdAllow;
      EffectiveCwd := Cwd;
      if EffectiveCwd = '' then
        EffectiveCwd := FConfig.DefaultCwd;
      if not FExecutor.Execute(FConfig.Shell, Command, EffectiveCwd, TimeoutMs,
        Execution) then
      begin
        Audit := MakeAudit(Command, Reason, SD, Approval, 0, False, 0);
        FSource.RecordAudit(Audit);
        AError := 'failed to execute: ' + Execution.Error;
        Exit(False);
      end;

      Truncated := Length(Execution.Output) > FConfig.MaxOutputBytes;
      AResult := 'exit_code: ' + IntToStr(Execution.ExitCode) + LineEnding;
      if Truncated then
        AResult := AResult + Copy(Execution.Output, 1, FConfig.MaxOutputBytes)
      else
        AResult := AResult + Execution.Output;
      if Truncated then
        AResult := AResult + LineEnding + '[output truncated at ' +
          IntToStr(FConfig.MaxOutputBytes) + ' bytes]';

      Audit := MakeAudit(Command, Reason, SD, Approval,
        Execution.ExitCode, Execution.TimedOut, Length(Execution.Output));
      FSource.RecordAudit(Audit);
      Result := True;
    finally
      Data.Free;
    end;
  except
    on E: Exception do
    begin
      AResult := '';
      AError := 'run_command error: ' + E.Message;
      Result := False;
    end;
  end;
end;

{ --- TStoreCommandPolicySource ------------------------------------------ }

constructor TMemoryCommandPolicySource.Create(const APolicy: TCommandPolicy);
begin
  inherited Create;
  FPolicy := APolicy;
  FApproved := nil;
end;

function TMemoryCommandPolicySource.LoadPolicy(out APolicy: TCommandPolicy;
  out AError: string): Boolean;
var
  I: Integer;
begin
  APolicy := FPolicy;
  for I := 0 to High(FApproved) do
  begin
    SetLength(APolicy.Allow, Length(APolicy.Allow) + 1);
    APolicy.Allow[High(APolicy.Allow)] := FApproved[I];
  end;
  AError := '';
  Result := True;
end;

function TMemoryCommandPolicySource.SaveApproval(const APattern: string;
  out AError: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FApproved) do
    if FApproved[I] = APattern then
    begin
      AError := '';
      Exit(True);
    end;
  SetLength(FApproved, Length(FApproved) + 1);
  FApproved[High(FApproved)] := APattern;
  AError := '';
  Result := True;
end;

procedure TMemoryCommandPolicySource.RecordAudit(
  const AEntry: TCommandAuditEntry);
begin
  { No sink without a store; audit is best-effort. }
end;

constructor TStoreCommandPolicySource.Create(AStore: TSqliteStore);
begin
  inherited Create;
  FStore := AStore;
end;

function LoadArraySetting(AStore: TSqliteStore; const AKey: string;
  out AList: TCommandArgArray; out AError: string): Boolean;
var
  Value: string;
  StoreError: TStoreError;
  Data: TJSONData;
  Arr: TJSONArray;
  I: Integer;
begin
  AList := nil;
  AError := '';
  if not AStore.GetSetting(AKey, Value, StoreError) then
  begin
    if StoreError.Code = seNotFound then
      Exit(True);
    AError := StoreErrText(StoreError);
    Exit(False);
  end;
  if Trim(Value) = '' then
    Exit(True);
  Data := nil;
  try
    try
      Data := GetJSON(Value);
    except
      AError := 'invalid setting ' + AKey;
      Exit(False);
    end;
    if not (Data is TJSONArray) then
    begin
      AError := 'setting ' + AKey + ' must be a JSON array';
      Exit(False);
    end;
    Arr := TJSONArray(Data);
    SetLength(AList, Arr.Count);
    for I := 0 to Arr.Count - 1 do
      AList[I] := Arr.Strings[I];
    Result := True;
  finally
    Data.Free;
  end;
end;

function TStoreCommandPolicySource.LoadPolicy(out APolicy: TCommandPolicy;
  out AError: string): Boolean;
var
  Approved: TCommandArgArray;
  Value: string;
  StoreError: TStoreError;
  I: Integer;
begin
  APolicy := Default(TCommandPolicy);
  if not LoadArraySetting(FStore, SettingPolicyAllow, APolicy.Allow, AError) then
    Exit(False);
  if not LoadArraySetting(FStore, SettingPolicyDeny, APolicy.Deny, AError) then
    Exit(False);
  if not LoadArraySetting(FStore, SettingPolicyRoots, APolicy.AllowedRoots,
    AError) then
    Exit(False);
  if not LoadArraySetting(FStore, SettingPolicyApproved, Approved, AError) then
    Exit(False);
  for I := 0 to High(Approved) do
  begin
    SetLength(APolicy.Allow, Length(APolicy.Allow) + 1);
    APolicy.Allow[High(APolicy.Allow)] := Approved[I];
  end;
  if FStore.GetSetting(SettingPolicyAllowInterpreters, Value, StoreError) then
    APolicy.AllowInterpreters := (Value = '1') or (Value = 'true')
  else if StoreError.Code <> seNotFound then
  begin
    AError := StoreErrText(StoreError);
    Exit(False);
  end;
  Result := True;
end;

function TStoreCommandPolicySource.SaveApproval(const APattern: string;
  out AError: string): Boolean;
var
  Approved: TCommandArgArray;
  StoreError: TStoreError;
  I: Integer;
begin
  AError := '';
  if not LoadArraySetting(FStore, SettingPolicyApproved, Approved, AError) then
    Exit(False);
  for I := 0 to High(Approved) do
    if Approved[I] = APattern then
      Exit(True);
  SetLength(Approved, Length(Approved) + 1);
  Approved[High(Approved)] := APattern;
  if not FStore.SetSetting(SettingPolicyApproved, EncodeArgArray(Approved),
    StoreError) then
  begin
    AError := StoreErrText(StoreError);
    Exit(False);
  end;
  Result := True;
end;

procedure TStoreCommandPolicySource.RecordAudit(const AEntry: TCommandAuditEntry);
var
  Req: TStoredRequest;
  StoreError: TStoreError;
  Status: TRequestStatus;
begin
  Req := Default(TStoredRequest);
  Req.Id := AEntry.Id;
  Req.Kind := 'command';
  Req.Payload := AEntry.Command;
  if not FStore.EnqueueRequest(Req, StoreError) then
    Exit;
  if AEntry.Approval = 'denied' then
    Status := rsFailed
  else if AEntry.TimedOut then
    Status := rsCancelled
  else
    Status := rsCompleted;
  FStore.FinishRequest(AEntry.Id, Status, AEntry.ExitCode, EncodeAudit(AEntry),
    StoreError);
end;

end.
