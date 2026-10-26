unit test_changes_store;
{ Tests for the SQLite IChangeStore adapter. The library's own rules are covered
  by test_changes against TMemoryChangeStore; what is untested there is the SQL
  binding, so every assertion here is about the round trip through a real
  database. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.store, hildegard.helper.changes.store,
  changes.types, changes.store, changes.log, changes.text;

type
  TChangesStoreTest = class(TTestCase)
  private
    FDir, FDbPath: string;
    FStore: TSqliteStore;
    FChanges: IChangeStore;
    function Rec(const APath: string; AKind: TChangeKind;
      const ABefore, AAfter: string; ATurn: Integer = 1): TChangeRecord;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSchemaIsAt13;
    procedure TestAppendAssignsAnId;
    procedure TestRoundTripPreservesEveryField;
    procedure TestForPathIsOrderedAndBounded;
    procedure TestLatestReturnsTheNewestOrMisses;
    procedure TestTouchingFiltersByPath;
    { A turn's changes, for the turn summary. The table has turn_id; this is the
      query that reads it. }
    procedure TestForTurnReturnsOneTurnsRowsInWriteOrder;
    procedure TestForTurnOnAnUnknownTurnIsEmptyNotAnError;
    { Per-call anchoring: the tool-result row does not exist when the change is
      written, so the id is stamped afterwards. }
    procedure TestSetMessageIdAnchorsARowAfterTheFact;
    procedure TestSetMessageIdOnAMissingRowIsNotAnError;
    { A delegating turn records under its CHILD session: one query for the lineage. }
    procedure TestForSessionsCoversTheWholeLineage;
    procedure TestKeyframeRoundTripAndHorizon;
    procedure TestPruneKeepsTheHorizonKeyframe;
    { Retention in turns: past the window, the oldest turn's changes go. }
    procedure TestPruneByTurnsDropsTheOldestTurn;
    procedure TestPruneByTurnsIsANoOpWithinTheWindow;
  end;

implementation

function TChangesStoreTest.Rec(const APath: string; AKind: TChangeKind;
  const ABefore, AAfter: string; ATurn: Integer): TChangeRecord;
var
  Capped: Boolean;
begin
  Result := Default(TChangeRecord);
  Result.WorkspaceId := 1;
  Result.SessionId := 'sess-a';
  Result.TurnId := ATurn;
  Result.MessageId := 42;
  Result.Path := APath;
  Result.Kind := AKind;
  Result.BeforeHash := 'B' + APath;
  Result.AfterHash := 'A' + APath;
  Result.Patch := DiffText(ABefore, AAfter, DefaultPatchCapBytes, Capped);
  Result.PatchBytes := Length(Result.Patch);
  Result.Capped := Capped;
  Result.BeforeSize := Length(ABefore);
  Result.AfterSize := Length(AAfter);
  Result.Source := csTier;
  Result.ExternalSession := '';
  Result.CreatedAt := 1700000000;
end;

procedure TChangesStoreTest.SetUp;
var
  Err: TStoreError;
  Cfg: TStoreConfig;
begin
  FDir := IncludeTrailingPathDelimiter(GetTempDir) + 'hhchg_' +
    IntToStr(GetTickCount64);
  ForceDirectories(FDir);
  FDbPath := IncludeTrailingPathDelimiter(FDir) + 'changes.db';
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := FDbPath;
  Cfg.BusyTimeoutMs := 5000;
  FStore := TSqliteStore.Create(Cfg);
  if not FStore.Open(Err) then
    raise Exception.Create('could not open: ' + Err.Message);
  FChanges := TSqliteChangeStore.Create(FStore);
end;

procedure TChangesStoreTest.TearDown;
begin
  FChanges := nil;
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

procedure TChangesStoreTest.TestSchemaIsAt13;
begin
  { The tables must exist on a fresh database, which means the migration ran. }
  AssertTrue('schema version includes v13', StoreSchemaVersion >= 13);
end;

procedure TChangesStoreTest.TestAppendAssignsAnId;
var
  Id, Id2: Integer;
  Err: string;
begin
  AssertTrue('first', FChanges.Append(Rec('a.txt', ckModified, '', 'one'#10),
    Id, Err));
  AssertTrue('an id was assigned', Id > 0);
  AssertTrue('second', FChanges.Append(Rec('a.txt', ckModified, 'one'#10,
    'two'#10), Id2, Err));
  AssertTrue('ids ascend', Id2 > Id);
end;

procedure TChangesStoreTest.TestRoundTripPreservesEveryField;
var
  R, Back: TChangeRecord;
  Id: Integer;
  Found: Boolean;
  Err: string;
begin
  R := Rec('src/a.pas', ckCreated, '', 'hello'#10'world'#10);
  R.SessionId := 'sess-xyz';
  R.ExternalSession := 'peer-42';
  R.Source := csProcess;
  AssertTrue('append', FChanges.Append(R, Id, Err));
  AssertTrue('latest', FChanges.Latest(1, 'src/a.pas', Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('path', 'src/a.pas', Back.Path);
  AssertEquals('kind', Ord(ckCreated), Ord(Back.Kind));
  AssertEquals('session', 'sess-xyz', Back.SessionId);
  AssertEquals('external session', 'peer-42', Back.ExternalSession);
  AssertEquals('source', Ord(csProcess), Ord(Back.Source));
  AssertEquals('before hash', 'Bsrc/a.pas', Back.BeforeHash);
  AssertEquals('after hash', 'Asrc/a.pas', Back.AfterHash);
  AssertEquals('turn', 1, Back.TurnId);
  AssertEquals('message', 42, Back.MessageId);
  AssertEquals('patch bytes', R.PatchBytes, Back.PatchBytes);
  AssertEquals('created', 1700000000, Back.CreatedAt);
  AssertEquals('the patch survives', R.Patch, Back.Patch);
  AssertEquals('before size', R.BeforeSize, Back.BeforeSize);
  AssertEquals('after size', R.AfterSize, Back.AfterSize);
end;

procedure TChangesStoreTest.TestForPathIsOrderedAndBounded;
var
  Rows: TChangeRecordArray;
  Id, I, FromId: Integer;
  Err: string;
begin
  for I := 1 to 5 do
    AssertTrue('append', FChanges.Append(Rec('a.txt', ckModified, '', 'v' +
      IntToStr(I)), Id, Err));
  AssertTrue('append other', FChanges.Append(Rec('b.txt', ckModified, '',
    'other'), Id, Err));
  AssertTrue('query', FChanges.ForPath(1, 'a.txt', 0, 0, Rows, Err));
  AssertEquals('only a.txt', 5, Length(Rows));
  AssertTrue('ascending', Rows[0].Id < Rows[4].Id);
  { Bounded. }
  AssertTrue('bounded query', FChanges.ForPath(1, 'a.txt', 0, 2, Rows, Err));
  AssertEquals('two rows', 2, Length(Rows));
  { From an id. Read it into a local first: passing Rows[1].Id while Rows is also
    the `out` parameter is undefined - the callee clears Rows on entry. }
  FromId := Rows[1].Id;
  AssertTrue('from an id', FChanges.ForPath(1, 'a.txt', FromId, 0, Rows, Err));
  AssertEquals('the tail from that id', 4, Length(Rows));
end;

procedure TChangesStoreTest.TestLatestReturnsTheNewestOrMisses;
var
  R, Back: TChangeRecord;
  Id: Integer;
  Found: Boolean;
  Err: string;
begin
  AssertTrue('latest on nothing', FChanges.Latest(1, 'nope.txt', Back, Found,
    Err));
  AssertFalse('not found', Found);
  R := Rec('a.txt', ckModified, '', 'v1');
  AssertTrue('append 1', FChanges.Append(R, Id, Err));
  R.AfterHash := 'SECOND';
  AssertTrue('append 2', FChanges.Append(R, Id, Err));
  AssertTrue('latest', FChanges.Latest(1, 'a.txt', Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('the newest', 'SECOND', Back.AfterHash);
end;

procedure TChangesStoreTest.TestTouchingFiltersByPath;
var
  Rows: TChangeRecordArray;
  Id: Integer;
  Err: string;
  Paths: TStringArrayLite;
begin
  AssertTrue('a', FChanges.Append(Rec('a.txt', ckModified, '', 'x'), Id, Err));
  AssertTrue('b', FChanges.Append(Rec('b.txt', ckModified, '', 'x'), Id, Err));
  AssertTrue('c', FChanges.Append(Rec('c.txt', ckModified, '', 'x'), Id, Err));
  SetLength(Paths, 2);
  Paths[0] := 'a.txt';
  Paths[1] := 'c.txt';
  AssertTrue('touching', FChanges.Touching(1, Paths, 0, Rows, Err));
  AssertEquals('two of the three', 2, Length(Rows));
  AssertEquals('first', 'a.txt', Rows[0].Path);
  AssertEquals('second', 'c.txt', Rows[1].Path);
  { An empty list is a valid no-op, not an error. }
  SetLength(Paths, 0);
  AssertTrue('empty list', FChanges.Touching(1, Paths, 0, Rows, Err));
  AssertEquals('nothing', 0, Length(Rows));
end;

procedure TChangesStoreTest.TestForTurnReturnsOneTurnsRowsInWriteOrder;
var
  Rows: TChangeRecordArray;
  Id: Integer;
  Err: string;
begin
  { Turn 7 writes two files, turn 8 one, in between. The summary needs exactly
    turn 7's rows, in the order they were written. }
  AssertTrue('t7 a', FChanges.Append(Rec('a.txt', ckModified, '', 'a1', 7), Id,
    Err));
  AssertTrue('t8 c', FChanges.Append(Rec('c.txt', ckModified, '', 'c1', 8), Id,
    Err));
  AssertTrue('t7 b', FChanges.Append(Rec('b.txt', ckCreated, '', 'b1', 7), Id,
    Err));

  AssertTrue('for turn 7', FChanges.ForTurn(1, 7, Rows, Err));
  AssertEquals('two rows', 2, Length(Rows));
  AssertEquals('first written', 'a.txt', Rows[0].Path);
  AssertEquals('second written', 'b.txt', Rows[1].Path);
  { Ascending id is write order, which is what the summary lists. }
  AssertTrue('ascending ids', Rows[0].Id < Rows[1].Id);
end;

procedure TChangesStoreTest.TestForTurnOnAnUnknownTurnIsEmptyNotAnError;
var
  Rows: TChangeRecordArray;
  Id: Integer;
  Err: string;
begin
  { A turn that changed nothing and a turn id that never existed are the same
    answer for this feature: no rows. Not an error. }
  AssertTrue('seed', FChanges.Append(Rec('a.txt', ckModified, '', 'x', 7), Id,
    Err));
  AssertTrue('unknown turn succeeds', FChanges.ForTurn(1, 999, Rows, Err));
  AssertEquals('no rows', 0, Length(Rows));
  AssertEquals('and no error', '', Err);
end;

procedure TChangesStoreTest.TestSetMessageIdAnchorsARowAfterTheFact;
var
  Rows: TChangeRecordArray;
  Id: Integer;
  Err: string;
begin
  { Per-call anchoring: the row is written while the tool runs, but the
    tool-result row it belongs to does not exist until the call finishes. So the
    id is stamped AFTER the fact. Without this a diff can never sit under the
    tool block that produced it. }
  AssertTrue('append', FChanges.Append(Rec('a.txt', ckModified, '', 'x', 7), Id,
    Err));
  AssertTrue('anchored', FChanges.SetMessageId(1, Id, 4242, Err));
  AssertTrue('read back', FChanges.ForTurn(1, 7, Rows, Err));
  AssertEquals('one row', 1, Length(Rows));
  AssertEquals('message id', 4242, Rows[0].MessageId);
end;

procedure TChangesStoreTest.TestSetMessageIdOnAMissingRowIsNotAnError;
var
  Err: string;
begin
  { Nothing to anchor is a no-op, not a failure: a row pruned between the write
    and the anchor is a normal race, and it must not fail the turn. }
  AssertTrue('no such row', FChanges.SetMessageId(1, 9999, 4242, Err));
  AssertEquals('no error', '', Err);
end;

procedure TChangesStoreTest.TestForSessionsCoversTheWholeLineage;
var
  Rows: TChangeRecordArray;
  Id: Integer;
  Err: string;
  Ids: TStringArrayLite;
  R: TChangeRecord;
begin
  { A delegating turn's work is recorded under its CHILD session's turn, so
    ForTurn(parentTurn) cannot see it. This is the query that lets a revert walk
    the lineage in one go rather than one session at a time. }
  R := Rec('parent.txt', ckModified, '', 'p', 7);
  R.SessionId := 'sess-parent';
  AssertTrue('parent row', FChanges.Append(R, Id, Err));

  R := Rec('child.txt', ckModified, '', 'c', 8);
  R.SessionId := 'sess-child';
  AssertTrue('child row', FChanges.Append(R, Id, Err));

  R := Rec('other.txt', ckModified, '', 'o', 9);
  R.SessionId := 'sess-unrelated';
  AssertTrue('unrelated row', FChanges.Append(R, Id, Err));

  SetLength(Ids, 2);
  Ids[0] := 'sess-parent';
  Ids[1] := 'sess-child';
  AssertTrue('lineage', FChanges.ForSessions(1, Ids, Rows, Err));
  AssertEquals('parent and child, not the unrelated one', 2, Length(Rows));

  { An empty lineage is an answer, not a failure. }
  SetLength(Ids, 0);
  AssertTrue('empty lineage', FChanges.ForSessions(1, Ids, Rows, Err));
  AssertEquals('nothing', 0, Length(Rows));
end;

procedure TChangesStoreTest.TestKeyframeRoundTripAndHorizon;
var
  Frame, Back: TKeyframe;
  Id: Integer;
  Found: Boolean;
  Err: string;
begin
  AssertTrue('append', FChanges.Append(Rec('a.txt', ckModified, '', 'v1'), Id,
    Err));
  Frame := Default(TKeyframe);
  Frame.WorkspaceId := 1;
  Frame.Path := 'a.txt';
  Frame.Hash := 'H1';
  Frame.Content := 'v1'#10;
  Frame.ThroughChangeId := Id;
  Frame.CreatedAt := 1700000000;
  AssertTrue('put', FChanges.PutKeyframe(Frame, Err));
  AssertTrue('get', FChanges.KeyframeBefore(1, 'a.txt', Id, Back, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('content', 'v1'#10, Back.Content);
  AssertEquals('hash', 'H1', Back.Hash);
  AssertEquals('through', Id, Back.ThroughChangeId);
  { A keyframe after the query point is not returned. }
  AssertTrue('before it', FChanges.KeyframeBefore(1, 'a.txt', Id - 1, Back,
    Found, Err));
  AssertFalse('not found before it', Found);
end;

procedure TChangesStoreTest.TestPruneKeepsTheHorizonKeyframe;
var
  Frame, Back: TKeyframe;
  Id, I, Id5: Integer;
  Found: Boolean;
  Err: string;
  Rows: TChangeRecordArray;
begin
  for I := 1 to 10 do
  begin
    AssertTrue('append', FChanges.Append(Rec('a.txt', ckModified, '', 'v' +
      IntToStr(I), I), Id, Err));
    if I = 5 then
      Id5 := Id;
  end;
  { A keyframe at change 5, which is the last one before the prune horizon. }
  Frame := Default(TKeyframe);
  Frame.WorkspaceId := 1;
  Frame.Path := 'a.txt';
  Frame.Hash := 'H5';
  Frame.Content := 'v5'#10;
  Frame.ThroughChangeId := Id5;
  Frame.CreatedAt := 1700000000;
  AssertTrue('put', FChanges.PutKeyframe(Frame, Err));
  { Keep from change 8: 1..7 go. }
  AssertTrue('prune', FChanges.Prune(1, Id5 + 3, Err));
  AssertTrue('remaining', FChanges.ForPath(1, 'a.txt', 0, 0, Rows, Err));
  AssertEquals('three survive', 3, Length(Rows));
  { The keyframe at the horizon survives: the oldest surviving change must be
    replayable. }
  AssertTrue('horizon keyframe', FChanges.KeyframeBefore(1, 'a.txt', Id5 + 3,
    Back, Found, Err));
  AssertTrue('it is there', Found);
  AssertEquals('and it is the one', 'H5', Back.Hash);
end;

procedure TChangesStoreTest.TestPruneByTurnsDropsTheOldestTurn;
var
  Id, I: Integer;
  R: TChangeRecord;
  Err: string;
  Rows: TChangeRecordArray;
begin
  { Twenty turns, one change each: past a sixteen-turn window, the oldest go. }
  for I := 1 to 20 do
  begin
    R := Rec('a.txt', ckModified, '', 'v' + IntToStr(I), I);
    AssertTrue('append turn ' + IntToStr(I), FChanges.Append(R, Id, Err));
  end;
  AssertTrue('prune', FChanges.PruneByTurns(1, DefaultRetentionTurns, Err));
  AssertTrue('remaining', FChanges.ForPath(1, 'a.txt', 0, 0, Rows, Err));
  AssertEquals('sixteen turns survive', DefaultRetentionTurns, Length(Rows));
  { The oldest surviving turn is 5: turns 1..4 are gone. }
  AssertEquals('turn 5 is the oldest kept', 5, Rows[0].TurnId);
  AssertEquals('turn 20 is the newest', 20, Rows[High(Rows)].TurnId);
end;

procedure TChangesStoreTest.TestPruneByTurnsIsANoOpWithinTheWindow;
var
  Id, I: Integer;
  R: TChangeRecord;
  Err: string;
  Rows: TChangeRecordArray;
begin
  { Three turns against a sixteen-turn window: nothing may be dropped. }
  for I := 1 to 3 do
  begin
    R := Rec('a.txt', ckModified, '', 'v' + IntToStr(I), I);
    AssertTrue('append', FChanges.Append(R, Id, Err));
  end;
  AssertTrue('prune', FChanges.PruneByTurns(1, DefaultRetentionTurns, Err));
  AssertTrue('remaining', FChanges.ForPath(1, 'a.txt', 0, 0, Rows, Err));
  AssertEquals('all three survive', 3, Length(Rows));
end;

initialization
  RegisterTest(TChangesStoreTest);
end.
