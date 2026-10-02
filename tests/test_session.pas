unit test_session;
{ fpcunit tests for hildegard.helper.session and the SQLite conversation
  adapter: session ids, the history round trip, the turn/request audit, and
  restore. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.store, hildegard.helper.session,
  hildegard.helper.session.store, hildegard.helper.llm, hildegard.helper.agent,
  hildegard.helper.recall.tool;

type
  TSessionTest = class(TTestCase)
  private
    FDir, FDbPath: string;
    function OpenStore: TSqliteStore;
    function UserMsg(const AText: string): TChatMessage;
    function AssistantMsg(const AText: string): TChatMessage;
    function ToolMsg(const AId, AText: string): TChatMessage;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestNewSessionIdIs32LowercaseHex;
    procedure TestNewSessionIdIsUnique;
    procedure TestFullRoundTripMatchesAppended;
    procedure TestRestoreSkipsReasoningAndErrors;
    procedure TestRestoreAfterReopen;
    procedure TestTailKeepsSystemAndRecent;
    procedure TestTailDropsOrphanTools;
    procedure TestAppendMapsRolesAndToolFields;
    procedure TestQueryMessagesReturnsAllBlocks;
    procedure TestBeginFinishTurnAndRequestRecorded;
    procedure TestPromptCapsLargeToolResult;
    procedure TestPromptLeavesSmallToolResultIntact;
    procedure TestCapZeroDisablesTruncation;
    procedure TestRenderStillShowsFullResult;
  end;

implementation

procedure TSessionTest.SetUp;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhsess_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  CreateDir(FDir);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
end;

procedure TSessionTest.TearDown;
begin
  DeleteFile(FDbPath);
  DeleteFile(FDbPath + '-wal');
  DeleteFile(FDbPath + '-shm');
  RemoveDir(FDir);
end;

function TSessionTest.OpenStore: TSqliteStore;
var
  Cfg: TStoreConfig;
  Err: TStoreError;
begin
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  Result := TSqliteStore.Create(Cfg);
  if not Result.Open(Err) then
  begin
    Result.Free;
    raise Exception.Create('store failed to open: ' + Err.Message);
  end;
end;

function TSessionTest.UserMsg(const AText: string): TChatMessage;
begin
  Result := Default(TChatMessage);
  Result.Role := crUser;
  Result.Content := AText;
end;

function TSessionTest.AssistantMsg(const AText: string): TChatMessage;
var
  Call: TChatToolCall;
begin
  Result := Default(TChatMessage);
  Result.Role := crAssistant;
  Result.Content := AText;
  Call.Id := 'call_1';
  Call.Name := 'get_system_time';
  Call.Arguments := '{"reason":"check the time"}';
  SetLength(Result.ToolCalls, 1);
  Result.ToolCalls[0] := Call;
  Call.Id := 'call_2';
  Call.Name := 'run_command';
  Call.Arguments := '{"command":"date","reason":"run it"}';
  SetLength(Result.ToolCalls, 2);
  Result.ToolCalls[1] := Call;
end;

function TSessionTest.ToolMsg(const AId, AText: string): TChatMessage;
begin
  Result := Default(TChatMessage);
  Result.Role := crTool;
  Result.ToolCallId := AId;
  Result.Content := AText;
  Result.ToolName := 'get_system_time';
  Result.ToolOk := True;
  Result.DurationMs := 7;
end;

procedure TSessionTest.TestNewSessionIdIs32LowercaseHex;
var
  Id: string;
  I: Integer;
  C: Char;
begin
  Id := NewSessionId;
  AssertEquals('length', 32, Length(Id));
  for I := 1 to Length(Id) do
  begin
    C := Id[I];
    AssertTrue('hex char', (C in ['0'..'9', 'a'..'f']));
  end;
end;

procedure TSessionTest.TestNewSessionIdIsUnique;
var
  Seen: TStringList;
  I: Integer;
begin
  Seen := TStringList.Create;
  try
    for I := 1 to 100 do
      Seen.Add(NewSessionId);
    AssertEquals('all unique', 100, Seen.Count);
  finally
    Seen.Free;
  end;
end;

procedure TSessionTest.TestFullRoundTripMatchesAppended;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: IConversationStore;
  Msgs: TChatMessageArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);
    Conv.Append(UserMsg('hello'));
    Conv.Append(AssistantMsg('calling'));
    Conv.Append(ToolMsg('call_1', 'time'));
    Conv.Append(ToolMsg('call_2', 'out'));

    Msgs := Conv.Messages;
    AssertEquals('four messages', 4, Length(Msgs));
    AssertEquals('user', Ord(crUser), Ord(Msgs[0].Role));
    AssertEquals('assistant', Ord(crAssistant), Ord(Msgs[1].Role));
    AssertEquals('two tool calls', 2, Length(Msgs[1].ToolCalls));
    AssertEquals('call id', 'call_1', Msgs[1].ToolCalls[0].Id);
    AssertEquals('call name', 'get_system_time', Msgs[1].ToolCalls[0].Name);
    AssertEquals('tool 1', Ord(crTool), Ord(Msgs[2].Role));
    AssertEquals('tool id', 'call_1', Msgs[2].ToolCallId);
    AssertEquals('tool name restored', 'get_system_time', Msgs[2].ToolName);
    AssertTrue('tool ok restored', Msgs[2].ToolOk);
    AssertEquals('tool duration restored', 7, Msgs[2].DurationMs);
    AssertEquals('tool id 2', 'call_2', Msgs[3].ToolCallId);
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestRestoreSkipsReasoningAndErrors;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: IConversationStore;
  Msgs: TChatMessageArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);
    Conv.Append(UserMsg('hello'));
    Conv.AppendReasoning('thinking...');
    Conv.AppendError('boom', 'detail');
    Conv.Append(UserMsg('again'));
    Msgs := Conv.Messages;
    AssertEquals('two messages', 2, Length(Msgs));
    AssertEquals('first', 'hello', Msgs[0].Content);
    AssertEquals('second', 'again', Msgs[1].Content);
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestRestoreAfterReopen;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: IConversationStore;
  Msgs: TChatMessageArray;
