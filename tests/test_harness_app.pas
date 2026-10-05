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
  hildegard.helper.tui.chat,
  hildegard.helper.harness.turn, hildegard.helper.harness.session,
  hildegard.helper.harness.driver, hildegard.helper.harness.app,
  hildegard.helper.store,
  hildegard.helper.session, llm_fakes;

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

  { Sleeps after every stream chunk, so a turn stays in flight long enough for
    the test to press Escape at it. }
  TSlowChunks = class
  private
    FMs: Integer;
  public
    constructor Create(AMs: Integer);
    procedure AfterChunk(Sender: TObject);
  end;

  { Fails the next request after the first stream chunk, so a truncated
    response's continuation hits a network error. }
  TFailNetworkAfterChunk = class
  private
    FFake: TFakeTransport;
  public
    constructor Create(AFake: TFakeTransport);
    procedure AfterChunk(Sender: TObject);
  end;

  THarnessAppTest = class(TTestCase)
  private
    FDir: string;
    FSession: THarnessSession;
    FSurface: TSurfaceMemory;
    FInput: TInputSourceScripted;
    FApp: THarnessApp;
    FFake: TFakeTransport;
    FStorePath: string;
    procedure Build;
    procedure BuildWithStore;
    function Key(AKind: TKeyKind): TInputEvent;
    function Ch(const AText: string): TInputEvent;
    function Ctrl(const ACh: string): TInputEvent;
    procedure SubmitPrompt(const AText: string);
    function Pump(AMax: Integer): Boolean;
    function MakeAsk: TApprovalAsk;
    function BlockCount: Integer;
    function BlockKind(AIndex: Integer): TChatKind;
    function BlockLabel(AIndex: Integer): string;
    function BlockText(AIndex: Integer): string;
    function BlockLive(AIndex: Integer): Boolean;
    function FindText(AKind: TChatKind; const ANeedle: string): Boolean;
    function BlockSignature: string;
    function DividerSignature: string;
    function ThoughtLabel: string;
    function AssistantEvent(const AText: string): TTurnEvent;
    function ApprovalEvent(ARequestId: Integer;
      const AAsk: TApprovalAsk): TTurnEvent;
    function Config: THarnessSessionConfig;
  protected
    procedure TearDown; override;
  published
    procedure TestStreamedTurnRendersAndReenables;
    procedure TestToolLineAppears;
    procedure TestEmptyToolResultShowsPlaceholder;
    procedure TestAppStreamsToolOutput;
    procedure TestResumeShowsTheResult;
    procedure TestErrorLineAppears;
    procedure TestApprovalModalResolvesGateAsk;
    procedure TestAsksDoNotStack;
    procedure TestOneFramePerStep;
    procedure TestRenderHistoryRestoresToolBlocks;
    procedure TestHeaderShowsSessionIdAndContext;
    procedure TestStatusShowsWorkspaceAndConsumption;
    procedure TestStatusSumsTurns;
    procedure TestResumeHeaderMatchesLive;
    procedure TestTurnDividerAfterSuccessfulTurn;
    procedure TestNoDividerAfterFailedTurn;
    procedure TestResumeRendersTurnDividers;
    procedure TestThoughtShowsDuration;
    procedure TestCtaHintsAreBlank;
    procedure TestThinkingStateDuringATurn;
    procedure TestReasoningSettlesIntoAThoughtBlock;
    procedure TestReadyStateAfterATurn;
    procedure TestErrorStateAfterAFailedTurn;
    procedure TestErrorRollsBackStreamedBlocks;
    procedure TestResumeMatchesLiveAfterTruncationError;
    procedure TestEscapeArmsThenCancels;
    procedure TestEarlyCancelRestoresThePrompt;
    procedure TestSubmitWhileBusyQueuesThePrompt;
    procedure TestPasteInsertsIntoTheCompose;
    procedure TestCtrlCQuitsOnlyWhenComposeIsEmpty;
    procedure TestApprovalDimsTheBackground;
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

{ TSlowChunks }

constructor TSlowChunks.Create(AMs: Integer);
begin
  inherited Create;
  FMs := AMs;
end;

procedure TSlowChunks.AfterChunk(Sender: TObject);
begin
  Sleep(FMs);
end;

{ TFailNetworkAfterChunk }

constructor TFailNetworkAfterChunk.Create(AFake: TFakeTransport);
begin
  inherited Create;
  FFake := AFake;
end;

procedure TFailNetworkAfterChunk.AfterChunk(Sender: TObject);
begin
  FFake.FailNetwork := True;
end;

{ THarnessAppTest }

procedure THarnessAppTest.TearDown;
begin
  FApp.Free;
  FInput := nil;
  FSurface := nil;
  FSession.Free;
  FFake.Free;
  if FStorePath <> '' then
  begin
    DeleteFile(FStorePath);
    DeleteFile(FStorePath + '-wal');
    DeleteFile(FStorePath + '-shm');
  end;
  if DirectoryExists(FDir) then
    RemoveDir(FDir);
end;

function THarnessAppTest.Config: THarnessSessionConfig;
begin
  Result := Default(THarnessSessionConfig);
  Result.WorkspacePath := FDir;
  Result.Transport := FFake;
  { Pin the context limit so the header is deterministic (the environment may
    set HILDEGARD_MAX_CONTEXT_TOKENS). }
  Result.MaxContextTokens := 120000;
end;

procedure THarnessAppTest.Build;
var
  Err: string;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := '';
  FFake := TFakeTransport.Create;
  { Tall enough that the approval modal (which grew a row) leaves a margin to
    dim above it. }
  FSurface := TSurfaceMemory.Create(40, 20);
  FInput := TInputSourceScripted.Create;
  FSession := THarnessSession.Open(Config, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession, LocalDriver(FSession));
  FApp.Step;   // initial layout/render
end;

procedure THarnessAppTest.BuildWithStore;
var
  Err: string;
  Cfg: THarnessSessionConfig;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('session opened: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession, LocalDriver(FSession));
  FApp.Step;
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

function THarnessAppTest.Ctrl(const ACh: string): TInputEvent;
begin
  Result := Ch(ACh);
  Result.Key.Mods := [moCtrl];
end;

procedure THarnessAppTest.SubmitPrompt(const AText: string);
var
  I: Integer;
  E: TInputEvent;
begin
  for I := 1 to Length(AText) do
    FInput.Push(Ch(AText[I]));
  { Shift+Enter submits now; a plain Enter adds a line. }
  E := Key(kkEnter);
  E.Key.Mods := [moShift];
  FInput.Push(E);
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

function THarnessAppTest.BlockCount: Integer;
begin
  Result := FApp.Panel.Stream.Count;
end;

function THarnessAppTest.BlockKind(AIndex: Integer): TChatKind;
begin
  Result := FApp.Panel.Stream.ItemAt(AIndex).Kind;
end;

function THarnessAppTest.BlockLabel(AIndex: Integer): string;
begin
  Result := FApp.Panel.Stream.ItemAt(AIndex).Label_;
end;

function THarnessAppTest.BlockText(AIndex: Integer): string;
begin
  Result := FApp.Panel.Stream.ItemAt(AIndex).Text;
end;

function THarnessAppTest.BlockLive(AIndex: Integer): Boolean;
begin
  Result := FApp.Panel.Stream.ItemAt(AIndex).Live;
end;

function THarnessAppTest.FindText(AKind: TChatKind; const ANeedle: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to BlockCount - 1 do
    if (BlockKind(I) = AKind) and (Pos(ANeedle, BlockText(I)) > 0) then
      Exit(True);
end;

function THarnessAppTest.BlockSignature: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to BlockCount - 1 do
    Result := Result + IntToStr(Ord(BlockKind(I))) + ':' + BlockText(I) + '|';
end;

function THarnessAppTest.DividerSignature: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to BlockCount - 1 do
    if BlockKind(I) = ckTurn then
      Result := Result + BlockText(I) + '|';
end;

function THarnessAppTest.ThoughtLabel: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to BlockCount - 1 do
    if BlockKind(I) = ckThought then
      Exit(BlockLabel(I));
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
begin
  Build;
  FFake.AddChunk(TextDelta('hello '));
  FFake.AddChunk(TextDelta('world'));
  FFake.AddChunk(FinishFrame('stop'));
  FFake.AddChunk(DoneFrame);
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));

  AssertEquals('user bubble plus assistant block', 2, BlockCount);
  AssertTrue('first block is the user bubble', BlockKind(0) = ckUser);
  AssertEquals('prompt echoed', 'hi', BlockText(0));
  AssertTrue('assistant streamed', FindText(ckAssistant, 'hello world'));
  AssertTrue('thinking indicator removed',
    not FindText(ckThinking, 'Thinking'));
  AssertTrue('prompt re-enabled', FApp.PromptActive);
  AssertFalse('not busy', FApp.Busy);
end;

procedure THarnessAppTest.TestReasoningSettlesIntoAThoughtBlock;
var
  I: Integer;
  SawThought: Boolean;
begin
  Build;
  FFake.AddChunk(ReasoningDelta('let me think'));
  FFake.AddChunk(TextDelta('answer'));
  FFake.AddChunk(FinishFrame('stop'));
  FFake.AddChunk(DoneFrame);
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));

  { While it streamed it read as "Thinking..."; once persisted it is a
    "Thought" block. }
  SawThought := False;
  for I := 0 to BlockCount - 1 do
    if (BlockKind(I) = ckThought) and (BlockText(I) = 'let me think') and
      (Pos('Thought', BlockLabel(I)) = 1) then
      SawThought := True;
  AssertTrue('reasoning settled into a Thought block', SawThought);
