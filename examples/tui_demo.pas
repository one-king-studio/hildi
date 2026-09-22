program tui_demo;
{ Interactive demonstration of the TUI toolkit.

  A nested layout: a status row and two independently scrolling panes (a
  coloured "conversation" and a coloured "diff"), a dimmed modal toggled with
  'm', and terminal resize handled by the app.

  Keys:  Tab / Left / Right  switch focus between panes
         Up / Down, j / k    scroll the focused pane by one line
         PgUp / PgDn, u / d  scroll the focused pane by a page
         click               focus the pane under the pointer
         mouse wheel         scroll the pane under the pointer
         m                   toggle the approval modal
         q                   quit

  The palette follows the terminal background: HILDEGARD_TUI_THEME=light|dark
  forces it, else COLORFGBG is used, else it queries OSC 11 when
  HILDEGARD_TUI_DETECT_THEME=1 (opt-in, because a slow reply can leak to the
  shell). Default is dark.

  Run with `make tui-demo` in a real terminal. }

{$mode delphi}{$H+}

uses
  SysUtils,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.surface.video,
  hildegard.helper.tui.widget, hildegard.helper.tui.text,
  hildegard.helper.tui.scroll, hildegard.helper.tui.app,
  hildegard.helper.tui.theme,
  hildegard.helper.tui.input.terminal;

type
  TPalette = record
    Bg, Fg, Head, Help, Code, Good, Del, Add, PanelBg, StatusFg: Byte;
  end;

const
  DarkPalette: TPalette = (Bg: 0; Fg: 7; Head: 81; Help: 244; Code: 215;
    Good: 114; Del: 203; Add: 114; PanelBg: 236; StatusFg: 244);
  LightPalette: TPalette = (Bg: 231; Fg: 0; Head: 25; Help: 240; Code: 130;
    Good: 28; Del: 124; Add: 28; PanelBg: 252; StatusFg: 240);

var
  Pal: TPalette;

type
  { A filled panel: draws a background over its bounds and insets the child,
    so a modal reads as a distinct surface over the dimmed base. }
  TPanel = class(TWidget)
  private
    FChild: TWidget;
    FBg: Byte;
    FApp: TTuiApp;
  public
    constructor Create(AChild: TWidget; ABg: Byte);
    destructor Destroy; override;
    procedure SetApp(AApp: TTuiApp);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  { The base root: handles global keys and scrolling, then forwards other events
    (mouse wheel) to the layout tree. }
  TShell = class(TWidget)
  private
    FChild: TWidget;
    FApp: TTuiApp;
    FChat, FDiff: TScrollContainer;
    FStatus: TTextBlock;
    FFocus: Integer;   { 0 = chat, 1 = diff }
    procedure ToggleModal;
    procedure SetFocus(AIndex: Integer);
    procedure ScrollFocused(ADelta: Integer);
  public
    constructor Create(AChild: TWidget; AChat, ADiff: TScrollContainer;
      AStatus: TTextBlock);
    destructor Destroy; override;
    procedure SetApp(AApp: TTuiApp);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function PointIn(const R: TRect; X, Y: Integer): Boolean;
begin
  Result := (X >= R.X) and (Y >= R.Y) and (X < R.X + R.W) and
    (Y < R.Y + R.H);
end;

