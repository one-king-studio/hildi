program tui_widgets_demo;
{ A demo of the TUI widget kit: a list, a preview panel, and buttons, driven by
  Tab/Shift-Tab or the mouse. A status row shows a clock-driven spinner and an
  indeterminate progress bar (no per-widget timers; TTuiApp.Run advances them).
  Enter/Space activates the focused control; 'q' or Ctrl-C quits.

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
  hildegard.helper.tui.list, hildegard.helper.tui.spinner,
  hildegard.helper.tui.progress;

var
  QuitRequested: Boolean = False;

type
  { Wraps the root so 'q'/Ctrl-C quit before the focus group consumes them.
    Extends TSingleChild so Advance/Animating reach the whole tree. }
  TQuitShell = class(TSingleChild)
  public
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  { Holds the actions and the widgets they touch. }
  TDemo = class
  private
    FApp: TTuiApp;
    FPreview: TTextBlock;
    FList: TListView;
    FTheme: TTheme;
    FInput: TInputSourceTerminal;
  public
    constructor Create(const ATheme: TTheme; APreview: TTextBlock;
      AList: TListView);
    procedure SetApp(AApp: TTuiApp);
    procedure SetInput(AInput: TInputSourceTerminal);
    { The Run loop's stop condition: a quit key or a signal. }
    function ShouldStop: Boolean;
    procedure Show(const S: string);
    procedure OnOpen(Sender: TObject);
    procedure OnQuit(Sender: TObject);
    procedure OnActivate(Sender: TObject);
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
  Result := inherited HandleEvent(E);
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

procedure TDemo.SetInput(AInput: TInputSourceTerminal);
begin
  FInput := AInput;
end;

function TDemo.ShouldStop: Boolean;
begin
  Result := QuitRequested or ((FInput <> nil) and FInput.Terminated);
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
  Spinner: TSpinner;
  Bar: TProgress;
  Main: TFocusGroup;
  Status: TContainer;
  Root: TContainer;
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
  Main := TFocusGroup.Create([Fixed(28), Fill(1)], [Fill(1), Fixed(1)]);
  Main.Add(List, 0, 0);
  Main.Add(PreviewPanel, 1, 0);
  Main.Add(OpenBtn, 0, 1);
  Main.Add(QuitBtn, 1, 1);

  { A status row driven by the frame clock: a spinner and an indeterminate bar,
    both pure functions of time, advanced by TTuiApp each frame. }
  Spinner := TSpinner.Create(BrailleFrames, 90, Theme.Accent);
  Bar := TProgress.Create(20, Theme.Success);
  Bar.Indeterminate := True;
  Status := TContainer.Create([Auto, Fixed(2), Fixed(20), Fill(1)], [Auto]);
  Status.Add(Spinner, 0, 0);
  Status.Add(Bar, 2, 0);

  Root := TContainer.Create([Fill(1)], [Fill(1), Fixed(1)]);
  Root.Add(Main, 0, 0);
  Root.Add(Status, 0, 1);

  Demo := TDemo.Create(Theme, Preview, List);
  OpenBtn.OnClick := Demo.OnOpen;
  QuitBtn.OnClick := Demo.OnQuit;
  List.OnActivate := Demo.OnActivate;
  Demo.Show('Select a file and press Open.' + #10 + #10 +
    'Tab moves focus; the focused control is highlighted.');

  App := TTuiApp.Create(Surface, Input, TQuitShell.Create(Root));
  Demo.SetApp(App);
  Demo.SetInput(InputTerm);
  try
    { Run waits on input to the next frame while the spinner/bar animate. }
    App.Run(Demo.ShouldStop);
  finally
    App.Free;
    Demo.Free;
    Input := nil;
    Surface := nil;
  end;
end.
