unit test_tui_sidebar;
{ fpcunit tests for the sidebar widget (tui.widgets.sidebar): rows from
  a roster, selection movement, Enter firing OnSelect, and the empty state. All
  over TSurfaceMemory — no terminal. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  tui.base, tui.surface,
  tui.input, tui.theme,
  tui.widget,
  hildegard.helper.harness.subagent, tui.widgets.sidebar;

type
  TSelectRecorder = class
  public
    Ids: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnSelect(const ASessionId: string);
  end;

  TSidebarTest = class(TTestCase)
  private
    FRoster: TSubagentRoster;
    FSb: TSidebar;
    FRec: TSelectRecorder;
    function Surface(W, H: Integer): ISurface;
    function Key(AKind: TKeyKind): TInputEvent;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSidebarRendersRows;
    procedure TestSidebarSelectionMoves;
    procedure TestSidebarEnterFiresSelect;
    procedure TestSidebarEmptyState;
  end;

implementation

constructor TSelectRecorder.Create;
begin
  inherited Create;
  Ids := TStringList.Create;
end;

destructor TSelectRecorder.Destroy;
begin
  Ids.Free;
  inherited Destroy;
end;

procedure TSelectRecorder.OnSelect(const ASessionId: string);
begin
  Ids.Add(ASessionId);
end;

function TSidebarTest.Surface(W, H: Integer): ISurface;
begin
  Result := TSurfaceMemory.Create(W, H);
end;

function TSidebarTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

procedure TSidebarTest.SetUp;
begin
  FRoster := TSubagentRoster.Create;
  FRec := TSelectRecorder.Create;
  FSb := TSidebar.Create(DarkTheme, FRoster);
  FSb.OnSelect := FRec.OnSelect;
end;

procedure TSidebarTest.TearDown;
begin
  FSb.Free;
  FRec.Free;
  FRoster.Free;
end;

procedure TSidebarTest.TestSidebarRendersRows;
var
  S: ISurface;
  Avail: TSize;
begin
  FRoster.Apply('a', 'alpha', 'running', 1000);
  FRoster.Apply('b', 'beta', 'completed', 1000);
  FSb.Refresh;
  AssertEquals('two rows', 2, FSb.RowCount);
  S := Surface(20, 4);
  FSb.Arrange(Default(TRect));
  FSb.Render(S);
  { The widget measures to fit its rows within the available width. }
  Avail := Default(TSize);
  Avail.W := 20;
  Avail.H := 10;
  AssertTrue('measure width', FSb.Measure(Avail).W > 0);
  AssertEquals('measure height', 2, FSb.Measure(Avail).H);
end;

procedure TSidebarTest.TestSidebarSelectionMoves;
begin
  FRoster.Apply('a', 'alpha', 'running', 1000);
  FRoster.Apply('b', 'beta', 'running', 1000);
  FSb.Refresh;
  AssertEquals('starts at 0', 0, FSb.Selected);
  AssertTrue('down handled', FSb.HandleEvent(Key(kkDown)));
  AssertEquals('moved to 1', 1, FSb.Selected);
  AssertTrue('down handled', FSb.HandleEvent(Key(kkDown)));
  AssertEquals('clamped at last', 1, FSb.Selected);
  AssertTrue('up handled', FSb.HandleEvent(Key(kkUp)));
  AssertEquals('moved back to 0', 0, FSb.Selected);
end;

procedure TSidebarTest.TestSidebarEnterFiresSelect;
begin
  FRoster.Apply('a', 'alpha', 'running', 1000);
  FRoster.Apply('b', 'beta', 'running', 1000);
  FSb.Refresh;
  { Navigation LOADS the session, per the operator: "when the user navigates on
    the list, the selected session is loaded into the chat stream". So Down fires
    OnSelect, and Enter fires it again for the row already selected. This test
    used to expect exactly one selection, which pinned the older contract where
    only Enter loaded - that made the list a picker you had to operate twice. }
  FSb.HandleEvent(Key(kkDown));
  AssertEquals('navigating loads the session', 1, FRec.Ids.Count);
  AssertEquals('loaded b', 'b', FRec.Ids[0]);

  AssertTrue('enter handled', FSb.HandleEvent(Key(kkEnter)));
  AssertEquals('enter re-selects the same row', 2, FRec.Ids.Count);
  AssertEquals('still b', 'b', FRec.Ids[1]);
end;

procedure TSidebarTest.TestSidebarEmptyState;
begin
  FSb.Refresh;
  AssertEquals('no rows', 0, FSb.RowCount);
  AssertEquals('no selection', -1, FSb.Selected);
  { Enter on an empty sidebar is not an activation. }
  AssertFalse('enter not handled', FSb.HandleEvent(Key(kkEnter)));
  AssertEquals('no selection fired', 0, FRec.Ids.Count);
end;

initialization
  RegisterTest(TSidebarTest);
end.
