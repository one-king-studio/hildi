program tui_layout_demo;
{ A layout exploration for a personal coding-agent harness.

  Two main columns - file explorer + editor, and the chat column - shown only
  when the terminal is wider than 180 columns. The two halves are a 50/50 split;
  the left half is a fixed 20-column file explorer plus a filling editor. Narrower
  terminals collapse to the chat column alone.

  The chat column follows docs/design/chat_panel_tui.md:
    - user messages: a raised background, a dimmed accent border and a heavy
      bottom edge (the "bubble");
    - assistant messages: plain text on the app background, blank lines between
      paragraphs;
    - thought blocks: collapsed to a dimmed rule, expanded to a dimmed box; the
      whole block is clickable;
    - tool reason/output blocks: collapsed to a heavy rule, expanded to a sunken
      (darker) box with full-contrast text;
    - an animated thinking indicator (a sparkle burst);
    - a scrollbar whose track is the panel's right border and whose thumb is the
      brighter thick bar.
  The input box shares the user bubble's raised background and border, grows with
  the text, and overlays the stream up to 60% of the height. It is a TTextEdit,
  so the caret is tracked through edits, wraps, and scrolling. Enter sends;
  Shift+Enter adds a line.

  Keys: Ctrl-C / Ctrl-D quit; Ctrl-B toggles the side panel; Enter send;
  Shift+Enter newline; arrows / Home / End move the caret in the input; wheel
  scrolls the stream; click a block to expand it.

  Theme: --theme=dark|light|auto (or HILDEGARD_THEME); auto detects the
  terminal's own background. We always paint our own background.

  Run: make layout-demo }

{$mode delphi}{$H+}{$codepage utf8}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils, Classes,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.app,
  hildegard.helper.tui.surface.video, hildegard.helper.tui.input.terminal,
  hildegard.helper.tui.theme, hildegard.helper.tui.panel,
  hildegard.helper.tui.list, hildegard.helper.tui.scroll,
  hildegard.helper.tui.chat, hildegard.helper.tui.compose,
  hildegard.helper.tui.chatpanel;

const
  WideThreshold = 180;     // two columns appear above this width
  SidebarWidth = 20;       // fixed file-explorer column
  SideWidth = 30;          // chat side panel
  MinChatWidth = 40;
  FooterHeight = 1;
  MaxComposePercent = 60;  // the input box never exceeds this share of the height
  CollapsedLines = 3;
  ContentBottomPad = 2;    // blank rows kept below the last message block
  Sparkles: array[0..12] of UnicodeString =
    ('∙', '•', '●', '◉', '❂', '✴', '✵', '✶', '✷', '✸', '✹', '✺', '❋');

var
  QuitRequested: Boolean = False;

type

  { Wraps the root so Ctrl-C/Ctrl-D quit. }
  TQuitShell = class(TSingleChild)
  public
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  { The responsive layout. }
  TResponsiveLayout = class(TWidget)
  private
    FFiles: TWidget;
    FEditor: TWidget;
    FChat: TWidget;
    FSide: TWidget;
    FShowSide: Boolean;
    procedure PlaceChatColumn(const R: TRect);
    procedure Place(const ABounds: TRect);
  public
    constructor Create(AFiles, AEditor, AChat, ASide: TWidget);
    destructor Destroy; override;
    procedure ToggleSide;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
  end;

  TDemo = class
  private
    FPanel: TChatPanel;
    FApp: TTuiApp;
  public
    constructor Create(APanel: TChatPanel);
    procedure SetApp(AApp: TTuiApp);
    procedure OnSubmit(const AText: string);
    procedure OnToggle(Sender: TObject);
  end;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function Rep(const ACh: UnicodeString; AN: Integer): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to AN do
    Result := Result + ACh;
end;

procedure PutCh(const S: ISurface; X, Y: Integer; const ACh: UnicodeString;
  const AAttr: TAttr);
var
  C: TCell;
begin
  C := Default(TCell);
  C.Ch := ACh;
  C.Attr := AAttr;
  S.Put(X, Y, C);
end;

procedure PutText(const S: ISurface; X, Y: Integer; const AText: UnicodeString;
  const AAttr: TAttr);
var
  I: Integer;
begin
  for I := 1 to Length(AText) do
    PutCh(S, X + I - 1, Y, UnicodeString(AText[I]), AAttr);
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

{ TResponsiveLayout }

constructor TResponsiveLayout.Create(AFiles, AEditor, AChat, ASide: TWidget);
begin
  inherited Create;
  FFiles := AFiles;
  FEditor := AEditor;
  FChat := AChat;
  FSide := ASide;
  FShowSide := False;
end;

destructor TResponsiveLayout.Destroy;
begin
  FFiles.Free;
  FEditor.Free;
  FChat.Free;
  FSide.Free;
  inherited Destroy;
end;

procedure TResponsiveLayout.ToggleSide;
begin
  FShowSide := not FShowSide;
  if FBounds.W > 0 then
    Arrange(FBounds);
end;

