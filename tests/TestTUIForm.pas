unit TestTUIForm;
{ fpcunit tests for TUIWidgetsForm.

  The unit exists to enforce three rules, each of which cost a real bug in the
  hand-rolled forms it replaces:

    1. Touched is set on BLUR, so a field is not marked wrong while you type.
    2. Validation is pairwise, so a field can see its siblings.
    3. The field RENDERS its own error. A field that can be invalid but cannot
       draw why looks like nothing happened - and did, for weeks. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput, TUISurface, TUITheme, TUIWidget,
  TUIWidgetsForm;

type
  TFormTest = class(TTestCase)
  private
    FTheme: TTheme;
    FSubmitted: Integer;
    FInvalid: Integer;
    FLastValues: string;
    procedure OnInit(const AValues: TFieldValues);
    procedure OnBad;
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function Down: TInputEvent;
  protected
    procedure SetUp; override;
  published
    { Registration }
    procedure TestFieldRegistersWithItsForm;
    procedure TestDuplicateNameIsRefusedAtAddTime;
    procedure TestFieldByNameFinds;

    { The three rules }
    procedure TestTouchedIsSetOnBlurNotOnConstruction;
    procedure TestUntouchedEmptyFieldIsNotYetInvalid;
    procedure TestSubmitMarksAnUntouchedBadField;
    procedure TestFieldCanValidateAgainstASibling;
    procedure TestFieldRendersItsOwnError;

    { Submission }
    procedure TestSubmitEmitsValuesWhenValid;
    procedure TestSubmitEmitsNothingWhenInvalid;
    procedure TestSubmitReportsInvalidInstead;
    procedure TestEmptyOptionalIsAValue;

    { Pick field }
    procedure TestPickCyclesAndWraps;
    procedure TestPickWithNoOptionsIsInvalid;
    procedure TestPickAllowEmptyToleratesNoOptions;

    { Focus }
    procedure TestFocusMovesAndBlurs;
  end;

implementation

procedure TFormTest.SetUp;
begin
  FTheme := DarkTheme;
  FSubmitted := 0;
  FInvalid := 0;
  FLastValues := '';
end;

procedure TFormTest.OnInit(const AValues: TFieldValues);
begin
  Inc(FSubmitted);
  FLastValues := AValues.Text;
end;

procedure TFormTest.OnBad;
begin
  Inc(FInvalid);
end;

function TFormTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TFormTest.Down: TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkDown;
end;

{ --- Registration --- }

procedure TFormTest.TestFieldRegistersWithItsForm;
var
  F: TForm;
begin
  F := TForm.Create(FTheme);
  try
    TTextField.Create(F, 'name');
    TTextField.Create(F, 'endpoint');
    AssertEquals('both fields registered', 2, F.FieldCount);
    AssertTrue('and are findable', F.FieldByName('endpoint') <> nil);
  finally
    F.Free;   { owns the fields }
  end;
end;

procedure TFormTest.TestDuplicateNameIsRefusedAtAddTime;
var
  F: TForm;
  Raised: Boolean;
begin
  F := TForm.Create(FTheme);
  try
    TTextField.Create(F, 'name');
    Raised := False;
    try
      TTextField.Create(F, 'name');
    except
      on E: Exception do
        Raised := True;
    end;
    { Discovering this at submit means one field's input silently goes to the
      other's key. }
    AssertTrue('a duplicate name raises on construction', Raised);
    AssertEquals('and was not added', 1, F.FieldCount);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestFieldByNameFinds;
var
  F: TForm;
  A, B: TTextField;
begin
  F := TForm.Create(FTheme);
  try
    A := TTextField.Create(F, 'a');
    B := TTextField.Create(F, 'b');
    AssertTrue('finds a', F.FieldByName('a') = A);
    AssertTrue('finds b', F.FieldByName('b') = B);
    AssertTrue('absent is nil', F.FieldByName('zzz') = nil);
  finally
    F.Free;
  end;
end;

{ --- The three rules --- }

procedure TFormTest.TestTouchedIsSetOnBlurNotOnConstruction;
var
  F: TForm;
  T: TTextField;
begin
  F := TForm.Create(FTheme);
  try
    T := TTextField.Create(F, 'name');
    T.Required := True;
    AssertFalse('a fresh field is untouched', T.Touched);
    AssertTrue('and therefore not yet wrong', T.Valid);
    T.Blur;
    AssertTrue('blurring touches it', T.Touched);
    { Now that it has been visited, it is wrong and may say so. }
    AssertFalse('an emptied required field is now invalid', T.Valid);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestUntouchedEmptyFieldIsNotYetInvalid;
var
  F: TForm;
  T: TTextField;
begin
  F := TForm.Create(FTheme);
  try
    T := TTextField.Create(F, 'name');
    T.Required := True;
    { The whole point: empty AND required, but never visited, so not yet an
      error. Marking it red on construction is hostile. }
    AssertEquals('no value', '', T.Value);
    AssertTrue('but not yet invalid', T.Valid);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestSubmitMarksAnUntouchedBadField;
var
  F: TForm;
  T: TTextField;
begin
  F := TForm.Create(FTheme);
  try
    T := TTextField.Create(F, 'name');
    T.Required := True;
    F.OnInvalid := OnBad;
    { Submit touches first, so pressing the button with an empty required field
      does mark it rather than doing nothing. }
    F.Submit;
    AssertTrue('submit touched the field', T.Touched);
    AssertEquals('and reported invalid', 1, FInvalid);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestFieldCanValidateAgainstASibling;
var
  F: TForm;
begin
  F := TForm.Create(FTheme);
  try
    TTextField.Create(F, 'provider').SetValue('openai');
    TTextField.Create(F, 'model');
    { Pairwise validation: the form brokers values, so a field can ask about its
      siblings. A per-field Valid boolean cannot express "model needs provider". }
    AssertEquals('a sibling value is visible during validation',
      'openai', F.ValueOf('provider'));
    AssertEquals('an absent sibling is empty', '', F.ValueOf('nope'));
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestFieldRendersItsOwnError;
var
  F: TForm;
  T: TTextField;
  M: TSurfaceMemory;
begin
  F := TForm.Create(FTheme);
  M := TSurfaceMemory.Create(30, 4);
  try
    T := TTextField.Create(F, 'name');
    T.Required := True;
    T.SetValue('');      { empty, so invalid once touched }
    T.Blur;
    F.Arrange(Rc(0, 0, 30, 4));

    M.SetScreenBg(FTheme.Bg);
    T.Arrange(Rc(0, 0, 30, 1));
    T.Render(M);

    { The error must be DRAWN. FError set with nothing painting it is how
      "name is required" went unseen for weeks. }
    AssertTrue('the error text reached the surface',
      Pos('required', string(UTF8Encode(M.RowText(0, 0, 30)))) > 0);
  finally
    M.Free;
    F.Free;
  end;
end;

{ --- Submission --- }

procedure TFormTest.TestSubmitEmitsValuesWhenValid;
var
  F: TForm;
begin
  F := TForm.Create(FTheme);
  try
    F.OnSubmit := OnInit;
    TTextField.Create(F, 'name').SetValue('alpha');
    TTextField.Create(F, 'endpoint').SetValue('http://x');
    F.Submit;
    AssertEquals('submitted once', 1, FSubmitted);
    AssertTrue('with the name', Pos('name=alpha', FLastValues) > 0);
    AssertTrue('and the endpoint', Pos('endpoint=http://x', FLastValues) > 0);
    AssertTrue('and the form is valid', F.State = fsValid);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestSubmitEmitsNothingWhenInvalid;
var
  F: TForm;
  T: TTextField;
begin
  F := TForm.Create(FTheme);
  try
    F.OnSubmit := OnInit;
    T := TTextField.Create(F, 'name');
    T.Required := True;
    { Empty and required: submit must NOT emit a half-filled mapping. That is
      how you get a provider row with a name and no endpoint. }
    F.Submit;
    AssertEquals('nothing submitted', 0, FSubmitted);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestSubmitReportsInvalidInstead;
var
  F: TForm;
begin
  F := TForm.Create(FTheme);
  try
    F.OnInvalid := OnBad;
    TTextField.Create(F, 'name').Required := True;
    F.Submit;
    AssertEquals('the host was told', 1, FInvalid);
    AssertTrue('and the form says so', F.State = fsInvalid);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestEmptyOptionalIsAValue;
var
  F: TForm;
begin
  F := TForm.Create(FTheme);
  try
    F.OnSubmit := OnInit;
    { An optional field left empty is valid, and its empty value is still part
      of the mapping - a caller can tell "present and empty" from "absent". }
    TTextField.Create(F, 'nickname');
    F.Submit;
    AssertEquals('submitted', 1, FSubmitted);
    AssertTrue('the empty value is in the mapping',
      Pos('nickname=', FLastValues) > 0);
  finally
    F.Free;
  end;
end;

{ --- Pick field --- }

procedure TFormTest.TestPickCyclesAndWraps;
var
  F: TForm;
  P: TPickField;
begin
  F := TForm.Create(FTheme);
  try
    P := TPickField.Create(F, 'provider');
    P.SetOptions(['alpha', 'beta', 'gamma']);
    AssertEquals('starts on the first', 'alpha', P.Value);
    P.Cycle(1);
    AssertEquals('next', 'beta', P.Value);
    P.Cycle(1);
    P.Cycle(1);
    { Wrap, or a two-option pick is a dead end in one direction. }
    AssertEquals('wraps forward', 'alpha', P.Value);
    P.Cycle(-1);
    AssertEquals('wraps backward', 'gamma', P.Value);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestPickWithNoOptionsIsInvalid;
var
  F: TForm;
  P: TPickField;
begin
  F := TForm.Create(FTheme);
  try
    P := TPickField.Create(F, 'model');
    P.Blur;
    AssertFalse('nothing to pick is invalid', P.Valid);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestPickAllowEmptyToleratesNoOptions;
var
  F: TForm;
  P: TPickField;
begin
  F := TForm.Create(FTheme);
  try
    P := TPickField.Create(F, 'model');
    P.AllowEmpty := True;
    P.Blur;
    { An optional pick with nothing to pick from is legal - the operator simply
      did not choose. }
    AssertTrue('allowed to be empty', P.Valid);
  finally
    F.Free;
  end;
end;

{ --- Focus --- }

procedure TFormTest.TestFocusMovesAndBlurs;
var
  F: TForm;
  A, B: TTextField;
begin
  F := TForm.Create(FTheme);
  try
    A := TTextField.Create(F, 'a');
    B := TTextField.Create(F, 'b');
    AssertTrue('starts on the first', F.FocusedField = A);
    F.HandleEvent(Down);
    { Moving focus BLURS the field being left - the only place Touched is set. }
    AssertTrue('leaving a field touches it', A.Touched);
    AssertTrue('and focus moved', F.FocusedField = B);
    AssertFalse('the new field is untouched', B.Touched);
  finally
    F.Free;
  end;
end;

initialization
  RegisterTest(TFormTest);
end.
