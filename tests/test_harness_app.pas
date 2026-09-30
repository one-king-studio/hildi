unit test_harness_app;
{ fpcunit tests for hildegard.helper.harness.app: the application wires the
  session, widgets, turn queue, and approval modal together. Runs a real turn
  through the worker over the fake transport against an in-memory surface and a
  scripted input source. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, Generics.Collections,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.harness.turn, hildegard.helper.harness.session,
  hildegard.helper.harness.app, llm_fakes;

type
  { Calls Gate.Ask on its own thread so the app can answer it. }
  TGateAskThread = class(TThread)
  private
    FGate: TApprovalGate;
    FAsk: TApprovalAsk;
  public
    Choice: TApprovalChoice;
    constructor Create(AGate: TApprovalGate; const AAsk: TApprovalAsk);
    procedure Execute; override;
  end;

  THarnessAppTest = class(TTestCase)
  private
    FDir: string;
    FSession: THarnessSession;
    FSurface: TSurfaceMemory;
    FInput: TInputSourceScripted;
    FApp: THarnessApp;
    FFake: TFakeTransport;
    procedure Build;
    function Key(AKind: TKeyKind): TInputEvent;
    function Ch(const AText: string): TInputEvent;
    procedure SubmitPrompt(const AText: string);
    function Pump(AMax: Integer): Boolean;
    function MakeAsk: TApprovalAsk;
    function AssistantEvent(const AText: string): TTurnEvent;
    function ApprovalEvent(ARequestId: Integer;
      const AAsk: TApprovalAsk): TTurnEvent;
    function Config: THarnessSessionConfig;
  protected
    procedure TearDown; override;
  published
    procedure TestStreamedTurnRendersAndReenables;
    procedure TestToolLineAppears;
    procedure TestErrorLineAppears;
    procedure TestApprovalModalResolvesGateAsk;
    procedure TestAsksDoNotStack;
    procedure TestOneFramePerStep;
  end;

implementation

constructor TGateAskThread.Create(AGate: TApprovalGate; const AAsk: TApprovalAsk);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FGate := AGate;
  FAsk := AAsk;
end;

procedure TGateAskThread.Execute;
begin
  Choice := FGate.Ask(FAsk);
end;

{ THarnessAppTest }

procedure THarnessAppTest.TearDown;
begin
  FApp.Free;
  FInput := nil;
  FSurface := nil;
  FSession.Free;
  FFake.Free;
  if DirectoryExists(FDir) then
    RemoveDir(FDir);
end;

function THarnessAppTest.Config: THarnessSessionConfig;
begin
  Result := Default(THarnessSessionConfig);
  Result.WorkspacePath := FDir;
  Result.Transport := FFake;
end;

procedure THarnessAppTest.Build;
var
  Err: string;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(40, 12);
  FInput := TInputSourceScripted.Create;
  FSession := THarnessSession.Open(Config, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession);
  FApp.Step;   // initial layout/render
end;

function THarnessAppTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function THarnessAppTest.Ch(const AText: string): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := UnicodeString(AText);
end;

procedure THarnessAppTest.SubmitPrompt(const AText: string);
var
  I: Integer;
begin
  for I := 1 to Length(AText) do
    FInput.Push(Ch(AText[I]));
  FInput.Push(Key(kkEnter));
end;

function THarnessAppTest.Pump(AMax: Integer): Boolean;
var
  I: Integer;
  SawBusy: Boolean;
begin
  Result := False;
  SawBusy := False;
  for I := 1 to AMax do
  begin
    FApp.Step;
    if FApp.Busy then
      SawBusy := True
    else if SawBusy then
      Exit(True);
    Sleep(2);
  end;
end;

function THarnessAppTest.AssistantEvent(const AText: string): TTurnEvent;
begin
  Result := Default(TTurnEvent);
  Result.Kind := teAssistantDelta;
  Result.Text := AText;
end;

function THarnessAppTest.ApprovalEvent(ARequestId: Integer;
  const AAsk: TApprovalAsk): TTurnEvent;
begin
  Result := Default(TTurnEvent);
  Result.Kind := teApprovalAsk;
  Result.RequestId := ARequestId;
  Result.Ask := AAsk;
end;

function THarnessAppTest.MakeAsk: TApprovalAsk;
var
  Option: TApprovalOption;
begin
  Result := Default(TApprovalAsk);
  Result.Summary := 'rm -rf build/';
  Result.Subject.Ref := 'run_command:rm';
  SetLength(Result.Options, 2);
  Option := Default(TApprovalOption);
  Option.Key := 'opt1';
  Option.Caption := 'Allow once';
  Result.Options[0] := Option;
  Option.Key := 'opt2';
  Option.Caption := 'Always allow';
  Result.Options[1] := Option;
end;

procedure THarnessAppTest.TestStreamedTurnRendersAndReenables;
var
  Text: string;
begin
  Build;
  FFake.AddChunk(TextDelta('hello '));
  FFake.AddChunk(TextDelta('world'));
  FFake.AddChunk(FinishFrame('stop'));
  FFake.AddChunk(DoneFrame);
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));

  Text := FApp.ConversationText;
  AssertTrue('prompt echoed', Pos('> hi', Text) > 0);
  AssertTrue('assistant streamed', Pos('hello world', Text) > 0);
  AssertTrue('prompt re-enabled', FApp.PromptActive);
  AssertFalse('not busy', FApp.Busy);
