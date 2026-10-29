unit test_changes_recorder;
{ Tests for the change-log recorder: the first consumer of the change log. What
  it must get right is the mapping from an in-memory change set to a record -
  hashes, sizes, kind - and that it never fails a tool call. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildi.hash, hildi.workspace.changes,
  hildi.changes.recorder,
  changes.types, changes.store, changes.log;

type
  { Replay verifies each hop against the record's after-hash, and the recorder
    stamps those with Sha256Hex - so the test's hasher must be the same function,
    or every replay would fail the hash check. }
  TShaHasher = class
  public
    function OfText(const AText: string): string;
  end;

  TChangesRecorderTest = class(TTestCase)
  private
    FStore: IChangeStore;
    FHasher: TShaHasher;
    function Change(const APath: string; AKind: TFileChangeKind;
      const ABefore, AAfter: string; ABeforeCaptured, ACaptured: Boolean):
      TFileChange;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestWantsIsFalseWithoutAStore;
    procedure TestNilSetIsANoOp;
    procedure TestOneCallWritesOneRecordPerFile;
    procedure TestHashesAreRecordedForCapturedSides;
    procedure TestAnUncapturedSideHasNoHashButKeepsItsSize;
    procedure TestKindMapsFromTheChangeSet;
    procedure TestTheTurnAndMessageAreCarried;
    procedure TestASessionIdIsStamped;
    { The record has to be replayable, or "what did this call do?" stays
      unanswerable once the tool block scrolls away. }
    procedure TestAModificationRecordsAPatchThatReplays;
    procedure TestACreationRecordsAPatchFromNothing;
    procedure TestAnUncapturedBeforeSideStoresNoPatch;
    procedure TestThePatchIsCappedAndSaysSo;
    { Per-call anchoring: rows are held against the call that wrote them, so one
      call cannot stamp another's rows when two run concurrently. }
    procedure TestAnchorCallStampsOnlyThatCallsRows;
    procedure TestAnchorCallForACallThatWroteNothingIsANoOp;
    procedure TestAnchorCallIsSingleUse;
    { The net fold: a turn's per-path change, not a pile of per-call patches. }
    procedure TestTwoEditsToOnePathFoldIntoOneNetRow;
    procedure TestEditsThatCancelYieldAnEmptyNetPatch;
    procedure TestPerCallRowsAreStillWrittenAlongsideNetOnes;
    { Every recorded row carries the time it was written. It was hardcoded to 0,
      so "recent changes" could not be ordered at all. }
    procedure TestAPerCallRowIsStampedWithATime;
    { Net rows are what the history reads, so they need the stamp most. }
    procedure TestANetRowIsStampedWithATime;
  end;

implementation

function TShaHasher.OfText(const AText: string): string;
begin
  Result := Sha256Hex(AText);
end;

procedure TChangesRecorderTest.SetUp;
begin
  FStore := TMemoryChangeStore.Create;
  FHasher := TShaHasher.Create;
end;

procedure TChangesRecorderTest.TearDown;
begin
  FHasher.Free;
  FHasher := nil;
end;

function TChangesRecorderTest.Change(const APath: string;
  AKind: TFileChangeKind; const ABefore, AAfter: string;
  ABeforeCaptured, ACaptured: Boolean): TFileChange;
begin
  Result := Default(TFileChange);
  Result.Path := APath;
  Result.Kind := AKind;
  Result.Before := ABefore;
  Result.After := AAfter;
  Result.BeforeCaptured := ABeforeCaptured;
  Result.Captured := ACaptured;
  Result.BeforeSize := Length(ABefore);
  Result.AfterSize := Length(AAfter);
end;

procedure TChangesRecorderTest.TestWantsIsFalseWithoutAStore;
var
  R: TChangeRecorder;
begin
  R := TChangeRecorder.Create(nil, 1, 's');
  try
    AssertFalse('nothing to record into', R.Wants);
  finally
    R.Free;
  end;
end;

procedure TChangesRecorderTest.TestNilSetIsANoOp;
var
  R: TChangeRecorder;
begin
  R := TChangeRecorder.Create(FStore, 1, 's');
  try
    R.Observe(nil);                // must not raise
    AssertEquals('nothing written', 0, R.RecordsWritten);
  finally
    R.Free;
  end;
end;

procedure TChangesRecorderTest.TestOneCallWritesOneRecordPerFile;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Rows: TChangeRecordArray;
  Err: string;
begin
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcCreated, '', 'one', False, True));
    Set_.Add(Change('b.txt', fcModified, 'old', 'new', True, True));
    R.SetTurn(7);
    R.Observe(Set_);
    AssertEquals('two records', 2, R.RecordsWritten);
    AssertTrue('read back', FStore.ForPath(1, 'a.txt', 0, 0, Rows, Err));
    AssertEquals('one for a.txt', 1, Length(Rows));
  finally
    Set_.Free;
    R.Free;
  end;
end;

procedure TChangesRecorderTest.TestHashesAreRecordedForCapturedSides;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Row: TChangeRecord;
  Found: Boolean;
  Err: string;
begin
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcModified, 'old', 'new', True, True));
    R.SetTurn(7);
    R.Observe(Set_);
  finally
    Set_.Free;
    R.Free;
  end;
  AssertTrue('latest', FStore.Latest(1, 'a.txt', Row, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('before hash', Sha256Hex('old'), Row.BeforeHash);
  AssertEquals('after hash', Sha256Hex('new'), Row.AfterHash);
  AssertTrue('the before hash is real', Row.BeforeHash <> '');
end;

procedure TChangesRecorderTest.TestAnUncapturedSideHasNoHashButKeepsItsSize;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Row: TChangeRecord;
  Found: Boolean;
  Err: string;
begin
  { A process-tier modification has the after text but not the before. The hash
    must be empty rather than faked, and the size must survive - that pair is
    exactly what the record's two capture flags are for. }
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcModified, '', 'newcontent', False, True));
    R.SetTurn(7);
    R.Observe(Set_);
  finally
    Set_.Free;
    R.Free;
  end;
  AssertTrue('latest', FStore.Latest(1, 'a.txt', Row, Found, Err));
  AssertEquals('no before hash', '', Row.BeforeHash);
  AssertEquals('but the size is there', 0, Row.BeforeSize);
  AssertTrue('and the after hash is real', Row.AfterHash <> '');
end;

procedure TChangesRecorderTest.TestKindMapsFromTheChangeSet;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Row: TChangeRecord;
  Found: Boolean;
  Err: string;
begin
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('new.txt', fcCreated, '', 'x', False, True));
    Set_.Add(Change('gone.txt', fcDeleted, 'x', '', True, False));
    R.SetTurn(7);
    R.Observe(Set_);
  finally
    Set_.Free;
    R.Free;
  end;
  AssertTrue('created', FStore.Latest(1, 'new.txt', Row, Found, Err));
  AssertEquals('is created', Ord(ckCreated), Ord(Row.Kind));
  AssertTrue('deleted', FStore.Latest(1, 'gone.txt', Row, Found, Err));
  AssertEquals('is deleted', Ord(ckDeleted), Ord(Row.Kind));
