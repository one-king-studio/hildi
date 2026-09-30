unit test_tui_approvalmodal;
{ fpcunit tests for hildegard.helper.tui.approvalmodal: option selection, scope,
  deny, and safe handling of an empty ask. No terminal. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
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
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRendersSummaryAndOptions;
    procedure TestArrowAndEnterChooses;
    procedure TestNumberChooses;
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
    AssertTrue('summary shown', Pos('rm -rf build/', Surface.RowText(2, 0, 40)) > 0);
    AssertTrue('option 1 shown', Pos('1) Option 1', Surface.RowText(4, 0, 40)) > 0);
    AssertTrue('option 2 shown', Pos('2) Option 2', Surface.RowText(5, 0, 40)) > 0);
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

procedure TApprovalModalTest.TestNumberChooses;
var
  Modal: TApprovalModal;
begin
  Modal := TApprovalModal.Create(MakeAsk(2));
  try
    Modal.OnChoose := FRecorder.OnChoose;
    Modal.HandleEvent(Ch('2'));
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
