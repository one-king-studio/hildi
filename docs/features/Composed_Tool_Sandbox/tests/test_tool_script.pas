unit test_tool_script;
{ fpcunit tests for hildi.tool.script: the run_script tool. A real
  TToolRegistry with the file tool and the script tool, a fake approval service
  that records the asks, and a temporary workspace. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildi.llm, hildi.agent, hildi.approval,
  hildi.workspace, hildi.files, hildi.script,
  hildi.tool.script;

type
  { Records every ask it resolves; Allow toggles allow vs deny. }
  TFakeApproval = class(TInterfacedObject, IApprovalService)
  public
    Allow: Boolean;
    Calls: Integer;
    Refs: TStringArray;
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

  TToolScriptTest = class(TTestCase)
  private
    FDir: string;
    FApproval: TFakeApproval;
    FTools: TToolRegistry;
    FFileTool: TFileTool;
    FScriptTool: TScriptTool;
    function Full(const ARel: string): string;
    procedure WriteRaw(const ARel, AText: string);
    function RunTool(const AArgs: string;
      out AResult, AError: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRegistersWithRequiredReason;
    procedure TestMissingReasonFailsBeforeTheEngine;
    procedure TestPureComputeScriptReturnsValue;
    procedure TestScriptGateResolvedBeforeTheEngine;
    procedure TestDeniedScriptGateRunsNothing;
    procedure TestScriptCallsFileToolThroughTheGate;
  end;

implementation

{ TFakeApproval }

function TFakeApproval.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
var
  I: Integer;
begin
  Inc(Calls);
  for I := 0 to High(AAsks) do
  begin
    SetLength(Refs, Length(Refs) + 1);
    Refs[High(Refs)] := AAsks[I].Subject.Ref;
  end;
  AResult := Default(TApprovalBatchResult);
  if Allow then
    AResult.Allowed := True
  else
  begin
    AResult.Denied := True;
    AResult.Reason := 'denied by test';
  end;
  Result := True;
end;

procedure TToolScriptTest.SetUp;
var
  FileCfg: TFileToolConfig;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-scripttool-' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  ForceDirectories(FDir);
  FApproval := TFakeApproval.Create;
  FApproval.Allow := True;

  FileCfg := Default(TFileToolConfig);
  FileCfg.Root := FDir;
  FFileTool := TFileTool.Create(FileCfg, FApproval);

  FTools := TToolRegistry.Create;
  FFileTool.Register(FTools);

  FScriptTool := TScriptTool.Create(FTools, FApproval);
  FScriptTool.Register(FTools);
end;

procedure TToolScriptTest.TearDown;
begin
  FScriptTool.Free;
  FFileTool.Free;
  FTools.Free;
  RemoveDir(FDir);
end;

function TToolScriptTest.Full(const ARel: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + ARel;
end;

procedure TToolScriptTest.WriteRaw(const ARel, AText: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := AText;
    L.SaveToFile(Full(ARel));
  finally
    L.Free;
  end;
end;

function TToolScriptTest.RunTool(const AArgs: string;
  out AResult, AError: string): Boolean;
begin
  Result := FScriptTool.Run(AArgs, AResult, AError);
end;

procedure TToolScriptTest.TestRegistersWithRequiredReason;
var
  Stored: TRegisteredTool;
begin
  AssertTrue('registered', FTools.Find('run_script', Stored));
  AssertTrue('reason required',
    Pos('"reason"', Stored.Spec.ParametersJson) > 0);
  AssertTrue('mentions script',
    Pos('"script"', Stored.Spec.ParametersJson) > 0);
end;

procedure TToolScriptTest.TestMissingReasonFailsBeforeTheEngine;
var
  Res, Err: string;
begin
  AssertFalse('fails', RunTool('{"script":"1+1;"}', Res, Err));
  AssertTrue('names the reason', Pos('reason', LowerCase(Err)) > 0);
  AssertEquals('no approval was asked', 0, FApproval.Calls);
end;

procedure TToolScriptTest.TestPureComputeScriptReturnsValue;
var
  Res, Err: string;
begin
  AssertTrue('ok', RunTool('{"script":"1 + 2;","reason":"compute"}', Res, Err));
  AssertTrue('result carries the value', Pos('3', Res) > 0);
  AssertEquals('one ask: the script gate', 1, FApproval.Calls);
  AssertEquals('the gate ref', 'script:run', FApproval.Refs[0]);
end;

procedure TToolScriptTest.TestScriptGateResolvedBeforeTheEngine;
var
  Res, Err: string;
begin
  { A syntactically broken script still asks the gate first: the gate is the
    boundary, resolved before the engine runs. }
  AssertFalse('fails', RunTool('{"script":"this is not js ###","reason":"r"}',
    Res, Err));
  AssertEquals('the gate was asked', 1, FApproval.Calls);
  AssertEquals('the gate ref', 'script:run', FApproval.Refs[0]);
end;

procedure TToolScriptTest.TestDeniedScriptGateRunsNothing;
var
  Res, Err: string;
begin
  FApproval.Allow := False;
  WriteRaw('a.txt', 'alpha');
  AssertFalse('denied', RunTool(
    '{"script":"await tools.file_read({path:\"a.txt\"}); 1;","reason":"r"}',
    Res, Err));
  AssertEquals('only the gate ask', 1, FApproval.Calls);
  AssertEquals('no file read ask', 'script:run', FApproval.Refs[0]);
end;

procedure TToolScriptTest.TestScriptCallsFileToolThroughTheGate;
var
  Res, Err: string;
begin
  WriteRaw('a.txt', 'alpha'#10'beta');
  AssertTrue('ok', RunTool(
    '{"script":"const r = await tools.file_read({path:\"a.txt\"}); ' +
    'r.includes(\"beta\") ? \"FOUND\" : \"MISSING\";","reason":"batch read"}',
    Res, Err));
  AssertTrue('the file tool ran', Pos('FOUND', Res) > 0);
  AssertEquals('two asks: script gate + file read', 2, FApproval.Calls);
  AssertEquals('gate first', 'script:run', FApproval.Refs[0]);
  AssertEquals('file read second', 'file:read', FApproval.Refs[1]);
end;

initialization
  RegisterTest(TToolScriptTest);
end.