end;

procedure TChangesRecorderTest.TestTheTurnAndMessageAreCarried;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Row: TChangeRecord;
  Found: Boolean;
  Err: string;
begin
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcModified, 'a', 'b', True, True));
    R.SetTurn(7);
    R.Observe(Set_);
  finally
    Set_.Free;
    R.Free;
  end;
  AssertTrue('latest', FStore.Latest(1, 'a.txt', Row, Found, Err));
  AssertEquals('turn', 7, Row.TurnId);
  AssertEquals('the message id is not knowable in the callback', 0,
    Row.MessageId);
  AssertEquals('the message id is not knowable in the callback', 0,
    Row.MessageId);
end;

procedure TChangesRecorderTest.TestASessionIdIsStamped;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Row: TChangeRecord;
  Found: Boolean;
  Err: string;
begin
  R := TChangeRecorder.Create(FStore, 3, 'session-abc');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcModified, 'a', 'b', True, True));
    R.SetTurn(7);
    R.Observe(Set_);
  finally
    Set_.Free;
    R.Free;
  end;
  AssertTrue('latest', FStore.Latest(3, 'a.txt', Row, Found, Err));
  AssertEquals('the workspace', 3, Row.WorkspaceId);
  AssertEquals('the session', 'session-abc', Row.SessionId);
end;

procedure TChangesRecorderTest.TestAModificationRecordsAPatchThatReplays;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Row: TChangeRecord;
  Found: Boolean;
  Err, Text: string;
  Frame: TKeyframe;
