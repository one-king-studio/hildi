unit hildegard.helper.shell.tier;
{ The builtin shell tier: pre-flight, gate and run.

  It is deliberately whole-script or nothing. TryRun parses the command; if it
  parses and every command name (and every literal option) is one the tier
  supports, the script runs in-process behind the normal approval service;
  otherwise it declines and the process executor runs the command exactly as
  before, before any side effect.

  The gate reuses run_command's refs (`run_command:<bin>`) and option shapes,
  so existing grants apply unchanged, and it inherits the model's reason into
  every ask. `tool`/`mcp` reach the same gate, and the dispatched tool still
  passes its own. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes,
  shell.types, shell.ast, shell.fs, shell.parser, shell.registry,
  shell.interpreter,
  hildegard.helper.approval, hildegard.helper.shell.fs,
  hildegard.helper.shell.commands;

type
  TBuiltinShellConfig = record
    Root: string;
    MaxOutputBytes: Integer;
    MaxCommands: Integer;
    MaxLoopIterations: Integer;
    MaxCallDepth: Integer;
    { Glob patterns for the tools `tool`/`mcp` may call. Empty = none. }
    AllowedTools: TStringArray;
  end;

  TBuiltinShell = class
  private
    FConfig: TBuiltinShellConfig;
    FApproval: IApprovalService;
    FInvoke: TShellToolInvoke;
    FFs: IShellFileSystem;
    FCmd: TBuiltinCommands;
    FRegistry: TShellRegistry;
    FReason: string;
    FDeny: string;
    FLastError: string;
    function Gate(const ACall: TShellCall): Boolean;
    function BuildAsk(const ACall: TShellCall): TApprovalAsk;
    function Preflight(const AScript: TScript): Boolean;
  public
    { Not thread-safe: the executor creates one per run_command call. }
    constructor Create(const AConfig: TBuiltinShellConfig;
      AApproval: IApprovalService; AInvoke: TShellToolInvoke = nil);
    destructor Destroy; override;
    { True when the whole script ran here; False = decline (LastError says
      why). On True, AOutput is stdout followed by stderr. }
    function TryRun(const ACommand, ACwd, AReason: string;
      ATimeoutMs: QWord; out AOutput: string; out AExitCode: Integer): Boolean;
    property LastError: string read FLastError;
  end;

{ True when the tier would run ACommand: it parses, every command name is
  known, and every literal option is supported. Side-effect free, so the
  command tool can decide whether the tier owns approval before it asks. }
function TierSupportsCommand(const ACommand: string; out AWhy: string): Boolean;

implementation

function MakeOption(const ARef, AKey, ACaption: string; APersists: Boolean;
  const AParams: TApprovalParams; AAny: Boolean): TApprovalOption;
begin
  Result := Default(TApprovalOption);
  Result.Key := AKey;
  Result.Caption := ACaption;
  Result.Persists := APersists;
  Result.Rule := DefaultApprovalRule(aeAllow);
  Result.Rule.Ref := ARef;
  Result.Rule.Params := AParams;
  Result.Rule.AnyParams := AAny;
end;

function OneParam(const AValue: string): TApprovalParams;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := AValue;
end;

constructor TBuiltinShell.Create(const AConfig: TBuiltinShellConfig;
  AApproval: IApprovalService; AInvoke: TShellToolInvoke);
var
  WFs: TWorkspaceShellFs;
begin
  inherited Create;
  FConfig := AConfig;
  FApproval := AApproval;
  FInvoke := AInvoke;
  WFs := TWorkspaceShellFs.Create(AConfig.Root);
  FFs := WFs;
  FCmd := TBuiltinCommands.Create(WFs, AInvoke, AConfig.AllowedTools);
  FRegistry := TShellRegistry.Create;
  FRegistry.Register('echo', FCmd.Echo);
  FRegistry.Register('cat', FCmd.Cat);
  FRegistry.Register('head', FCmd.Head);
  FRegistry.Register('tail', FCmd.Tail);
  FRegistry.Register('wc', FCmd.Wc);
  FRegistry.Register('grep', FCmd.Grep);
  FRegistry.Register('ls', FCmd.Ls);
  FRegistry.Register('mkdir', FCmd.Mkdir);
  FRegistry.Register('rm', FCmd.Rm);
  FRegistry.Register('mv', FCmd.Mv);
  FRegistry.Register('cp', FCmd.Cp);
  FRegistry.Register('touch', FCmd.Touch);
  FRegistry.Register('sort', FCmd.SortCmd);
  FRegistry.Register('uniq', FCmd.Uniq);
  FRegistry.Register('basename', FCmd.Basename);
  FRegistry.Register('dirname', FCmd.Dirname);
  FRegistry.Register('test', FCmd.TestCmd);
  FRegistry.Register('[', FCmd.Bracket);
  FRegistry.Register('true', FCmd.TrueCmd);
  FRegistry.Register('false', FCmd.FalseCmd);
  FRegistry.Register('tool', FCmd.Tool);
  FRegistry.Register('mcp', FCmd.Mcp);
end;

destructor TBuiltinShell.Destroy;
begin
  FRegistry.Free;
  FCmd.Free;
  FFs := nil;   // releases the filesystem
  inherited Destroy;
end;

function TBuiltinShell.Gate(const ACall: TShellCall): Boolean;
var
  Ask: TApprovalAsk;
  Batch: TApprovalBatchResult;
begin
  if not Assigned(FApproval) then
    Exit(True);
  Ask := BuildAsk(ACall);
  Batch := Default(TApprovalBatchResult);
  if not FApproval.Resolve([Ask], Batch) then
  begin
    FLastError := Batch.Reason;
    Exit(False);
  end;
  if Batch.Denied or (not Batch.Allowed) then
  begin
    if Batch.Reason <> '' then
      FLastError := Batch.Reason;
    Exit(False);
  end;
  Result := True;
end;

function TBuiltinShell.BuildAsk(const ACall: TShellCall): TApprovalAsk;
var
  Bin, Ref, Summary: string;
  Args: TApprovalParams;
  I: Integer;
begin
  Bin := ExtractFileName(ACall.Name);
  Ref := 'run_command:' + Bin;
  Summary := ACall.Name;
  for I := 0 to High(ACall.Args) do
    Summary := Summary + ' ' + ACall.Args[I];
  Args := ACall.Args;
  Result := Default(TApprovalAsk);
  Result.Summary := Summary;
  Result.Reason := FReason;
  Result.Subject.Ref := Ref;
  Result.Subject.Params := Args;
  SetLength(Result.Options, 3);
  Result.Options[0] := MakeOption(Ref, 'once', 'allow once', False, nil, False);
  Result.Options[1] := MakeOption(Ref, 'exact', 'always this exact command',
    True, Args, False);
  Result.Options[2] := MakeOption(Ref, 'any',
    'always ' + Bin + ' with any arguments', True, nil, True);
  if (Length(ACall.Args) > 0) and (ACall.Args[0] <> '') and
    (ACall.Args[0][1] <> '-') then
  begin
    SetLength(Result.Options, 4);
    Result.Options[3] := MakeOption(Ref, 'prefix',
      'always ' + Bin + ' ' + ACall.Args[0] + ' ...', True,
      OneParam(ACall.Args[0]), True);
  end;
end;

function LiteralTextOf(const AW: TWord; out AText: string): Boolean;
var
  I: Integer;
  P: TWordPart;
begin
  AText := '';
  Result := True;
  for I := 0 to High(AW.Parts) do
  begin
    P := AW.Parts[I];
    case P.Kind of
      wpLiteral, wpGlob, wpTilde: AText := AText + P.Text;
      wpVariable, wpSpecial:
        Exit(False);
    end;
  end;
end;

function KnownTierName(const AName: string; AFunctions: TStringList): Boolean;
begin
  if AName = '' then
    Exit(True);
  if IsBuiltinCommand(AName) then
    Exit(True);
  if AFunctions.IndexOf(AName) >= 0 then
    Exit(True);
  Result := (AName = 'cd') or (AName = 'pwd') or (AName = 'export') or
    (AName = 'unset') or (AName = 'local') or (AName = 'shift') or
    (AName = 'return') or (AName = 'exit') or (AName = 'set');
end;

procedure CollectFunctionsOf(const ASt: TStatement; AFunctions: TStringList); forward;

procedure CollectFunctionsCmd(const AC: TCommand; AFunctions: TStringList);
var
  I: Integer;
begin
  case AC.Kind of
    ckFunction:
      begin
        AFunctions.Add(AC.FuncName);
        if AC.FuncBody <> nil then
          CollectFunctionsCmd(AC.FuncBody, AFunctions);
      end;
    ckGroup, ckSubshell: CollectFunctionsOf(AC.Group, AFunctions);
    ckIf:
      begin
        for I := 0 to High(AC.Clauses) do
        begin
          CollectFunctionsOf(AC.Clauses[I].Condition, AFunctions);
          CollectFunctionsOf(AC.Clauses[I].Body, AFunctions);
        end;
        CollectFunctionsOf(AC.ElseBody, AFunctions);
      end;
    ckFor: CollectFunctionsOf(AC.LoopBody, AFunctions);
    ckWhile, ckUntil:
      begin
        CollectFunctionsOf(AC.Condition, AFunctions);
        CollectFunctionsOf(AC.LoopBody, AFunctions);
      end;
    ckCase:
      for I := 0 to High(AC.CaseItems) do
        CollectFunctionsOf(AC.CaseItems[I].Body, AFunctions);
    ckSimple: ;
  end;
end;

procedure CollectFunctionsOf(const ASt: TStatement; AFunctions: TStringList);
var
  I, J, K: Integer;
begin
  if ASt = nil then
    Exit;
  for I := 0 to High(ASt.Items) do
    for J := 0 to High(ASt.Items[I].Pipelines) do
      for K := 0 to High(ASt.Items[I].Pipelines[J].Commands) do
        CollectFunctionsCmd(ASt.Items[I].Pipelines[J].Commands[K], AFunctions);
end;

function CheckGrepPatternOf(const AC: TCommand; out AWhy: string): Boolean;
var
  I: Integer;
  Arg, Pattern: string;
  Fixed, Extended, Seen: Boolean;
begin
  Result := True;
  AWhy := '';
  Fixed := False;
  Extended := False;
  Seen := False;
  Pattern := '';
  for I := 1 to High(AC.Words) do
  begin
    if not LiteralTextOf(AC.Words[I], Arg) then
      Continue;
    if (not Seen) and (Arg <> '') and (Arg[1] = '-') and (Arg <> '-') then
    begin
      if Pos('F', Arg) > 0 then
        Fixed := True;
      if Pos('E', Arg) > 0 then
        Extended := True;
      Continue;
    end;
    if not Seen then
    begin
      Seen := True;
      Pattern := Arg;
    end;
  end;
  if Seen then
    Result := GrepPatternSupported(Pattern, Fixed, Extended, AWhy);
end;

procedure CheckTierCommand(const AC: TCommand; AFunctions: TStringList;
  var ADeny: string); forward;

procedure CheckTierStatement(const ASt: TStatement; AFunctions: TStringList;
  var ADeny: string);
var
  I, J, K: Integer;
begin
  if (ASt = nil) or (ADeny <> '') then
    Exit;
  for I := 0 to High(ASt.Items) do
    for J := 0 to High(ASt.Items[I].Pipelines) do
      for K := 0 to High(ASt.Items[I].Pipelines[J].Commands) do
      begin
        CheckTierCommand(ASt.Items[I].Pipelines[J].Commands[K], AFunctions,
          ADeny);
        if ADeny <> '' then
          Exit;
      end;
end;

procedure CheckTierCommand(const AC: TCommand; AFunctions: TStringList;
  var ADeny: string);
var
  I: Integer;
  Name, Arg, Options: string;
begin
  if ADeny <> '' then
    Exit;
  case AC.Kind of
    ckSimple:
      begin
        if Length(AC.Words) = 0 then
          Exit;
        if not LiteralTextOf(AC.Words[0], Name) then
          Exit;
        if not KnownTierName(Name, AFunctions) then
        begin
          ADeny := 'the builtin shell does not know "' + Name + '"';
          Exit;
        end;
        if Name = 'grep' then
          if not CheckGrepPatternOf(AC, Arg) then
          begin
            ADeny := 'grep: ' + Arg;
            Exit;
          end;
        { test/[ arguments are operands, not options: -f, -d, -eq are the
          expression itself. }
        if (Name = 'test') or (Name = '[') then
          Exit;
        if BuiltinCommandOptions(Name, Options) then
          for I := 1 to High(AC.Words) do
            if LiteralTextOf(AC.Words[I], Arg) and IsUnsupportedOption(Arg, Options) then
            begin
              ADeny := 'the builtin shell does not support the option "' + Arg +
                '" for ' + Name;
              Exit;
            end;
      end;
    ckGroup, ckSubshell: CheckTierStatement(AC.Group, AFunctions, ADeny);
    ckIf:
      begin
        for I := 0 to High(AC.Clauses) do
        begin
          CheckTierStatement(AC.Clauses[I].Condition, AFunctions, ADeny);
          CheckTierStatement(AC.Clauses[I].Body, AFunctions, ADeny);
        end;
        CheckTierStatement(AC.ElseBody, AFunctions, ADeny);
      end;
    ckFor: CheckTierStatement(AC.LoopBody, AFunctions, ADeny);
    ckWhile, ckUntil:
      begin
        CheckTierStatement(AC.Condition, AFunctions, ADeny);
        CheckTierStatement(AC.LoopBody, AFunctions, ADeny);
      end;
    ckCase:
      for I := 0 to High(AC.CaseItems) do
        CheckTierStatement(AC.CaseItems[I].Body, AFunctions, ADeny);
    ckFunction:
      if AC.FuncBody <> nil then
        CheckTierCommand(AC.FuncBody, AFunctions, ADeny);
  end;
end;

function ScriptInTier(const AScript: TScript; out AWhy: string): Boolean;
var
  Fns: TStringList;
begin
  AWhy := '';
  Fns := TStringList.Create;
  try
    Fns.CaseSensitive := True;
    if AScript <> nil then
    begin
      CollectFunctionsOf(AScript.Root, Fns);
      CheckTierStatement(AScript.Root, Fns, AWhy);
    end;
    Result := AWhy = '';
  finally
    Fns.Free;
  end;
end;

{ True when the tier would run ACommand (parse + whole-script pre-flight).
  Deterministic and side-effect free, so the tool can ask "will you own this?"
  before it builds its own asks. }
function TierSupportsCommand(const ACommand: string; out AWhy: string): Boolean;
var
  S: TScript;
  E: TShellParseError;
begin
  AWhy := '';
  Result := False;
  if not ParseShellScript(ACommand, S, E) then
  begin
    AWhy := Format('parse error at %d:%d: %s', [E.Line, E.Column, E.Message]);
    Exit;
  end;
  try
    Result := ScriptInTier(S, AWhy);
  finally
    S.Free;
  end;
end;

function TBuiltinShell.Preflight(const AScript: TScript): Boolean;
begin
  Result := ScriptInTier(AScript, FDeny);
  if not Result then
    FLastError := FDeny;
end;

function TBuiltinShell.TryRun(const ACommand, ACwd, AReason: string;
  ATimeoutMs: QWord; out AOutput: string; out AExitCode: Integer): Boolean;
var
  S: TScript;
  E: TShellParseError;
  Env, RunEnv: TShellEnv;
  Limits: TShellLimits;
  ErrText: string;
  Shell: TShell;
  D: TShellLimits;
begin
  AOutput := '';
  AExitCode := 0;
  FLastError := '';
  FReason := AReason;
  Result := False;
  if not ParseShellScript(ACommand, S, E) then
  begin
    FLastError := Format('parse error at %d:%d: %s',
      [E.Line, E.Column, E.Message]);
    Exit;
  end;
  try
    if not Preflight(S) then
      Exit;
    D := DefaultShellLimits;
    Limits := D;
    if FConfig.MaxCommands > 0 then
      Limits.MaxCommands := FConfig.MaxCommands;
    if FConfig.MaxLoopIterations > 0 then
      Limits.MaxLoopIterations := FConfig.MaxLoopIterations;
    if FConfig.MaxCallDepth > 0 then
      Limits.MaxCallDepth := FConfig.MaxCallDepth;
    if FConfig.MaxOutputBytes > 0 then
      Limits.MaxOutputBytes := FConfig.MaxOutputBytes;
    if ATimeoutMs > 0 then
      Limits.MaxExecutionTimeMs := Int64(ATimeoutMs);
    Env := TShellEnv.Create;
    try
      Env.SetValue('HOME', FConfig.Root);
      Env.SetValue('PWD', ACwd);
      RunEnv := Env;
      FCmd.Reason := AReason;
      Shell := TShell.Create(FRegistry, FFs, ACwd, Gate, Limits, RunEnv);
      try
        AExitCode := Shell.Run(S, AOutput, ErrText);
      finally
        Shell.Free;
      end;
      if ErrText <> '' then
        AOutput := AOutput + ErrText;
      Result := True;
    finally
      Env.Free;
    end;
  finally
    S.Free;
  end;
end;

end.
