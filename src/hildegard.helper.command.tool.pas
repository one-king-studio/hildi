unit hildegard.helper.command.tool;
{ The gated shell tool. `run_command` parses a command into simple-command
  segments, asks the approval service to resolve each segment through the
  generic tool-approval whitelist, executes synchronously through an injectable
  executor (a thin wrapper over TCommandRunner), and caps the output returned to
  the model.

  The tool owns its approval granularity: for each segment it offers "once",
  "this exact command", "any arguments", and (when a non-flag prefix exists) a
  prefix-subtree option. The harness supplies the store-backed approval service
  and the operator prompt. v1 is Unix-first: the shell is a value (POSIX bash by
  default). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  hildegard.helper.agent, hildegard.helper.llm,
  hildegard.helper.command.policy, hildegard.helper.approval,
  hildegard.helper.process;

type
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

  { Runs one command through TCommandRunner, collecting combined output. }
  TProcessCommandExecutor = class(TInterfacedObject, ICommandExecutor)
  public
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord;
      out AExecution: TCommandExecution): Boolean;
  end;

  TCommandTool = class(TInterfacedObject, IApprovableTool)
  private
    FConfig: TCommandToolConfig;
    FService: IApprovalService;
    FExecutor: ICommandExecutor;
  public
    constructor Create(const AConfig: TCommandToolConfig;
      AService: IApprovalService; AExecutor: ICommandExecutor = nil);
    { Registers run_command with the registry. }
    procedure Register(ATools: TToolRegistry);
    { Matches TToolHandler; registered by Register. Public for direct testing. }
    function Run(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    { One approval ask per parsed segment (IApprovableTool). }
    function ApprovalAsks(const AArgumentsJson: string): TApprovalAskArray;
  end;

function DefaultShellProfile: TShellProfile;

const
  CommandToolName = 'run_command';
  ProfileDefaultTimeoutMs = 30000;
  DefaultMaxOutputBytes = 32768;

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

function DefaultShellProfile: TShellProfile;
begin
  Result.Executable := '/bin/bash';
  Result.Switch := '-c';
  Result.Syntax := ssPosix;
end;

{ Builds the approval ask for each parsed segment. Pure; nil on parse error. }
function BuildAsks(const ACommand: string;
  ASyntax: TShellSyntax): TApprovalAskArray;
var
  Plan: TCommandPlan;
  I: Integer;
  Seg: TCommandSegment;
  Bin, Ref: string;

  function OneParam(const AValue: string): TApprovalParams;
  begin
    Result := nil;
    SetLength(Result, 1);
    Result[0] := AValue;
  end;

  procedure AddOption(var AAsk: TApprovalAsk; const AKey, ACaption: string;
    APersists: Boolean; const AParams: TApprovalParams; AAny: Boolean);
  var
    Opt: TApprovalOption;
  begin
    Opt := Default(TApprovalOption);
    Opt.Key := AKey;
    Opt.Caption := ACaption;
    Opt.Persists := APersists;
    Opt.Rule := DefaultApprovalRule(aeAllow);
    Opt.Rule.Ref := Ref;
    Opt.Rule.Params := AParams;
    Opt.Rule.AnyParams := AAny;
    SetLength(AAsk.Options, Length(AAsk.Options) + 1);
    AAsk.Options[High(AAsk.Options)] := Opt;
  end;

begin
  Result := nil;
  Plan := ParseCommand(ACommand, ASyntax);
  if (Plan.ParseError <> '') or (Length(Plan.Segments) = 0) then
    Exit;
  for I := 0 to High(Plan.Segments) do
  begin
    Seg := Plan.Segments[I];
    if Seg.Executable = '' then
      Continue;
    Bin := ExtractFileName(Seg.Executable);
    if Bin = '' then
      Bin := Seg.Executable;
    Ref := 'run_command:' + Bin;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Default(TApprovalAsk);
    Result[High(Result)].Summary := Seg.Text;
    Result[High(Result)].Subject.Ref := Ref;
    Result[High(Result)].Subject.Params :=
      Copy(Seg.Arguments, 0, Length(Seg.Arguments));

    AddOption(Result[High(Result)], 'once', 'allow once', False, nil, False);
    AddOption(Result[High(Result)], 'exact', 'always this exact command', True,
      Copy(Seg.Arguments, 0, Length(Seg.Arguments)), False);
    AddOption(Result[High(Result)], 'any',
      'always ' + Bin + ' with any arguments', True, nil, True);
    if (Length(Seg.Arguments) > 0) and (Seg.Arguments[0] <> '') and
      (Seg.Arguments[0][1] <> '-') then
      AddOption(Result[High(Result)], 'prefix',
        'always ' + Bin + ' ' + Seg.Arguments[0] + ' ...', True,
        OneParam(Seg.Arguments[0]), True);
  end;
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
  AService: IApprovalService; AExecutor: ICommandExecutor);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.Shell.Executable = '' then
    FConfig.Shell := DefaultShellProfile;
  if FConfig.DefaultTimeoutMs = 0 then
    FConfig.DefaultTimeoutMs := ProfileDefaultTimeoutMs;
  if FConfig.MaxOutputBytes <= 0 then
    FConfig.MaxOutputBytes := DefaultMaxOutputBytes;
  FService := AService;
  if AExecutor = nil then
    FExecutor := TProcessCommandExecutor.Create
  else
    FExecutor := AExecutor;
