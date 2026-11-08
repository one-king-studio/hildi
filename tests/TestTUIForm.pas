unit TestTUIForm;
{ fpcunit tests for TUIWidgetsForm.

  The unit exists to enforce two rules, each of which cost a real bug in the
  hand-rolled forms it replaces:

    1. Validation is PAIRWISE, so a field can see its siblings.
    2. The field RENDERS its own error. A field that can be invalid but cannot
       draw why looks like nothing happened - and did, for weeks.

  Touched/blur gating was considered and deliberately skipped, so validation is
  direct: a field reports its verdict immediately and Submit marks everything. }

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
    FDirty: Integer;
    FCount: Integer;
    FNames: string;
    FValues: string;
    procedure OnInit(const AValues: TFieldValueArray);
    procedure OnBad;
    procedure OnDirty;
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function Down: TInputEvent;
    function Left: TInputEvent;
  protected
    procedure SetUp; override;
  published
    { Registration }
    procedure TestFieldRegistersWithItsForm;
    procedure TestDuplicateNameIsRefusedAtAddTime;
    procedure TestFieldNamedFinds;

    { The two rules }
    procedure TestFieldCanValidateAgainstASibling;
    procedure TestFieldRendersItsOwnError;
    procedure TestForcedInvalidRendersSomething;

    { Submission }
    procedure TestSubmitEmitsValuesInRegistrationOrder;
    procedure TestSubmitEmitsNothingWhenInvalid;
    procedure TestSubmitReportsInvalidInstead;
    procedure TestEmptyOptionalIsAValue;
    procedure TestClearErrorsResetsState;

    { Pick field }
    procedure TestPickCyclesAndWraps;
    procedure TestPickWithNoItemsIsInvalid;
    procedure TestPickAllowEmptyToleratesNoItems;
    procedure TestPickSetValueSelects;

    { Secret field }
    procedure TestSecretFieldMasksAndKeepsItsValue;
    procedure TestSecretClearWantsClearAndEmpties;

    { Number field }
    procedure TestNumberEmptyIsAbsentNotZero;
    procedure TestNumberZeroIsPresentAndZero;
    procedure TestNumberUnparseableIsInvalid;
    procedure TestNumberOutOfRangeIsInvalidNotClamped;
    procedure TestNumberWholeRejectsAFraction;

    { Focus }
    procedure TestFocusMovesBetweenFields;

    { Parsing helpers }
    procedure TestParseOptFloatAbsentAndPresent;
    procedure TestParseOptIntRejectsAFraction;
  end;

implementation

procedure TFormTest.SetUp;
begin
  FTheme := DarkTheme;
  FSubmitted := 0;
  FInvalid := 0;
  FDirty := 0;
  FCount := 0;
  FNames := '';
  FValues := '';
end;

procedure TFormTest.OnInit(const AValues: TFieldValueArray);
var
  I: Integer;
begin
  Inc(FSubmitted);
  FCount := Length(AValues);
  for I := 0 to High(AValues) do
  begin
    if I > 0 then
    begin
      FNames := FNames + ',';
      FValues := FValues + ',';
    end;
    FNames := FNames + AValues[I].Name;
    FValues := FValues + AValues[I].Value;
  end;
end;

procedure TFormTest.OnBad;
begin
  Inc(FInvalid);
end;

procedure TFormTest.OnDirty;
begin
  Inc(FDirty);
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

function TFormTest.Left: TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkLeft;
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
    AssertEquals('both registered', 2, F.FieldCount);
    AssertTrue('and findable', F.FieldNamed('endpoint') <> nil);
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
    AssertTrue('a duplicate raises at construction', Raised);
    AssertEquals('and was not added', 1, F.FieldCount);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestFieldNamedFinds;
var
  F: TForm;
  A, B: TTextField;
begin
  F := TForm.Create(FTheme);
  try
    A := TTextField.Create(F, 'a');
    B := TTextField.Create(F, 'b');
    AssertTrue('finds a', F.FieldNamed('a') = A);
    AssertTrue('finds b', F.FieldNamed('b') = B);
    AssertTrue('absent is nil', F.FieldNamed('zzz') = nil);
  finally
    F.Free;
  end;
end;

{ --- The two rules --- }

procedure TFormTest.TestFieldCanValidateAgainstASibling;
var
  F: TForm;
begin
  F := TForm.Create(FTheme);
  try
    TTextField.Create(F, 'provider').SetValue('openai');
    TTextField.Create(F, 'model');
    { Pairwise: the form brokers values, so a field can ask about its siblings.
      A per-field Valid boolean cannot express "a model needs a provider". }
    AssertEquals('a sibling value is visible', 'openai', F.ValueOf('provider'));
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

