unit TestFuzzy;
{ fpcunit tests for HildiFuzzy: the subsequence matcher, its
  scoring (so results rank sensibly), and the stable ranker. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  HildiFuzzy;

type
  TFuzzyTest = class(TTestCase)
  private
    function Ranked(const ANeedle: string;
      const AItems: array of string): TArray<Integer>;
  published
    procedure TestSubsequenceMatches;
    procedure TestNonSubsequenceDoesNotMatch;
    procedure TestCaseInsensitive;
    procedure TestEmptyNeedleMatchesAll;
    procedure TestPositionsAreRecorded;
    procedure TestBoundaryAndConsecutiveScoreHigher;
    procedure TestRankIsBestFirstAndStable;
  end;

implementation

function TFuzzyTest.Ranked(const ANeedle: string;
  const AItems: array of string): TArray<Integer>;
var
  Arr: TStringArray;
  I: Integer;
begin
  SetLength(Arr, Length(AItems));
  for I := 0 to High(AItems) do
    Arr[I] := AItems[I];
  Result := FuzzyRank(ANeedle, Arr);
end;

procedure TFuzzyTest.TestSubsequenceMatches;
begin
  AssertTrue('drain matches d-r-n', FuzzyMatches('drn', 'drain the queue'));
  AssertTrue('exact', FuzzyMatches('drain', 'drain'));
  AssertTrue('prefix', FuzzyMatches('dra', 'drain'));
  AssertTrue('across words', FuzzyMatches('dtq', 'drain the queue'));
end;

procedure TFuzzyTest.TestNonSubsequenceDoesNotMatch;
begin
  AssertFalse('out of order', FuzzyMatches('ndr', 'drain'));
  AssertFalse('missing char', FuzzyMatches('drx', 'drain'));
  AssertFalse('too many', FuzzyMatches('drainn', 'drain'));
end;

procedure TFuzzyTest.TestCaseInsensitive;
begin
  AssertTrue('upper needle', FuzzyMatches('DRN', 'drain'));
  AssertTrue('upper haystack', FuzzyMatches('drn', 'DRAIN'));
end;

procedure TFuzzyTest.TestEmptyNeedleMatchesAll;
var
  M: TFuzzyMatch;
begin
  M := FuzzyMatch('', 'anything');
  AssertTrue('matches', M.Matched);
  AssertEquals('score zero', 0, M.Score);
  AssertEquals('all ranked', 2, Length(Ranked('', ['a', 'b'])));
end;

procedure TFuzzyTest.TestPositionsAreRecorded;
var
  M: TFuzzyMatch;
begin
  M := FuzzyMatch('dn', 'drain');
  AssertTrue('matched', M.Matched);
  AssertEquals('two positions', 2, Length(M.Positions));
  AssertEquals('d at 1', 1, M.Positions[0]);
  AssertEquals('n at 5', 5, M.Positions[1]);
end;

procedure TFuzzyTest.TestBoundaryAndConsecutiveScoreHigher;
var
  Better, Worse: TFuzzyMatch;
begin
  { A word-boundary, consecutive match should outrank a scattered one. }
  Better := FuzzyMatch('dt', 'drain the');
  Worse := FuzzyMatch('dt', 'adit');
  AssertTrue('both match', Better.Matched and Worse.Matched);
  AssertTrue('boundary+consecutive scores higher', Better.Score > Worse.Score);
end;

procedure TFuzzyTest.TestRankIsBestFirstAndStable;
var
  R: TArray<Integer>;
begin
  { "drain the queue" (boundary "d", boundary "t") should beat "a dry run". }
  R := Ranked('dr', ['a dry run', 'drain the queue']);
  AssertEquals('two matches', 2, Length(R));
  AssertEquals('best first', 1, R[0]);
  AssertEquals('worse second', 0, R[1]);
  { Ties keep source order. }
  R := Ranked('x', ['x one', 'x two']);
  AssertEquals('tie: source order', 0, R[0]);
  AssertEquals('tie: source order', 1, R[1]);
end;

initialization
  RegisterTest(TFuzzyTest);
end.
