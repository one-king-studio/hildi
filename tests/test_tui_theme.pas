unit test_tui_theme;
{ fpcunit tests for hildegard.helper.tui.theme (pure background detection). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.theme;

type
  TTuiThemeTest = class(TTestCase)
  published
    procedure TestParseOSC11SixteenBit;
    procedure TestParseOSC11Hash;
    procedure TestColorIsLight;
    procedure TestParseColorFGBG;
  end;

implementation

procedure TTuiThemeTest.TestParseOSC11SixteenBit;
var
  R, G, B: Byte;
begin
  AssertTrue('parsed',
    ParseOSC11(#27']11;rgb:1e1e/3030/ffff'#7, R, G, B));
  AssertEquals('red', $1e, R);
  AssertEquals('green', $30, G);
  AssertEquals('blue', $ff, B);
end;

procedure TTuiThemeTest.TestParseOSC11Hash;
var
  R, G, B: Byte;
begin
  AssertTrue('parsed', ParseOSC11(']11;rgb:#0a0b0c', R, G, B));
  AssertEquals('red', $0a, R);
  AssertEquals('green', $0b, G);
  AssertEquals('blue', $0c, B);
end;

procedure TTuiThemeTest.TestColorIsLight;
begin
  AssertTrue('white is light', ColorIsLight(255, 255, 255));
  AssertFalse('black is dark', ColorIsLight(0, 0, 0));
  AssertFalse('dark grey is dark', ColorIsLight(30, 30, 30));
  AssertTrue('mid grey is light', ColorIsLight(128, 128, 128));
end;

procedure TTuiThemeTest.TestParseColorFGBG;
var
  K: TThemeKind;
begin
  AssertTrue('parsed dark', ParseColorFGBG('15;0', K));
  AssertTrue('is dark', K = thDark);
  AssertTrue('parsed light', ParseColorFGBG('0;15', K));
  AssertTrue('is light', K = thLight);
  AssertFalse('garbage', ParseColorFGBG('nonsense', K));
end;

initialization
  RegisterTest(TTuiThemeTest);
end.
