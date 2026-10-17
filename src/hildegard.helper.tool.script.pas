unit hildegard.helper.tool.script;
{ The run_script tool: parse its arguments, gate the call as `script:run`, then
  hand the script to the facade with the registry's tools injected. Each
  injected tools.* call dispatches through the same registry — the same gated
  handler a direct call uses — with the script's reason. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.script;

type
  TScriptTool = class(TInterfacedObject)
  private
    FTools: TToolRegistry;
    FService: IApprovalService;
    FCancelCheck: TScriptCancelCheck;
    FScriptName: string;
    { Resolve one sub-call through the registry, with the script's reason. }
    function Invoke(const AName, AArgumentsJson, AReason: string;
      out AResult, AError: string): Boolean;
    { The registry's exposed tool names (exclusions removed). }
    function ExposedToolNames: TScriptNameArray;
    { Resolve the `script:run` ask. False + AError on denial. }
    function Approve(const AReason: string; out AError: string): Boolean;
  public
    constructor Create(ATools: TToolRegistry; AService: IApprovalService);
    { The turn's cancel check, so a cancelled turn stops a running script. }
    property CancelCheck: TScriptCancelCheck read FCancelCheck
      write FCancelCheck;
    { Registers run_script. }
    procedure Register(ATools: TToolRegistry);
    { Matches TToolHandler; public for direct testing. }
    function Run(const AArgumentsJson: string; out AResult: string;
      out AError: string; AObserver: TToolObserver = nil): Boolean;
  end;

const
  ScriptToolName = 'run_script';

implementation

constructor TScriptTool.Create(ATools: TToolRegistry; AService: IApprovalService);
begin
  inherited Create;
  FTools := ATools;
  FService := AService;
  FScriptName := ScriptToolName;
end;

procedure TScriptTool.Register(ATools: TToolRegistry);
var
  Spec: TToolSpec;
begin
  Spec.Name := ScriptToolName;
  Spec.Description :=
    'Run one JavaScript program that can call this harness''s own tools as ' +
    'async functions on a global `tools` object: ' +
    '`await tools.file_read({path: "a.ps", reason: "r"})`. Every call routes ' +
    'through the same approval gate, reason requirement, and audit row as a ' +
    'direct call, so a loop over many files is ONE tool call while each file ' +
    'is still approved. Standard JavaScript is available (loops, functions, ' +
    'top-level await, TypeScript-style type annotations); the shell is NOT ' +
    'reachable from a script. Requires a short reason (the script''s, which ' +
    'flows to every sub-call). Gated by approval as script:run.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"script":{"type":"string","description":"The JavaScript program to run."},' +
    '"reason":{"type":"string","description":"Short reason this script is needed."}' +
    '},"required":["script","reason"]}';
  ATools.Add(Spec, Run);
end;

function TScriptTool.Approve(const AReason: string;
  out AError: string): Boolean;
var
  Ask: TApprovalAsk;
  Asks: TApprovalAskArray;
  Batch: TApprovalBatchResult;
begin
  AError := '';
  if FService = nil then
    Exit(True);                 // no gate wired: allowed (a test or a bare run)
  Ask := Default(TApprovalAsk);
  Ask.Summary := 'run a script';
  Ask.Reason := AReason;
  Ask.Subject.Ref := 'script:run';
  SetLength(Ask.Options, 1);
  Ask.Options[0] := Default(TApprovalOption);
  Ask.Options[0].Key := 'once';
  Ask.Options[0].Caption := 'allow this script';
  Ask.Options[0].Persists := False;
  Ask.Options[0].Rule := DefaultApprovalRule(aeAllow);
  Ask.Options[0].Rule.Ref := 'script:run';
  SetLength(Asks, 1);
  Asks[0] := Ask;
  Batch := Default(TApprovalBatchResult);
  if not FService.Resolve(Asks, Batch) then
  begin
    AError := 'approval service failed';
    Exit(False);
  end;
  if Batch.Denied then
  begin
    if Batch.Reason <> '' then
      AError := 'script:run denied: ' + Batch.Reason
    else
      AError := 'script:run denied';
    Exit(False);
  end;
  Result := True;
end;

function TScriptTool.ExposedToolNames: TScriptNameArray;
var
  Specs: TToolSpecArray;
  All: TScriptNameArray;
  I: Integer;
begin
  Result := nil;
  if FTools = nil then
    Exit;
  Specs := FTools.Specs;
  SetLength(All, Length(Specs));
  for I := 0 to High(Specs) do
    All[I] := Specs[I].Name;
  Result := FilterScriptTools(All);
end;

function TScriptTool.Invoke(const AName, AArgumentsJson, AReason: string;
  out AResult, AError: string): Boolean;
var
  Tool: TRegisteredTool;
  Reason, ReasonError, Augmented: string;
  Root: TJSONObject;
  Data: TJSONData;
begin
  AResult := '';
  AError := '';
  if (FTools = nil) or not FTools.Find(AName, Tool) then
  begin
    AError := 'tool "' + AName + '" is not available in a script';
    Exit(False);
  end;
  { The tool's handler requires a reason in its arguments. The script's reason
    is authoritative, so overlay it onto the arguments the script passed (and
    add it if the script omitted it). }
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      Data := nil;
    end;
    if Data is TJSONObject then
      Root := TJSONObject(Data)
    else
    begin
      Data.Free;
      Data := TJSONObject.Create;
      Root := TJSONObject(Data);
    end;
    Root.Delete('reason');
    Root.Add('reason', AReason);
    Augmented := Root.AsJSON;
  finally
    Data.Free;
  end;
  { A malformed reason would be rejected by the handler; our reason is valid by
    construction, so this only guards the unexpected. }
  if not ExtractToolReason(Augmented, Reason, ReasonError) then
  begin
    AError := ReasonError;
    Exit(False);
  end;
  try
    Result := Tool.Handler(Augmented, AResult, AError, nil);
  except
    on E: Exception do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

function TScriptTool.Run(const AArgumentsJson: string; out AResult: string;
  out AError: string; AObserver: TToolObserver): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  V: TJSONData;
  ScriptText, Reason, ReasonError: string;
  Limits: TScriptLimits;
  SR: TScriptResult;
begin
  AResult := '';
  AError := '';
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      AError := 'invalid arguments JSON';
      Exit(False);
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit(False);
    end;
    Root := TJSONObject(Data);

    V := Root.Find('script');
    if (V = nil) or (V.JSONType <> jtString) then
    begin
      AError := 'missing required "script"';
      Exit(False);
    end;
    ScriptText := V.AsString;

    if not ExtractToolReason(AArgumentsJson, Reason, ReasonError) then
    begin
      AError := ReasonError;
      Exit(False);
    end;

    { The gate is the boundary: resolve it before the engine ever runs. }
    if not Approve(Reason, AError) then
      Exit(False);

    Limits := Default(TScriptLimits);
    SR := RunScript(ScriptText, Reason, Invoke, ExposedToolNames, Limits,
      FCancelCheck);
    if not SR.Ok then
    begin
      AError := SR.Error;
      Exit(False);
    end;

    { Return the script's value and any captured console output. }
    AResult := SR.Value;
    if SR.Output <> '' then
    begin
      if AResult <> '' then
        AResult := AResult + LineEnding + LineEnding;
      AResult := AResult + '[console output]' + LineEnding + SR.Output;
    end;
    Result := True;
  finally
    Data.Free;
  end;
end;

end.
