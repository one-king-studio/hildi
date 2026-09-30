program tui_widgets_demo;
{ A demo of the TUI widget kit: a list, a preview panel, and buttons, driven by
  Tab/Shift-Tab or the mouse. Enter/Space activates the focused control; 'q' or
  Ctrl-C quits.

  Run: make widgets-demo }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils, Classes,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.app,
  hildegard.helper.tui.surface.video, hildegard.helper.tui.input.terminal,
  hildegard.helper.tui.theme, hildegard.helper.tui.panel,
  hildegard.helper.tui.focus, hildegard.helper.tui.button,
  hildegard.helper.tui.list;

var
  QuitRequested: Boolean = False;

type
  { Wraps the root so 'q'/Ctrl-C quit before the focus group consumes them. }
  TQuitShell = class(TWidget)
  private
    FChild: TWidget;
  public
    constructor Create(AChild: TWidget);
    destructor Destroy; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  { Holds the actions and the widgets they touch. }
  TDemo = class
  private
    FApp: TTuiApp;
    FPreview: TTextBlock;
    FList: TListView;
    FTheme: TTheme;
  public
    constructor Create(const ATheme: TTheme; APreview: TTextBlock;
      AList: TListView);
    procedure SetApp(AApp: TTuiApp);
    procedure Show(const S: string);
    procedure OnOpen(Sender: TObject);
    procedure OnQuit(Sender: TObject);
    procedure OnActivate(Sender: TObject);
  end;

constructor TQuitShell.Create(AChild: TWidget);
begin
  inherited Create;
  FChild := AChild;
end;

destructor TQuitShell.Destroy;
begin
  FChild.Free;
  inherited Destroy;
end;

function TQuitShell.Measure(const AAvail: TSize): TSize;
begin
  Result := FChild.Measure(AAvail);
end;

procedure TQuitShell.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  FChild.Arrange(ABounds);
end;

procedure TQuitShell.Render(const S: ISurface);
begin
  FChild.Render(S);
end;

function TQuitShell.HandleEvent(const E: TInputEvent): Boolean;
begin
  if (E.Kind = ikKey) and (E.Key.Kind = kkChar) and
    ((moCtrl in E.Key.Mods) and ((E.Key.Ch = 'c') or (E.Key.Ch = 'd')) or
     ((E.Key.Mods = []) and (E.Key.Ch = 'q'))) then
  begin
    QuitRequested := True;
    Exit(True);
  end;
  Result := FChild.HandleEvent(E);
end;

constructor TDemo.Create(const ATheme: TTheme; APreview: TTextBlock;
  AList: TListView);
begin
  inherited Create;
  FTheme := ATheme;
  FPreview := APreview;
  FList := AList;
end;

procedure TDemo.SetApp(AApp: TTuiApp);
begin
  FApp := AApp;
end;

procedure TDemo.Show(const S: string);
begin
  FPreview.SetText(S, FTheme.Text);
end;

procedure TDemo.OnOpen(Sender: TObject);
begin
  if (FList.Selected >= 0) then
    Show('Opened ' + FList.ItemAt(FList.Selected) + '.' + #10 + #10 +
      'Enter/Space activates the focused control;' + #10 +
      'Tab or Shift-Tab moves focus; the mouse focuses too.')
  else
    Show('Nothing selected.');
end;

procedure TDemo.OnQuit(Sender: TObject);
begin
  QuitRequested := True;
end;

procedure TDemo.OnActivate(Sender: TObject);
begin
  Show('Selected ' + FList.ItemAt(FList.Selected) + '.');
end;

var
  Surface: ISurface;
  InputTerm: TInputSourceTerminal;
  Input: IInputSource;
  Theme: TTheme;
  Preview: TTextBlock;
  List: TListView;
  PreviewPanel: TPanel;
  OpenBtn, QuitBtn: TButton;
  Root: TFocusGroup;
  App: TTuiApp;
  Demo: TDemo;
  Style: TBoxStyle;
begin
  Surface := TSurfaceVideo.Create;
  InputTerm := TInputSourceTerminal.Create;
  Input := InputTerm;

  Theme := DarkTheme;

  List := TListView.Create(Theme);
  List.AddItem('alpha.txt');
  List.AddItem('beta.txt');
  List.AddItem('gamma.txt');
  List.AddItem('notes.md');

  Preview := TTextBlock.Create([], wmNone);

  Style := DefaultBoxStyle;
  Style.Title := 'Preview';
  PreviewPanel := TPanel.Create(Preview, Theme, Style);

  OpenBtn := TButton.Create('Open', Theme);
  QuitBtn := TButton.Create('Quit', Theme);

  { The list and the buttons are direct children so the focus group sees them. }
  Root := TFocusGroup.Create([Fixed(28), Fill(1)], [Fill(1), Fixed(1)]);
  Root.Add(List, 0, 0);
  Root.Add(PreviewPanel, 1, 0);
  Root.Add(OpenBtn, 0, 1);
  Root.Add(QuitBtn, 1, 1);

  Demo := TDemo.Create(Theme, Preview, List);
  OpenBtn.OnClick := Demo.OnOpen;
  QuitBtn.OnClick := Demo.OnQuit;
  List.OnActivate := Demo.OnActivate;
  Demo.Show('Select a file and press Open.' + #10 + #10 +
    'Tab moves focus; the focused control is highlighted.');

  App := TTuiApp.Create(Surface, Input, TQuitShell.Create(Root));
  Demo.SetApp(App);
  try
    while App.Step do
    begin
      if QuitRequested or InputTerm.Terminated then
        App.Stop;
      Sleep(1);
    end;
  finally
    App.Free;
    Demo.Free;
    Input := nil;
    Surface := nil;
  end;
end.
