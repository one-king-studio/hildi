program tui_layout_demo;
{ A layout exploration for a personal coding-agent harness.

  Two main columns - file explorer + editor, and the chat column - shown only
  when the terminal is wider than 180 columns. The two halves are a 50/50 split;
  the left half is a fixed 20-column file explorer plus a filling editor. Narrower
  terminals collapse to the chat column alone.

  The chat column is a chat stream with an optional side panel (Ctrl-B) and a
  persistent bottom panel, under the chat stream only, for the chat input and
  status information.

  Keys: Ctrl-C / Ctrl-D quit; Ctrl-B toggles the side panel; Enter sends a
  message into the chat.

  Theme: --theme=dark|light|auto (or HILDEGARD_THEME); auto detects the
  terminal's own background. We always paint our own background.

  Run: make layout-demo }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.app,
  hildegard.helper.tui.surface.video, hildegard.helper.tui.input.terminal,
  hildegard.helper.tui.theme, hildegard.helper.tui.panel,
  hildegard.helper.tui.list, hildegard.helper.tui.prompt;

const
  { Two columns appear only when the terminal is wider than this. }
  WideThreshold = 180;
  { The file explorer is a fixed 20 columns; the editor fills the rest. }
  SidebarWidth = 20;
  { The chat side panel is a fixed width; the chat keeps at least this much. }
  SideWidth = 30;
  MinChatWidth = 40;
  { The persistent bottom panel (prompt + status), including its border. }
  InputHeight = 6;

var
  QuitRequested: Boolean = False;

type
  { Wraps the root so Ctrl-C/Ctrl-D quit. Extends TSingleChild so the protocol
    (including the clock hooks) forwards for free. Plain keys are left to the
    chat input. }
  TQuitShell = class(TSingleChild)
  public
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  { Appends submitted chat lines to the chat stream. }
  TDemo = class
  private
    FChatText: TTextBlock;
    FAttr: TAttr;
    FLog: string;
  public
    constructor Create(AChatText: TTextBlock; const AAttr: TAttr;
      const AInitial: string);
    procedure OnSubmit(const AText: string);
  end;

  { The responsive layout. It owns five panels and, on every Arrange, decides
    the shape from the available width:
      wide   -> [ files | editor ] | [ chat (+ side panel) / input ]
      narrow -> [ chat (+ side panel) / input ]
    The chat column always has the persistent bottom input panel. }
  TResponsiveLayout = class(TWidget)
  private
    FFiles: TPanel;
    FEditor: TPanel;
    FChat: TPanel;
    FSide: TPanel;
    FInput: TPanel;
    FShowSide: Boolean;
    procedure PlaceChatColumn(const R: TRect);
    procedure Place(const ABounds: TRect);
  public
    constructor Create(AFiles, AEditor, AChat, ASide, AInput: TPanel);
    destructor Destroy; override;
    procedure ToggleSide;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
  end;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

{ TQuitShell }

function TQuitShell.HandleEvent(const E: TInputEvent): Boolean;
begin
  if (E.Kind = ikKey) and (E.Key.Kind = kkChar) and (moCtrl in E.Key.Mods) and
    ((E.Key.Ch = 'c') or (E.Key.Ch = 'd')) then
  begin
    QuitRequested := True;
    Exit(True);
  end;
  Result := inherited HandleEvent(E);
end;

{ TDemo }

constructor TDemo.Create(AChatText: TTextBlock; const AAttr: TAttr;
  const AInitial: string);
begin
  inherited Create;
  FChatText := AChatText;
  FAttr := AAttr;
  FLog := AInitial;
  FChatText.SetText(FLog, FAttr);
end;

procedure TDemo.OnSubmit(const AText: string);
begin
  FLog := FLog + '> ' + AText + #10;
  FChatText.SetText(FLog, FAttr);
end;

{ TResponsiveLayout }

constructor TResponsiveLayout.Create(AFiles, AEditor, AChat, ASide,
  AInput: TPanel);
begin
  inherited Create;
  FFiles := AFiles;
  FEditor := AEditor;
  FChat := AChat;
  FSide := ASide;
  FInput := AInput;
  FShowSide := False;
end;

destructor TResponsiveLayout.Destroy;
begin
  FFiles.Free;
  FEditor.Free;
  FChat.Free;
  FSide.Free;
  FInput.Free;
  inherited Destroy;
end;

procedure TResponsiveLayout.ToggleSide;
begin
  FShowSide := not FShowSide;
  { Re-lay out immediately; the app repaints on the input that got us here. }
  if FBounds.W > 0 then
    Arrange(FBounds);
end;

function TResponsiveLayout.Measure(const AAvail: TSize): TSize;
begin
  Result := AAvail;
end;

procedure TResponsiveLayout.PlaceChatColumn(const R: TRect);
var
  InH, SideW, ChatW: Integer;
  SideR, ChatCol, ChatR, InputR: TRect;