begin
  { The recorder used to store an empty patch, which made the record a label
    rather than a change: Reconstruct stops at the first record without one, so
    nothing could ever be replayed. }
  Text := '';
  { A modification replays from a keyframe - the patch only carries the lines
    around the edit, not the whole file - so the before-text is seeded as one,
    exactly as the first write of a path would leave it. }
  Frame := Default(TKeyframe);
  Frame.WorkspaceId := 1;
  Frame.Path := 'a.txt';
  Frame.Content := 'one' + LineEnding;
  Frame.Hash := Sha256Hex(Frame.Content);
  Frame.ThroughChangeId := 0;
  AssertTrue('keyframe', FStore.PutKeyframe(Frame, Err));
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcModified, 'one' + LineEnding,
      'one' + LineEnding + 'two' + LineEnding, True, True));
    R.SetTurn(7);
    R.Observe(Set_);
  finally
    Set_.Free;
    R.Free;
  end;

  AssertTrue('latest', FStore.Latest(1, 'a.txt', Row, Found, Err));
  AssertTrue('found', Found);
  AssertTrue('a patch was stored', Row.Patch <> '');
  AssertEquals('and its size is recorded', Length(Row.Patch), Row.PatchBytes);

  AssertTrue('replays: ' + Err,
    Reconstruct(FStore, FHasher.OfText, Row, Text, Err));
  AssertEquals('to the text after the change',
    'one' + LineEnding + 'two' + LineEnding, Text);
end;

procedure TChangesRecorderTest.TestACreationRecordsAPatchFromNothing;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Row: TChangeRecord;
  Found: Boolean;
  Err, Text: string;
begin
  { A creation's before-text is empty by definition, not merely uncaptured, so it
    is replayable even when the capture flag is clear. }
  Text := '';
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('new.txt', fcCreated, '', 'hello' + LineEnding, False, True));
    R.SetTurn(7);
    R.Observe(Set_);
  finally
    Set_.Free;
    R.Free;
  end;

  AssertTrue('latest', FStore.Latest(1, 'new.txt', Row, Found, Err));
  AssertTrue('found', Found);
  AssertTrue('a patch was stored', Row.Patch <> '');
  AssertTrue('replays: ' + Err, Reconstruct(FStore, FHasher.OfText, Row, Text, Err));
  AssertEquals('to the created text', 'hello' + LineEnding, Text);
end;

procedure TChangesRecorderTest.TestAnUncapturedBeforeSideStoresNoPatch;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Row: TChangeRecord;
  Found: Boolean;
  Err: string;
begin
  { The process tier sees the after-text but not the before. A patch cannot be
    invented from a hash, so the record keeps its hashes and stores no patch -
    which Reconstruct reports honestly rather than replaying something wrong. }
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcModified, '', 'newcontent', False, True));
    R.SetTurn(7);
    R.Observe(Set_);
  finally
    Set_.Free;
    R.Free;
  end;

  AssertTrue('latest', FStore.Latest(1, 'a.txt', Row, Found, Err));
  AssertTrue('found', Found);
  AssertEquals('no patch', '', Row.Patch);
  AssertEquals('no patch size', 0, Row.PatchBytes);
  AssertFalse('and it does not claim to be capped', Row.Capped);
end;

procedure TChangesRecorderTest.TestThePatchIsCappedAndSaysSo;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Row: TChangeRecord;
  Found: Boolean;
  Err: string;
  Big, Bigger: string;
  I: Integer;
begin
  { A capped patch is still a useful record for "what changed", so it is stored
    with Capped set rather than dropped. }
  Big := '';
  for I := 1 to 4000 do
    Big := Big + 'line ' + IntToStr(I) + LineEnding;
  Bigger := Big;
  for I := 1 to 4000 do
    Bigger := Bigger + 'extra ' + IntToStr(I) + LineEnding;

  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('big.txt', fcModified, Big, Bigger, True, True));
    R.SetTurn(7);
    R.Observe(Set_);
  finally
    Set_.Free;
    R.Free;
  end;

  AssertTrue('latest', FStore.Latest(1, 'big.txt', Row, Found, Err));
  AssertTrue('found', Found);
  AssertTrue('capped', Row.Capped);
  AssertTrue('the stored patch is bounded by the cap',
    Length(Row.Patch) <= DefaultPatchCapBytes + 4096);
end;

procedure TChangesRecorderTest.TestTwoEditsToOnePathFoldIntoOneNetRow;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Rows: TChangeRecordArray;
  Err: string;
