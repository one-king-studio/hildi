unit test_tui_sessionsmodal;
{ fpcunit tests for the /sessions modal (hildegard.helper.tui.sessionsmodal):
  filtering, navigation, the archived toggle, and the row actions. Headless,
  against TSurfaceMemory and scripted input. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.theme, hildegard.helper.session,
  hildegard.helper.tui.sessionsmodal;

type
  TSessionsModalTest = class(TTestCase)
  private
    FModal: TSessionsModal;
    FSurface: TSurfaceMemory;
    FTheme: TTheme;
    FActionId: string;
    FActionKind: TSessionAction;
    FRenameId: string;
    FRenameText: string;
    procedure NoteAction(const ASessionId: string; AAction: TSessionAction);
    procedure NoteRename(const ASessionId, ANewTitle: string);
    procedure Render;
    function Key(AKind: TKeyKind): TInputEvent;
    function Ch(const AText: string): TInputEvent;
    function Row(const AId, ATitle: string; APinned, AArchived: Boolean): TSessionRow;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestListsRowsAndSelectsFirst;
    procedure TestFilterMatchesTitleKeywordAndId;
    procedure TestArchivedHiddenByDefaultAndToggled;
    procedure TestNavigationMovesSelection;
    procedure TestPinKeyRaisesTheAction;
    procedure TestRenameCapturesText;
    procedure TestEmptyIsDrawnNotCrashed;
  end;

implementation

procedure TSessionsModalTest.NoteAction(const ASessionId: string;
  AAction: TSessionAction);
begin
  FActionId := ASessionId;
  FActionKind := AAction;
end;

procedure TSessionsModalTest.NoteRename(const ASessionId, ANewTitle: string);
begin
  FRenameId := ASessionId;
  FRenameText := ANewTitle;
end;

procedure TSessionsModalTest.Render;
var
  Sz: TSize;
  Bounds: TRect;
begin
  Sz := Default(TSize);
  Sz.W := FSurface.Width;
  Sz.H := FSurface.Height;
  FModal.Measure(Sz);
  Bounds := Default(TRect);
  Bounds.W := FSurface.Width;
  Bounds.H := FSurface.Height;
  FModal.Arrange(Bounds);
  FModal.Render(FSurface);
end;

function TSessionsModalTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function TSessionsModalTest.Ch(const AText: string): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := UnicodeString(AText);
end;

function TSessionsModalTest.Row(const AId, ATitle: string; APinned,
  AArchived: Boolean): TSessionRow;
begin
  Result := Default(TSessionRow);
  Result.Id := AId;
  Result.Title := ATitle;
  Result.Pinned := APinned;
  Result.Archived := AArchived;
end;

procedure TSessionsModalTest.SetUp;
begin
  FSurface := TSurfaceMemory.Create(60, 20);
  FTheme := DarkTheme;
  FModal := TSessionsModal.Create(FTheme);
end;

procedure TSessionsModalTest.TearDown;
begin
  FModal.Free;
  FSurface.Free;
  FSurface := nil;
end;

procedure TSessionsModalTest.TestListsRowsAndSelectsFirst;
begin
  FModal.SetRows([Row('a', 'Alpha', False, False), Row('b', 'Beta', False, False)]);
  AssertEquals('two visible', 2, FModal.VisibleCount);
  AssertEquals('first selected', 'a', FModal.SelectedSessionId);
end;

procedure TSessionsModalTest.TestFilterMatchesTitleKeywordAndId;
var
  R: TSessionRow;
begin
  R := Row('deadbeef01', 'Fix the drain', False, False);
  SetLength(R.Keywords, 1);
  R.Keywords[0] := 'tui';
  FModal.SetRows([R, Row('cafe', 'Other', False, False)]);
  FModal.Filter := 'drain';
  AssertEquals('title matches', 1, FModal.VisibleCount);
  FModal.Filter := 'tui';
  AssertEquals('keyword matches', 1, FModal.VisibleCount);
  FModal.Filter := 'dead';
  AssertEquals('id matches', 1, FModal.VisibleCount);
  FModal.Filter := 'zzz';
  AssertEquals('no match', 0, FModal.VisibleCount);
end;

procedure TSessionsModalTest.TestArchivedHiddenByDefaultAndToggled;
begin
  FModal.SetRows([Row('a', 'Live', False, False),
    Row('b', 'Old', False, True)]);
  AssertEquals('archived hidden', 1, FModal.VisibleCount);
  FModal.ShowArchived := True;
  AssertEquals('archived shown', 2, FModal.VisibleCount);
end;

procedure TSessionsModalTest.TestNavigationMovesSelection;
begin
  FModal.SetRows([Row('a', 'A', False, False), Row('b', 'B', False, False),
    Row('c', 'C', False, False)]);
  FModal.HandleEvent(Key(kkDown));
  AssertEquals('moved to b', 'b', FModal.SelectedSessionId);
  FModal.HandleEvent(Key(kkEnd));
  AssertEquals('to the end', 'c', FModal.SelectedSessionId);
  FModal.HandleEvent(Key(kkHome));
  AssertEquals('to the top', 'a', FModal.SelectedSessionId);
  { Clamped at the top. }
  FModal.HandleEvent(Key(kkUp));
  AssertEquals('still at the top', 'a', FModal.SelectedSessionId);
end;

procedure TSessionsModalTest.TestPinKeyRaisesTheAction;
begin
  FModal.SetRows([Row('a', 'A', False, False), Row('b', 'B', False, False)]);
  FModal.OnAction := NoteAction;
  FModal.HandleEvent(Ch('p'));
  AssertEquals('pinned a', 'a', FActionId);
  AssertEquals('pin action', Ord(saTogglePin), Ord(FActionKind));
  FModal.HandleEvent(Ch('a'));
  AssertEquals('archived a', 'a', FActionId);
  AssertEquals('archive action', Ord(saToggleArchive), Ord(FActionKind));
end;

procedure TSessionsModalTest.TestRenameCapturesText;
begin
  FModal.SetRows([Row('a', 'A', False, False)]);
  FModal.OnRename := NoteRename;
  FModal.HandleEvent(Ch('r'));
  AssertTrue('renaming', FModal.Renaming);
  FModal.HandleEvent(Ch('h'));
  FModal.HandleEvent(Ch('i'));
  FModal.HandleEvent(Key(kkEnter));
  AssertFalse('rename ended', FModal.Renaming);
  AssertEquals('renamed a', 'a', FRenameId);
  AssertEquals('to hi', 'hi', FRenameText);
end;

procedure TSessionsModalTest.TestEmptyIsDrawnNotCrashed;
begin
  FModal.SetRows(nil);
  AssertEquals('no rows', 0, FModal.VisibleCount);
  Render;   // must not raise
  AssertTrue('rendered', True);
end;

initialization
  RegisterTest(TSessionsModalTest);
end.
