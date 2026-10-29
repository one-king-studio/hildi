unit test_board_store;
{ Tests for the board store: append-only entries, supersession as a pointer, the
  TOC counts, cursors, and the staleness join. Real SQLite; hermetic. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildi.store, hildi.board,
  hildi.board.store,
  changes.types, changes.store, hildi.changes.store;

type
  TBoardStoreTest = class(TTestCase)
  private
    FDir, FDbPath: string;
    FStore: TSqliteStore;
    FBoard: IBoardStore;
    function Entry(const ATopic, ATitle: string;
      AKind: TBoardKind = bkFinding): TBoardEntry;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSchemaHasTheBoardTables;
    procedure TestAppendRoundTripsEveryField;
    procedure TestPathsRoundTrip;
    procedure TestReadIsNewestFirstAndBounded;
    procedure TestReadFiltersByTopic;
    procedure TestReadFiltersByKind;
    procedure TestSupersessionMakesTheOlderEntryNonCurrent;
    procedure TestSoftDeleteExcludesButKeeps;
    procedure TestRestoreBringsBackTheOlderCurrent;
    procedure TestTopicLockAndUnlock;
    procedure TestTocCounts;
    { The dashboard's channel list: every live topic, so it can offer them as
      channels. Filtering by topic already exists; ENUMERATING them did not,
      which is the one thing a Slack-shaped sidebar needs. }
    procedure TestListTopicsNamesEachLiveTopicOnce;
    { An answered question is not an open one. The count drives whether an agent
      thinks someone needs it, so a question that has been answered must not keep
      counting - which is what q=1 forever meant before this. }
    procedure TestTocStopsCountingAnAnsweredQuestion;
    procedure TestTocStillCountsAQuestionWithOnlyADeletedAnswer;
    procedure TestCursorRoundTrip;
    { Staleness: an entry naming a path counts changes to it since the entry was
      written. Advisory only, but it must be real. }
    procedure TestStalenessCountsChangesSinceTheEntry;
    { Retention drops the noise classes and NEVER the knowledge. }
    procedure TestPruneDropsNotesButNeverDecisions;
  end;

implementation

function TBoardStoreTest.Entry(const ATopic, ATitle: string;
  AKind: TBoardKind): TBoardEntry;
begin
  Result := Default(TBoardEntry);
  Result.WorkspaceId := 1;
  Result.Kind := AKind;
  Result.Topic := ATopic;
  Result.Title := ATitle;
  Result.Body := 'body of ' + ATitle;
  Result.FromSession := 'sess-a';
  Result.FromLabel := 'parent';
  Result.CreatedAt := 1700000000;
end;

procedure TBoardStoreTest.SetUp;
var
  Cfg: TStoreConfig;
  Err: TStoreError;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhboard_' +
    IntToStr(GetTickCount64);
  ForceDirectories(FDir);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'board.db';
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  FStore := TSqliteStore.Create(Cfg);
  if not FStore.Open(Err) then
    raise Exception.Create('open: ' + Err.Message);
  FBoard := TSqliteBoardStore.Create(FStore);
end;

procedure TBoardStoreTest.TearDown;
begin
  FBoard := nil;
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

procedure TBoardStoreTest.TestSchemaHasTheBoardTables;
begin
  AssertTrue('v14 applied', StoreSchemaVersion >= 14);
end;

procedure TBoardStoreTest.TestAppendRoundTripsEveryField;
var
  E, Back: TBoardEntry;
  Id: Integer;
  Found: Boolean;
  Err: string;
begin
  E := Entry('parser', 'the guard is in ParseWord', bkFinding);
  E.ReplyTo := 0;
  E.Supersedes := 0;
  AssertTrue('append', FBoard.Append(E, Id, Err));
  AssertTrue('id assigned', Id > 0);
  AssertTrue('get', FBoard.Get(1, Id, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('kind', Ord(bkFinding), Ord(Back.Kind));
  AssertEquals('topic', 'parser', Back.Topic);
  AssertEquals('title', 'the guard is in ParseWord', Back.Title);
  AssertEquals('body', 'body of the guard is in ParseWord', Back.Body);
  AssertEquals('session', 'sess-a', Back.FromSession);
  AssertEquals('label', 'parent', Back.FromLabel);
  AssertEquals('created', 1700000000, Back.CreatedAt);
  AssertEquals('not deleted', 0, Back.DeletedAt);
  AssertFalse('not pinned', Back.Pinned);
end;

procedure TBoardStoreTest.TestPathsRoundTrip;
var
  E, Back: TBoardEntry;
  Id: Integer;
  Found: Boolean;
  Err: string;
begin
  E := Entry('parser', 'about two files');
  SetLength(E.Paths, 2);
  E.Paths[0] := 'src/a.pas';
  E.Paths[1] := 'src/b.pas';
  AssertTrue('append', FBoard.Append(E, Id, Err));
  AssertTrue('get', FBoard.Get(1, Id, Back, Found, Err));
  AssertEquals('two paths', 2, Length(Back.Paths));
  AssertEquals('first', 'src/a.pas', Back.Paths[0]);
  AssertEquals('second', 'src/b.pas', Back.Paths[1]);
end;

procedure TBoardStoreTest.TestReadIsNewestFirstAndBounded;
var
  E: TBoardEntry;
  Id, I: Integer;
  Rows: TBoardEntryArray;
  F: TBoardFilter;
  Err: string;
begin
  for I := 1 to 5 do
  begin
    E := Entry('t', 'post ' + IntToStr(I));
    AssertTrue('append', FBoard.Append(E, Id, Err));
  end;
  F := Default(TBoardFilter);
  AssertTrue('read', FBoard.Read(1, F, Rows, Err));
  AssertEquals('five', 5, Length(Rows));
  AssertTrue('newest first', Rows[0].Id > Rows[4].Id);
  AssertEquals('newest title', 'post 5', Rows[0].Title);
  F.Limit := 2;
  AssertTrue('bounded', FBoard.Read(1, F, Rows, Err));
  AssertEquals('two', 2, Length(Rows));
end;

procedure TBoardStoreTest.TestReadFiltersByTopic;
var
  E: TBoardEntry;
  Id: Integer;
  Rows: TBoardEntryArray;
  F: TBoardFilter;
  Err: string;
begin
  E := Entry('alpha', 'a1'); AssertTrue('a', FBoard.Append(E, Id, Err));
  E := Entry('beta', 'b1'); AssertTrue('b', FBoard.Append(E, Id, Err));
  E := Entry('alpha', 'a2'); AssertTrue('c', FBoard.Append(E, Id, Err));
  F := Default(TBoardFilter);
  F.Topic := 'alpha';
  AssertTrue('read', FBoard.Read(1, F, Rows, Err));
  AssertEquals('two alpha', 2, Length(Rows));
  AssertEquals('newest alpha', 'a2', Rows[0].Title);
end;

procedure TBoardStoreTest.TestReadFiltersByKind;
var
  E: TBoardEntry;
  Id: Integer;
  Rows: TBoardEntryArray;
  F: TBoardFilter;
  Err: string;
begin
  E := Entry('t', 'a note', bkNote); AssertTrue('n', FBoard.Append(E, Id, Err));
  E := Entry('t', 'a decision', bkDecision);
  AssertTrue('d', FBoard.Append(E, Id, Err));
  E := Entry('t', 'a finding', bkFinding);
  AssertTrue('f', FBoard.Append(E, Id, Err));
  F := Default(TBoardFilter);
  F.Kind := bkDecision;
  F.KindSet := True;
  AssertTrue('read', FBoard.Read(1, F, Rows, Err));
  AssertEquals('one decision', 1, Length(Rows));
  AssertEquals('the right one', 'a decision', Rows[0].Title);
end;

procedure TBoardStoreTest.TestSupersessionMakesTheOlderEntryNonCurrent;
var
  E, First, Second, Cur: TBoardEntry;
  Id1, Id2: Integer;
  Found: Boolean;
  Err: string;
begin
  E := Entry('retry-policy', 'exponential backoff');
  AssertTrue('first', FBoard.Append(E, Id1, Err));
  E := Entry('retry-policy', 'full jitter instead');
  E.Supersedes := Id1;
  AssertTrue('second', FBoard.Append(E, Id2, Err));

  AssertTrue('current', FBoard.CurrentOf(1, 'retry-policy', Cur, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('the newer one is current', Id2, Cur.Id);

  { Both rows survive: supersession is a pointer, not a rewrite. }
  AssertTrue('first still readable', FBoard.Get(1, Id1, First, Found, Err));
  AssertTrue('first exists', Found);
  AssertTrue('second readable', FBoard.Get(1, Id2, Second, Found, Err));
  AssertEquals('and it points at the first', Id1, Second.Supersedes);
end;

procedure TBoardStoreTest.TestSoftDeleteExcludesButKeeps;
var
  E, Back: TBoardEntry;
  Id: Integer;
  Found: Boolean;
  Rows: TBoardEntryArray;
  F: TBoardFilter;
  Err: string;
begin
  E := Entry('t', 'doomed');
  AssertTrue('append', FBoard.Append(E, Id, Err));
  AssertTrue('delete', FBoard.MarkDeleted(1, Id, True, 'operator', Err));
  F := Default(TBoardFilter);
  AssertTrue('read', FBoard.Read(1, F, Rows, Err));
  AssertEquals('excluded from reads', 0, Length(Rows));
  { But the row survives for audit. }
  AssertTrue('get', FBoard.Get(1, Id, Back, Found, Err));
  AssertTrue('still there', Found);
  AssertTrue('marked deleted', Back.DeletedAt <> 0);
  AssertEquals('by whom', 'operator', Back.DeletedBy);
end;

procedure TBoardStoreTest.TestRestoreBringsBackTheOlderCurrent;
var
  E, Cur: TBoardEntry;
  Id1, Id2: Integer;
  Found: Boolean;
  Err: string;
begin
  { Undoing a correction restores the earlier belief - which is what a wiki
    wants and what an editable page cannot do. }
  E := Entry('policy', 'first belief');
  AssertTrue('first', FBoard.Append(E, Id1, Err));
  E := Entry('policy', 'correction');
  E.Supersedes := Id1;
  AssertTrue('second', FBoard.Append(E, Id2, Err));
  AssertTrue('current before', FBoard.CurrentOf(1, 'policy', Cur, Found, Err));
  AssertEquals('the correction', Id2, Cur.Id);

  { Delete the correction: the earlier entry becomes current again. }
  AssertTrue('delete', FBoard.MarkDeleted(1, Id2, True, 'operator', Err));
  AssertTrue('current after', FBoard.CurrentOf(1, 'policy', Cur, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('the first belief is current again', Id1, Cur.Id);
end;

procedure TBoardStoreTest.TestTopicLockAndUnlock;
var
  By, Err: string;
begin
  AssertTrue('locked query', FBoard.IsLocked(1, 'debate', By, Err));
  AssertEquals('not locked initially', '', By);
  AssertTrue('lock', FBoard.Lock(1, 'debate', 'operator', True, Err));
  AssertTrue('query', FBoard.IsLocked(1, 'debate', By, Err));
  AssertEquals('the locker', 'operator', By);
  AssertTrue('unlock', FBoard.Lock(1, 'debate', 'operator', False, Err));
  AssertTrue('query again', FBoard.IsLocked(1, 'debate', By, Err));
  AssertEquals('unlocked', '', By);
end;

procedure TBoardStoreTest.TestTocCounts;
var
  E: TBoardEntry;
  Id, Unread, Q, D, F: Integer;
  LastAt: Int64;
  Err: string;
begin
  E := Entry('t', 'q1', bkQuestion); AssertTrue('1', FBoard.Append(E, Id, Err));
  E := Entry('t', 'd1', bkDecision); AssertTrue('2', FBoard.Append(E, Id, Err));
  E := Entry('t', 'f1', bkFinding); AssertTrue('3', FBoard.Append(E, Id, Err));
  E := Entry('t', 'f2', bkFinding); AssertTrue('4', FBoard.Append(E, Id, Err));
  AssertTrue('toc', FBoard.Toc(1, 0, Unread, Q, D, F, LastAt, Err));
  AssertEquals('all four unread from zero', 4, Unread);
  AssertEquals('one question', 1, Q);
  AssertEquals('one decision', 1, D);
  AssertEquals('two findings', 2, F);
  { From the third entry: only the fourth is newer. }
  AssertTrue('toc from 3', FBoard.Toc(1, 3, Unread, Q, D, F, LastAt, Err));
  AssertEquals('one unread', 1, Unread);
end;

{ Whether ATopics contains ATopic. A local helper rather than IndexStr: that
  function is not available in this RTL build, and the test only needs presence. }
function HasTopic(const ATopics: TStringArray; const ATopic: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(ATopics) do
    if ATopics[I] = ATopic then
      Exit(True);
end;

{ The dashboard lists the board's topics as channels, so it must be able to
  ENUMERATE them. Filtering by topic already existed; listing them did not, and
  a filter cannot answer "what topics are there?" without knowing them first. }
procedure TBoardStoreTest.TestListTopicsNamesEachLiveTopicOnce;
var
  E: TBoardEntry;
  Id: Integer;
  Topics: TStringArray;
  Err: string;
begin
  E := Entry('coordination', 'a', bkStatus); AssertTrue('1', FBoard.Append(E, Id, Err));
  E := Entry('coordination', 'b', bkStatus); AssertTrue('2', FBoard.Append(E, Id, Err));
  E := Entry('tui-split', 'c', bkFinding);   AssertTrue('3', FBoard.Append(E, Id, Err));
  E := Entry('dashboard', 'd', bkNote);      AssertTrue('4', FBoard.Append(E, Id, Err));

  AssertTrue('list', FBoard.ListTopics(1, Topics, Err));
  { Each topic once, however many entries it holds: three topics, four entries. }
  AssertEquals('three topics', 3, Length(Topics));
  AssertTrue('coordination present', HasTopic(Topics, 'coordination'));
  AssertTrue('tui-split present', HasTopic(Topics, 'tui-split'));
  AssertTrue('dashboard present', HasTopic(Topics, 'dashboard'));

  { A deleted entry's topic does not vanish while the topic still has a live
    entry - and a topic emptied by deletion drops out. }
  E := Entry('empty', 'e', bkNote); AssertTrue('5', FBoard.Append(E, Id, Err));
  AssertTrue('list 2', FBoard.ListTopics(1, Topics, Err));
  AssertEquals('four topics', 4, Length(Topics));
  AssertTrue('delete', FBoard.MarkDeleted(1, Id, True, 'parent', Err));
  AssertTrue('list 3', FBoard.ListTopics(1, Topics, Err));
  AssertEquals('the emptied topic drops out', 3, Length(Topics));
  AssertTrue('empty is gone', not HasTopic(Topics, 'empty'));
end;

procedure TBoardStoreTest.TestCursorRoundTrip;
var
  Id: Integer;
  Err: string;
begin
  AssertTrue('initial', FBoard.CursorOf('sess-a', Id, Err));
  AssertEquals('zero', 0, Id);
  AssertTrue('set', FBoard.SetCursor('sess-a', 42, Err));
  AssertTrue('read', FBoard.CursorOf('sess-a', Id, Err));
  AssertEquals('forty-two', 42, Id);
end;

procedure TBoardStoreTest.TestStalenessCountsChangesSinceTheEntry;
var
  E: TBoardEntry;
  Id, Count, CId: Integer;
  Err, CErr: string;
  Changes: IChangeStore;
  Rec: TChangeRecord;
begin
  { An entry naming a path, written at T. Changes to that path after T must be
    counted; a change before T, or to a different path, must not. }
  E := Entry('parser', 'the guard is in ParseWord');
  E.CreatedAt := 1700000100;
  SetLength(E.Paths, 1);
  E.Paths[0] := 'src/parser.pas';
  AssertTrue('append', FBoard.Append(E, Id, Err));

  { Fresh: nothing has changed since it was written. }
  AssertTrue('fresh', FBoard.ChangedSince(1, E.CreatedAt, E.Paths, Count, Err));
  AssertEquals('no changes yet', 0, Count);

  { Written through the real change-store adapter, so this exercises the same
    rows the recorder produces. }
  Changes := TSqliteChangeStore.Create(FStore);
  Rec := Default(TChangeRecord);
  Rec.WorkspaceId := 1;
  Rec.Path := 'src/parser.pas';
  Rec.CreatedAt := 1700000050;           // before the entry
  AssertTrue('before', Changes.Append(Rec, CId, CErr));
  Rec.CreatedAt := 1700000200;           // after it
  AssertTrue('after 1', Changes.Append(Rec, CId, CErr));
  Rec.Path := 'src/other.pas';           // a different path
  Rec.CreatedAt := 1700000300;
  AssertTrue('after 2', Changes.Append(Rec, CId, CErr));

  AssertTrue('stale', FBoard.ChangedSince(1, E.CreatedAt, E.Paths, Count, Err));
  AssertEquals('only the ones after it, for the named path', 1, Count);
  Changes := nil;
end;

procedure TBoardStoreTest.TestPruneDropsNotesButNeverDecisions;
var
  E: TBoardEntry;
  Id, Pruned, I: Integer;
  Err: string;
  Rows: TBoardEntryArray;
  F: TBoardFilter;
begin
  { Five notes and two decisions, all old. A tight window must drop the notes and
    keep every decision: knowledge is not noise. }
  for I := 1 to 5 do
  begin
    E := Entry('scratch', 'note ' + IntToStr(I), bkNote);
    E.CreatedAt := 1700000000;
    AssertTrue('note', FBoard.Append(E, Id, Err));
  end;
  E := Entry('policy', 'we chose jitter', bkDecision);
  E.CreatedAt := 1700000000;
  AssertTrue('decision 1', FBoard.Append(E, Id, Err));
  E := Entry('policy', 'we chose 8 attempts', bkDecision);
  E.CreatedAt := 1700000000;
  AssertTrue('decision 2', FBoard.Append(E, Id, Err));

  { Keep two notes, and prune anything older than a cutoff in the far future.
    The AGE rule fires first and takes all five notes; the count rule then has
    nothing left to do. Both are exercised, and the assertion is on the outcome
    that matters: every note is gone and neither decision is. }
  AssertTrue('prune', FBoard.Prune(1, 2, 1900000000, Pruned, Err));
  AssertEquals('all five notes were older than the cutoff', 5, Pruned);

  F := Default(TBoardFilter);
  F.IncludeDeleted := True;
  AssertTrue('read', FBoard.Read(1, F, Rows, Err));
  { Only the two decisions survive - the kind rule protected them. }
  AssertEquals('both decisions, no notes', 2, Length(Rows));
  { And no decision was touched. }
  F.Topic := 'policy';
  F.Limit := 10;
  AssertTrue('policy read', FBoard.Read(1, F, Rows, Err));
  AssertEquals('both decisions survive', 2, Length(Rows));
end;

procedure TBoardStoreTest.TestTocStopsCountingAnAnsweredQuestion;
var
  E: TBoardEntry;
  Id, QId, AId, Unread, Q, D, F: Integer;
  LastAt: Int64;
  Err: string;
begin
  { This is the defect the coordination entries exposed: I answered question #1
    in entry #2, and the tail kept reporting q="1" forever. An agent reading that
    thinks someone is waiting, and nobody is. }
  E := Entry('t', 'the question', bkQuestion);
  AssertTrue('q', FBoard.Append(E, Id, Err));
  QId := Id;
  AssertTrue('toc', FBoard.Toc(1, 0, Unread, Q, D, F, LastAt, Err));
  AssertEquals('one open question', 1, Q);

  E := Entry('t', 'the answer', bkAnswer);
  E.ReplyTo := QId;
  AssertTrue('a', FBoard.Append(E, Id, Err));
  AId := Id;

  AssertTrue('toc after the answer', FBoard.Toc(1, 0, Unread, Q, D, F, LastAt,
    Err));
  AssertEquals('answered, so no longer open', 0, Q);
  { The answer is still an entry: the count changed, the record did not. }
  AssertEquals('both entries are unread', 2, Unread);
end;

procedure TBoardStoreTest.TestTocStillCountsAQuestionWithOnlyADeletedAnswer;
var
  E: TBoardEntry;
  Id, QId, Unread, Q, D, F: Integer;
  LastAt: Int64;
  Err: string;
begin
  { A retracted answer leaves the question open again - a moderation that hides
    the answer must not silently make the question disappear from the count. }
  E := Entry('t', 'the question', bkQuestion);
  AssertTrue('q', FBoard.Append(E, Id, Err));
  QId := Id;
  E := Entry('t', 'an answer that gets retracted', bkAnswer);
  E.ReplyTo := QId;
  AssertTrue('a', FBoard.Append(E, Id, Err));
  AssertTrue('mark deleted', FBoard.MarkDeleted(1, Id, True, 'sess-a', Err));

  AssertTrue('toc', FBoard.Toc(1, 0, Unread, Q, D, F, LastAt, Err));
  AssertEquals('open again', 1, Q);
end;

initialization
  RegisterTest(TBoardStoreTest);
end.
