unit test_changes_summary;
{ fpcunit tests for the turn summary model: turning one turn's net rows into the
  block the operator reads. Hermetic - no database, no TUI. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  changes.types, changes.text, changes.summary;

type
  TChangesSummaryTest = class(TTestCase)
  private
    function Net(const APath: string; AKind: TChangeKind;
      const ABefore, AAfter: string): TChangeRecord;
    function NoPatch(const APath: string; AKind: TChangeKind;
      const ABefore, AAfter: string): TChangeRecord;
  public
  published
    { Counting from the stored patch. }
    procedure TestCountsComeFromThePatch;
    procedure TestACreationCountsAsAdditionsOnly;
    procedure TestADeletionCountsAsRemovalsOnly;
    procedure TestHunkHeadersAreNotCounted;
    { The three states a file can be in. }
    procedure TestAnUnchangedNetRowIsNotListed;
    procedure TestAnUncapturedRowIsListedWithUnknownCounts;
    procedure TestCappedIsPropagated;
    { Attribution. }
    procedure TestAWatcherRowIsUnattributed;
    procedure TestAnExternalRowIsUnattributed;
    { The shape of the result. }
    procedure TestZeroRowsYieldAnEmptySummary;
    procedure TestPerCallRowsAreIgnoredWhenNetRowsExist;
    procedure TestTotalsSumTheFiles;
    procedure TestUnknownCountsAreExcludedFromTheTotal;
    { Presentation. }
    procedure TestLinesAreOrderedByPath;
    procedure TestLinesCapAndSayHowManyAreHidden;
    procedure TestAnUnchangedSummaryRendersNoLines;
    { The diff view: one record's stored patch, parsed for rendering. }
    procedure TestDiffViewClassifiesEveryLineKind;
    procedure TestDiffViewExposesHunkHeaders;
    procedure TestDiffViewOfAnEmptyPatchHasNoLines;
    procedure TestDiffViewReportsNotCaptured;
    procedure TestDiffViewReportsCapped;
  end;

implementation

function TChangesSummaryTest.Net(const APath: string; AKind: TChangeKind;
  const ABefore, AAfter: string): TChangeRecord;
var
  Capped: Boolean;
begin
  Result := Default(TChangeRecord);
  Result.WorkspaceId := 1;
  Result.SessionId := 'sess-a';
  Result.TurnId := 7;
  Result.Path := APath;
  Result.Kind := AKind;
  Result.IsNet := True;
  { The hash stands in for the content, so identical text yields identical
    hashes - which is the invariant the recorder guarantees (it hashes the first
    before-text and the last after-text). A helper that fabricated unequal hashes
    for equal text would make "unchanged" unrepresentable, and the test would be
    asserting a state production can never be in. }
  Result.BeforeHash := 'h:' + ABefore;
  Result.AfterHash := 'h:' + AAfter;
  if ABefore = '' then
    Result.BeforeHash := '';   // a creation has no before-side
  Result.Patch := DiffText(ABefore, AAfter, DefaultPatchCapBytes, Capped);
  Result.PatchBytes := Length(Result.Patch);
  Result.Capped := Capped;
  Result.BeforeSize := Length(ABefore);
  Result.AfterSize := Length(AAfter);
end;

{ A row whose sides were never captured: the process tier sees the after-text
  but not the before, so there is no patch and no hash to compare. }
function TChangesSummaryTest.NoPatch(const APath: string; AKind: TChangeKind;
  const ABefore, AAfter: string): TChangeRecord;
begin
  Result := Default(TChangeRecord);
  Result.WorkspaceId := 1;
  Result.SessionId := 'sess-a';
  Result.TurnId := 7;
  Result.Path := APath;
  Result.Kind := AKind;
  Result.IsNet := True;
  { What an uncaptured change actually looks like: the process tier sees the
    after-text but never the before-text, so the after-hash is set and the
    before-hash is empty. That is the shape the summary must read as 'we could
    not count', distinct from 'the two ends are identical'. }
  Result.BeforeHash := '';
  Result.AfterHash := 'h:' + AAfter;
  Result.Patch := '';
  Result.PatchBytes := 0;
  Result.BeforeSize := Length(ABefore);
  Result.AfterSize := Length(AAfter);
end;

procedure TChangesSummaryTest.TestCountsComeFromThePatch;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  SetLength(Rows, 1);
  Rows[0] := Net('a.txt', ckModified, 'one' + LineEnding + 'two' + LineEnding,
    'one' + LineEnding + 'TWO' + LineEnding + 'three' + LineEnding);
  S := SummarizeTurn(Rows);
  AssertEquals('one file', 1, Length(S.Files));
  AssertEquals('one removed', 1, S.Files[0].Removed);
  AssertEquals('two added', 2, S.Files[0].Added);
  AssertTrue('counts known', S.Files[0].CountsKnown);
end;

procedure TChangesSummaryTest.TestACreationCountsAsAdditionsOnly;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  SetLength(Rows, 1);
  Rows[0] := Net('new.txt', ckCreated, '', 'a' + LineEnding + 'b' + LineEnding);
  S := SummarizeTurn(Rows);
  AssertEquals('two added', 2, S.Files[0].Added);
  AssertEquals('none removed', 0, S.Files[0].Removed);
end;

procedure TChangesSummaryTest.TestADeletionCountsAsRemovalsOnly;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  SetLength(Rows, 1);
  Rows[0] := Net('gone.txt', ckDeleted, 'a' + LineEnding + 'b' + LineEnding, '');
  S := SummarizeTurn(Rows);
  AssertEquals('two removed', 2, S.Files[0].Removed);
  AssertEquals('none added', 0, S.Files[0].Added);
end;

procedure TChangesSummaryTest.TestHunkHeadersAreNotCounted;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  { `--- a/f` and `+++ b/f` are headers, not content. Counting them would add one
    to each side of every diff. }
  SetLength(Rows, 1);
  Rows[0] := Net('a.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  S := SummarizeTurn(Rows);
  AssertEquals('one added', 1, S.Files[0].Added);
  AssertEquals('one removed', 1, S.Files[0].Removed);
end;

procedure TChangesSummaryTest.TestAnUnchangedNetRowIsNotListed;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  { The case the fold exists for: a file edited and reverted ends the turn
    identical. Nothing changed, so nothing is listed - showing it would be the
    confusion this design removes. }
  SetLength(Rows, 1);
  Rows[0] := Net('same.txt', ckModified, 'orig' + LineEnding,
    'orig' + LineEnding);
  AssertEquals('no patch', '', Rows[0].Patch);
  S := SummarizeTurn(Rows);
  AssertEquals('not listed', 0, Length(S.Files));
  AssertEquals('and it renders no lines', 0, Length(SummaryLines(S, 10)));
end;

procedure TChangesSummaryTest.TestAnUncapturedRowIsListedWithUnknownCounts;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  { The process tier has no before-text, so there is no patch. That is NOT
    'unchanged' - it is 'we could not count'. The two must not be confused, or
    the summary reports a clean tree where work happened. }
  SetLength(Rows, 1);
  Rows[0] := NoPatch('big.bin', ckModified, '', '');
  S := SummarizeTurn(Rows);
  AssertEquals('listed', 1, Length(S.Files));
  AssertFalse('counts unknown', S.Files[0].CountsKnown);
  AssertEquals('unknown total recorded', 1, S.UnknownCount);
  AssertEquals('no additions claimed', 0, S.Files[0].Added);
  AssertEquals('no removals claimed', 0, S.Files[0].Removed);
end;

procedure TChangesSummaryTest.TestCappedIsPropagated;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  SetLength(Rows, 1);
  Rows[0] := Net('capped.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  Rows[0].Capped := True;
  S := SummarizeTurn(Rows);
  AssertTrue('capped recorded', S.Files[0].Capped);
  AssertTrue('and counted as at least', S.Files[0].CountsKnown);
end;

procedure TChangesSummaryTest.TestAWatcherRowIsUnattributed;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  SetLength(Rows, 1);
  Rows[0] := Net('a.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  Rows[0].SessionId := '';
  S := SummarizeTurn(Rows);
  AssertFalse('unattributed', S.Files[0].Attributed);
end;

procedure TChangesSummaryTest.TestAnExternalRowIsUnattributed;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  { A peer caught writing: not this agent's change, and the summary says so. }
  SetLength(Rows, 1);
  Rows[0] := Net('a.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  Rows[0].ExternalSession := 'other-session';
  S := SummarizeTurn(Rows);
  AssertFalse('unattributed', S.Files[0].Attributed);
end;

procedure TChangesSummaryTest.TestZeroRowsYieldAnEmptySummary;
var
  S: TTurnChangeSummary;
begin
  S := SummarizeTurn(nil);
  AssertEquals('no files', 0, Length(S.Files));
  AssertEquals('nothing added', 0, S.TotalAdded);
  AssertEquals('nothing removed', 0, S.TotalRemoved);
  AssertEquals('no unknowns', 0, S.UnknownCount);
end;

procedure TChangesSummaryTest.TestPerCallRowsAreIgnoredWhenNetRowsExist;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  { ForTurn returns both kinds. Summarising must read only the net rows, or the
    summary double-counts the net and its parts. }
  SetLength(Rows, 2);
  Rows[0] := Net('a.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  Rows[0].IsNet := False;         // a per-call row
  Rows[1] := Net('a.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  S := SummarizeTurn(Rows);
  AssertEquals('one file, from the net row only', 1, Length(S.Files));
  AssertEquals('one added, not two', 1, S.TotalAdded);
end;

procedure TChangesSummaryTest.TestTotalsSumTheFiles;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  SetLength(Rows, 2);
  Rows[0] := Net('a.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  Rows[1] := Net('b.txt', ckCreated, '', 'p' + LineEnding + 'q' + LineEnding);
  S := SummarizeTurn(Rows);
  AssertEquals('three added', 3, S.TotalAdded);
  AssertEquals('one removed', 1, S.TotalRemoved);
end;

procedure TChangesSummaryTest.TestUnknownCountsAreExcludedFromTheTotal;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  { A total that silently includes an unknown is a lie. The unknown is counted
    separately so the UI can say 'plus N uncounted'. }
  SetLength(Rows, 2);
  Rows[0] := Net('a.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  Rows[1] := NoPatch('b.bin', ckModified, '', '');
  S := SummarizeTurn(Rows);
  AssertEquals('only the known file counts', 1, S.TotalAdded);
  AssertEquals('and one is uncounted', 1, S.UnknownCount);
end;

procedure TChangesSummaryTest.TestLinesAreOrderedByPath;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
  L: TStringArray;
begin
  SetLength(Rows, 3);
  Rows[0] := Net('c.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  Rows[1] := Net('a.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  Rows[2] := Net('b.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  S := SummarizeTurn(Rows);
  L := SummaryLines(S, 10);
  AssertEquals('three lines', 3, Length(L));
  AssertTrue('a first: ' + L[0], Pos('a.txt', L[0]) > 0);
  AssertTrue('b second: ' + L[1], Pos('b.txt', L[1]) > 0);
  AssertTrue('c third: ' + L[2], Pos('c.txt', L[2]) > 0);
end;

procedure TChangesSummaryTest.TestLinesCapAndSayHowManyAreHidden;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
  L: TStringArray;
  I: Integer;
begin
  SetLength(Rows, 5);
  for I := 0 to 4 do
    Rows[I] := Net('f' + IntToStr(I) + '.txt', ckModified,
      'x' + LineEnding, 'y' + LineEnding);
  S := SummarizeTurn(Rows);
  L := SummaryLines(S, 2);
  { Two files, then a tail naming how many are hidden. }
  AssertEquals('two files plus a tail', 3, Length(L));
  AssertTrue('the tail says three more: ' + L[2], Pos('3 more', L[2]) > 0);
end;

procedure TChangesSummaryTest.TestAnUnchangedSummaryRendersNoLines;
var
  Rows: TChangeRecordArray;
  S: TTurnChangeSummary;
begin
  SetLength(Rows, 1);
  Rows[0] := Net('same.txt', ckModified, 'orig' + LineEnding,
    'orig' + LineEnding);
  S := SummarizeTurn(Rows);
  AssertEquals('no lines', 0, Length(SummaryLines(S, 10)));
end;

procedure TChangesSummaryTest.TestDiffViewClassifiesEveryLineKind;
var
  R: TChangeRecord;
  V: TDiffView;
  Kind: TDiffLineKind;
  Text: string;
  I, Adds, Rems, Ctx: Integer;
begin
  { The viewer must be able to colour every line it draws, so the distinction
    has to survive parsing: an added line, a removed line and context are three
    kinds, and a header is a fourth. }
  R := Net('a.txt', ckModified,
    'one' + LineEnding + 'two' + LineEnding + 'three' + LineEnding,
    'one' + LineEnding + 'TWO' + LineEnding + 'three' + LineEnding);
  V := TDiffView.FromRecord(R);
  try
    AssertTrue('has lines', V.LineCount > 0);
    Adds := 0; Rems := 0; Ctx := 0;
    for I := 0 to V.LineCount - 1 do
    begin
      AssertTrue('line ' + IntToStr(I), V.Line(I, Kind, Text));
      case Kind of
        dkAdded: Inc(Adds);
        dkRemoved: Inc(Rems);
        dkContext: Inc(Ctx);
      else
        ;   // headers are neither content nor context
      end;
    end;
    AssertEquals('one addition', 1, Adds);
    AssertEquals('one removal', 1, Rems);
    AssertTrue('and some context', Ctx > 0);
  finally
    V.Free;
  end;
end;

procedure TChangesSummaryTest.TestDiffViewExposesHunkHeaders;
var
  R: TChangeRecord;
  V: TDiffView;
  Kind: TDiffLineKind;
  Text: string;
  I: Integer;
  Hunks: Integer;
begin
  R := Net('a.txt', ckModified, 'only' + LineEnding, 'changed' + LineEnding);
  V := TDiffView.FromRecord(R);
  try
    Hunks := 0;
    for I := 0 to V.LineCount - 1 do
      if V.Line(I, Kind, Text) and (Kind = dkHunk) then
        Inc(Hunks);
    AssertEquals('one hunk header', 1, Hunks);
  finally
    V.Free;
  end;
end;

procedure TChangesSummaryTest.TestDiffViewOfAnEmptyPatchHasNoLines;
var
  R: TChangeRecord;
  V: TDiffView;
begin
  { An unchanged net row carries no patch. The viewer must open empty rather
    than claim a change. }
  R := Net('same.txt', ckModified, 'orig' + LineEnding, 'orig' + LineEnding);
  AssertEquals('no patch', '', R.Patch);
  V := TDiffView.FromRecord(R);
  try
    AssertEquals('no lines', 0, V.LineCount);
    AssertTrue('and it says why', V.NotCaptured or (V.LineCount = 0));
  finally
    V.Free;
  end;
end;

procedure TChangesSummaryTest.TestDiffViewReportsNotCaptured;
var
  R: TChangeRecord;
  V: TDiffView;
begin
  { A process-tier row has no before-text, so it has no patch. That is 'not
    captured', never 'no changes'. }
  R := NoPatch('big.bin', ckModified, '', '');
  V := TDiffView.FromRecord(R);
  try
    AssertTrue('reports not captured', V.NotCaptured);
    AssertEquals('no lines', 0, V.LineCount);
  finally
    V.Free;
  end;
end;

procedure TChangesSummaryTest.TestDiffViewReportsCapped;
var
  R: TChangeRecord;
  V: TDiffView;
begin
  { A truncated patch must say so, or the operator reads a partial diff as the
    whole change. }
  R := Net('a.txt', ckModified, 'x' + LineEnding, 'y' + LineEnding);
  R.Capped := True;
  V := TDiffView.FromRecord(R);
  try
    AssertTrue('reports capped', V.Capped);
  finally
    V.Free;
  end;
end;

initialization
  RegisterTest(TChangesSummaryTest);
end.