function TResponsiveLayout.Measure(const AAvail: TSize): TSize;
begin
  Result := AAvail;
end;

procedure TResponsiveLayout.PlaceChatColumn(const R: TRect);
var
  SideW, ChatW: Integer;
  SideR, ChatCol: TRect;
begin
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
  FChat.Arrange(ChatCol);
  FSide.Arrange(SideR);
end;

procedure TResponsiveLayout.Place(const ABounds: TRect);
var
  Wide: Boolean;
  LeftW, RightW: Integer;
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
  end
  else
  begin
    FFiles.Arrange(Rc(ABounds.X, ABounds.Y, 0, 0));
    FEditor.Arrange(Rc(ABounds.X, ABounds.Y, 0, 0));
    PlaceChatColumn(ABounds);
  end;
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
end;

function TResponsiveLayout.Animating: Boolean;
begin
  Result := (FFiles.Visible and FFiles.Animating) or
    (FEditor.Visible and FEditor.Animating) or
    (FChat.Visible and FChat.Animating) or
    (FSide.Visible and FSide.Animating);
end;

{ TDemo }

constructor TDemo.Create(APanel: TChatPanel);
begin
  inherited Create;
  FPanel := APanel;
end;

procedure TDemo.SetApp(AApp: TTuiApp);
begin
  FApp := AApp;
end;

procedure TDemo.OnSubmit(const AText: string);
begin
  FPanel.Stream.Add(ckUser, '', AText);
  if FApp <> nil then
    FApp.Invalidate;
end;

procedure TDemo.OnToggle(Sender: TObject);
begin
  if FApp <> nil then
    FApp.Invalidate;
end;

var
  Surface: ISurface;
  InputTerm: TInputSourceTerminal;
  Input: IInputSource;
  Theme: TTheme;
  Files: TListView;
  EditorText, SideText: TTextBlock;
  ChatPanel: TChatPanel;
  FilesPanel, EditorPanel, SidePanel: TPanel;
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

  ChatPanel := TChatPanel.Create(Theme, 'Hildegard · Model v1 Fireworks · low',
    '↵ send   ⇧+↵ newline   click a block to expand   ' +
    'ctrl+p commands   ctrl+b sidebar');
  ChatPanel.Stream.Add(ckUser, '',
    'This is the user''s message. It should be rendered with a slightly lighter ' +
    'background to distinguish it from the rest of the content. Make the border ' +
    'be a dimmed accent color to not make it too distracting.');
  ChatPanel.Stream.Add(ckThought, 'Thought · 8.2s',
    'This is an expanded thought block. The entire block is clickable even when ' +
    'collapsed, and clicking toggles between expanded and collapsed. The borders ' +
    'and text in this block are rendered with a dimmed color on the default ' +
    'background.');
  ChatPanel.Stream.Add(ckAssistant, '',
    'Assistant message between thoughts.');
  ChatPanel.Stream.Add(ckTool, 'looking for the build file',
    'glob  {"pattern":"Makefile"}' + #10 + '' + #10 +
    'AGENTS.md  Makefile   deps       examples   src' + #10 +
    'the reason is the title; expand for the tool and its output');
  ChatPanel.Stream.Add(ckAssistant, '',
    'Final assistant message. The scrollbar is the same character but rendered ' +
    'in different colors: a darker track and a lighter thumb.' + #10 + '' + #10 +
    'A multi-paragraph response simply applies a gap between paragraphs.');
  ChatPanel.SetState(psThinking, 'thinking');
  ChatPanel.SetStatus(GetCurrentDir);
  ChatPanel.SetStats('1.2k in · 310 out · 92% cached · 3.4s · 2 req');

  SideText := TTextBlock.Create([], wmNone);
  SideText.SetText(
    'Tools' + #10 + '' + #10 +
    '  read_file      idle' + #10 +
    '  write_file     idle' + #10 +
    '  run_command    idle' + #10 +
    '  grep           idle' + #10 + '' + #10 +
    'Context' + #10 + '' + #10 +
    '  workspace  hildegard-helper' + #10 +
    '  model      fireworks' + #10 +
    '  session    (in memory)', Theme.Muted);
  Style := DefaultBoxStyle;
  Style.Title := 'Tools';
  SidePanel := TPanel.Create(SideText, Theme, Style);

  Demo := TDemo.Create(ChatPanel);
  ChatPanel.Stream.OnToggle := Demo.OnToggle;
  ChatPanel.Compose.OnSubmit := Demo.OnSubmit;
  ChatPanel.Compose.OnChange := Demo.OnToggle;

  Layout := TResponsiveLayout.Create(FilesPanel, EditorPanel, ChatPanel,
    SidePanel);

  App := TTuiApp.Create(Surface, Input, TQuitShell.Create(Layout));
  App.ScreenBg := Theme.Bg;
  Demo.SetApp(App);
  try
    App.Run(@ShouldStop);
  finally
    App.Free;
    Demo.Free;
    Input := nil;
    Surface := nil;
  end;
end.
