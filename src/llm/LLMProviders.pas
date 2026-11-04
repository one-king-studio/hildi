unit LLMProviders;
{ The vendor adapters: Fireworks, OpenRouter and OpenAI.

  EACH DIFFERS IN A DIFFERENT WAY, which is why the seam has three methods rather
  than one. Measured against the live catalogues:

                     Fireworks      OpenRouter       OpenAI
    catalogue auth   required       NONE (public)    required
    friendly name    none           all 455          none
    chat capability  boolean        output_modalities  ABSENT
    tool capability  boolean        supported_params   ABSENT
    context length   sometimes      always           ABSENT
    finish reasons   OpenAI's       + `error`        + `function_call`

  The consequence that drove the design: capability is TRI-STATE. OpenAI's model
  object declares no chat capability, no tool capability and no context length at
  all, so treating "absent" as "false" would hide every OpenAI model from a
  picker. capUnknown means "offered, the vendor did not say" - only a vendor
  POSITIVELY declaring a model unusable hides it.

  OpenAI is the simplest adapter here and the most important one to keep working,
  because it is also what any self-hosted, proxied or alias endpoint speaks -
  including Fireworks' own OpenAI-compatible base URL. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson, LLMProvider;

type
  { ------------------------------------------------------------------ Fireworks
    accounts/fireworks/models/... — auth required, capability flags served,
    context_length usually served, no friendly names, `kind` distinguishes
    embedding and rerank entries from chat models. }
  TFireworksProvider = class(TLLMProvider)
  public
    function Key: string; override;
    function DisplayName: string; override;
    function DefaultEndpoint: string; override;
    function ModelsUrl(const AChatEndpoint: string): string; override;
    function ParseModels(const ABody: string;
      out AModels: TProviderModelArray; out AError: string): Boolean; override;
    procedure DecorateRequest(const AContext: TProviderContext;
      ARoot: TJSONObject); override;
  end;

  { ----------------------------------------------------------------- OpenRouter
    The richest catalogue and the only public one: no key needed to list.
    Serves `name` for every model, capability through supported_parameters and
    architecture.output_modalities, and its own finish reason `error`, which
    arrives inside an otherwise successful stream. }
  TOpenRouterProvider = class(TLLMProvider)
  public
    function Key: string; override;
    function DisplayName: string; override;
    function DefaultEndpoint: string; override;
    function ModelsNeedKey: Boolean; override;
    function ModelsUrl(const AChatEndpoint: string): string; override;
    function ParseModels(const ABody: string;
      out AModels: TProviderModelArray; out AError: string): Boolean; override;
    procedure ExtraHeaders(AHeaders: TStrings); override;
    function InspectChunk(const AJson: TJSONObject;
      out AProviderError, AFinishHint: string): Boolean; override;
  end;

  { -------------------------------------------------------------------- OpenAI
    The sparsest catalogue and the most widely spoken dialect. A model object is
    id/created/object/owned_by/shutdown_date and nothing else, so every model it
    lists must be offered with its capabilities UNKNOWN rather than assumed
    unusable. }
  TOpenAIProvider = class(TLLMProvider)
  public
    function Key: string; override;
    function DisplayName: string; override;
    function DefaultEndpoint: string; override;
    function ModelsUrl(const AChatEndpoint: string): string; override;
    function ParseModels(const ABody: string;
      out AModels: TProviderModelArray; out AError: string): Boolean; override;
    function InspectChunk(const AJson: TJSONObject;
      out AProviderError, AFinishHint: string): Boolean; override;
  end;

implementation

{ --- shared helpers ------------------------------------------------------ }

{ The endpoint's path with the last segment replaced, e.g.
    https://host/inference/v1/chat/completions -> https://host/inference/v1/models
  Derived from the CONFIGURED endpoint rather than hard-coded, so a proxy, a
  mirror or a self-hosted install works without a special case. }
function SiblingEndpoint(const AChatEndpoint, ALastSegment: string): string;
var
  P: Integer;
begin
  Result := Trim(AChatEndpoint);
  if Result = '' then
    Exit('');
  P := LastDelimiter('/', Result);
  if P > 0 then
    Result := Copy(Result, 1, P);   // keeps the trailing slash
  Result := Result + ALastSegment;
end;

function JsonString(AObj: TJSONObject; const AName: string): string;
var
  D: TJSONData;
begin
  Result := '';
  if AObj = nil then
    Exit;
  D := AObj.Find(AName);
  if (D <> nil) and (D.JSONType = jtString) then
    Result := D.AsString;
end;

function JsonInt(AObj: TJSONObject; const AName: string; ADefault: Integer): Integer;
var
  D: TJSONData;
begin
  Result := ADefault;
  if AObj = nil then
    Exit;
  D := AObj.Find(AName);
  if (D <> nil) and (D.JSONType = jtNumber) then
    Result := D.AsInteger;
end;

function JsonBoolData(AData: TJSONData): Boolean;
begin
  Result := (AData <> nil) and (AData.JSONType = jtBoolean) and AData.AsBoolean;
end;

{ True when AObj's array field AName contains the exact string AValue. }
function JsonArrayHasString(AObj: TJSONObject; const AName, AValue: string): Boolean;
var
  D: TJSONData;
  I: Integer;
begin
  Result := False;
  if AObj = nil then
    Exit;
  D := AObj.Find(AName);
  if not (D is TJSONArray) then
    Exit;
  for I := 0 to TJSONArray(D).Count - 1 do
    if (TJSONArray(D).Items[I].JSONType = jtString) and
      SameText(TJSONArray(D).Items[I].AsString, AValue) then
      Exit(True);
end;

{ The `data` array of a catalogue envelope. False when the body is not a
  catalogue at all - which is different from an empty one, and must not be
  presented as "this vendor has no models". }
function CatalogueData(const ABody: string; out AArray: TJSONArray;
  out AError: string): Boolean;
var
  D: TJSONData;
begin
  AArray := nil;
  AError := '';
  if Trim(ABody) = '' then
  begin
    AError := 'empty response body';
    Exit(False);
  end;
  D := nil;
  try
    try
      D := GetJSON(ABody);
    except
      on E: Exception do
      begin
        AError := 'could not parse the catalogue: ' + E.Message;
        Exit(False);
      end;
    end;
    if not (D is TJSONObject) then
    begin
      AError := 'the catalogue is not a JSON object';
      Exit(False);
    end;
    if not (TJSONObject(D).Find('data') is TJSONArray) then
    begin
      AError := 'the catalogue has no data array';
      Exit(False);
    end;
    AArray := TJSONArray(TJSONObject(D).Find('data'));
    Result := True;
  finally
    D.Free;
  end;
end;

{ --- TFireworksProvider -------------------------------------------------- }

function TFireworksProvider.Key: string;
begin
  Result := 'fireworks';
end;

function TFireworksProvider.DisplayName: string;
begin
  Result := 'Fireworks';
end;

function TFireworksProvider.DefaultEndpoint: string;
begin
  Result := 'https://api.fireworks.ai/inference/v1/chat/completions';
end;

function TFireworksProvider.ModelsUrl(const AChatEndpoint: string): string;
begin
  Result := SiblingEndpoint(AChatEndpoint, 'models');
end;

function TFireworksProvider.ParseModels(const ABody: string;
  out AModels: TProviderModelArray; out AError: string): Boolean;
var
  Arr: TJSONArray;
  Obj: TJSONObject;
  M: TProviderModel;
  I: Integer;
  Kind: string;
  D: TJSONData;
begin
  AModels := nil;
  if not CatalogueData(ABody, Arr, AError) then
    Exit(False);
  for I := 0 to Arr.Count - 1 do
  begin
    if not (Arr.Items[I] is TJSONObject) then
      Continue;
    Obj := TJSONObject(Arr.Items[I]);
    M := Default(TProviderModel);
    M.Id := JsonString(Obj, 'id');
    if M.Id = '' then
      Continue;
    { Fireworks serves NO friendly name. Leave DisplayName empty so ModelLabel
      derives one from the id. }
    Kind := JsonString(Obj, 'kind');
    D := Obj.Find('supports_chat');
    if D <> nil then
    begin
      if JsonBoolData(D) then
        M.ChatCapability := capYes
      else
        M.ChatCapability := capNo;
    end
    else if Kind = 'EMBEDDING_MODEL' then
      M.ChatCapability := capNo
    else
      M.ChatCapability := capUnknown;

    D := Obj.Find('supports_tools');
    if D <> nil then
    begin
      if JsonBoolData(D) then
        M.ToolCapability := capYes
      else
        M.ToolCapability := capNo;
    end;

    { Absent on some entries (every router, in the catalogue I sampled): 0 means
      unknown, not "no context". }
    M.ContextLength := JsonInt(Obj, 'context_length', 0);

    { Hide only what the vendor POSITIVELY says cannot chat. An embedding or
      rerank entry is exactly that. }
    M.Usable := M.ChatCapability <> capNo;

    SetLength(AModels, Length(AModels) + 1);
    AModels[High(AModels)] := M;
  end;
  Result := True;
end;

procedure TFireworksProvider.DecorateRequest(const AContext: TProviderContext;
  ARoot: TJSONObject);
begin
  { Nothing yet. `service_tier: "priority"` belongs here when the operator can
    set it: it is a Fireworks serverless mode with no cross-vendor meaning, which
    is precisely the kind of field this hook exists for. }
end;

{ --- TOpenRouterProvider ------------------------------------------------- }

function TOpenRouterProvider.Key: string;
begin
  Result := 'openrouter';
end;

function TOpenRouterProvider.DisplayName: string;
begin
  Result := 'OpenRouter';
end;

function TOpenRouterProvider.DefaultEndpoint: string;
begin
  Result := 'https://openrouter.ai/api/v1/chat/completions';
end;

function TOpenRouterProvider.ModelsNeedKey: Boolean;
begin
  { The catalogue is public. Demanding a key would make browsing impossible on an
    install that has not stored one yet. }
  Result := False;
end;

function TOpenRouterProvider.ModelsUrl(const AChatEndpoint: string): string;
begin
  Result := SiblingEndpoint(AChatEndpoint, 'models');
end;

function TOpenRouterProvider.ParseModels(const ABody: string;
  out AModels: TProviderModelArray; out AError: string): Boolean;
var
  Arr: TJSONArray;
  Obj: TJSONObject;
  M: TProviderModel;
  Arch: TJSONObject;
  D: TJSONData;
  I: Integer;
begin
  AModels := nil;
  if not CatalogueData(ABody, Arr, AError) then
    Exit(False);
  for I := 0 to Arr.Count - 1 do
  begin
    if not (Arr.Items[I] is TJSONObject) then
      Continue;
    Obj := TJSONObject(Arr.Items[I]);
    M := Default(TProviderModel);
    M.Id := JsonString(Obj, 'id');
    if M.Id = '' then
      Continue;
    { The only one of the three that serves a friendly name - `"Z.ai: GLM 5.3
      FlashX Legal"`. }
    M.DisplayName := JsonString(Obj, 'name');

    D := Obj.Find('architecture');
    if D is TJSONObject then
    begin
      Arch := TJSONObject(D);
      if JsonArrayHasString(Arch, 'output_modalities', 'text') then
        M.ChatCapability := capYes
      else if Arch.Find('output_modalities') <> nil then
        M.ChatCapability := capNo;
    end;

    D := Obj.Find('supported_parameters');
    if D is TJSONArray then
    begin
      if JsonArrayHasString(Obj, 'supported_parameters', 'tools') then
        M.ToolCapability := capYes;
    end;

    M.ContextLength := JsonInt(Obj, 'context_length', 0);
    M.Usable := M.ChatCapability <> capNo;

    SetLength(AModels, Length(AModels) + 1);
    AModels[High(AModels)] := M;
  end;
  Result := True;
end;

procedure TOpenRouterProvider.ExtraHeaders(AHeaders: TStrings);
begin
  { Attribution headers OpenRouter documents. Optional, but they are how usage
    shows up as ours rather than anonymous. }
  AHeaders.Values['HTTP-Referer'] := 'https://github.com/hildi';
  AHeaders.Values['X-OpenRouter-Title'] := 'hildi';
end;

function TOpenRouterProvider.InspectChunk(const AJson: TJSONObject;
  out AProviderError, AFinishHint: string): Boolean;
var
  Choices: TJSONData;
  Choice: TJSONObject;
  ErrObj: TJSONData;
begin
  AProviderError := '';
  AFinishHint := '';
  Result := True;
  if AJson = nil then
    Exit;
  { OpenRouter can deliver a genuine failure INSIDE an HTTP 200 SSE stream: the
    choice carries an `error` object instead of content. Without this the stream
    ends as a clean stop with an empty answer - the worst failure mode there is,
    because nothing looks wrong. }
  Choices := AJson.Find('choices');
  if (Choices = nil) or not (Choices is TJSONArray) then
    Exit;
  if TJSONArray(Choices).Count = 0 then
    Exit;
  if not (TJSONArray(Choices).Items[0] is TJSONObject) then
    Exit;
  Choice := TJSONObject(TJSONArray(Choices).Items[0]);
  ErrObj := Choice.Find('error');
  if ErrObj is TJSONObject then
  begin
    AProviderError := JsonString(TJSONObject(ErrObj), 'message');
    if AProviderError = '' then
      AProviderError := 'the provider reported an error';
    Exit(False);
  end;
  { `error` is a normalised finish reason here, distinct from the error OBJECT. }
  if SameText(JsonString(Choice, 'finish_reason'), 'error') then
    AFinishHint := 'error';
end;

{ --- TOpenAIProvider ----------------------------------------------------- }

function TOpenAIProvider.Key: string;
begin
  Result := 'openai';
end;

function TOpenAIProvider.DisplayName: string;
begin
  Result := 'OpenAI';
end;

function TOpenAIProvider.DefaultEndpoint: string;
begin
  Result := 'https://api.openai.com/v1/chat/completions';
end;

function TOpenAIProvider.ModelsUrl(const AChatEndpoint: string): string;
begin
  Result := SiblingEndpoint(AChatEndpoint, 'models');
end;

function TOpenAIProvider.ParseModels(const ABody: string;
  out AModels: TProviderModelArray; out AError: string): Boolean;
var
  Arr: TJSONArray;
  Obj: TJSONObject;
  M: TProviderModel;
  I: Integer;
begin
  AModels := nil;
  if not CatalogueData(ABody, Arr, AError) then
    Exit(False);
  for I := 0 to Arr.Count - 1 do
  begin
    if not (Arr.Items[I] is TJSONObject) then
      Continue;
    Obj := TJSONObject(Arr.Items[I]);
    M := Default(TProviderModel);
    M.Id := JsonString(Obj, 'id');
    if M.Id = '' then
      Continue;
    { Nothing else is served: not a name, not a capability, not a context
      length. Everything stays capUnknown / 0 / usable, which is the honest
      reading and the reason capability is tri-state. A picker that treated
      absent as false would show an empty list here. }
    M.ChatCapability := capUnknown;
    M.ToolCapability := capUnknown;
    M.ContextLength := 0;
    M.Usable := True;
    SetLength(AModels, Length(AModels) + 1);
    AModels[High(AModels)] := M;
  end;
  Result := True;
end;

function TOpenAIProvider.InspectChunk(const AJson: TJSONObject;
  out AProviderError, AFinishHint: string): Boolean;
var
  Choices: TJSONData;
  Reason: string;
begin
  AProviderError := '';
  AFinishHint := '';
  Result := True;
  if AJson = nil then
    Exit;
  Choices := AJson.Find('choices');
  if (Choices = nil) or not (Choices is TJSONArray) then
    Exit;
  if TJSONArray(Choices).Count = 0 then
    Exit;
  if not (TJSONArray(Choices).Items[0] is TJSONObject) then
    Exit;
  { `function_call` is deprecated but still documented, and the neutral parser
    drops it to frUnknown - which reads as "the model just stopped" while a tool
    call was actually requested. Map it onto the verb that exists. }
  Reason := JsonString(TJSONObject(TJSONArray(Choices).Items[0]),
    'finish_reason');
  if SameText(Reason, 'function_call') then
    AFinishHint := 'tool_calls';
end;

{ --- registration -------------------------------------------------------- }

procedure RegisterBuiltinProviders(ARegistry: TProviderModelRegistry);
begin
  if ARegistry = nil then
    Exit;
  ARegistry.Add(TFireworksProvider.Create);
  ARegistry.Add(TOpenRouterProvider.Create);
  ARegistry.Add(TOpenAIProvider.Create);
end;

initialization
  { Install the registrar, so unloading this unit is what makes the vendors
    exist. Referencing LLMProviders anywhere in the program links the adapters;
    a program that never names a vendor gets none, which is the honest result. }
  LLMProvider.ProviderRegistrar := @RegisterBuiltinProviders;

end.
