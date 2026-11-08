unit TUIWidgetsForm;
{ A form container and its field kinds.

  THREE LANES were about to hand-roll the same ~400 lines: a container of wrapped
  inputs, index-based focus cycling with a wrap, validation living in the widget,
  and a deferred-close callback. This is that, once.

  The model is an HTML form, which is the operator's own description:

    - a field REGISTERS with its form by name; a duplicate name is refused at
      add time rather than discovered at submit
    - the form brokers values, so a field can validate against its siblings
    - Submit validates everything, marks the invalid fields, and emits the
      name->value map ONLY when all of them pass

  The form is a CONTAINER of fields, not a dialog. It sits inside TModal, which
  already owns the frame, the title, the 80% cap and the fixed CTA footer - so a
  form dialog is a TForm inside a TModal and nothing else.

  TWO RULES THIS UNIT EXISTS TO ENFORCE, each paid for by a bug:

  1. Validation is pairwise. A field reads its siblings through ValueOf, so
     "a model needs a provider" is expressible at all.
  2. The field RENDERS its own error. A field that can be invalid but cannot
     draw why looks like nothing happened - and did, for weeks, in the provider
     form, which set FError and painted nothing.

  DELIBERATELY NO "Touched" GATING. An earlier design defered errors until a
  field lost focus; the operator chose to skip it, so validation is direct: a
  field reports its own verdict immediately and Submit marks everything. That
  removes a whole state machine and the "who blurs?" question with it.

  DELIBERATELY NOT A TContainer. A grid with one column and one row holds ONE
  child - every field after the first is silently dropped by TContainer.Add and,
  because it is dropped, never owned (a leak, not an error). TForm arranges and
  renders its fields itself and owns them outright. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, Classes, Math,
  TUIBase, TUIInput,
  TUISurface, TUITheme, TUIWidget,
  TUIGrapheme,
  TUIWidgetsText, TUIWidgetsPrompt, TUIWidgetsFocus;

type
  TFormState = (fsPristine, fsValid, fsInvalid);

  { The field->value mapping handed to OnSubmit. An ARRAY OF RECORDS rather than
    a TStringList: it has no ownership question, so a handler cannot forget to
    free it, and registration order is preserved so a caller can rely on it. }
  TFieldValue = record
    Name: string;
    Value: string;
  end;
  TFieldValueArray = array of TFieldValue;

  TFormSubmitEvent = procedure(const AValues: TFieldValueArray) of object;
  TFormEvent = procedure of object;

  TForm = class;

  { One field. A TFocusable, so TFocusGroup can drive focus over a form without
    the form re-implementing index arithmetic. }
  TFormField = class(TFocusable)
  private
    FForm: TForm;
    FName: string;
    FLabel: string;
    FForceInvalid: Boolean;
  protected
    { Whether THIS field's value is acceptable. May consult FForm.ValueOf for a
      cross-field rule - that is the whole reason the field keeps a form link. }
    function FieldValid: Boolean; virtual;
    { Draw the field's own row. }
    procedure RenderField(const S: ISurface; const ARow: TRect); virtual;
    { Paint the error at the right edge of ARow, if there is one. Shared so every
      kind draws it the same way - and so a new kind cannot forget. }
    procedure PaintError(const S: ISurface; const ARow: TRect);
  public
    constructor Create(AForm: TForm; const AName: string);
    { The value as the form sees it. }
    function Value: string; virtual;
    procedure SetValue(const AValue: string); virtual;
    procedure Render(const S: ISurface); override;
    property Form: TForm read FForm;
    property FieldName: string read FName;
    property LabelText: string read FLabel write FLabel;
    { Valid = this field's own verdict AND not externally forced invalid. }
    function Valid: Boolean;
    { Why it is invalid. '' when valid. Usually RENDERED BY THE FIELD, but a host
      also needs to read it: a form-level summary or a status line wants the
      reason, not just the fact. }
    function ErrorText: string; virtual;
    { A host can mark a field invalid for a reason the field cannot know (a
      server-side rejection), without inventing a second error channel. }
    property ForceInvalid: Boolean read FForceInvalid write FForceInvalid;
  end;

  { A single line of text. Composes TPromptLine rather than replacing it, so
    caret, wrapping and history come from the editor. }
  TTextField = class(TFormField)
  private
    FEdit: TPromptLine;
    FRequired: Boolean;
    FPlaceholder: string;
  protected
    function FieldValid: Boolean; override;
    procedure RenderField(const S: ISurface; const ARow: TRect); override;
  public
    function ErrorText: string; override;
    constructor Create(AForm: TForm; const AName: string);
    destructor Destroy; override;
    function Value: string; override;
    procedure SetValue(const AValue: string); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    property Required: Boolean read FRequired write FRequired;
    property Placeholder: string read FPlaceholder write FPlaceholder;
    property Edit: TPromptLine read FEdit;
  end;

  { Masked on screen, plain in value. Composes TPromptLine with Maskson, because
    masking is a RENDERING concern and the real text must stay untouched - a
    field whose value silently became asterisks would corrupt what it collected.

    Clear() exists because '' cannot mean both "leave it alone" and "delete it"
    when editing an existing record. }
  TSecretField = class(TTextField)
  private
    FWantsClear: Boolean;
    function GetMasked: Boolean;
    procedure SetMasked(AValue: Boolean);
  public
    constructor Create(AForm: TForm; const AName: string);
    { Mark for removal, and empty the visible text. The host decides what to do
      with WantsClear - the form deals in strings and has no store. }
    procedure Clear;
    function WantsClear: Boolean;
    property Masked: Boolean read GetMasked write SetMasked;
  end;

  { Cycles a known list. The value is the selected item. Deliberately a PICK and
    not a text box: a free-typed name that does not resolve is how a broken row
    gets created. This is the provider/model field. }
  TPickField = class(TFormField)
  private
    FItems: TStringArray;
    FIndex: Integer;
    FAllowEmpty: Boolean;
  protected
    function FieldValid: Boolean; override;
    procedure RenderField(const S: ISurface; const ARow: TRect); override;
  public
    function ErrorText: string; override;
    constructor Create(AForm: TForm; const AName: string);
    procedure SetItems(const AItems: array of string);
    function ItemCount: Integer;
    function SelectedIndex: Integer;
    procedure Select(AIndex: Integer);
    procedure Cycle(ADelta: Integer);
    function Value: string; override;
    procedure SetValue(const AValue: string); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property AllowEmpty: Boolean read FAllowEmpty write FAllowEmpty;
  end;

  { An OPTIONAL number. Empty means ABSENT (HasValue = False), never zero:
    temperature=0 is a real setting, and a field that defaults to 0 has silently
    overwritten it.

    Out of range is INVALID, never CLAMPED - clamping substitutes a number the
    operator did not choose. }
  TNumberField = class(TTextField)
  private
    FHasValue: Boolean;
    FAsFloat: Double;
    FWhole: Boolean;
    FMinValue, FMaxValue: Double;
    FHasMin, FHasMax: Boolean;
  protected
    function FieldValid: Boolean; override;
  public
    function ErrorText: string; override;
    constructor Create(AForm: TForm; const AName: string);
    { Re-parse the text. Called by the form before validation. }
    procedure Commit;
    property HasValue: Boolean read FHasValue;
    property AsFloat: Double read FAsFloat;
    function AsInteger: Integer;
    property Whole: Boolean read FWhole write FWhole;
    property MinValue: Double read FMinValue write FMinValue;
    property MaxValue: Double read FMaxValue write FMaxValue;
    { Set to open the range. Without these the bound is absent, not zero. }
    procedure SetMin(AValue: Double);
    procedure SetMax(AValue: Double);
  end;

  TForm = class(TWidget)
  private
    FFields: array of TFormField;
    FTheme: TTheme;
    FState: TFormState;
    FFocused: Integer;
    FOnSubmit: TFormSubmitEvent;
    FOnInvalid: TFormEvent;
    FOnDirty: TFormEvent;
    function IndexOfField(const AName: string): Integer;
  protected
    procedure RenderContent(const S: ISurface); virtual;
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    { Register a field. A duplicate name is refused HERE, at add time, because
      discovering it at submit means the operator's input silently goes to the
      wrong key. Returns the field for chaining. }
    function AddField(AField: TFormField): TFormField;
    function FieldCount: Integer;
    function FieldAt(AIndex: Integer): TFormField;
    function FieldNamed(const AName: string): TFormField;
    { A sibling's value during validation, so cross-field rules can exist. }
    function ValueOf(const AName: string): string;
    function Valid: Boolean;
    { Validate every field, mark each one, then emit OnSubmit with the mapping
      ONLY when all pass. OnInvalid fires instead, so a host can beep or focus
      the first bad field. A form that half-submits is how you get a row with a
      name and no endpoint. }
    procedure Submit;
    { Clear every field's error state, e.g. after a server-side failure has been
      dealt with. }
    procedure ClearErrors;
    procedure FocusNext;
    procedure FocusPrev;
    function FocusedField: TFormField;
    function FirstInvalid: TFormField;
    { Told by a field when its value changed, so a host can enable a Save button
      or mark the dialog dirty. }
    procedure FieldChanged(AField: TFormField);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property State: TFormState read FState;
    property Theme: TTheme read FTheme;
    property OnSubmit: TFormSubmitEvent read FOnSubmit write FOnSubmit;
    property OnInvalid: TFormEvent read FOnInvalid write FOnInvalid;
    property OnDirty: TFormEvent read FOnDirty write FOnDirty;
  end;

{ Optional-number parsing, shared rather than copied into a third form. Absent
  (empty or whitespace) is Has=False and value 0; a non-empty unparseable string
  is Has=False too, and ValidOpt tells the caller which it was. }
function ParseOptFloat(const AText: string; out AValue: Double;
  out AHas: Boolean): Boolean;
function ParseOptInt(const AText: string; out AValue: Integer;
  out AHas: Boolean): Boolean;

implementation

{ A '.' decimal separator regardless of locale. On a comma-decimal locale the
  default settings make StrToFloat('0.2') fail or read as 2, so a value typed
  here would disagree with what the provider sends. }
function InvariantFormat: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function ParseOptFloat(const AText: string; out AValue: Double;
  out AHas: Boolean): Boolean;
var
  S: string;
  V: Double;
begin
  V := 0;
  AValue := 0;
  AHas := False;
  S := Trim(AText);
  if S = '' then
    Exit(True);          { absent, and that is not an error }
  { JSONFormatSettings: on a comma-decimal locale StrToFloat('0.2') is not 0.2. }
  if not TryStrToFloat(S, V, InvariantFormat) then
    Exit(False);
  AValue := V;
  AHas := True;
  Result := True;
end;

function ParseOptInt(const AText: string; out AValue: Integer;
  out AHas: Boolean): Boolean;
var
  S: string;
  V: Integer;
begin
  AValue := 0;
  AHas := False;
  S := Trim(AText);
  if S = '' then
    Exit(True);
  if not TryStrToInt(S, V) then
    Exit(False);
  AValue := V;
  AHas := True;
  Result := True;
end;

{ --- TFormField --------------------------------------------------------- }

constructor TFormField.Create(AForm: TForm; const AName: string);
begin
  inherited Create;
  FForm := AForm;
  FName := AName;
  FLabel := AName;
  FForceInvalid := False;
  if AForm <> nil then
    { Registration happens ONCE, here. An Add that registered too would make the
      second call a duplicate-name error for a field that is not a duplicate. }
    AForm.AddField(Self);
end;

function TFormField.FieldValid: Boolean;
begin
  Result := True;
end;

function TFormField.ErrorText: string;
begin
  Result := '';
end;

function TFormField.Value: string;
begin
  Result := '';
end;

procedure TFormField.SetValue(const AValue: string);
begin
  { Base field holds nothing; a kind that stores a value overrides. }
end;

function TFormField.Valid: Boolean;
begin
  if FForceInvalid then
    Exit(False);
  Result := FieldValid;
end;

procedure TFormField.PaintError(const S: ISurface; const ARow: TRect);
var
  Err: string;
  X: Integer;
  C: TCell;
begin
  Err := ErrorText;
  { A forced-invalid field with no message still has to say SOMETHING, or the
    operator sees a rejected value with no reason. }
  if (Err = '') and FForceInvalid then
    Err := 'invalid';
  if Err = '' then
    Exit;
  X := ARow.X + ARow.W - StringWidth(UnicodeString(Err));
  if X < ARow.X then
    X := ARow.X;
  C := Default(TCell);
  C.Ch := UnicodeString(Err);
  C.Attr := DefaultAttr;
  S.Put(X, ARow.Y, C);
end;

procedure TFormField.RenderField(const S: ISurface; const ARow: TRect);
begin
  { A kind that draws nothing still draws its error, via Render. }
end;

procedure TFormField.Render(const S: ISurface);
var
  Row: TRect;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  Row := Rc(FBounds.X, FBounds.Y, FBounds.W, 1);
  RenderField(S, Row);
  PaintError(S, Row);
end;

{ --- TTextField --------------------------------------------------------- }

constructor TTextField.Create(AForm: TForm; const AName: string);
begin
  inherited Create(AForm, AName);
  FEdit := TPromptLine.Create('');
  FRequired := False;
  FPlaceholder := '';
end;

destructor TTextField.Destroy;
begin
  FEdit.Free;
  inherited Destroy;
end;

function TTextField.Value: string;
begin
  Result := FEdit.Text;
end;

procedure TTextField.SetValue(const AValue: string);
begin
  FEdit.SetText(AValue);
end;

function TTextField.FieldValid: Boolean;
begin
  Result := (not FRequired) or (Trim(FEdit.Text) <> '');
end;

function TTextField.ErrorText: string;
begin
  if FieldValid then
    Result := ''
  else if FRequired then
    Result := 'required'
  else
    Result := 'invalid';
end;

procedure TTextField.RenderField(const S: ISurface; const ARow: TRect);
begin
  FEdit.Arrange(ARow);
  FEdit.Render(S);
end;

function TTextField.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := FEdit.HandleEvent(E);
  if Result and (FForm <> nil) then
    FForm.FieldChanged(Self);
end;

function TTextField.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := AAvail.W;
  Result.H := 1;
end;

procedure TTextField.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  FEdit.Arrange(Rc(ABounds.X, ABounds.Y, ABounds.W, 1));
end;

{ --- TSecretField ------------------------------------------------------- }

constructor TSecretField.Create(AForm: TForm; const AName: string);
begin
  inherited Create(AForm, AName);
  FEdit.Mask := True;
  FWantsClear := False;
end;

function TSecretField.GetMasked: Boolean;
begin
  Result := FEdit.Mask;
end;

procedure TSecretField.SetMasked(AValue: Boolean);
begin
  FEdit.Mask := AValue;
end;

procedure TSecretField.Clear;
begin
  inherited SetValue('');
  FWantsClear := True;
end;

function TSecretField.WantsClear: Boolean;
begin
  Result := FWantsClear;
end;

{ --- TPickField --------------------------------------------------------- }

constructor TPickField.Create(AForm: TForm; const AName: string);
begin
  inherited Create(AForm, AName);
  FIndex := 0;
  FAllowEmpty := False;
end;

procedure TPickField.SetItems(const AItems: array of string);
var
  I: Integer;
begin
  SetLength(FItems, Length(AItems));
  for I := 0 to High(AItems) do
    FItems[I] := AItems[I];
  FIndex := 0;
end;

function TPickField.ItemCount: Integer;
begin
  Result := Length(FItems);
end;

function TPickField.SelectedIndex: Integer;
begin
  Result := FIndex;
end;

procedure TPickField.Select(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex < Length(FItems)) then
    FIndex := AIndex;
end;

procedure TPickField.Cycle(ADelta: Integer);
begin
  if Length(FItems) = 0 then
    Exit;
  Inc(FIndex, ADelta);
  { Wrap, so a two-item pick is not a dead end in one direction. }
  while FIndex < 0 do
    Inc(FIndex, Length(FItems));
  while FIndex >= Length(FItems) do
    Dec(FIndex, Length(FItems));
end;

function TPickField.Value: string;
begin
  if (FIndex >= 0) and (FIndex < Length(FItems)) then
    Result := FItems[FIndex]
  else
    Result := '';
end;

procedure TPickField.SetValue(const AValue: string);
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    if FItems[I] = AValue then
    begin
      FIndex := I;
      Exit;
    end;
end;

function TPickField.FieldValid: Boolean;
begin
  if Length(FItems) = 0 then
    Exit(FAllowEmpty);
  { A selected index that has drifted out of range is invalid, not silent. }
  if (FIndex < 0) or (FIndex > High(FItems)) then
    Exit(FAllowEmpty);
  Result := True;
end;

function TPickField.ErrorText: string;
begin
  if FieldValid then
    Result := ''
  else
    Result := 'choose one';
end;

procedure TPickField.RenderField(const S: ISurface; const ARow: TRect);
var
  T: string;
  I: Integer;
  C: TCell;
begin
  if ItemCount = 0 then
    T := ''
  else
    T := '< ' + Value + ' >';
  if T = '' then
    Exit;
  for I := 1 to Length(T) do
  begin
    if ARow.X + I - 1 >= ARow.X + ARow.W then
      Break;
    C := Default(TCell);
    C.Ch := UnicodeString(T[I]);
    C.Attr := DefaultAttr;
    S.Put(ARow.X + I - 1, ARow.Y, C);
  end;
end;

function TPickField.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := False;
  if E.Kind <> ikKey then
    Exit;
  case E.Key.Kind of
    kkLeft:
      begin
        Cycle(-1);
        if (FForm <> nil) and (ItemCount > 0) then
          FForm.FieldChanged(Self);
        Result := True;
      end;
    kkRight:
      begin
        Cycle(1);
        if (FForm <> nil) and (ItemCount > 0) then
          FForm.FieldChanged(Self);
        Result := True;
      end;
  else
    Result := False;
  end;
end;

{ --- TNumberField ------------------------------------------------------- }

constructor TNumberField.Create(AForm: TForm; const AName: string);
begin
  inherited Create(AForm, AName);
  FHasValue := False;
  FAsFloat := 0;
  FWhole := False;
  FHasMin := False;
  FHasMax := False;
end;

procedure TNumberField.SetMin(AValue: Double);
begin
  FMinValue := AValue;
  FHasMin := True;
end;

procedure TNumberField.SetMax(AValue: Double);
begin
  FMaxValue := AValue;
  FHasMax := True;
end;

procedure TNumberField.Commit;
var
  IV: Integer;
begin
  { Parse the text into the value. Unparseable leaves HasValue False, and
    FieldValid reports the reason - it does not silently become 0. }
  FHasValue := False;
  FAsFloat := 0;
  if Trim(Value) = '' then
    Exit;
  if FWhole then
  begin
    if TryStrToInt(Trim(Value), IV) then
    begin
      FAsFloat := IV;
      FHasValue := True;
    end;
  end
  else
    FHasValue := TryStrToFloat(Trim(Value), FAsFloat, InvariantFormat);
end;

function TNumberField.AsInteger: Integer;
begin
  Result := Round(FAsFloat);
end;

function TNumberField.FieldValid: Boolean;
begin
  if Trim(Value) = '' then
    { Absent is valid: the field is optional by construction. }
    Exit(True);
  if not FHasValue then
    Exit(False);
  if FHasMin and (FAsFloat < FMinValue) then
    Exit(False);
  if FHasMax and (FAsFloat > FMaxValue) then
    Exit(False);
  Result := True;
end;

function TNumberField.ErrorText: string;
begin
  if FieldValid then
    Exit('');
  if (Trim(Value) <> '') and (not FHasValue) then
  begin
    if FWhole then
      Exit('whole number');
    Exit('number');
  end;
  { Named as a RANGE, not "invalid": the operator needs to know the boundary. }
  if FHasMin and (FAsFloat < FMinValue) then
    Exit('min ' + FloatToStr(FMinValue, InvariantFormat));
  Exit('max ' + FloatToStr(FMaxValue, InvariantFormat));
end;

{ --- TForm -------------------------------------------------------------- }

constructor TForm.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FState := fsPristine;
  FFocused := 0;
end;

destructor TForm.Destroy;
var
  I: Integer;
begin
  { TForm owns its fields outright - it is not a container, so nothing else
    frees them. }
  for I := 0 to High(FFields) do
    FFields[I].Free;
  FFields := nil;
  inherited Destroy;
end;

function TForm.AddField(AField: TFormField): TFormField;
begin
  Result := AField;
  if AField = nil then
    Exit;
  { Refused here, not at submit: a duplicate name means one field's input goes
    silently to another field's key. }
  if IndexOfField(AField.FieldName) >= 0 then
    raise Exception.CreateFmt('TForm: duplicate field name "%s"',
      [AField.FieldName]);
  SetLength(FFields, Length(FFields) + 1);
  FFields[High(FFields)] := AField;
end;

function TForm.IndexOfField(const AName: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FFields) do
    if FFields[I].FieldName = AName then
      Exit(I);
end;

function TForm.FieldCount: Integer;
begin
  Result := Length(FFields);
end;

function TForm.FieldAt(AIndex: Integer): TFormField;
begin
  if (AIndex >= 0) and (AIndex <= High(FFields)) then
    Result := FFields[AIndex]
  else
    Result := nil;
end;

function TForm.FieldNamed(const AName: string): TFormField;
var
  I: Integer;
begin
  I := IndexOfField(AName);
  if I >= 0 then
    Result := FFields[I]
  else
    Result := nil;
end;

function TForm.ValueOf(const AName: string): string;
var
  F: TFormField;
begin
  F := FieldNamed(AName);
  if F <> nil then
    Result := F.Value
  else
    Result := '';
end;

function TForm.Valid: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FFields) do
    if not FFields[I].Valid then
      Exit(False);
  Result := True;
end;

function TForm.FirstInvalid: TFormField;
var
  I: Integer;
begin
  for I := 0 to High(FFields) do
    if not FFields[I].Valid then
      Exit(FFields[I]);
  Result := nil;
end;

procedure TForm.ClearErrors;
var
  I: Integer;
begin
  for I := 0 to High(FFields) do
    FFields[I].ForceInvalid := False;
  FState := fsPristine;
end;

procedure TForm.Submit;
var
  I: Integer;
  Values: TFieldValueArray;
begin
  { Number fields re-parse first: validation must see the CURRENT text, not the
    value from when the field was last touched. }
  for I := 0 to High(FFields) do
    if FFields[I] is TNumberField then
      TNumberField(FFields[I]).Commit;

  if not Valid then
  begin
    FState := fsInvalid;
    if Assigned(FOnInvalid) then
      FOnInvalid();
    Exit;
  end;

  FState := fsValid;
  if not Assigned(FOnSubmit) then
    Exit;

  { Registration order, so a caller can rely on it. }
  SetLength(Values, Length(FFields));
  for I := 0 to High(FFields) do
  begin
    Values[I].Name := FFields[I].FieldName;
    Values[I].Value := FFields[I].Value;
  end;
  FOnSubmit(Values);
end;

procedure TForm.FocusNext;
begin
  if Length(FFields) = 0 then
    Exit;
  FFields[FFocused].Focused := False;
  Inc(FFocused);
  if FFocused > High(FFields) then
    FFocused := 0;
  FFields[FFocused].Focused := True;
end;

procedure TForm.FocusPrev;
begin
  if Length(FFields) = 0 then
    Exit;
  FFields[FFocused].Focused := False;
  Dec(FFocused);
  if FFocused < 0 then
    FFocused := High(FFields);
  FFields[FFocused].Focused := True;
end;

function TForm.FocusedField: TFormField;
begin
  Result := FieldAt(FFocused);
end;

procedure TForm.FieldChanged(AField: TFormField);
begin
  if FState <> fsPristine then
    FState := fsPristine;
  if Assigned(FOnDirty) then
    FOnDirty();
end;

procedure TForm.RenderContent(const S: ISurface);
var
  I: Integer;
begin
  for I := 0 to High(FFields) do
    if FFields[I].Visible then
      FFields[I].Render(S);
end;

procedure TForm.Render(const S: ISurface);
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  S.PushClip(FBounds);
  RenderContent(S);
  S.PopClip;
end;

function TForm.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := AAvail.W;
  { One row per field, plus one for a form-level message line. }
  Result.H := Length(FFields) + 1;
end;

procedure TForm.Arrange(const ABounds: TRect);
var
  I, Y: Integer;
begin
  inherited Arrange(ABounds);
  { One row each, in registration order - the order the operator sees. }
  Y := ABounds.Y;
  for I := 0 to High(FFields) do
  begin
    FFields[I].Arrange(Rc(ABounds.X, Y, ABounds.W, 1));
    Inc(Y);
  end;
end;

function TForm.HandleEvent(const E: TInputEvent): Boolean;
var
  F: TFormField;
begin
  Result := False;
  if E.Kind <> ikKey then
    Exit;
  case E.Key.Kind of
    kkTab:
      begin
        FocusNext;
        Result := True;
      end;
    kkDown:
      begin
        FocusNext;
        Result := True;
      end;
    kkUp:
      begin
        FocusPrev;
        Result := True;
      end;
  else
    { Everything else goes to the focused field, so typing reaches the editor
      without the form caring which kind it is. }
    F := FocusedField;
    if F <> nil then
      Result := F.HandleEvent(E);
  end;
end;

end.
