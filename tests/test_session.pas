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
  hildegard.helper.recall.tool, hildegard.helper.ambient;

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
    procedure TestEmptyAssistantRowIsNotPersistedAndRestores;
    procedure TestRestoreSkipsReasoningAndErrors;
    procedure TestRestoreAfterReopen;
    procedure TestTailKeepsSystemAndRecent;
    procedure TestTailDropsOrphanTools;
    procedure TestResumeFromCheckpointShrinksContext;
    procedure TestAppendMapsRolesAndToolFields;
    procedure TestQueryMessagesReturnsAllBlocks;
    procedure TestBeginFinishTurnAndRequestRecorded;
    procedure TestPromptCapsLargeToolResult;
    procedure TestPromptLeavesSmallToolResultIntact;
    procedure TestCapZeroDisablesTruncation;
    procedure TestRenderStillShowsFullResult;
    procedure TestAppendAmbientRoundTrip;
    procedure TestComposeWrapsAmbientAsUser;
    procedure TestFormatAmbientEscapes;
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

procedure TSessionTest.TestEmptyAssistantRowIsNotPersistedAndRestores;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: IConversationStore;
  Msgs: TChatMessageArray;
  Recs: TMessageRecordArray;
  Asst: TChatMessage;
  I, AssistantRows: Integer;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);
    Conv.Append(UserMsg('hi'));
    { An assistant message that only carried tool calls: no content. }
    Asst := AssistantMsg('');
    Conv.Append(Asst);
    Conv.Append(ToolMsg('call_1', 'time'));
    Conv.Append(ToolMsg('call_2', 'out'));

    { No empty assistant row is persisted. }
    AssertTrue('query', S.QueryMessages(SessionId, Recs, Err));
    AssistantRows := 0;
    for I := 0 to High(Recs) do
      if Recs[I].Role = mrAssistant then
      begin
        Inc(AssistantRows);
        AssertTrue('assistant row has content', Recs[I].Content <> '');
      end;
    AssertEquals('no empty assistant row', 0, AssistantRows);

    { Restore still synthesises the assistant message with its tool calls. }
    Msgs := Conv.Messages;
    AssertEquals('user + assistant + 2 tools', 4, Length(Msgs));
    AssertEquals('assistant synthesised', Ord(crAssistant), Ord(Msgs[1].Role));
    AssertEquals('two tool calls restored', 2, Length(Msgs[1].ToolCalls));
    AssertEquals('call id', 'call_1', Msgs[1].ToolCalls[0].Id);
    AssertEquals('tool result follows', Ord(crTool), Ord(Msgs[2].Role));
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
    Conv.AppendReasoning('thinking...', 0);
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
    Conv.AppendReasoning('why', 2300);
    Conv.AppendError('bad', 'details');

    AssertTrue('query', S.QueryMessages(SessionId, Records, Err));
    AssertEquals('three blocks', 3, Length(Records));
    AssertEquals('reasoning role', Ord(mrReasoning), Ord(Records[1].Role));
    AssertEquals('reasoning content', 'why', Records[1].Content);
    AssertEquals('reasoning duration', 2300, Records[1].DurationMs);
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

