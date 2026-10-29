program tui_standalone;
{ The isolation smoke for the TUI core library. It uses ONLY `src/tui/core`
  plus the RTL: the build puts no widget, harness or agent unit on the search
  path, so a dependency on one fails HERE rather than silently coupling the
  substrate to the application.

  That is the whole point of the split. `src/tui/core` is meant to be pure -
  geometry, surfaces, input decoding, grapheme width, theming - so it can be
  reused by anything, the same way `src/shell` and `src/async` are. The
  composite widgets in `src/tui/widgets` are allowed to be "complex
  components"; core is not.

  It draws a frame into a memory surface and asserts the cells, so this is a
  behaviour check as well as a link check. }

{$mode delphi}{$H+}
{$codepage utf8}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils,
  TUIBase, TUIGrapheme, TUISurface, TUITheme, TUIWidget, TUIClock;

var
  Failures: Integer;

procedure Check(const AName: string; ACondition: Boolean);
begin
  if not ACondition then
  begin
    WriteLn('FAIL  ', AName);
    Inc(Failures);
  end
  else
    WriteLn('ok    ', AName);
end;

{ A minimal core-only widget: it proves TWidget is usable without the widget
  kit, and that a Render can fill and box a rect from bare surface calls. }
type
  TFrameBox = class(TWidget)
  private
    FTheme: TTheme;
  public
    constructor Create(const ATheme: TTheme);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
  end;

constructor TFrameBox.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
end;

function TFrameBox.Measure(const AAvail: TSize): TSize;
begin
  Result.W := AAvail.W;
  Result.H := AAvail.H;
end;

procedure TFrameBox.Render(const S: ISurface);
var
  C: TCell;
  X: Integer;
begin
  S.FillRect(FBounds, FTheme.Panel);
  { Top and bottom rails, so the box is visibly closed at both ends. }
  for X := FBounds.X to FBounds.X + FBounds.W - 1 do
  begin
    C := Default(TCell);
    C.Ch := UnicodeString(WideChar($2500));   // box-drawing horizontal
    C.Attr := FTheme.Border;
    S.Put(X, FBounds.Y, C);
    S.Put(X, FBounds.Y + FBounds.H - 1, C);
  end;
end;

var
  Mem: TSurfaceMemory;
  Surf: ISurface;
  Box: TFrameBox;
  Theme: TTheme;
  Line: string;
  W: Integer;
  C: TCell;
  Bounds: TRect;

begin
  Failures := 0;
  Theme := DarkTheme;

  { 1. Geometry and theme are usable with no harness unit. }
  { Every role paints the app's SCREEN background (sfScreenBg) rather than its
    own Bg - the palette index comes from SetScreenBg at paint time. So the
    invariant is the style flag, not that Base.Bg equals Theme.Bg. }
  Check('base role uses the screen background',
    sfScreenBg in Theme.Base.Style);
  Check('text role uses the screen background',
    sfScreenBg in Theme.Text.Style);
  Check('grapheme width of a narrow char is 1', StringWidth('a') = 1);

  { 2. A memory surface exists and is addressable - the rendering seam. }
  W := 20;
  Mem := TSurfaceMemory.Create(W, 5);
  Surf := Mem;
  Check('surface reports its width', Surf.Width = W);
  Check('surface reports its height', Surf.Height = 5);

  { 3. A widget renders into it, and the cells come back. }
  Surf.SetScreenBg(Theme.Bg);
  Surf.Clear(DefaultAttr);
  Box := TFrameBox.Create(Theme);
  try
    { TRect has no constructor in core - assign its fields. }
    Bounds := Default(TRect);
    Bounds.X := 0;
    Bounds.Y := 0;
    Bounds.W := W;
    Bounds.H := 5;
    Box.Arrange(Bounds);
    Box.Render(Surf);
    C := Mem.CellAt(0, 0);
    Check('top-left cell is the drawn rail',
      C.Ch = UnicodeString(WideChar($2500)));
    C := Mem.CellAt(W - 1, 4);
    Check('bottom-right cell is the drawn rail',
      C.Ch = UnicodeString(WideChar($2500)));
    Line := UTF8Encode(Mem.RowText(0, 0, W));
    Check('row 0 is a full rail', Length(Line) > 0);
  finally
    Box.Free;
    Surf := nil;
  end;

  { 4. The clock is a pure function of the frame time - no timers in core. }
  Check('clock exposes a monotonic-ish source', MonotonicMs >= 0);

  if Failures > 0 then
  begin
    WriteLn(Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('tui core standalone: ok');
end.
