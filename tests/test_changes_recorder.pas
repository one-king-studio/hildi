unit test_changes_recorder;
{ Tests for the change-log recorder: the first consumer of the change log. What
  it must get right is the mapping from an in-memory change set to a record -
  hashes, sizes, kind - and that it never fails a tool call. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.hash, hildegard.helper.workspace.changes,
  hildegard.helper.changes.recorder,
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

initialization
  RegisterTest(TChangesRecorderTest);
end.
