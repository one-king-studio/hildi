unit test_tasks_store;
{ Tests for the task store: the claim CAS, guarded transitions, and retention
  that never prunes live state. Real SQLite; hermetic. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.store, hildegard.helper.tasks,
  hildegard.helper.tasks.store;

type
  TTaskStoreTest = class(TTestCase)
  private
    FDir, FDbPath: string;
    FStore: TSqliteStore;
    FTasks: ITaskStore;
    function Card(const ATitle: string; AParent: Integer = 0): TTaskCard;
    function AddCard(const ATitle: string; out AId: Integer;
      AParent: Integer = 0): Boolean;
    { Claim and assert it won; the shared setup for the transition tests. }
    procedure ClaimOk(AId: Integer; const ABy: string);
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSchemaHasTaskCards;
    procedure TestAddThenGetRoundTrips;
    procedure TestClaimSucceedsFromOpen;
    procedure TestSecondClaimIsRefusedAndNamesTheHolder;
    procedure TestClaimOnADoneCardNamesTheStatus;
    procedure TestReleaseReturnsToOpenAndClearsTheClaim;
    procedure TestDoneFromOpenIsRefused;
    procedure TestDoneFromClaimedRecordsTheNote;
    procedure TestATransitionByANonHolderIsRefused;
    procedure TestBlockedNamesItsBlockerAndUnblockKeepsTheClaim;
    procedure TestSubtaskOfATopLevelCardIsAllowed;
    procedure TestAParentDoesNotAutoClose;
    procedure TestPruneDropsFinishedButNeverLive;
    procedure TestPruneNeverDropsACardsParent;
    { The spec's transition table is enforced, not merely documented. }
    procedure TestATransitionOutsideTheTableIsRefused;
    { An unknown id is an error naming it, never a silent no-op. }
    procedure TestAnEditOfAMissingCardFailsNamingIt;
    procedure TestADeleteOfAMissingCardFailsNamingIt;
    { Workspace scoping, for the two verbs the CAS does not guard. }
    procedure TestAnEditCannotReachAnotherWorkspace;
    procedure TestADeleteCannotReachAnotherWorkspace;
    { Retention by COUNT, not only by age. }
    procedure TestPruneKeepsOnlyTheNewestDoneCards;
    procedure TestTheCountRuleNeverTouchesLiveCards;
    procedure TestTheCountRuleNeverDropsACardsBlocker;
  end;

implementation

function TTaskStoreTest.Card(const ATitle: string; AParent: Integer): TTaskCard;
begin
  Result := Default(TTaskCard);
  Result.WorkspaceId := 1;
  Result.Title := ATitle;
  Result.Body := 'body';
  Result.Parent := AParent;
  Result.FromSession := 'sess-a';
  Result.FromLabel := 'parent';
  Result.CreatedAt := 1700000000;
end;

function TTaskStoreTest.AddCard(const ATitle: string; out AId: Integer;
  AParent: Integer): Boolean;
var
  Err: string;
begin
  Result := FTasks.Add(Card(ATitle, AParent), AId, Err);
end;

procedure TTaskStoreTest.ClaimOk(AId: Integer; const ABy: string);
var
  Prev: TTaskCard;
  Claimed, Found: Boolean;
  Err: string;
begin
  Prev := Default(TTaskCard);
  AssertTrue('claim ' + IntToStr(AId),
    FTasks.Claim(1, AId, ABy, Prev, Claimed, Found, Err));
  AssertTrue('claimed by ' + ABy, Claimed);
end;

procedure TTaskStoreTest.SetUp;
var
  Cfg: TStoreConfig;
  Err: TStoreError;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhtask_' +
    IntToStr(GetTickCount64);
  ForceDirectories(FDir);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'tasks.db';
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  FStore := TSqliteStore.Create(Cfg);
  if not FStore.Open(Err) then
    raise Exception.Create('open: ' + Err.Message);
  FTasks := TSqliteTaskStore.Create(FStore);
end;

procedure TTaskStoreTest.TearDown;
begin
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

procedure TTaskStoreTest.TestSchemaHasTaskCards;
begin
  AssertTrue('v15 applied', StoreSchemaVersion >= 15);
end;

procedure TTaskStoreTest.TestAddThenGetRoundTrips;
var
  Id: Integer;
  Back: TTaskCard;
  Found: Boolean;
  Err: string;
begin
  AssertTrue('add', AddCard('wire the board drain', Id));
  AssertTrue('id assigned', Id > 0);
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('title', 'wire the board drain', Back.Title);
  AssertEquals('body', 'body', Back.Body);
  AssertEquals('starts open', Ord(tsOpen), Ord(Back.Status));
  AssertEquals('unclaimed', '', Back.ClaimedBy);
  AssertEquals('no parent', 0, Back.Parent);
  AssertEquals('creator', 'sess-a', Back.FromSession);
end;

procedure TTaskStoreTest.TestClaimSucceedsFromOpen;
var
  Id: Integer;
  Back: TTaskCard;
  Found: Boolean;
  Err: string;
begin
  AssertTrue('add', AddCard('a card', Id));
  ClaimOk(Id, 'sess-a');
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertEquals('now claimed', Ord(tsClaimed), Ord(Back.Status));
  AssertEquals('by the claimer', 'sess-a', Back.ClaimedBy);
  AssertTrue('with a timestamp', Back.ClaimedAt > 0);
end;

procedure TTaskStoreTest.TestSecondClaimIsRefusedAndNamesTheHolder;
var
  Id: Integer;
  Prev: TTaskCard;
  Claimed, Found: Boolean;
  Err: string;
  Back: TTaskCard;
begin
  Prev := Default(TTaskCard);
  { THE test: two agents reaching for one card. The loser must learn who holds
    it - that message is the feature's whole product, not an error string. }
  AssertTrue('add', AddCard('contested', Id));
  ClaimOk(Id, 'sess-a');

  AssertTrue('second', FTasks.Claim(1, Id, 'sess-b', Prev, Claimed, Found, Err));
  AssertFalse('the second loses', Claimed);
  AssertTrue('and the card exists', Found);
  AssertEquals('it names the holder', 'sess-a', Prev.ClaimedBy);
  AssertTrue('and when they took it', Prev.ClaimedAt > 0);

  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertEquals('still the first claimer''s', 'sess-a', Back.ClaimedBy);
end;

procedure TTaskStoreTest.TestClaimOnADoneCardNamesTheStatus;
var
  Id: Integer;
  Prev: TTaskCard;
  Claimed, Found: Boolean;
  Err: string;
begin
  Prev := Default(TTaskCard);
  AssertTrue('add', AddCard('finished', Id));
  ClaimOk(Id, 'sess-a');
  AssertTrue('done', FTasks.Transition(1, Id, tsClaimed, tsDone, 'sess-a', 0,
    tbkNone, 'shipped', Err));
  AssertTrue('claim again', FTasks.Claim(1, Id, 'sess-b', Prev, Claimed, Found,
    Err));
  AssertFalse('refused', Claimed);
  AssertTrue('found', Found);
  AssertEquals('the status explains it', Ord(tsDone), Ord(Prev.Status));
end;

procedure TTaskStoreTest.TestReleaseReturnsToOpenAndClearsTheClaim;
var
  Id: Integer;
  Back: TTaskCard;
  Found: Boolean;
  Err: string;
begin
  AssertTrue('add', AddCard('release me', Id));
  ClaimOk(Id, 'sess-a');
  AssertTrue('release', FTasks.Transition(1, Id, tsClaimed, tsOpen, 'sess-a',
    0, tbkNone, '', Err));
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertEquals('open again', Ord(tsOpen), Ord(Back.Status));
  AssertEquals('claim cleared', '', Back.ClaimedBy);
  AssertEquals('timestamp cleared', 0, Back.ClaimedAt);
end;

procedure TTaskStoreTest.TestDoneFromOpenIsRefused;
var
  Id: Integer;
  Err: string;
begin
  { Finishing what nobody claimed hides who did it, and the claim is the
    attribution. }
  AssertTrue('add', AddCard('unclaimed', Id));
  AssertFalse('refused', FTasks.Transition(1, Id, tsClaimed, tsDone, 'sess-a',
    0, tbkNone, 'done', Err));
  AssertTrue('says why', Pos('not in the expected state', Err) > 0);
end;

procedure TTaskStoreTest.TestDoneFromClaimedRecordsTheNote;
var
  Id: Integer;
  Back: TTaskCard;
  Found: Boolean;
  Err: string;
begin
  AssertTrue('add', AddCard('finish me', Id));
  ClaimOk(Id, 'sess-a');
  AssertTrue('done', FTasks.Transition(1, Id, tsClaimed, tsDone, 'sess-a', 0,
    tbkNone, 'shipped it', Err));
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertEquals('done', Ord(tsDone), Ord(Back.Status));
  AssertEquals('the note', 'shipped it', Back.DoneNote);
  AssertTrue('status stamped', Back.StatusAt > 0);
end;

procedure TTaskStoreTest.TestATransitionByANonHolderIsRefused;
var
  Id: Integer;
  Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  AssertTrue('add', AddCard('mine', Id));
  ClaimOk(Id, 'sess-a');
  { sess-b does not hold it, so it cannot drive it. }
  AssertFalse('refused', FTasks.Transition(1, Id, tsClaimed, tsDone, 'sess-b',
    0, tbkNone, 'stolen', Err));
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertEquals('still claimed', Ord(tsClaimed), Ord(Back.Status));
end;

procedure TTaskStoreTest.TestBlockedNamesItsBlockerAndUnblockKeepsTheClaim;
var
  Id, QId: Integer;
  Back: TTaskCard;
  Found: Boolean;
  Err: string;
begin
  AssertTrue('add', AddCard('blocked card', Id));
  AssertTrue('add a question card', AddCard('the question', QId));
  ClaimOk(Id, 'sess-a');
  AssertTrue('block', FTasks.Transition(1, Id, tsClaimed, tsBlocked, 'sess-a',
    QId, tbkCard, '', Err));
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertEquals('blocked', Ord(tsBlocked), Ord(Back.Status));
  AssertEquals('names the blocker', QId, Back.BlockedOnId);
  AssertEquals('and its kind', Ord(tbkCard), Ord(Back.BlockedOnKind));

  { Unblocking returns to claimed and KEEPS the claim. }
  AssertTrue('unblock', FTasks.Transition(1, Id, tsBlocked, tsClaimed,
    'sess-a', 0, tbkNone, '', Err));
  AssertTrue('get', FTasks.Get(1, Id, Back, Found, Err));
  AssertEquals('claimed again', Ord(tsClaimed), Ord(Back.Status));
  AssertEquals('the claim survived', 'sess-a', Back.ClaimedBy);
end;

procedure TTaskStoreTest.TestSubtaskOfATopLevelCardIsAllowed;
var
  PId, CId: Integer;
  Back: TTaskCard;
  Found: Boolean;
  Err: string;
begin
  AssertTrue('parent', AddCard('parent', PId));
  AssertTrue('child', AddCard('child', CId, PId));
  AssertTrue('get', FTasks.Get(1, CId, Back, Found, Err));
  AssertEquals('points at its parent', PId, Back.Parent);
end;

procedure TTaskStoreTest.TestAParentDoesNotAutoClose;
var
  PId, CId: Integer;
  Back: TTaskCard;
  Found: Boolean;
  Err: string;
begin
  { "All subtasks done" and "the task is done" are different claims, and
    conflating them hides incomplete thinking. }
  AssertTrue('parent', AddCard('parent', PId));
  AssertTrue('child', AddCard('child', CId, PId));
  ClaimOk(CId, 'sess-a');
  AssertTrue('finish the child', FTasks.Transition(1, CId, tsClaimed, tsDone,
    'sess-a', 0, tbkNone, 'child done', Err));
  AssertTrue('get the parent', FTasks.Get(1, PId, Back, Found, Err));
  AssertEquals('the parent is still open', Ord(tsOpen), Ord(Back.Status));
end;

procedure TTaskStoreTest.TestPruneDropsFinishedButNeverLive;
var
  DoneId, OpenId: Integer;
  Pruned: Integer;
  Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  { Only the AGE rule is implemented so far (the count rule is still open - see
    the plan). A card finished just now is not older than the cutoff, so nothing
    is pruned; the point of the test is that a LIVE card is never touched. }
  AssertTrue('open card', AddCard('still open', OpenId));
  AssertTrue('done card', AddCard('finished', DoneId));
  ClaimOk(DoneId, 'sess-a');
  AssertTrue('finish', FTasks.Transition(1, DoneId, tsClaimed, tsDone, 'sess-a',
    0, tbkNone, 'x', Err));

  AssertTrue('prune with a one-second window', FTasks.Prune(1, 200, 1, Pruned,
    Err));
  AssertEquals('a card finished now is not stale enough', 0, Pruned);
  AssertTrue('open is untouched', FTasks.Get(1, OpenId, Back, Found, Err));
  AssertTrue('and it is still there', Found);
  AssertTrue('so is the fresh done card', FTasks.Get(1, DoneId, Back, Found,
    Err));
  AssertTrue('still there', Found);
end;

procedure TTaskStoreTest.TestPruneNeverDropsACardsParent;
var
  PId, CId: Integer;
  Pruned: Integer;
  Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  { A finished card that is another card's parent must survive: the reference
    would dangle. }
  AssertTrue('parent', AddCard('a parent card', PId));
  AssertTrue('child', AddCard('child', CId, PId));
  ClaimOk(PId, 'sess-a');
  AssertTrue('finish the parent', FTasks.Transition(1, PId, tsClaimed, tsDone,
    'sess-a', 0, tbkNone, 'x', Err));

  AssertTrue('prune', FTasks.Prune(1, 200, 1, Pruned, Err));
  AssertTrue('the parent survives', FTasks.Get(1, PId, Back, Found, Err));
  AssertTrue('because its child names it', Found);
end;

procedure TTaskStoreTest.TestATransitionOutsideTheTableIsRefused;
var
  Id: Integer;
  Err: string;
begin
  { The spec's table is the contract, and the store's guards are not the same
    thing. An OPERATOR action (ABy = '') drops the claimed_by guard, so the
    status guard is all that is left - and it permits any status change to any
    other. done -> claimed passes it. Without an explicit table check an
    operator action could reopen a finished card. }
  AssertTrue('add', AddCard('finish me', Id));
  ClaimOk(Id, 'sess-a');
  AssertTrue('finish', FTasks.Transition(1, Id, tsClaimed, tsDone, 'sess-a',
    0, tbkNone, 'x', Err));
  AssertFalse('done -> claimed is refused even for an operator',
    FTasks.Transition(1, Id, tsDone, tsClaimed, '', 0, tbkNone, '', Err));
  AssertTrue('and names the actual state', Pos('done', Err) > 0);
end;

procedure TTaskStoreTest.TestAnEditOfAMissingCardFailsNamingIt;
var
  Err: string;
begin
  AssertFalse('editing a card that is not there fails',
    FTasks.Edit(1, 999, 'new title', 'new body', Err));
  AssertTrue('naming the id', Pos('999', Err) > 0);
end;

procedure TTaskStoreTest.TestADeleteOfAMissingCardFailsNamingIt;
var
  Err: string;
begin
  AssertFalse('deleting a card that is not there fails',
    FTasks.Delete(1, 999, Err));
  AssertTrue('naming the id', Pos('999', Err) > 0);
end;

procedure TTaskStoreTest.TestAnEditCannotReachAnotherWorkspace;
var
  Id: Integer;
  Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  AssertTrue('add', AddCard('mine', Id));
  AssertFalse('another workspace cannot edit it',
    FTasks.Edit(2, Id, 'hijacked', 'x', Err));
  AssertTrue('read back', FTasks.Get(1, Id, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('title is untouched', 'mine', Back.Title);
end;

procedure TTaskStoreTest.TestADeleteCannotReachAnotherWorkspace;
var
  Id: Integer;
  Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  AssertTrue('add', AddCard('mine', Id));
  AssertFalse('another workspace cannot delete it', FTasks.Delete(2, Id, Err));
  AssertTrue('read back', FTasks.Get(1, Id, Back, Found, Err));
  AssertTrue('still there', Found);
end;

procedure TTaskStoreTest.TestPruneKeepsOnlyTheNewestDoneCards;
var
  Ids: array[0..4] of Integer;
  I: Integer;
  Pruned: Integer;
  Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  { The count rule bounds the table the way the age rule bounds the clock: a
    burst of finished cards in one afternoon is exactly the case age cannot
    catch. Five done cards, keep two -> the oldest three go. }
  for I := 0 to 4 do
    AssertTrue('add ' + IntToStr(I), AddCard('card ' + IntToStr(I), Ids[I]));
  for I := 0 to 4 do
  begin
    ClaimOk(Ids[I], 'sess-a');
    AssertTrue('finish ' + IntToStr(I),
      FTasks.Transition(1, Ids[I], tsClaimed, tsDone, 'sess-a', 0, tbkNone,
        'x', Err));
  end;

  { A zero age window: nothing is old, so only the count rule can prune. }
  AssertTrue('prune', FTasks.Prune(1, 2, 0, Pruned, Err));
  AssertEquals('three pruned by count', 3, Pruned);

  for I := 0 to 2 do
  begin
    AssertTrue('get ' + IntToStr(I), FTasks.Get(1, Ids[I], Back, Found, Err));
    AssertFalse('the oldest are gone: ' + IntToStr(I), Found);
  end;
  for I := 3 to 4 do
  begin
    AssertTrue('get ' + IntToStr(I), FTasks.Get(1, Ids[I], Back, Found, Err));
    AssertTrue('the newest two survive: ' + IntToStr(I), Found);
  end;
end;

procedure TTaskStoreTest.TestTheCountRuleNeverTouchesLiveCards;
var
  DoneId, OpenId, ClaimedId: Integer;
  Pruned: Integer;
  Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  AssertTrue('done', AddCard('done card', DoneId));
  ClaimOk(DoneId, 'sess-a');
  AssertTrue('finish', FTasks.Transition(1, DoneId, tsClaimed, tsDone,
    'sess-a', 0, tbkNone, 'x', Err));
  AssertTrue('open', AddCard('live open', OpenId));
  AssertTrue('claimed', AddCard('live claimed', ClaimedId));
  ClaimOk(ClaimedId, 'sess-b');

  { Keep ZERO: the count rule would delete every finished card if it could see
    live ones. It must not. }
  AssertTrue('prune', FTasks.Prune(1, 0, 0, Pruned, Err));
  AssertEquals('only the finished card goes', 1, Pruned);
  AssertTrue('get open', FTasks.Get(1, OpenId, Back, Found, Err));
  AssertTrue('open survives', Found);
  AssertTrue('get claimed', FTasks.Get(1, ClaimedId, Back, Found, Err));
  AssertTrue('claimed survives', Found);
end;

procedure TTaskStoreTest.TestTheCountRuleNeverDropsACardsBlocker;
var
  BlockedId, BlockerId: Integer;
  Pruned: Integer;
  Err: string;
  Back: TTaskCard;
  Found: Boolean;
begin
  { A finished card that another card names as its blocker must survive, for the
    same reason a parent must: the reference would dangle and the blocked card
    would point at nothing. }
  AssertTrue('blocker', AddCard('the blocker', BlockerId));
  ClaimOk(BlockerId, 'sess-a');
  AssertTrue('finish the blocker', FTasks.Transition(1, BlockerId, tsClaimed,
    tsDone, 'sess-a', 0, tbkNone, 'x', Err));
  AssertTrue('blocked card', AddCard('waiting', BlockedId));
  ClaimOk(BlockedId, 'sess-b');
  AssertTrue('block it', FTasks.Transition(1, BlockedId, tsClaimed, tsBlocked,
    'sess-b', BlockerId, tbkCard, '', Err));

  AssertTrue('prune keeping none', FTasks.Prune(1, 0, 0, Pruned, Err));
  AssertEquals('nothing pruned', 0, Pruned);
  AssertTrue('get', FTasks.Get(1, BlockerId, Back, Found, Err));
  AssertTrue('the blocker survives', Found);
end;

initialization
  RegisterTest(TTaskStoreTest);
end.