end;

procedure THarnessAppTest.TestToolLineAppears;
var
  I: Integer;
  ToolSeen: Boolean;
begin
  Build;
  FFake.AddResponse([TextDelta('let me check '),
    ToolNameFrame(0, 'c1', 'get_system_time'),
    ToolArgsFrame(0, '{"reason":"checking"}'), FinishFrame('tool_calls'),
    DoneFrame]);
  FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('time?');
  AssertTrue('turn finished', Pump(300));

  AssertTrue('assistant text followed', FindText(ckAssistant, 'done'));
  ToolSeen := False;
  for I := 0 to BlockCount - 1 do
    if (BlockKind(I) = ckTool) and (BlockLabel(I) = 'checking') and
      (BlockText(I) <> '') then
      ToolSeen := True;
  AssertTrue('reason is the title, the result is the body', ToolSeen);
  AssertFalse('the raw call is not shown',
    FindText(ckTool, 'get_system_time'));
  AssertFalse('no [ok] prefix', FindText(ckTool, '[ok]'));
  { The text that accompanied the call stays before it; the answer that follows
    the tools is its own block, after them. }
  AssertEquals('four blocks', 4, BlockCount);
  AssertTrue('user first', BlockKind(0) = ckUser);
  AssertTrue('lead-in second', BlockKind(1) = ckAssistant);
  AssertTrue('tool third', BlockKind(2) = ckTool);
  AssertTrue('answer last', BlockKind(3) = ckAssistant);
  AssertEquals('answer text', 'done', BlockText(3));
  AssertEquals('lead-in text', 'let me check ', BlockText(1));
