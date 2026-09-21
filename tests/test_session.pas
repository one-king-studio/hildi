unit test_session;
{ fpcunit tests for hildegard.helper.session and the SQLite conversation
  adapter: session ids, the ledger round trip, and restore. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.store, hildegard.helper.session,
  hildegard.helper.session.store, hildegard.helper.llm, hildegard.helper.agent;

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
  Call.Arguments := '{"reason":"r"}';
  SetLength(Result.ToolCalls, 1);
  Result.ToolCalls[0] := Call;
  Call.Id := 'call_2';
  Call.Name := 'run_command';
  Call.Arguments := '{"command":"date","reason":"r"}';
  SetLength(Result.ToolCalls, 2);
  Result.ToolCalls[1] := Call;
end;

function TSessionTest.ToolMsg(const AId, AText: string): TChatMessage;
begin
  Result := Default(TChatMessage);
  Result.Role := crTool;
  Result.ToolCallId := AId;
  Result.Content := AText;
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
  Rec: TSessionRecord;
begin
  S := OpenStore;
  try
    S.EnsureWorkspace('/tmp', WorkspaceId, Err);
    S.CreateSession(WorkspaceId, SessionId, Err);
    Conv := TSqliteConversationStore.Create(S, SessionId);
    Conv.Append(UserMsg('hello'));

    Rec := Default(TSessionRecord);
    Rec.SessionId := SessionId;
    Rec.Kind := srkReasoning;
    Rec.Content := 'thinking...';
    S.AppendSessionRecord(Rec, Err);
    Rec.Kind := srkError;
    Rec.Content := 'boom';
    S.AppendSessionRecord(Rec, Err);

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

initialization
  RegisterTest(TSessionTest);
end.
