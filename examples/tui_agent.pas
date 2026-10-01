program tui_agent;
{ The full-screen agent harness: a conversation pane, streaming assistant text,
  tool-activity lines, an approval modal, and SQLite-backed session persistence.

  Type a prompt and press Enter. The agent runs off the UI thread, so the view
  stays responsive. Ctrl-C (or Ctrl-D) quits; a turn in flight is cancelled and
  the terminal is restored.

  Config comes from the environment/.env like the CLI; flags mirror it:
    --workspace PATH  --session ID  --continue  --model M  --endpoint URL
    --no-store        run in memory (no persistence, session-only approvals)

  Run with `make tui-agent`. }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  Classes, SysUtils,
  hildegard.helper.cli,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.surface.video,
  hildegard.helper.tui.input.terminal, hildegard.helper.tui.theme,
  hildegard.helper.harness.session, hildegard.helper.harness.app;

var
  RawArgs: TStringList;
  Args: array of string;
  Opts: TCLIOptions;
  I: Integer;
  NoStore: Boolean;
  ThemeArg: string;
  ThemeMode: TThemeMode;
  Light: Boolean;
  StorePath: string;
  Cfg: THarnessSessionConfig;
  Session: THarnessSession;
  Err: string;
  Surface: ISurface;
  InputTerm: TInputSourceTerminal;
  Input: IInputSource;
  App: THarnessApp;

{ End the run loop on SIGTERM/SIGINT/SIGHUP so the terminal is restored. }
function ShouldStop: Boolean;
begin
  Result := InputTerm.Terminated;
end;

begin
  RawArgs := TStringList.Create;
  try
    for I := 1 to ParamCount do
      RawArgs.Add(ParamStr(I));
    NoStore := RawArgs.IndexOf('--no-store') >= 0;
    ThemeArg := '';
    SetLength(Args, 0);
    for I := 0 to RawArgs.Count - 1 do
    begin
      if RawArgs[I] = '--no-store' then
        Continue;
      if Copy(RawArgs[I], 1, 8) = '--theme=' then
      begin
        ThemeArg := Copy(RawArgs[I], 9, MaxInt);
        Continue;
      end;
      SetLength(Args, Length(Args) + 1);
      Args[High(Args)] := RawArgs[I];
    end;
    try
      Opts := ParseCLIOptions(Args);
    except
      on E: ECLIError do
      begin
        WriteLn('error: ', E.Message);
        WriteLn;
        WriteLn(UsageText);
        Halt(2);
      end;
    end;
  finally
    RawArgs.Free;
  end;

  if Opts.Help then
  begin
    WriteLn(UsageText);
    Halt(0);
  end;

  StorePath := '';
  if not NoStore then
  begin
    StorePath := GetEnvironmentVariable('HILDEGARD_STORE_PATH');
    if StorePath = '' then
      StorePath := IncludeTrailingPathDelimiter(GetUserDir) +
        '.hildegard-helper' + PathDelim + 'store.db';
  end;

  Cfg := Default(THarnessSessionConfig);
  Cfg.WorkspacePath := Opts.Workspace;
  Cfg.StorePath := StorePath;
  Cfg.SessionId := Opts.Session;
  Cfg.Resume := Opts.ContinueSession;
  Cfg.Model := Opts.Model;
  Cfg.Endpoint := Opts.Endpoint;

  Session := THarnessSession.Open(Cfg, Err);
  if Session = nil then
  begin
    WriteLn('error: ', Err);
    Halt(1);
  end;

  { Create the surface before the input source; destroy the input before the
    surface, so each restores the termios it saved and the tty ends cooked. }
  Surface := TSurfaceVideo.Create;
  InputTerm := TInputSourceTerminal.Create;
  Input := InputTerm;

  { Theme: forced by --theme, else detected from the terminal (OSC 11). }
  ThemeMode := ThemeModeFromString(ThemeArg);
  Light := (ThemeMode = tmAuto) and InputTerm.DetectLightBackground;
  App := THarnessApp.Create(Surface, Input, Session, ThemeMode, Light);
  try
    { Clock-driven: waits on input, drains the turn queue each iteration, and
      renders on the frame cadence only while a turn is in flight. }
    App.Run(@ShouldStop);
  finally
    App.Free;
    Input := nil;
    Surface := nil;
    Session.Free;
  end;
end.
