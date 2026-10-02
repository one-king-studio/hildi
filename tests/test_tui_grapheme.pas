unit test_tui_grapheme;
{ fpcunit tests for hildegard.helper.tui.grapheme: cluster splitting, display
  width for narrow/wide/combining clusters, and cluster offsets. No terminal is
  attached. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.grapheme;

type
  TTuiGraphemeTest = class(TTestCase)
  published
    procedure TestClustersSplitOnBaseCharacters;
    procedure TestClustersKeepCombiningMarksWithBase;
    procedure TestClustersKeepSurrogatePairTogether;
    procedure TestClusterWidthNarrowWideAndEmpty;
    procedure TestStringWidthSumsClusters;
    procedure TestClusterStartsAreCodeUnitOffsets;
  end;

implementation

procedure TTuiGraphemeTest.TestClustersSplitOnBaseCharacters;
var
  C: TClusterArray;
begin
  C := Clusters('abc');
  AssertEquals('three clusters', 3, Length(C));
  AssertEquals('first', 'a', C[0]);
  AssertEquals('last', 'c', C[2]);
  AssertEquals('empty text has no clusters', 0, Length(Clusters('')));
end;

procedure TTuiGraphemeTest.TestClustersKeepCombiningMarksWithBase;
var
  C: TClusterArray;
begin
  { 'e' + COMBINING ACUTE ACCENT is one cluster of two code units. }
  C := Clusters('e' + #$0301 + 'x');
  AssertEquals('combining mark joins its base', 2, Length(C));
  AssertEquals('cluster text', 'e' + #$0301, C[0]);
  AssertEquals('next cluster', 'x', C[1]);
end;

procedure TTuiGraphemeTest.TestClustersKeepSurrogatePairTogether;
var
  C: TClusterArray;
begin
  { U+1F600 GRINNING FACE is a surrogate pair in UTF-16. }
  C := Clusters(#$D83D + #$DE00);
  AssertEquals('one cluster', 1, Length(C));
  AssertEquals('both code units', 2, Length(C[0]));
end;

procedure TTuiGraphemeTest.TestClusterWidthNarrowWideAndEmpty;
begin
  AssertEquals('narrow is one', 1, ClusterWidth('a'));
  AssertEquals('wide is two', 2, ClusterWidth(#$4E16));   { CJK ideograph }
  AssertEquals('emoji is two', 2, ClusterWidth(#$D83D + #$DE00));
  AssertEquals('empty is zero', 0, ClusterWidth(''));
end;

procedure TTuiGraphemeTest.TestStringWidthSumsClusters;
begin
  AssertEquals('narrow text', 3, StringWidth('abc'));
  { Two narrow plus one wide plus a combining mark that adds nothing. }
  AssertEquals('mixed text', 6,
    StringWidth('ab' + #$4E16 + 'c' + 'e' + #$0301));
  AssertEquals('empty text', 0, StringWidth(''));
end;

procedure TTuiGraphemeTest.TestClusterStartsAreCodeUnitOffsets;
var
  S: TClusterOffsetArray;
begin
  S := ClusterStarts('abc');
  AssertEquals('three offsets', 3, Length(S));
  AssertEquals('first offset', 1, S[0]);
  AssertEquals('third offset', 3, S[2]);
  { A two-code-unit cluster advances the offset by two. }
  S := ClusterStarts('e' + #$0301 + 'x');
  AssertEquals('two offsets', 2, Length(S));
  AssertEquals('base offset', 1, S[0]);
  AssertEquals('offset after the combining cluster', 3, S[1]);
  AssertEquals('empty text', 0, Length(ClusterStarts('')));
end;

initialization
  RegisterTest(TTuiGraphemeTest);
end.
