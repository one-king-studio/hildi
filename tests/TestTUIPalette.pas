unit TestTUIPalette;
{ fpcunit tests for TUIWidgetsPalette: the pure command filter and the
  palette's selection/filter behaviour. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, TUIWidgetsPalette,
  TUITheme, TUIInput, TUIBase, TUISurface;

type
  TTuiPaletteTest = class(TTestCase)
  private
    function Cmds: TCommandArray;
    function KeyEvent(AKind: TKeyKind): TInputEvent;
  published
    procedure TestFilterEmptyShowsAll;
    procedure TestFilterByPrefix;
    procedure TestFilterIgnoresLeadingSlash;
    procedure TestFilterCaseInsensitive;
    procedure TestFilterNoMatch;
    procedure TestPaletteFilterAndSelect;
    procedure TestSelectedNameEmpty;
    { The list WRAPS: pressing down past the last row returns to the first, and
      up past the first goes to the last. Clamping made the operator press up N
      times to get back to the top. }
    procedure TestSelectionWrapsAtBothEnds;
    { The panel's height must leave a row for EVERY command AND the hint row.
      Reported live: typing /ski showed only /skill, which was drawn on the row
      the hints then covered - so the only match was invisible. }
    procedure TestSingleMatchIsVisibleAboveTheHintRow;
  end;

implementation

function TTuiPaletteTest.KeyEvent(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function TTuiPaletteTest.Cmds: TCommandArray;
begin
  Result := nil;
  SetLength(Result, 3);
  Result[0].Name := 'checkpoint';
  Result[0].Description := 'hand off the session';
  Result[1].Name := 'help';
  Result[1].Description := 'show help';
  Result[2].Name := 'clear';
  Result[2].Description := 'clear the view';
end;

procedure TTuiPaletteTest.TestFilterEmptyShowsAll;
begin
  AssertEquals('all', 3, Length(FilterCommands(Cmds, '')));
end;

procedure TTuiPaletteTest.TestFilterByPrefix;
var
  R: TCommandArray;
begin
  R := FilterCommands(Cmds, 'ch');
  AssertEquals('one', 1, Length(R));
  AssertEquals('checkpoint', 'checkpoint', R[0].Name);
end;

procedure TTuiPaletteTest.TestFilterIgnoresLeadingSlash;
var
  R: TCommandArray;
begin
  R := FilterCommands(Cmds, '/che');
  AssertEquals('one', 1, Length(R));
  AssertEquals('checkpoint', 'checkpoint', R[0].Name);
end;

procedure TTuiPaletteTest.TestFilterCaseInsensitive;
var
  R: TCommandArray;
begin
  R := FilterCommands(Cmds, 'HELP');
  AssertEquals('one', 1, Length(R));
  AssertEquals('help', 'help', R[0].Name);
end;

procedure TTuiPaletteTest.TestFilterNoMatch;
begin
  AssertEquals('none', 0, Length(FilterCommands(Cmds, 'zzz')));
end;

procedure TTuiPaletteTest.TestPaletteFilterAndSelect;
var
  P: TCommandPalette;
  T: TCommandArray;
begin
  P := TCommandPalette.Create(Default(TTheme));
  try
    T := Cmds;
    P.SetCommands(T);
    AssertEquals('all visible', 3, P.VisibleCount);
    AssertEquals('first selected', 'checkpoint', P.SelectedName);
    P.Filter('/cl');
    AssertEquals('one visible', 1, P.VisibleCount);
    AssertEquals('clear selected', 'clear', P.SelectedName);
  finally
    P.Free;
  end;
end;

procedure TTuiPaletteTest.TestSelectedNameEmpty;
var
  P: TCommandPalette;
begin
  P := TCommandPalette.Create(Default(TTheme));
  try
    AssertEquals('no commands -> empty', '', P.SelectedName);
  finally
    P.Free;
  end;
end;

procedure TTuiPaletteTest.TestSelectionWrapsAtBothEnds;
var
  P: TCommandPalette;
  T: TCommandArray;
begin
  P := TCommandPalette.Create(Default(TTheme));
  try
    T := Cmds;
    P.SetCommands(T);
    AssertEquals('starts on the first', 'checkpoint', P.SelectedName);
    { Down past the last row returns to the first. }
    P.HandleEvent(KeyEvent(kkDown));
    P.HandleEvent(KeyEvent(kkDown));
    AssertEquals('on the last', 'clear', P.SelectedName);
    P.HandleEvent(KeyEvent(kkDown));
    AssertEquals('down wraps to the first', 'checkpoint', P.SelectedName);
    { Up past the first row goes to the last. }
    P.HandleEvent(KeyEvent(kkUp));
    AssertEquals('up wraps to the last', 'clear', P.SelectedName);
  finally
    P.Free;
  end;
end;

procedure TTuiPaletteTest.TestSingleMatchIsVisibleAboveTheHintRow;
var
  P: TCommandPalette;
  T: TCommandArray;
  Mem: TSurfaceMemory;
  R: TRect;
  H, Row: Integer;
  Line: UnicodeString;
  SawName, SawHint: Boolean;
begin
  { Reported live: typing /ski matched only /skill, and it was INVISIBLE - drawn
    on the row the hint line then painted over. The height and the render
    disagreed: Measure returned border + N, while Render reserved the last row
    for hints, leaving N-1 rows for commands. With a single match that is zero.

    This asserts on the RENDERED surface rather than on Measure, because the bug
    was the two disagreeing - a Measure-only test would have passed. }
  P := TCommandPalette.Create(Default(TTheme));
  Mem := TSurfaceMemory.Create(40, 10);
  try
    SetLength(T, 1);
    T[0].Name := 'skill';
    T[0].Description := 'load a skill';
    P.SetCommands(T);
    { Give it exactly the height it asks for, as the panel host does. }
    R := Default(TRect);
    R.W := 40;
    R.H := 10;
    H := P.Measure(Default(TSize)).H;
    R.H := H;
    P.Arrange(R);
    P.Render(Mem);

    SawName := False;
    SawHint := False;
    for Row := 0 to H - 1 do
    begin
      Line := Mem.RowText(Row, 0, 40);
      if Pos('/skill', Line) > 0 then
        SawName := True;
      if Pos('enter', Line) > 0 then
        SawHint := True;
    end;
    { Both, on different rows: the command visible AND the hint present. }
    AssertTrue('the single match is rendered', SawName);
    AssertTrue('the hint row is rendered too', SawHint);
    AssertTrue('and the panel is tall enough for both', H >= 3);
  finally
    Mem.Free;
    P.Free;
  end;
end;

initialization
  RegisterTest(TTuiPaletteTest);
end.
