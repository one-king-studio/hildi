unit test_tasks_tools;
{ Tests for the task list's ten tools and its tail work queue. Real SQLite.

  The interesting behaviours are the refusals and the hand-offs: a second claim
  naming the holder, a transition by a non-holder, the two gated verbs changing
  nothing on a denial, and the tail staying inside its budget with a hundred
  cards on the board. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, fpcunit, testregistry,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.store, hildegard.helper.tasks, hildegard.helper.tasks.store,
  hildegard.helper.tasks.tools, hildegard.helper.sqlite;

type
  TFakeTaskApproval = class(TInterfacedObject, IApprovalService)
  public
    Allow: Boolean;
    Asks: Integer;
    LastSummary: string;
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

  TTaskToolsTest = class(TTestCase)
  private
    FDir, FDbPath: string;
    FStore: TSqliteStore;
    FTasks: ITaskStore;
    FTools: TTaskTool;
    FToolsNoGate: TTaskTool;
    FApproval: TFakeTaskApproval;
    ApprovalRef: IApprovalService;
    FReg: TToolRegistry;
    { A board-question seam the test controls. }
    FQuestionExists: Boolean;
    FQuestionId: Integer;
    function QuestionHook(AWorkspaceId, AId: Integer;
      out ATitle: string): Boolean;
    function IdFromResult(const AText: string): Integer;
    procedure AgeCard(AId: Integer; ASecondsAgo: Integer);
    function AddOne(const ATitle: string; AParent: Integer = 0): Integer;
    function ClaimOne(AId: Integer): Boolean;
    function Call(AHandler: TToolHandler; const AJson: string;
      out AResult, AError: string): Boolean;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestAddCreatesAnOpenCard;
    procedure TestAddRefusesASubtaskOfASubtask;
    procedure TestClaimThenASecondClaimNamesTheHolderAndTheAge;
    procedure TestClaimingADoneCardNamesTheStatus;
    procedure TestClaimingAMissingCardNamesTheId;
    procedure TestReleaseNeedsTheClaim;
    procedure TestDoneFromOpenIsRefusedThroughTheTool;
    procedure TestDoneRecordsTheNote;
    procedure TestDropNeedsAReason;
    procedure TestAnUnclaimedCardCanBeDropped;
    procedure TestBlockResolvesACardAndRefusesAGhost;
    procedure TestBlockResolvesABoardQuestion;
    procedure TestBlockRefusesAQuestionWithNoBoard;
    procedure TestEditCannotChangeStatus;
    procedure TestEditLeavesAnAbsentFieldAlone;
    procedure TestAllTenToolsAreRegistered;
    procedure TestReassignAsksAndADenialChangesNothing;
    procedure TestDeleteAsksAndADenialChangesNothing;
    procedure TestDeleteAllowedRemovesTheCard;
    procedure TestEveryUngatedVerbRunsWithNoGateConfigured;
    { The tail work queue. }
    procedure TestTheQueueShowsMineFirstWithItsAge;
    procedure TestTheQueueCapsOpenAtThree;
    procedure TestTheQueueIsEmptyWithNoWork;
    procedure TestTheQueueStaysInsideItsBudgetWithAHundredCards;
    procedure TestTheQueueDropOrderNeverLosesMine;
    { A block is shown when it is yours OR has gone stale, and not otherwise. }
    procedure TestTheQueueShowsYourOwnBlockImmediately;
    procedure TestTheQueueShowsAStaleBlockHeldByAnotherSession;
    procedure TestTheQueueHidesAFreshBlockHeldByAnotherSession;
  end;

implementation

function TFakeTaskApproval.Resolve(const AAsks: TApprovalAskArray;
  out AResult: TApprovalBatchResult): Boolean;
begin
  Inc(Asks);
  if Length(AAsks) > 0 then
    LastSummary := AAsks[0].Summary;
  AResult := Default(TApprovalBatchResult);
  if Allow then
    AResult.Allowed := True
  else
  begin
    AResult.Denied := True;
    AResult.Reason := 'operator said no';
  end;
  Result := True;
end;

{ Stands in for the board: resolves only the id the test nominated. }
function TTaskToolsTest.QuestionHook(AWorkspaceId, AId: Integer;
  out ATitle: string): Boolean;
begin
  Result := FQuestionExists and (AId = FQuestionId);
  if Result then
    ATitle := 'is the drain safe?'
  else
    ATitle := '';
end;

procedure TTaskToolsTest.SetUp;
var
  Cfg: TStoreConfig;
  Err: TStoreError;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhtt_' +
    IntToStr(GetTickCount64);
  ForceDirectories(FDir);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'tt.db';
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  FStore := TSqliteStore.Create(Cfg);
  if not FStore.Open(Err) then
    raise Exception.Create('open: ' + Err.Message);
  FTasks := TSqliteTaskStore.Create(FStore);
  FApproval := TFakeTaskApproval.Create;
  ApprovalRef := FApproval;
  FQuestionExists := False;
  FQuestionId := 0;
  { The hook is an object method, so it must be bound to this instance. }
  FTools := TTaskTool.Create(FTasks, 1, 'sess-a', 'parent', ApprovalRef,
    QuestionHook);
  FToolsNoGate := TTaskTool.Create(FTasks, 1, 'sess-a', 'parent', nil, nil);
  FReg := TToolRegistry.Create;
  FToolsNoGate.Register(FReg);
end;

procedure TTaskToolsTest.TearDown;
begin
  FReg.Free;
  FToolsNoGate.Free;
  FTools.Free;
  FApproval := nil;
  FTasks := nil;
  if FStore <> nil then
  begin
    FStore.Close;
    FStore.Free;
    FStore := nil;
  end;
  if FileExists(FDbPath) then
    DeleteFile(FDbPath);
  if DirectoryExists(FDir) then
    RemoveDir(FDir);
end;

{ "added #7 title" -> 7. The id is what follows '#', up to the next space. }
function TTaskToolsTest.IdFromResult(const AText: string): Integer;
var
  P, Q: Integer;
  Digits: string;
begin
  P := Pos('#', AText);
  if P = 0 then
    Exit(0);
  Digits := '';
  for Q := P + 1 to Length(AText) do
  begin
    if AText[Q] in ['0'..'9'] then
      Digits := Digits + AText[Q]
    else
      Break;
  end;
  Result := StrToIntDef(Digits, 0);
end;

function TTaskToolsTest.AddOne(const ATitle: string; AParent: Integer): Integer;
var
  Res, Err: string;
begin
  Result := 0;
  AssertTrue('add ' + ATitle, Call(FTools.AddCard,
    '{"title":"' + ATitle + '","reason":"test"' +
    IfThen(AParent <> 0, ',"parent":' + IntToStr(AParent)) + '}', Res, Err));
  Result := IdFromResult(Res);
  AssertTrue('parsed an id from "' + Res + '"', Result > 0);
end;

function TTaskToolsTest.ClaimOne(AId: Integer): Boolean;
var
  Res, Err: string;
begin
  Result := Call(FTools.ClaimCard, '{"id":' + IntToStr(AId) +
    ',"reason":"test"}', Res, Err);
end;

function TTaskToolsTest.Call(AHandler: TToolHandler; const AJson: string;
  out AResult, AError: string): Boolean;
begin
  Result := AHandler(AJson, AResult, AError, nil);
end;

{ --- registration ------------------------------------------------------ }

procedure TTaskToolsTest.TestAllTenToolsAreRegistered;
var
  Specs: TToolSpecArray;
  I, N: Integer;
  Names: string;
begin
  Specs := FReg.Specs;
  Names := '';
  N := 0;
  for I := 0 to High(Specs) do
  begin
    if Specs[I].Name = '' then
      Continue;
    Inc(N);
    if Names <> '' then
      Names := Names + ', ';
    Names := Names + Specs[I].Name;
  end;
  { Six tools carrying ten verbs. The tool count is what the request pays for,
    so the two moderate verbs share one entry and the five update verbs share
    another. }
  AssertEquals('tool count: ' + Names, 6, N);
  AssertTrue('task_list', Pos('task_list', Names) > 0);
  AssertTrue('task_add', Pos('task_add', Names) > 0);
  AssertTrue('task_claim', Pos('task_claim', Names) > 0);
  AssertTrue('task_update', Pos('task_update', Names) > 0);
  AssertTrue('task_edit', Pos('task_edit', Names) > 0);
  AssertTrue('task_moderate', Pos('task_moderate', Names) > 0);
end;

{ --- add --------------------------------------------------------------- }

procedure TTaskToolsTest.TestAddCreatesAnOpenCard;
var
  Id: Integer;
  Back: TTaskCard;
  Found: Boolean;
  Err: string;
begin
  Id := AddOne('write the drain');
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('open', Ord(tsOpen), Ord(Back.Status));
  AssertEquals('title', 'write the drain', Back.Title);
  AssertEquals('from session', 'sess-a', Back.FromSession);
  { A zero timestamp would make the card infinitely old and let retention prune
    it on sight. }
  AssertTrue('created_at is set', Back.CreatedAt > 0);
  AssertEquals('and nobody holds it', '', Back.ClaimedBy);
end;

procedure TTaskToolsTest.TestAddRefusesASubtaskOfASubtask;
var
  ParentId, ChildId: Integer;
  Res, Err: string;
  Mid: TTaskCard;
  Found: Boolean;
begin
  ParentId := AddOne('top');
  ChildId := AddOne('child', ParentId);
  { Diagnostic: is the parent link persisted at all? }
  AssertTrue('get child', FTasks.Get(1, ChildId, Mid, Found, Err));
  AssertTrue('child found', Found);
  AssertEquals('parent id ' + IntToStr(ParentId) + ' -> ' + IntToStr(ChildId),
    ParentId, Mid.Parent);
  AssertFalse('a grandchild is refused', Call(FTools.AddCard,
    '{"title":"grandchild","parent":' + IntToStr(ChildId) +
    ',"reason":"test"}', Res, Err));
  AssertTrue('says why: ' + Err, Pos('one level', Err) > 0);
end;

{ --- the claim CAS, through the tool ----------------------------------- }

procedure TTaskToolsTest.TestClaimThenASecondClaimNamesTheHolderAndTheAge;
var
  Id: Integer;
  Res, Err: string;
  Other: TTaskTool;
begin
  Id := AddOne('contended');
  AssertTrue('first claim', ClaimOne(Id));
  { A second session reaching for the same card. }
  Other := TTaskTool.Create(FTasks, 1, 'sess-b', 'parent', nil, nil);
  try
    AssertFalse('second claim refused', Call(Other.ClaimCard,
      '{"id":' + IntToStr(Id) + ',"reason":"test"}', Res, Err));
  finally
    Other.Free;
  end;
  { This message is the feature: who holds it, and for how long. }
  AssertTrue('names the holder: ' + Err, Pos('sess-a', Err) > 0);
  AssertTrue('and the age: ' + Err, Pos(' ago', Err) > 0);
  AssertTrue('and the card: ' + Err, Pos('#' + IntToStr(Id), Err) > 0);
end;

procedure TTaskToolsTest.TestClaimingADoneCardNamesTheStatus;
var
  Id: Integer;
  Res, Err: string;
begin
  Id := AddOne('finish me');
  AssertTrue('claim', ClaimOne(Id));
  AssertTrue('done', Call(FTools.TransitionCard, '{"op":"done","id":' +
    IntToStr(Id) + ',"note":"did it","reason":"test"}', Res, Err));
  { Call the tool directly: ClaimOne returns only a Boolean and would discard the
    message this test exists to read. }
  AssertFalse('claiming it now fails', Call(FTools.ClaimCard,
    '{"id":' + IntToStr(Id) + ',"reason":"test"}', Res, Err));
  AssertTrue('naming the status: ' + Err, Pos('done', Err) > 0);
end;

procedure TTaskToolsTest.TestClaimingAMissingCardNamesTheId;
var
  Res, Err: string;
begin
  AssertFalse('no such card', Call(FTools.ClaimCard,
    '{"id":999,"reason":"test"}', Res, Err));
  AssertTrue('names the id: ' + Err, Pos('999', Err) > 0);
end;

{ --- transitions ------------------------------------------------------- }

procedure TTaskToolsTest.TestReleaseNeedsTheClaim;
var
  Id: Integer;
  Res, Err: string;
  Other: TTaskTool;
begin
  Id := AddOne('held');
  AssertTrue('claim', ClaimOne(Id));
  Other := TTaskTool.Create(FTasks, 1, 'sess-b', 'parent', nil, nil);
  try
    AssertFalse('a non-holder cannot release it', Call(Other.TransitionCard,
      '{"op":"release","id":' + IntToStr(Id) + ',"reason":"test"}', Res, Err));
  finally
    Other.Free;
  end;
  AssertTrue('still held by sess-a', Pos('sess-a', Err) > 0);
  AssertTrue('the holder can', Call(FTools.TransitionCard,
    '{"op":"release","id":' + IntToStr(Id) + ',"reason":"test"}', Res, Err));
end;

procedure TTaskToolsTest.TestDoneFromOpenIsRefusedThroughTheTool;
var
  Id: Integer;
  Res, Err: string;
begin
  Id := AddOne('nobody claimed this');
  AssertFalse('done from open is refused', Call(FTools.TransitionCard,
    '{"op":"done","id":' + IntToStr(Id) + ',"note":"x","reason":"test"}',
    Res, Err));
  AssertTrue('and says what is legal: ' + Err, Pos('open', Err) > 0);
end;

procedure TTaskToolsTest.TestDoneRecordsTheNote;
var
  Id: Integer;
  Res, Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  Id := AddOne('finish with a note');
  AssertTrue('claim', ClaimOne(Id));
  AssertTrue('done', Call(FTools.TransitionCard, '{"op":"done","id":' +
    IntToStr(Id) + ',"note":"shipped it","reason":"test"}', Res, Err));
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('done', Ord(tsDone), Ord(Back.Status));
  AssertEquals('note kept', 'shipped it', Back.DoneNote);
  AssertEquals('and the claim is released', '', Back.ClaimedBy);
end;

procedure TTaskToolsTest.TestDropNeedsAReason;
var
  Id: Integer;
  Res, Err: string;
begin
  Id := AddOne('drop me');
  AssertFalse('no note, no drop', Call(FTools.TransitionCard,
    '{"op":"drop","id":' + IntToStr(Id) + ',"reason":"test"}', Res, Err));
  AssertTrue('says why: ' + Err, Pos('reason', Err) > 0);
end;

procedure TTaskToolsTest.TestAnUnclaimedCardCanBeDropped;
var
  Id: Integer;
  Res, Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  Id := AddOne('abandoned');
  AssertTrue('drop', Call(FTools.TransitionCard, '{"op":"drop","id":' +
    IntToStr(Id) + ',"note":"not needed","reason":"test"}', Res, Err));
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('dropped', Ord(tsDropped), Ord(Back.Status));
end;

{ --- blocking ---------------------------------------------------------- }

procedure TTaskToolsTest.TestBlockResolvesACardAndRefusesAGhost;
var
  BlockedId, BlockerId: Integer;
  Res, Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  BlockerId := AddOne('the blocker');
  BlockedId := AddOne('the blocked');
  AssertTrue('claim', ClaimOne(BlockedId));
  AssertTrue('block on a real card', Call(FTools.TransitionCard,
    '{"op":"block","id":' + IntToStr(BlockedId) + ',"blocked_on":"' +
    IntToStr(BlockerId) + '","reason":"test"}', Res, Err));
  AssertTrue('get', FTasks.Get(1, BlockedId, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('blocked', Ord(tsBlocked), Ord(Back.Status));
  AssertEquals('on the card', BlockerId, Back.BlockedOnId);
  AssertEquals('of kind card', Ord(tbkCard), Ord(Back.BlockedOnKind));

  { A ghost id is refused rather than recorded as a blocker pointing nowhere. }
  AssertFalse('a ghost blocker is refused', Call(FTools.TransitionCard,
    '{"op":"block","id":' + IntToStr(BlockerId) + ',"blocked_on":"999",' +
    '"reason":"test"}', Res, Err));
  AssertTrue('naming it: ' + Err, Pos('999', Err) > 0);
end;

procedure TTaskToolsTest.TestBlockResolvesABoardQuestion;
var
  BlockedId: Integer;
  Res, Err: string;
  Back: TTaskCard;
  Found: Boolean;
  Q: TTaskTool;
begin
  FQuestionExists := True;
  FQuestionId := 12;
  Q := TTaskTool.Create(FTasks, 1, 'sess-a', 'parent', nil,
    QuestionHook);
  try
    BlockedId := AddOne('waiting on an answer');
    AssertTrue('claim', ClaimOne(BlockedId));
    AssertTrue('block on a question', Call(Q.TransitionCard,
      '{"op":"block","id":' + IntToStr(BlockedId) +
      ',"blocked_on":"question:12","reason":"test"}', Res, Err));
  finally
    Q.Free;
  end;
  AssertTrue('get', FTasks.Get(1, BlockedId, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('blocked', Ord(tsBlocked), Ord(Back.Status));
  AssertEquals('on question 12', 12, Back.BlockedOnId);
  { The discriminator is the point: the same id space, resolved to the right
    table. }
  AssertEquals('of kind question', Ord(tbkQuestion), Ord(Back.BlockedOnKind));
end;

procedure TTaskToolsTest.TestBlockRefusesAQuestionWithNoBoard;
var
  BlockedId: Integer;
  Res, Err: string;
begin
  BlockedId := AddOne('wants a board');
  AssertTrue('claim', ClaimOne(BlockedId));
  AssertFalse('no board, no question blocker', Call(FTools.TransitionCard,
    '{"op":"block","id":' + IntToStr(BlockedId) +
    ',"blocked_on":"question:12","reason":"test"}', Res, Err));
  AssertTrue('says there is no board: ' + Err, Pos('no board', Err) > 0);
end;

{ --- edit -------------------------------------------------------------- }

procedure TTaskToolsTest.TestEditCannotChangeStatus;
var
  Id: Integer;
  Res, Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  Id := AddOne('edit me');
  AssertFalse('a status field is refused', Call(FTools.EditCard,
    '{"id":' + IntToStr(Id) + ',"status":"done","reason":"test"}', Res, Err));
  AssertTrue('says to use a verb: ' + Err, Pos('task_update', Err) > 0);
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('still open', Ord(tsOpen), Ord(Back.Status));
end;

procedure TTaskToolsTest.TestEditLeavesAnAbsentFieldAlone;
var
  Id: Integer;
  Res, Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  AssertTrue('add with a body', Call(FTools.AddCard,
    '{"title":"old title","body":"keep me","reason":"test"}', Res, Err));
  Id := IdFromResult(Res);
  AssertTrue('edit the title only', Call(FTools.EditCard,
    '{"id":' + IntToStr(Id) + ',"title":"new title","reason":"test"}',
    Res, Err));
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('title changed', 'new title', Back.Title);
  { An edit that silently blanked the body would be a data loss nobody asked
    for. }
  AssertEquals('body kept', 'keep me', Back.Body);
end;

{ --- gating ------------------------------------------------------------ }

procedure TTaskToolsTest.TestReassignAsksAndADenialChangesNothing;
var
  Id: Integer;
  Res, Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  Id := AddOne('reassign me');
  AssertTrue('claim', ClaimOne(Id));
  FApproval.Allow := False;
  AssertFalse('denied', Call(FTools.ModerateCard, '{"op":"reassign","id":' +
    IntToStr(Id) + ',"session":"sess-b","reason":"hand off"}', Res, Err));
  AssertEquals('asked once', 1, FApproval.Asks);
  AssertTrue('asked about the card: ' + FApproval.LastSummary,
    Pos('reassign me', FApproval.LastSummary) > 0);
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('still sess-a', 'sess-a', Back.ClaimedBy);
  AssertEquals('still claimed', Ord(tsClaimed), Ord(Back.Status));
end;

procedure TTaskToolsTest.TestDeleteAsksAndADenialChangesNothing;
var
  Id: Integer;
  Res, Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  Id := AddOne('delete me');
  FApproval.Allow := False;
  AssertFalse('denied', Call(FTools.ModerateCard, '{"op":"delete","id":' +
    IntToStr(Id) + ',"reason":"cleanup"}', Res, Err));
  AssertTrue('asked', FApproval.Asks > 0);
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertTrue('the card is still there', Found);
end;

procedure TTaskToolsTest.TestDeleteAllowedRemovesTheCard;
var
  Id: Integer;
  Res, Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  Id := AddOne('delete me for real');
  FApproval.Allow := True;
  AssertTrue('allowed', Call(FTools.ModerateCard, '{"op":"delete","id":' +
    IntToStr(Id) + ',"reason":"cleanup"}', Res, Err));
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertFalse('the card is gone', Found);
end;

procedure TTaskToolsTest.TestEveryUngatedVerbRunsWithNoGateConfigured;
var
  Id, BlockedId: Integer;
  Res, Err: string;
begin
  { FToolsNoGate has NO approval service at all: these must run because they are
    ungated, not merely because nobody was asked. }
  AssertTrue('add', Call(FToolsNoGate.AddCard, '{"title":"ungated","reason":"t"}',
    Res, Err));
  Id := IdFromResult(Res);
  AssertTrue('list', Call(FToolsNoGate.ListCards, '{"reason":"t"}', Res, Err));
  AssertTrue('claim', Call(FToolsNoGate.ClaimCard, '{"id":' + IntToStr(Id) +
    ',"reason":"t"}', Res, Err));
  AssertTrue('edit', Call(FToolsNoGate.EditCard, '{"id":' + IntToStr(Id) +
    ',"title":"ungated 2","reason":"t"}', Res, Err));
  AssertTrue('release', Call(FToolsNoGate.TransitionCard, '{"op":"release","id":' +
    IntToStr(Id) + ',"reason":"t"}', Res, Err));
  AssertTrue('claim again', Call(FToolsNoGate.ClaimCard, '{"id":' +
    IntToStr(Id) + ',"reason":"t"}', Res, Err));
  AssertTrue('done', Call(FToolsNoGate.TransitionCard, '{"op":"done","id":' +
    IntToStr(Id) + ',"note":"x","reason":"t"}', Res, Err));
  BlockedId := 0;
  AssertTrue('add a second', Call(FToolsNoGate.AddCard,
    '{"title":"second","reason":"t"}', Res, Err));
  BlockedId := IdFromResult(Res);
  AssertTrue('claim the second', Call(FToolsNoGate.ClaimCard, '{"id":' +
    IntToStr(BlockedId) + ',"reason":"t"}', Res, Err));
  AssertTrue('block', Call(FToolsNoGate.TransitionCard, '{"op":"block","id":' +
    IntToStr(BlockedId) + ',"blocked_on":"' + IntToStr(Id) + '","reason":"t"}',
    Res, Err));
  AssertTrue('unblock', Call(FToolsNoGate.TransitionCard, '{"op":"unblock","id":' +
    IntToStr(BlockedId) + ',"reason":"t"}', Res, Err));
  AssertTrue('drop', Call(FToolsNoGate.TransitionCard, '{"op":"drop","id":' +
    IntToStr(BlockedId) + ',"note":"enough","reason":"t"}', Res, Err));
end;

{ --- the tail work queue ------------------------------------------------ }

procedure TTaskToolsTest.TestTheQueueShowsMineFirstWithItsAge;
var
  Id: Integer;
  Err, Line: string;
begin
  AssertEquals('empty with no work', '', FTools.QueueLine(Err));
  Id := AddOne('wire the drain');
  AssertTrue('claim', ClaimOne(Id));
  Line := FTools.QueueLine(Err);
  AssertTrue('mine is present: ' + Line, Pos('mine="', Line) > 0);
  AssertTrue('naming the card: ' + Line, Pos('wire the drain', Line) > 0);
  { Age, not a timestamp: "0s" is what a model can act on. }
  AssertTrue('with its age: ' + Line, Pos('(0s)', Line) > 0);
  { The tail element is data; the prose lives in the system prompt. }
  AssertTrue('and no prose: ' + Line, Pos('task list', LowerCase(Line)) = 0);
end;

procedure TTaskToolsTest.TestTheQueueCapsOpenAtThree;
var
  I: Integer;
  Err, Line: string;
begin
  for I := 1 to 6 do
    AddOne('card ' + IntToStr(I));
  Line := FTools.QueueLine(Err);
  { The element reports how many open cards EXIST - forty must not look like
    three - while naming only three of them. }
  AssertTrue('reports the true count: ' + Line, Pos('open="6"', Line) > 0);
  AssertTrue('and says how many it did not name: ' + Line,
    Pos('+3 more', Line) > 0);
  { The most recently updated are the ones named. }
  AssertTrue('card 6 is named: ' + Line, Pos('card 6', Line) > 0);
  AssertTrue('card 1 is not: ' + Line, Pos('card 1 ', Line) = 0);
end;

procedure TTaskToolsTest.TestTheQueueIsEmptyWithNoWork;
var
  Err: string;
begin
  { Nothing to say is said with nothing, not with an empty element. }
  AssertEquals('empty queue, empty fragment', '', FTools.QueueLine(Err));
end;

procedure TTaskToolsTest.TestTheQueueStaysInsideItsBudgetWithAHundredCards;
var
  I, Id: Integer;
  Err, Line: string;
begin
  { The open list is capped at three, so a hundred OPEN cards alone cannot
    exceed the budget - a test built only from those can never fail. The
    unbounded part is `mine`: every card this session holds is named. So the
    pressure has to come from claims. }
  for I := 1 to 100 do
  begin
    Id := AddOne('a task title that is deliberately long enough to matter ' +
      IntToStr(I));
    if I <= 12 then
      ClaimOne(Id);
  end;
  Line := FTools.QueueLine(Err);
  AssertTrue('still says something', Line <> '');
  AssertTrue('and stays inside the budget: ' + IntToStr(Length(Line)),
    Length(Line) <= MaxTaskQueueBytes);
end;

procedure TTaskToolsTest.TestTheQueueDropOrderNeverLosesMine;
var
  I, Id, FirstId: Integer;
  Err, Line: string;
begin
  { Mine must survive any amount of pressure: losing your own commitment
    mid-turn is how work gets abandoned. Under pressure the open list goes
    first. }
  for I := 1 to 12 do
  begin
    Id := AddOne('my commitment number ' + IntToStr(I) +
      ' with a long title to eat the budget');
    ClaimOne(Id);
  end;
  FirstId := AddOne('an unclaimed backlog item');
  Line := FTools.QueueLine(Err);
  AssertTrue('inside the budget: ' + IntToStr(Length(Line)),
    Length(Line) <= MaxTaskQueueBytes);
  AssertTrue('mine is not dropped: ' + Line, Pos('mine="', Line) > 0);
  { The open list is what gives way - it is the least costly thing to lose,
    because the count still tells you it is there. }
  AssertTrue('and the open list gave way: ' + Line,
    Pos('an unclaimed backlog item', Line) = 0);
end;

procedure TTaskToolsTest.AgeCard(AId: Integer; ASecondsAgo: Integer);
var
  Sql: string;
begin
  { The store's seam offers no way to backdate a card, and the staleness rule is
    a pure function of status_at. Reaching for the db directly is the honest way
    to test a clock-dependent rule without sleeping for thirty minutes. }
  Sql := 'UPDATE task_cards SET status_at = status_at - ' +
    IntToStr(ASecondsAgo) + ' WHERE id = ' + IntToStr(AId);
  AssertEquals('aged card ' + IntToStr(AId), SQLITE_OK,
    sqlite3_exec(FStore.Db, PAnsiChar(AnsiString(Sql)), nil, nil, nil));
end;

procedure TTaskToolsTest.TestTheQueueShowsYourOwnBlockImmediately;
var
  BlockedId, BlockerId: Integer;
  Res, Err, Line: string;
begin
  { Yours is shown at once: you are the one who needs to know you are stuck. }
  BlockerId := AddOne('the blocker');
  BlockedId := AddOne('mine and blocked');
  AssertTrue('claim', ClaimOne(BlockedId));
  AssertTrue('block', Call(FTools.TransitionCard, '{"op":"block","id":' +
    IntToStr(BlockedId) + ',"blocked_on":"' + IntToStr(BlockerId) +
    '","reason":"t"}', Res, Err));
  Line := FTools.QueueLine(Err);
  AssertTrue('a fresh block of your own is shown: ' + Line,
    Pos('blocked="', Line) > 0);
end;

procedure TTaskToolsTest.TestTheQueueShowsAStaleBlockHeldByAnotherSession;
var
  BlockedId, BlockerId: Integer;
  Res, Err, Line: string;
  Other: TTaskTool;
begin
  { A block nobody is moving is the orchestrator's problem - but only once it has
    sat. Past the threshold it becomes every agent's problem, and it must appear
    even though it is not in Mine. }
  BlockerId := AddOne('the blocker');
  BlockedId := AddOne('someone else is stuck on this');
  Other := TTaskTool.Create(FTasks, 1, 'sess-b', 'parent', nil, nil);
  try
    AssertTrue('sess-b claims', Call(Other.ClaimCard,
      '{"id":' + IntToStr(BlockedId) + ',"reason":"t"}', Res, Err));
    AssertTrue('and blocks', Call(Other.TransitionCard, '{"op":"block","id":' +
      IntToStr(BlockedId) + ',"blocked_on":"' + IntToStr(BlockerId) +
      '","reason":"t"}', Res, Err));
  finally
    Other.Free;
  end;
  { Fresh: not this session's, not yet stale, so it stays out of the tail. }
  Line := FTools.QueueLine(Err);
  AssertTrue('a fresh block of someone else''s is hidden: ' + Line,
    Pos('blocked="', Line) = 0);
  { Now let it sit past the threshold. }
  AgeCard(BlockedId, (StaleBlockMinutes + 5) * 60);
  Line := FTools.QueueLine(Err);
  AssertTrue('a stale block of someone else''s is shown: ' + Line,
    Pos('blocked="', Line) > 0);
  AssertTrue('naming it: ' + Line, Pos('#' + IntToStr(BlockedId), Line) > 0);
end;

procedure TTaskToolsTest.TestTheQueueHidesAFreshBlockHeldByAnotherSession;
var
  BlockedId, BlockerId: Integer;
  Res, Err, Line: string;
  Other: TTaskTool;
begin
  { The same card, one second short of the threshold: still hidden. This is the
    half that makes the threshold mean something rather than "always show". }
  BlockerId := AddOne('the blocker');
  BlockedId := AddOne('recently blocked elsewhere');
  Other := TTaskTool.Create(FTasks, 1, 'sess-b', 'parent', nil, nil);
  try
    AssertTrue('sess-b claims', Call(Other.ClaimCard,
      '{"id":' + IntToStr(BlockedId) + ',"reason":"t"}', Res, Err));
    AssertTrue('and blocks', Call(Other.TransitionCard, '{"op":"block","id":' +
      IntToStr(BlockedId) + ',"blocked_on":"' + IntToStr(BlockerId) +
      '","reason":"t"}', Res, Err));
  finally
    Other.Free;
  end;
  AgeCard(BlockedId, (StaleBlockMinutes * 60) - 60);
  Line := FTools.QueueLine(Err);
  AssertTrue('one minute short of stale is still hidden: ' + Line,
    Pos('blocked="', Line) = 0);
end;

initialization
  RegisterTest(TTaskToolsTest);
end.