end;

procedure TCommandTool.Register(ATools: TToolRegistry);
var
  Spec: TToolSpec;
begin
  Spec.Name := CommandToolName;
  Spec.Description :=
    'Run a shell command on the host and return its output. Requires a short ' +
    'reason. Commands are checked against the approval whitelist and may need ' +
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

function TCommandTool.ApprovalAsks(
  const AArgumentsJson: string): TApprovalAskArray;
var
  Data: TJSONData;
  Root: TJSONObject;
  Command, Reason, ReasonError: string;
  I: Integer;
begin
  Result := nil;
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      Exit;
    end;
    try
      if not (Data is TJSONObject) then
        Exit;
      Root := TJSONObject(Data);
      if not ReadStringArg(Root, 'command', Command) or (Trim(Command) = '') then
        Exit;
      Result := BuildAsks(Command, FConfig.Shell.Syntax);
      { The reason is already in the call's arguments; carry it so the dialog
        can show why the model wants to run this. }
      Reason := '';
      ExtractToolReason(AArgumentsJson, Reason, ReasonError);
      for I := 0 to High(Result) do
        Result[I].Reason := Reason;
    finally
      Data.Free;
    end;
  except
    Result := nil;
  end;
end;

function TCommandTool.Run(const AArgumentsJson: string;
  out AResult: string; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Command, Reason, Cwd, EffectiveCwd: string;
  TimeoutMs: QWord;
  Plan: TCommandPlan;
  Asks: TApprovalAskArray;
  Batch: TApprovalBatchResult;
  Execution: TCommandExecution;
  Truncated: Boolean;
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

      Plan := ParseCommand(Command, FConfig.Shell.Syntax);
      if (Plan.ParseError <> '') or (Length(Plan.Segments) = 0) then
      begin
        AError := 'could not parse command: ' + Plan.ParseError;
        Exit(False);
      end;

      if FService = nil then
      begin
        AError := 'no approval service configured';
        Exit(False);
      end;
      Asks := BuildAsks(Command, FConfig.Shell.Syntax);
      if not FService.Resolve(Asks, Batch) then
      begin
        AError := 'approval error: ' + Batch.Reason;
        Exit(False);
      end;
      if Batch.Denied then
      begin
        AError := Batch.Reason;
        Exit(False);
      end;

      EffectiveCwd := Cwd;
      if EffectiveCwd = '' then
        EffectiveCwd := FConfig.DefaultCwd;
      if not FExecutor.Execute(FConfig.Shell, Command, EffectiveCwd, TimeoutMs,
        Execution) then
      begin
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

end.