procedure TFormTest.TestForcedInvalidRendersSomething;
var
  F: TForm;
  T: TTextField;
  M: TSurfaceMemory;
begin
  F := TForm.Create(FTheme);
  M := TSurfaceMemory.Create(30, 4);
  try
    T := TTextField.Create(F, 'name');
    T.SetValue('looks fine');
    { A host can reject a value for a reason the field cannot know. It must still
      say SOMETHING, or the operator sees a refusal with no reason. }
    T.ForceInvalid := True;
    T.Arrange(Rc(0, 0, 30, 1));
    M.SetScreenBg(FTheme.Bg);
    T.Render(M);
    AssertTrue('a forced-invalid field still says why',
      Pos('invalid', string(UTF8Encode(M.RowText(0, 0, 30)))) > 0);
    AssertFalse('and reports invalid', T.Valid);
  finally
    M.Free;
    F.Free;
  end;
end;

{ --- Submission --- }

procedure TFormTest.TestSubmitEmitsValuesInRegistrationOrder;
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
    AssertEquals('two values', 2, FCount);
    { Registration order, so a caller can rely on it rather than sorting. }
    AssertEquals('names in order', 'name,endpoint', FNames);
    AssertEquals('values in order', 'alpha,http://x', FValues);
    AssertTrue('and the form is valid', F.State = fsValid);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestSubmitEmitsNothingWhenInvalid;
var
  F: TForm;
begin
  F := TForm.Create(FTheme);
  try
    F.OnSubmit := OnInit;
    TTextField.Create(F, 'name').Required := True;
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
    { An optional field left empty is valid, and its empty value is still part of
      the mapping - a caller can tell "present and empty" from "absent". }
    TTextField.Create(F, 'nickname');
    F.Submit;
    AssertEquals('submitted', 1, FSubmitted);
    AssertEquals('the empty value is in the mapping', 'nickname', FNames);
    AssertEquals('with an empty value', '', FValues);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestClearErrorsResetsState;
var
  F: TForm;
begin
  F := TForm.Create(FTheme);
  try
    F.OnInvalid := OnBad;
    TTextField.Create(F, 'name').Required := True;
    F.Submit;
    AssertTrue('invalid', F.State = fsInvalid);
    F.ClearErrors;
    { A server-side failure that has been dealt with should not leave the form
      stuck showing an error. }
    AssertTrue('pristine again', F.State = fsPristine);
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
    P.SetItems(['alpha', 'beta', 'gamma']);
    AssertEquals('starts on the first', 'alpha', P.Value);
    P.Cycle(1);
    AssertEquals('next', 'beta', P.Value);
    P.Cycle(1);
    P.Cycle(1);
    { Wrap, or a two-item pick is a dead end in one direction. }
    AssertEquals('wraps forward', 'alpha', P.Value);
    P.Cycle(-1);
    AssertEquals('wraps backward', 'gamma', P.Value);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestPickWithNoItemsIsInvalid;
var
  F: TForm;
  P: TPickField;
begin
  F := TForm.Create(FTheme);
  try
    P := TPickField.Create(F, 'model');
    AssertFalse('nothing to pick is invalid', P.Valid);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestPickAllowEmptyToleratesNoItems;
var
  F: TForm;
  P: TPickField;
begin
  F := TForm.Create(FTheme);
  try
    P := TPickField.Create(F, 'model');
    P.AllowEmpty := True;
    { An optional pick with nothing to pick from is legal - the operator simply
      did not choose. }
    AssertTrue('allowed to be empty', P.Valid);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestPickSetValueSelects;
var
  F: TForm;
  P: TPickField;
begin
  F := TForm.Create(FTheme);
  try
    P := TPickField.Create(F, 'provider');
    P.SetItems(['alpha', 'beta']);
    P.SetValue('beta');
    AssertEquals('selected by value', 1, P.SelectedIndex);
    AssertEquals('and reports it', 'beta', P.Value);
    P.SetValue('not-in-list');
    { An unknown value must not silently select something else. }
    AssertEquals('unknown value leaves the selection alone', 1, P.SelectedIndex);
  finally
    F.Free;
  end;
end;

{ --- Secret field --- }

procedure TFormTest.TestSecretFieldMasksAndKeepsItsValue;
var
  F: TForm;
  S: TSecretField;
  M: TSurfaceMemory;
begin
  F := TForm.Create(FTheme);
  M := TSurfaceMemory.Create(20, 2);
  try
    S := TSecretField.Create(F, 'key');
    S.SetValue('sk-secret-123');
    S.Arrange(Rc(0, 0, 20, 1));
    M.SetScreenBg(FTheme.Bg);
    S.Render(M);
    { Masking is a RENDERING concern: the value must survive untouched, and no
      part of it may appear on screen. }
    AssertEquals('the value is intact', 'sk-secret-123', S.Value);
    AssertTrue('nothing of it is drawn',
      Pos('sk-secret', string(UTF8Encode(M.RowText(0, 0, 20)))) = 0);
  finally
    M.Free;
    F.Free;
  end;
