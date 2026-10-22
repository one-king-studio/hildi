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
  TChangesRecorderTest = class(TTestCase)
  private
    FStore: IChangeStore;
    function Change(const APath: string; AKind: TFileChangeKind;
      const ABefore, AAfter: string; ABeforeCaptured, ACaptured: Boolean):
      TFileChange;
  public
    procedure SetUp; override;
  published
    procedure TestWantsIsFalseWithoutAStore;
    procedure TestNilSetIsANoOp;
    procedure TestOneCallWritesOneRecordPerFile;
    procedure TestHashesAreRecordedForCapturedSides;
    procedure TestAnUncapturedSideHasNoHashButKeepsItsSize;
    procedure TestKindMapsFromTheChangeSet;
    procedure TestTheTurnAndMessageAreCarried;
    procedure TestASessionIdIsStamped;
  end;

implementation

procedure TChangesRecorderTest.SetUp;
begin
  FStore := TMemoryChangeStore.Create;
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

initialization
  RegisterTest(TChangesRecorderTest);
end.