end;

procedure THarnessAppTest.TestToolLineAppears;
var
  Text: string;
begin
  Build;
  FFake.AddResponse([ToolNameFrame(0, 'c1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"checking"}'), FinishFrame('tool_calls'),
    DoneFrame]);
  FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('time?');
  AssertTrue('turn finished', Pump(300));

  Text := FApp.ConversationText;
  AssertTrue('tool call line', Pos('[tool] get_system_time', Text) > 0);
  AssertTrue('tool reason', Pos('checking', Text) > 0);
  AssertTrue('tool result line', Pos('[result] get_system_time: ok', Text) > 0);
end;

procedure THarnessAppTest.TestErrorLineAppears;
var
  Text: string;
begin
  Build;
  FFake.FailNetwork := True;
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));

  Text := FApp.ConversationText;
  AssertTrue('error line', Pos('[error]', Text) > 0);
  AssertTrue('prompt re-enabled', FApp.PromptActive);
end;

procedure THarnessAppTest.TestApprovalModalResolvesGateAsk;
var
  Thread: TGateAskThread;
  Waited: Integer;
begin
  Build;
  Thread := TGateAskThread.Create(FSession.Gate, MakeAsk);
  Thread.Start;

  Waited := 0;
  while (not FApp.ModalActive) and (Waited < 500) do
  begin
    FApp.Step;
    Sleep(2);
    Inc(Waited);
  end;
  AssertTrue('approval modal shown', FApp.ModalActive);

  FInput.Push(Key(kkDown));
  FInput.Push(Key(kkEnter));
  Waited := 0;
  while (not Thread.Finished) and (Waited < 500) do
  begin
    FApp.Step;
    Sleep(2);
    Inc(Waited);
  end;
  Thread.WaitFor;
  AssertTrue('thread finished', Thread.Finished);
  AssertTrue('allowed', Thread.Choice.Allowed);
  AssertEquals('chosen option', 'opt2', Thread.Choice.OptionKey);
  Thread.Free;
end;

procedure THarnessAppTest.TestAsksDoNotStack;
begin
  Build;
  FSession.Queue.Push(ApprovalEvent(1, MakeAsk));
  FSession.Queue.Push(ApprovalEvent(2, MakeAsk));

  { First drain shows one modal and queues the second. }
  FApp.Step;
  AssertTrue('first modal shown', FApp.ModalActive);

  { Answering the first must surface the second, not pop it. }
  FInput.Push(Key(kkEnter));
  FApp.Step;   { consumes Enter -> chooses the first }
  FApp.Step;   { pops the first and shows the second }
  AssertTrue('second modal shown', FApp.ModalActive);

  FInput.Push(Key(kkEnter));
  FApp.Step;   { chooses the second }
  FApp.Step;   { pops it }
  AssertFalse('no modal left', FApp.ModalActive);
end;

procedure THarnessAppTest.TestOneFramePerStep;
var
  Before: Integer;
begin
  Build;
  Before := FSurface.FlushCount;
  FSession.Queue.Push(AssistantEvent('x'));
  FApp.Step;
  AssertEquals('one flush per step', 1, FSurface.FlushCount - Before);
end;

initialization
  RegisterTest(THarnessAppTest);
  Randomize;

end.