function Inset(const R: TRect; ADx, ADy: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := R.X + ADx;
  Result.Y := R.Y + ADy;
  Result.W := R.W - 2 * ADx;
  Result.H := R.H - 2 * ADy;
  if Result.W < 0 then
    Result.W := 0;
  if Result.H < 0 then
    Result.H := 0;
end;

function Span(const AText: UnicodeString; AFg, ABg: Byte;
  AStyle: TStyle = []): TSpan;
begin
  Result := Default(TSpan);
  Result.Text := AText;
  Result.Attr.Fg := AFg;
  Result.Attr.Bg := ABg;
  Result.Attr.Style := AStyle;
end;

function RepeatedLines(const APrefix: string; ACount, AStart: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := AStart to AStart + ACount - 1 do
  begin
    if I > AStart then
      Result := Result + #10;
    Result := Result + APrefix + IntToStr(I);
  end;
end;

function MakeConversation: TTextBlock;
begin
  Result := TTextBlock.Create([
    Span('TUI Harness demo' + #10, Pal.Head, Pal.Bg, [sfBold]),
    Span('Nested grid; tracks are fixed/auto/fill.' + #10, Pal.Help, Pal.Bg),
    Span('Spans carry 256-colour attributes, e.g. ', Pal.Help, Pal.Bg),
    Span('inline code', Pal.Code, Pal.Bg, [sfBold]),
    Span(' or ', Pal.Help, Pal.Bg),
    Span('emphasis.', Pal.Good, Pal.Bg, [sfItalic]),
    Span(#10 + #10, Pal.Help, Pal.Bg),
    Span(UnicodeString(RepeatedLines('assistant: response line ', 60, 1)),
      Pal.Help, Pal.Bg)],
    wmNone);
end;

function MakeDiff: TTextBlock;
begin
  Result := TTextBlock.Create([
    Span(UnicodeString(RepeatedLines('- removed line ', 40, 1)) + #10,
      Pal.Del, Pal.Bg),
    Span(UnicodeString(RepeatedLines('+ added line ', 40, 1)),
      Pal.Add, Pal.Bg)],
    wmNone);
end;

{ Choose a palette from the env override, COLORFGBG, or the OSC 11 reply. }
function ChooseThemeKind(const AReply: string): TThemeKind;
var
  V: string;
  R, G, B: Byte;
begin
  V := LowerCase(GetEnvironmentVariable('HILDEGARD_TUI_THEME'));
  if V = 'light' then
    Exit(thLight);
  if V = 'dark' then
    Exit(thDark);
  if ParseColorFGBG(GetEnvironmentVariable('COLORFGBG'), Result) then
    Exit;
  Result := thDark;
  if ParseOSC11(AReply, R, G, B) and ColorIsLight(R, G, B) then
    Result := thLight;
end;

{ TPanel }

constructor TPanel.Create(AChild: TWidget; ABg: Byte);
begin
  inherited Create;
  FChild := AChild;
  FBg := ABg;
end;

destructor TPanel.Destroy;
begin
  FChild.Free;
  inherited Destroy;
end;

procedure TPanel.SetApp(AApp: TTuiApp);
begin
  FApp := AApp;
end;

function TPanel.HandleEvent(const E: TInputEvent): Boolean;
begin
  if (E.Kind = ikKey) and
    ((E.Key.Kind = kkEscape) or
    ((E.Key.Kind = kkChar) and (E.Key.Ch = 'm'))) then
  begin
    if FApp <> nil then
      FApp.PopPlane;
    Exit(True);
  end;
  Result := FChild.HandleEvent(E);
end;

function TPanel.Measure(const AAvail: TSize): TSize;
begin
  Result := FChild.Measure(AAvail);
  Inc(Result.W, 2);
  Inc(Result.H, 2);
end;

procedure TPanel.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  FChild.Arrange(Inset(ABounds, 1, 1));
end;

procedure TPanel.Render(const S: ISurface);
var
  A: TAttr;
begin
  A := DefaultAttr;
  A.Bg := FBg;
  S.FillRect(FBounds, A);
  FChild.Render(S);
end;

{ TShell }

constructor TShell.Create(AChild: TWidget; AChat, ADiff: TScrollContainer;
  AStatus: TTextBlock);
begin
  inherited Create;
  FChild := AChild;
  FChat := AChat;
  FDiff := ADiff;
  FStatus := AStatus;
  FFocus := 0;
end;

destructor TShell.Destroy;
begin
  FChild.Free;
  inherited Destroy;
end;

procedure TShell.SetApp(AApp: TTuiApp);
begin
  FApp := AApp;
end;

procedure TShell.SetFocus(AIndex: Integer);
begin
  FFocus := AIndex;
  if FFocus <> 0 then
    FStatus.SetText(
      'status: focus right (diff)   [Tab/click] switch  [m] modal  [q] quit',
      Span('', Pal.StatusFg, Pal.Bg).Attr)
  else
    FStatus.SetText(
      'status: focus left (chat)   [Tab/click] switch  [m] modal  [q] quit',
      Span('', Pal.StatusFg, Pal.Bg).Attr);
end;

procedure TShell.ScrollFocused(ADelta: Integer);
begin
  if FFocus = 1 then
    FDiff.ScrollBy(0, ADelta)
  else
    FChat.ScrollBy(0, ADelta);
end;

function TShell.Measure(const AAvail: TSize): TSize;
begin
  Result := FChild.Measure(AAvail);
end;

procedure TShell.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  FChild.Arrange(ABounds);
end;

procedure TShell.Render(const S: ISurface);
begin
  FChild.Render(S);
end;

procedure TShell.ToggleModal;
var
  Root: TContainer;
  Body, Panel: TWidget;
begin
  if FApp.ModalActive then
    FApp.PopPlane
  else
  begin
    Root := TContainer.Create([Fill(1), Fixed(46), Fill(1)],
      [Fill(1), Fixed(9), Fill(1)]);
    Body := TTextBlock.Create([
      Span('Approve this command?' + #10 + #10, Pal.Head, Pal.PanelBg,
        [sfBold]),
      Span('  rm -rf build/' + #10, Pal.Code, Pal.PanelBg),
      Span('  Reason: clear generated output.' + #10 + #10, Pal.Help,
        Pal.PanelBg),
      Span('[m] dismiss', Pal.Good, Pal.PanelBg)],
      wmNone);
    Panel := TPanel.Create(Body, Pal.PanelBg);
    TPanel(Panel).SetApp(FApp);
    Root.Add(Panel, 1, 1);
    Root.Arrange(FBounds);
    FApp.PushPlane(TPlane.Create(Root, True, True));
  end;
end;

function TShell.HandleEvent(const E: TInputEvent): Boolean;
begin
  if E.Kind = ikMouse then
  begin
    { Give the panes first refusal: wheel scrolling and scrollbar drags are
      consumed there and must not change focus. A left click no pane consumes
      focuses the pane under the pointer. }
    if FChild.HandleEvent(E) then
      Exit(True);
    if E.Mouse.Button = mbLeft then
    begin
      if PointIn(FChat.Bounds, E.Mouse.X, E.Mouse.Y) then
        SetFocus(0)
      else if PointIn(FDiff.Bounds, E.Mouse.X, E.Mouse.Y) then
        SetFocus(1);
      Exit(True);
    end;
    Exit(False);
  end;
  if E.Kind <> ikKey then
    Exit(False);

  if E.Key.Kind = kkChar then
  begin
    if E.Key.Ch = 'q' then
    begin
      FApp.Stop;
      Exit(True);
    end;
    if E.Key.Ch = 'm' then
    begin
      ToggleModal;
      Exit(True);
    end;
    if E.Key.Ch = 'j' then
    begin
      ScrollFocused(1);
      Exit(True);
    end;
    if E.Key.Ch = 'k' then
    begin
      ScrollFocused(-1);
      Exit(True);
    end;
    if E.Key.Ch = 'd' then
    begin
      ScrollFocused(8);
      Exit(True);
    end;
    if E.Key.Ch = 'u' then
    begin
      ScrollFocused(-8);
      Exit(True);
    end;
  end;

  case E.Key.Kind of
    kkTab:
      begin
        SetFocus(1 - FFocus);
        Exit(True);
      end;
    kkLeft:
      begin
        SetFocus(0);
        Exit(True);
      end;
    kkRight:
      begin
        SetFocus(1);
        Exit(True);
      end;
    kkUp:
      begin
        ScrollFocused(-1);
        Exit(True);
      end;
    kkDown:
      begin
        ScrollFocused(1);
        Exit(True);
      end;
    kkPageUp:
      begin
        ScrollFocused(-8);
        Exit(True);
      end;
    kkPageDown:
      begin
        ScrollFocused(8);
        Exit(True);
      end;
  else
    ;
  end;
  Result := False;
end;

var
  Surface: ISurface;
  Input: IInputSource;
  InputTerm: TInputSourceTerminal;
  App: TTuiApp;
  Shell: TShell;
  Root, Panes, Status: TContainer;
  ChatScroll, DiffScroll: TScrollContainer;
  StatusText: TTextBlock;
  Bg: TAttr;
  Reply: string;
begin
  { Create the surface before the input source, and destroy the input source
    before the surface: video's init must run first, and each restores the
    termios it saved, so the tty ends up cooked. }
  Surface := TSurfaceVideo.Create;
  InputTerm := TInputSourceTerminal.Create;
  Input := InputTerm;

  { Query from the input adapter (raw mode is active there), so the reply is
    read and drained. Opt-in only: a slow terminal can answer after startup, and
    that late reply would otherwise reach the shell. Use COLORFGBG,
    HILDEGARD_TUI_THEME=light|dark, or HILDEGARD_TUI_DETECT_THEME=1. }
  Reply := '';
  if GetEnvironmentVariable('HILDEGARD_TUI_DETECT_THEME') = '1' then
    Reply := InputTerm.QueryBackground;
  if ChooseThemeKind(Reply) = thLight then
    Pal := LightPalette
  else
    Pal := DarkPalette;

  Root := TContainer.Create([Fill(1)], [Fill(1), Fixed(1)]);
  Panes := TContainer.Create([Fill(2), Fill(1)], [Fill(1)]);

  ChatScroll := TScrollContainer.Create(MakeConversation, smAuto, smNever);
  DiffScroll := TScrollContainer.Create(MakeDiff, smAuto, smNever);

  Panes.Add(ChatScroll, 0, 0);
  Panes.Add(DiffScroll, 1, 0);

  Status := TContainer.Create([Fill(1)], [Fixed(1)]);
  StatusText := TTextBlock.Create(
    [Span('status: focus left (chat)   [Tab/click] switch  [m] modal  [q] quit',
      Pal.StatusFg, Pal.Bg)], wmNone);
  Status.Add(StatusText, 0, 0);

  Root.Add(Panes, 0, 0);
  Root.Add(Status, 0, 1);

  Shell := TShell.Create(Root, ChatScroll, DiffScroll, StatusText);
  App := TTuiApp.Create(Surface, Input, Shell);
  Bg := DefaultAttr;
  Bg.Fg := Pal.Fg;
  Bg.Bg := Pal.Bg;
  App.Background := Bg;
  Shell.SetApp(App);
  try
    { Same as App.Run, but also stop on SIGTERM/SIGINT/SIGHUP so the terminal is
      restored on the normal exit path. }
    while App.Step do
    begin
      if InputTerm.Terminated then
        App.Stop;
      Sleep(1);
    end;
  finally
    App.Free;
    Input := nil;
    Surface := nil;
  end;
end.
