unit hildegard.helper.tui.base;
{ Core value types for the TUI toolkit.

  Deliberately free of any terminal, video, or I/O dependency: the rest of the
  toolkit and its tests compile against these types alone. TRect is the
  toolkit's own X/Y/W/H rectangle; it shadows the RTL's Left/Top/Right/Bottom
  TRect so rect arithmetic stays unambiguous. }

{$mode delphi}{$H+}

interface

type
  { Size in character cells and rows. }
  TSize = record
    W, H: Integer;
  end;

  { Rectangle in character cells: X, Y is the top-left and W, H the extent. }
  TRect = record
    X, Y, W, H: Integer;
  end;

  { Rendition flags, mapped to the terminal backend's attributes. sfScreenBg
    means "paint the app's screen background" (a palette index the app sets via
    TTuiApp.ScreenBg), so a widget never has to know the background colour and
    text never sits on a mismatched box. }
  TStyleFlag = (sfBold, sfDim, sfItalic, sfUnderline, sfReverse, sfBlink,
    sfStrike, sfScreenBg);
  TStyle = set of TStyleFlag;

  { A cell attribute: 256-colour foreground/background palette indices plus
    rendition flags. Indices 0..15 are the base ANSI colours, 16..231 the 6x6x6
    colour cube, and 232..255 greyscale; a theme chooses the indices. When
    sfScreenBg is set the background index is ignored and the app's screen
    background is painted instead. }
  TAttr = record
    Fg, Bg: Byte;
    Style: TStyle;
  end;

  { A screen cell. Ch is an extended grapheme cluster; '' means erased/blank. }
  TCell = record
    Ch: UnicodeString;
    Attr: TAttr;
  end;

const
  DefaultAttr: TAttr = (Fg: 7; Bg: 0; Style: [sfScreenBg]);
  ErasedChar = '';

{ Map a 256-colour palette index to a darker one, for a modal's dimmed
  background. Base colours drop to black, the cube steps each channel down, and
  the greyscale ramp drops about a third. }
function DimPaletteIndex(AIndex: Byte): Byte;

implementation

function DimPaletteIndex(AIndex: Byte): Byte;
var
  R, G, B: Integer;
begin
  if AIndex < 8 then
    Result := 0
  else if AIndex < 16 then
    Result := AIndex - 8
  else if AIndex < 232 then
  begin
    R := (AIndex - 16) div 36;
    G := ((AIndex - 16) mod 36) div 6;
    B := (AIndex - 16) mod 6;
    if R > 0 then
      Dec(R);
    if G > 0 then
      Dec(G);
    if B > 0 then
      Dec(B);
    Result := 16 + R * 36 + G * 6 + B;
  end
  else
  begin
    if AIndex > 232 + 8 then
      Result := AIndex - 8
    else
      Result := 232;
  end;
end;

end.