begin
  InH := InputHeight;
  if InH > R.H - 2 then
    InH := R.H div 3;

  { The side panel spans the full height of the chat column; the chat stream and
    the input panel stack in the remaining width. }
  FSide.Visible := FShowSide and (R.W >= MinChatWidth + SideWidth);
  if FSide.Visible then
  begin
    SideW := SideWidth;
    ChatW := R.W - SideW;
    ChatCol := Rc(R.X, R.Y, ChatW, R.H);
    SideR := Rc(R.X + ChatW, R.Y, SideW, R.H);
  end
  else
  begin
    ChatCol := R;
    SideR := Rc(R.X, R.Y, 0, 0);
  end;

  ChatR := Rc(ChatCol.X, ChatCol.Y, ChatCol.W, ChatCol.H - InH);
  InputR := Rc(ChatCol.X, ChatCol.Y + ChatCol.H - InH, ChatCol.W, InH);

  FChat.Arrange(ChatR);
  FInput.Arrange(InputR);
  FSide.Arrange(SideR);
end;

procedure TResponsiveLayout.Place(const ABounds: TRect);
var
  Wide: Boolean;
  LeftW, RightW: Integer;
  Mode: string;
  St: TBoxStyle;
begin
  Wide := ABounds.W > WideThreshold;
  FFiles.Visible := Wide;
  FEditor.Visible := Wide;

  if Wide then
  begin
    LeftW := ABounds.W div 2;
    RightW := ABounds.W - LeftW;
    FFiles.Arrange(Rc(ABounds.X, ABounds.Y, SidebarWidth, ABounds.H));
    FEditor.Arrange(Rc(ABounds.X + SidebarWidth, ABounds.Y,
      LeftW - SidebarWidth, ABounds.H));
    PlaceChatColumn(Rc(ABounds.X + LeftW, ABounds.Y, RightW, ABounds.H));
    Mode := 'wide >180: files | editor || chat';
  end
  else
  begin
    FFiles.Arrange(Rc(ABounds.X, ABounds.Y, 0, 0));
    FEditor.Arrange(Rc(ABounds.X, ABounds.Y, 0, 0));
    PlaceChatColumn(ABounds);
    Mode := 'narrow <=180: chat only';
  end;

  St := FChat.Style;
  St.Title := 'Chat  ' + IntToStr(ABounds.W) + 'x' + IntToStr(ABounds.H) +
    '  ' + Mode;
  FChat.Style := St;
end;

procedure TResponsiveLayout.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  Place(ABounds);
end;

procedure TResponsiveLayout.Render(const S: ISurface);
begin
  S.PushClip(FBounds);
  if FFiles.Visible then
    FFiles.Render(S);
  if FEditor.Visible then
    FEditor.Render(S);
  if FChat.Visible then
    FChat.Render(S);
  if FSide.Visible then
    FSide.Render(S);
  if FInput.Visible then
    FInput.Render(S);
  S.PopClip;
end;

function TResponsiveLayout.HandleEvent(const E: TInputEvent): Boolean;
begin
  if (E.Kind = ikKey) and (E.Key.Kind = kkChar) and (moCtrl in E.Key.Mods) and
    (E.Key.Ch = 'b') then
  begin
    ToggleSide;
    Exit(True);
  end;
  if FFiles.Visible and FFiles.HandleEvent(E) then
    Exit(True);
  if FEditor.Visible and FEditor.HandleEvent(E) then
    Exit(True);
  if FChat.Visible and FChat.HandleEvent(E) then
    Exit(True);
  if FSide.Visible and FSide.HandleEvent(E) then
    Exit(True);
  if FInput.Visible and FInput.HandleEvent(E) then
    Exit(True);
  Result := False;
end;

function TResponsiveLayout.Advance(const ANowMs: Int64): Boolean;
begin
  Result := False;
  if FFiles.Visible and FFiles.Advance(ANowMs) then
    Result := True;
  if FEditor.Visible and FEditor.Advance(ANowMs) then
    Result := True;
  if FChat.Visible and FChat.Advance(ANowMs) then
    Result := True;
  if FSide.Visible and FSide.Advance(ANowMs) then
    Result := True;
  if FInput.Visible and FInput.Advance(ANowMs) then
    Result := True;
end;

function TResponsiveLayout.Animating: Boolean;
begin
  Result := (FFiles.Visible and FFiles.Animating) or
    (FEditor.Visible and FEditor.Animating) or
    (FChat.Visible and FChat.Animating) or
    (FSide.Visible and FSide.Animating) or
    (FInput.Visible and FInput.Animating);
end;

var
  Surface: ISurface;
  InputTerm: TInputSourceTerminal;
  Input: IInputSource;
  Theme: TTheme;
  Files: TListView;
  EditorText, ChatText, SideText, InfoText: TTextBlock;
  Prompt: TPromptLine;
  InputStack: TContainer;
  FilesPanel, EditorPanel, ChatPanel, SidePanel, InputPanel: TPanel;
  Layout: TResponsiveLayout;
  Demo: TDemo;
  App: TTuiApp;
  Style: TBoxStyle;
  Mode: TThemeMode;
  Light: Boolean;

