unit HildiProviderForm;
{ The add/edit form for a provider.

  THREE FIELDS, and the middle one is a PICK, not a text box: the provider slug
  must come from the registered adapters. Free-typing a slug is how an unusable
  row gets created, and while the list renders such a row honestly, it is better
  not to allow it in the first place.

  The form OWNS validation and reports it inline; the host owns persistence. That
  split keeps the same discipline as the list: everything decidable without a
  store is decided here and can be tested. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  TUIBase, TUIInput, TUISurface, TUIWidget, TUITheme,
  TUIWidgetsModal, TUIWidgetsPrompt,
  HildiStore;

type
  { 'add' | 'save' | 'remove' | 'cancel' }
  TProviderFormAction = procedure(const AAction: string) of object;

  { What the form hands back on save. The host turns this into a row. }
  TProviderFormResult = record
    Name: string;
    Key: string;
    Endpoint: string;
    Model: string;
    { The API key as typed. Transient: the host hands it to SetProviderSecret and
      never puts it on a TProviderRow, because the row is what gets rendered. }
    Secret: string;
    { True when the operator typed a key. False leaves any stored key alone, so
      editing the model does not require retyping the secret. }
    SecretSet: Boolean;
    { True when the operator asked to REMOVE the stored key. Separate from
      SecretSet because '' cannot mean both "leave it" and "delete it". }
    SecretClear: Boolean;
  end;

  TProviderForm = class(TModal)
  private
    FName, FKey, FEndpoint, FModel, FSecret: TPromptLine;
    FBody: TContainer;
    FFocus: Integer;
    FEditing: Boolean;
    FError: string;
    FBusy: Boolean;
    FSecretClear: Boolean;
    FKeys: TStringArray;
    FOnAction: TProviderFormAction;
    procedure RefreshFooter;
    procedure MoveFocus(ADelta: Integer);
    procedure FocusField(AIndex: Integer);
    procedure Submit;
    procedure SubmitText(const AText: string);
    procedure Changed;
  public
    { AKeys is the list of provider slugs the form may offer, in order. }
    constructor Create(const ATheme: TTheme; const AKeys: TStringArray;
      AEditing: Boolean);
    destructor Destroy; override;
    { Fill the fields for an edit. Ignored for an add. }
    procedure LoadFrom(const ARow: TProviderRow);
    function Result_: TProviderFormResult;
    { The user pressed ctrl+r: cycle to the next provider slug. }
    function OnNextProvider: Boolean;
    { The host reports a failed connection check here. The form does no I/O.
      A BUSY state holds the modal open and disables the CTAs while a check is in
      flight, so the operator cannot double-submit. }
    procedure SetError(const AText: string);
    procedure SetBusy(AValue: Boolean);
    property Error_: string read FError;
    property OnAction: TProviderFormAction read FOnAction write FOnAction;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  protected
    procedure RenderContent(const S: ISurface); override;
    procedure FooterClicked(const AKey: string); override;
  end;

{ The slugs this build can speak, in registration order. Exported so a test can
  assert the form offers exactly the registered providers. }
function RegisteredProviderKeys: TStringArray;

implementation

uses
  LLMProvider, LLMProviders;

function RegisteredProviderKeys: TStringArray;
var
  Reg: TProviderModelRegistry;
  I: Integer;
begin
  Result := nil;
  Reg := RegisteredProviders;
  for I := 0 to Reg.Count - 1 do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Reg[I].Key;
  end;
end;

constructor TProviderForm.Create(const ATheme: TTheme; const AKeys: TStringArray;
  AEditing: Boolean);
begin
  FKeys := AKeys;
  FEditing := AEditing;
  FFocus := 0;
  FName := TPromptLine.Create('name: ');
  FKey := TPromptLine.Create('provider: ');
  FEndpoint := TPromptLine.Create('endpoint: ');
  FModel := TPromptLine.Create('model: ');
  { The key is a field like any other, but it is NOT read back from the row: a
    row has no secret, by design. Editing shows it empty and leaves the stored
    key alone unless something is typed. }
  FSecret := TPromptLine.Create('api key: ');
  { Masked on screen, plain in memory. A secret field that renders its own value
    is a shoulder-surfing bug in a dialog whose whole job includes collecting it. }
  FSecret.Mask := True;
  FName.OnSubmit := SubmitText;
  FKey.OnSubmit := SubmitText;
  FEndpoint.OnSubmit := SubmitText;
  FModel.OnSubmit := SubmitText;
  FSecret.OnSubmit := SubmitText;
  { The four prompts live in a container so TModal has something to arrange and
    render; a nil content would leave the frame empty. }
  FBody := TContainer.Create([Fill(1)], [Auto, Auto, Auto, Auto, Auto]);
  FBody.Add(FName, 0, 0);
  FBody.Add(FKey, 0, 1);
  FBody.Add(FEndpoint, 0, 2);
  FBody.Add(FModel, 0, 3);
  FBody.Add(FSecret, 0, 4);
  inherited Create(ATheme, FBody, False);
  if AEditing then
    SetTitle('edit provider')
  else
    SetTitle('add provider');
  { An add starts on the name, which is the first thing to choose. }
  FocusField(0);
  RefreshFooter;
end;

destructor TProviderForm.Destroy;
begin
  FName.Free;
  FKey.Free;
  FEndpoint.Free;
  FModel.Free;
  FSecret.Free;
  inherited Destroy;
end;

procedure TProviderForm.RefreshFooter;
begin
  { Two shapes, as specified. An ADD has one commit path; an edit can also
    remove, which is destructive and therefore chorded rather than a bare letter
    beside save. }
  if FEditing then
    SetFooter('ctrl+x clear key   ctrl+d remove   enter save   esc cancel')
  else
    SetFooter('enter add   esc cancel');
end;

procedure TProviderForm.FocusField(AIndex: Integer);
begin
  FName.Active := AIndex = 0;
  FKey.Active := AIndex = 1;
  FEndpoint.Active := AIndex = 2;
  FModel.Active := AIndex = 3;
  FSecret.Active := AIndex = 4;
  FFocus := AIndex;
end;

procedure TProviderForm.MoveFocus(ADelta: Integer);
var
  Next: Integer;
begin
  Next := FFocus + ADelta;
  if Next < 0 then
    Next := 3;
  if Next > 4 then
    Next := 0;
  FocusField(Next);
end;

procedure TProviderForm.LoadFrom(const ARow: TProviderRow);
begin
  FName.SetText(ARow.Name);
  FKey.SetText(ARow.Key);
  FEndpoint.SetText(ARow.Endpoint);
  FModel.SetText(ARow.Model);
  FocusField(0);
end;

function TProviderForm.OnNextProvider: Boolean;
var
  Cur, I, Next: Integer;
begin
  Result := True;
  Cur := -1;
  for I := 0 to High(FKeys) do
    if SameText(FKeys[I], string(FKey.Text)) then
      Cur := I;
  if Cur < 0 then
    Next := 0
  else
    Next := (Cur + 1) mod Length(FKeys);
  FKey.SetText(FKeys[Next]);
  Changed;
end;

procedure TProviderForm.SetError(const AText: string);
begin
  FError := AText;
end;

procedure TProviderForm.SetBusy(AValue: Boolean);
begin
  FBusy := AValue;
end;

procedure TProviderForm.Changed;
begin
  { A validation message refers to the previous content, so it is cleared the
    moment anything changes. A stale error beside corrected input is a lie. }
  FError := '';
end;

function TProviderForm.Result_: TProviderFormResult;
begin
  Result := Default(TProviderFormResult);
  Result.Name := Trim(string(FName.Text));
  Result.Key := Trim(string(FKey.Text));
  Result.Endpoint := Trim(string(FEndpoint.Text));
  Result.Model := Trim(string(FModel.Text));
  Result.Secret := string(FSecret.Text);
  Result.SecretSet := Result.Secret <> '';
  Result.SecretClear := FSecretClear;
end;

{ The rules the SPEC pins, decided here because they need no store. }
function ValidateForm(const R: TProviderFormResult;
  const AKeys: TStringArray): string;
var
  I: Integer;
  Known: Boolean;
begin
  Result := '';
  if R.Name = '' then
    Exit('name is required');
  if R.Key = '' then
    Exit('provider is required');
  Known := False;
  for I := 0 to High(AKeys) do
    if SameText(AKeys[I], R.Key) then
      Known := True;
  if not Known then
    Exit('unknown provider "' + R.Key + '"');
  { An endpoint must be absolute. A bare host would be handed to the HTTP client
    as-is and fail at connect time with a message that does not name the cause. }
  if (R.Endpoint <> '') and
    (Pos('://', R.Endpoint) = 0) then
    Exit('endpoint must be a full URL');
  Result := '';
end;

procedure TProviderForm.SubmitText(const AText: string);
begin
  Submit;
end;

procedure TProviderForm.Submit;
var
  R: TProviderFormResult;
  Bad: string;
begin
  if FBusy then
    Exit;
  R := Result_;
  Bad := ValidateForm(R, FKeys);
  if Bad <> '' then
  begin
    FError := Bad;
    Exit;
  end;
  if Assigned(FOnAction) then
  begin
    if FEditing then
      FOnAction('save')
    else
      FOnAction('add');
  end;
end;

function TProviderForm.HandleEvent(const E: TInputEvent): Boolean;
begin
  { Tab / shift-tab move between fields; everything else goes to the focused
    field first, so typing never falls through to a chord. }
  if E.Kind = ikKey then
  begin
    if (E.Key.Kind = kkTab) and (moShift in E.Key.Mods) then
    begin
      MoveFocus(-1);
      Exit(True);
    end;
    if E.Key.Kind = kkTab then
    begin
      MoveFocus(1);
      Exit(True);
    end;
    if (E.Key.Kind = kkChar) and (moCtrl in E.Key.Mods) then
    begin
      if (E.Key.Ch = 'd') or (E.Key.Ch = 'D') then
      begin
        if FEditing and Assigned(FOnAction) then
          FOnAction('remove');
        Exit(True);
      end;
      if (E.Key.Kind = kkChar) and (E.Key.Ch = 'r') then
        Exit(OnNextProvider);
      if (FEditing) and ((E.Key.Ch = 'x') or (E.Key.Ch = 'X')) then
      begin
        { Marks the stored key for removal and says so, because a chord that
          silently arms a destructive change is worse than one that is loud. }
        FSecretClear := True;
        FSecret.SetText('');
        FError := 'the stored key will be removed on save';
        Exit(True);
      end;
    end;
    if E.Key.Kind = kkEscape then
    begin
      if Assigned(FOnAction) then
        FOnAction('cancel');
      Exit(True);
    end;
  end;
  case FFocus of
    0: Result := FName.HandleEvent(E);
    1: Result := FKey.HandleEvent(E);
    2: Result := FEndpoint.HandleEvent(E);
    3: Result := FModel.HandleEvent(E);
  else
    Result := FSecret.HandleEvent(E);
  end;
  if Result then
    Changed;
end;

procedure TProviderForm.RenderContent(const S: ISurface);
var
  Inner: TRect;
  Y: Integer;
  MsgAttr: TAttr;
begin
  inherited RenderContent(S);
  { THE MESSAGE MUST BE VISIBLE. FError was set from the day validation landed and
    nothing painted it, so every "name is required" went unseen. A connection
    failure would have been worse: the modal simply refused to close with no
    explanation. }
  Inner := InnerRect;
  Y := Inner.Y + 5;                 // one row per field, below the last
  if Y < Inner.Y + Inner.H then
  begin
    MsgAttr := OnBg(Theme.Accent, Theme.Bg);
    if FBusy then
      PutText(S, Inner.X, Y, 'checking connection...', MsgAttr)
    else if FError <> '' then
      PutText(S, Inner.X, Y, UnicodeString(FError), MsgAttr);
  end;
end;

procedure TProviderForm.FooterClicked(const AKey: string);
begin
  if (AKey = 'ctrl+x') and FEditing then
  begin
    FSecretClear := True;
    FSecret.SetText('');
    FError := 'the stored key will be removed on save';
  end
  else if AKey = 'ctrl+d' then
  begin
    if FEditing and Assigned(FOnAction) then
      FOnAction('remove');
  end
  else if AKey = 'enter' then
    Submit
  else if AKey = 'esc' then
  begin
    if Assigned(FOnAction) then
      FOnAction('cancel');
  end
  else
    inherited FooterClicked(AKey);
end;

end.