procedure TSessionTest.TestAppendAmbientRoundTrip;
var
  S: TSqliteStore;
  Conv: TSqliteConversationStore;
  Recs: TMessageRecordArray;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    Conv := TSqliteConversationStore.Create(S, Sid, 0);
    try
      Conv.AppendAmbient('subagent done: 3 files', 'child-abc', 'research',
        'delegate_task', 'completed', 4200);
    finally
      Conv.Free;
    end;
    AssertTrue('query', S.QueryMessages(Sid, Recs, Err));
    AssertEquals('one record', 1, Length(Recs));
    AssertEquals('ambient role', Ord(mrAmbient), Ord(Recs[0].Role));
    AssertEquals('content', 'subagent done: 3 files', Recs[0].Content);
    AssertEquals('ref session', 'child-abc', Recs[0].RefSessionId);
    AssertEquals('label', 'research', Recs[0].LabelText);
    AssertEquals('source', 'delegate_task', Recs[0].Source);
    AssertEquals('status', 'completed', Recs[0].Status);
    AssertEquals('elapsed', 4200, Recs[0].DurationMs);
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestComposeWrapsAmbientAsUser;
var
  S: TSqliteStore;
  Conv: TSqliteConversationStore;
  Msgs: TChatMessageArray;
  Err: TStoreError;
  Ws: Integer;
  Sid: string;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', Ws, Err);
    S.CreateSession(Ws, Sid, Err);
    Conv := TSqliteConversationStore.Create(S, Sid, 0);
    try
      Conv.AppendAmbient('the result text', 'child-xyz', 'research',
        'delegate_task', 'completed', 1000);
      Msgs := Conv.Messages;
      AssertEquals('one provider message', 1, Length(Msgs));
      AssertEquals('delivered as user', Ord(crUser), Ord(Msgs[0].Role));
      AssertTrue('wrapped', Pos('<ambient ', Msgs[0].Content) = 1);
      AssertTrue('message element', Pos('<message source="delegate_task"',
        Msgs[0].Content) > 0);
      AssertTrue('carries id', Pos('id="child-xyz"', Msgs[0].Content) > 0);
      AssertTrue('carries label', Pos('label="research"',
        Msgs[0].Content) > 0);
      AssertTrue('carries status', Pos('status="completed"',
        Msgs[0].Content) > 0);
      AssertTrue('carries the text', Pos('the result text',
        Msgs[0].Content) > 0);
      AssertTrue('carries instructions', Pos('<instructions>',
        Msgs[0].Content) > 0);
    finally
      Conv.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TSessionTest.TestFormatAmbientEscapes;
var
  S: string;
begin
  S := FormatAmbient('a < b & c > d', 'child-1', 'lbl', 'delegate_task', 'completed', 0);
  AssertTrue('escaped lt', Pos('a &lt; b', S) > 0);
  AssertTrue('escaped amp', Pos('&amp;', S) > 0);
  AssertTrue('escaped gt', Pos('c &gt; d', S) > 0);
  AssertTrue('id attr', Pos('id="child-1"', S) > 0);
  AssertTrue('label attr', Pos('label="lbl"', S) > 0);
  AssertTrue('source attr', Pos('source="delegate_task"', S) > 0);
  AssertTrue('status attr', Pos('status="completed"', S) > 0);
  AssertTrue('timestamp attr', Pos('timestamp="', S) > 0);
  AssertTrue('instructions block', Pos('<instructions>', S) > 0);
end;

procedure TSessionTest.TestResumeFromCheckpointShrinksContext;
var
  S: TSqliteStore;
  Err: TStoreError;
  SessionId: string;
  WorkspaceId: Integer;
  Conv: IConversationStore;
  Msgs: TChatMessageArray;
  Seq: Int64;
  I: Integer;
  Sys, PlainAsst: TChatMessage;
  Checked: TCheckpointRecord;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);
    { A system prompt and several turns of plain history. }
    Sys := Default(TChatMessage);
    Sys.Role := crSystem;
    Sys.Content := 'you are a test';
    Conv.Append(Sys);
    for I := 1 to 5 do
    begin
      Conv.Append(UserMsg('turn ' + IntToStr(I)));
      PlainAsst := Default(TChatMessage);
      PlainAsst.Role := crAssistant;
      PlainAsst.Content := 'reply ' + IntToStr(I);
      Conv.Append(PlainAsst);
    end;
    { Before the checkpoint: the full history replays. }
    Msgs := Conv.Messages;
    AssertTrue('full history replays', Length(Msgs) >= 11);

    { Record a checkpoint at the current HWM. }
    AssertTrue('checkpoint', S.SaveCheckpoint(SessionId, 'we did turns 1-5', Seq,
      Err));
    AssertEquals('boundary is the hwm', 11, Seq);
    Checked := Default(TCheckpointRecord);
    AssertTrue('latest finds it', S.LatestCheckpoint(SessionId, Checked, Err));

    { Resume: the system prompt + the checkpoint context, and the archived
      turns are gone from the prompt. }
    Msgs := Conv.Messages;
    AssertEquals('system + checkpoint context', 2, Length(Msgs));
    AssertEquals('system first', Ord(crSystem), Ord(Msgs[0].Role));
    AssertEquals('context is system', Ord(crSystem), Ord(Msgs[1].Role));
    AssertTrue('carries the summary', Pos('we did turns 1-5', Msgs[1].Content) > 0);
    AssertTrue('marked as carried-forward',
      Pos('carried forward', Msgs[1].Content) > 0);
    AssertTrue('marked as carried-forward',
      Pos('carried forward', Msgs[1].Content) > 0);
  finally
    S.Free;
  end;
end;

initialization
  RegisterTest(TSessionTest);
end.