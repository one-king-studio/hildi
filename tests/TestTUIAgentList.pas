unit TestTUIAgentList;
{ fpcunit tests for the agent-list widget (HildiAgentList): rows from
  a roster, selection movement, Enter firing OnSelect, and the empty state. All
  over TSurfaceMemory — no terminal. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  TUIBase, TUISurface,
  TUIInput, TUITheme,
  TUIWidget,
  HildiHarnessSubagent, HildiAgentList;

type
  TSelectRecorder = class
  public
    Ids: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnSelect(const ASessionId: string);
  end;

  TAgentListTest = class(TTestCase)
  private
    FRoster: TSubagentRoster;
    FSb: TAgentList;
    FRec: TSelectRecorder;
    function Surface(W, H: Integer): ISurface;
    function Key(AKind: TKeyKind): TInputEvent;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestAgentListRendersRows;
    procedure TestAgentListSelectionMoves;
    procedure TestAgentListEnterFiresSelect;
    procedure TestAgentListEmptyState;
    { The CTAs follow the same rule as the chat toolbar: the keybinding is dim,
      the action it performs is brighter. They used to be one uniformly amber
      string, so "ctrl+a" and "abort" read as a single word. }
    procedure TestAgentListHintDimsTheKeyAndBrightensTheAction;
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

function TAgentListTest.Surface(W, H: Integer): ISurface;
begin
  Result := TSurfaceMemory.Create(W, H);
end;

function TAgentListTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

procedure TAgentListTest.SetUp;
begin
  FRoster := TSubagentRoster.Create;
  FRec := TSelectRecorder.Create;
  FSb := TAgentList.Create(DarkTheme, FRoster);
  FSb.OnSelect := FRec.OnSelect;
end;

procedure TAgentListTest.TearDown;
begin
  FSb.Free;
  FRec.Free;
  FRoster.Free;
end;

procedure TAgentListTest.TestAgentListRendersRows;
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

procedure TAgentListTest.TestAgentListSelectionMoves;
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

procedure TAgentListTest.TestAgentListEnterFiresSelect;
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

procedure TAgentListTest.TestAgentListEmptyState;
begin
  FSb.Refresh;
  AssertEquals('no rows', 0, FSb.RowCount);
  AssertEquals('no selection', -1, FSb.Selected);
  { Enter on an empty agent list is not an activation. }
  AssertFalse('enter not handled', FSb.HandleEvent(Key(kkEnter)));
  AssertEquals('no selection fired', 0, FRec.Ids.Count);
end;

procedure TAgentListTest.TestAgentListHintDimsTheKeyAndBrightensTheAction;
var
  Mem: TSurfaceMemory;
  R: TRect;
  Row, X, HintX, ActX: Integer;
  Line: UnicodeString;
  KeyAttr, ActAttr: TAttr;
begin
  { Two children, so a row is selected and the three chords are offered. }
  FRoster.Apply('a', 'agent-a', 'running', 1000);
  FRoster.Apply('b', 'agent-b', 'running', 1000);
  FSb.SetHints('ctrl+a abort · ctrl+r release');
  FSb.Refresh;

  Mem := TSurfaceMemory.Create(60, 12);
  try
    R := Default(TRect);
    R.X := 0; R.Y := 0; R.W := 60; R.H := 12;
    FSb.Arrange(R);
    FSb.Render(Mem);
    { Find the CTA row and the columns of the key and the action. }
    HintX := -1;
    Row := -1;
    for Row := 0 to 11 do
    begin
      { Built with a placeholder for an empty cell: an unwritten cell's Ch is
        EMPTY, not a space, so concatenating Ch makes the string shorter than the
        row and every index after the first blank maps to the wrong column. That
        is the trap that made this assertion fail against correct code. }
      Line := '';
      for X := 0 to 59 do
        if Mem.CellAt(X, Row).Ch = '' then
          Line := Line + ' '
        else
          Line := Line + Mem.CellAt(X, Row).Ch;
      HintX := Pos(UnicodeString('ctrl+a'), Line);
      if HintX > 0 then
        Break;
    end;
    AssertTrue('the CTA key is drawn', HintX > 0);
    AssertTrue('the action follows it', Pos(UnicodeString('abort'), Line) > 0);

    KeyAttr := Mem.CellAt(HintX - 1, Row).Attr;
    ActX := Pos(UnicodeString('abort'), Line);
    ActAttr := Mem.CellAt(ActX - 1, Row).Attr;
    { The split must be VISIBLE: the box stays amber (it is not the prompt), but
      the action is not dim, so the two parts read as different things. }
    AssertTrue('the keybinding is dim', sfDim in KeyAttr.Style);
    AssertFalse('the action is not dim', sfDim in ActAttr.Style);
  finally
    Mem.Free;
  end;
end;

initialization
  RegisterTest(TAgentListTest);
end.
