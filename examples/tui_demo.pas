program tui_demo;
{ Interactive demonstration of the TUI toolkit.

  A nested layout: a status row and two independently scrolling panes (a
  coloured "conversation" and a coloured "diff"), a dimmed modal toggled with
  'm', and terminal resize handled by the app.

  Keys:  Tab / Left / Right  switch focus between panes
         Up / Down, j / k    scroll the focused pane by one line
         PgUp / PgDn, u / d  scroll the focused pane by a page
         mouse wheel         scroll the pane under the pointer
         m                   toggle the approval modal
         q                   quit

  Run with `make tui-demo` in a real terminal. Markdown-to-span parsing is a
  follow-on component (Markdown_v1.SPEC.md); this demo uses styled spans
  directly to show the 256-colour palette. }

{$mode delphi}{$H+}

uses
  SysUtils,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.surface.video,
  hildegard.helper.tui.widget, hildegard.helper.tui.text,
  hildegard.helper.tui.scroll, hildegard.helper.tui.app,
  hildegard.helper.tui.input.terminal;

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

function Span(const AText: UnicodeString; AFg: Byte;
  AStyle: TStyle = []): TSpan;
begin
  Result := Default(TSpan);
  Result.Text := AText;
  Result.Attr.Fg := AFg;
  Result.Attr.Bg := 0;
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
const
  Help = 244;
  Head = 81;
  Code = 215;
  Good = 114;
begin
  Result := TTextBlock.Create([
    Span('TUI Harness demo' + #10, Head, [sfBold]),
    Span('Nested grid; tracks are fixed/auto/fill.' + #10, Help),
    Span('Spans carry 256-colour attributes, e.g. ', Help),
    Span('inline code', Code, [sfBold]),
    Span(' or ', Help),
    Span('emphasis.', Good, [sfItalic]),
    Span(#10 + #10, Help),
    Span(UnicodeString(RepeatedLines('assistant: response line ', 60, 1)),
      Help)],
    wmNone);
end;

function MakeDiff: TTextBlock;
const
  Add = 114;
  Del = 203;
begin
  Result := TTextBlock.Create([
    Span(UnicodeString(RepeatedLines('- removed line ', 40, 1)) + #10, Del),
    Span(UnicodeString(RepeatedLines('+ added line ', 40, 1)), Add)],
    wmNone);
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
    FStatus.SetText('status: focus right (diff)   [Tab/click] switch  [m] modal  [q] quit',
      Span('', 244).Attr)
  else
    FStatus.SetText('status: focus left (chat)   [Tab/click] switch  [m] modal  [q] quit',
      Span('', 244).Attr);
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
      Span('Approve this command?' + #10 + #10, 81, [sfBold]),
      Span('  rm -rf build/' + #10, 215),
      Span('  Reason: clear generated output.' + #10 + #10, 244),
      Span('[m] dismiss', 114)],
      wmNone);
    Panel := TPanel.Create(Body, 236);
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
    { A left click focuses the pane under the pointer; the wheel only scrolls. }
    if E.Mouse.Button = mbLeft then
    begin
      if PointIn(FChat.Bounds, E.Mouse.X, E.Mouse.Y) then
        SetFocus(0)
      else if PointIn(FDiff.Bounds, E.Mouse.X, E.Mouse.Y) then
        SetFocus(1);
    end;
    Exit(FChild.HandleEvent(E));
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
  App: TTuiApp;
  Shell: TShell;
  Root, Panes, Status: TContainer;
  ChatScroll, DiffScroll: TScrollContainer;
  StatusText: TTextBlock;
begin
  { Create the surface before the input source, and destroy the input source
    before the surface: video's init must run first, and each restores the
    termios it saved, so the tty ends up cooked. Reversing either order leaves
    the terminal in raw mode or breaks input. }
  Surface := TSurfaceVideo.Create;
  Input := TInputSourceTerminal.Create;

  Root := TContainer.Create([Fill(1)], [Fill(1), Fixed(1)]);
  Panes := TContainer.Create([Fill(2), Fill(1)], [Fill(1)]);

  ChatScroll := TScrollContainer.Create(MakeConversation, smAuto, smNever);
  DiffScroll := TScrollContainer.Create(MakeDiff, smAuto, smNever);

  Panes.Add(ChatScroll, 0, 0);
  Panes.Add(DiffScroll, 1, 0);

  Status := TContainer.Create([Fill(1)], [Fixed(1)]);
  StatusText := TTextBlock.Create(
    [Span('status: focus left (chat)   [Tab/click] switch  [m] modal  [q] quit',
      244)], wmNone);
  Status.Add(StatusText, 0, 0);

  Root.Add(Panes, 0, 0);
  Root.Add(Status, 0, 1);

  Shell := TShell.Create(Root, ChatScroll, DiffScroll, StatusText);
  App := TTuiApp.Create(Surface, Input, Shell);
  Shell.SetApp(App);
  try
    App.Run;
  finally
    App.Free;
    Input := nil;
    Surface := nil;
  end;
end.