end;

procedure THarnessAppTest.TestEmptyToolResultShowsPlaceholder;
var
  E: TTurnEvent;
begin
  Build;
  { A tool that produced nothing still ran; the block shows a marker. }
  E := Default(TTurnEvent);
  E.Kind := teToolResult;
  E.ToolName := 'glob';
  E.Text := '';
  E.ToolOk := True;
  FSession.Queue.Push(E);
  FApp.Step;
  AssertTrue('placeholder shown', FindText(ckTool, '(no output)'));
end;

procedure THarnessAppTest.TestAppStreamsToolOutput;
var
  Call, Chunk, Res: TTurnEvent;
begin
  Build;
  { A tool call opens the block; chunks stream into it and it reads as live. }
  Call := Default(TTurnEvent);
  Call.Kind := teToolCall;
  Call.ToolId := 'call_1';
  Call.ToolName := 'run_command';
  Call.ToolReason := 'building';
  FSession.Queue.Push(Call);

  Chunk := Default(TTurnEvent);
  Chunk.Kind := teToolOutput;
  Chunk.ToolId := 'call_1';
  Chunk.ToolName := 'run_command';
  Chunk.Text := 'compiling ';
  FSession.Queue.Push(Chunk);
  Chunk.Text := 'done';
  FSession.Queue.Push(Chunk);
  FApp.Step;

  AssertTrue('streamed body', FindText(ckTool, 'compiling done'));
  AssertTrue('live while running', BlockLive(BlockCount - 1));
  AssertEquals('reason is the title', 'building', BlockLabel(BlockCount - 1));

  { The authoritative result replaces the streamed body on completion. }
  Res := Default(TTurnEvent);
  Res.Kind := teToolResult;
  Res.ToolId := 'call_1';
  Res.ToolName := 'run_command';
  Res.Text := 'compiling done (exit 0)';
  Res.ToolOk := True;
  FSession.Queue.Push(Res);
  FApp.Step;

  AssertFalse('settled', BlockLive(BlockCount - 1));
  AssertEquals('result replaced the stream', 'compiling done (exit 0)',
    BlockText(BlockCount - 1));