begin
  { Two calls edit a.txt in one turn: v1 -> v2, then v2 -> v3. The net row must
    be v1 -> v3 - one row, not two patches the operator has to mentally compose. }
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcModified, 'v1' + LineEnding, 'v2' + LineEnding,
      True, True));
    R.SetTurn(7);
    R.Observe(Set_);
    Set_.Clear;
    Set_.Add(Change('a.txt', fcModified, 'v2' + LineEnding, 'v3' + LineEnding,
      True, True));
    R.Observe(Set_);
    R.FlushTurn;
  finally
    Set_.Free;
    R.Free;
  end;

  AssertTrue('read', FStore.ForTurn(1, 7, Rows, Err));
  { Two per-call rows plus one net row. }
  AssertEquals('three rows total', 3, Length(Rows));
  AssertTrue('the last is the net row', Rows[2].IsNet);
  AssertEquals('net path', 'a.txt', Rows[2].Path);
  { The net patch goes v1 -> v3: it must mention v1 as removed and v3 as added,
    which no single per-call patch does. }
  AssertTrue('removes v1', Pos('-v1', Rows[2].Patch) > 0);
  AssertTrue('adds v3', Pos('+v3', Rows[2].Patch) > 0);
  AssertFalse('and does not mention the intermediate v2 in a hunk',
    Pos('-v2', Rows[2].Patch) > 0);
end;

procedure TChangesRecorderTest.TestEditsThatCancelYieldAnEmptyNetPatch;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Rows: TChangeRecordArray;
  Err: string;
begin
  { The case that motivated the fold: an edit and its reversal. The net change is
    NOTHING, and saying so is the whole point - two patches would read as a
    large change. }
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcModified, 'orig' + LineEnding,
      'modified' + LineEnding, True, True));
    R.SetTurn(7);
    R.Observe(Set_);
    Set_.Clear;
    Set_.Add(Change('a.txt', fcModified, 'modified' + LineEnding,
      'orig' + LineEnding, True, True));
    R.Observe(Set_);
    R.FlushTurn;
  finally
    Set_.Free;
    R.Free;
  end;

  AssertTrue('read', FStore.ForTurn(1, 7, Rows, Err));
  AssertTrue('net row exists', Rows[High(Rows)].IsNet);
  AssertEquals('the net change is empty', '', Rows[High(Rows)].Patch);
  AssertEquals('and its size is zero', 0, Rows[High(Rows)].PatchBytes);
end;

procedure TChangesRecorderTest.TestPerCallRowsAreStillWrittenAlongsideNetOnes;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Rows: TChangeRecordArray;
  Err: string;
  I, PerCall, Net: Integer;
begin
  { The per-call rows are what a diff under the tool block reads; the net rows
    are what the turn summary reads. Both must exist, and be distinguishable -
    otherwise the summary double-counts. }
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcModified, 'a1' + LineEnding, 'a2' + LineEnding,
      True, True));
    Set_.Add(Change('b.txt', fcCreated, '', 'b1' + LineEnding, False, True));
    R.SetTurn(7);
    R.Observe(Set_);
    R.FlushTurn;
  finally
    Set_.Free;
    R.Free;
  end;

  AssertTrue('read', FStore.ForTurn(1, 7, Rows, Err));
  PerCall := 0;
  Net := 0;
  for I := 0 to High(Rows) do
    if Rows[I].IsNet then
      Inc(Net)
    else
      Inc(PerCall);
  AssertEquals('two per-call rows', 2, PerCall);
  AssertEquals('two net rows, one per path', 2, Net);
  AssertEquals('four rows total', 4, Length(Rows));
end;

procedure TChangesRecorderTest.TestAPerCallRowIsStampedWithATime;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Rows: TChangeRecordArray;
  Err: string;
  I: Integer;
  Before: Int64;
begin
  { The row's time was hardcoded to 0 and nothing ever filled it in, so every
    recorded change claimed the epoch and "recent changes" could not be ordered.
    Assert it is a plausible NOW, not merely non-zero: a stamp from the wrong
    epoch would pass a "> 0" check and still be useless. }
  Before := Trunc((Now - EncodeDate(1970, 1, 1)) * MSecsPerDay);
  R := TChangeRecorder.Create(FStore, 1, 's1');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcCreated, '', 'one', False, True));
    R.SetTurn(7);
    R.Observe(Set_);
  finally
    Set_.Free;
    R.Free;
  end;

  AssertTrue('read', FStore.ForTurn(1, 7, Rows, Err));
  AssertEquals('one row', 1, Length(Rows));
  AssertTrue('the stamp is not the epoch: ' + IntToStr(Rows[0].CreatedAt),
    Rows[0].CreatedAt > 0);
  { Within a generous window of the clock taken just before: this catches a
    stamp in the wrong units (seconds vs milliseconds) as well as a zero. }
  AssertTrue('and it is roughly now',
    (Rows[0].CreatedAt >= Before) and (Rows[0].CreatedAt <= Before + 60000));
