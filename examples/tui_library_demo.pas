program tui_library_demo;
{ A runnable tour of the TUI library, meant to be the first thing a consumer
  reads and the thing an operator can look at without reading any Pascal.

  It uses ONLY src/tui/** and the RTL - no Hildi unit is reachable from here, so
  it doubles as a live demonstration that the module is exportable.

  What it shows:
    - a themed window with a bordered panel and a title
    - a scrolling list with a selection, driven by keys and by the wheel
    - a selectable text pane: drag across it, and the selection copies to the
      terminal clipboard on release (OSC 52)
    - a progress bar and a spinner that animate from app-registered intervals

  Run it, then:
    up/down or wheel   move the list selection
    drag on the text   select text; release copies it
    q                  quit

  NOTE: selecting also works with Shift+held, which most terminals intercept for
  their own selection - the library deliberately ignores shift-modified mouse
  events so the two can coexist. }

{$mode delphi}{$H+}{$codepage utf8}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}
  SysUtils,
  TUIBase, TUIInput, TUISurface, TUITheme, TUIWidget, TUIApp,
  TUISurfaceVideo, TUIInputTerminal,
  TUIWidgetsPanel, TUIWidgetsText, TUIWidgetsList, TUIWidgetsScroll,
  TUIWidgetsSelectable, TUIWidgetsProgress, TUIWidgetsSpinner;

type
  { A read-only text pane that is selectable. A consumer writes this much:
    the rows it draws, and where column 0 of each row sits. }
  TSelectablePane = class(TSelectable)
  private
    FText: TTextBlock;
  public
    constructor Create(const ATheme: TTheme; const AText: string);
    destructor Destroy; override;
    function RowCount: Integer; override;
    function RowTextAt(ARow: Integer): UnicodeString; override;
    function RowWrapsAt(ARow: Integer): Boolean; override;
    procedure Render(const S: ISurface); override;
  end;

constructor TSelectablePane.Create(const ATheme: TTheme; const AText: string);
var
  Spans: array of TSpan;
begin
  inherited Create;
  { Selection is opt-in: a leaf that descends from TSelectable still has to ask
    for it, or re-parenting would make every text widget swallow clicks. }
  Selectable := True;
  SetLength(Spans, 1);
  { Explicit: AText is an AnsiString from the caller, and assigning it
    straight into a UnicodeString span is an implicit conversion - an error
    here, and a lossy one on a non-UTF-8 locale. }
  Spans[0].Text := UnicodeString(AText);
  Spans[0].Attr := ATheme.Text;
  FText := TTextBlock.Create(Spans, wmWord);
end;

destructor TSelectablePane.Destroy;
begin
  FText.Free;
  inherited Destroy;
end;

function TSelectablePane.RowCount: Integer;
begin
  if FBounds.W <= 0 then
    Exit(0);
  Result := Length(FText.WrappedRows(FBounds.W));
end;

function TSelectablePane.RowTextAt(ARow: Integer): UnicodeString;
var
  Rows: TWrappedRows;
begin
  Result := '';
  if FBounds.W <= 0 then
    Exit;
  Rows := FText.WrappedRows(FBounds.W);
  if (ARow >= 0) and (ARow <= High(Rows)) then
    Result := Rows[ARow];
end;

function TSelectablePane.RowWrapsAt(ARow: Integer): Boolean;
begin
  { A paragraph is one long soft-wrapped line, so every row but the last ended
    by wrapping. A copy must not insert newlines at those breaks. }
  Result := ARow < RowCount - 1;
end;

procedure TSelectablePane.Render(const S: ISurface);
begin
  FText.Arrange(FBounds);
  FText.Render(S);
  { The highlight RECOLOURS cells that are already drawn, so it must come after
    the text - never before. }
  RenderSelection(S);
end;

{ --- The app ------------------------------------------------------------ }

type
  TDemo = class
  public
    Panel: TPanel;
    List: TListView;
    Pane: TSelectablePane;
    Bar: TProgress;
    Spin: TSpinner;
  end;

const
  DemoText =
    'The TUI library is an immediate-mode terminal toolkit. Every frame renders ' +
    'the whole visible tree into a cell buffer and diffs it once at flush, so ' +
    'there is no invalidation graph to get wrong. Try dragging across this ' +
    'paragraph: the highlight follows your pointer and the text arrives on your ' +
    'clipboard when you let go.';

var
  Theme: TTheme;
  Style: TBoxStyle;
  Surface: TSurfaceVideo;
  Input: TInputSourceTerminal;
  App: TTuiApp;
  Root: TContainer;
  D: TDemo;
  Running: Boolean;

begin
  Theme := DarkTheme;
  Surface := TSurfaceVideo.Create;
  Input := TInputSourceTerminal.Create;
  D := TDemo.Create;

  { The list is fed strings directly - no domain record, which is the point of
    the library's boundary. }
  D.List := TListView.Create(Theme);
  D.List.AddItem('one');
  D.List.AddItem('two');
  D.List.AddItem('three');
  D.List.AddItem('four');
  D.List.AddItem('five');
  D.List.AddItem('six');
  D.List.AddItem('seven');

  D.Pane := TSelectablePane.Create(Theme, DemoText);

  D.Bar := TProgress.Create(20);
  D.Bar.Value := 40;
  D.Bar.Max := 100;

  D.Spin := TSpinner.Create(['|', '/', '-', '\\']);

  { A vertical stack: the list on top, the text pane filling the middle, and a
    one-row strip for the progress and spinner at the bottom. }
  Root := TContainer.Create([Fill(1)], [Fixed(8), Fill(1), Fixed(1)]);
  Root.Add(D.List, 0, 0);
  Root.Add(D.Pane, 0, 1);
  Root.Add(D.Bar, 0, 2);

  { TPanel takes a style: border, rounded corners, a title, padding. }
  Style := Default(TBoxStyle);
  Style.Border := True;
  Style.Rounded := True;
  Style.Title := ' TUI library ';
  Style.Padding := 1;
  D.Panel := TPanel.Create(Root, Theme, Style);
  Root := TContainer.Create([Fill(1)], [Fill(1)]);
  Root.Add(D.Panel, 0, 0);

  App := TTuiApp.Create(Surface, Input, Root, 16);
  try
    { Copy on mouse release is the default. Stated here because it is the
      behaviour a consumer will look for. }
    App.CopyOnRelease := True;
    Running := True;
    while Running do
      if not App.Step then
        Running := False;
  finally
    App.Free;
    Input := nil;
    Surface := nil;
  end;
end.
