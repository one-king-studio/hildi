program tui_widgets_standalone;
{ The isolation smoke for the TUI WIDGET tier.

  It uses ONLY src/tui/** plus the RTL and (by the tier rule) src/markdown. No
  Hildi application unit is on the search path, so a widget that reaches into
  HildiSession, HildiApproval, HildiFuzzy or HildiHarnessSubagent fails HERE
  rather than silently coupling a reusable component to the harness.

  That is the whole point of the tiering. `src/tui/core` is pure substrate and
  is proven by `tui-standalone`. `src/tui/widgets` is allowed to be complex -
  but only complex TUI, never application logic, or it cannot be exported.

  It draws into a memory surface and asserts the cells, so this is a behaviour
  check as well as a link check, the same shape as tui_standalone.pas. }

{$mode delphi}{$H+}
{$codepage utf8}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils,
  TUIBase, TUIInput, TUISurface, TUITheme, TUIWidget,
  { EVERY library unit, listed deliberately: the gate must prove the whole tier
    is exportable, so listing only what this program uses would leave the rest
    unchecked - and an unlisted unit is an unproven one. The eight Hildi domain
    widgets (chat, compose, the dialogs, the agent list) are NOT here: they live
    in src/ beside the harness, because they are Hildi's, not the library's.

    The three markdown widgets are conditional. Built WITHOUT the define they
    are absent from the program AND from the search path, which is what proves
    the other 17 widgets need no markdown at all. Built WITH it, they get a gate
    of their own - otherwise taking them out of this list would leave them
    unproven by anything. }
  TUIWidgetsText, TUIWidgetsPanel, TUIWidgetsButton, TUIWidgetsActions,
  TUIWidgetsDiffviewer, TUIWidgetsEdit, TUIWidgetsFocus,
  TUIWidgetsList, TUIWidgetsModal,
  TUIWidgetsPalette, TUIWidgetsProgress, TUIWidgetsPrompt, TUIWidgetsScroll,
  TUIWidgetsSpinner
  {$ifdef TUI_WITH_MARKDOWN}
  , TUIWidgetsMarkdownView, TUIWidgetsMdtheme, TUIWidgetsFileviewer
  {$endif}
  ;

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

var
  Theme: TTheme;
  Mem: TSurfaceMemory;
  Surf: ISurface;
  Panel: TPanel;
  Block: TTextBlock;
  Spans: array of TSpan;
  Style: TBoxStyle;
  Bounds: TRect;
  Line: string;

begin
  Failures := 0;
  Theme := DarkTheme;

  { 1. The theme is usable with no application unit on the path. }
  Check('theme base uses the screen background',
    sfScreenBg in Theme.Base.Style);

  { 2. A composite panel holding a text leaf renders, through the widget tier
       only, with no harness type involved. }
  Mem := TSurfaceMemory.Create(30, 5);
  Surf := Mem;
  Surf.SetScreenBg(Theme.Bg);
  Surf.Clear(DefaultAttr);

  SetLength(Spans, 1);
  Spans[0].Text := 'hello tier';
  Spans[0].Attr := Theme.Text;
  Block := TTextBlock.Create(Spans, wmWord);

  Style := Default(TBoxStyle);
  Style.Border := True;
  Style.Padding := 1;
  Panel := TPanel.Create(Block, Theme, Style);
  try
    Bounds := Default(TRect);
    Bounds.X := 0;
    Bounds.Y := 0;
    Bounds.W := 30;
    Bounds.H := 5;
    Panel.Arrange(Bounds);
    Panel.Render(Surf);

    Check('panel reports its arranged width', Panel.Bounds.W = 30);
    Line := UTF8Encode(Mem.RowText(0, 0, 30));
    Check('panel drew a top border', Length(Line) > 0);
    Check('the leaf text reached a row inside the panel',
      (Pos('hello', UTF8Encode(Mem.RowText(1, 0, 30))) > 0) or
      (Pos('hello', UTF8Encode(Mem.RowText(2, 0, 30))) > 0));
    Check('nothing was drawn outside the panel bounds',
      Pos('hello', UTF8Encode(Mem.RowText(4, 0, 30))) = 0);
  finally
    Panel.Free;   { owns the block }
    Surf := nil;
  end;

  if Failures > 0 then
  begin
    WriteLn(Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('tui widgets standalone: ok');
end.