end;

procedure THarnessAppTest.TestResumeShowsTheResult;
var
  Call, Chunk, Res: TTurnEvent;
begin
  Build;
  { Stream a tool to completion, then check the settled body is exactly the
    authoritative result: a resumed view renders the same ledger content, so
    the two must match. }
  Call := Default(TTurnEvent);
  Call.Kind := teToolCall;
  Call.ToolId := 'call_1';
  Call.ToolName := 'run_command';
  Call.ToolReason := 'building';
  FSession.Queue.Push(Call);

  Chunk := Default(TTurnEvent);
  Chunk.Kind := teToolOutput;
  Chunk.ToolId := 'call_1';
  Chunk.ToolName := 'run_command';
  Chunk.Text := 'partial';
  FSession.Queue.Push(Chunk);

  Res := Default(TTurnEvent);
  Res.Kind := teToolResult;
  Res.ToolId := 'call_1';
  Res.ToolName := 'run_command';
  Res.Text := 'the result';
  Res.ToolOk := True;
  FSession.Queue.Push(Res);
  FApp.Step;

  AssertEquals('live final body is the result', 'the result',
    BlockText(BlockCount - 1));
  AssertFalse('not live after settle', BlockLive(BlockCount - 1));
end;

procedure THarnessAppTest.TestErrorLineAppears;
var
  I: Integer;
  ErrSeen: Boolean;
begin
  Build;
  FFake.FailNetwork := True;
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));

  ErrSeen := False;
  for I := 0 to BlockCount - 1 do
    if (BlockKind(I) = ckError) and (BlockText(I) <> '') then
      ErrSeen := True;
  AssertTrue('an error block with text exists', ErrSeen);
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

procedure THarnessAppTest.TestRenderHistoryRestoresToolBlocks;
var
  Store: TSqliteStore;
  StoreCfg: TStoreConfig;
  StoreErr: TStoreError;
  Cfg: THarnessSessionConfig;
  WorkspaceId: Integer;
  Sid: string;
  TurnId: Int64;
  Rec: TMessageRecord;
  Err: string;
  SawReasoning, SawTool, SawResult, SawAssistant, SawError: Boolean;
  I: Integer;

  procedure Add(ARole: TMessageRole; const AContent, AToolCallId,
    AToolName, AToolArgs, AToolReason: string; AToolOk: Boolean);
  begin
    Rec := Default(TMessageRecord);
    Rec.SessionId := Sid;
    Rec.TurnId := TurnId;
    Rec.Role := ARole;
    Rec.Content := AContent;
    Rec.ToolCallId := AToolCallId;
    Rec.ToolName := AToolName;
    Rec.ToolArguments := AToolArgs;
    Rec.ToolReason := AToolReason;
    Rec.ToolOk := AToolOk;
    Store.AppendMessage(Rec, StoreErr);
  end;

begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hh-app-' +
    IntToStr(Random(1000000));
  ForceDirectories(FDir);
  FStorePath := IncludeTrailingPathDelimiter(FDir) + 'store.db';

  StoreCfg.DatabasePath := FStorePath;
  StoreCfg.BusyTimeoutMs := 5000;
  Store := TSqliteStore.Create(StoreCfg);
  try
    AssertTrue('open store', Store.Open(StoreErr));
    Store.EnsureWorkspace(FDir, WorkspaceId, StoreErr);
    Store.CreateSession(WorkspaceId, Sid, StoreErr);
    Store.BeginTurn(Sid, TurnId, StoreErr);
    Add(mrUser, 'do it', '', '', '', '', False);
    Add(mrReasoning, 'why not', '', '', '', '', False);
    Add(mrToolCall, '', 'c1', 'run_command', '{"command":"date"}',
      'check the date', False);
    Add(mrTool, 'noon', 'c1', 'run_command', '', '', True);
    Add(mrAssistant, 'done', '', '', '', '', False);
    Add(mrError, 'boom', '', '', '', '', False);
  finally
    Store.Free;
  end;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession, LocalDriver(FSession));
  FApp.Step;

  SawReasoning := False;
  SawTool := False;
  SawResult := False;
  SawAssistant := False;
  SawError := False;
  for I := 0 to BlockCount - 1 do
  begin
    if (BlockKind(I) = ckThought) and (Pos('why not', BlockText(I)) > 0) then
      SawReasoning := True;
    if (BlockKind(I) = ckTool) and (BlockLabel(I) = 'check the date') then
      SawTool := True;
    if (BlockKind(I) = ckTool) and (Pos('noon', BlockText(I)) > 0) then
      SawResult := True;
    if (BlockKind(I) = ckAssistant) and (Pos('done', BlockText(I)) > 0) then
      SawAssistant := True;
    if (BlockKind(I) = ckError) and (Pos('boom', BlockText(I)) > 0) then
      SawError := True;
  end;
  AssertTrue('user bubble restored', FindText(ckUser, 'do it'));
  AssertTrue('reasoning block restored', SawReasoning);
  AssertTrue('tool block titled by reason', SawTool);
  AssertTrue('tool result paired into the block', SawResult);
  AssertFalse('the raw call is not restored', FindText(ckTool, 'run_command'));
  AssertTrue('assistant block restored', SawAssistant);
  AssertTrue('error block restored', SawError);
end;

procedure THarnessAppTest.TestHeaderShowsSessionIdAndContext;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":1200,"completion_tokens":310,' +
      '"total_tokens":1510,"prompt_tokens_details":{"cached_tokens":1100}}'),
    FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));

  { The id prefix is the left border title; the context the right. }
  AssertEquals('session id on the left', Copy(FSession.SessionId, 1, 12),
    FApp.Panel.HeaderLeft);
  AssertTrue('context tokens in the header',
    Pos('1.2k', FApp.Panel.HeaderRight) > 0);
  { The pinned limit is 120k, so the context bar and percentage are shown. }
  AssertTrue('context percentage in the header',
    Pos('1%', FApp.Panel.HeaderRight) > 0);
  { The consumption is on the status bar, not the header. }
  AssertFalse('no consumption in the header',
    Pos('cached', FApp.Panel.HeaderRight) > 0);
end;

procedure THarnessAppTest.TestResumeHeaderMatchesLive;
var
  Live, Sid: string;
  Cfg: THarnessSessionConfig;
  Err: string;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":1200,"completion_tokens":310,' +
      '"total_tokens":1510,"prompt_tokens_details":{"cached_tokens":1100}}'),
    FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  Live := FApp.Panel.HeaderLeft + '|' + FApp.Panel.HeaderRight;
  AssertTrue('live header present', FApp.Panel.HeaderRight <> '');
  Sid := FSession.SessionId;

  { Drop the live app but keep the store, then resume the same session. }
  FApp.Free;
  FApp := nil;
  FInput := nil;
  FSurface := nil;
  FSession.Free;
  FSession := nil;
  FFake.Free;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession, LocalDriver(FSession));
  FApp.Step;

  AssertEquals('resumed header identical to live', Live,
    FApp.Panel.HeaderLeft + '|' + FApp.Panel.HeaderRight);
end;