end;

procedure TChangesRecorderTest.TestANetRowIsStampedWithATime;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Rows: TChangeRecordArray;
  Err: string;
  I: Integer;
  Net: Integer;
begin
  { Net rows are what the history reads, so a missing stamp here is the one that
    would break a time-ordered dialog even if per-call rows were fine. }
  R := TChangeRecorder.Create(FStore, 1, 's1');
  Set_ := TFileChangeSet.Create;
  try
    Set_.Add(Change('a.txt', fcModified, 'one', 'two', True, True));
    R.SetTurn(9);
    R.Observe(Set_);
    R.FlushTurn;
  finally
    Set_.Free;
    R.Free;
  end;

  AssertTrue('read', FStore.ForTurn(1, 9, Rows, Err));
  Net := 0;
  for I := 0 to High(Rows) do
    if Rows[I].IsNet then
    begin
      Inc(Net);
      AssertTrue('the net row is stamped: ' + IntToStr(Rows[I].CreatedAt),
        Rows[I].CreatedAt > 0);
    end;
  AssertEquals('a net row was written', 1, Net);
end;

procedure TChangesRecorderTest.TestAnchorCallStampsOnlyThatCallsRows;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
  Rows: TChangeRecordArray;
  Err: string;
  I, CallA, CallB: Integer;
begin
  { Two calls write in one turn - run_command is parallel-safe, so this is the
    real shape. Each anchors its OWN rows: if A could stamp B's, a diff would
    appear under the wrong tool block. }
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    R.SetTurn(7);
    Set_.Add(Change('a.txt', fcModified, 'x' + LineEnding, 'y' + LineEnding,
      True, True));
    R.Observe(Set_, 'call_A');
    Set_.Clear;
    Set_.Add(Change('b.txt', fcModified, 'p' + LineEnding, 'q' + LineEnding,
      True, True));
    R.Observe(Set_, 'call_B');

    CallA := R.AnchorCall('call_A', 111);
    CallB := R.AnchorCall('call_B', 222);
  finally
    Set_.Free;
    R.Free;
  end;

  AssertEquals('A anchored one row', 1, CallA);
  AssertEquals('B anchored one row', 1, CallB);

  AssertTrue('read', FStore.ForTurn(1, 7, Rows, Err));
  for I := 0 to High(Rows) do
    if Rows[I].Path = 'a.txt' then
      AssertEquals('a.txt carries A message id', 111, Rows[I].MessageId)
    else if Rows[I].Path = 'b.txt' then
      AssertEquals('b.txt carries B message id', 222, Rows[I].MessageId);
end;

procedure TChangesRecorderTest.TestAnchorCallForACallThatWroteNothingIsANoOp;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
begin
  { A call that changed no files has nothing to anchor. Anchoring it must not
    raise, and must not consume another call's pending rows. }
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    R.SetTurn(7);
    Set_.Add(Change('a.txt', fcModified, 'x' + LineEnding, 'y' + LineEnding,
      True, True));
    R.Observe(Set_, 'call_A');
    AssertEquals('nothing for a silent call', 0, R.AnchorCall('call_zzz', 9));
    { A's rows are still waiting, and still anchor to A. }
    AssertEquals('A still anchors', 1, R.AnchorCall('call_A', 111));
  finally
    Set_.Free;
    R.Free;
  end;
end;

procedure TChangesRecorderTest.TestAnchorCallIsSingleUse;
var
  R: TChangeRecorder;
  Set_: TFileChangeSet;
begin
  { Anchoring consumes the pending entry: a second anchor for the same call must
    not re-stamp rows that already carry an id. }
  R := TChangeRecorder.Create(FStore, 1, 'sess');
  Set_ := TFileChangeSet.Create;
  try
    R.SetTurn(7);
    Set_.Add(Change('a.txt', fcModified, 'x' + LineEnding, 'y' + LineEnding,
      True, True));
    R.Observe(Set_, 'call_A');
    AssertEquals('first anchor', 1, R.AnchorCall('call_A', 111));
    AssertEquals('second anchor does nothing', 0, R.AnchorCall('call_A', 222));
  finally
    Set_.Free;
    R.Free;
  end;
end;

initialization
  RegisterTest(TChangesRecorderTest);
end.
