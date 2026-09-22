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

  { Rendition flags, mapped to the terminal backend's attributes. }
  TStyleFlag = (sfBold, sfDim, sfItalic, sfUnderline, sfReverse, sfBlink,
    sfStrike);
  TStyle = set of TStyleFlag;

  { A cell attribute: 256-colour foreground/background palette indices plus
    rendition flags. Indices 0..15 are the base ANSI colours, 16..231 the 6x6x6
    colour cube, and 232..255 greyscale; a theme chooses the indices. }
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
  DefaultAttr: TAttr = (Fg: 7; Bg: 0; Style: []);
  ErasedChar = '';

implementation

end.
