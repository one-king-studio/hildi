unit hildegard.helper.tui.theme;
{ Named colour roles for the widget kit, so widgets do not hard-code attributes.
  Indices are 256-colour palette entries (see TAttr).

  Every role paints the app's screen background (sfScreenBg) rather than its own
  Bg index, so text never sits on a mismatched box; the app sets that background
  from TTheme.Bg. The theme itself is chosen by TThemeMode: detected from the
  terminal (auto) or forced (dark/light). }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base;

type
  TTheme = record
    Bg: Byte;         // the app background painted for sfScreenBg cells
    Base: TAttr;      // screen background
    Panel: TAttr;     // panel / box background
    Border: TAttr;    // box-drawing frame
    Title: TAttr;     // panel title
    Text: TAttr;      // primary text
    Muted: TAttr;     // secondary text
    Accent: TAttr;    // focus / selection
    Warn: TAttr;      // tool / caution
    Error: TAttr;
    Success: TAttr;
  end;

  { How the theme is chosen: detect from the terminal (auto) or force one,
    regardless of the system's own setting. }
  TThemeMode = (tmAuto, tmDark, tmLight);

const
  DarkBg = 234;    // #1c1c1c - a neutral near-black
  LightBg = 255;   // #eeeeee

function DarkTheme: TTheme;
function LightTheme: TTheme;

{ Pick a theme: force dark/light, or follow the detected terminal background. }
function SelectTheme(AMode: TThemeMode; ALightDetected: Boolean): TTheme;

{ Parse `dark`/`light`/`auto` (anything else is auto). }
function ThemeModeFromString(const S: string): TThemeMode;
function ThemeModeName(AMode: TThemeMode): string;

implementation

uses
  SysUtils;

function MakeAttr(AFg: Byte; AStyle: TStyle = []): TAttr;
begin
  { All roles use the app's screen background (sfScreenBg), so the UI does not
    paint a second, mismatched grey behind the text. }
  Result := DefaultAttr;
  Result.Fg := AFg;
  Result.Style := AStyle + [sfScreenBg];
end;

function DarkTheme: TTheme;
begin
  Result.Bg := DarkBg;
  Result.Base := MakeAttr(252);
  Result.Panel := MakeAttr(252);
  Result.Border := MakeAttr(240);
  Result.Title := MakeAttr(81, [sfBold]);
  Result.Text := MakeAttr(252);
  Result.Muted := MakeAttr(244, [sfDim]);
  Result.Accent := MakeAttr(81, [sfBold]);
  Result.Warn := MakeAttr(215);
  Result.Error := MakeAttr(203, [sfBold]);
  Result.Success := MakeAttr(114, [sfBold]);
end;

function LightTheme: TTheme;
begin
  Result.Bg := LightBg;
  Result.Base := MakeAttr(235);
  Result.Panel := MakeAttr(235);
  Result.Border := MakeAttr(245);
  Result.Title := MakeAttr(25, [sfBold]);
  Result.Text := MakeAttr(235);
  Result.Muted := MakeAttr(242, [sfDim]);
  Result.Accent := MakeAttr(25, [sfBold]);
  Result.Warn := MakeAttr(130);
  Result.Error := MakeAttr(160, [sfBold]);
  Result.Success := MakeAttr(28, [sfBold]);
end;

function SelectTheme(AMode: TThemeMode; ALightDetected: Boolean): TTheme;
begin
  case AMode of
    tmDark:
      Result := DarkTheme;
    tmLight:
      Result := LightTheme;
  else
    if ALightDetected then
      Result := LightTheme
    else
      Result := DarkTheme;
  end;
end;

function ThemeModeFromString(const S: string): TThemeMode;
begin
  if SameText(S, 'dark') then
    Result := tmDark
  else if SameText(S, 'light') then
    Result := tmLight
  else
    Result := tmAuto;
end;

function ThemeModeName(AMode: TThemeMode): string;
begin
  case AMode of
    tmDark:
      Result := 'dark';
    tmLight:
      Result := 'light';
  else
    Result := 'auto';
  end;
end;

end.
