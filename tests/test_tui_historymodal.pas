unit test_tui_historymodal;
{ fpcunit tests for the shared history dialog (tui.widgets.historymodal): one
  list, three intents, newest first, unselectable rows skipped. Headless, against
  TSurfaceMemory and scripted input. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  tui.base, tui.input,
  tui.surface, tui.widget,
  tui.theme,
  tui.widgets.historymodal;

type
  THistoryModalTest = class(TTestCase)
  private
    FModal: THistoryModal;
    FSurface: TSurfaceMemory;
    FTheme: TTheme;
    FChosen: Int64;
    FChooseCount: Integer;
    procedure NoteChoose(const ATurnId: Int64);
    procedure Render;
    function Key(AKind: TKeyKind): TInputEvent;
    function Row(ATurnId: Int64; ASeq: Integer; const ATitle: string;
      AFiles, AAdded, ARemoved: Integer; ASelectable: Boolean = True;
      AUndone: Boolean = False): THistoryRow;
    function Rows3: THistoryRowArray;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    { Rows render newest-first as given, with seq, stats and title. }
    procedure TestRendersTheRowsAsGiven;
    { Down/Up move, Home/End jump, and the selection clamps. }
    procedure TestNavigationMovesAndClamps;
    { Enter reports the selected turn id, once. }
    procedure TestEnterChoosesTheSelectedTurn;
    { A row the host marked unselectable is skipped by the arrows and refused by
      Enter: the operator never lands somewhere Enter does nothing. }
    procedure TestUnselectableRowsAreSkipped;
    { If every row is unselectable there is nothing to choose, and Enter says so
      by doing nothing rather than choosing an arbitrary turn. }
    procedure TestAllUnselectableChoosesNothing;
    { The first selectable row is selected on load, not row 0 blindly. }
    procedure TestOpensOnTheFirstSelectableRow;
    { An undone turn is drawn differently - the SAME list serves undo and redo,
      so the operator must be able to see which turns are already undone. }
    procedure TestAnUndoneRowIsDrawnDifferently;
    { An unknown count renders '?', never a fabricated +0 -0. }
    procedure TestAnUnknownCountSaysQuestionMark;
    { The intent changes the footer verb but not the list. }
    procedure TestTheIntentNamesTheAction;
    { An empty list draws a notice and consumes only Escape. }
    procedure TestAnEmptyListIsDrawnNotCrashed;
    { Escape is left to the host: the plane pop is deferred there. }
    procedure TestEscapeIsNotConsumed;
  end;

implementation

const
  SurfaceW = 70;
  SurfaceH = 14;

procedure THistoryModalTest.NoteChoose(const ATurnId: Int64);
begin
  FChosen := ATurnId;
  Inc(FChooseCount);
end;

procedure THistoryModalTest.SetUp;
var
  Sz: TSize;
  Bounds: TRect;
begin
  FTheme := DarkTheme;
  FModal := THistoryModal.Create(FTheme);
  FModal.OnChoose := NoteChoose;
  FChosen := 0;
  FChooseCount := 0;
  FSurface := TSurfaceMemory.Create(SurfaceW, SurfaceH);
  Sz := Default(TSize);
  Sz.W := SurfaceW;
  Sz.H := SurfaceH;
  FModal.Measure(Sz);
  Bounds := Default(TRect);
  Bounds.X := 0;
  Bounds.Y := 0;
  Bounds.W := SurfaceW;
  Bounds.H := SurfaceH;
  FModal.Arrange(Bounds);
end;

procedure THistoryModalTest.TearDown;
begin
  FModal.Free;
  FSurface.Free;
end;

procedure THistoryModalTest.Render;
begin
  FSurface.Clear(Default(TAttr));
  FModal.Render(FSurface);
end;

function THistoryModalTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function THistoryModalTest.Row(ATurnId: Int64; ASeq: Integer;
  const ATitle: string; AFiles, AAdded, ARemoved: Integer;
  ASelectable: Boolean; AUndone: Boolean): THistoryRow;
begin
  Result := Default(THistoryRow);
  Result.TurnId := ATurnId;
  Result.Seq := ASeq;
  Result.Title := ATitle;
  Result.Files := AFiles;
  Result.Added := AAdded;
  Result.Removed := ARemoved;
  Result.CountsKnown := AFiles > 0;
  Result.Selectable := ASelectable;
  Result.Undone := AUndone;
end;

function THistoryModalTest.Rows3: THistoryRowArray;
begin
  Result := nil;
  SetLength(Result, 3);
  Result[0] := Row(30, 3, 'the newest turn', 2, 10, 4);
  Result[1] := Row(20, 2, 'the middle turn', 1, 3, 0);
  Result[2] := Row(10, 1, 'the oldest turn', 4, 1, 9);
end;

procedure THistoryModalTest.TestRendersTheRowsAsGiven;
var
  Text: UnicodeString;
begin
  FModal.SetRows(Rows3);
  Render;
  Text := FSurface.RowText(1, 0, SurfaceW) + FSurface.RowText(2, 0, SurfaceW) +
    FSurface.RowText(3, 0, SurfaceW);
  AssertTrue('the newest turn is shown: ' + string(Text),
    Pos('the newest turn', string(Text)) > 0);
  AssertTrue('the middle turn is shown', Pos('the middle turn', string(Text)) > 0);
  AssertTrue('the oldest turn is shown', Pos('the oldest turn', string(Text)) > 0);
  AssertTrue('with its stat', Pos('+10', string(Text)) > 0);
end;

procedure THistoryModalTest.TestNavigationMovesAndClamps;
begin
  FModal.SetRows(Rows3);
  AssertEquals('starts at the newest', 30, FModal.SelectedTurnId);
  AssertTrue('down', FModal.HandleEvent(Key(kkDown)));
  AssertEquals('moved to the middle', 20, FModal.SelectedTurnId);
  AssertTrue('up', FModal.HandleEvent(Key(kkUp)));
  AssertEquals('back at the newest', 30, FModal.SelectedTurnId);
  { Up at the top clamps rather than wrapping or going out of range. }
  FModal.HandleEvent(Key(kkUp));
  AssertEquals('clamped at the top', 30, FModal.SelectedTurnId);
  AssertTrue('end', FModal.HandleEvent(Key(kkEnd)));
  AssertEquals('jumped to the oldest', 10, FModal.SelectedTurnId);
  AssertTrue('home', FModal.HandleEvent(Key(kkHome)));
  AssertEquals('back to the newest', 30, FModal.SelectedTurnId);
end;

procedure THistoryModalTest.TestEnterChoosesTheSelectedTurn;
begin
  FModal.SetRows(Rows3);
  FModal.HandleEvent(Key(kkDown));
  AssertTrue('enter is consumed', FModal.HandleEvent(Key(kkEnter)));
  AssertEquals('the middle turn was chosen', 20, FChosen);
  AssertEquals('exactly once', 1, FChooseCount);
end;

procedure THistoryModalTest.TestUnselectableRowsAreSkipped;
var
  R: THistoryRowArray;
begin
  SetLength(R, 3);
  R[0] := Row(30, 3, 'newest', 1, 1, 0);
  R[1] := Row(20, 2, 'a running turn', 0, 0, 0, False);
  R[2] := Row(10, 1, 'oldest', 1, 2, 2);
  FModal.SetRows(R);
  AssertEquals('starts on the newest', 30, FModal.SelectedTurnId);
  FModal.HandleEvent(Key(kkDown));
  { The middle row is unselectable, so Down lands on the oldest. }
  AssertEquals('skipped the unselectable row', 10, FModal.SelectedTurnId);
end;

procedure THistoryModalTest.TestAllUnselectableChoosesNothing;
var
  R: THistoryRowArray;
begin
  SetLength(R, 2);
  R[0] := Row(30, 2, 'busy', 0, 0, 0, False);
  R[1] := Row(20, 1, 'also busy', 0, 0, 0, False);
  FModal.SetRows(R);
  AssertEquals('nothing to select', 0, FModal.SelectedTurnId);
  FModal.HandleEvent(Key(kkEnter));
  AssertEquals('nothing was chosen', 0, FChooseCount);
end;

procedure THistoryModalTest.TestOpensOnTheFirstSelectableRow;
var
  R: THistoryRowArray;
begin
  { Opening on a greyed-out row would make Enter look broken. }
  SetLength(R, 2);
  R[0] := Row(30, 2, 'running', 0, 0, 0, False);
  R[1] := Row(20, 1, 'done', 1, 1, 0);
  FModal.SetRows(R);
  AssertEquals('the first selectable row is selected', 20, FModal.SelectedTurnId);
end;

procedure THistoryModalTest.TestAnUndoneRowIsDrawnDifferently;
var
  Plain, Undone: THistoryModal;
  SP, SU: TSurfaceMemory;
  Sz: TSize;
  Bounds: TRect;

  procedure Arrange(M: THistoryModal; S: TSurfaceMemory);
  begin
    Sz := Default(TSize);
    Sz.W := SurfaceW;
    Sz.H := SurfaceH;
    M.Measure(Sz);
    Bounds := Default(TRect);
    Bounds.X := 0;
    Bounds.Y := 0;
    Bounds.W := SurfaceW;
    Bounds.H := SurfaceH;
    M.Arrange(Bounds);
  end;

var
  I: Integer;
  Differs: Boolean;
  R: THistoryRowArray;
begin
  { The same list serves undo and redo, so an already-undone turn must be
    visually distinct or the operator cannot tell what redo would restore. }
  Plain := THistoryModal.Create(FTheme);
  Undone := THistoryModal.Create(FTheme);
  SP := TSurfaceMemory.Create(SurfaceW, SurfaceH);
  SU := TSurfaceMemory.Create(SurfaceW, SurfaceH);
  try
    Arrange(Plain, SP);
    Arrange(Undone, SU);
    SetLength(R, 2);
    { Two rows: the FIRST is selected on load, so the second is the one drawn in
      its plain colour. Comparing the selected row would compare the selection
      highlight in both cases and prove nothing - selection wins over the undone
      tint, which is the right precedence but not what this test is about. }
    R[0] := Row(40, 4, 'a live turn', 1, 1, 0);
    R[1] := Row(30, 3, 'a turn', 1, 1, 0);
    Plain.SetRows(R);
    R[1] := Row(30, 3, 'a turn', 1, 1, 0, True, True);
    Undone.SetRows(R);
    Plain.Render(SP);
    Undone.Render(SU);

    { Compare the second row, which is unselected in both. }
    Differs := False;
    for I := 0 to SurfaceW - 1 do
      if SP.CellAt(I, 2).Attr.Fg <> SU.CellAt(I, 2).Attr.Fg then
        Differs := True;
    AssertTrue('an undone row is coloured differently', Differs);
  finally
    Plain.Free;
    Undone.Free;
    SP.Free;
    SU.Free;
  end;
end;

procedure THistoryModalTest.TestAnUnknownCountSaysQuestionMark;
var
  R: THistoryRowArray;
  Text: UnicodeString;
begin
  SetLength(R, 1);
  R[0] := Row(30, 3, 'process tier', 2, 0, 0);
  R[0].CountsKnown := False;
  FModal.SetRows(R);
  Render;
  Text := FSurface.RowText(1, 0, SurfaceW);
  AssertTrue('says ? rather than a fabricated zero: ' + string(Text),
    Pos('+?', string(Text)) > 0);
end;

procedure THistoryModalTest.TestTheIntentNamesTheAction;
var
  Footer: UnicodeString;
begin
  FModal.SetRows(Rows3);
  FModal.Intent := hiUndo;
  Render;
  Footer := FSurface.RowText(SurfaceH - 1, 0, SurfaceW);
  AssertTrue('undo verb: ' + string(Footer), Pos('undo to this turn',
    string(Footer)) > 0);

  FModal.Intent := hiRevert;
  Render;
  Footer := FSurface.RowText(SurfaceH - 1, 0, SurfaceW);
  AssertTrue('revert verb: ' + string(Footer), Pos('revert this turn',
    string(Footer)) > 0);

  { The LIST is unchanged by the intent - that is what lets one dialog serve
    three commands. }
  AssertEquals('the same rows are still offered', 30, FModal.SelectedTurnId);
end;

procedure THistoryModalTest.TestAnEmptyListIsDrawnNotCrashed;
var
  Text: UnicodeString;
begin
  FModal.SetRows(nil);
  Render;
  Text := FSurface.RowText(1, 0, SurfaceW);
  AssertTrue('a notice is drawn: ' + string(Text),
    Pos('no turns', string(Text)) > 0);
  AssertFalse('enter does nothing', FModal.HandleEvent(Key(kkEnter)));
  AssertEquals('nothing chosen', 0, FChooseCount);
end;

procedure THistoryModalTest.TestEscapeIsNotConsumed;
begin
  FModal.SetRows(Rows3);
  { The plane pop is deferred in the host, as with the sessions modal: consuming
    Escape here would strand the plane. }
  AssertFalse('escape is the host''s', FModal.HandleEvent(Key(kkEscape)));
end;

initialization
  RegisterTest(THistoryModalTest);

end.
