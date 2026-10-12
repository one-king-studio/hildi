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
  hildegard.helper.harness.view, hildegard.helper.harness.driver,
  hildegard.helper.harness.app, hildegard.helper.session.protocol,
  hildegard.helper.session.client;

type
  { The lazy-connect hook: on the first prompt, create the session and spawn its
    runtime, then Attach (or FailConnect). Holds the view and app so the connect
    is one method of object. }
  TLauncher = class
  private
    FSession: TSessionView;
    FApp: THarnessApp;
    FStorePath: string;
  public
    constructor Create(ASession: TSessionView; AApp: THarnessApp;
      const AStorePath: string);
    procedure Connect;
  end;

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
  Session: TSessionView;
  Err: string;
  Surface: ISurface;
  InputTerm: TInputSourceTerminal;
  Input: IInputSource;
  App: THarnessApp;
  Launcher: TLauncher;

constructor TLauncher.Create(ASession: TSessionView; AApp: THarnessApp;
  const AStorePath: string);
begin
  inherited Create;
  FSession := ASession;
  FApp := AApp;
  FStorePath := AStorePath;
end;

procedure TLauncher.Connect;
var
  Err: string;
  ClientCfg: TSessionClientConfig;
  Driver: ISessionDriver;
begin
  { Create the session now (the lazy path defers it), then spawn the runtime. }
  if not FSession.EnsureSession(Err) then
  begin
    FApp.FailConnect('could not create session: ' + Err);
    Exit;
  end;
  ClientCfg := Default(TSessionClientConfig);
  ClientCfg.SessionId := FSession.SessionId;
  ClientCfg.WorkspacePath := FSession.WorkspaceRoot;
  ClientCfg.StorePath := FStorePath;
  ClientCfg.Role := srDrive;
  ClientCfg.FromSeq := 0;
  ClientCfg.Spawn := True;
  ClientCfg.SpawnTimeoutMs := 5000;
  ClientCfg.RuntimeCommand := ResolveRuntimeBinary(
    GetEnvironmentVariable('HILDEGARD_RUNTIME_BIN'), ParamStr(0));
  Driver := RemoteDriver(ClientCfg, Err);
  if Driver = nil then
  begin
    FApp.FailConnect(Err);
    Exit;
  end;
  FApp.Attach(FSession, Driver);
end;

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
    owns the loop. With no explicit session or --continue, defer creating one
    until the operator sends the first prompt (so a launch has no side effect). }
  Cfg := Default(THarnessSessionConfig);
  Cfg.WorkspacePath := Opts.Workspace;
  Cfg.StorePath := StorePath;
  Cfg.SessionId := Opts.Session;
  Cfg.Resume := Opts.ContinueSession;
  Cfg.Model := Opts.Model;
  Cfg.Endpoint := Opts.Endpoint;
  Cfg.LazySession := (Opts.Session = '') and (not Opts.ContinueSession);

  Session := TSessionView.Open(Cfg, Err);
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

  { Paint first: build the app with no driver. It is idle (no session) or
    connecting (a named/resumed session); the driver attaches after. }
  App := THarnessApp.Create(Surface, Input, Session, nil, ThemeMode, Light);
  Launcher := TLauncher.Create(Session, App, StorePath);
  try
    if Session.HasSession then
      { A named or resumed session: connect now (the first frame is already up). }
      Launcher.Connect
    else
      { No session yet: connect lazily on the first prompt. }
      App.OnNeedConnect := Launcher.Connect;
    { Clock-driven: waits on input, drains the driver's queue each iteration,
      and renders on the frame cadence only while a turn is in flight. }
    App.Run(@ShouldStop);
  finally
    Launcher.Free;
    App.Free;
    Input := nil;
    Surface := nil;
    Session.Free;
  end;
end.
