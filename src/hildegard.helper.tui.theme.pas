unit hildegard.helper.tui.theme;
{ Named colour roles for the widget kit, so widgets do not hard-code attributes.
  Indices are 256-colour palette entries (see TAttr). }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base;

type
  TTheme = record
    Base: TAttr;      // screen background
    Panel: TAttr;     // panel / box background
    Border: TAttr;    // box-drawing frame
    Title: TAttr;     // panel title
    Text: TAttr;      // primary text
    Muted: TAttr;     // secondary text
    Accent: TAttr;    // focus / selection
    Error: TAttr;
    Success: TAttr;
  end;

function DarkTheme: TTheme;
function LightTheme: TTheme;

implementation

function MakeAttr(AFg, ABg: Byte; AStyle: TStyle = []): TAttr;
begin
  Result := DefaultAttr;
  Result.Fg := AFg;
  Result.Bg := ABg;
  Result.Style := AStyle;
end;

function DarkTheme: TTheme;
begin
  Result.Base := MakeAttr(252, 234);
  Result.Panel := MakeAttr(252, 236);
  Result.Border := MakeAttr(240, 236);
  Result.Title := MakeAttr(81, 236, [sfBold]);
  Result.Text := MakeAttr(252, 0);
  Result.Muted := MakeAttr(244, 0, [sfDim]);
  Result.Accent := MakeAttr(81, 0, [sfBold]);
  Result.Error := MakeAttr(203, 0, [sfBold]);
  Result.Success := MakeAttr(114, 0, [sfBold]);
end;

function LightTheme: TTheme;
begin
  Result.Base := MakeAttr(235, 255);
  Result.Panel := MakeAttr(235, 254);
  Result.Border := MakeAttr(245, 254);
  Result.Title := MakeAttr(25, 254, [sfBold]);
  Result.Text := MakeAttr(235, 0);
  Result.Muted := MakeAttr(244, 0, [sfDim]);
  Result.Accent := MakeAttr(25, 0, [sfBold]);
  Result.Error := MakeAttr(160, 0, [sfBold]);
  Result.Success := MakeAttr(28, 0, [sfBold]);
end;

end.
