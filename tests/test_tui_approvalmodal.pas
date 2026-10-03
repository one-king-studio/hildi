unit test_tui_approvalmodal;
{ fpcunit tests for hildegard.helper.tui.approvalmodal: option selection, scope,
  deny, and safe handling of an empty ask. No terminal. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.theme,
  hildegard.helper.approval, hildegard.helper.tui.approvalmodal;

type
  TChoiceRecorder = class
  public
    Count: Integer;
    Last: TApprovalChoice;
    procedure OnChoose(const AChoice: TApprovalChoice);
  end;

  TApprovalModalTest = class(TTestCase)
  private
    FRecorder: TChoiceRecorder;
    function MakeAsk(ACount: Integer): TApprovalAsk;
    function Key(AKind: TKeyKind): TInputEvent;
    function Ch(const AText: string): TInputEvent;
    function Rc(AW, AH: Integer): TRect;
    function Mouse(AX, AY: Integer; AButton: TMouseButton): TInputEvent;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRendersSummaryAndOptions;
    procedure TestModalTitlesAndBorders;
    procedure TestModalDefaultWidthIsWide;
    procedure TestModalMouseHoverBrightens;
    procedure TestModalClickSelectsWithoutAccepting;
    procedure TestModalFooterClickAcceptsAndDenies;
    procedure TestModalActionsKeepClearOfTheBorder;
    procedure TestModalMarksTheSelectedChoice;
    procedure TestModalKeybindingsAreRightAlignedAndDim;
    procedure TestModalShowsTheScopeAndFooter;
    procedure TestModalDetailsUseTheSunkenBackground;
    procedure TestArrowAndEnterChooses;
    procedure TestNumberSelectsWithoutAccepting;
    procedure TestEscapeDenies;
    procedure TestScopeKeyIsUsed;
    procedure TestTabCyclesScope;
    procedure TestZeroOptionAskDeniesSafely;
    procedure TestAnsweredIgnoresFurtherInput;
  end;

implementation

procedure TChoiceRecorder.OnChoose(const AChoice: TApprovalChoice);
begin
  Inc(Count);
  Last := AChoice;
end;

procedure TApprovalModalTest.SetUp;
begin
  FRecorder := TChoiceRecorder.Create;
end;

procedure TApprovalModalTest.TearDown;
begin
  FRecorder.Free;
end;

function TApprovalModalTest.MakeAsk(ACount: Integer): TApprovalAsk;
var
  I: Integer;
  Option: TApprovalOption;
begin
  Result := Default(TApprovalAsk);
  Result.Summary := 'rm -rf build/';
  Result.Subject.Ref := 'run_command:rm';
  SetLength(Result.Options, ACount);
  for I := 0 to ACount - 1 do
  begin
    Option := Default(TApprovalOption);
    Option.Key := 'opt' + IntToStr(I + 1);
    Option.Caption := 'Option ' + IntToStr(I + 1);
    Option.Persists := False;
    Result.Options[I] := Option;
  end;
end;

function TApprovalModalTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function TApprovalModalTest.Ch(const AText: string): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := UnicodeString(AText);
end;

function TApprovalModalTest.Rc(AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.W := AW;
  Result.H := AH;
end;

function TApprovalModalTest.Mouse(AX, AY: Integer;
  AButton: TMouseButton): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikMouse;
  Result.Mouse.X := AX;
  Result.Mouse.Y := AY;
  Result.Mouse.Button := AButton;
end;

procedure TApprovalModalTest.TestRendersSummaryAndOptions;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  Surface := TSurfaceMemory.Create(40, 10);
  try
    Modal.Arrange(Rc(40, 10));
    Modal.Render(Surface);
    AssertTrue('summary in the details band',
      Pos('rm -rf build/', Surface.RowText(1, 0, 40)) > 0);
    AssertTrue('option 1 shown', Pos('Option 1', Surface.RowText(3, 0, 40)) > 0);
    AssertTrue('option 2 shown', Pos('Option 2', Surface.RowText(4, 0, 40)) > 0);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalTitlesAndBorders;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  Surface := TSurfaceMemory.Create(40, 10);
  try
    Modal.Arrange(Rc(40, 10));
    Modal.Render(Surface);
    AssertTrue('title in the top border',
      Pos('Approval needed', Surface.RowText(0, 0, 40)) > 0);
    AssertTrue('rounded top-left (U+256D)',
      Ord(Surface.CellAt(0, 0).Ch[1]) = $256D);
    AssertTrue('heavy bottom edge (U+2550)',
      Ord(Surface.CellAt(10, 9).Ch[1]) = $2550);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalDefaultWidthIsWide;
var
  Modal: TApprovalModal;
  Sz: TSize;
begin
  Modal := TApprovalModal.Create(MakeAsk(1));
  try
    Sz := Default(TSize);
    Sz.W := 200;
    Sz.H := 40;
    AssertEquals('a short ask still gets a 55-column dialog', 55,
      Modal.Measure(Sz).W);
  finally
    Modal.Free;
  end;
end;

procedure TApprovalModalTest.TestModalMouseHoverBrightens;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  Surface := TSurfaceMemory.Create(40, 10);
  try
    Modal.Arrange(Rc(40, 10));
    Modal.Render(Surface);
    AssertEquals('unselected is normal', DarkTheme.Text.Fg,
      Surface.CellAt(4, 4).Attr.Fg);

    AssertTrue('hover handled', Modal.HandleEvent(Mouse(5, 4, mbNone)));
    Modal.Render(Surface);
    AssertEquals('hovered option brightens', DarkTheme.AccentSoft.Fg,
      Surface.CellAt(4, 4).Attr.Fg);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalClickSelectsWithoutAccepting;
var
  Modal: TApprovalModal;
begin
  Modal := TApprovalModal.Create(MakeAsk(3));
  try
    Modal.Arrange(Rc(40, 12));
    Modal.OnChoose := FRecorder.OnChoose;
    { Row 4 is the second option. }
    AssertTrue('click handled', Modal.HandleEvent(Mouse(6, 4, mbLeft)));
    AssertEquals('clicked option selected', 1, Modal.Selected);
    AssertEquals('clicking does not accept', 0, FRecorder.Count);
    AssertFalse('not answered', Modal.Answered);
  finally
    Modal.Free;
  end;
end;

procedure TApprovalModalTest.TestModalFooterClickAcceptsAndDenies;
var
  Modal: TApprovalModal;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  try
    Modal.Arrange(Rc(40, 10));
    Modal.OnChoose := FRecorder.OnChoose;
    { The footer is row 8: accept spans columns 14..25, deny 29..36. }
    AssertTrue('accept click', Modal.HandleEvent(Mouse(18, 8, mbLeft)));
    AssertEquals('accepted', 1, FRecorder.Count);
    AssertTrue('allowed', FRecorder.Last.Allowed);
  finally
    Modal.Free;
  end;

  FRecorder.Count := 0;
  Modal := TApprovalModal.Create(MakeAsk(2));
  try
    Modal.Arrange(Rc(40, 10));
    Modal.OnChoose := FRecorder.OnChoose;
    AssertTrue('deny click', Modal.HandleEvent(Mouse(32, 8, mbLeft)));
    AssertEquals('denied', 1, FRecorder.Count);
    AssertFalse('denied', FRecorder.Last.Allowed);
  finally
    Modal.Free;
  end;
end;

procedure TApprovalModalTest.TestModalActionsKeepClearOfTheBorder;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  Surface := TSurfaceMemory.Create(40, 10);
  try
    Modal.Arrange(Rc(40, 10));
    Modal.Render(Surface);
    { The footer ends two columns short of the border at column 39. }
    AssertEquals('last action character', 'y',
      string(Surface.CellAt(36, 8).Ch));
    AssertEquals('one column clear', '', Surface.CellAt(37, 8).Ch);
    AssertEquals('two columns clear', '', Surface.CellAt(38, 8).Ch);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;
procedure TApprovalModalTest.TestModalMarksTheSelectedChoice;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  Surface := TSurfaceMemory.Create(40, 10);
  try
    Modal.Arrange(Rc(40, 10));
    Modal.Render(Surface);
    AssertTrue('selected has an arrow',
      Pos('→ Option 1', Surface.RowText(3, 0, 40)) > 0);
    AssertTrue('unselected has a bullet',
      Pos('◦ Option 2', Surface.RowText(4, 0, 40)) > 0);
    AssertEquals('selected text uses the soft accent', DarkTheme.AccentSoft.Fg,
      Surface.CellAt(4, 3).Attr.Fg);

    Modal.HandleEvent(Key(kkDown));
    Modal.Render(Surface);
    AssertTrue('arrow moved',
      Pos('→ Option 2', Surface.RowText(4, 0, 40)) > 0);
    AssertTrue('the first is now a bullet',
      Pos('◦ Option 1', Surface.RowText(3, 0, 40)) > 0);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalKeybindingsAreRightAlignedAndDim;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  Surface := TSurfaceMemory.Create(40, 10);
  try
    Modal.Arrange(Rc(40, 10));
    Modal.Render(Surface);
    { The box is 40 wide and right-aligned keys keep two columns clear of the
      border at 39, so the option key is at 36 and the scope keys start at 26. }
    AssertEquals('option key right aligned', '1',
      string(Surface.CellAt(36, 3).Ch));
    AssertTrue('option key is dim',
      sfDim in Surface.CellAt(36, 3).Attr.Style);
    AssertTrue('scope keys are right aligned and dim',
      (Surface.CellAt(26, 6).Ch = 't') and
      (sfDim in Surface.CellAt(26, 6).Attr.Style));
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalShowsTheScopeAndFooter;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  Surface := TSurfaceMemory.Create(40, 10);
  try
    Modal.Arrange(Rc(40, 10));
    Modal.Render(Surface);
    AssertTrue('scope line',
      Pos('scope: workspace', Surface.RowText(6, 0, 40)) > 0);
    AssertTrue('scope keys',
      Pos('tab / g w s', Surface.RowText(6, 0, 40)) > 0);
    AssertTrue('footer accept', Pos('enter accept', Surface.RowText(8, 0, 40)) > 0);
    AssertTrue('footer deny', Pos('esc deny', Surface.RowText(8, 0, 40)) > 0);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalDetailsUseTheSunkenBackground;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  Surface := TSurfaceMemory.Create(40, 10);
  try
    Modal.Arrange(Rc(40, 10));
    Modal.Render(Surface);
    AssertEquals('details band on the sunken background',
      DarkTheme.SunkenBg, Surface.CellAt(5, 1).Attr.Bg);
    { The modal is drawn after the dim, so its own cells are not dimmed. }
    AssertFalse('the modal is not dimmed',
      sfDim in Surface.CellAt(5, 1).Attr.Style);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestArrowAndEnterChooses;
var
  Modal: TApprovalModal;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  try
    Modal.OnChoose := FRecorder.OnChoose;
    Modal.HandleEvent(Key(kkDown));
    Modal.HandleEvent(Key(kkEnter));
    AssertEquals('chose once', 1, FRecorder.Count);
    AssertTrue('allowed', FRecorder.Last.Allowed);
    AssertEquals('second option', 'opt2', FRecorder.Last.OptionKey);
    AssertTrue('answered', Modal.Answered);
  finally
    Modal.Free;
  end;
end;

procedure TApprovalModalTest.TestNumberSelectsWithoutAccepting;
var
  Modal: TApprovalModal;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  try
    Modal.OnChoose := FRecorder.OnChoose;
    Modal.HandleEvent(Ch('2'));
    { A digit moves the selection; accepting stays a separate action. }
    AssertEquals('selected option 2', 1, Modal.Selected);
    AssertEquals('not answered', 0, FRecorder.Count);
    AssertFalse('not answered', Modal.Answered);

    Modal.HandleEvent(Key(kkEnter));
    AssertEquals('chose once', 1, FRecorder.Count);
    AssertEquals('option 2', 'opt2', FRecorder.Last.OptionKey);
  finally
    Modal.Free;
  end;
end;

procedure TApprovalModalTest.TestEscapeDenies;
var
  Modal: TApprovalModal;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  try
    Modal.OnChoose := FRecorder.OnChoose;
    Modal.HandleEvent(Key(kkEscape));
    AssertEquals('answered once', 1, FRecorder.Count);
    AssertFalse('denied', FRecorder.Last.Allowed);
    AssertEquals('no option', '', FRecorder.Last.OptionKey);
  finally
    Modal.Free;
  end;
end;

procedure TApprovalModalTest.TestScopeKeyIsUsed;
var
  Modal: TApprovalModal;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  try
    Modal.OnChoose := FRecorder.OnChoose;
    Modal.HandleEvent(Ch('g'));
    Modal.HandleEvent(Ch('1'));
    AssertEquals('global scope', Ord(asGlobal), Ord(FRecorder.Last.Scope));
  finally
    Modal.Free;
  end;
end;

procedure TApprovalModalTest.TestTabCyclesScope;
var
  Modal: TApprovalModal;
begin
  Modal := TApprovalModal.Create(MakeAsk(1));
  try
    Modal.OnChoose := FRecorder.OnChoose;
    Modal.HandleEvent(Key(kkTab));
    Modal.HandleEvent(Key(kkEnter));
    AssertEquals('tab -> session', Ord(asSession), Ord(FRecorder.Last.Scope));
  finally
    Modal.Free;
  end;

  Modal := TApprovalModal.Create(MakeAsk(1));
  try
    Modal.OnChoose := FRecorder.OnChoose;
    Modal.HandleEvent(Key(kkTab));
    Modal.HandleEvent(Key(kkTab));
    Modal.HandleEvent(Key(kkEnter));
    AssertEquals('tab tab -> global', Ord(asGlobal), Ord(FRecorder.Last.Scope));
  finally
    Modal.Free;
  end;
end;


procedure TApprovalModalTest.TestZeroOptionAskDeniesSafely;
var
  Modal: TApprovalModal;
begin
  Modal := TApprovalModal.Create(MakeAsk(0));
  try
    Modal.OnChoose := FRecorder.OnChoose;
    Modal.HandleEvent(Key(kkEnter));
    AssertEquals('answered', 1, FRecorder.Count);
    AssertFalse('denied', FRecorder.Last.Allowed);
  finally
    Modal.Free;
  end;
end;

procedure TApprovalModalTest.TestAnsweredIgnoresFurtherInput;
var
  Modal: TApprovalModal;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  try
    Modal.OnChoose := FRecorder.OnChoose;
    Modal.HandleEvent(Key(kkEnter));
    Modal.HandleEvent(Key(kkEnter));
    Modal.HandleEvent(Ch('2'));
    AssertEquals('only one choice', 1, FRecorder.Count);
  finally
    Modal.Free;
  end;
end;

initialization
  RegisterTest(TApprovalModalTest);

end.