procedure THarnessAppTest.TestStatusSumsTurns;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('one'),
    UsageFrame('{"prompt_tokens":1000,"completion_tokens":100,' +
      '"total_tokens":1100}'), FinishFrame('stop'), DoneFrame]);
  FFake.AddResponse([TextDelta('two'),
    UsageFrame('{"prompt_tokens":2000,"completion_tokens":200,' +
      '"total_tokens":2200}'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('a');
  AssertTrue('first turn finished', Pump(300));
  SubmitPrompt('b');
  AssertTrue('second turn finished', Pump(300));

  { The status bar's consumption sums both turns: 3.0k in, 300 out, 2 req. }
  AssertTrue('input summed', Pos('3.0k in', FApp.StatsText) > 0);
  AssertTrue('output summed', Pos('300 out', FApp.StatsText) > 0);
  AssertTrue('two requests', Pos('2 req', FApp.StatsText) > 0);
end;

procedure THarnessAppTest.TestStatusShowsWorkspaceAndConsumption;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":1200,"completion_tokens":310,' +
      '"total_tokens":1510,"prompt_tokens_details":{"cached_tokens":1100}}'),
    FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));

  { The workspace stays on the left; the consumption is on the right. }
  AssertEquals('workspace on the left', FDir, FApp.StatusText);
  AssertTrue('input in the consumption', Pos('1.2k in', FApp.StatsText) > 0);
  AssertTrue('output in the consumption', Pos('310 out', FApp.StatsText) > 0);
  AssertTrue('cache in the consumption',
    Pos('92% cached', FApp.StatsText) > 0);
end;

procedure THarnessAppTest.TestTurnDividerAfterSuccessfulTurn;
var
  I: Integer;
  Saw: Boolean;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":1200,"completion_tokens":310,' +
      '"total_tokens":1510,"prompt_tokens_details":{"cached_tokens":1100}}'),
    FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));

  Saw := False;
  for I := 0 to BlockCount - 1 do
    if (BlockKind(I) = ckTurn) and (Pos('1.2k in', BlockText(I)) > 0) then
      Saw := True;
  AssertTrue('a divider carries the loop stats', Saw);
end;

procedure THarnessAppTest.TestNoDividerAfterFailedTurn;
var
  I: Integer;
begin
  Build;
  FFake.FailNetwork := True;
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));
  for I := 0 to BlockCount - 1 do
    AssertFalse('no divider for a failed loop', BlockKind(I) = ckTurn);
end;

procedure THarnessAppTest.TestResumeRendersTurnDividers;
var
  Live, Sid: string;
  Cfg: THarnessSessionConfig;
  Err: string;
begin
  BuildWithStore;
  FFake.AddResponse([TextDelta('hi'),
    UsageFrame('{"prompt_tokens":1200,"completion_tokens":310,' +
      '"total_tokens":1510,"prompt_tokens_details":{"cached_tokens":1100}}'),
    FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  Live := DividerSignature;
  AssertTrue('a live divider exists', Live <> '');
  Sid := FSession.SessionId;

  FApp.Free;
  FApp := nil;
  FInput := nil;
  FSurface := nil;
  FSession.Free;
  FSession := nil;
  FFake.Free;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession, LocalDriver(FSession));
  FApp.Step;

  AssertEquals('resumed dividers identical to live', Live, DividerSignature);
end;

procedure THarnessAppTest.TestThoughtShowsDuration;
var
  Delay: TSlowChunks;
  Live, Sid: string;
  Cfg: THarnessSessionConfig;
  Err: string;
begin
  BuildWithStore;
  Delay := TSlowChunks.Create(20);
  try
    FFake.AfterChunk := Delay.AfterChunk;
    FFake.AddResponse([ReasoningDelta('think'), TextDelta('answer'),
      FinishFrame('stop'), DoneFrame]);
    SubmitPrompt('hi');
    AssertTrue('turn finished', Pump(400));
  finally
    Delay.Free;
  end;
  Live := ThoughtLabel;
  AssertTrue('thought shows its duration', Pos('Thought for ', Live) > 0);
  Sid := FSession.SessionId;

  FApp.Free;
  FApp := nil;
  FInput := nil;
  FSurface := nil;
  FSession.Free;
  FSession := nil;
  FFake.Free;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession, LocalDriver(FSession));
  FApp.Step;

  AssertEquals('resumed thought label identical', Live, ThoughtLabel);
end;

procedure THarnessAppTest.TestCtaHintsAreBlank;
begin
  Build;
  { The toolbar hints are intentionally blank for now. }
  AssertEquals('hints blanked', '', FApp.HintsText);
  AssertFalse('hints are not in the status bar',
    Pos('newline', FApp.StatusText) > 0);
end;

procedure THarnessAppTest.TestThinkingStateDuringATurn;
var
  I: Integer;
  Seen: Boolean;
begin
  Build;
  FFake.AddChunk(TextDelta('hi'));
  FFake.AddChunk(FinishFrame('stop'));
  FFake.AddChunk(DoneFrame);
  SubmitPrompt('hello');
  Seen := False;
  for I := 1 to 300 do
  begin
    FApp.Step;
    if FApp.Busy then
    begin
      Seen := True;
      AssertEquals('thinking while busy', 'thinking', FApp.StateText);
      Break;
    end;
    Sleep(2);
  end;
  AssertTrue('the turn started', Seen);
