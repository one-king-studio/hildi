unit TestTUISelectable;
{ fpcunit tests for TSelectable: the widget half of text selection.

  Drives a probe selectable through scripted mouse events - press, motion,
  release - and asserts both what it selected and what it painted. The paint is
  checked on a memory surface, so the highlight is verified cell by cell rather
  than described.

  The probe draws its own text and then calls RenderSelection, which is the
  contract a real subclass follows: TSelectable recolours cells that are already
  there, it does not paint text. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput, TUISurface, TUITheme, TUIWidget,
  TUISelection, TUIWidgetsSelectable;

type
  { A minimal selectable: fixed rows, all hard breaks, drawn plainly. }
  TProbeSelectable = class(TSelectable)
  private
    FRows: TStringArray;
  protected
    function RowCount: Integer; override;
    function RowTextAt(ARow: Integer): UnicodeString; override;
    function RowWrapsAt(ARow: Integer): Boolean; override;
  public
    constructor Create(const ARows: TStringArray);
    { Draw the rows as plain text, then the highlight - the real contract. }
    procedure Render(const S: ISurface); override;
  end;

  TSelectableTest = class(TTestCase)
  private
    FTheme: TTheme;
    function Mouse(X, Y: Integer; AButton: TMouseButton;
      AAction: TMouseAction): TInputEvent;
    function MakeProbe(const ARows: TStringArray): TProbeSelectable;
  protected
    procedure SetUp; override;
  published
    procedure TestPressStartsASelection;
    procedure TestDragExtendsTheSelection;
    procedure TestReleaseEndsTheDrag;
    procedure TestBackwardsDragNormalises;
    procedure TestClickWithoutDragSelectsNothing;
    procedure TestShiftPressIsNotConsumed;
    procedure TestSelectionTextReadsTheRows;
    procedure TestHighlightPaintsTheSelectedCells;
    procedure TestHighlightLeavesUnselectedCellsAlone;
    procedure TestHighlightIsAbsentWhenNothingIsSelected;
    procedure TestClearSelectionRemovesTheHighlight;
    procedure TestContentChangeMarksTheSelectionStale;
  end;

implementation

{ TProbeSelectable }

constructor TProbeSelectable.Create(const ARows: TStringArray);
begin
  inherited Create;
  FRows := ARows;
  { Selection is opt-in now: a leaf that adopts this base must not swallow
    presses unless the host asks. }
  Selectable := True;
end;

function TProbeSelectable.RowCount: Integer;
begin
  Result := Length(FRows);
end;

function TProbeSelectable.RowTextAt(ARow: Integer): UnicodeString;
begin
  if (ARow >= 0) and (ARow <= High(FRows)) then
    Result := UnicodeString(FRows[ARow])
  else
    Result := '';
end;

function TProbeSelectable.RowWrapsAt(ARow: Integer): Boolean;
begin
  { Hard breaks only: every row ends because the text ended. }
  Result := False;
end;

procedure TProbeSelectable.Render(const S: ISurface);
var
  I, X: Integer;
  C: TCell;
  Line: UnicodeString;
begin
  for I := 0 to RowCount - 1 do
  begin
    Line := RowTextAt(I);
    for X := 1 to Length(Line) do
    begin
      C := Default(TCell);
      C.Ch := Line[X];
      C.Attr := DefaultAttr;
      S.Put(Bounds.X + X - 1, Bounds.Y + I, C);
    end;
  end;
  RenderSelection(S);
end;

{ TSelectableTest }

procedure TSelectableTest.SetUp;
begin
  FTheme := DarkTheme;
end;

function TSelectableTest.Mouse(X, Y: Integer; AButton: TMouseButton;
  AAction: TMouseAction): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikMouse;
  Result.Mouse.X := X;
  Result.Mouse.Y := Y;
  Result.Mouse.Button := AButton;
  Result.Mouse.Action := AAction;
end;

function TSelectableTest.MakeProbe(const ARows: TStringArray): TProbeSelectable;
var
  R: TRect;
begin
  Result := TProbeSelectable.Create(ARows);
  R := Default(TRect);
  R.X := 0;
  R.Y := 0;
  R.W := 20;
  R.H := Length(ARows);
  Result.Arrange(R);
  Result.SetContentOrigin(R.X, R.Y);
end;

procedure TSelectableTest.TestPressStartsASelection;
var
  W: TProbeSelectable;
begin
  W := MakeProbe(['alpha', 'beta']);
  try
    AssertTrue('press consumed', W.HandleEvent(Mouse(2, 0, mbLeft, maPress)));
    AssertTrue('a selection is active', W.Selection.Active);
    AssertEquals('anchor row', 0, W.Selection.Anchor.Row);
    AssertEquals('anchor col', 2, W.Selection.Anchor.Col);
    AssertTrue('dragging', W.Dragging);
  finally
    W.Free;
  end;
end;

procedure TSelectableTest.TestDragExtendsTheSelection;
var
  W: TProbeSelectable;
begin
  W := MakeProbe(['alpha', 'beta']);
  try
    W.HandleEvent(Mouse(1, 0, mbLeft, maPress));
    AssertTrue('motion consumed', W.HandleEvent(Mouse(3, 1, mbLeft, maMotion)));
    AssertEquals('caret row', 1, W.Selection.Caret.Row);
    AssertEquals('caret col', 3, W.Selection.Caret.Col);
    AssertEquals('anchor unchanged', 1, W.Selection.Anchor.Col);
  finally
    W.Free;
  end;
end;

procedure TSelectableTest.TestReleaseEndsTheDrag;
var
  W: TProbeSelectable;
begin
  W := MakeProbe(['alpha']);
  try
    W.HandleEvent(Mouse(0, 0, mbLeft, maPress));
    W.HandleEvent(Mouse(5, 0, mbLeft, maMotion));
    AssertTrue('release consumed', W.HandleEvent(Mouse(5, 0, mbNone, maRelease)));
    AssertFalse('dragging stopped', W.Dragging);
    AssertTrue('the selection survives the release', W.Selection.Active);
    AssertEquals('text is still the selection', 'alpha', W.SelectedText);
  finally
    W.Free;
  end;
end;

procedure TSelectableTest.TestBackwardsDragNormalises;
var
  W: TProbeSelectable;
  Span: TTextSpan;
begin
  W := MakeProbe(['abcdef']);
  try
    W.HandleEvent(Mouse(4, 0, mbLeft, maPress));
    W.HandleEvent(Mouse(1, 0, mbLeft, maMotion));
    Span := SelectionSpan(W.Selection);
    AssertEquals('start is the smaller column', 1, Span.Start.Col);
    AssertEquals('stop is the larger column', 4, Span.Stop.Col);
    AssertEquals('text in reading order', 'bcd', W.SelectedText);
  finally
    W.Free;
  end;
end;

procedure TSelectableTest.TestClickWithoutDragSelectsNothing;
var
  W: TProbeSelectable;
begin
  W := MakeProbe(['alpha']);
  try
    W.HandleEvent(Mouse(2, 0, mbLeft, maPress));
    W.HandleEvent(Mouse(2, 0, mbNone, maRelease));
    AssertFalse('a press with no movement selected nothing',
      SelectionIsUsable(W.Selection));
    AssertEquals('and copies nothing', '', W.SelectedText);
  finally
    W.Free;
  end;
end;

procedure TSelectableTest.TestShiftPressIsNotConsumed;
var
  W: TProbeSelectable;
  E: TInputEvent;
begin
  W := MakeProbe(['alpha']);
  try
    E := Mouse(2, 0, mbLeft, maPress);
    Include(E.Mouse.Mods, moShift);
    { Shift+drag is the terminal's own selection. A widget that consumed it
      would take that away from the operator. }
    AssertFalse('shift+click is not consumed', W.HandleEvent(E));
    AssertFalse('and starts no selection', W.Selection.Active);
  finally
    W.Free;
  end;
end;

procedure TSelectableTest.TestSelectionTextReadsTheRows;
var
  W: TProbeSelectable;
begin
  W := MakeProbe(['alpha', 'beta']);
  try
    W.HandleEvent(Mouse(3, 0, mbLeft, maPress));
    W.HandleEvent(Mouse(2, 1, mbLeft, maMotion));
    AssertEquals('from mid row 0 to mid row 1',
      'ha' + LineEnding + 'be', W.SelectedText);
  finally
    W.Free;
  end;
end;

procedure TSelectableTest.TestHighlightPaintsTheSelectedCells;
var
  W: TProbeSelectable;
  S: TSurfaceMemory;
  Painted, Selected: TAttr;
begin
  W := MakeProbe(['abcdef']);
  S := TSurfaceMemory.Create(10, 2);
  try
    S.SetScreenBg(FTheme.Bg);
    W.Render(S);
    Painted := S.CellAt(2, 0).Attr;

    W.HandleEvent(Mouse(1, 0, mbLeft, maPress));
    W.HandleEvent(Mouse(4, 0, mbLeft, maMotion));
    W.Render(S);

    Selected := S.CellAt(2, 0).Attr;
    AssertTrue('the glyph survived the highlight', S.CellAt(2, 0).Ch <> '');
    AssertTrue('a selected cell is painted differently',
      (Selected.Fg <> Painted.Fg) or (Selected.Bg <> Painted.Bg) or
      (Selected.Style <> Painted.Style));
  finally
    W.Free;
    S.Free;
  end;
end;

procedure TSelectableTest.TestHighlightLeavesUnselectedCellsAlone;
var
  W: TProbeSelectable;
  S: TSurfaceMemory;
  OutsideBefore, OutsideAfter: TAttr;
begin
  W := MakeProbe(['abcdef']);
  S := TSurfaceMemory.Create(10, 2);
  try
    S.SetScreenBg(FTheme.Bg);
    W.Render(S);
    OutsideBefore := S.CellAt(0, 0).Attr;

    { Select cells 1..3 only; cell 0 must be untouched. }
    W.HandleEvent(Mouse(1, 0, mbLeft, maPress));
    W.HandleEvent(Mouse(3, 0, mbLeft, maMotion));
    W.Render(S);

    OutsideAfter := S.CellAt(0, 0).Attr;
    AssertTrue('cell 0 is outside the span and unchanged',
      (OutsideBefore.Fg = OutsideAfter.Fg) and
      (OutsideBefore.Bg = OutsideAfter.Bg) and
      (OutsideBefore.Style = OutsideAfter.Style));
  finally
    W.Free;
    S.Free;
  end;
end;

procedure TSelectableTest.TestHighlightIsAbsentWhenNothingIsSelected;
var
  W: TProbeSelectable;
  S: TSurfaceMemory;
  Before, After: TAttr;
begin
  W := MakeProbe(['abcdef']);
  S := TSurfaceMemory.Create(10, 2);
  try
    S.SetScreenBg(FTheme.Bg);
    W.Render(S);
    Before := S.CellAt(2, 0).Attr;
    W.Render(S);
    After := S.CellAt(2, 0).Attr;
    AssertTrue('rendering again with no selection changes nothing',
      (Before.Fg = After.Fg) and (Before.Bg = After.Bg) and
      (Before.Style = After.Style));
  finally
    W.Free;
    S.Free;
  end;
end;

procedure TSelectableTest.TestClearSelectionRemovesTheHighlight;
var
  W: TProbeSelectable;
begin
  W := MakeProbe(['abcdef']);
  try
    W.HandleEvent(Mouse(1, 0, mbLeft, maPress));
    W.HandleEvent(Mouse(4, 0, mbLeft, maMotion));
    AssertTrue('selection exists', W.Selection.Active);
    W.ClearSelection;
    AssertFalse('cleared', W.Selection.Active);
    AssertEquals('and copies nothing', '', W.SelectedText);
  finally
    W.Free;
  end;
end;

procedure TSelectableTest.TestContentChangeMarksTheSelectionStale;
var
  W: TProbeSelectable;
begin
  W := MakeProbe(['abcdef']);
  try
    W.HandleEvent(Mouse(1, 0, mbLeft, maPress));
    W.HandleEvent(Mouse(4, 0, mbLeft, maMotion));
    AssertFalse('fresh', W.Selection.Stale);
    W.ContentChanged;
    AssertTrue('stale after the content changed', W.Selection.Stale);
    AssertFalse('and no longer usable', SelectionIsUsable(W.Selection));
  finally
    W.Free;
  end;
end;

initialization
  RegisterTest(TSelectableTest);
end.
