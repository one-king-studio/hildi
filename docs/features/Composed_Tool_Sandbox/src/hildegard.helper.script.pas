unit hildegard.helper.script;
{ The facade over the vendored GocciaScript engine: run ONE model-authored
  script with the harness's tools injected as a single async `tools` object, and
  map the outcome to a structured result. This unit is the only place the engine
  is reached, so an engine upgrade is a facade change.

  Core-only, capability-free (TGocciaCapabilities.None): the script's only
  reachable surface is the injected `tools` object (a view over the harness's
  registry), plus an inert capture-only `console`. Every tools.* call blocks
  inside its native callback until the tool and its approval complete, then
  returns an already-settled promise, so the script sees an ordinary `await`
  (spike path A — no engine change). The engine is recreated per script, so
  intrinsics cannot bleed between scripts. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils;

type
  { Resolves one injected tool call: run the named tool with these JSON
    arguments and the script's reason, returning the tool's text result. False +
    AError on a tool failure or a denial. Called on the engine thread. }
  TScriptToolInvoker = function(const AName, AArgumentsJson,
    AReason: string; out AResult, AError: string): Boolean of object;

  { Consulted before the run and at each injected tool call; True stops the
    script. }
  TScriptCancelCheck = function: Boolean of object;

  TScriptLimits = record
    TimeoutMs: Integer;       // wall-clock; 0 => default
    MaxInstructions: Int64;   // 0 => default
    MaxMemoryBytes: Int64;    // 0 => default
    MaxOutputBytes: Integer;  // 0 => default
  end;

  TScriptResult = record
    Ok: Boolean;
    Output: string;           // captured console output
    Value: string;            // the script's return value, as text
    Error: string;            // '' when Ok
  end;

  TScriptNameArray = array of string;

const
  DefaultScriptTimeoutMs = 30000;
  DefaultScriptMaxInstructions = 50000000;
  DefaultScriptMaxMemoryBytes = 268435456;   // 256 MiB
  DefaultScriptMaxOutputBytes = 32768;

  { The shell stays a separate, first-class call; recall is harness-internal and
    ungated; run_script is this feature's own tool. None is reachable from a
    script. }
  ScriptExcludedToolCount = 3;
  ScriptExcludedTools: array[0..ScriptExcludedToolCount - 1] of string =
    ('run_command', 'recall_tool_result', 'run_script');

{ True when AName may not be exposed to a script. }
function IsScriptExcludedTool(const AName: string): Boolean;
{ The subset of ANames a script may reach (the exclusions removed). }
function FilterScriptTools(const ANames: TScriptNameArray): TScriptNameArray;

{ Run ASource with the injected tools.* dispatcher. Never raises for a guest
  fault (a syntax error, a runtime throw, a limit breach); returns Ok=False with
  Error set. An engine-integrity fault is NOT swallowed: it propagates. }
function RunScript(const ASource, AReason: string;
  const AInvoke: TScriptToolInvoker; const AExposedTools: TScriptNameArray;
  const ALimits: TScriptLimits;
  const ACancel: TScriptCancelCheck = nil): TScriptResult;

implementation

uses
  Contnrs,
  Goccia.Capabilities,
  Goccia.Engine,
  Goccia.Error,
  Goccia.Executor.Interpreter,
  Goccia.GarbageCollector,
  Goccia.InstructionLimit,
  Goccia.JSON,
  Goccia.Scope,
  Goccia.Threading,
  Goccia.Timeout,
  Goccia.Arguments.Collection,
  Goccia.Values.Error,
  Goccia.Values.ErrorHelper,
  Goccia.Values.NativeFunction,
  Goccia.Values.NativeFunctionCallback,
  Goccia.Values.ObjectValue,
  Goccia.Values.Primitives,
  Goccia.Values.PromiseValue;

{ --- limit resolution --------------------------------------------------- }

function ResolveTimeout(const ALimits: TScriptLimits): Integer;
begin
  if ALimits.TimeoutMs > 0 then
    Result := ALimits.TimeoutMs
  else
    Result := DefaultScriptTimeoutMs;
end;

function ResolveMaxInstructions(const ALimits: TScriptLimits): Int64;
begin
  if ALimits.MaxInstructions > 0 then
    Result := ALimits.MaxInstructions
  else
    Result := DefaultScriptMaxInstructions;
end;

function ResolveMaxMemory(const ALimits: TScriptLimits): Int64;
begin
  if ALimits.MaxMemoryBytes > 0 then
    Result := ALimits.MaxMemoryBytes
  else
    Result := DefaultScriptMaxMemoryBytes;
end;

function ResolveMaxOutput(const ALimits: TScriptLimits): Integer;
begin
  if ALimits.MaxOutputBytes > 0 then
    Result := ALimits.MaxOutputBytes
  else
    Result := DefaultScriptMaxOutputBytes;
end;

{ --- tool filter -------------------------------------------------------- }

function IsScriptExcludedTool(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to ScriptExcludedToolCount - 1 do
    if SameText(AName, ScriptExcludedTools[I]) then
      Exit(True);
  Result := False;
end;

function FilterScriptTools(const ANames: TScriptNameArray): TScriptNameArray;
var
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  SetLength(Result, Length(ANames));
  for I := 0 to High(ANames) do
    if (ANames[I] <> '') and not IsScriptExcludedTool(ANames[I]) then
    begin
      Result[N] := ANames[I];
      Inc(N);
    end;
  SetLength(Result, N);
end;

{ --- the per-script host ------------------------------------------------ }

type
  TScriptHost = class;

  { One tools.<name> native method. Holds its own name so the single callback
    shape dispatches to the right tool. }
  TScriptToolMethod = class
  private
    FHost: TScriptHost;
    FName: string;
  public
    constructor Create(AHost: TScriptHost; const AName: string);
    function Invoke(const AArgs: TGocciaArgumentsCollection;
      const AThisValue: TGocciaValue): TGocciaValue;
  end;

  { Per-script host state: the invoker, the script's reason, the cancel check,
    the captured console output, and the live tool-method helpers (which the
    native functions reference but do not own). }
  TScriptHost = class
  private
    FInvoke: TScriptToolInvoker;
    FReason: string;
    FCancel: TScriptCancelCheck;
    FOutput: string;
    FBytes: Integer;
    FMaxOutput: Integer;
    FTruncated: Boolean;
    FMethods: TObjectList;
    FStringifier: TGocciaJSONStringifier;
    procedure AppendOutput(const AText: string);
  public
    constructor Create(AInvoke: TScriptToolInvoker; const AReason: string;
      ACancel: TScriptCancelCheck; AMaxOutput: Integer);
    destructor Destroy; override;
    function Cancelled: Boolean;
    function CapturedOutput: string;
    procedure AddTool(ATools: TGocciaObjectValue; const AName: string);
    function InvokeTool(const AName, AArgsJson: string;
      out AResult, AError: string): Boolean;
    function StringifyArgs(const AValue: TGocciaValue): string;
    function ConsoleWrite(const AArgs: TGocciaArgumentsCollection;
      const AThisValue: TGocciaValue): TGocciaValue;
  end;

{ An already-rejected promise carrying a JS Error with AMessage. }
function RejectedPromise(const AMessage: UnicodeString): TGocciaPromiseValue;
var
  GC: TGarbageCollector;
  ErrObj: TGocciaValue;
begin
  GC := TGarbageCollector.Instance;
  Result := TGocciaPromiseValue.Create;
  if GC <> nil then
    GC.AddTempRoot(Result);
  ErrObj := CreateErrorObject(UnicodeString('Error'), AMessage);
  if GC <> nil then
    GC.AddTempRoot(ErrObj);
  Result.Reject(ErrObj);
  if GC <> nil then
    GC.RemoveTempRoot(ErrObj);
  if GC <> nil then
    GC.RemoveTempRoot(Result);
end;

{ An already-fulfilled promise carrying AText. }
function FulfilledPromise(const AText: UnicodeString): TGocciaPromiseValue;
var
  GC: TGarbageCollector;
  SV: TGocciaStringLiteralValue;
begin
  GC := TGarbageCollector.Instance;
  SV := TGocciaStringLiteralValue.Create(AText);
  if GC <> nil then
    GC.AddTempRoot(SV);
  try
    Result := PromiseResolveIntrinsic(SV);
  finally
    if GC <> nil then
      GC.RemoveTempRoot(SV);
  end;
end;

{ --- TScriptToolMethod -------------------------------------------------- }

constructor TScriptToolMethod.Create(AHost: TScriptHost; const AName: string);
begin
  inherited Create;
  FHost := AHost;
  FName := AName;
end;

function TScriptToolMethod.Invoke(const AArgs: TGocciaArgumentsCollection;
  const AThisValue: TGocciaValue): TGocciaValue;
var
  ArgsJson, Res, Err: string;
begin
  { The callback blocks here — this is where the tool and its approval
    complete (path A). The script's await is a one-microtask no-op. }
  if FHost.Cancelled then
    Exit(RejectedPromise(UnicodeString('script cancelled by the operator')));

  ArgsJson := '{}';
  if AArgs.Length > 0 then
    ArgsJson := FHost.StringifyArgs(AArgs.GetElement(0));

  if FHost.InvokeTool(FName, ArgsJson, Res, Err) then
    Result := FulfilledPromise(UTF8Decode(Res))
  else
    Result := RejectedPromise(UTF8Decode(Err));
end;

{ --- TScriptHost -------------------------------------------------------- }

constructor TScriptHost.Create(AInvoke: TScriptToolInvoker;
  const AReason: string; ACancel: TScriptCancelCheck; AMaxOutput: Integer);
begin
  inherited Create;
  FInvoke := AInvoke;
  FReason := AReason;
  FCancel := ACancel;
  FMaxOutput := AMaxOutput;
  FMethods := TObjectList.Create(True);
  FStringifier := TGocciaJSONStringifier.Create;
end;

destructor TScriptHost.Destroy;
begin
  FStringifier.Free;
  FMethods.Free;
  inherited Destroy;
end;

function TScriptHost.Cancelled: Boolean;
begin
  Result := Assigned(FCancel) and FCancel();
end;

procedure TScriptHost.AppendOutput(const AText: string);
var
  S: string;
begin
  if FTruncated then
    Exit;
  S := AText + LineEnding;
  if (FMaxOutput > 0) and (FBytes + Length(S) > FMaxOutput) then
  begin
    S := Copy(S, 1, FMaxOutput - FBytes);
    FTruncated := True;
  end;
  FOutput := FOutput + S;
  Inc(FBytes, Length(S));
end;

function TScriptHost.CapturedOutput: string;
begin
  Result := FOutput;
  if FTruncated then
    Result := Result + '[console output truncated]';
end;

procedure TScriptHost.AddTool(ATools: TGocciaObjectValue; const AName: string);
var
  M: TScriptToolMethod;
begin
  M := TScriptToolMethod.Create(Self, AName);
  FMethods.Add(M);
  ATools.RegisterNativeMethod(
    TGocciaNativeFunctionValue.CreateWithoutPrototype(M.Invoke, UTF8Decode(AName), 1));
end;

function TScriptHost.InvokeTool(const AName, AArgsJson: string;
  out AResult, AError: string): Boolean;
begin
  AResult := '';
  AError := '';
  if not Assigned(FInvoke) then
  begin
    AError := 'tool "' + AName + '" is not available in a script';
    Exit(False);
  end;
  Result := FInvoke(AName, AArgsJson, FReason, AResult, AError);
end;

function TScriptHost.StringifyArgs(const AValue: TGocciaValue): string;
begin
  try
    Result := UTF8Encode(FStringifier.Stringify(AValue));
  except
    Result := '{}';
  end;
end;

function TScriptHost.ConsoleWrite(const AArgs: TGocciaArgumentsCollection;
  const AThisValue: TGocciaValue): TGocciaValue;
var
  I: Integer;
  Line: UnicodeString;
begin
  Line := '';
  for I := 0 to AArgs.Length - 1 do
  begin
    if I > 0 then
      Line := Line + ' ';
    Line := Line + AArgs.GetElement(I).ToStringLiteral.Value;
  end;
  AppendOutput(UTF8Encode(Line));
  Result := TGocciaUndefinedLiteralValue.UndefinedValue;
end;

{ --- RunScript ---------------------------------------------------------- }

function RunScript(const ASource, AReason: string;
  const AInvoke: TScriptToolInvoker; const AExposedTools: TScriptNameArray;
  const ALimits: TScriptLimits; const ACancel: TScriptCancelCheck): TScriptResult;
var
  Source: TStringList;
  Executor: TGocciaInterpreterExecutor;
  Engine: TGocciaEngine;
  Host: TScriptHost;
  ToolsObj, ConsoleObj: TGocciaObjectValue;
  GC: TGarbageCollector;
  OldMaxBytes: Int64;
  R: TGocciaScriptResult;
  I: Integer;
  UMsg: UnicodeString;
  MaxMem: Int64;
begin
  Result := Default(TScriptResult);
  Result.Ok := False;
  Result.Output := '';
  Result.Value := '';
  Result.Error := '';
  Source := TStringList.Create;
  Executor := nil;
  Engine := nil;
  Host := nil;
  GC := nil;
  OldMaxBytes := 0;
  MaxMem := ResolveMaxMemory(ALimits);
  try
    try
      Source.Text := ASource;
      Executor := TGocciaInterpreterExecutor.Create;
      Engine := TGocciaEngine.Create(UnicodeString('script.ts'), Source,
        Executor, TGocciaCapabilities.None);

      { GocciaScript is strict-subset by default (no `for`/`while`/`function`/
        `var`), which defeats the feature's whole point. Enable the standard-JS
        language surface. Deliberately OFF: cfNonStrictMode (modern ECMAScript
        is always strict; a module-level script should not silently become
        sloppy) and cfExperimentalJSModuleSource (marked experimental). The
        compatibility set widens the LANGUAGE, not the capability surface:
        none of these flags grant host access. Top-level (global) `await` needs
        no flag — the parser allows it at function depth 0 — and TypeScript-style
        type annotations are on by default (the TC39 types-as-comments model);
        the `.ts` file name makes a leading `<` type syntax rather than a JSX
        tag, avoiding the JSX heuristic. }
      Engine.Compatibility := [cfASI, cfVar, cfFunction, cfTraditionalFor,
        cfWhileLoops, cfLooseEquality, cfArgumentsObject, cfLabel, cfForIn];

      Host := TScriptHost.Create(AInvoke, AReason, ACancel,
        ResolveMaxOutput(ALimits));

      { The one injected surface: a `tools` object whose methods are views over
        the registry (each dispatch runs the same gated handler a direct call
        would). }
      ToolsObj := TGocciaObjectValue.Create;
      for I := 0 to High(AExposedTools) do
        Host.AddTool(ToolsObj, AExposedTools[I]);
      Engine.Interpreter.GlobalScope.DefineLexicalBinding(
        UnicodeString('tools'), ToolsObj, dtConst);

      { An inert capture-only console: core-only has no console extension, so we
        provide one whose methods only append to the output buffer (no host
        access). }
      ConsoleObj := TGocciaObjectValue.Create;
      ConsoleObj.RegisterNativeMethod(TGocciaNativeFunctionValue.CreateWithoutPrototype(
        Host.ConsoleWrite, UnicodeString('log'), -1));
      ConsoleObj.RegisterNativeMethod(TGocciaNativeFunctionValue.CreateWithoutPrototype(
        Host.ConsoleWrite, UnicodeString('info'), -1));
      ConsoleObj.RegisterNativeMethod(TGocciaNativeFunctionValue.CreateWithoutPrototype(
        Host.ConsoleWrite, UnicodeString('warn'), -1));
      ConsoleObj.RegisterNativeMethod(TGocciaNativeFunctionValue.CreateWithoutPrototype(
        Host.ConsoleWrite, UnicodeString('error'), -1));
      ConsoleObj.RegisterNativeMethod(TGocciaNativeFunctionValue.CreateWithoutPrototype(
        Host.ConsoleWrite, UnicodeString('debug'), -1));
      Engine.Interpreter.GlobalScope.DefineLexicalBinding(
        UnicodeString('console'), ConsoleObj, dtConst);

      { Memory cap: bound the script's heap for the run, then restore. }
      GC := TGarbageCollector.Instance;
      if (GC <> nil) and (MaxMem > 0) then
      begin
        OldMaxBytes := GC.MaxBytes;
        GC.MaxBytes := MaxMem;
      end;

      if Host.Cancelled then
      begin
        Result.Error := 'script cancelled by the operator';
        Exit;
      end;

      StartExecutionTimeout(ResolveTimeout(ALimits));
      StartInstructionLimit(ResolveMaxInstructions(ALimits));
      try
        R := Engine.Execute;
        if R.Result <> nil then
          Result.Value := UTF8Encode(R.Result.ToStringLiteral.Value);
        Result.Ok := True;
      finally
        ClearInstructionLimit;
        ClearExecutionTimeout;
      end;
    except
      on E: TGocciaTimeoutError do
        Result.Error := 'script timed out';
      on E: TGocciaInstructionLimitError do
        Result.Error := 'script exceeded the instruction limit';
      on E: TGocciaSyntaxError do
        Result.Error := 'syntax error: ' + E.Message;
      on E: TGocciaRuntimeError do
        Result.Error := 'script error: ' + E.Message;
      on E: TGocciaThrowValue do
      begin
        UMsg := '';
        if E.Value <> nil then
          UMsg := E.Value.ToStringLiteral.Value;
        Result.Error := UTF8Encode(UMsg);
      end;
      { Engine-integrity faults (EObjectCheck, EAccessViolation, ...) are
        deliberately NOT caught: they propagate to the caller. }
    end;
  finally
    ClearInstructionLimit;
    ClearExecutionTimeout;
    if (GC <> nil) and (MaxMem > 0) then
      GC.MaxBytes := OldMaxBytes;
    if Host <> nil then
      Result.Output := Host.CapturedOutput;
    Host.Free;
    Engine.Free;
    Executor.Free;
    Source.Free;
    { The engine's realm pins its intrinsic prototype graph and only unpins it
      on destruction; nothing collects afterwards, so a fresh realm's graph
      would survive each run. One collect per run releases it. }
    if GC <> nil then
      GC.Collect;
  end;
end;

finalization
  { Release the engine's per-thread caches (member-definition arrays, timezone,
    regex, semver hosts, ...) that survive as process-lifetime threadvar state.
    This is the engine's documented main-thread teardown; it must run once, at
    process exit, not per script (per-script calls free state still in use). }
  ShutdownThreadRuntime;
end.
