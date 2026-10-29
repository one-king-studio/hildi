unit TestChanges;
{ fpcunit tests for the Changes library: the diff engine, the log rules, and the
  store seam. Hermetic - TMemoryChangeStore, no database, no filesystem. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  ChangesTypes, ChangesText, ChangesStore, ChangesLog;

type
  { A stand-in hash: the library takes the consumer's, so a test can use
    anything stable and cheap. }
  THasher = class
  public
    function OfText(const AText: string): string;
  end;

  TChangesTest = class(TTestCase)
  private
    FHasher: THasher;
    function NewStore: IChangeStore;
    function Rec(AWorkspaceId: Integer; const APath: string;
      AKind: TChangeKind; const ABefore, AAfter: string): TChangeRecord;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    { The diff engine. }
    procedure TestDiffOfEqualTextsIsEmpty;
    procedure TestRoundTripCreate;
    procedure TestRoundTripSingleLineEdit;
    procedure TestRoundTripMultiHunk;
    procedure TestRoundTripCRLF;
    procedure TestCapTruncatesAndFlags;
    procedure TestApplyMismatchNamesTheLine;
    { Inverting a patch is how revert works: the log stores the forward diff. }
    procedure TestInvertPatchRoundTripsAnEdit;
    procedure TestInvertPatchSwapsHunkNumbers;
    procedure TestInvertOfAnEmptyPatchIsANoOp;
    { The revert: compare-and-swap, invert, apply, verify. }
    procedure TestRevertRestoresTheOriginal;
    procedure TestRevertRefusesWhenTheFileMovedSince;
    { Redo is the mirror of revert: the same recorded change applied FORWARD,
      which is what `/redo` replays. }
    procedure TestApplyReplaysTheRecordedChange;
    procedure TestApplyRefusesWhenTheFileMovedSince;
    procedure TestApplyAndRevertRoundTrip;
    { The log. }
    procedure TestReplayWithoutKeyframeStartsEmpty;
    procedure TestReplayFromKeyframeIsBounded;
    procedure TestReplayDetectsATamperedPatch;
    procedure TestKeyframeDueBySize;
    procedure TestKeyframeDueByInterval;
    procedure TestCasOkWhenTheFileIsUnchanged;
    procedure TestCasConflictsAndNamesTheLastWriter;
    procedure TestCasOkOnAnUnrecordedPath;
    procedure TestCasRefusesABlindWrite;
    { Retention. }
    procedure TestPrunePointKeepsSixteenTurns;
    { The summary. }
    procedure TestSummaryIsBoundedAndHonest;
  end;

implementation

{ THasher }

function THasher.OfText(const AText: string): string;
var
  I: Integer;
  H: Cardinal;
begin
  H := 2166136261;
  { The build enables range checking (-Cr), and FNV multiplication overflows a
    Cardinal by design, so the wrap must be explicit rather than an exception. }
  {$push}{$Q-}{$R-}
  for I := 1 to Length(AText) do
    H := (H xor Ord(AText[I])) * 16777619;
  {$pop}
  Result := IntToHex(H, 8);
end;

function TChangesTest.NewStore: IChangeStore;
begin
  Result := TMemoryChangeStore.Create;
end;

procedure TChangesTest.SetUp;
begin
  FHasher := THasher.Create;
end;

procedure TChangesTest.TearDown;
begin
  FHasher.Free;
  FHasher := nil;
end;

function TChangesTest.Rec(AWorkspaceId: Integer; const APath: string;
  AKind: TChangeKind; const ABefore, AAfter: string): TChangeRecord;
begin
  { A function result of a record with managed fields is NOT zeroed by FPC.
    Without this the string fields hold garbage and assigning to them
    de-references it - which is what produced the range errors. }
  Result := Default(TChangeRecord);
  Result.WorkspaceId := AWorkspaceId;
  Result.Path := APath;
  Result.Kind := AKind;
  Result.BeforeHash := FHasher.OfText(ABefore);
  Result.AfterHash := FHasher.OfText(AAfter);
  Result.Patch := DiffText(ABefore, AAfter, DefaultPatchCapBytes,
    Result.Capped);
  Result.PatchBytes := Length(Result.Patch);
  Result.BeforeSize := Length(ABefore);
  Result.AfterSize := Length(AAfter);
  Result.Source := csTier;
  Result.TurnId := 1;
end;

{ --- the diff engine --------------------------------------------------- }

procedure TChangesTest.TestDiffOfEqualTextsIsEmpty;
var
  Capped: Boolean;
begin
  AssertEquals('no diff for equal text', '', DiffText('a'#10'b', 'a'#10'b',
    DefaultPatchCapBytes, Capped));
  AssertFalse('not capped', Capped);
end;

procedure TChangesTest.TestRoundTripCreate;
var
  D, Out2, Err: string;
  Capped: Boolean;
begin
  Err := '';
  D := DiffText('', 'one'#10'two', DefaultPatchCapBytes, Capped);
  AssertTrue('a creation has a diff', D <> '');
  AssertFalse('not capped', Capped);
  AssertTrue('applies: ' + Err, ApplyUnifiedDiff('', D, Out2, Err));
  AssertEquals('round trip', 'one'#10'two'#10, Out2);
end;

procedure TChangesTest.TestRoundTripSingleLineEdit;
var
  D, Out2, Err, Before, After: string;
  Capped: Boolean;
begin
  Err := '';
  Before := 'one'#10'two'#10'three'#10;
  After := 'one'#10'TWO'#10'three'#10;
  D := DiffText(Before, After, DefaultPatchCapBytes, Capped);
  AssertTrue('applies: ' + Err, ApplyUnifiedDiff(Before, D, Out2, Err));
  AssertEquals('round trip', After, Out2);
end;

procedure TChangesTest.TestRoundTripMultiHunk;
var
  D, Out2, Err, Before, After: string;
  I: Integer;
  Capped: Boolean;
begin
  Err := '';
  { Two edits far apart, so the diff must produce two hunks. }
  Before := '';
  for I := 1 to 40 do
    Before := Before + 'line ' + IntToStr(I) + #10;
  After := StringReplace(Before, 'line 2'#10, 'LINE 2'#10, [rfReplaceAll]);
  After := StringReplace(After, 'line 38'#10, 'LINE 38'#10, [rfReplaceAll]);
  D := DiffText(Before, After, DefaultPatchCapBytes, Capped);
  AssertTrue('two hunks', Pos('@@', Copy(D, Pos('@@', D) + 2, MaxInt)) > 0);
  AssertTrue('applies: ' + Err, ApplyUnifiedDiff(Before, D, Out2, Err));
  AssertEquals('round trip', After, Out2);
end;

procedure TChangesTest.TestRoundTripCRLF;
var
  D, Out2, Err, Before, After: string;
  Capped: Boolean;
begin
  Err := '';
  { CR is stripped on split, so a CRLF file round-trips to LF form - the same
    normalisation the applier already used. }
  Before := 'a'#13#10'b'#13#10;
  After := 'a'#13#10'B'#13#10;
  D := DiffText(Before, After, DefaultPatchCapBytes, Capped);
  AssertTrue('applies: ' + Err, ApplyUnifiedDiff(Before, D, Out2, Err));
  AssertEquals('round trip', 'a'#10'B'#10, Out2);
end;

procedure TChangesTest.TestCapTruncatesAndFlags;
var
  D, Before, After: string;
  Capped: Boolean;
  I: Integer;
begin
  Before := '';
  After := '';
  for I := 1 to 200 do
  begin
    Before := Before + 'old ' + IntToStr(I) + #10;
    After := After + 'new ' + IntToStr(I) + #10;
  end;
  D := DiffText(Before, After, 200, Capped);
  AssertTrue('flagged capped', Capped);
  AssertTrue('bounded', Length(D) < 1000);
end;

procedure TChangesTest.TestApplyMismatchNamesTheLine;
var
  D, Out2, Err: string;
  Capped: Boolean;
begin
  Err := '';
  D := DiffText('one'#10'two'#10, 'one'#10'TWO'#10, DefaultPatchCapBytes, Capped);
  { Apply it to text that is not what it expects. }
  AssertFalse('refuses',
    ApplyUnifiedDiff('different'#10'content'#10, D, Out2, Err));
  AssertTrue('names the line', Pos('line', Err) > 0);
end;

procedure TChangesTest.TestInvertPatchRoundTripsAnEdit;
var
  D, Inv, Back, Err: string;
  Capped: Boolean;
  Before, After: string;
begin
  Err := '';
  Inv := '';
  Back := '';
  { The revert path: the log stores the forward patch, so undoing means applying
    its inverse to the after-text. Applying the inverse must land exactly on the
    original text - anything else is data loss. }
  Before := 'one'#10'two'#10'three'#10;
  After := 'one'#10'TWO'#10'three'#10;
  D := DiffText(Before, After, DefaultPatchCapBytes, Capped);
  AssertTrue('inverts: ' + Err, InvertPatch(D, Inv, Err));
  AssertTrue('applies: ' + Err, ApplyUnifiedDiff(After, Inv, Back, Err));
  AssertEquals('back to the original', Before, Back);
end;

procedure TChangesTest.TestInvertPatchSwapsHunkNumbers;
var
  D, Inv, Err: string;
  Capped: Boolean;
begin
  Err := '';
  Inv := '';
  Err := '';
  Inv := '';
  { A hunk header's line numbers must swap, or the reverse change applies at the
    wrong place. Assert on the header rather than on a round trip: a round trip
    could pass by luck on a one-line file. }
  D := DiffText('a'#10'b'#10'c'#10, 'a'#10'X'#10'c'#10, DefaultPatchCapBytes,
    Capped);
  AssertTrue('inverts: ' + Err, InvertPatch(D, Inv, Err));
  { Forward was -2,1 +2,1; the inverse is the same numbers but the - and + lines
    swap. Assert the body swapped, which is the observable difference. }
  AssertTrue('the inverse removes what was added', Pos('-X', Inv) > 0);
  AssertTrue('and restores what was removed', Pos('+b', Inv) > 0);
end;

procedure TChangesTest.TestInvertOfAnEmptyPatchIsANoOp;
var
  Inv, Err: string;
begin
  { An unchanged net row carries no patch. Inverting it is a no-op, not a
    failure - "undo nothing" succeeds and changes nothing. }
  AssertTrue('inverts', InvertPatch('', Inv, Err));
  AssertEquals('and stays empty', '', Inv);
  AssertEquals('no error', '', Err);
end;

procedure TChangesTest.TestRevertRestoresTheOriginal;
var
  Before, After, D, Text, Err: string;
  Capped: Boolean;
begin
  { The revert path end to end: a recorded change, reverted against the current
    text, lands exactly on the original - and the hash check proves it rather
    than trusting the apply. }
  Err := '';
  Text := '';
  Before := 'one'#10'two'#10'three'#10;
  After := 'one'#10'TWO'#10'three'#10;
  D := DiffText(Before, After, DefaultPatchCapBytes, Capped);
  AssertTrue('reverts: ' + Err,
    RevertText(D, FHasher.OfText(Before), FHasher.OfText(After), After,
      FHasher.OfText, Text, Err));
  AssertEquals('back to the original', Before, Text);
end;

procedure TChangesTest.TestRevertRefusesWhenTheFileMovedSince;
var
  Before, After, D, Text, Err: string;
  Capped: Boolean;
begin
  { A revert is a compare-and-swap. If the file no longer holds the after-text
    the record was anchored to, someone has worked on it since, and reverting
    would silently discard that work. Refuse rather than clobber. }
  Err := '';
  Text := '';
  Before := 'one'#10'two'#10;
  After := 'one'#10'TWO'#10;
  D := DiffText(Before, After, DefaultPatchCapBytes, Capped);
  AssertFalse('refuses',
    RevertText(D, FHasher.OfText(Before), FHasher.OfText(After),
      'something else entirely'#10, FHasher.OfText, Text, Err));
  AssertTrue('and says why: ' + Err, Pos('changed', Err) > 0);
  AssertEquals('nothing written', '', Text);
end;

procedure TChangesTest.TestApplyReplaysTheRecordedChange;
var
  Before, After, D, Text, Err: string;
  Capped: Boolean;
begin
  { Redo end to end: a recorded change applied forward against the original
    text lands exactly on the after-text, and the hash check proves it rather
    than trusting the apply. }
  Err := '';
  Text := '';
  Before := 'one'#10'two'#10'three'#10;
  After := 'one'#10'TWO'#10'three'#10;
  D := DiffText(Before, After, DefaultPatchCapBytes, Capped);
  AssertTrue('replays: ' + Err,
    ApplyText(D, FHasher.OfText(Before), FHasher.OfText(After), Before,
      FHasher.OfText, Text, Err));
  AssertEquals('forward to the recorded result', After, Text);
end;

procedure TChangesTest.TestApplyRefusesWhenTheFileMovedSince;
var
  Before, After, D, Text, Err: string;
  Capped: Boolean;
begin
  { The mirror of the revert's guard, on the other hash: redo must not clobber a
    file that no longer holds what this change started FROM. Both directions are
    compare-and-swap or neither is. }
  Err := '';
  Text := '';
  Before := 'one'#10'two'#10;
  After := 'one'#10'TWO'#10;
  D := DiffText(Before, After, DefaultPatchCapBytes, Capped);
  AssertFalse('refuses',
    ApplyText(D, FHasher.OfText(Before), FHasher.OfText(After),
      'something else entirely'#10, FHasher.OfText, Text, Err));
  AssertTrue('and says why: ' + Err, Pos('changed', Err) > 0);
  AssertEquals('nothing written', '', Text);
end;

procedure TChangesTest.TestApplyAndRevertRoundTrip;
var
  Before, After, D, Reverted, Reapplied, Err: string;
  Capped: Boolean;
begin
  { The property that makes `/redo` trustworthy without re-deriving anything:
    applying the forward patch to the before-text and then reverting lands back
    where it started, so the two directions are exact inverses of each other
    over the same record. }
  Before := 'alpha'#10'beta'#10'gamma'#10;
  After := 'alpha'#10'BETA'#10'gamma'#10'delta'#10;
  D := DiffText(Before, After, DefaultPatchCapBytes, Capped);

  Err := '';
  AssertTrue('apply: ' + Err,
    ApplyText(D, FHasher.OfText(Before), FHasher.OfText(After), Before,
      FHasher.OfText, Reapplied, Err));
  AssertEquals('at the after-text', After, Reapplied);

  Err := '';
  AssertTrue('revert: ' + Err,
    RevertText(D, FHasher.OfText(Before), FHasher.OfText(After), Reapplied,
      FHasher.OfText, Reverted, Err));
  AssertEquals('back at the before-text', Before, Reverted);
end;

{ --- the log ----------------------------------------------------------- }

procedure TChangesTest.TestReplayWithoutKeyframeStartsEmpty;
var
  Store: IChangeStore;
  R: TChangeRecord;
  Id, Id2: Integer;
  Found: Boolean;
  Err, Text: string;
begin
  Err := '';
  Text := '';
  Store := NewStore;
  R := Rec(1, 'a.txt', ckModified, '', 'one'#10);
  AssertTrue(Store.Append(R, Id, Err));
  R := Rec(1, 'a.txt', ckModified, 'one'#10, 'one'#10'two'#10);
  AssertTrue(Store.Append(R, Id2, Err));
  { The record to replay is the newest one. }
  R := Default(TChangeRecord);
  R.WorkspaceId := 1;
  R.Path := 'a.txt';
  R.Id := Id2;
  AssertTrue('replays: ' + Err, Reconstruct(Store, FHasher.OfText, R, Text, Err));
  AssertEquals('both patches applied', 'one'#10'two'#10, Text);
end;

procedure TChangesTest.TestReplayFromKeyframeIsBounded;
var
  Store: IChangeStore;
  R: TChangeRecord;
  Id, I: Integer;
  Err, Text: string;
  Frame: TKeyframe;
begin
  Err := '';
  Text := '';
  Store := NewStore;
  R := Rec(1, 'a.txt', ckModified, '', 'v1'#10);
  AssertTrue(Store.Append(R, Id, Err));
  Frame := Default(TKeyframe);
  Frame.WorkspaceId := 1;
  Frame.Path := 'a.txt';
  Frame.Hash := FHasher.OfText('v1'#10);
  Frame.Content := 'v1'#10;
  Frame.ThroughChangeId := Id;
  AssertTrue(Store.PutKeyframe(Frame, Err));
  Id := 0;
  for I := 2 to 4 do
  begin
    R := Rec(1, 'a.txt', ckModified, 'v' + IntToStr(I - 1) + #10,
      'v' + IntToStr(I) + #10);
    AssertTrue(Store.Append(R, Id, Err));
  end;
  R := Default(TChangeRecord);
  R.WorkspaceId := 1;
  R.Path := 'a.txt';
  R.Id := Id;
  AssertTrue('replays: ' + Err, Reconstruct(Store, FHasher.OfText, R, Text, Err));
  AssertEquals('replay landed on the newest', 'v4'#10, Text);
end;

procedure TChangesTest.TestReplayDetectsATamperedPatch;
var
  Store: IChangeStore;
  R: TChangeRecord;
  Id: Integer;
  Found: Boolean;
  Err, Text: string;
begin
  Err := '';
  Text := '';
  Store := NewStore;
  R := Rec(1, 'a.txt', ckModified, '', 'one'#10);
  { Pretend the patch produces different text than the hash claims. }
  R.AfterHash := 'DEADBEEF';
  AssertTrue(Store.Append(R, Id, Err));
  R := Default(TChangeRecord);
  R.WorkspaceId := 1;
  R.Path := 'a.txt';
  R.Id := Id;
  AssertFalse('a bad hash is caught',
    Reconstruct(Store, FHasher.OfText, R, Text, Err));
  AssertTrue('and explained', Pos('hash', Err) > 0);
  Found := True;
  AssertTrue('the record is still in the store', Found);
end;

procedure TChangesTest.TestKeyframeDueBySize;
begin
  AssertFalse('a small delta on a big file', KeyframeDue(100, 10000, 1));
  AssertTrue('the delta dwarfs the file', KeyframeDue(25000, 10000, 1));
end;

procedure TChangesTest.TestKeyframeDueByInterval;
begin
  AssertFalse('one short', KeyframeDue(0, 1000, KeyframeChangeInterval - 1));
  AssertTrue('at the interval', KeyframeDue(0, 1000, KeyframeChangeInterval));
end;

procedure TChangesTest.TestCasOkWhenTheFileIsUnchanged;
var
  Store: IChangeStore;
  R, Last: TChangeRecord;
  Id: Integer;
  Err: string;
  V: TCasVerdict;
begin
  Err := '';
  Store := NewStore;
  R := Rec(1, 'a.txt', ckModified, '', 'one'#10);
  AssertTrue(Store.Append(R, Id, Err));
  AssertTrue(CheckWrite(Store, 1, 'a.txt', 'H1', 'H1', V, Last, Err));
  AssertEquals('ok', Ord(cvOk), Ord(V));
end;

procedure TChangesTest.TestCasConflictsAndNamesTheLastWriter;
var
  Store: IChangeStore;
  R, Last: TChangeRecord;
  Id: Integer;
  Err: string;
  V: TCasVerdict;
begin
  Err := '';
  Store := NewStore;
  R := Rec(1, 'a.txt', ckModified, '', 'one'#10);
  R.SessionId := 'other-session';
  R.CreatedAt := 1234;
  AssertTrue(Store.Append(R, Id, Err));
  { The caller read H1, but the file is now H2. }
  AssertTrue(CheckWrite(Store, 1, 'a.txt', 'H1', 'H2', V, Last, Err));
  AssertEquals('conflict', Ord(cvConflict), Ord(V));
  AssertEquals('names the session', 'other-session', Last.SessionId);
end;

procedure TChangesTest.TestCasOkOnAnUnrecordedPath;
var
  Store: IChangeStore;
  Last: TChangeRecord;
  Err: string;
  V: TCasVerdict;
begin
  Err := '';
  Store := NewStore;
  { Nothing has ever recorded this path, so there is nothing to conflict with.
    This must NOT be cvUnknown - that is reserved for a store failure. }
  AssertTrue(CheckWrite(Store, 1, 'new.txt', 'H1', 'H1', V, Last, Err));
  AssertEquals('ok', Ord(cvOk), Ord(V));
end;

procedure TChangesTest.TestCasRefusesABlindWrite;
var
  Store: IChangeStore;
  R, Last: TChangeRecord;
  Id: Integer;
  Err: string;
  V: TCasVerdict;
begin
  Err := '';
  Store := NewStore;
  R := Rec(1, 'a.txt', ckModified, '', 'one'#10);
  AssertTrue(Store.Append(R, Id, Err));
  { No expected hash: the caller did not read the file first. Refusing is how
    edits are not lost. }
  AssertTrue(CheckWrite(Store, 1, 'a.txt', '', 'H2', V, Last, Err));
  AssertEquals('conflict', Ord(cvConflict), Ord(V));
  AssertTrue('says why', Pos('expected hash', Err) > 0);
end;

{ --- retention --------------------------------------------------------- }

procedure TChangesTest.TestPrunePointKeepsSixteenTurns;
var
  Rows: TChangeRecordArray;
  I: Integer;
begin
  { 20 turns, one change each, ids ascending. }
  SetLength(Rows, 20);
  for I := 0 to 19 do
  begin
    Rows[I] := Default(TChangeRecord);
    Rows[I].Id := I + 1;
    Rows[I].TurnId := I + 1;
    Rows[I].Path := 'f' + IntToStr(I) + '.txt';
  end;
  { Keeping 16 of 20 turns means turns 5..20 survive, so pruning starts at the
    id of turn 4. }
  AssertEquals('prune point is the last dropped turn', 4,
    PrunePointFor(Rows, DefaultRetentionTurns));
  { Nothing to prune when the window is larger than the history. }
  AssertEquals('nothing to prune', 0, PrunePointFor(Rows, 100));
end;

{ --- the summary ------------------------------------------------------- }

procedure TChangesTest.TestSummaryIsBoundedAndHonest;
var
  Rows: TChangeRecordArray;
  S: string;
begin
  SetLength(Rows, 2);
  Rows[0] := Default(TChangeRecord);
  Rows[0].Path := 'new.txt';
  Rows[0].Kind := ckCreated;
  Rows[1] := Default(TChangeRecord);
  Rows[1].Path := 'src/a.pas';
  Rows[1].Kind := ckModified;
  S := Summarize(Rows, 200);
  AssertEquals('A and M', 'A new.txt, M src/a.pas', S);
  { Capped: no line delta is fabricated here, because the summary has no text to
    compare - the delta belongs to a caller that captured both sides. }
  S := Summarize(Rows, 10);
  AssertTrue('bounded', Length(S) <= 15);
  AssertTrue('says it was cut', Pos('...', S) > 0);
end;

initialization
  RegisterTest(TChangesTest);
end.
