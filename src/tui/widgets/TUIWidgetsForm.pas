unit TUIWidgetsForm;
{ A form container and its field kinds.

  THREE LANES were about to hand-roll the same ~400 lines: a container of
  wrapped inputs, manual focus cycling with an index and a wrap, validation
  living in the widget, and a deferred-close callback. This is that, once.

  The model is an HTML form, which is the operator's own description:

    - a field REGISTERS with its form by name; a duplicate name is refused at
      add time rather than discovered at submit
    - the form brokers values, so a field can validate against its siblings
      (a model is meaningless without its provider)
    - Submit validates everything, marks the invalid fields, and emits the
      name->value map ONLY when all of them pass

  The form is a CONTAINER, not a dialog. It sits inside TModal, which already
  owns the frame, the title, the 80% cap and the fixed CTA footer - so a form
  dialog is a TForm inside a TModal and nothing else.

  Three rules this unit exists to enforce, each paid for by a bug:

  1. Touched is set on BLUR, not on keystroke. Marking a field invalid while the
     operator is still typing is hostile, and the workaround for its absence -
     clearing the error on every keystroke - makes errors flash and vanish.
  2. FieldValid is pairwise. A field can read its siblings through ValueOf, so
     cross-field rules are expressible at all.
  3. The field RENDERS its own error. A field that can be invalid but cannot
     draw why looks like nothing happened - and did, for weeks, in the provider
     form. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, Classes,
  TUIBase, TUIInput,
  TUISurface, TUITheme, TUIWidget,
  TUIGrapheme,
  TUIWidgetsText, TUIWidgetsPrompt;

type
  TFormState = (fsPristine, fsValid, fsInvalid);

  { The submitted mapping. A TStringList rather than a dictionary: forms are
    small, order is stable for a predictable test, and it is copyable. }
  TFieldValues = TStringList;

  TFormSubmitEvent = procedure(const AValues: TFieldValues) of object;
  TFormEvent = procedure of object;

  TForm = class;

  { One field. Descendants supply a value, a validity verdict and their own
    rendering; this class owns the parts every field shares: the name, the
    touched flag, the error text, and the link back to the form. }
  TFormField = class(TWidget)
  private
    FForm: TForm;
    FName: string;
    FLabel: string;
    FTouched: Boolean;
    FForceInvalid: Boolean;
    function GetErrorText: string;
  protected
    { The subclass's own verdict, BEFORE the touched rule is applied. A field
      that has not been touched still reports honestly here; Valid applies the
      courtesy. }
    function FieldValid: Boolean; virtual;
    { Why it is invalid, drawn by the field itself. '' when valid. }
    function ErrorText: string; virtual;
    { The field's own row rendering, painted by RenderRow. }
    procedure RenderField(const S: ISurface; const ARow: TRect); virtual;
  public
    constructor Create(AForm: TForm; const AName: string);
    { Value as the form sees it. '' is a legitimate value; use HasValue to tell
      "empty" from "absent" on optional fields. }
    function Value: string; virtual;
    { A blur: from here on the field may show an error. }
    procedure Blur;
    { Validate now and stop being polite about it - used by Submit, which has to
      mark every bad field at once. }
    procedure Touch;
    procedure Render(const S: ISurface); override;
    property Form: TForm read FForm;
    property FieldName: string read FName;
    property LabelText: string read FLabel write FLabel;
    { True once the operator has left the field at least once. }
    property Touched: Boolean read FTouched;
    { Valid only when touched: an untouched field is not yet wrong, merely
      unvisited. Submit calls Touch first, so a submit with an empty required
      field does mark it. }
    function Valid: Boolean;
    property ForceInvalid: Boolean read FForceInvalid write FForceInvalid;
  end;

  { A text field built on TPromptLine, so caret, wrapping and history come from
    the editor rather than being re-implemented. }
  TTextField = class(TFormField)
  private
    FEdit: TPromptLine;
    FRequired: Boolean;
  protected
    function FieldValid: Boolean; override;
    function ErrorText: string; override;
    procedure RenderField(const S: ISurface; const ARow: TRect); override;
  public
    constructor Create(AForm: TForm; const AName: string);
    destructor Destroy; override;
    function Value: string; override;
    procedure SetValue(const AText: string);
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    property Required: Boolean read FRequired write FRequired;
    property Edit: TPromptLine read FEdit;
  end;

  { A field that cycles a known list. This is the provider/model pick, and it is
    the piece that unblocks the other lanes, so it ships in the first wave. }
  TPickField = class(TFormField)
  private
    FOptions: TStringArray;
    FIndex: Integer;
    FAllowEmpty: Boolean;
  protected
    function FieldValid: Boolean; override;
    function ErrorText: string; override;
    procedure RenderField(const S: ISurface; const ARow: TRect); override;
  public
    constructor Create(AForm: TForm; const AName: string);
    procedure SetOptions(const AOptions: array of string);
    function OptionCount: Integer;
    function SelectedIndex: Integer;
    procedure Select(AIndex: Integer);
    procedure Cycle(ADelta: Integer);
    function Value: string; override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property AllowEmpty: Boolean read FAllowEmpty write FAllowEmpty;
  end;

  { The container. Owns nothing visually; it arranges its fields and brokers
    values, focus and submission. }
  { Deliberately NOT a TContainer. A grid with one column and one row holds one
    child; every field after the first would be silently dropped and never
    owned - a leak AND a lie about ownership. TForm arranges and renders its
    fields itself, so it owns them directly. }
  TForm = class(TWidget)
  private
    FFields: array of TFormField;
    FTheme: TTheme;
    FState: TFormState;
    FFocused: Integer;
    FOnSubmit: TFormSubmitEvent;
    FOnInvalid: TFormEvent;
    function IndexOfField(const AName: string): Integer;
  protected
    procedure RenderContent(const S: ISurface);
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    { Register a field. A duplicate name is refused HERE, at add time, because
      discovering it at submit means the operator's input silently goes to the
      wrong key. Returns the field for chaining. }
    function AddField(AField: TFormField): TFormField;
    function FieldCount: Integer;
    function FieldAt(AIndex: Integer): TFormField;
    function FieldByName(const AName: string): TFormField;
    { A sibling's value during validation, so cross-field rules can exist. }
    function ValueOf(const AName: string): string;
    function Valid: Boolean;
    { Validate every field, marking each one, then emit OnSubmit with the
      mapping ONLY when all pass. OnInvalid fires instead, so a host can beep or
      focus the first bad field. A form that half-submits is how you get a row
      with a name and no endpoint. }
    procedure Submit;
    procedure FocusNext;
    procedure FocusPrev;
    function FocusedField: TFormField;
    function FirstInvalid: TFormField;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property State: TFormState read FState;
    property Theme: TTheme read FTheme;
    property OnSubmit: TFormSubmitEvent read FOnSubmit write FOnSubmit;
    property OnInvalid: TFormEvent read FOnInvalid write FOnInvalid;
  end;

implementation

{ A rect constructor. Local, as every other TUI unit does. }
function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

{ --- TFormField --------------------------------------------------------- }

constructor TFormField.Create(AForm: TForm; const AName: string);
begin
  inherited Create;
  FForm := AForm;
  FName := AName;
  FLabel := AName;
  FTouched := False;
  FForceInvalid := False;
  if AForm <> nil then
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

function TFormField.Valid: Boolean;
begin
  { Untouched is not wrong - it is unvisited. Submit calls Touch first, so a
    submit that finds an empty required field does mark it. }
  if not FTouched then
    Exit(True);
  Result := FieldValid and (not FForceInvalid);
end;

function TFormField.GetErrorText: string;
begin
  Result := '';
  if not FTouched then
    Exit;
  if FForceInvalid then
    Exit('invalid');
  Result := ErrorText;
end;

procedure TFormField.Blur;
begin
  { The only place Touched is set. Per-keystroke validation is hostile: it marks
    you wrong before you have finished typing. }
  FTouched := True;
end;

procedure TFormField.Touch;
begin
  FTouched := True;
end;

procedure TFormField.RenderField(const S: ISurface; const ARow: TRect);
begin
  if ARow.H <= 0 then
    Exit;
end;

procedure TFormField.Render(const S: ISurface);
var
  Row: TRect;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  Row := Rc(FBounds.X, FBounds.Y, FBounds.W, 1);
  RenderField(S, Row);
end;

{ --- TTextField --------------------------------------------------------- }

constructor TTextField.Create(AForm: TForm; const AName: string);
begin
  inherited Create(AForm, AName);
  FEdit := TPromptLine.Create('');
  FRequired := False;
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

procedure TTextField.SetValue(const AText: string);
begin
  FEdit.SetText(AText);
end;

function TTextField.FieldValid: Boolean;
begin
  Result := (not FRequired) or (Trim(FEdit.Text) <> '');
end;

function TTextField.ErrorText: string;
begin
  if not FieldValid then
    Result := 'required'
  else
    Result := '';
end;

procedure TTextField.RenderField(const S: ISurface; const ARow: TRect);
var
  C: TCell;
  I: Integer;
  Err: string;
begin
  FEdit.Arrange(ARow);
  FEdit.Render(S);
  { The error is DRAWN by the field. FError set with nothing painting it is how
    "name is required" went unseen for weeks. }
  Err := GetErrorText;
  if Err <> '' then
  begin
    I := ARow.X + ARow.W - StringWidth(UnicodeString(Err));
    if I < ARow.X then
      I := ARow.X;
    C := Default(TCell);
    C.Attr := DefaultAttr;
    C.Ch := UnicodeString(Err);
    S.Put(I, ARow.Y, C);
  end;
end;

function TTextField.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := FEdit.HandleEvent(E);
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

{ --- TPickField --------------------------------------------------------- }

constructor TPickField.Create(AForm: TForm; const AName: string);
begin
  inherited Create(AForm, AName);
  FIndex := 0;
  FAllowEmpty := False;
end;

procedure TPickField.SetOptions(const AOptions: array of string);
var
  I: Integer;
begin
  SetLength(FOptions, Length(AOptions));
  for I := 0 to High(AOptions) do
    FOptions[I] := AOptions[I];
  FIndex := 0;
end;

function TPickField.OptionCount: Integer;
begin
  Result := Length(FOptions);
end;

function TPickField.SelectedIndex: Integer;
begin
  Result := FIndex;
end;

procedure TPickField.Select(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex < Length(FOptions)) then
    FIndex := AIndex;
end;

procedure TPickField.Cycle(ADelta: Integer);
begin
  if Length(FOptions) = 0 then
    Exit;
  Inc(FIndex, ADelta);
  { Wrap, so a pick with two options is not a dead end in one direction. }
  while FIndex < 0 do
    Inc(FIndex, Length(FOptions));
  while FIndex >= Length(FOptions) do
    Dec(FIndex, Length(FOptions));
end;

function TPickField.Value: string;
begin
  if (FIndex >= 0) and (FIndex < Length(FOptions)) then
    Result := FOptions[FIndex]
  else
    Result := '';
end;

function TPickField.FieldValid: Boolean;
begin
  if FAllowEmpty and (Length(FOptions) = 0) then
    Exit(True);
  Result := Length(FOptions) > 0;
end;

function TPickField.ErrorText: string;
begin
  if not FieldValid then
    Result := 'nothing to pick'
  else
    Result := '';
end;

procedure TPickField.RenderField(const S: ISurface; const ARow: TRect);
var
  C: TCell;
  T, Err: string;
  I: Integer;
begin
  T := '< ' + Value + ' >';
  for I := 1 to Length(T) do
  begin
    if ARow.X + I - 1 >= ARow.X + ARow.W then
      Break;
    C := Default(TCell);
    C.Ch := UnicodeString(T[I]);
    C.Attr := DefaultAttr;
    S.Put(ARow.X + I - 1, ARow.Y, C);
  end;
  Err := GetErrorText;
  if Err <> '' then
  begin
    I := ARow.X + ARow.W - StringWidth(UnicodeString(Err));
    if I < ARow.X then
      I := ARow.X;
    C := Default(TCell);
    C.Ch := UnicodeString(Err);
    C.Attr := DefaultAttr;
    S.Put(I, ARow.Y, C);
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
        Result := True;
      end;
    kkRight:
      begin
        Cycle(1);
        Result := True;
      end;
  else
    { Every other key is not the pick's business. }
    Result := False;
  end;
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
  if AField = nil then
    Exit(nil);
  { Refused here, not at submit: a duplicate name means one field's input goes
    silently to another field's key. }
  if IndexOfField(AField.FieldName) >= 0 then
    raise Exception.CreateFmt('TForm: duplicate field name "%s"',
      [AField.FieldName]);
  SetLength(FFields, Length(FFields) + 1);
  FFields[High(FFields)] := AField;
  Result := AField;
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

function TForm.FieldByName(const AName: string): TFormField;
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
  F := FieldByName(AName);
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

procedure TForm.Submit;
var
  I: Integer;
  Values: TFieldValues;
begin
  { Touch every field FIRST: an untouched empty required field must be marked by
    a submit, or the operator presses the button and nothing happens. }
  for I := 0 to High(FFields) do
    FFields[I].Touch;

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
  { Only on success. A form that half-submits produces a row with a name and no
    endpoint. }
  Values := TFieldValues.Create;
  try
    for I := 0 to High(FFields) do
      Values.Add(FFields[I].FieldName + '=' + FFields[I].Value);
    FOnSubmit(Values);
  finally
    Values.Free;
  end;
end;

procedure TForm.FocusNext;
begin
  if Length(FFields) = 0 then
    Exit;
  Inc(FFocused);
  if FFocused > High(FFields) then
    FFocused := 0;
end;

procedure TForm.FocusPrev;
begin
  if Length(FFields) = 0 then
    Exit;
  Dec(FFocused);
  if FFocused < 0 then
    FFocused := High(FFields);
end;

function TForm.FocusedField: TFormField;
begin
  Result := FieldAt(FFocused);
end;

procedure TForm.RenderContent(const S: ISurface);
var
  I: Integer;
begin
  for I := 0 to High(FFields) do
    if FFields[I].Visible then
      FFields[I].Render(S);
end;

function TForm.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := AAvail.W;
  { One row per field plus one for the message line. }
  Result.H := Length(FFields) + 1;
end;

procedure TForm.Arrange(const ABounds: TRect);
var
  I, Y: Integer;
  R: TRect;
begin
  inherited Arrange(ABounds);
  { Lay the fields out ourselves: one row each, in registration order, which is
    the order the operator sees. }
  Y := ABounds.Y;
  for I := 0 to High(FFields) do
  begin
    R := Rc(ABounds.X, Y, ABounds.W, 1);
    FFields[I].Arrange(R);
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
    kkDown, kkTab:
      begin
        { Moving focus BLURS the field being left, which is where Touched is
          set - the only place. }
        if (FFocused >= 0) and (FFocused <= High(FFields)) then
          FFields[FFocused].Blur;
        FocusNext;
        Result := True;
      end;
    kkUp:
      begin
        if (FFocused >= 0) and (FFocused <= High(FFields)) then
          FFields[FFocused].Blur;
        FocusPrev;
        Result := True;
      end;
  else
    F := FocusedField;
    if F <> nil then
      Result := F.HandleEvent(E);
  end;
end;

end.
