unit test_tui_widgets;
{ fpcunit tests for the widget kit: theme, single-child/panel, focus, button,
  and list. Headless, against TSurfaceMemory and scripted input. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.theme, hildegard.helper.tui.panel,
  hildegard.helper.tui.focus, hildegard.helper.tui.button,
  hildegard.helper.tui.list;

type
  { Records the widget protocol calls it receives. }
  TProbe = class(TWidget)
  private
    FW, FH: Integer;
  public
    MeasureCalls, ArrangeCalls, RenderCalls, EventCalls: Integer;
    LastBounds: TRect;
    constructor Create(AW, AH: Integer);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  TCount = class
  public
    N: Integer;
    procedure Bump(Sender: TObject);
  end;

  TThemeTest = class(TTestCase)
  published
    procedure TestDarkAndLightSetAllRoles;
  end;

  TSingleChildTest = class(TTestCase)
  published
    procedure TestForwardsProtocol;
  end;

  TPanelTest = class(TTestCase)
  published
    procedure TestBorderAndTitleRender;
    procedure TestBorderDrawsRightTitle;
    procedure TestRightTitleSkipsWhenTooNarrow;
    procedure TestPaddingInsetsChild;
    procedure TestBorderOffStillPads;
    procedure TestMeasureInflates;
  end;

  TFocusGroupTest = class(TTestCase)
  private
    FCount: TCount;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestTabCyclesWithWrap;
    procedure TestShiftTabReverses;
    procedure TestClickFocuses;
    procedure TestKeyGoesToFocused;
  end;

  TButtonTest = class(TTestCase)
  private
    FCount: TCount;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRendersCaption;
    procedure TestEnterFiresOnlyWhenFocused;
    procedure TestClickFires;
  end;

  TListTest = class(TTestCase)
  private
    FCount: TCount;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSelectionMovesAndClamps;
    procedure TestEnterActivatesWhenFocused;
    procedure TestSelectedRowUsesAccent;
  end;

implementation

{ module helpers }

function MakeRect(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function MakeKey(AKind: TKeyKind; AMods: TModifiers = []): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
  Result.Key.Mods := AMods;
end;

function MakeMouse(X, Y: Integer): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikMouse;
  Result.Mouse.Button := mbLeft;
  Result.Mouse.X := X;
  Result.Mouse.Y := Y;
end;

{ TProbe }

constructor TProbe.Create(AW, AH: Integer);
begin
  inherited Create;
  FW := AW;
  FH := AH;
end;

function TProbe.Measure(const AAvail: TSize): TSize;
begin
  Inc(MeasureCalls);
  Result := Default(TSize);
  Result.W := FW;
  Result.H := FH;
end;

procedure TProbe.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  Inc(ArrangeCalls);
  LastBounds := ABounds;
end;

procedure TProbe.Render(const S: ISurface);
begin
  Inc(RenderCalls);
end;

function TProbe.HandleEvent(const E: TInputEvent): Boolean;
begin
  Inc(EventCalls);
  Result := True;
end;

{ TCount }

procedure TCount.Bump(Sender: TObject);
begin
  Inc(N);
end;

{ TThemeTest }

procedure TThemeTest.TestDarkAndLightSetAllRoles;
var
  D, L: TTheme;
begin
  D := DarkTheme;
  L := LightTheme;
  AssertTrue('base fg differs', D.Base.Fg <> L.Base.Fg);
  AssertTrue('panel fg set', D.Panel.Fg <> 0);
  AssertTrue('border set', D.Border.Fg <> 0);
  AssertTrue('title set', D.Title.Fg <> 0);
  AssertTrue('text set', D.Text.Fg <> 0);
  AssertTrue('muted set', D.Muted.Fg <> 0);
  AssertTrue('accent set', D.Accent.Fg <> 0);
  AssertTrue('error set', D.Error.Fg <> 0);
  AssertTrue('success set', D.Success.Fg <> 0);
  { The UI paints its own background, chosen for the terminal's mode. }
  AssertTrue('base uses the screen background', sfScreenBg in D.Base.Style);
  AssertTrue('panel uses the screen background', sfScreenBg in D.Panel.Style);
  AssertTrue('text uses the screen background', sfScreenBg in D.Text.Style);
  AssertTrue('dark background set', D.Bg = DarkBg);
  AssertTrue('light background set', L.Bg = LightBg);
  AssertTrue('raised background set', D.RaisedBg <> D.Bg);
  AssertTrue('sunken background set', D.SunkenBg <> D.Bg);
  AssertTrue('warn role set', D.Warn.Fg <> 0);
  { Forcing a mode ignores the detected terminal background. }
  AssertTrue('forced dark', SelectTheme(tmDark, True).Bg = DarkBg);
  AssertTrue('forced light', SelectTheme(tmLight, False).Bg = LightBg);
  AssertTrue('auto dark', SelectTheme(tmAuto, False).Bg = DarkBg);
  AssertTrue('auto light', SelectTheme(tmAuto, True).Bg = LightBg);
end;

{ TSingleChildTest }

procedure TSingleChildTest.TestForwardsProtocol;
var
  Probe: TProbe;
  Wrap: TSingleChild;
  S: TSurfaceMemory;
begin
  Probe := TProbe.Create(4, 2);
  Wrap := TSingleChild.Create(Probe);
  S := TSurfaceMemory.Create(10, 5);
  try
    AssertEquals('measure forwarded', 4, Wrap.Measure(Default(TSize)).W);
    Wrap.Arrange(MakeRect(0, 0, 10, 5));
    AssertEquals('arrange forwarded', 1, Probe.ArrangeCalls);
    Wrap.Render(S);
    AssertEquals('render forwarded', 1, Probe.RenderCalls);
    AssertTrue('event forwarded', Wrap.HandleEvent(MakeKey(kkEnter)));
    AssertEquals('event count', 1, Probe.EventCalls);
  finally
    Wrap.Free;
    S.Free;
  end;
end;

{ TPanelTest }

procedure TPanelTest.TestBorderAndTitleRender;
var
  Probe: TProbe;
  Panel: TPanel;
  Style: TBoxStyle;
  S: TSurfaceMemory;
begin
  Probe := TProbe.Create(2, 1);
  Style := DefaultBoxStyle;
  Style.Title := 'Hi';
  Panel := TPanel.Create(Probe, DarkTheme, Style);
  S := TSurfaceMemory.Create(12, 5);
  try
    Panel.Arrange(MakeRect(0, 0, 12, 5));
    Panel.Render(S);
    AssertEquals('top-left corner', UnicodeString(WideChar($250C)),
      S.CellAt(0, 0).Ch);
    AssertEquals('bottom-right corner', UnicodeString(WideChar($2518)),
      S.CellAt(11, 4).Ch);
    AssertTrue('title shown', Pos('Hi', S.RowText(0, 0, 12)) > 0);
  finally
    Panel.Free;
    S.Free;
  end;
end;

procedure TPanelTest.TestBorderDrawsRightTitle;
var
  Probe: TProbe;
  Panel: TPanel;
  Style: TBoxStyle;
  S: TSurfaceMemory;
begin
  Probe := TProbe.Create(2, 1);
  Style := DefaultBoxStyle;
  Style.Title := 'left';
  Style.TitleRight := 'right';
  Panel := TPanel.Create(Probe, DarkTheme, Style);
  S := TSurfaceMemory.Create(30, 5);
  try
    Panel.Arrange(MakeRect(0, 0, 30, 5));
    Panel.Render(S);
    AssertTrue('left title shown', Pos('left', S.RowText(0, 0, 30)) > 0);
    AssertTrue('right title shown', Pos('right', S.RowText(0, 0, 30)) > 0);
    AssertTrue('left before right',
      Pos('left', S.RowText(0, 0, 30)) < Pos('right', S.RowText(0, 0, 30)));
    AssertEquals('right title ends before the corner',
      UnicodeString(WideChar($2510)), S.CellAt(29, 0).Ch);
  finally
    Panel.Free;
    S.Free;
  end;
end;

procedure TPanelTest.TestRightTitleSkipsWhenTooNarrow;
var
  Probe: TProbe;
  Panel: TPanel;
  Style: TBoxStyle;
  S: TSurfaceMemory;
begin
  Probe := TProbe.Create(2, 1);
  Style := DefaultBoxStyle;
  Style.Title := 'left';
  Style.TitleRight := 'right';
  Panel := TPanel.Create(Probe, DarkTheme, Style);
  S := TSurfaceMemory.Create(10, 5);
  try
    Panel.Arrange(MakeRect(0, 0, 10, 5));
    Panel.Render(S);
    AssertTrue('left title kept', Pos('left', S.RowText(0, 0, 10)) > 0);
    AssertFalse('right title skipped',
      Pos('right', S.RowText(0, 0, 10)) > 0);
  finally
    Panel.Free;
    S.Free;
  end;
end;

procedure TPanelTest.TestPaddingInsetsChild;
var
  Probe: TProbe;
  Panel: TPanel;
begin
  Probe := TProbe.Create(2, 1);
  Panel := TPanel.Create(Probe, DarkTheme, DefaultBoxStyle);
  try
    Panel.Arrange(MakeRect(0, 0, 12, 6));
    { border + padding = inset 2 }
    AssertEquals('child x', 2, Probe.LastBounds.X);
    AssertEquals('child y', 2, Probe.LastBounds.Y);
    AssertEquals('child width', 8, Probe.LastBounds.W);
    AssertEquals('child height', 2, Probe.LastBounds.H);
  finally
    Panel.Free;
  end;
end;

procedure TPanelTest.TestBorderOffStillPads;
var
  Probe: TProbe;
  Panel: TPanel;
  Style: TBoxStyle;
begin
  Probe := TProbe.Create(2, 1);
  Style := DefaultBoxStyle;
  Style.Border := False;
  Panel := TPanel.Create(Probe, DarkTheme, Style);
  try
    Panel.Arrange(MakeRect(0, 0, 12, 6));
    AssertEquals('child x inset by padding', 1, Probe.LastBounds.X);
    AssertEquals('child width', 10, Probe.LastBounds.W);
  finally
    Panel.Free;
  end;
end;

procedure TPanelTest.TestMeasureInflates;
var
  Probe: TProbe;
  Panel: TPanel;
  Sz: TSize;
begin
  Probe := TProbe.Create(4, 2);
  Panel := TPanel.Create(Probe, DarkTheme, DefaultBoxStyle);
  try
    Sz := Panel.Measure(Default(TSize));
    AssertEquals('width inflated by border+padding', 8, Sz.W);
    AssertEquals('height inflated', 6, Sz.H);
  finally
    Panel.Free;
  end;
end;

{ TFocusGroupTest }

procedure TFocusGroupTest.SetUp;
begin
  FCount := TCount.Create;
end;

procedure TFocusGroupTest.TearDown;
begin
  FCount.Free;
end;

procedure TFocusGroupTest.TestTabCyclesWithWrap;
var
  G: TFocusGroup;
  B1, B2: TButton;
begin
  G := TFocusGroup.Create([Fill(1)], [Auto, Auto]);
  B1 := TButton.Create('one', DarkTheme);
  B2 := TButton.Create('two', DarkTheme);
  try
    G.Add(B1, 0, 0);
    G.Add(B2, 0, 1);
    G.Arrange(MakeRect(0, 0, 20, 2));
    B1.Focused := True;
    G.HandleEvent(MakeKey(kkTab));
    AssertTrue('focus moved to two', B2.Focused);
    G.HandleEvent(MakeKey(kkTab));
    AssertTrue('wrapped to one', B1.Focused);
  finally
    G.Free;
  end;
end;

procedure TFocusGroupTest.TestShiftTabReverses;
var
  G: TFocusGroup;
  B1, B2: TButton;
begin
  G := TFocusGroup.Create([Fill(1)], [Auto, Auto]);
  B1 := TButton.Create('one', DarkTheme);
  B2 := TButton.Create('two', DarkTheme);
  try
    G.Add(B1, 0, 0);
    G.Add(B2, 0, 1);
    G.Arrange(MakeRect(0, 0, 20, 2));
    B1.Focused := True;
    G.HandleEvent(MakeKey(kkTab, [moShift]));
    AssertTrue('shift-tab wrapped to two', B2.Focused);
  finally
    G.Free;
  end;
end;

procedure TFocusGroupTest.TestClickFocuses;
var
  G: TFocusGroup;
  B1, B2: TButton;
begin
  G := TFocusGroup.Create([Fill(1)], [Auto, Auto]);
  B1 := TButton.Create('one', DarkTheme);
  B2 := TButton.Create('two', DarkTheme);
  try
    G.Add(B1, 0, 0);
    G.Add(B2, 0, 1);
    G.Arrange(MakeRect(0, 0, 20, 2));
    B1.Focused := True;
    G.HandleEvent(MakeMouse(1, 1));   { row 1 = the second button }
    AssertTrue('clicked two', B2.Focused);
    AssertFalse('one not focused', B1.Focused);
  finally
    G.Free;
  end;
end;

procedure TFocusGroupTest.TestKeyGoesToFocused;
var
  G: TFocusGroup;
  B1, B2: TButton;
begin
  G := TFocusGroup.Create([Fill(1)], [Auto, Auto]);
  B1 := TButton.Create('one', DarkTheme);
  B2 := TButton.Create('two', DarkTheme);
  try
    G.Add(B1, 0, 0);
    G.Add(B2, 0, 1);
    G.Arrange(MakeRect(0, 0, 20, 2));
    B1.OnClick := FCount.Bump;
    B2.OnClick := FCount.Bump;
    B2.Focused := True;
    G.HandleEvent(MakeKey(kkEnter));
    AssertEquals('focused button fired once', 1, FCount.N);
  finally
    G.Free;
  end;
end;

{ TButtonTest }

procedure TButtonTest.SetUp;
begin
  FCount := TCount.Create;
end;

procedure TButtonTest.TearDown;
begin
  FCount.Free;
end;

procedure TButtonTest.TestRendersCaption;
var
  B: TButton;
  S: TSurfaceMemory;
begin
  B := TButton.Create('OK', DarkTheme);
  S := TSurfaceMemory.Create(10, 1);
  try
    B.Arrange(MakeRect(0, 0, 10, 1));
    B.Render(S);
    AssertEquals('label', '[ OK ]', S.RowText(0, 0, 6));
  finally
    B.Free;
    S.Free;
  end;
end;

procedure TButtonTest.TestEnterFiresOnlyWhenFocused;
var
  B: TButton;
begin
  B := TButton.Create('OK', DarkTheme);
  try
    B.OnClick := FCount.Bump;
    B.HandleEvent(MakeKey(kkEnter));
    AssertEquals('unfocused does not fire', 0, FCount.N);
    B.Focused := True;
    B.HandleEvent(MakeKey(kkEnter));
    AssertEquals('focused fires', 1, FCount.N);
  finally
    B.Free;
  end;
end;

procedure TButtonTest.TestClickFires;
var
  B: TButton;
begin
  B := TButton.Create('OK', DarkTheme);
  try
    B.Arrange(MakeRect(0, 0, 10, 1));
    B.OnClick := FCount.Bump;
    B.HandleEvent(MakeMouse(1, 0));
    AssertEquals('click fires', 1, FCount.N);
  finally
    B.Free;
  end;
end;

{ TListTest }

procedure TListTest.SetUp;
begin
  FCount := TCount.Create;
end;

procedure TListTest.TearDown;
begin
  FCount.Free;
end;

procedure TListTest.TestSelectionMovesAndClamps;
var
  L: TListView;
begin
  L := TListView.Create(DarkTheme);
  try
    L.AddItem('a');
    L.AddItem('b');
    L.AddItem('c');
    AssertEquals('starts at first', 0, L.Selected);
    L.HandleEvent(MakeKey(kkDown));
    AssertEquals('down', 1, L.Selected);
    L.HandleEvent(MakeKey(kkEnd));
    AssertEquals('end', 2, L.Selected);
    L.HandleEvent(MakeKey(kkDown));
    AssertEquals('clamps at end', 2, L.Selected);
    L.HandleEvent(MakeKey(kkHome));
    AssertEquals('home', 0, L.Selected);
    L.HandleEvent(MakeKey(kkUp));
    AssertEquals('clamps at start', 0, L.Selected);
  finally
    L.Free;
  end;
end;

procedure TListTest.TestEnterActivatesWhenFocused;
var
  L: TListView;
begin
  L := TListView.Create(DarkTheme);
  try
    L.AddItem('a');
    L.OnActivate := FCount.Bump;
    L.HandleEvent(MakeKey(kkEnter));
    AssertEquals('unfocused does not activate', 0, FCount.N);
    L.Focused := True;
    L.HandleEvent(MakeKey(kkEnter));
    AssertEquals('focused activates', 1, FCount.N);
  finally
    L.Free;
  end;
end;

procedure TListTest.TestSelectedRowUsesAccent;
var
  L: TListView;
  S: TSurfaceMemory;
begin
  L := TListView.Create(DarkTheme);
  S := TSurfaceMemory.Create(10, 2);
  try
    L.AddItem('a');
    L.AddItem('b');
    L.Arrange(MakeRect(0, 0, 10, 2));
    L.Render(S);
    AssertEquals('selected row uses accent fg', DarkTheme.Accent.Fg,
      S.CellAt(0, 0).Attr.Fg);
    AssertEquals('unselected row uses text fg', DarkTheme.Text.Fg,
      S.CellAt(0, 1).Attr.Fg);
  finally
    L.Free;
    S.Free;
  end;
end;

initialization
  RegisterTest(TThemeTest);
  RegisterTest(TSingleChildTest);
  RegisterTest(TPanelTest);
  RegisterTest(TFocusGroupTest);
  RegisterTest(TButtonTest);
  RegisterTest(TListTest);

end.
