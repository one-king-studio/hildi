unit test_tui_approvalmodal;
{ fpcunit tests for tui.widgets.approvalmodal: option selection, scope,
  deny, the reason line, wrapped/compacted details, and safe handling of an
  empty ask. No terminal. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  tui.base, tui.input,
  tui.surface, tui.widget,
  tui.theme,
  hildegard.helper.approval, tui.widgets.approvalmodal;

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
    { The height the modal wants at the test width (40), so the arranged box
      matches its content and the bottom border lands on the last row. }
    function MeasuredHeight(AModal: TApprovalModal): Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRendersSummaryAndOptions;
    { A command that cd's must show where its effects land. }
    procedure TestRendersTheWorkingDirectoryWhenChanged;
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
    procedure TestModalShowsTheScriptAndBoldsTheFocus;
    procedure TestModalEffectAskShowsThePathAndTheScript;
    procedure TestModalScrollsToTheFocus;
    procedure TestModalScrollKeysAndWheel;
    procedure TestModalShowsTheReason;
    procedure TestModalReasonPlaceholder;
    procedure TestModalReasonWraps;
    procedure TestModalWrapsLongDetails;
    procedure TestModalCompactsVeryLongDetails;
    procedure TestModalKeepsEdgePadding;
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

function TApprovalModalTest.MeasuredHeight(AModal: TApprovalModal): Integer;
var
  Sz: TSize;
begin
  Sz := Default(TSize);
  Sz.W := 40;
  Sz.H := 60;
  Result := AModal.Measure(Sz).H;
end;

{ With the reason line and a one-line details band, the rows are: title 0,
  reason 1, details 2, blank 3, options from 4, blank, scope, separator, footer,
  bottom. Tests use a tall surface so nothing clips. }

procedure TApprovalModalTest.TestRendersTheWorkingDirectoryWhenChanged;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
  A: TApprovalAsk;
  Found: Boolean;
  Row: Integer;
begin
  { `cd /tmp && touch test.txt` writes where the operator cannot infer from the
    command text. Approving a write without knowing WHERE is approving blind. }
  A := MakeAsk(2);
  A.WorkDir := '/tmp';
  Modal := TApprovalModal.Create(A);
  Surface := TSurfaceMemory.Create(60, 24);
  try
    Modal.Arrange(Rc(60, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    Found := False;
    for Row := 0 to 10 do
      if Pos('/tmp', Surface.RowText(Row, 0, 60)) > 0 then
        Found := True;
    AssertTrue('the working directory is shown', Found);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestRendersSummaryAndOptions;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    AssertTrue('summary in the details band',
      Pos('rm -rf build/', Surface.RowText(3, 0, 40)) > 0);
    AssertTrue('option 1 shown', Pos('Option 1', Surface.RowText(5, 0, 40)) > 0);
    AssertTrue('option 2 shown', Pos('Option 2', Surface.RowText(6, 0, 40)) > 0);
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
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    AssertTrue('title in the top border',
      Pos('Approval needed', Surface.RowText(0, 0, 40)) > 0);
    AssertTrue('rounded top-left (U+256D)',
      Ord(Surface.CellAt(0, 0).Ch[1]) = $256D);
    AssertTrue('heavy bottom edge (U+2550)',
      Ord(Surface.CellAt(10, 11).Ch[1]) = $2550);
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
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    { Option 2 (row 6) is unselected and normal. }
    AssertEquals('unselected is normal', DarkTheme.Text.Fg,
      Surface.CellAt(4, 6).Attr.Fg);

    AssertTrue('hover handled', Modal.HandleEvent(Mouse(5, 6, mbNone)));
    Modal.Render(Surface);
    AssertEquals('hovered option brightens', DarkTheme.AccentSoft.Fg,
      Surface.CellAt(4, 6).Attr.Fg);
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
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.OnChoose := FRecorder.OnChoose;
    { Row 6 is the second option. }
    AssertTrue('click handled', Modal.HandleEvent(Mouse(6, 6, mbLeft)));
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
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.OnChoose := FRecorder.OnChoose;
    { The footer is row 10: accept spans columns 14..25, deny 29..36. }
    AssertTrue('accept click', Modal.HandleEvent(Mouse(18, 10, mbLeft)));
    AssertEquals('accepted', 1, FRecorder.Count);
    AssertTrue('allowed', FRecorder.Last.Allowed);
  finally
    Modal.Free;
  end;

  FRecorder.Count := 0;
  Modal := TApprovalModal.Create(MakeAsk(2));
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.OnChoose := FRecorder.OnChoose;
    AssertTrue('deny click', Modal.HandleEvent(Mouse(32, 10, mbLeft)));
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
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    { The footer ends two columns short of the border at column 39. }
    AssertEquals('last action character', 'y',
      string(Surface.CellAt(36, 10).Ch));
    AssertEquals('one column clear', '', Surface.CellAt(37, 10).Ch);
    AssertEquals('two columns clear', '', Surface.CellAt(38, 10).Ch);
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
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    AssertTrue('selected has an arrow',
      Pos('→ Option 1', Surface.RowText(5, 0, 40)) > 0);
    AssertTrue('unselected has a bullet',
      Pos('◦ Option 2', Surface.RowText(6, 0, 40)) > 0);
    AssertEquals('selected text uses the soft accent', DarkTheme.AccentSoft.Fg,
      Surface.CellAt(4, 5).Attr.Fg);

    Modal.HandleEvent(Key(kkDown));
    Modal.Render(Surface);
    AssertTrue('arrow moved',
      Pos('→ Option 2', Surface.RowText(6, 0, 40)) > 0);
    AssertTrue('the first is now a bullet',
      Pos('◦ Option 1', Surface.RowText(5, 0, 40)) > 0);
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
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    { The box is 40 wide and right-aligned keys keep two columns clear of the
      border at 39, so the option key is at 36 and the scope keys start at 26. }
    AssertEquals('option key right aligned', '1',
      string(Surface.CellAt(36, 5).Ch));
    AssertTrue('option key is dim',
      sfDim in Surface.CellAt(36, 5).Attr.Style);
    AssertTrue('scope keys are right aligned and dim',
      (Surface.CellAt(26, 8).Ch = 't') and
      (sfDim in Surface.CellAt(26, 8).Attr.Style));
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
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    AssertTrue('scope line',
      Pos('scope: workspace', Surface.RowText(8, 0, 40)) > 0);
    AssertTrue('scope keys',
      Pos('tab / g w s', Surface.RowText(8, 0, 40)) > 0);
    AssertTrue('footer accept', Pos('enter accept', Surface.RowText(10, 0, 40)) > 0);
    AssertTrue('footer deny', Pos('esc deny', Surface.RowText(10, 0, 40)) > 0);
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
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    AssertEquals('details band on the sunken background',
      DarkTheme.SunkenBg, Surface.CellAt(5, 3).Attr.Bg);
    { The modal is drawn after the dim, so its own cells are not dimmed. }
    AssertFalse('the modal is not dimmed',
      sfDim in Surface.CellAt(5, 3).Attr.Style);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

function ScriptAsk(const AScript: string; const AFocus: string): TApprovalAsk;
begin
  Result := Default(TApprovalAsk);
  Result.Summary := AFocus;
  Result.Script := AScript;
  Result.FocusStart := Pos(AFocus, AScript);
  Result.FocusLen := Length(AFocus);
  SetLength(Result.Options, 2);
  Result.Options[0].Key := 'once';
  Result.Options[0].Caption := 'allow once';
  Result.Options[1].Key := 'any';
  Result.Options[1].Caption := 'always';
end;

procedure TApprovalModalTest.TestModalShowsTheScriptAndBoldsTheFocus;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
  Row, Ch: UnicodeString;
  X, ColR, ColE: Integer;
begin
  Modal := TApprovalModal.Create(ScriptAsk('echo hi; rm -rf build/',
    'rm -rf build/'));
  Surface := TSurfaceMemory.Create(60, 20);
  try
    Modal.Arrange(Rc(60, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    Row := Surface.RowText(3, 0, 60);
    { The whole command, not just the segment. }
    AssertTrue('the script is shown',
      Pos(UnicodeString('echo hi; rm -rf build/'), Row) > 0);
    { No arrow marks the focus row any more: it shifted the script one column
      whenever the focus moved, which read as the dialog resizing. The span is
      bold, which the assertions below verify. }
    AssertFalse('the focus row carries no arrow',
      Pos(UnicodeString(WideChar($2192)), Row) > 0);
    { Only the focus span is bold: the segment is, the command before it is
      not. (Cells, not string offsets: an erased cell takes no string index.) }
    ColR := -1;
    ColE := -1;
    for X := 0 to 59 do
    begin
      Ch := Surface.CellAt(X, 3).Ch;
      if (ColE < 0) and (Ch = 'e') then
        ColE := X;
      if (ColR < 0) and (Ch = 'r') then
        ColR := X;
    end;
    AssertTrue('found the focus text', ColR > 0);
    AssertTrue('focus start is bold',
      sfBold in Surface.CellAt(ColR, 3).Attr.Style);
    AssertFalse('the focus is not dimmed',
      sfDim in Surface.CellAt(ColR, 3).Attr.Style);
    AssertTrue('found the leading text', ColE > 0);
    AssertFalse('text before the focus is not bold',
      sfBold in Surface.CellAt(ColE, 3).Attr.Style);
    AssertTrue('text before the focus is dimmed',
      sfDim in Surface.CellAt(ColE, 3).Attr.Style);
    { Rendition only: the focus keeps the band's foreground, no accent colour. }
    AssertEquals('no colour on the focus',
      Surface.CellAt(ColE, 3).Attr.Fg, Surface.CellAt(ColR, 3).Attr.Fg);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalEffectAskShowsThePathAndTheScript;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
  Ask: TApprovalAsk;
begin
  { A file effect ask: the path is what is approved; the script is context. }
  Ask := ScriptAsk('cd sub; cat a.txt', 'cat a.txt');
  Ask.Summary := 'read sub/a.txt (cwd sub)';
  Ask.Subject.Ref := 'file:read';
  Ask.Subject.Path := 'sub/a.txt';
  Modal := TApprovalModal.Create(Ask);
  Surface := TSurfaceMemory.Create(60, 20);
  try
    Modal.Arrange(Rc(60, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    AssertTrue('the effect', Pos(UnicodeString('read sub/a.txt'),
      Surface.RowText(3, 0, 60)) > 0);
    { The effect line is the key information, so it is not dimmed. }
    AssertFalse('the effect is not dimmed',
      sfDim in Surface.CellAt(3, 3).Attr.Style);
    AssertTrue('the command', Pos(UnicodeString('cd sub; cat a.txt'),
      Surface.RowText(4, 0, 60)) > 0);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalScrollsToTheFocus;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
  Script: string;
  I: Integer;
  Found: Boolean;
begin
  Script := '';
  for I := 0 to 19 do
    Script := Script + 'cmd' + IntToStr(I) + ' here' + #10;
  Script := Script + 'target command';
  Modal := TApprovalModal.Create(ScriptAsk(Script, 'target command'));
  Surface := TSurfaceMemory.Create(60, 40);
  try
    Modal.Arrange(Rc(60, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    { The band opens on the focus, not on the first line. }
    Found := False;
    for I := 3 to 12 do
      if Pos('target command', Surface.RowText(I, 0, 60)) > 0 then
        Found := True;
    AssertTrue('the focus is visible', Found);
    AssertTrue('scroll offset moved', Modal.Scroll > 0);
    AssertTrue('the head is scrolled away',
      Pos('cmd0 here', Surface.RowText(3, 0, 60)) = 0);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalScrollKeysAndWheel;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
  Script: string;
  I, Before: Integer;
begin
  Script := '';
  for I := 0 to 19 do
    Script := Script + 'cmd' + IntToStr(I) + ' here' + #10;
  Modal := TApprovalModal.Create(ScriptAsk(Script, 'cmd19 here'));
  Surface := TSurfaceMemory.Create(60, 40);
  try
    Modal.Arrange(Rc(60, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    Before := Modal.Scroll;
    AssertTrue('page up handled', Modal.HandleEvent(Key(kkPageUp)));
    AssertTrue('scrolled up', Modal.Scroll < Before);
    Surface.Free;
    Surface := TSurfaceMemory.Create(60, 40);
    Modal.Render(Surface);
    AssertTrue('page down handled', Modal.HandleEvent(Key(kkPageDown)));
    AssertTrue('scrolled further than the page-up position',
      Modal.Scroll >= Before);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalShowsTheReason;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
  Ask: TApprovalAsk;
begin
  Ask := MakeAsk(2);
  Ask.Reason := 'free the build dir';
  Modal := TApprovalModal.Create(Ask);
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    AssertTrue('reason label', Pos('reason:', Surface.RowText(1, 0, 40)) > 0);
    AssertTrue('reason text',
      Pos('free the build dir', Surface.RowText(1, 0, 40)) > 0);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalReasonPlaceholder;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    AssertTrue('label still drawn', Pos('reason:', Surface.RowText(1, 0, 40)) > 0);
    AssertTrue('placeholder',
      Pos('—', Surface.RowText(1, 0, 40)) > 0);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalReasonWraps;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
  Ask: TApprovalAsk;
begin
  Ask := MakeAsk(2);
  Ask.Reason := 'aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj';
  Modal := TApprovalModal.Create(Ask);
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    AssertTrue('first reason line',
      Pos('aaaa bbbb cccc dddd eeee', Surface.RowText(1, 0, 40)) > 0);
    AssertTrue('second reason line',
      Pos('ffff gggg hhhh iiii jjjj', Surface.RowText(2, 0, 40)) > 0);
    { Two reason rows push the options down. }
    AssertTrue('options below the reason',
      Pos('Option 1', Surface.RowText(6, 0, 40)) > 0);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalWrapsLongDetails;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
  Ask: TApprovalAsk;
begin
  Ask := MakeAsk(2);
  Ask.Summary := 'aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj';
  Modal := TApprovalModal.Create(Ask);
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    AssertTrue('first detail line',
      Pos('aaaa bbbb cccc dddd eeee', Surface.RowText(3, 0, 40)) > 0);
    AssertTrue('wrapped detail line',
      Pos('hhhh iiii jjjj', Surface.RowText(4, 0, 40)) > 0);
    { Two detail rows: the first option is at row 6. }
    AssertTrue('options below the details',
      Pos('Option 1', Surface.RowText(6, 0, 40)) > 0);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalCompactsVeryLongDetails;
var
  Modal: TApprovalModal;
  Surface: TSurfaceMemory;
  Ask: TApprovalAsk;
  I: Integer;
  S: string;
begin
  Ask := MakeAsk(2);
  S := '';
  for I := 1 to 12 do
  begin
    if I > 1 then
      S := S + #10;
    S := S + 'd' + IntToStr(I);
  end;
  Ask.Summary := S;
  Modal := TApprovalModal.Create(Ask);
  Surface := TSurfaceMemory.Create(40, 20);
  try
    Modal.Arrange(Rc(40, MeasuredHeight(Modal)));
    Modal.Render(Surface);
    AssertTrue('first kept line', Pos('d1', Surface.RowText(3, 0, 40)) > 0);
    AssertTrue('second kept line', Pos('d2', Surface.RowText(4, 0, 40)) > 0);
    AssertTrue('ellipsis', Pos('...', Surface.RowText(5, 0, 40)) > 0);
    AssertTrue('first tail line', Pos('d10', Surface.RowText(6, 0, 40)) > 0);
    AssertTrue('last tail line', Pos('d12', Surface.RowText(8, 0, 40)) > 0);
    { Six detail rows: the first option is at row 10. }
    AssertTrue('options below the details',
      Pos('Option 1', Surface.RowText(10, 0, 40)) > 0);
  finally
    Modal.Free;
    Surface.Free;
  end;
end;

procedure TApprovalModalTest.TestModalKeepsEdgePadding;
var
  Modal: TApprovalModal;
  Ask: TApprovalAsk;
  Sz, Measured: TSize;
begin
  Ask := MakeAsk(2);
  Ask.Summary := StringOfChar('x', 500);
  Modal := TApprovalModal.Create(Ask);
  try
    Sz := Default(TSize);
    Sz.W := 100;
    Sz.H := 30;
    Measured := Modal.Measure(Sz);
    AssertTrue('width keeps the 4-column edge padding', Measured.W <= 92);
    AssertTrue('width grew for the content', Measured.W > 55);
    AssertTrue('height keeps the 4-row edge padding', Measured.H <= 22);
  finally
    Modal.Free;
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