end;

procedure THarnessAppTest.TestReadyStateAfterATurn;
begin
  Build;
  FFake.AddResponse([TextDelta('hi'), FinishFrame('stop'), DoneFrame]);
  SubmitPrompt('hello');
  AssertTrue('turn finished', Pump(300));
  AssertEquals('ready state', 'ready', FApp.StateText);
end;

procedure THarnessAppTest.TestErrorStateAfterAFailedTurn;
begin
  Build;
  FFake.FailNetwork := True;
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));
  AssertEquals('error state', 'error', FApp.StateText);
end;

procedure THarnessAppTest.TestErrorRollsBackStreamedBlocks;
var
  Fail: TFailNetworkAfterChunk;
begin
  Build;
  Fail := TFailNetworkAfterChunk.Create(FFake);
  try
    { The first response streams a fragment and is truncated; the continuation
      then hits a network error, so the pending response is discarded. }
    FFake.AfterChunk := Fail.AfterChunk;
    FFake.AddResponse([TextDelta('partial answer'), FinishFrame('length'),
      DoneFrame]);
    SubmitPrompt('hi');
    AssertTrue('turn finished', Pump(300));
  finally
    FFake.AfterChunk := nil;
    Fail.Free;
  end;

  AssertFalse('the streamed fragment was rolled back',
    FindText(ckAssistant, 'partial answer'));
  AssertTrue('an error block exists', FindText(ckError, 'failed'));
  AssertTrue('prompt re-enabled', FApp.PromptActive);
end;

procedure THarnessAppTest.TestResumeMatchesLiveAfterTruncationError;
var
  Live, Sid: string;
  Cfg: THarnessSessionConfig;
  Err: string;
begin
  BuildWithStore;
  { A truncated fragment that the next request cannot complete. }
  FFake.AddResponse([TextDelta('partial answer'), FinishFrame('length'),
    DoneFrame]);
  FFake.AddResponse([FinishFrame('content_filter'), DoneFrame]);
  SubmitPrompt('hi');
  AssertTrue('turn finished', Pump(300));
  AssertFalse('no fragment live', FindText(ckAssistant, 'partial answer'));
  Live := BlockSignature;
  Sid := FSession.SessionId;

  { Drop the live app but keep the store, then resume the same session. }
  FApp.Free;
  FApp := nil;
  FInput := nil;
  FSurface := nil;
  FSession.Free;
  FSession := nil;
  FFake.Free;

  FFake := TFakeTransport.Create;
  FSurface := TSurfaceMemory.Create(60, 20);
  FInput := TInputSourceScripted.Create;
  Cfg := Config;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := Sid;
  Cfg.Resume := True;
  FSession := THarnessSession.Open(Cfg, Err);
  AssertTrue('resumed: ' + Err, FSession <> nil);
  FApp := THarnessApp.Create(FSurface, FInput, FSession, LocalDriver(FSession));
  FApp.Step;

  AssertEquals('resumed blocks identical to live', Live, BlockSignature);
end;

procedure THarnessAppTest.TestEscapeArmsThenCancels;
var
  Slow: TSlowChunks;
  I: Integer;