end;

procedure TFormTest.TestSecretClearWantsClearAndEmpties;
var
  F: TForm;
  S: TSecretField;
begin
  F := TForm.Create(FTheme);
  try
    S := TSecretField.Create(F, 'key');
    S.SetValue('sk-secret-123');
    AssertFalse('not marked before clearing', S.WantsClear);
    S.Clear;
    { '' cannot mean both "leave it" and "delete it". }
    AssertTrue('clear marks it for removal', S.WantsClear);
    AssertEquals('and empties the visible text', '', S.Value);
  finally
    F.Free;
  end;
end;

{ --- Number field --- }

procedure TFormTest.TestNumberEmptyIsAbsentNotZero;
var
  F: TForm;
  N: TNumberField;
begin
  F := TForm.Create(FTheme);
  try
    N := TNumberField.Create(F, 'temperature');
    N.SetValue('');
    N.Commit;
    { temperature=0 is a real setting, so absent must not read as 0. }
    AssertFalse('empty is absent', N.HasValue);
    AssertTrue('and is VALID - the field is optional', N.Valid);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestNumberZeroIsPresentAndZero;
var
  F: TForm;
  N: TNumberField;
begin
  F := TForm.Create(FTheme);
  try
    N := TNumberField.Create(F, 'temperature');
    N.SetValue('0');
    N.Commit;
    AssertTrue('zero is a value', N.HasValue);
    AssertEquals('and it is zero', 0, Round(N.AsFloat));
    AssertTrue('and valid', N.Valid);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestNumberUnparseableIsInvalid;
var
  F: TForm;
  N: TNumberField;
begin
  F := TForm.Create(FTheme);
  try
    N := TNumberField.Create(F, 'temperature');
    N.SetValue('abc');
    N.Commit;
    AssertFalse('nothing parsed', N.HasValue);
    { Invalid, NOT silently absent: the operator typed something. }
    AssertFalse('and it is invalid', N.Valid);
    AssertTrue('with a reason', N.ErrorText <> '');
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestNumberOutOfRangeIsInvalidNotClamped;
var
  F: TForm;
  N: TNumberField;
begin
  F := TForm.Create(FTheme);
  try
    N := TNumberField.Create(F, 'temperature');
    N.SetMin(0);
    N.SetMax(2);
    N.SetValue('9');
    N.Commit;
    { Clamping substitutes a number the operator did not choose. }
    AssertFalse('out of range is invalid', N.Valid);
    AssertEquals('and the value is NOT clamped', 9, Round(N.AsFloat));
    AssertTrue('with a range in the message', Pos('max', N.ErrorText) > 0);
  finally
    F.Free;
  end;
end;

procedure TFormTest.TestNumberWholeRejectsAFraction;
var
  F: TForm;
  N: TNumberField;
begin
  F := TForm.Create(FTheme);
  try
    N := TNumberField.Create(F, 'max_tokens');
    N.Whole := True;
    N.SetValue('1.5');
    N.Commit;
    AssertFalse('a fraction is not whole', N.Valid);
    AssertTrue('and says so', Pos('whole', N.ErrorText) > 0);
  finally
    F.Free;
  end;
end;

{ --- Focus --- }

procedure TFormTest.TestFocusMovesBetweenFields;
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
    AssertTrue('focus moved', F.FocusedField = B);
  finally
    F.Free;
  end;
end;

{ --- Parsing helpers --- }

procedure TFormTest.TestParseOptFloatAbsentAndPresent;
var
  V: Double;
  Has: Boolean;
begin
  { Absent is not an error. }
  AssertTrue('empty parses', ParseOptFloat('', V, Has));
  AssertFalse('and is absent', Has);
  AssertTrue('whitespace parses', ParseOptFloat('   ', V, Has));
  AssertFalse('and is absent', Has);
  AssertTrue('a number parses', ParseOptFloat('0.25', V, Has));
  AssertTrue('and is present', Has);
  AssertEquals('with its value', 0.25, V, 0.0001);
  AssertFalse('junk does not parse', ParseOptFloat('abc', V, Has));
end;

procedure TFormTest.TestParseOptIntRejectsAFraction;
var
  V: Integer;
  Has: Boolean;
begin
  AssertFalse('a fraction is not an int', ParseOptInt('1.5', V, Has));
  AssertFalse('so it has no value', Has);
  AssertTrue('a whole number parses', ParseOptInt('42', V, Has));
  AssertEquals('with its value', 42, V);
end;

initialization
  RegisterTest(TFormTest);
end.
