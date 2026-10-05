program tui_agent;
{ The full-screen agent harness as a headless-session client: the agent loop
  lives in a detached runtime process, and the TUI attaches to it as the driver.
  Type a prompt and press Enter. Ctrl-C (or Ctrl-D) quits; the runtime keeps the
  turn running, and another client (a CLI `--attach`, a second TUI) sees the same
  session.

  Config comes from the environment/.env like the CLI; flags mirror it:
    --workspace PATH  --session ID  --continue  --model M  --endpoint URL
    --theme=dark|light

  Run with `make tui-agent`. }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  Classes, SysUtils,
  hildegard.helper.cli,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.surface.video,
  hildegard.helper.tui.input.terminal, hildegard.helper.tui.theme,
  hildegard.helper.harness.session, hildegard.helper.harness.driver,
  hildegard.helper.harness.app, hildegard.helper.session.protocol,
  hildegard.helper.session.runtime;

var
  RawArgs: TStringList;
  Args: array of string;
  Opts: TCLIOptions;
  I: Integer;
  ThemeArg: string;
  ThemeMode: TThemeMode;
  Light: Boolean;
  StorePath: string;
  Cfg: THarnessSessionConfig;
  Session: THarnessSession;
  Err: string;
  ClientCfg: TSessionClientConfig;
  Driver: ISessionDriver;
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
  { When the driver spawns a runtime it re-executes this binary with the runtime
    argv; run the runtime instead of the TUI. }
  if (ParamCount >= 1) and (ParamStr(1) = '--session-runtime') then
  begin
    SetLength(Args, ParamCount);
    for I := 0 to ParamCount - 1 do
      Args[I] := ParamStr(I + 1);
    Halt(RunSessionRuntime(Args));
  end;

  RawArgs := TStringList.Create;
  try
    for I := 1 to ParamCount do
      RawArgs.Add(ParamStr(I));
    ThemeArg := '';
    SetLength(Args, 0);
    for I := 0 to RawArgs.Count - 1 do
    begin
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

  StorePath := GetEnvironmentVariable('HILDEGARD_STORE_PATH');
  if StorePath = '' then
    StorePath := IncludeTrailingPathDelimiter(GetUserDir) +
      '.hildegard-helper' + PathDelim + 'store.db';

  { The TUI process only needs the store/workspace/session handle; the runtime
    owns the loop. }
  Cfg := Default(THarnessSessionConfig);
  Cfg.WorkspacePath := Opts.Workspace;
  Cfg.StorePath := StorePath;
  Cfg.SessionId := Opts.Session;
  Cfg.Resume := Opts.ContinueSession;
  Cfg.Model := Opts.Model;
  Cfg.Endpoint := Opts.Endpoint;
  Cfg.NoLoop := True;

  Session := THarnessSession.Open(Cfg, Err);
  if Session = nil then
  begin
    WriteLn('error: ', Err);
    Halt(1);
  end;

  { Connect to (or spawn) the session's runtime as the driver. }
  ClientCfg := Default(TSessionClientConfig);
  ClientCfg.SessionId := Session.SessionId;
  ClientCfg.WorkspacePath := Session.WorkspaceRoot;
  ClientCfg.StorePath := StorePath;
  ClientCfg.Role := srDrive;
  ClientCfg.FromSeq := 0;
  ClientCfg.Spawn := True;
  ClientCfg.SpawnTimeoutMs := 5000;
  ClientCfg.RuntimeCommand := ExpandFileName(ParamStr(0));
  Driver := RemoteDriver(ClientCfg, Err);
  if Driver = nil then
  begin
    WriteLn('error: ', Err);
    Session.Free;
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
  App := THarnessApp.Create(Surface, Input, Session, Driver, ThemeMode, Light);
  try
    { Clock-driven: waits on input, drains the driver's queue each iteration,
      and renders on the frame cadence only while a turn is in flight. }
    App.Run(@ShouldStop);
  finally
    App.Free;
    Driver := nil;
    Input := nil;
    Surface := nil;
    Session.Free;
  end;
end.
