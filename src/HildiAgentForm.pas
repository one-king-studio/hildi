unit HildiAgentForm;
{ The add/edit form for an agent.

  MIRRORS HildiProviderForm deliberately: same container layout, same
  focus-cycling, same validation-in-the-widget, same SetError/SetBusy contract
  with the host, same deferred close. Those solved hard problems once and copying
  the shape is correct; inventing a parallel one would not be.

  The fields are the provider's PLUS the agent-specific ones, minus the secret:

    name, provider, model          mirror the provider's identity fields
    system prompt                  the BEHAVIOUR - what makes an agent an agent
    reasoning effort, tier         tuning that is not discoverable from any
                                   catalogue, so it can only be operator-set
    temperature, top_p, max_tokens optional sampling, tri-state

  NO API KEY FIELD. A secret belongs to the connection, not to a behaviour - two
  agents can share one provider, and one key. That is why the provider row owns
  it and this form does not.

  The form OWNS validation and reports it inline; the host owns persistence. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  TUIBase, TUIInput, TUISurface, TUIWidget, TUITheme,
  TUIWidgetsModal, TUIWidgetsPrompt,
  HildiStore;

type
  { 'add' | 'save' | 'remove' | 'cancel' }
  TAgentFormAction = procedure(const AAction: string) of object;

  { What the form hands back on save. The host turns this into a TAgentRow. }
  TAgentFormResult = record
    Name: string;
    ProviderName: string;
    Model: string;
    SystemPrompt: string;
    ReasoningEffort: string;
    Tier: string;
    { Each optional parameter carries its own Has flag because an unset parameter
      is NOT zero: a temperature of 0 is a real, very different setting. An empty
      box means "omit the key from the request", and that survives to the wire. }
    Temperature: Double;  HasTemperature: Boolean;
    TopP: Double;         HasTopP: Boolean;
    MaxTokens: Integer;   HasMaxTokens: Boolean;
  end;

  TAgentForm = class(TModal)
  private
    FName, FProvider, FModel, FPrompt: TPromptLine;
    FEffort, FTier: TPromptLine;
    FTemp, FTopP, FMaxTok: TPromptLine;
    FBody: TContainer;
    FFocus: Integer;
    FEditing: Boolean;
    FError: string;
    FBusy: Boolean;
    FProviders: TStringArray;
    FOnAction: TAgentFormAction;
    procedure RefreshFooter;
    procedure MoveFocus(ADelta: Integer);
    procedure FocusField(AIndex: Integer);
    procedure Submit;
    procedure SubmitText(const AText: string);
    procedure Changed;
  public
    { AProviders is the list of configured provider names the form may offer. }
    constructor Create(const ATheme: TTheme; const AProviders: TStringArray;
      AEditing: Boolean);
    destructor Destroy; override;
    { Fill the fields for an edit. Ignored for an add. }
    procedure LoadFrom(const ARow: TAgentRow);
    function Result_: TAgentFormResult;
    { ctrl+p cycles to the next configured provider. A PICK rather than free
      text: a provider name that does not exist is a broken agent, and the list
      is short enough to cycle. }
    function OnNextProvider: Boolean;
    procedure SetError(const AText: string);
    procedure SetBusy(AValue: Boolean);
    property Error_: string read FError;
    property OnAction: TAgentFormAction read FOnAction write FOnAction;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  protected
    procedure RenderContent(const S: ISurface); override;
    procedure FooterClicked(const AKey: string); override;
  end;

{ Parse an OPTIONAL numeric field. Empty => not configured. Unparseable => the
  Has flag stays false. Exported because the provider form needs the same rule and
  two implementations of "empty is not zero" would drift. }
procedure ParseOptFloat(const AText: string; out AValue: Double; out AHas: Boolean);
procedure ParseOptInt(const AText: string; out AValue: Integer; out AHas: Boolean);

implementation

const
  FieldCount = 9;

procedure ParseOptFloat(const AText: string; out AValue: Double; out AHas: Boolean);
var
  FS: TFormatSettings;
begin
  AValue := 0;
  AHas := False;
  if Trim(AText) = '' then
    Exit;
  { JSONFormatSettings, not the locale default: on a comma-decimal locale
    StrToFloat('0.3') would not be 0.3, and the body is written with '.'. }
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  AHas := TryStrToFloat(Trim(AText), AValue, FS);
end;

procedure ParseOptInt(const AText: string; out AValue: Integer; out AHas: Boolean);
var
  V: Int64;
begin
  AValue := 0;
  AHas := False;
  if Trim(AText) = '' then
    Exit;
  if TryStrToInt64(Trim(AText), V) and (V >= 0) and (V <= High(Integer)) then
  begin
    AHas := True;
    AValue := V;
  end;
end;

constructor TAgentForm.Create(const ATheme: TTheme;
  const AProviders: TStringArray; AEditing: Boolean);
begin
  FProviders := AProviders;
  FEditing := AEditing;
  FFocus := 0;
  FName := TPromptLine.Create('name: ');
  FProvider := TPromptLine.Create('provider (ctrl+p): ');
  FModel := TPromptLine.Create('model: ');
  FPrompt := TPromptLine.Create('behaviour: ');
  FEffort := TPromptLine.Create('reasoning effort: ');
  FTier := TPromptLine.Create('tier: ');
  { Each optional line says so, because an empty box is the honest "not
    configured" - never a zero typed in by default. }
  FTemp := TPromptLine.Create('temperature (opt): ');
  FTopP := TPromptLine.Create('top_p (opt): ');
  FMaxTok := TPromptLine.Create('max tokens (opt): ');
  FName.OnSubmit := SubmitText;
  FProvider.OnSubmit := SubmitText;
  FModel.OnSubmit := SubmitText;
  FPrompt.OnSubmit := SubmitText;
  FEffort.OnSubmit := SubmitText;
  FTier.OnSubmit := SubmitText;
  FTemp.OnSubmit := SubmitText;
  FTopP.OnSubmit := SubmitText;
  FMaxTok.OnSubmit := SubmitText;
  FBody := TContainer.Create([Fill(1)],
    [Auto, Auto, Auto, Auto, Auto, Auto, Auto, Auto, Auto]);
  FBody.Add(FName, 0, 0);
  FBody.Add(FProvider, 0, 1);
  FBody.Add(FModel, 0, 2);
  FBody.Add(FPrompt, 0, 3);
  FBody.Add(FEffort, 0, 4);
  FBody.Add(FTier, 0, 5);
  FBody.Add(FTemp, 0, 6);
  FBody.Add(FTopP, 0, 7);
  FBody.Add(FMaxTok, 0, 8);
  inherited Create(ATheme, FBody, False);
  if AEditing then
    SetTitle('edit agent')
  else
    SetTitle('add agent');
  FocusField(0);
  RefreshFooter;
end;

destructor TAgentForm.Destroy;
begin
  FName.Free;
  FProvider.Free;
  FModel.Free;
  FPrompt.Free;
  FEffort.Free;
  FTier.Free;
  FTemp.Free;
  FTopP.Free;
  FMaxTok.Free;
  inherited Destroy;
end;

procedure TAgentForm.RefreshFooter;
begin
  if FEditing then
    SetFooter('ctrl+d remove   enter save   esc cancel')
  else
    SetFooter('enter add   esc cancel');
end;

procedure TAgentForm.FocusField(AIndex: Integer);
begin
  FName.Active := AIndex = 0;
  FProvider.Active := AIndex = 1;
  FModel.Active := AIndex = 2;
  FPrompt.Active := AIndex = 3;
  FEffort.Active := AIndex = 4;
  FTier.Active := AIndex = 5;
  FTemp.Active := AIndex = 6;
  FTopP.Active := AIndex = 7;
  FMaxTok.Active := AIndex = 8;
  FFocus := AIndex;
end;

procedure TAgentForm.MoveFocus(ADelta: Integer);
var
  Next: Integer;
begin
  Next := FFocus + ADelta;
  if Next < 0 then
    Next := FieldCount - 1;
  if Next > FieldCount - 1 then
    Next := 0;
  FocusField(Next);
end;

procedure TAgentForm.LoadFrom(const ARow: TAgentRow);
begin
  FName.SetText(ARow.Name);
  FProvider.SetText(ARow.ProviderName);
  FModel.SetText(ARow.Model);
  FPrompt.SetText(ARow.SystemPrompt);
  FEffort.SetText(ARow.ReasoningEffort);
  FTier.SetText(ARow.Tier);
  { An unset parameter loads as an EMPTY BOX, not '0'. Writing '0.0' into an
    unset temperature would turn "not configured" into "deliberately
    deterministic" the moment the operator saved anything else. }
  if ARow.HasTemperature then
    FTemp.SetText(FormatFloat('0.######', ARow.Temperature));
  if ARow.HasTopP then
    FTopP.SetText(FormatFloat('0.######', ARow.TopP));
  if ARow.HasMaxTokens then
    FMaxTok.SetText(IntToStr(ARow.MaxTokens));
  FocusField(0);
end;

function TAgentForm.OnNextProvider: Boolean;
var
  Cur, I, Next: Integer;
begin
  Result := True;
  if Length(FProviders) = 0 then
    Exit;
  Cur := -1;
  for I := 0 to High(FProviders) do
    if SameText(FProviders[I], string(FProvider.Text)) then
      Cur := I;
  if Cur < 0 then
    Next := 0
  else
    Next := (Cur + 1) mod Length(FProviders);
  FProvider.SetText(FProviders[Next]);
  Changed;
end;

procedure TAgentForm.SetError(const AText: string);
begin
  FError := AText;
end;

procedure TAgentForm.SetBusy(AValue: Boolean);
begin
  FBusy := AValue;
end;

procedure TAgentForm.Changed;
begin
  { A validation message refers to the previous content, so any change clears it.
    A stale error beside corrected input is a lie. }
  FError := '';
end;

function TAgentForm.Result_: TAgentFormResult;
begin
  Result := Default(TAgentFormResult);
  Result.Name := Trim(string(FName.Text));
  Result.ProviderName := Trim(string(FProvider.Text));
  Result.Model := Trim(string(FModel.Text));
  Result.SystemPrompt := string(FPrompt.Text);
  Result.ReasoningEffort := Trim(string(FEffort.Text));
  Result.Tier := Trim(string(FTier.Text));
  { Parsed here, left UNSET when empty. The Has flags come from emptiness, not
    from the number, so a typed 0 stays a configured zero. }
  ParseOptFloat(string(FTemp.Text), Result.Temperature, Result.HasTemperature);
  ParseOptFloat(string(FTopP.Text), Result.TopP, Result.HasTopP);
  ParseOptInt(string(FMaxTok.Text), Result.MaxTokens, Result.HasMaxTokens);
end;

{ The rules decidable without a store. }
function ValidateAgentForm(const R: TAgentFormResult;
  const AProviders: TStringArray): string;
var
  I: Integer;
  Known: Boolean;
begin
  Result := '';
  if R.Name = '' then
    Exit('name is required');
  { A MODEL IS ONLY MEANINGFUL WITH A PROVIDER. 'openai/gpt-4o' names a model in
    OpenRouter's namespace; the same id means something else - or nothing - under
    another provider. So the two are a PAIR: either both are given, or neither is.
    Half a pair is refused rather than saved, because it would resolve to whatever
    the other half happened to be at prompt time. }
  if (R.ProviderName = '') <> (R.Model = '') then
  begin
    if R.Model <> '' then
      Exit('a model needs a provider')
    else
      Exit('a provider needs a model');
  end;
  { NEITHER given is fine: the agent then inherits the active selection, which is
    the common case - most agents name no model at all. }
  if (R.ProviderName = '') and (R.Model = '') then
    Exit('');
  Known := False;
  for I := 0 to High(AProviders) do
    if SameText(AProviders[I], R.ProviderName) then
      Known := True;
  if not Known then
    Exit('no such provider "' + R.ProviderName + '"');
  Result := '';
end;

procedure TAgentForm.SubmitText(const AText: string);
begin
  Submit;
end;

procedure TAgentForm.Submit;
var
  R: TAgentFormResult;
  Bad: string;
begin
  if FBusy then
    Exit;
  R := Result_;
  Bad := ValidateAgentForm(R, FProviders);
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

function TAgentForm.HandleEvent(const E: TInputEvent): Boolean;
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
      if (E.Key.Ch = 'p') or (E.Key.Ch = 'P') then
        Exit(OnNextProvider);
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
    1: Result := FProvider.HandleEvent(E);
    2: Result := FModel.HandleEvent(E);
    3: Result := FPrompt.HandleEvent(E);
    4: Result := FEffort.HandleEvent(E);
    5: Result := FTier.HandleEvent(E);
    6: Result := FTemp.HandleEvent(E);
    7: Result := FTopP.HandleEvent(E);
  else
    Result := FMaxTok.HandleEvent(E);
  end;
  if Result then
    Changed;
end;

procedure TAgentForm.RenderContent(const S: ISurface);
var
  Inner: TRect;
  Y: Integer;
  MsgAttr: TAttr;
begin
  inherited RenderContent(S);
  { The message MUST be visible - the provider form shipped with FError set and
    nothing painting it, so every "name is required" went unseen. Not twice. }
  Inner := InnerRect;
  Y := Inner.Y + FieldCount;
  if Y < Inner.Y + Inner.H then
  begin
    MsgAttr := OnBg(Theme.Accent, Theme.Bg);
    if FBusy then
      PutText(S, Inner.X, Y, 'working...', MsgAttr)
    else if FError <> '' then
      PutText(S, Inner.X, Y, UnicodeString(FError), MsgAttr);
  end;
end;

procedure TAgentForm.FooterClicked(const AKey: string);
begin
  if AKey = 'ctrl+d' then
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
