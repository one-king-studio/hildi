unit test_tui_palette;
{ fpcunit tests for hildegard.helper.tui.palette: the pure command filter and the
  palette's selection/filter behaviour. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, hildegard.helper.tui.palette,
  hildegard.helper.tui.theme;

type
  TTuiPaletteTest = class(TTestCase)
  private
    function Cmds: TCommandArray;
  published
    procedure TestFilterEmptyShowsAll;
    procedure TestFilterByPrefix;
    procedure TestFilterIgnoresLeadingSlash;
    procedure TestFilterCaseInsensitive;
    procedure TestFilterNoMatch;
    procedure TestPaletteFilterAndSelect;
    procedure TestSelectedNameEmpty;
  end;

implementation

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

initialization
  RegisterTest(TTuiPaletteTest);
end.
