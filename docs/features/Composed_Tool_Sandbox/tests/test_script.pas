unit test_script;
{ fpcunit tests for hildi.script: the facade over the vendored
  GocciaScript engine. Pure-compute, console capture, error mapping, the
  injected async tools object, the limits, and the excluded tools. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  HildiLLM, HildiAgent, hildi.script;

type
  { Records each injected call; Allow toggles fulfilment vs rejection. }
  TFakeInvoker = class
  public
    Calls: Integer;
    LastName, LastArgs, LastReason: string;
    Allow: Boolean;
    Reply: string;
    constructor Create;
    function Invoke(const AName, AArgumentsJson, AReason: string;
      out AResult, AError: string): Boolean;
    { Matches TToolHandler, for registering in a real TToolRegistry. }
    function Handle(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;

  { True after N calls, so a runaway script is stopped deterministically. }
  TCancelAfter = class
  public
    Remaining: Integer;
    function Check: Boolean;
  end;

  TScriptTest = class(TTestCase)
  private
    FInvoker: TFakeInvoker;
    function Names: TScriptNameArray;
    function Limits(ATimeoutMs: Integer; AMaxInstr: Int64): TScriptLimits;
    function RunIt(const ASource: string; const AReason: string): TScriptResult;
    function RunWith(const ASource: string; AInvoke: TScriptToolInvoker;
      const ALimits: TScriptLimits;
      ACancel: TScriptCancelCheck = nil): TScriptResult;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestPureComputeReturnsValue;
    procedure TestConsoleOutputCaptured;
    procedure TestSyntaxErrorIsOkFalse;
    procedure TestRuntimeErrorIsOkFalse;
    procedure TestInjectedCallReachesInvoker;
    procedure TestInjectedResultVisibleToScript;
    procedure TestDeniedCallIsCatchable;
    procedure TestInstructionCapStopsRunaway;
    procedure TestTimeoutStopsRunaway;
    procedure TestCancelStopsRunaway;
    procedure TestExcludedToolsAreAbsent;
    procedure TestFilterScriptTools;
    procedure TestModernJavaScriptSurface;
    procedure TestTopLevelAwait;
    procedure TestTypeAnnotations;
    procedure TestRegisteredToolIsExposedAndGated;
  end;

implementation

constructor TFakeInvoker.Create;
begin
  inherited Create;
  Allow := True;
  Reply := 'TOOL-OK';
end;

function TFakeInvoker.Invoke(const AName, AArgumentsJson, AReason: string;
  out AResult, AError: string): Boolean;
begin
  Inc(Calls);
  LastName := AName;
  LastArgs := AArgumentsJson;
  LastReason := AReason;
  if Allow then
  begin
    AResult := Reply;
    AError := '';
    Result := True;
  end
  else
  begin
    AResult := '';
    AError := 'denied by test';
    Result := False;
  end;
end;

function TFakeInvoker.Handle(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver): Boolean;
begin
  Result := Invoke('file_read', AArgumentsJson, 'r', AResult, AError);
end;

function TCancelAfter.Check: Boolean;
begin
  Dec(Remaining);
  Result := Remaining < 0;
end;

procedure TScriptTest.SetUp;
begin
  FInvoker := TFakeInvoker.Create;
end;

procedure TScriptTest.TearDown;
begin
  FInvoker.Free;
end;

function TScriptTest.Names: TScriptNameArray;
begin
  Result := nil;
  SetLength(Result, 3);
  Result[0] := 'file_read';
  Result[1] := 'run_command';
  Result[2] := 'recall_tool_result';
  Result := FilterScriptTools(Result);
end;

function TScriptTest.Limits(ATimeoutMs: Integer;
  AMaxInstr: Int64): TScriptLimits;
begin
  Result := Default(TScriptLimits);
  Result.TimeoutMs := ATimeoutMs;
  Result.MaxInstructions := AMaxInstr;
end;

function TScriptTest.RunWith(const ASource: string;
  AInvoke: TScriptToolInvoker; const ALimits: TScriptLimits;
  ACancel: TScriptCancelCheck): TScriptResult;
begin
  Result := RunScript(ASource, 'test reason', AInvoke, Names, ALimits, ACancel);
end;

function TScriptTest.RunIt(const ASource: string;
  const AReason: string): TScriptResult;
begin
  Result := RunScript(ASource, AReason, FInvoker.Invoke, Names,
    Default(TScriptLimits));
end;

procedure TScriptTest.TestPureComputeReturnsValue;
var
  R: TScriptResult;
begin
  R := RunIt('let t = 0; for (const i of [1,2,3,4,5]) { t += i; } t;', 'sum');
  AssertTrue('ok', R.Ok);
  AssertEquals('value', '15', R.Value);
  AssertEquals('no error', '', R.Error);
end;

procedure TScriptTest.TestConsoleOutputCaptured;
var
  R: TScriptResult;
begin
  R := RunIt('console.log("hello"); console.log("world"); 1;', 'log');
  AssertTrue('ok', R.Ok);
  AssertTrue('captures first line', Pos('hello', R.Output) > 0);
  AssertTrue('captures second line', Pos('world', R.Output) > 0);
end;

procedure TScriptTest.TestSyntaxErrorIsOkFalse;
var
  R: TScriptResult;
begin
  R := RunIt('this is not valid javascript ###', 'bad');
  AssertFalse('not ok', R.Ok);
  AssertTrue('names a syntax error', Pos('syntax', LowerCase(R.Error)) > 0);
end;

procedure TScriptTest.TestRuntimeErrorIsOkFalse;
var
  R: TScriptResult;
begin
  R := RunIt('throw new Error("boom");', 'throw');
  AssertFalse('not ok', R.Ok);
  AssertTrue('carries the message', Pos('boom', R.Error) > 0);
end;

procedure TScriptTest.TestInjectedCallReachesInvoker;
var
  R: TScriptResult;
begin
  R := RunIt('await tools.file_read({path: "x.pas", reason: "r"}); 1;', 'read');
  AssertTrue('ok', R.Ok);
  AssertEquals('one call', 1, FInvoker.Calls);
  AssertEquals('name', 'file_read', FInvoker.LastName);
  AssertTrue('args carry the path', Pos('x.pas', FInvoker.LastArgs) > 0);
  AssertEquals('reason threaded', 'read', FInvoker.LastReason);
end;

procedure TScriptTest.TestInjectedResultVisibleToScript;
var
  R: TScriptResult;
begin
  FInvoker.Reply := 'FILE-CONTENT';
  R := RunIt('const a = await tools.file_read({path: "x"}); a;', 'read');
  AssertTrue('ok', R.Ok);
  AssertEquals('result visible', 'FILE-CONTENT', R.Value);
end;

procedure TScriptTest.TestDeniedCallIsCatchable;
var
  R: TScriptResult;
begin
  FInvoker.Allow := False;
  R := RunIt('try { await tools.file_read({path: "x"}); "no"; } ' +
    'catch (e) { "caught: " + e.message; }', 'deny');
  AssertTrue('ok', R.Ok);
  AssertTrue('caught the denial', Pos('caught', R.Value) > 0);
  AssertTrue('names the denial', Pos('denied', R.Value) > 0);
end;

procedure TScriptTest.TestInstructionCapStopsRunaway;
var
  R: TScriptResult;
begin
  R := RunWith('while (true) {}', FInvoker.Invoke,
    Limits(60000, 200000));
  AssertFalse('not ok', R.Ok);
  AssertTrue('names the instruction limit',
    Pos('instruction', LowerCase(R.Error)) > 0);
end;

procedure TScriptTest.TestTimeoutStopsRunaway;
var
  R: TScriptResult;
begin
  R := RunWith('while (true) {}', FInvoker.Invoke,
    Limits(300, 0));
  AssertFalse('not ok', R.Ok);
  AssertTrue('names the timeout', Pos('timed out', LowerCase(R.Error)) > 0);
end;

procedure TScriptTest.TestCancelStopsRunaway;
var
  C: TCancelAfter;
  R: TScriptResult;
begin
  C := TCancelAfter.Create;
  try
    C.Remaining := 0;   // cancelled on the very first check
    R := RunWith('await tools.file_read({path: "x"}); 1;',
      FInvoker.Invoke, Default(TScriptLimits), C.Check);
    AssertFalse('not ok', R.Ok);
    AssertTrue('names the cancel', Pos('cancel', LowerCase(R.Error)) > 0);
    AssertEquals('never reached the tool', 0, FInvoker.Calls);
  finally
    C.Free;
  end;
end;

procedure TScriptTest.TestExcludedToolsAreAbsent;
var
  R: TScriptResult;
begin
  R := RunIt('typeof tools.run_command === "undefined" && ' +
    'typeof tools.recall_tool_result === "undefined" && ' +
    'typeof tools.file_read === "function";', 'probe');
  AssertTrue('ok', R.Ok);
  AssertEquals('excluded absent, allowed present', 'true', R.Value);
end;

procedure TScriptTest.TestFilterScriptTools;
var
  N: TScriptNameArray;
begin
  N := FilterScriptTools(Names);
  AssertEquals('one survives', 1, Length(N));
  AssertEquals('the file tool', 'file_read', N[0]);
  AssertTrue('excluded', IsScriptExcludedTool('run_command'));
  AssertTrue('excluded', IsScriptExcludedTool('recall_tool_result'));
  AssertFalse('not excluded', IsScriptExcludedTool('file_read'));
end;

procedure TScriptTest.TestModernJavaScriptSurface;
var
  R: TScriptResult;
begin
  R := RunIt('let s=0; for (let i=0;i<5;i++){s+=i;} s;', 'for');
  AssertTrue('for ok', R.Ok);
  AssertEquals('for sum', '10', R.Value);
  R := RunIt('let i=0; while(i<3){i++;} i;', 'while');
  AssertTrue('while ok', R.Ok);
  AssertEquals('while count', '3', R.Value);
  R := RunIt('function add(a,b){return a+b;} add(2,3);', 'fn');
  AssertTrue('function ok', R.Ok);
  AssertEquals('function result', '5', R.Value);
  R := RunIt('var x = 7; x;', 'var');
  AssertTrue('var ok', R.Ok);
  AssertEquals('var result', '7', R.Value);
end;

procedure TScriptTest.TestTopLevelAwait;
var
  R: TScriptResult;
begin
  R := RunIt('let t = await Promise.resolve(41); t + 1;', 'tla');
  AssertTrue('ok', R.Ok);
  AssertEquals('resolved', '42', R.Value);
end;

procedure TScriptTest.TestTypeAnnotations;
var
  R: TScriptResult;
begin
  R := RunIt('const x: number = 5; function f(n: number): number ' +
    '{ return n * 2; } f(x);', 'ts');
  AssertTrue('ok', R.Ok);
  AssertEquals('annotations are types-as-comments', '10', R.Value);
end;

procedure TScriptTest.TestRegisteredToolIsExposedAndGated;
var
  Tools: TToolRegistry;
  Specs: TToolSpecArray;
  AllNames, Names2: TScriptNameArray;
  Stored: TRegisteredTool;
  Spec: TToolSpec;
  I: Integer;
  R: TScriptResult;
begin
  { A real registry: the script must be able to call a registered tool and be
    unable to call the shell, proving the tools object is a view over it. }
  Tools := TToolRegistry.Create;
  try
    RegisterDefaultTools(Tools);
    Spec.Name := 'file_read';
    Spec.Description := 'read';
    Spec.ParametersJson := '{"type":"object","properties":{},' +
      '"required":["reason"]}';
    Tools.Add(Spec, FInvoker.Handle);
    Spec.Name := 'run_command';
    Spec.Description := 'shell';
    Spec.ParametersJson := '{"type":"object","properties":{},' +
      '"required":["reason"]}';
    Tools.Add(Spec, FInvoker.Handle);

    Specs := Tools.Specs;
    SetLength(AllNames, Length(Specs));
    for I := 0 to High(Specs) do
      AllNames[I] := Specs[I].Name;
    Names2 := FilterScriptTools(AllNames);
    AssertTrue('shell is registered', Tools.Find('run_command', Stored));
    AssertTrue('shell not exposed', Length(Names2) < Length(AllNames));
    FInvoker.Reply := 'OK';
    R := RunScript('typeof tools.file_read === "function" && ' +
      'typeof tools.run_command === "undefined";', 'probe',
      FInvoker.Invoke, Names2, Default(TScriptLimits));
    AssertTrue('ok', R.Ok);
    AssertEquals('file tool reachable, shell not', 'true', R.Value);
  finally
    Tools.Free;
  end;
end;

initialization
  RegisterTest(TScriptTest);
end.