function RequestedThemeMode: TThemeMode;
var
  I: Integer;
  S: string;
begin
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Copy(S, 1, 8) = '--theme=' then
      Exit(ThemeModeFromString(Copy(S, 9, MaxInt)));
    if S = '--dark' then
      Exit(tmDark);
    if S = '--light' then
      Exit(tmLight);
  end;
  Result := ThemeModeFromString(GetEnvironmentVariable('HILDEGARD_THEME'));
end;

function ShouldStop: Boolean;
begin
  Result := QuitRequested or InputTerm.Terminated;
end;

begin
  Surface := TSurfaceVideo.Create;
  InputTerm := TInputSourceTerminal.Create;
  Input := InputTerm;

  { Theme: forced by --theme / HILDEGARD_THEME, else detected from the terminal
    (OSC 11). We always paint our own background; detection only chooses which
    one, so a light terminal gets dark text on a light background. }
  Mode := RequestedThemeMode;
  Light := False;
  if Mode = tmAuto then
    Light := InputTerm.DetectLightBackground;
  Theme := SelectTheme(Mode, Light);

  Files := TListView.Create(Theme);
  Files.AddItem('src/');
  Files.AddItem('  hildegard.helper.tui.app.pas');
  Files.AddItem('  hildegard.helper.tui.widget.pas');
  Files.AddItem('  hildegard.helper.tui.text.pas');
  Files.AddItem('  hildegard.helper.tui.panel.pas');
  Files.AddItem('examples/');
  Files.AddItem('  tui_layout_demo.pas');
  Files.AddItem('Makefile');
  Files.AddItem('HANDOFF.md');
  Style := DefaultBoxStyle;
  Style.Title := 'Files';
  FilesPanel := TPanel.Create(Files, Theme, Style);

  EditorText := TTextBlock.Create([], wmNone);
  EditorText.SetText(
    'unit hildegard.helper.tui.app;' + #10 +
    '' + #10 +
    'procedure TTuiApp.Tick(const ANowMs: Int64);' + #10 +
    'begin' + #10 +
    '  if FStop then Exit;' + #10 +
    '  FNowMs := ANowMs;' + #10 +
    '  FLastTickMs := ANowMs;' + #10 +
    '  if AdvanceTree(ANowMs) or FLayoutDirty then' + #10 +
    '    Present;' + #10 +
    'end;', Theme.Text);
  Style.Title := 'Editor';
  EditorPanel := TPanel.Create(EditorText, Theme, Style);

  ChatText := TTextBlock.Create([], wmNone);
  Style.Title := 'Chat';
  ChatPanel := TPanel.Create(ChatText, Theme, Style);
  Demo := TDemo.Create(ChatText, Theme.Text,
    '> add a responsive two-column layout' + #10 +
    '' + #10 +
    'I will show the file explorer and editor beside the chat' + #10 +
    'when the terminal is wide enough.' + #10 +
    '' + #10 +
    '[tool] list_dir  (read the workspace)' + #10 +
    '  examples/, src/, Makefile, HANDOFF.md' + #10);

  SideText := TTextBlock.Create([], wmNone);
  SideText.SetText(
    'Tools' + #10 +
    '' + #10 +
    '  read_file      idle' + #10 +
    '  write_file     idle' + #10 +
    '  run_command    idle' + #10 +
    '  grep           idle' + #10 +
    '' + #10 +
    'Context' + #10 +
    '' + #10 +
    '  workspace  hildegard-helper' + #10 +
    '  model      fireworks' + #10 +
    '  session    (in memory)', Theme.Muted);
  Style.Title := 'Tools';
  SidePanel := TPanel.Create(SideText, Theme, Style);

  { The persistent bottom panel: a prompt line plus a status/hint line. }
  Prompt := TPromptLine.Create('> ');
  Prompt.Active := True;
  Prompt.Attr := Theme.Text;
  Prompt.OnSubmit := Demo.OnSubmit;
  InfoText := TTextBlock.Create([], wmNone);
  InfoText.SetText('Ctrl-B side panel   Enter send   Ctrl-C quit',
    Theme.Muted);
  InputStack := TContainer.Create([Fill(1)], [Fixed(1), Fixed(1)]);
  InputStack.Add(Prompt, 0, 0);
  InputStack.Add(InfoText, 0, 1);
  Style.Title := 'Compose';
  InputPanel := TPanel.Create(InputStack, Theme, Style);

  Layout := TResponsiveLayout.Create(FilesPanel, EditorPanel, ChatPanel,
    SidePanel, InputPanel);

  App := TTuiApp.Create(Surface, Input, TQuitShell.Create(Layout));
  App.ScreenBg := Theme.Bg;
  try
    App.Run(@ShouldStop);
  finally
    App.Free;
    Demo.Free;
    Input := nil;
    Surface := nil;
  end;
end.
