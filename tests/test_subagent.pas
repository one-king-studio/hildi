unit test_subagent;
{ fpcunit tests for the delegation tools (hildegard.helper.subagent): the four
  tool specs, required-reason enforcement, argument parsing, the approval ask
  shape (subagent:<verb> refs, default ask), and the immediate delegate result
  carrying the child session id and the parent's remaining capacity. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.agent, hildegard.helper.llm, hildegard.helper.approval,
  hildegard.helper.subagent;

type
  TFakeApproval = class(TInterfacedObject, IApprovalService)
  public
    Allow: Boolean;
    Calls: Integer;
    LastRef: string;
    LastSummary: string;
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

  { Records the last call and returns canned results. }
  TFakeService = class(TInterfacedObject, ISubagentService)
  public
    DelegateOk: Boolean;
    DelegateId: string;
    Available: Integer;
    Max: Integer;
    LastTask: string;
    LastContext: string;
    LastLabel: string;
    LastMessageId: string;
    LastMessageText: string;
    LastAbortId: string;
    LastReleaseId: string;
    function Delegate(const ATask, AContext, ALabel: string;
      out AResult: TSubagentSpawnResult): Boolean;
    function Message(const ASessionId, AText: string;
      out AError: string): Boolean;
    function Abort(const ASessionId: string; out AError: string): Boolean;
    function Release(const ASessionId: string; out AError: string): Boolean;
    function Status(const ASessionId: string): string;
  end;

  TSubagentToolTest = class(TTestCase)
  private
    FService: TFakeService;
    FApproval: TFakeApproval;
    FTools: TSubagentToolSet;
    function Args(const APairs: array of string): string;
    function MakeTool(AVerb: TSubagentVerb): TSubagentTool;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestDelegateTaskSpec;
    procedure TestMessageAbortReleaseSpecs;
    procedure TestDelegateReturnsSessionAndCapacity;
    procedure TestDelegatePassesTaskContextLabel;
    procedure TestDelegateRequiresTask;
    procedure TestMessageRequiresSessionAndMessage;
    procedure TestAbortAndReleaseCallService;
    procedure TestUnknownChildIdErrors;
    procedure TestApprovalAskShape;
    procedure TestDelegateDeniedReturnsError;
    procedure TestRegisterAdvertisesFourTools;
    procedure TestReasonIsCarriedIntoTheAsk;
  end;

implementation

{ TFakeApproval }

function TFakeApproval.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
begin
  Inc(Calls);
  AResult := Default(TApprovalBatchResult);
  if Length(AAsks) > 0 then
  begin
    LastRef := AAsks[0].Subject.Ref;
    LastSummary := AAsks[0].Summary;
  end;
  if Allow then
    AResult.Allowed := True
  else
  begin
    AResult.Denied := True;
    AResult.Reason := 'denied by policy';
  end;
  Result := True;
end;

{ TFakeService }

function TFakeService.Delegate(const ATask, AContext, ALabel: string;
  out AResult: TSubagentSpawnResult): Boolean;
begin
  LastTask := ATask;
  LastContext := AContext;
  LastLabel := ALabel;
  AResult := Default(TSubagentSpawnResult);
  Result := DelegateOk;
  if not DelegateOk then
  begin
    AResult.Error := 'capacity exhausted';
    Exit;
  end;
  AResult.Ok := True;
  AResult.SessionId := DelegateId;
  AResult.LabelText := ALabel;
  AResult.Available := Available;
  AResult.Max := Max;
end;

function TFakeService.Message(const ASessionId, AText: string;
  out AError: string): Boolean;
begin
  AError := '';
  LastMessageId := ASessionId;
  LastMessageText := AText;
  Result := True;
end;

function TFakeService.Abort(const ASessionId: string;
  out AError: string): Boolean;
begin
  AError := '';
  LastAbortId := ASessionId;
  Result := True;
end;

function TFakeService.Release(const ASessionId: string;
  out AError: string): Boolean;
begin
  AError := '';
  LastReleaseId := ASessionId;
  Result := True;
end;

function TFakeService.Status(const ASessionId: string): string;
begin
  Result := 'running';
end;

{ TSubagentToolTest }

procedure TSubagentToolTest.SetUp;
begin
  FService := TFakeService.Create;
  FService.DelegateOk := True;
  FService.DelegateId := 'child-123';
  FService.Available := 9;
  FService.Max := 10;
  FApproval := TFakeApproval.Create;
  FApproval.Allow := True;
  FTools := TSubagentToolSet.Create(FService, FApproval);
end;

procedure TSubagentToolTest.TearDown;
begin
  FTools.Free;
  FApproval := nil;
  FService := nil;
end;

function TSubagentToolTest.Args(const APairs: array of string): string;
var
  I: Integer;
  S: string;
begin
  S := '{';
  I := 0;
  while I < Length(APairs) do
  begin
    if I > 0 then
      S := S + ',';
    S := S + '"' + APairs[I] + '":"' + APairs[I + 1] + '"';
    Inc(I, 2);
  end;
  S := S + '}';
  Result := S;
end;

function TSubagentToolTest.MakeTool(AVerb: TSubagentVerb): TSubagentTool;
begin
  Result := TSubagentTool.Create(AVerb, FService, FApproval);
end;

procedure TSubagentToolTest.TestDelegateTaskSpec;
var
  Tool: TSubagentTool;
  Asks: TApprovalAskArray;
begin
  Tool := MakeTool(svDelegate);
  try
    Asks := Tool.ApprovalAsks(Args(['task', 'do a thing', 'context', 'ctx',
      'label', 'research', 'reason', 'because']));
    AssertEquals('one ask', 1, Length(Asks));
    AssertEquals('ref', 'subagent:delegate_task', Asks[0].Subject.Ref);
    AssertEquals('summary is the label', 'research', Asks[0].Summary);
  finally
    Tool.Free;
  end;
end;

procedure TSubagentToolTest.TestMessageAbortReleaseSpecs;
var
  Tool: TSubagentTool;
  Asks: TApprovalAskArray;
begin
  Tool := MakeTool(svMessage);
  try
    Asks := Tool.ApprovalAsks(Args(['session_id', 'child-1', 'message', 'hi',
      'reason', 'r']));
    AssertEquals('message ref', 'subagent:message_task', Asks[0].Subject.Ref);
  finally
    Tool.Free;
  end;
  Tool := MakeTool(svAbort);
  try
    Asks := Tool.ApprovalAsks(Args(['session_id', 'child-1', 'reason', 'r']));
    AssertEquals('abort ref', 'subagent:abort_task', Asks[0].Subject.Ref);
  finally
    Tool.Free;
  end;
  Tool := MakeTool(svRelease);
  try
    Asks := Tool.ApprovalAsks(Args(['session_id', 'child-1', 'reason', 'r']));
    AssertEquals('release ref', 'subagent:release_task', Asks[0].Subject.Ref);
  finally
    Tool.Free;
  end;
end;

procedure TSubagentToolTest.TestDelegateReturnsSessionAndCapacity;
var
  Tool: TSubagentTool;
  Res, Err: string;
begin
  Tool := MakeTool(svDelegate);
  try
    AssertTrue('run ok', Tool.Run(Args(['task', 'do', 'context', 'c',
      'label', 'research', 'reason', 'why']), Res, Err));
    AssertTrue('names the child', Pos('child-123', Res) > 0);
    AssertTrue('reports capacity', Pos('9 of 10', Res) > 0);
    AssertTrue('mentions follow-up', Pos('message_task', Res) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TSubagentToolTest.TestDelegatePassesTaskContextLabel;
var
  Tool: TSubagentTool;
  Res, Err: string;
begin
  Tool := MakeTool(svDelegate);
  try
    Tool.Run(Args(['task', 'the task', 'context', 'the context',
      'label', 'the label', 'reason', 'why']), Res, Err);
    AssertEquals('task', 'the task', FService.LastTask);
    AssertEquals('context', 'the context', FService.LastContext);
    AssertEquals('label', 'the label', FService.LastLabel);
  finally
    Tool.Free;
  end;
end;

procedure TSubagentToolTest.TestDelegateRequiresTask;
var
  Tool: TSubagentTool;
  Res, Err: string;
begin
  Tool := MakeTool(svDelegate);
  try
    AssertFalse('no task fails',
      Tool.Run(Args(['context', 'c', 'reason', 'why']), Res, Err));
    AssertTrue('mentions task', Pos('task', Err) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TSubagentToolTest.TestMessageRequiresSessionAndMessage;
var
  Tool: TSubagentTool;
  Res, Err: string;
begin
  Tool := MakeTool(svMessage);
  try
    AssertFalse('no session fails',
      Tool.Run(Args(['message', 'hi', 'reason', 'r']), Res, Err));
    AssertTrue('mentions session', Pos('session_id', Err) > 0);
    AssertFalse('no message fails',
      Tool.Run(Args(['session_id', 'child-1', 'reason', 'r']), Res, Err));
    AssertTrue('mentions message', Pos('message', Err) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TSubagentToolTest.TestAbortAndReleaseCallService;
var
  Tool: TSubagentTool;
  Res, Err: string;
begin
  Tool := MakeTool(svAbort);
  try
    AssertTrue('abort ok', Tool.Run(Args(['session_id', 'child-9',
      'reason', 'r']), Res, Err));
    AssertEquals('abort id', 'child-9', FService.LastAbortId);
  finally
    Tool.Free;
  end;
  Tool := MakeTool(svRelease);
  try
    AssertTrue('release ok', Tool.Run(Args(['session_id', 'child-8',
      'reason', 'r']), Res, Err));
    AssertEquals('release id', 'child-8', FService.LastReleaseId);
  finally
    Tool.Free;
  end;
end;

procedure TSubagentToolTest.TestUnknownChildIdErrors;
var
  Tool: TSubagentTool;
  Res, Err: string;
begin
  { The fake service fails unknown ids; the tool surfaces the service error. }
  FService.DelegateOk := False;
  Tool := MakeTool(svDelegate);
  try
    AssertFalse('delegate failure surfaces',
      Tool.Run(Args(['task', 't', 'context', 'c', 'reason', 'r']), Res, Err));
    AssertTrue('carries the service error', Pos('capacity', Err) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TSubagentToolTest.TestApprovalAskShape;
var
  Tool: TSubagentTool;
  Asks: TApprovalAskArray;
begin
  Tool := MakeTool(svAbort);
  try
    Asks := Tool.ApprovalAsks(Args(['session_id', 'child-1', 'reason', 'r']));
    AssertEquals('one ask', 1, Length(Asks));
    AssertEquals('ref', 'subagent:abort_task', Asks[0].Subject.Ref);
    AssertEquals('no params (tool-level)', 0, Length(Asks[0].Subject.Params));
    AssertTrue('offers a once option', Length(Asks[0].Options) >= 1);
  finally
    Tool.Free;
  end;
end;

procedure TSubagentToolTest.TestDelegateDeniedReturnsError;
var
  Tool: TSubagentTool;
  Res, Err: string;
begin
  FApproval.Allow := False;
  Tool := MakeTool(svDelegate);
  try
    AssertFalse('denied fails',
      Tool.Run(Args(['task', 't', 'context', 'c', 'reason', 'r']), Res, Err));
    AssertEquals('one approval call', 1, FApproval.Calls);
    AssertTrue('mentions denial', Pos('denied', Err) > 0);
  finally
    Tool.Free;
  end;
end;

procedure TSubagentToolTest.TestRegisterAdvertisesFourTools;
var
  Reg: TToolRegistry;
  Specs: TToolSpecArray;
  I, Found: Integer;
begin
  Reg := TToolRegistry.Create;
  try
    FTools.Register(Reg);
    Specs := Reg.Specs;
    AssertEquals('four tools', 4, Length(Specs));
    Found := 0;
    for I := 0 to High(Specs) do
      if (Specs[I].Name = SubagentDelegateTool) or
        (Specs[I].Name = SubagentMessageTool) or
        (Specs[I].Name = SubagentAbortTool) or
        (Specs[I].Name = SubagentReleaseTool) then
        Inc(Found);
    AssertEquals('all four names present', 4, Found);
  finally
    Reg.Free;
  end;
end;

procedure TSubagentToolTest.TestReasonIsCarriedIntoTheAsk;
var
  Tool: TSubagentTool;
  Asks: TApprovalAskArray;
begin
  Tool := MakeTool(svDelegate);
  try
    Asks := Tool.ApprovalAsks(Args(['task', 't', 'context', 'c',
      'reason', 'the stated reason']));
    AssertEquals('reason carried', 'the stated reason', Asks[0].Reason);
  finally
    Tool.Free;
  end;
end;

initialization
  RegisterTest(TSubagentToolTest);
end.
