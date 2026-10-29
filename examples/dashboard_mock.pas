program dashboard_mock;
{ A MOCK of the Board Dashboard: the same widget, rendered over static data.

  The widget itself lives in hildi.dashboard.panel, so this program
  carries no drawing code at all - it fills the panel's globals with the shape
  of a real workspace and runs it. That is the point of the split: the mock and
  the real binary (examples/dashboard.pas) draw through one implementation, so
  a layout change cannot land in one and not the other.

  The data is static: reads no store, writes nothing. The real binary reads the
  store through the same panel.

  Keys: Tab / Shift-Tab switch zone; arrows move; 'q' or Ctrl-C quits.
  Run: make dashboard-mock }

{$mode delphi}{$H+}{$codepage utf8}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils,
  tui.base, tui.theme, tui.app, tui.surface, tui.surface.video,
  tui.input, tui.input.terminal, tui.widget,
  hildi.dashboard.panel;

var
  Theme: TTheme;
  Surface: ISurface;
  InputTerm: TInputSourceTerminal;
  Input: IInputSource;
  App: TTuiApp;
  Panel: TDashboard;
  DumpW, DumpH: Integer;

function ShouldStop: Boolean;
begin
  Result := QuitRequested or InputTerm.Terminated;
end;

begin
  QuitRequested := False;
  InitData;

  { `--dump [WxH]` renders one frame and exits; no terminal is opened, so this
    works over a pipe and in a test harness. }
  if (ParamCount >= 1) and (ParamStr(1) = '--dump') then
  begin
    DumpW := 100;
    DumpH := 34;
    if ParamCount >= 2 then
    begin
      DumpW := StrToIntDef(Copy(ParamStr(2), 1, Pos('x', ParamStr(2)) - 1), 0);
      DumpH := StrToIntDef(Copy(ParamStr(2), Pos('x', ParamStr(2)) + 1,
        Length(ParamStr(2))), 0);
      if (DumpW <= 0) or (DumpH <= 0) then
      begin
        WriteLn('usage: dashboard-mock --dump [WxH]');
        Halt(2);
      end;
    end;
    DumpFrame(DumpW, DumpH);
    Halt(0);
  end;

  Theme := DarkTheme;
  Surface := TSurfaceVideo.Create;
  InputTerm := TInputSourceTerminal.Create;
  Input := InputTerm;

  Panel := TDashboard.Create(Theme);
  App := TTuiApp.Create(Surface, Input, Panel);
  { Same wiring as the other examples: TTuiApp defaults ScreenBg to 0, so
    without this every sfScreenBg cell paints palette 0. }
  App.ScreenBg := Theme.Bg;
  try
    App.Run(@ShouldStop);
  finally
    App.Free;
    { Panel is NOT freed: TTuiApp owns its root widget. }
    Input := nil;
    Surface := nil;
  end;
end.
