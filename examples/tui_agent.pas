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
  Classes, Contnrs, SysUtils,
  hildegard.helper.cli,
  tui.base, tui.input,
  tui.surface, tui.surface.video,
  tui.input.terminal, tui.theme,
  hildegard.helper.harness.view, hildegard.helper.harness.driver,
  hildegard.helper.harness.app, hildegard.helper.session.protocol,
  hildegard.helper.session.client;

type
  { The lazy-connect hook: on the first prompt, create the session and spawn its
    runtime, then Attach (or FailConnect). Holds the view and app so the connect
    is one method of object. Also opens a session on demand (Switch) when the
    operator activates a row in /sessions; those opened views are owned here and
    freed at shutdown. }
  TLauncher = class
  private
    FSession: TSessionView;
    FApp: THarnessApp;
    FStorePath: string;
    FWorkspaceRoot: string;
    FModel: string;
    { The views opened by Switch, kept alive for the app's lifetime (the app
      holds a reference to the active one). }
    FOpened: TObjectList;
  public
    constructor Create(ASession: TSessionView; AApp: THarnessApp;
      const AStorePath: string);
    destructor Destroy; override;
    procedure Connect;
    { Open another session for the app: a fresh view and a spawned runtime
      driver. False + AError on failure (the view is released). }
    function Switch(const ASessionId: string; out ASession: TSessionView;
      out ADriver: ISessionDriver; out AError: string): Boolean;
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
  FOpened := TObjectList.Create(True);
  if ASession <> nil then
  begin
    FWorkspaceRoot := ASession.WorkspaceRoot;
    FModel := ASession.Model;
  end;
end;

destructor TLauncher.Destroy;
begin
  FOpened.Free;
  inherited Destroy;
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

function TLauncher.Switch(const ASessionId: string; out ASession: TSessionView;
  out ADriver: ISessionDriver; out AError: string): Boolean;
var
  Cfg: THarnessSessionConfig;
  View: TSessionView;
  ClientCfg: TSessionClientConfig;
begin
  Result := False;
  ASession := nil;
  ADriver := nil;
  AError := '';
  { Open a fresh view for the target (the workspace is already known), then spawn
    its runtime. The view is owned here and kept alive for the app's lifetime. }
  Cfg := Default(THarnessSessionConfig);
  Cfg.WorkspacePath := FWorkspaceRoot;
  Cfg.StorePath := FStorePath;
  Cfg.SessionId := ASessionId;
  Cfg.Resume := True;
  Cfg.Model := FModel;
  View := TSessionView.Open(Cfg, AError);
  if View = nil then
    Exit;
  ClientCfg := Default(TSessionClientConfig);
  ClientCfg.SessionId := ASessionId;
  ClientCfg.WorkspacePath := FWorkspaceRoot;
  ClientCfg.StorePath := FStorePath;
  ClientCfg.Role := srDrive;
  ClientCfg.FromSeq := 0;
  ClientCfg.Spawn := True;
  ClientCfg.SpawnTimeoutMs := 5000;
  ClientCfg.RuntimeCommand := ResolveRuntimeBinary(
    GetEnvironmentVariable('HILDEGARD_RUNTIME_BIN'), ParamStr(0));
  ADriver := RemoteDriver(ClientCfg, AError);
  if ADriver = nil then
  begin
    View.Free;
    Exit;
  end;
  FOpened.Add(View);
  ASession := View;
  Result := True;
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
    { The /sessions modal can open another session: the launcher owns the view
      and spawns the runtime. }
    App.OnSwitchSession := Launcher.Switch;
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
    { Free the app before the launcher: the app holds references to the launcher's
      opened views (the active one), so the views must outlive it. }
    App.Free;
    Launcher.Free;
    Input := nil;
    Surface := nil;
    Session.Free;
  end;
end.
