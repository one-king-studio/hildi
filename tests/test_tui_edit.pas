unit test_tui_edit;
{ fpcunit tests for hildegard.helper.tui.edit: the caret-aware multi-line editor.
  Covers the buffer/caret model, display rows and navigation, and rendering on
  the memory surface. No terminal is attached. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface,
  hildegard.helper.tui.clock, hildegard.helper.tui.text,
  hildegard.helper.tui.edit;

type
  TTuiEditTest = class(TTestCase)
  private
    FChanges: Integer;
    procedure OnChanged(Sender: TObject);
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function Key(AKind: TKeyKind; AMods: TModifiers = []): TInputEvent;
    function CharKey(const ACh: UnicodeString;
      AMods: TModifiers = []): TInputEvent;
    { An editor laid out at AWidth so movement has a wrap width. }
    function Editor(AWidth: Integer; const AText: UnicodeString;
      AWrap: TWrapMode = wmWord): TTextEdit;
  published
    { Buffer and caret. }
    procedure TestSetTextResetsCaretToEnd;
    procedure TestInsertTextAtEndAdvancesCaret;
    procedure TestInsertTextMidBuffer;
    procedure TestInsertTextCountsClusters;
    procedure TestBackspaceDeletesClusterBeforeCaret;
    procedure TestBackspaceAtStartDoesNothing;
    procedure TestBackspaceDeletesCombiningCluster;
    procedure TestDeleteForwardDeletesClusterAtCaret;
    procedure TestDeleteForwardAtEndDoesNothing;
    procedure TestClearEmptiesBufferAndCaret;
    procedure TestClearLineClearsTheCaretLine;
    procedure TestClearLineOnEmptyLineIsNoOp;
    procedure TestCtrlUClearsTheLine;
    procedure TestCtrlCClearsTheBufferAndReportsHandled;
    procedure TestCtrlCOnEmptyBufferReportsUnhandled;
    procedure TestSetCaretClampsToBuffer;
    procedure TestOnChangeFiresOnEveryMutation;
    procedure TestActiveRegistersTheCaret;
    procedure TestBlinkingHoldsTheCaretSolid;
    { Display rows and navigation. }
    procedure TestRowsTileTheBuffer;
    procedure TestHardBreakSplitsRows;
    procedure TestTrailingNewlineYieldsEmptyRow;
    procedure TestCharWrapBreaksMidWord;
    procedure TestWordWrapBreaksAtSpace;
    procedure TestWordWrapFallsBackToCharacterBreak;
    procedure TestWideClusterCountsTwoColumns;
    procedure TestCaretCellAtEndOfBuffer;
    procedure TestCaretCellStaysWithinRows;
    procedure TestMoveLeftAndRightByCluster;
    procedure TestMoveUpDownPreservesColumn;
    procedure TestMoveUpClampsToShorterRow;
    procedure TestMoveUpDownAcrossSoftWrap;
    procedure TestMoveUpAtFirstRowDoesNothing;
    procedure TestHomeAndEndOnLogicalLine;
    procedure TestHomeOnFirstLine;
    { Rendering, scrolling, and input mapping. }
    procedure TestTextRendersInAttr;
    procedure TestCaretAtRowEndIsABlock;
    procedure TestCaretOnCharacterReversesIt;
    procedure TestScrollKeepsCaretVisible;
    procedure TestBlinkTogglesWithAdvance;
    procedure TestHandleEventMapsEditingKeys;
    procedure TestHandleEventMapsNavigationKeys;
    { Word motion and deletion. }
    procedure TestMoveWordLeftAndRight;
    procedure TestWordMotionSkipsWhitespace;
    procedure TestWordMotionClampsAtEnds;
    procedure TestDeleteWordBack;
    procedure TestDeleteWordForward;
    { Selection. }
    procedure TestShiftMoveSetsSelection;
    procedure TestBackwardSelectionBounds;
    procedure TestSelectAllAndClear;
    procedure TestInsertReplacesSelection;
    procedure TestBackspaceAndDeleteReplaceSelection;
    procedure TestShiftVerticalExtendsSelection;
    procedure TestShiftAltExtendsByWord;
    procedure TestAltBackspaceDeletesWord;
    { Sticky end-of-row column. }
    procedure TestStickyEndColumnAcrossRows;
    procedure TestMidRowColumnStillApplies;
    procedure TestStickyEndSurvivesRepeatedMoves;
    { Caret and selection rendering. }
    procedure TestSelectionRendersInSelAttr;
    procedure TestCaretOverlaySwapsColours;
    procedure TestCaretDoesNotBlinkWithSelection;
    procedure TestInactiveCaretIsAHollowBox;
    procedure TestInactiveCaretDoesNotHighlightACharacter;
  end;

implementation

procedure TTuiEditTest.OnChanged(Sender: TObject);
begin
  Inc(FChanges);
end;

function TTuiEditTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TTuiEditTest.Editor(AWidth: Integer; const AText: UnicodeString;
  AWrap: TWrapMode): TTextEdit;
begin
  Result := TTextEdit.Create(AWrap);
  Result.SetText(AText);
  Result.Arrange(Rc(0, 0, AWidth, 8));
end;

function TTuiEditTest.Key(AKind: TKeyKind; AMods: TModifiers): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
  Result.Key.Mods := AMods;
end;

function TTuiEditTest.CharKey(const ACh: UnicodeString;
  AMods: TModifiers): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := ACh;
  Result.Key.Mods := AMods;
end;

procedure TTuiEditTest.TestSetTextResetsCaretToEnd;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.SetText('abc');
    AssertEquals('text kept', 'abc', string(E.Text));
    AssertEquals('caret at the end', 3, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestInsertTextAtEndAdvancesCaret;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.SetText('ab');
    E.InsertText('c');
    AssertEquals('text appended', 'abc', string(E.Text));
    AssertEquals('caret past the insert', 3, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestInsertTextMidBuffer;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.SetText('ac');
    E.SetCaret(1);
    E.InsertText('b');
    AssertEquals('inserted in the middle', 'abc', string(E.Text));
    AssertEquals('caret after the inserted cluster', 2, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestInsertTextCountsClusters;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.InsertText('ab');
    AssertEquals('two clusters', 2, E.CaretIndex);
    { A combining mark joins the previous cluster, so it adds no caret step. }
    E.InsertText(#$0301);
    AssertEquals('combining mark joins', 2, E.CaretIndex);
    E.InsertText('c');
    AssertEquals('next cluster', 3, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestBackspaceDeletesClusterBeforeCaret;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.SetText('abc');
    E.SetCaret(2);
    E.Backspace;
    AssertEquals('cluster removed', 'ac', string(E.Text));
    AssertEquals('caret pulled back', 1, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestBackspaceAtStartDoesNothing;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.SetText('ab');
    E.SetCaret(0);
    E.Backspace;
    AssertEquals('text unchanged', 'ab', string(E.Text));
    AssertEquals('caret unchanged', 0, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestBackspaceDeletesCombiningCluster;
var
  E: TTextEdit;
  Expected: UnicodeString;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.SetText('e' + #$0301 + 'x');
    AssertEquals('two clusters', 2, E.CaretIndex);
    E.Backspace;
    { Compare as UnicodeString: the combining mark must survive the delete. }
    Expected := 'e' + #$0301;
    AssertTrue('plain cluster removed', E.Text = Expected);
    AssertEquals('caret back one cluster', 1, E.CaretIndex);
    E.Backspace;
    AssertTrue('combining cluster removed whole', E.Text = '');
    AssertEquals('caret at the start', 0, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestDeleteForwardDeletesClusterAtCaret;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.SetText('abc');
    E.SetCaret(1);
    E.DeleteForward;
    AssertEquals('cluster removed', 'ac', string(E.Text));
    AssertEquals('caret stays put', 1, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestDeleteForwardAtEndDoesNothing;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.SetText('ab');
    E.DeleteForward;
    AssertEquals('text unchanged', 'ab', string(E.Text));
    AssertEquals('caret unchanged', 2, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestClearEmptiesBufferAndCaret;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.SetText('abc');
    E.Clear;
    AssertEquals('buffer empty', '', string(E.Text));
    AssertEquals('caret at the start', 0, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestSetCaretClampsToBuffer;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.SetText('ab');
    E.SetCaret(99);
    AssertEquals('clamped to the end', 2, E.CaretIndex);
    E.SetCaret(-4);
    AssertEquals('clamped to the start', 0, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestOnChangeFiresOnEveryMutation;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    E.OnChange := OnChanged;
    FChanges := 0;
    E.SetText('ab');
    AssertEquals('SetText fired', 1, FChanges);
    E.InsertText('c');
    AssertEquals('InsertText fired', 2, FChanges);
    E.Backspace;
    AssertEquals('Backspace fired', 3, FChanges);
    E.SetCaret(0);
    AssertEquals('SetCaret fired', 4, FChanges);
    E.DeleteForward;
    AssertEquals('DeleteForward fired', 5, FChanges);
    E.Clear;
    AssertEquals('Clear fired', 6, FChanges);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestRowsTileTheBuffer;
var
  E: TTextEdit;
  R: TDisplayRowArray;
begin
  E := Editor(3, 'abcde', wmChar);
  try
    R := E.Rows(3);
    AssertEquals('two rows', 2, Length(R));
    AssertEquals('first row starts at the buffer start', 0, R[0].First);
    AssertEquals('first row holds three clusters', 3, R[0].Count);
    AssertEquals('first row width', 3, R[0].Width);
    AssertEquals('second row starts after the first', 3, R[1].First);
    AssertEquals('second row holds the rest', 2, R[1].Count);
    AssertEquals('second row width', 2, R[1].Width);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestHardBreakSplitsRows;
var
  E: TTextEdit;
  R: TDisplayRowArray;
begin
  E := Editor(10, 'ab' + #10 + 'cd');
  try
    R := E.Rows(10);
    AssertEquals('two rows', 2, Length(R));
    AssertEquals('first row excludes the newline', 2, R[0].Count);
    AssertEquals('second row starts after the newline', 3, R[1].First);
    AssertEquals('second row holds the rest', 2, R[1].Count);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestTrailingNewlineYieldsEmptyRow;
var
  E: TTextEdit;
  R: TDisplayRowArray;
  Row, Col: Integer;
begin
  { The Shift+Enter regression: a buffer ending in #10 must show a new row,
    with the caret at its head. }
  E := Editor(10, 'ab' + #10);
  try
    R := E.Rows(10);
    AssertEquals('two rows', 2, Length(R));
    AssertEquals('trailing row is empty', 0, R[1].Count);
    AssertEquals('trailing row starts at the buffer end', 3, R[1].First);
    E.CaretCell(10, Row, Col);
    AssertEquals('caret on the trailing row', 1, Row);
    AssertEquals('caret at the head of the row', 0, Col);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestCharWrapBreaksMidWord;
var
  E: TTextEdit;
  R: TDisplayRowArray;
begin
  E := Editor(3, 'abcdef', wmChar);
  try
    R := E.Rows(3);
    AssertEquals('two content rows plus the caret row', 3, Length(R));
    AssertEquals('first row', 3, R[0].Count);
    AssertEquals('second row', 3, R[1].Count);
    AssertEquals('caret row is empty', 0, R[2].Count);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestWordWrapBreaksAtSpace;
var
  E: TTextEdit;
  R: TDisplayRowArray;
begin
  E := Editor(3, 'ab cd', wmWord);
  try
    R := E.Rows(3);
    AssertEquals('two rows', 2, Length(R));
    AssertEquals('break after the space', 3, R[0].Count);
    AssertEquals('continuation starts after the space', 3, R[1].First);
    AssertEquals('continuation holds the last word', 2, R[1].Count);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestWordWrapFallsBackToCharacterBreak;
var
  E: TTextEdit;
  R: TDisplayRowArray;
begin
  { No space to break at, so the word is split mid-way. }
  E := Editor(3, 'abcde', wmWord);
  try
    R := E.Rows(3);
    AssertEquals('two rows', 2, Length(R));
    AssertEquals('first row', 3, R[0].Count);
    AssertEquals('second row', 2, R[1].Count);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestWideClusterCountsTwoColumns;
var
  E: TTextEdit;
  R: TDisplayRowArray;
begin
  { 'a' + CJK ideograph + 'b' at width 3: the wide cluster takes two columns. }
  E := Editor(3, 'a' + #$4E16 + 'b', wmChar);
  try
    R := E.Rows(3);
    AssertEquals('two rows', 2, Length(R));
    AssertEquals('narrow plus wide fills the row', 2, R[0].Count);
    AssertEquals('row width counts the wide cluster twice', 3, R[0].Width);
    AssertEquals('second row holds the tail', 1, R[1].Count);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestCaretCellAtEndOfBuffer;
var
  E: TTextEdit;
  Row, Col: Integer;
begin
  E := Editor(10, 'ab' + #10 + 'cde');
  try
    E.CaretCell(10, Row, Col);
    AssertEquals('caret on the last row', 1, Row);
    AssertEquals('caret after the last cluster', 3, Col);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestCaretCellStaysWithinRows;
var
  E: TTextEdit;
  R: TDisplayRowArray;
  Row, Col, I: Integer;
begin
  E := Editor(4, 'abcdef' + #10 + 'ghijkl', wmChar);
  try
    R := E.Rows(4);
    for I := 0 to 15 do
    begin
      E.SetCaret(I);
      E.CaretCell(4, Row, Col);
      AssertTrue('row in range', (Row >= 0) and (Row <= High(R)));
      AssertTrue('column inside the row',
        (Col >= 0) and (Col <= R[Row].Width));
    end;
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestMoveLeftAndRightByCluster;
var
  E: TTextEdit;
begin
  E := Editor(10, 'abc');
  try
    E.MoveLeft;
    AssertEquals('one cluster left', 2, E.CaretIndex);
    E.MoveLeft;
    E.MoveLeft;
    E.MoveLeft;
    AssertEquals('clamped at the start', 0, E.CaretIndex);
    E.MoveRight;
    E.MoveRight;
    AssertEquals('two clusters right', 2, E.CaretIndex);
    { A combining cluster moves as one. }
    E.SetText('e' + #$0301 + 'x');
    E.MoveLeft;
    AssertEquals('combining cluster is one step', 1, E.CaretIndex);
    E.MoveLeft;
    AssertEquals('back to the start', 0, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestMoveUpDownPreservesColumn;
var
  E: TTextEdit;
begin
  E := Editor(10, 'abc' + #10 + 'defg');
  try
    E.SetCaret(5);   { row 1, column 1 }
    E.MoveUp;
    AssertEquals('up keeps the column', 1, E.CaretIndex);
    E.MoveDown;
    AssertEquals('down keeps the column', 5, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestMoveUpClampsToShorterRow;
var
  E: TTextEdit;
begin
  E := Editor(10, 'ab' + #10 + 'cdef');
  try
    E.SetCaret(6);   { row 1, column 4 }
    E.MoveUp;
    AssertEquals('clamped to the shorter row', 2, E.CaretIndex);
    { The goal column survives the clamp, so down returns to column 4. }
    E.MoveDown;
    AssertEquals('column restored on the way down', 6, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestMoveUpDownAcrossSoftWrap;
var
  E: TTextEdit;
begin
  E := Editor(3, 'abcdef', wmChar);
  try
    E.SetCaret(4);   { row 1, column 1 }
    E.MoveUp;
    AssertEquals('up into the wrapped row', 1, E.CaretIndex);
    E.MoveDown;
    AssertEquals('down back into the wrapped row', 4, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestMoveUpAtFirstRowDoesNothing;
var
  E: TTextEdit;
begin
  E := Editor(10, 'ab' + #10 + 'cd');
  try
    E.SetCaret(1);
    E.MoveUp;
    AssertEquals('stays on the first row', 1, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestHomeAndEndOnLogicalLine;
var
  E: TTextEdit;
begin
  E := Editor(10, 'abc' + #10 + 'def');
  try
    E.SetCaret(5);
    E.MoveHome;
    AssertEquals('home at the line start', 4, E.CaretIndex);
    E.MoveEnd;
    AssertEquals('end at the line end', 7, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestHomeOnFirstLine;
var
  E: TTextEdit;
begin
  E := Editor(10, 'abc' + #10 + 'def');
  try
    E.SetCaret(2);
    E.MoveHome;
    AssertEquals('home at the buffer start', 0, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestTextRendersInAttr;
var
  E: TTextEdit;
  S: TSurfaceMemory;
  A: TAttr;
begin
  S := TSurfaceMemory.Create(10, 3);
  try
    E := TTextEdit.Create(wmWord);
    try
      A := DefaultAttr;
      A.Fg := 7;
      E.Attr := A;
      E.SetText('ab');
      E.Arrange(Rc(0, 0, 10, 3));
      S.Clear(DefaultAttr);
      E.Render(S);
      S.Flush;
      AssertEquals('first cell', 'a', S.CellAt(0, 0).Ch);
      AssertEquals('second cell', 'b', S.CellAt(1, 0).Ch);
      AssertEquals('text rendition', 7, S.CellAt(0, 0).Attr.Fg);
      AssertEquals('second row untouched', '', S.CellAt(0, 1).Ch);
    finally
      E.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiEditTest.TestCaretAtRowEndIsABlock;
var
  E: TTextEdit;
  S: TSurfaceMemory;
  A: TAttr;
begin
  S := TSurfaceMemory.Create(10, 3);
  try
    E := TTextEdit.Create(wmWord);
    try
      A := DefaultAttr;
      A.Fg := 1;
      E.CaretAttr := A;
      E.SetText('ab');   { caret at the end, column 2 }
      E.Arrange(Rc(0, 0, 10, 3));
      S.Clear(DefaultAttr);
      E.Render(S);
      S.Flush;
      AssertEquals('block caret', '█', S.CellAt(2, 0).Ch);
      AssertEquals('caret rendition', 1, S.CellAt(2, 0).Attr.Fg);
    finally
      E.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiEditTest.TestCaretOnCharacterReversesIt;
var
  E: TTextEdit;
  S: TSurfaceMemory;
  A: TAttr;
begin
  S := TSurfaceMemory.Create(10, 3);
  try
    E := TTextEdit.Create(wmWord);
    try
      A := DefaultAttr;
      A.Fg := 1;
      A.Bg := 3;
      E.CaretAttr := A;
      E.SetText('ab');
      E.SetCaret(1);   { on 'b' }
      E.Arrange(Rc(0, 0, 10, 3));
      S.Clear(DefaultAttr);
      E.Render(S);
      S.Flush;
      AssertEquals('character kept under the caret', 'b', S.CellAt(1, 0).Ch);
      { The caret colour's foreground and background are swapped. }
      AssertEquals('background becomes the caret colour', 1,
        S.CellAt(1, 0).Attr.Bg);
      AssertEquals('foreground becomes the caret background', 3,
        S.CellAt(1, 0).Attr.Fg);
      AssertEquals('neighbour unaffected', 7, S.CellAt(0, 0).Attr.Fg);
    finally
      E.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiEditTest.TestScrollKeepsCaretVisible;
var
  E: TTextEdit;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(5, 2);
  try
    E := TTextEdit.Create(wmChar);
    try
      E.SetText('aaaaa' + #10 + 'bbbbb' + #10 + 'cccc');
      E.Arrange(Rc(0, 0, 5, 2));
      S.Clear(DefaultAttr);
      E.Render(S);
      S.Flush;
      { Three rows in a two-row viewport: the caret is on the last row, so the
        view must have scrolled to show it. }
      AssertEquals('scrolled to the caret row', 1, E.TopRow);
      AssertEquals('first visible row is the middle one', 'b', S.CellAt(0, 0).Ch);
      AssertEquals('caret block on the last row', '█', S.CellAt(4, 1).Ch);
    finally
      E.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiEditTest.TestBlinkTogglesWithAdvance;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    AssertTrue('animating while active', E.Animating);
    AssertFalse('already on at zero', E.Advance(0));
    AssertTrue('toggles off after the half period', E.Advance(600));
    AssertTrue('toggles back on', E.Advance(1200));
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestHandleEventMapsEditingKeys;
var
  E: TTextEdit;
  Ev: TInputEvent;
begin
  E := Editor(10, '');
  try
    Ev := Default(TInputEvent);
    Ev.Kind := ikKey;
    Ev.Key.Kind := kkChar;
    Ev.Key.Ch := 'a';
    AssertTrue('character handled', E.HandleEvent(Ev));
    AssertEquals('character inserted', 'a', string(E.Text));
    Ev.Key.Kind := kkEnter;
    AssertTrue('enter handled', E.HandleEvent(Ev));
    AssertEquals('enter inserts a newline', 'a' + #10, string(E.Text));
    Ev.Key.Kind := kkBackspace;
    AssertTrue('backspace handled', E.HandleEvent(Ev));
    AssertEquals('backspace removed the newline', 'a', string(E.Text));
    Ev.Key.Kind := kkDelete;
    Ev.Key.Ch := '';
    AssertTrue('delete handled', E.HandleEvent(Ev));
    AssertEquals('delete forward at the end is a no-op', 'a', string(E.Text));
    Ev.Key.Kind := kkTab;
    AssertFalse('unmapped key ignored', E.HandleEvent(Ev));
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestClearLineClearsTheCaretLine;
var
  E: TTextEdit;
begin
  E := Editor(20, 'first' + #10 + 'second' + #10 + 'third');
  try
    E.MoveHome;   { caret on the third line }
    E.ClearLine;
    AssertEquals('third line cleared',
      'first' + #10 + 'second' + #10, string(E.Text));
    AssertEquals('caret at the line start', 13, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestClearLineOnEmptyLineIsNoOp;
var
  E: TTextEdit;
begin
  E := Editor(20, 'a' + #10 + #10 + 'b');
  try
    E.SetCaret(2);   { the empty middle line }
    E.ClearLine;
    AssertEquals('unchanged', 'a' + #10 + #10 + 'b', string(E.Text));
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestCtrlUClearsTheLine;
var
  E: TTextEdit;
begin
  E := Editor(20, 'hello world');
  try
    AssertTrue('ctrl+u handled', E.HandleEvent(CharKey('u', [moCtrl])));
    AssertEquals('line cleared', '', string(E.Text));
    AssertEquals('caret at the start', 0, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestCtrlCClearsTheBufferAndReportsHandled;
var
  E: TTextEdit;
begin
  E := Editor(20, 'abc');
  try
    AssertTrue('ctrl+c handled', E.HandleEvent(CharKey('c', [moCtrl])));
    AssertEquals('buffer cleared', '', string(E.Text));
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestCtrlCOnEmptyBufferReportsUnhandled;
var
  E: TTextEdit;
begin
  E := Editor(20, '');
  try
    AssertFalse('ctrl+c falls through when empty',
      E.HandleEvent(CharKey('c', [moCtrl])));
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestHandleEventMapsNavigationKeys;
var
  E: TTextEdit;
  Ev: TInputEvent;
begin
  E := Editor(10, 'abc' + #10 + 'def');
  try
    Ev := Default(TInputEvent);
    Ev.Kind := ikKey;
    Ev.Key.Kind := kkLeft;
    AssertTrue('left handled', E.HandleEvent(Ev));
    AssertEquals('left moved', 6, E.CaretIndex);
    Ev.Key.Kind := kkUp;
    AssertTrue('up handled', E.HandleEvent(Ev));
    AssertEquals('up moved to the row above', 2, E.CaretIndex);
    Ev.Key.Kind := kkHome;
    AssertTrue('home handled', E.HandleEvent(Ev));
    AssertEquals('home at the line start', 0, E.CaretIndex);
    Ev.Key.Kind := kkEnd;
    AssertTrue('end handled', E.HandleEvent(Ev));
    AssertEquals('end at the line end', 3, E.CaretIndex);
    Ev.Key.Kind := kkDown;
    AssertTrue('down handled', E.HandleEvent(Ev));
    AssertEquals('down moved back', 7, E.CaretIndex);
    Ev.Key.Kind := kkRight;
    AssertTrue('right handled', E.HandleEvent(Ev));
    AssertEquals('right clamped at the end', 7, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestMoveWordLeftAndRight;
var
  E: TTextEdit;
begin
  E := Editor(40, 'alpha beta gamma');
  try
    E.MoveWordLeft;
    AssertEquals('left lands on the last word start', 11, E.CaretIndex);
    E.MoveWordLeft;
    AssertEquals('left lands on the middle word start', 6, E.CaretIndex);
    E.MoveWordLeft;
    AssertEquals('left lands on the first word start', 0, E.CaretIndex);
    E.MoveWordRight;
    AssertEquals('right lands on the next word start', 6, E.CaretIndex);
    E.MoveWordRight;
    AssertEquals('right skips to the following word', 11, E.CaretIndex);
    E.MoveWordRight;
    AssertEquals('right ends at the buffer end', 16, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestWordMotionSkipsWhitespace;
var
  E: TTextEdit;
begin
  { A run of spaces and a newline are all word separators. }
  E := Editor(40, 'ab   ' + #10 + '  cd');
  try
    E.MoveWordLeft;
    AssertEquals('left skips the run of separators', 8, E.CaretIndex);
    E.MoveWordLeft;
    AssertEquals('left skips on to the first word', 0, E.CaretIndex);
    E.MoveWordRight;
    AssertEquals('right lands on the second word', 8, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestWordMotionClampsAtEnds;
var
  E: TTextEdit;
begin
  E := Editor(40, 'one');
  try
    E.MoveWordRight;
    AssertEquals('right at the end stays', 3, E.CaretIndex);
    E.MoveWordLeft;
    E.MoveWordLeft;
    AssertEquals('left at the start stays', 0, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestDeleteWordBack;
var
  E: TTextEdit;
begin
  E := Editor(40, 'alpha beta');
  try
    E.DeleteWordBack;
    AssertEquals('the last word is gone', 'alpha ', string(E.Text));
    AssertEquals('caret at the deleted word start', 6, E.CaretIndex);
    E.DeleteWordBack;
    AssertEquals('the trailing space is gone too', '', string(E.Text));
    AssertEquals('caret at the buffer start', 0, E.CaretIndex);
    E.DeleteWordBack;
    AssertEquals('at the start it is a no-op', '', string(E.Text));
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestDeleteWordForward;
var
  E: TTextEdit;
begin
  E := Editor(40, 'alpha beta');
  try
    E.SetCaret(6);
    E.DeleteWordForward;
    AssertEquals('the next word is gone', 'alpha ', string(E.Text));
    AssertEquals('caret stays at the deletion point', 6, E.CaretIndex);
    E.SetCaret(0);
    E.DeleteWordForward;
    AssertEquals('the first word is gone', '', string(E.Text));
    E.DeleteWordForward;
    AssertEquals('at the end it is a no-op', '', string(E.Text));
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestShiftMoveSetsSelection;
var
  E: TTextEdit;
begin
  E := Editor(40, 'abcdef');
  try
    AssertFalse('no selection to start', E.HasSelection);
    AssertTrue('shift-left handled', E.HandleEvent(Key(kkLeft, [moShift])));
    AssertEquals('caret moved', 5, E.CaretIndex);
    AssertTrue('selection exists', E.HasSelection);
    AssertEquals('start is the caret', 5, E.SelectionStart);
    AssertEquals('end is the anchor', 6, E.SelectionEnd);
    E.HandleEvent(Key(kkLeft, [moShift]));
    AssertEquals('extended', 4, E.SelectionStart);
    AssertEquals('end unchanged', 6, E.SelectionEnd);
    AssertTrue('plain move handled', E.HandleEvent(Key(kkLeft, [])));
    AssertFalse('selection dropped by an unshifted move', E.HasSelection);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestBackwardSelectionBounds;
var
  E: TTextEdit;
begin
  E := Editor(40, 'abcdef');
  try
    E.SetCaret(2);
    E.HandleEvent(Key(kkRight, [moShift]));
    E.HandleEvent(Key(kkRight, [moShift]));
    AssertEquals('caret at the far end', 4, E.CaretIndex);
    AssertEquals('start is the anchor', 2, E.SelectionStart);
    AssertEquals('end is the caret', 4, E.SelectionEnd);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestSelectAllAndClear;
var
  E: TTextEdit;
begin
  E := Editor(40, 'abcdef');
  try
    AssertTrue('ctrl+a handled', E.HandleEvent(CharKey('a', [moCtrl])));
    AssertTrue('everything selected', E.HasSelection);
    AssertEquals('start', 0, E.SelectionStart);
    AssertEquals('end', 6, E.SelectionEnd);
    E.ClearSelection;
    AssertFalse('cleared', E.HasSelection);
    AssertEquals('caret untouched', 6, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestInsertReplacesSelection;
var
  E: TTextEdit;
begin
  E := Editor(40, 'abcdef');
  try
    E.SetCaret(2);
    E.HandleEvent(Key(kkRight, [moShift]));
    E.HandleEvent(Key(kkRight, [moShift]));
    E.HandleEvent(Key(kkRight, [moShift]));   { selection [2,5) = "cde" }
    E.HandleEvent(CharKey('X', []));
    AssertEquals('selection replaced', 'abXf', string(E.Text));
    AssertEquals('caret after the insert', 3, E.CaretIndex);
    AssertFalse('selection gone', E.HasSelection);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestBackspaceAndDeleteReplaceSelection;
var
  E: TTextEdit;
begin
  E := Editor(40, 'abcdef');
  try
    E.SetCaret(2);
    E.HandleEvent(Key(kkRight, [moShift]));
    E.HandleEvent(Key(kkRight, [moShift]));
    E.HandleEvent(Key(kkRight, [moShift]));   { [2,5) }
    E.HandleEvent(Key(kkBackspace, []));
    AssertEquals('selection deleted', 'abf', string(E.Text));
    AssertEquals('caret at the selection start', 2, E.CaretIndex);
    E.SetCaret(0);
    E.HandleEvent(Key(kkRight, [moShift]));
    E.HandleEvent(Key(kkRight, [moShift]));   { [0,2) }
    E.HandleEvent(Key(kkDelete, []));
    AssertEquals('forward delete removes the selection too', 'f',
      string(E.Text));
    AssertEquals('caret at the selection start', 0, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestShiftVerticalExtendsSelection;
var
  E: TTextEdit;
begin
  E := Editor(40, 'abc' + #10 + 'def');
  try
    E.SetCaret(2);
    E.HandleEvent(Key(kkDown, [moShift]));
    AssertTrue('selection exists', E.HasSelection);
    AssertEquals('anchor on the first row', 2, E.SelectionStart);
    AssertEquals('caret on the second row', 6, E.SelectionEnd);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestShiftAltExtendsByWord;
var
  E: TTextEdit;
begin
  E := Editor(40, 'alpha beta');
  try
    E.SetCaret(0);
    E.HandleEvent(Key(kkRight, [moShift, moAlt]));
    AssertEquals('caret at the next word start', 6, E.CaretIndex);
    AssertEquals('anchor at the buffer start', 0, E.SelectionStart);
    AssertEquals('selection end', 6, E.SelectionEnd);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestAltBackspaceDeletesWord;
var
  E: TTextEdit;
begin
  E := Editor(40, 'alpha beta');
  try
    E.HandleEvent(Key(kkBackspace, [moAlt]));
    AssertEquals('word removed', 'alpha ', string(E.Text));
    AssertEquals('caret at the word start', 6, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestStickyEndColumnAcrossRows;
var
  E: TTextEdit;
begin
  { Row 0 is short, row 1 is longer. From the end of row 0, Down must land at
    the end of row 1 rather than at column 3. }
  E := Editor(40, 'abc' + #10 + 'defghij');
  try
    E.SetCaret(3);
    E.MoveDown;
    AssertEquals('lands at the end of the longer row', 11, E.CaretIndex);
    E.MoveUp;
    AssertEquals('and back at the end of the short row', 3, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestMidRowColumnStillApplies;
var
  E: TTextEdit;
begin
  E := Editor(40, 'abc' + #10 + 'defghij');
  try
    E.SetCaret(1);
    E.MoveDown;
    AssertEquals('same column on the next row', 5, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestStickyEndSurvivesRepeatedMoves;
var
  E: TTextEdit;
begin
  E := Editor(40, 'ab' + #10 + 'cdef' + #10 + 'g');
  try
    E.SetCaret(2);      { end of row 0 }
    E.MoveDown;
    AssertEquals('second row end', 7, E.CaretIndex);
    E.MoveDown;
    AssertEquals('third row end', 9, E.CaretIndex);
    E.MoveLeft;         { a horizontal move clears the sticky goal }
    E.MoveUp;
    AssertEquals('numeric column after a horizontal move', 3, E.CaretIndex);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestSelectionRendersInSelAttr;
var
  E: TTextEdit;
  S: TSurfaceMemory;
  A, Sel: TAttr;
begin
  S := TSurfaceMemory.Create(10, 3);
  try
    E := TTextEdit.Create(wmWord);
    try
      A := DefaultAttr;
      A.Fg := 7;
      E.Attr := A;
      Sel := DefaultAttr;
      Sel.Fg := 1;
      Sel.Bg := 2;
      E.SelAttr := Sel;
      E.SetText('abcd');
      E.SetCaret(1);
      E.MoveRight(True);   { select 'b' }
      E.Arrange(Rc(0, 0, 10, 3));
      S.Clear(DefaultAttr);
      E.Render(S);
      S.Flush;
      AssertEquals('selected cluster uses the selection foreground', 1,
        S.CellAt(1, 0).Attr.Fg);
      AssertEquals('selected cluster uses the selection background', 2,
        S.CellAt(1, 0).Attr.Bg);
      AssertEquals('unselected cluster untouched', 7,
        S.CellAt(0, 0).Attr.Fg);
    finally
      E.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiEditTest.TestCaretOverlaySwapsColours;
var
  E: TTextEdit;
  A, O: TAttr;
begin
  E := TTextEdit.Create(wmWord);
  try
    A := DefaultAttr;
    A.Fg := 1;
    A.Bg := 3;
    E.CaretAttr := A;
    O := E.CaretOverlay;
    AssertEquals('background becomes the caret colour', 1, O.Bg);
    AssertEquals('foreground becomes the caret background', 3, O.Fg);
  finally
    E.Free;
  end;
end;

procedure TTuiEditTest.TestCaretDoesNotBlinkWithSelection;
var
  E: TTextEdit;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(10, 3);
  try
    E := TTextEdit.Create(wmWord);
    try
      E.SetText('ab');
      E.SetCaret(0);
      E.SelectAll;
      E.Arrange(Rc(0, 0, 10, 3));
      E.Advance(600);   { the blink is off, but a selection is active }
      S.Clear(DefaultAttr);
      E.Render(S);
      S.Flush;
      AssertEquals('caret block still drawn', '█', S.CellAt(2, 0).Ch);
    finally
      E.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiEditTest.TestInactiveCaretIsAHollowBox;
var
  E: TTextEdit;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(10, 3);
  try
    E := TTextEdit.Create(wmWord);
    try
      E.SetText('ab');
      E.Active := False;
      E.Arrange(Rc(0, 0, 10, 3));
      S.Clear(DefaultAttr);
      E.Render(S);
      S.Flush;
      AssertEquals('hollow box past the text', '▯', S.CellAt(2, 0).Ch);
    finally
      E.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiEditTest.TestInactiveCaretDoesNotHighlightACharacter;
var
  E: TTextEdit;
  S: TSurfaceMemory;
  A: TAttr;
begin
  S := TSurfaceMemory.Create(10, 3);
  try
    E := TTextEdit.Create(wmWord);
    try
      A := DefaultAttr;
      A.Fg := 7;
      E.Attr := A;
      E.SetText('ab');
      E.SetCaret(1);
      E.Active := False;
      E.Arrange(Rc(0, 0, 10, 3));
      S.Clear(DefaultAttr);
      E.Render(S);
      S.Flush;
      AssertEquals('character untouched', 'b', S.CellAt(1, 0).Ch);
      AssertEquals('no highlight over the character', 7,
        S.CellAt(1, 0).Attr.Fg);
    finally
      E.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiEditTest.TestActiveRegistersTheCaret;
var
  E: TTextEdit;
begin
  AnimationClock.Reset;
  E := TTextEdit.Create(wmWord);
  try
    AssertEquals('registered at the caret rate', CaretBlinkIntervalMs,
      AnimationClock.MinIntervalMs);
    E.Active := False;
    AssertEquals('cleared when inactive', 0, AnimationClock.MinIntervalMs);
    E.Active := True;
    AssertEquals('back when active', CaretBlinkIntervalMs,
      AnimationClock.MinIntervalMs);
  finally
    E.Free;
    AnimationClock.Reset;
  end;
end;

procedure TTuiEditTest.TestBlinkingHoldsTheCaretSolid;
var
  E: TTextEdit;
begin
  E := TTextEdit.Create(wmWord);
  try
    AssertTrue('blinks by default', E.Blinking);
    E.Advance(1000);   { 1000 div 530 is odd: the caret toggles off }
    E.Blinking := False;
    { A steady caret turns on and then reports no further change. }
    AssertTrue('steady turns the caret on', E.Advance(1000));
    AssertFalse('and stays', E.Advance(1590));
    AssertFalse('and stays', E.Advance(2120));
  finally
    E.Free;
  end;
end;

initialization
  RegisterTest(TTuiEditTest);
end.
