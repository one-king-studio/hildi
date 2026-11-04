unit TestTUISelection;
{ fpcunit tests for TUISelection: the pure selection arithmetic.

  Everything here is cells and rows, never string indices. A column is a display
  column, so a wide character occupies two and a combining mark occupies none -
  the same rule the renderer follows. No widget, no surface, no terminal: this is
  the part of selection that must be right before any of it is worth looking at. }

{$mode delphi}{$H+}
{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUISelection;

type
  TSelectionTest = class(TTestCase)
  private
    function Pos(ARow, ACol: Integer): TTextPos;
    function Sel(ARow1, ACol1, ARow2, ACol2: Integer): TSelection;
  published
    { Normalisation }
    procedure TestSpanIsOrderedWhenCaretPrecedesAnchor;
    procedure TestSpanIsOrderedWhenAnchorPrecedesCaret;
    procedure TestSingleCellSelection;
    procedure TestSelectionOnOneRow;

    { Clamping }
    procedure TestColumnClampsToRowWidth;
    procedure TestNegativeRowAndColumnAreClampedAway;

    { Character extraction }
    procedure TestSpanOnOneRowReturnsTheSubstring;
    procedure TestSpanAcrossRowsJoinsWithNewlineAtHardBreaks;
    procedure TestSoftWrappedRowContributesNoNewline;
    procedure TestWideCharacterIsNeverSplit;
    procedure TestHalfOpenSpanEndsBeforeTheCellItNames;
    procedure TestCombiningMarkStaysWithItsBase;

    { Empty and stale }
    procedure TestInactiveSelectionIsEmpty;
    procedure TestEmptySpanReturnsEmptyString;
    procedure TestStaleSelectionReportsItself;
  end;

implementation

function TSelectionTest.Pos(ARow, ACol: Integer): TTextPos;
begin
  Result := Default(TTextPos);
  Result.Row := ARow;
  Result.Col := ACol;
end;

function TSelectionTest.Sel(ARow1, ACol1, ARow2, ACol2: Integer): TSelection;
begin
  Result := Default(TSelection);
  Result.Active := True;
  Result.Anchor := Pos(ARow1, ACol1);
  Result.Caret := Pos(ARow2, ACol2);
end;

{ --- Normalisation --- }

procedure TSelectionTest.TestSpanIsOrderedWhenCaretPrecedesAnchor;
var
  Span: TTextSpan;
begin
  { Dragged RIGHT to LEFT: the caret is before the anchor. }
  Span := SelectionSpan(Sel(3, 10, 1, 2));
  AssertEquals('start row', 1, Span.Start.Row);
  AssertEquals('start col', 2, Span.Start.Col);
  AssertEquals('end row', 3, Span.Stop.Row);
  AssertEquals('end col', 10, Span.Stop.Col);
end;

procedure TSelectionTest.TestSpanIsOrderedWhenAnchorPrecedesCaret;
var
  Span: TTextSpan;
begin
  Span := SelectionSpan(Sel(1, 2, 3, 10));
  AssertEquals('start row', 1, Span.Start.Row);
  AssertEquals('start col', 2, Span.Start.Col);
  AssertEquals('end row', 3, Span.Stop.Row);
  AssertEquals('end col', 10, Span.Stop.Col);
end;

procedure TSelectionTest.TestSingleCellSelection;
var
  Span: TTextSpan;
begin
  Span := SelectionSpan(Sel(2, 5, 2, 6));
  AssertEquals('start row', 2, Span.Start.Row);
  AssertEquals('start col', 5, Span.Start.Col);
  AssertEquals('end row', 2, Span.Stop.Row);
  AssertEquals('end col', 6, Span.Stop.Col);
  AssertFalse('one cell is not empty', SelectionIsEmpty(SelectionSpan(Sel(2, 5, 2, 6))));
end;

procedure TSelectionTest.TestSelectionOnOneRow;
var
  Span: TTextSpan;
begin
  Span := SelectionSpan(Sel(0, 3, 0, 7));
  AssertEquals('same row start', 0, Span.Start.Row);
  AssertEquals('same row end', 0, Span.Stop.Row);
  AssertEquals('width is four cells', 4, Span.Stop.Col - Span.Start.Col);
end;

{ --- Clamping --- }

procedure TSelectionTest.TestColumnClampsToRowWidth;
var
  C: TTextPos;
begin
  { A drag past the end of a row clamps to the row's width, not to -1 or 999. }
  C := ClampPos(Pos(1, 999), 10, 3);
  AssertEquals('row kept', 1, C.Row);
  AssertEquals('col clamped to the width', 10, C.Col);
end;

procedure TSelectionTest.TestNegativeRowAndColumnAreClampedAway;
var
  C: TTextPos;
begin
  { Dragging above or left of the content clamps to the origin. }
  C := ClampPos(Pos(-4, -9), 10, 3);
  AssertEquals('row clamped to zero', 0, C.Row);
  AssertEquals('col clamped to zero', 0, C.Col);
end;

{ --- Character extraction --- }

procedure TSelectionTest.TestSpanOnOneRowReturnsTheSubstring;
var
  Lines: TStringArray;
  Span: TTextSpan;
begin
  { "hello world", cells 0..6 = "hello w". }
  SetLength(Lines, 1);
  Lines[0] := 'hello world';
  Span := SelectionSpan(Sel(0, 0, 0, 7));
  AssertEquals('substring', 'hello w', SelectionText(Span, Lines, nil));
end;

procedure TSelectionTest.TestSpanAcrossRowsJoinsWithNewlineAtHardBreaks;
var
  Lines: TStringArray;
  Span: TTextSpan;
begin
  { Two HARD lines: the copy must carry the newline that was in the text. }
  SetLength(Lines, 2);
  Lines[0] := 'first';
  Lines[1] := 'second';
  Span := SelectionSpan(Sel(0, 0, 1, 6));
  AssertEquals('joined with a newline', 'first' + LineEnding + 'second',
    SelectionText(Span, Lines, nil));
end;

procedure TSelectionTest.TestSoftWrappedRowContributesNoNewline;
var
  Lines: TStringArray;
  Wraps: array of Boolean;
  Span: TTextSpan;
begin
  { One paragraph that soft-wrapped at the width: row 0 ended because it ran out
    of room, not because the text broke. Copying must NOT invent a newline. }
  SetLength(Lines, 2);
  Lines[0] := 'the quick brown';
  Lines[1] := 'fox jumps';
  SetLength(Wraps, 2);
  Wraps[0] := True;    { wrapped }
  Wraps[1] := False;   { last row of the paragraph }
  Span := SelectionSpan(Sel(0, 0, 1, 9));
  AssertEquals('no newline invented at a soft wrap',
    'the quick brownfox jumps', SelectionText(Span, Lines, Wraps));
end;

procedure TSelectionTest.TestWideCharacterIsNeverSplit;
var
  Lines: TStringArray;
  Span: TTextSpan;
begin
  { Two CJK characters, each two cells wide, then 'x'. Cells: 0-1, 2-3, 4.
    A selection STARTING at cell 1 lands inside the first character, so it must
    snap back to that character's start rather than cut it in half; the span is
    half-open, so the end at cell 5 takes everything. }
  SetLength(Lines, 1);
  Lines[0] := WideChar($4F60) + WideChar($597D) + 'x';
  Span := SelectionSpan(Sel(0, 1, 0, 5));
  AssertEquals('wide char snapped to its start, all three copied',
    WideChar($4F60) + WideChar($597D) + 'x', SelectionText(Span, Lines, nil));
end;

procedure TSelectionTest.TestHalfOpenSpanEndsBeforeTheCellItNames;
var
  Lines: TStringArray;
  Span: TTextSpan;
begin
  { The end is EXCLUSIVE: ending at cell 4 in the same line copies the two wide
    characters (cells 0-3) and stops before 'x' at cell 4. }
  SetLength(Lines, 1);
  Lines[0] := WideChar($4F60) + WideChar($597D) + 'x';
  Span := SelectionSpan(Sel(0, 0, 0, 4));
  AssertEquals('end cell is excluded',
    WideChar($4F60) + WideChar($597D), SelectionText(Span, Lines, nil));
end;

procedure TSelectionTest.TestCombiningMarkStaysWithItsBase;
var
  Lines: TStringArray;
  Span: TTextSpan;
begin
  { 'e' + combining acute is ONE cell for display. Selecting that cell must
    yield both code points, never the base alone. }
  SetLength(Lines, 1);
  Lines[0] := 'e' + WideChar($0301) + 'x';
  Span := SelectionSpan(Sel(0, 0, 0, 1));
  AssertEquals('combining mark travels with its base',
    'e' + WideChar($0301), SelectionText(Span, Lines, nil));
end;

{ --- Empty and stale --- }

procedure TSelectionTest.TestInactiveSelectionIsEmpty;
var
  S: TSelection;
begin
  S := Default(TSelection);
  S.Active := False;
  AssertTrue('an inactive selection is empty',
    SelectionIsEmpty(SelectionSpan(S)));
end;

procedure TSelectionTest.TestEmptySpanReturnsEmptyString;
var
  Lines: TStringArray;
  Span: TTextSpan;
begin
  SetLength(Lines, 1);
  Lines[0] := 'abc';
  { Anchor and caret in the same place: nothing was selected. }
  Span := SelectionSpan(Sel(0, 2, 0, 2));
  AssertEquals('empty span copies nothing', '', SelectionText(Span, Lines, nil));
end;

procedure TSelectionTest.TestStaleSelectionReportsItself;
var
  S: TSelection;
begin
  S := Sel(0, 0, 0, 3);
  AssertFalse('fresh', S.Stale);
  S.Stale := True;
  AssertTrue('stale is reported', S.Stale);
  AssertFalse('a stale selection is not usable',
    SelectionIsUsable(S));
end;

initialization
  RegisterTest(TSelectionTest);
end.