begin
  Build;
  Slow := TSlowChunks.Create(80);
  try
    FFake.AfterChunk := Slow.AfterChunk;
    { Two requests, so the loop reaches a boundary where the cancel is seen. }
    FFake.AddResponse([TextDelta('working'),
      ToolNameFrame(0, 'c1', 'get_system_time'),
      ToolArgsFrame(0, '{"reason":"r"}'),
      FinishFrame('tool_calls'), DoneFrame]);
    FFake.AddResponse([TextDelta('done'), FinishFrame('stop'), DoneFrame]);
    SubmitPrompt('hello');
    for I := 1 to 300 do
    begin
      FApp.Step;
      if FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertTrue('turn in flight', FApp.Busy);

    FInput.Push(Key(kkEscape));
    FApp.Step;
    AssertTrue('first escape arms', FApp.InterruptArmed);
    AssertEquals('prompt shown', 'press esc again to cancel', FApp.StateText);

    FInput.Push(Key(kkEscape));
    FApp.Step;
    AssertFalse('second escape disarms', FApp.InterruptArmed);
    AssertEquals('cancelling', 'cancelling', FApp.StateText);

    { The cancel is seen at the worker's next loop boundary; wait for idle. }
    for I := 1 to 600 do
    begin
      FApp.Step;
      if not FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertEquals('cancelled state', 'cancelled', FApp.StateText);
  finally
    Slow.Free;
  end;
end;

procedure THarnessAppTest.TestEarlyCancelRestoresThePrompt;
var
  Slow: TSlowChunks;
  I: Integer;
begin
  Build;
  Slow := TSlowChunks.Create(80);
  try
    FFake.AfterChunk := Slow.AfterChunk;
    FFake.AddResponse([TextDelta('working'), FinishFrame('stop'), DoneFrame]);
    SubmitPrompt('hello');
    for I := 1 to 300 do
    begin
      FApp.Step;
      if FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertTrue('turn in flight', FApp.Busy);

    FInput.Push(Key(kkEscape));
    FApp.Step;
    FInput.Push(Key(kkEscape));
    FApp.Step;
    for I := 1 to 800 do
    begin
      FApp.Step;
      if not FApp.Busy then
        Break;
      Sleep(2);
    end;

    AssertEquals('cancelled', 'cancelled', FApp.StateText);
    AssertEquals('the prompt came back', 'hello',
      string(FApp.Panel.Compose.Text));
    AssertEquals('the aborted turn left no block', 0, BlockCount);
  finally
    Slow.Free;
  end;
end;

procedure THarnessAppTest.TestSubmitWhileBusyQueuesThePrompt;
var
  Slow: TSlowChunks;
  I: Integer;
begin
  Build;
  Slow := TSlowChunks.Create(80);
  try
    FFake.AfterChunk := Slow.AfterChunk;
    FFake.AddResponse([TextDelta('one'), FinishFrame('stop'), DoneFrame]);
    FFake.AddResponse([TextDelta('two'), FinishFrame('stop'), DoneFrame]);
    SubmitPrompt('first');
    for I := 1 to 300 do
    begin
      FApp.Step;
      if FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertTrue('turn in flight', FApp.Busy);

    { A second submit while busy is queued, not dropped. }
    SubmitPrompt('second');
    for I := 1 to 1200 do
    begin
      FApp.Step;
      if not FApp.Busy then
        Break;
      Sleep(2);
    end;
    AssertEquals('the queued prompt started the next turn', 2, FFake.Calls);
    AssertTrue('the queued prompt is in the transcript',
      FindText(ckUser, 'second'));
  finally
    Slow.Free;
  end;
end;

procedure THarnessAppTest.TestPasteInsertsIntoTheCompose;
var
  E: TInputEvent;
begin
  Build;
  E := Default(TInputEvent);
  E.Kind := ikPaste;
  E.Text := 'pasted' + #10 + 'text';
  FInput.Push(E);
  FApp.Step;

  AssertEquals('pasted text inserted whole', 'pasted' + #10 + 'text',
    string(FApp.Panel.Compose.Text));
  AssertFalse('a paste never submits', FApp.Busy);
end;

procedure THarnessAppTest.TestCtrlCQuitsOnlyWhenComposeIsEmpty;
begin
  Build;
  FInput.Push(Ch('h'));
  FInput.Push(Ch('i'));
  FApp.Step;
  FApp.Step;
  AssertEquals('compose has text', 'hi', string(FApp.Panel.Compose.Text));

  FInput.Push(Ctrl('c'));
  AssertTrue('ctrl+c with text does not quit', FApp.Step);
  AssertEquals('compose cleared', '', string(FApp.Panel.Compose.Text));

  FInput.Push(Ctrl('c'));
  AssertFalse('ctrl+c on an empty compose quits', FApp.Step);
end;

procedure THarnessAppTest.TestApprovalDimsTheBackground;
begin
  Build;
  FSession.Queue.Push(ApprovalEvent(1, MakeAsk));
  FApp.Step;   // drain the ask -> show the modal
  FApp.Step;   // render it
  AssertTrue('modal shown', FApp.ModalActive);
  { A cell above the modal (the panel's top border) is dimmed. }
  AssertTrue('the background is dimmed',
    sfDim in FSurface.CellAt(20, 0).Attr.Style);
end;

initialization
  RegisterTest(THarnessAppTest);
  Randomize;

end.
