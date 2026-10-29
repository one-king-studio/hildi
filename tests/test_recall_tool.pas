unit test_recall_tool;
{ fpcunit tests for hildi.recall.tool: windowed reads of a stored
  tool result, capped and never spilled. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildi.store, hildi.session,
  hildi.agent, hildi.recall.tool;

type
  TRecallToolTest = class(TTestCase)
  private
    FDir, FDbPath: string;
    FStore: TSqliteStore;
    FSessionId: string;
    FToolId: Int64;
    FUserId: Int64;
    FContent: string;
    FTool: TRecallTool;
    procedure Seed(const AContent: string);
    function Recall(AOffset, ALimit: Integer;
      out AResult, AError: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRecallReturnsWindow;
    procedure TestRecallDefaultsToCap;
    procedure TestRecallClampsToArtifact;
    procedure TestRecallCapsOverLargeLimit;
    procedure TestRecallUnknownIdFails;
    procedure TestRecallNonToolIdFails;
    procedure TestRecallNegativeOffsetFails;
    procedure TestRecallRegistersTheTool;
    procedure TestRecallSearchFindsMessage;
    procedure TestRecallSearchNoMatch;
  end;

implementation

procedure TRecallToolTest.SetUp;
var
  Cfg: TStoreConfig;
  Err: TStoreError;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhrecall_' +
    IntToStr(GetTickCount64) + '_' + IntToStr(Random(100000));
  CreateDir(FDir);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'store.db';
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  FStore := TSqliteStore.Create(Cfg);
  if not FStore.Open(Err) then
    raise Exception.Create('store failed to open: ' + Err.Message);
  Seed('0123456789abcdefghij');   // 20 bytes
  FTool := TRecallTool.Create(FStore, FSessionId, 8);
end;

procedure TRecallToolTest.TearDown;
begin
  FTool.Free;
  FStore.Free;
  DeleteFile(FDbPath);
  DeleteFile(FDbPath + '-wal');
  DeleteFile(FDbPath + '-shm');
  RemoveDir(FDir);
end;

procedure TRecallToolTest.Seed(const AContent: string);
var
  Err: TStoreError;
  WorkspaceId: Integer;
  TurnId: Int64;
  Rec: TMessageRecord;
  Records: TMessageRecordArray;
begin
  FContent := AContent;
  FStore.EnsureWorkspace('/tmp', WorkspaceId, Err);
  FStore.CreateSession(WorkspaceId, FSessionId, Err);
  FStore.BeginTurn(FSessionId, TurnId, Err);
  Rec := Default(TMessageRecord);
  Rec.SessionId := FSessionId;
  Rec.TurnId := TurnId;
  Rec.Role := mrUser;
  Rec.Content := 'ask';
  FStore.AppendMessage(Rec, Err);
  Rec := Default(TMessageRecord);
  Rec.SessionId := FSessionId;
  Rec.TurnId := TurnId;
  Rec.Role := mrTool;
  Rec.ToolCallId := 'c1';
  Rec.ToolName := 'run_command';
  Rec.ToolOk := True;
  Rec.Content := AContent;
  FStore.AppendMessage(Rec, Err);
  FStore.QueryMessages(FSessionId, Records, Err);
  FUserId := Records[0].Id;
  FToolId := Records[1].Id;
end;

function TRecallToolTest.Recall(AOffset, ALimit: Integer;
  out AResult, AError: string): Boolean;
var
  Args: string;
begin
  if ALimit < 0 then
    Args := Format('{"message_id":%d,"offset":%d,"reason":"r"}',
      [FToolId, AOffset])
  else
    Args := Format('{"message_id":%d,"offset":%d,"limit":%d,"reason":"r"}',
      [FToolId, AOffset, ALimit]);
  Result := FTool.Recall(Args, AResult, AError);
end;

procedure TRecallToolTest.TestRecallReturnsWindow;
var
  Out_, ErrStr: string;
begin
  AssertTrue('recall', Recall(5, 4, Out_, ErrStr));
  AssertEquals('window', '5678', Out_);
end;

procedure TRecallToolTest.TestRecallDefaultsToCap;
var
  Out_, ErrStr: string;
begin
  AssertTrue('recall', Recall(0, -1, Out_, ErrStr));
  AssertEquals('cap-sized window', '01234567', Out_);
end;

procedure TRecallToolTest.TestRecallClampsToArtifact;
var
  Out_, ErrStr: string;
begin
  AssertTrue('recall', Recall(15, 1000, Out_, ErrStr));
  AssertEquals('only the tail remains', 'fghij', Out_);
end;

procedure TRecallToolTest.TestRecallCapsOverLargeLimit;
var
  Out_, ErrStr: string;
begin
  AssertTrue('recall', Recall(0, 1000, Out_, ErrStr));
  AssertEquals('capped at the cap', 8, Length(Out_));
  AssertTrue('no truncation marker',
    Pos('output truncated', Out_) = 0);
end;

procedure TRecallToolTest.TestRecallUnknownIdFails;
var
  Out_, ErrStr: string;
begin
  AssertFalse('fails', FTool.Recall(
    '{"message_id":999999,"offset":0,"reason":"r"}', Out_, ErrStr));
  AssertTrue('names the id', Pos('999999', ErrStr) > 0);
end;

procedure TRecallToolTest.TestRecallNonToolIdFails;
var
  Out_, ErrStr: string;
begin
  AssertFalse('fails', FTool.Recall(Format(
    '{"message_id":%d,"offset":0,"reason":"r"}', [FUserId]), Out_, ErrStr));
  AssertTrue('names the problem', Pos('not a tool result', ErrStr) > 0);
end;

procedure TRecallToolTest.TestRecallNegativeOffsetFails;
var
  Out_, ErrStr: string;
begin
  AssertFalse('fails', Recall(-1, 4, Out_, ErrStr));
  AssertTrue('names offset', Pos('offset', ErrStr) > 0);
end;

procedure TRecallToolTest.TestRecallRegistersTheTool;
var
  Tools: TToolRegistry;
  Stored: TRegisteredTool;
begin
  Tools := TToolRegistry.Create;
  try
    FTool.Register(Tools);
    AssertTrue('registered', Tools.Find(RecallToolName, Stored));
    AssertTrue('reason required',
      Pos('"reason"', Stored.Spec.ParametersJson) > 0);
  finally
    Tools.Free;
  end;
end;

procedure TRecallToolTest.TestRecallSearchFindsMessage;
var
  Res, Err: string;
begin
  { The seeded tool result content is '0123456789abcdefghij' — one FTS token. }
  AssertTrue('search', FTool.Recall(
    '{"query":"0123456789abcdefghij","reason":"r"}', Res, Err));
  AssertTrue('found', Pos('0123456789abcdefghij', Res) > 0);
end;

procedure TRecallToolTest.TestRecallSearchNoMatch;
var
  Res, Err: string;
begin
  AssertTrue('search', FTool.Recall(
    '{"query":"zzznomatch","reason":"r"}', Res, Err));
  AssertEquals('no matches', '(no matches)', Res);
end;

initialization
  RegisterTest(TRecallToolTest);
end.