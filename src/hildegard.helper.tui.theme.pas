unit hildegard.helper.tui.theme;
{ Pure helpers for deciding whether the terminal has a light or dark background.

  No terminal dependency: callers feed a response (an OSC 11 reply) or the
  COLORFGBG environment value and get a theme kind back, so the mapping is unit
  tested. The tty query itself lives in the caller. }

{$mode delphi}{$H+}

interface

type
  TThemeKind = (thDark, thLight);

{ Parse an OSC 11 background reply, e.g. "...rgb:1e1e/1e1e/1e1e..." or
  "...rgb:#1e1e1e...", returning 8-bit components. }
function ParseOSC11(const AResponse: string; out AR, AG, AB: Byte): Boolean;

{ Perceived luminance (ITU-R BT.601). }
function ColorIsLight(AR, AG, AB: Byte): Boolean;

{ Parse the COLORFGBG value ("fg;bg"), where bg >= 7 means a light background. }
function ParseColorFGBG(const AValue: string; out AKind: TThemeKind): Boolean;

implementation

uses
  SysUtils;

function HexComponent(const S: string): Byte;
var
  N, L: Integer;
begin
  L := Length(S);
  if L = 0 then
    Exit(0);
  N := StrToIntDef('$' + S, 0);
  case L of
    1:
      N := N * 17;
    2:
      ;
    3:
      N := N shr 4;
  else
    N := N shr ((L - 2) * 4);
  end;
  if N > 255 then
    N := 255;
  Result := Byte(N);
end;

function ParseOSC11(const AResponse: string; out AR, AG, AB: Byte): Boolean;
var
  P, Q, I: Integer;
  Body, Comp: string;
  Parts: array[0..2] of Byte;
  Count: Integer;
begin
  AR := 0;
  AG := 0;
  AB := 0;
  Result := False;
  P := Pos('rgb:', AResponse);
  if P = 0 then
    Exit;
  Body := Copy(AResponse, P + 4, MaxInt);
  { Accept a leading '#' (some terminals reply rgb:#rrggbb). }
  if (Body <> '') and (Body[1] = '#') then
  begin
    if Length(Body) < 7 then
      Exit;
    AR := HexComponent(Copy(Body, 2, 2));
    AG := HexComponent(Copy(Body, 4, 2));
    AB := HexComponent(Copy(Body, 6, 2));
    Exit(True);
  end;
  Count := 0;
  I := 1;
  while (I <= Length(Body)) and (Count < 3) do
  begin
    Q := I;
    while (Q <= Length(Body)) and (Body[Q] <> '/') and
      (((Body[Q] >= '0') and (Body[Q] <= '9')) or
      ((Body[Q] >= 'a') and (Body[Q] <= 'f')) or
      ((Body[Q] >= 'A') and (Body[Q] <= 'F'))) do
      Inc(Q);
    Comp := Copy(Body, I, Q - I);
    if Comp = '' then
      Break;
    Parts[Count] := HexComponent(Comp);
    Inc(Count);
    I := Q + 1;
  end;
  if Count <> 3 then
    Exit;
  AR := Parts[0];
  AG := Parts[1];
  AB := Parts[2];
  Result := True;
end;

function ColorIsLight(AR, AG, AB: Byte): Boolean;
begin
  Result := (299 * Integer(AR) + 587 * Integer(AG) + 114 * Integer(AB)) div
    1000 >= 128;
end;

function ParseColorFGBG(const AValue: string; out AKind: TThemeKind): Boolean;
var
  P, Bg: Integer;
begin
  AKind := thDark;
  Result := False;
  P := LastDelimiter(';', AValue);
  if P = 0 then
    Exit;
  Bg := StrToIntDef(Copy(AValue, P + 1, MaxInt), -1);
  if Bg < 0 then
    Exit;
  if Bg >= 7 then
    AKind := thLight
  else
    AKind := thDark;
  Result := True;
end;

end.