begin
  S := OpenStore;
  S.EnsureWorkspace('/tmp', WorkspaceId, Err);
  S.CreateSession(WorkspaceId, SessionId, Err);
  Conv := TSqliteConversationStore.Create(S, SessionId);
  Conv.Append(UserMsg('hello'));
  Conv.Append(AssistantMsg('calling'));
  Conv.Append(ToolMsg('call_1', 'time'));
  S.Close;
  S.Free;

  S := OpenStore;
  try
    Conv := TSqliteConversationStore.Create(S, SessionId);
    Msgs := Conv.Messages;
    AssertEquals('restored', 3, Length(Msgs));
    AssertEquals('content', 'hello', Msgs[0].Content);
    AssertEquals('tool calls restored', 2, Length(Msgs[1].ToolCalls));
    AssertEquals('tool', 'time', Msgs[2].Content);
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestTailKeepsSystemAndRecent;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: IConversationStore;
  Msgs: TChatMessageArray;
  Sys: TChatMessage;
  I: Integer;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId, 5);
    Sys := Default(TChatMessage);
    Sys.Role := crSystem;
    Sys.Content := 'sys';
    Conv.Append(Sys);
    for I := 1 to 6 do
      Conv.Append(UserMsg('m' + IntToStr(I)));

    Msgs := Conv.Messages;
    AssertEquals('system + last five', 6, Length(Msgs));
    AssertEquals('system kept', Ord(crSystem), Ord(Msgs[0].Role));
    AssertEquals('first kept is m2', 'm2', Msgs[1].Content);
    AssertEquals('last is m6', 'm6', Msgs[5].Content);
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestTailDropsOrphanTools;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: IConversationStore;
  Msgs: TChatMessageArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId, 2);
    Conv.Append(UserMsg('u'));
    Conv.Append(AssistantMsg('calling'));
    Conv.Append(ToolMsg('call_1', 'time'));
    Conv.Append(ToolMsg('call_2', 'out'));
    Conv.Append(UserMsg('x'));

    { Full: u, assistant(2 calls), tool, tool, x. Last two are [tool, x];
      the orphan tool is dropped. }
    Msgs := Conv.Messages;
    AssertEquals('one message', 1, Length(Msgs));
    AssertEquals('user x', 'x', Msgs[0].Content);
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestAppendMapsRolesAndToolFields;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: IConversationStore;
  Records: TMessageRecordArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);
    Conv.Append(UserMsg('hello'));
    Conv.Append(AssistantMsg('calling'));
    Conv.Append(ToolMsg('call_1', 'the time is noon'));

    AssertTrue('query', S.QueryMessages(SessionId, Records, Err));
    AssertEquals('five rows (user, assistant, 2 calls, tool)', 5,
      Length(Records));
    AssertEquals('user role', Ord(mrUser), Ord(Records[0].Role));
    AssertEquals('assistant role', Ord(mrAssistant), Ord(Records[1].Role));
    AssertEquals('first call role', Ord(mrToolCall), Ord(Records[2].Role));
    AssertEquals('call id', 'call_1', Records[2].ToolCallId);
    AssertEquals('call name', 'get_system_time', Records[2].ToolName);
    AssertEquals('call reason extracted', 'check the time',
      Records[2].ToolReason);
    AssertEquals('tool role', Ord(mrTool), Ord(Records[4].Role));
    AssertEquals('tool result content', 'the time is noon',
      Records[4].Content);
    AssertEquals('tool result name', 'get_system_time', Records[4].ToolName);
    AssertTrue('tool result ok', Records[4].ToolOk);
    AssertEquals('tool result duration', 7, Records[4].DurationMs);
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestQueryMessagesReturnsAllBlocks;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: IConversationStore;
  Records: TMessageRecordArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);
    Conv.Append(UserMsg('hi'));
    Conv.AppendReasoning('why');
    Conv.AppendError('bad', 'details');

    AssertTrue('query', S.QueryMessages(SessionId, Records, Err));
    AssertEquals('three blocks', 3, Length(Records));
    AssertEquals('reasoning role', Ord(mrReasoning), Ord(Records[1].Role));
    AssertEquals('reasoning content', 'why', Records[1].Content);
    AssertEquals('error role', Ord(mrError), Ord(Records[2].Role));
    AssertEquals('error content', 'bad', Records[2].Content);
    AssertEquals('error detail', 'details', Records[2].ToolArguments);
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestBeginFinishTurnAndRequestRecorded;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: IConversationStore;
  TurnId, ReqId: Int64;
  Turns: TTurnRecordArray;
  Reqs: TRequestRecordArray;
  ReqOutcome: TRequestOutcome;
  TurnOutcome: TTurnOutcome;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);

    TurnId := Conv.BeginTurn;
    AssertTrue('turn opened', TurnId > 0);
    ReqId := Conv.BeginRequest(TurnId, 'model-x', 2);
    AssertTrue('request opened', ReqId > 0);
    Conv.Append(UserMsg('hi'));
    Conv.Append(AssistantMsg('calling'));

    ReqOutcome := Default(TRequestOutcome);
    ReqOutcome.Ok := True;
    ReqOutcome.RawFinishReason := 'tool_calls';
    ReqOutcome.Usage.PromptTokens := 10;
    ReqOutcome.Usage.CompletionTokens := 5;
    ReqOutcome.Usage.TotalTokens := 15;
    ReqOutcome.DurationMs := 111;
    ReqOutcome.FirstTokenMs := 33;
    Conv.FinishRequest(ReqId, ReqOutcome);

    TurnOutcome := Default(TTurnOutcome);
    TurnOutcome.Status := tsCompleted;
    TurnOutcome.FinishReason := 'tool_calls';
    Conv.FinishTurn(TurnId, TurnOutcome);

    AssertTrue('query turns', S.QueryTurns(SessionId, Turns, Err));
    AssertEquals('one turn', 1, Length(Turns));
    AssertEquals('completed', Ord(tsCompleted), Ord(Turns[0].Status));
    AssertEquals('one request', 1, Turns[0].RequestCount);
    AssertEquals('prompt is the user message', 'hi', Turns[0].Prompt);
    AssertEquals('rollup tokens', 15, Turns[0].Usage.TotalTokens);

    AssertTrue('query requests', S.QueryRequests(TurnId, Reqs, Err));
    AssertEquals('one request', 1, Length(Reqs));
    AssertEquals('model', 'model-x', Reqs[0].Model);
    AssertEquals('message count', 2, Reqs[0].MessageCount);
    AssertEquals('finish', 'tool_calls', Reqs[0].FinishReason);
    AssertEquals('duration', 111, Reqs[0].DurationMs);
    AssertEquals('first token', 33, Reqs[0].FirstTokenMs);
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestPromptCapsLargeToolResult;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: TSqliteConversationStore;
  Msgs: TChatMessageArray;
  Records: TMessageRecordArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);
    try
      Conv.ToolResultCap := 10;
      Conv.Append(ToolMsg('c1', StringOfChar('x', 50)));
      Msgs := Conv.Messages;
      AssertEquals('one message', 1, Length(Msgs));
      AssertEquals('capped head', StringOfChar('x', 10),
        Copy(Msgs[0].Content, 1, 10));
      AssertTrue('marker present',
        Pos('output truncated', Msgs[0].Content) > 0);
      AssertTrue('names the recall tool',
        Pos(RecallToolName, Msgs[0].Content) > 0);
      S.QueryMessages(SessionId, Records, Err);
      AssertTrue('names the message id',
        Pos('message_id=' + IntToStr(Records[0].Id), Msgs[0].Content) > 0);
    finally
      Conv.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestPromptLeavesSmallToolResultIntact;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: TSqliteConversationStore;
  Msgs: TChatMessageArray;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);
    try
      Conv.ToolResultCap := 100;
      Conv.Append(ToolMsg('c1', 'short output'));
      Msgs := Conv.Messages;
      AssertEquals('unchanged', 'short output', Msgs[0].Content);
      AssertTrue('no marker', Pos('output truncated', Msgs[0].Content) = 0);
    finally
      Conv.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestCapZeroDisablesTruncation;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: TSqliteConversationStore;
  Msgs: TChatMessageArray;
  Content: string;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);
    try
      Conv.ToolResultCap := 0;
      Content := StringOfChar('y', 500);
      Conv.Append(ToolMsg('c1', Content));
      Msgs := Conv.Messages;
      AssertEquals('full content', Content, Msgs[0].Content);
    finally
      Conv.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestRenderStillShowsFullResult;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: TSqliteConversationStore;
  Records: TMessageRecordArray;
  Content: string;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);
    try
      Conv.ToolResultCap := 10;
      Content := StringOfChar('z', 50);
      Conv.Append(ToolMsg('c1', Content));
      { The prompt view is capped, but the stored block is untouched. }
      S.QueryMessages(SessionId, Records, Err);
      AssertEquals('stored in full', Content, Records[0].Content);
    finally
      Conv.Free;
    end;
  finally
    S.Free;
  end;
end;

initialization
  RegisterTest(TSessionTest);
end.
