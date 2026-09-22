program tui_demo;
{ Interactive demonstration of the TUI toolkit.

  A nested layout: a status row and two independently scrolling panes (a
  coloured "conversation" and a coloured "diff"), a dimmed modal toggled with
  'm', and terminal resize handled by the app.

  Keys:  Up/Down    scroll the left pane
         PgUp/PgDn  scroll the right pane
         m          toggle the approval modal
         q          quit

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
  { A scroll container that only consumes a chosen set of keys, so two panes
    can scroll independently with different keys. }
  TKeyScroll = class(TScrollContainer)
  public
    Keys: set of TKeyKind;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  { The base root: handles global keys, then forwards to the layout tree. }
  TShell = class(TWidget)
  private
    FChild: TWidget;
    FApp: TTuiApp;
    procedure ToggleModal;
  public
    constructor Create(AChild: TWidget);
    destructor Destroy; override;
    procedure SetApp(AApp: TTuiApp);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

function TKeyScroll.HandleEvent(const E: TInputEvent): Boolean;
begin
  if (E.Kind = ikKey) and (E.Key.Kind in Keys) then
    Result := inherited HandleEvent(E)
  else
    Result := False;
end;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
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
  Help = 244;   { greyscale }
  Head = 81;    { blue }
  Code = 215;   { orange }
  Good = 114;   { green }
begin
  Result := TTextBlock.Create([
    Span('TUI Harness demo' + #10, Head, [sfBold]),
    Span('The layout is a nested grid; tracks are fixed/auto/fill.' + #10, Help),
    Span('Spans carry 256-colour attributes, e.g. ', Help),
    Span('inline code', Code, [sfBold]),
    Span(' or ', Help),
    Span('emphasis.', Good, [sfItalic]),
    Span(#10 + #10, Help),
    Span('Panels:' + #10, Head, [sfBold]),
    Span('  left  - conversation (Up/Down)' + #10, Help),
    Span('  right - diff (PgUp/PgDn)' + #10, Help),
    Span(#10, Help),
    Span(UnicodeString(RepeatedLines('assistant: response line ', 60, 1)),
      Help)],
    wmNone);
end;

function MakeDiff: TTextBlock;
const
  Add = 114;   { green }
  Del = 203;   { red }
begin
  Result := TTextBlock.Create([
    Span(UnicodeString(RepeatedLines('- removed line ', 40, 1)) + #10, Del),
    Span(UnicodeString(RepeatedLines('+ added line ', 40, 1)), Add)],
    wmNone);
end;

constructor TShell.Create(AChild: TWidget);
begin
  inherited Create;
  FChild := AChild;
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
  Body: TTextBlock;
begin
  if FApp.ModalActive then
    FApp.PopPlane
  else
  begin
    Root := TContainer.Create([Fill(1), Fixed(42), Fill(1)],
      [Fill(1), Fixed(7), Fill(1)]);
    Body := TTextBlock.Create([
      Span('Approve this command?' + #10 + #10, 81, [sfBold]),
      Span('  rm -rf build/' + #10, 215),
      Span('  Reason: clear generated output.' + #10 + #10, 244),
      Span('[m] dismiss', 114)],
      wmNone);
    Root.Add(Body, 1, 1);
    Root.Arrange(FBounds);
    FApp.PushPlane(TPlane.Create(Root, True, True));
  end;
end;

function TShell.HandleEvent(const E: TInputEvent): Boolean;
begin
  if (E.Kind = ikKey) and (E.Key.Kind = kkChar) then
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
  end;
  Result := FChild.HandleEvent(E);
end;

var
  Surface: ISurface;
  Input: IInputSource;
  App: TTuiApp;
  Shell: TShell;
  Root, Panes, Status: TContainer;
  ChatScroll, DiffScroll: TKeyScroll;
begin
  Surface := TSurfaceVideo.Create;
  Input := TInputSourceTerminal.Create;

  Root := TContainer.Create([Fill(1)], [Fill(1), Fixed(1)]);
  Panes := TContainer.Create([Fill(2), Fill(1)], [Fill(1)]);

  ChatScroll := TKeyScroll.Create(MakeConversation, smAuto, smNever);
  ChatScroll.Keys := [kkUp, kkDown];
  DiffScroll := TKeyScroll.Create(MakeDiff, smAuto, smNever);
  DiffScroll.Keys := [kkPageUp, kkPageDown];

  Panes.Add(ChatScroll, 0, 0);
  Panes.Add(DiffScroll, 1, 0);

  Status := TContainer.Create([Fill(1)], [Fixed(1)]);
  Status.Add(TTextBlock.Create([Span('status: ready   [m] modal  [q] quit',
    244)], wmNone), 0, 0);

  Root.Add(Panes, 0, 0);
  Root.Add(Status, 0, 1);

  Shell := TShell.Create(Root);
  App := TTuiApp.Create(Surface, Input, Shell);
  Shell.SetApp(App);
  try
    App.Run;
  finally
    App.Free;
    Surface := nil;
    Input := nil;
  end;
end.
