unit LLMProvider;
{ The provider seam: what genuinely differs between LLM vendors, normalised so
  the harness never learns a vendor name.

  THREE THINGS DIFFER, and they are the whole interface:

    ListModels        the catalogue (endpoint, auth, envelope, and even whether
                      a friendly name exists at all)
    DecorateRequest   fields only this vendor understands
    InspectChunk      its finish-reason vocabulary and in-stream errors

  Everything else - SSE framing, message shape, tool calls, usage - is shared.
  That is why this sits ABOVE the transport and BELOW the client: a provider
  contributes request fields and interpretations, never a second code path.

  WHY THE FIELDS ARE MOSTLY OPTIONAL: measured against the live catalogues.
  OpenRouter serves a friendly name for all 455 models; Fireworks serves none for
  any of its 30; OpenAI's model object carries only id/created/owned_by. So a
  required field beyond the id would work on exactly one vendor.

  WHY CAPABILITY IS TRI-STATE: OpenAI declares no chat capability, no tool
  capability and no context length at all. "Absent" must mean UNKNOWN, never
  "false" - otherwise a picker would hide every OpenAI model. The rule is: hide
  only what a vendor POSITIVELY says cannot serve a turn.

  This unit uses no HTTP and knows no vendor, so it is testable without a network
  and cannot drift toward one provider's shape. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson;

type
  { A capability a vendor may, or may not, declare. capUnknown is not a synonym
    for capNo: it means "the catalogue did not say", and the UI must OFFER an
    unknown model rather than hide it. }
  TCapability = (capUnknown, capYes, capNo);

  { One model, normalised. Only Id is guaranteed. }
  TProviderModel = record
    Id: string;                    // the only key; what a provider row stores
    DisplayName: string;           // '' => derive a label from Id
    ChatCapability: TCapability;
    ToolCapability: TCapability;
    ContextLength: Integer;        // 0 => unknown
    { True unless the vendor positively declares this model cannot hold a
      conversation (an embedding or rerank entry). }
    Usable: Boolean;
  end;

  TProviderModelArray = array of TProviderModel;

  { What a provider needs about a connection. Deliberately NOT LLMClient's
    TLLMConfig: this unit must not depend on the client, or the dependency runs
    both ways and the seam turns into a knot. }
  TProviderContext = record
    Endpoint: string;   // the chat endpoint, as configured
    ApiKey: string;     // read only by the caller that performs the request
    Model: string;
  end;

  { Fetches a URL and returns the body. Injected so this unit performs no I/O:
    the tests hand back a canned catalogue, production hands back a real GET.
    True means an HTTP response arrived, even a non-2xx one. }
  TModelFetch = function(const AUrl, AApiKey: string;
    out ABody, AError: string; out AStatus: Integer): Boolean of object;

  TLLMProvider = class
  public
    { The stable key stored on a provider row. Lowercase, no spaces. }
    function Key: string; virtual; abstract;
    { A label for a provider picker. }
    function DisplayName: string; virtual; abstract;
    { The chat endpoint used when a row leaves it empty. }
    function DefaultEndpoint: string; virtual; abstract;
    { Whether the catalogue requires a key. OpenRouter's does not, and demanding
      one would make browsing impossible for an install with no key stored. }
    function ModelsNeedKey: Boolean; virtual;

    { The models URL for a chat endpoint. '' when the vendor has no catalogue.
      Derived from the configured endpoint rather than hard-coded, so a proxy or
      a self-hosted mirror works. }
    function ModelsUrl(const AChatEndpoint: string): string; virtual;

    { Parse a catalogue body. Returns False only when the body cannot be
      understood at all; an understood-but-empty list is True with no models,
      because "this vendor lists nothing" is not a parse failure. }
    function ParseModels(const ABody: string;
      out AModels: TProviderModelArray; out AError: string): Boolean; virtual;

    { Fetch and parse in one step, using AInjected when supplied. }
    function ListModels(const AContext: TProviderContext; AFetch: TModelFetch;
      out AModels: TProviderModelArray; out AError: string;
      out AStatus: Integer): Boolean;

    { Add or rewrite fields this vendor owns. Called on the body AFTER the
      neutral request is built, so a provider can never corrupt the message
      array it does not understand. }
    procedure DecorateRequest(const AContext: TProviderContext;
      ARoot: TJSONObject); virtual;

    { Headers beyond Authorization/Content-Type/Accept. }
    procedure ExtraHeaders(AHeaders: TStrings); virtual;

    { Interpret a chunk before the neutral parser sees it. Returns False when the
      chunk carries a provider error that must end the stream; AFinishHint, when
      non-empty, maps a vendor-specific finish reason onto the neutral
      vocabulary. }
    function InspectChunk(const AJson: TJSONObject;
      out AProviderError, AFinishHint: string): Boolean; virtual;
  end;

const
  { Why a model cannot be offered. Kept as text so a picker can explain itself
    rather than silently omitting rows. }
  ModelUnusableEmbedding = 'this model does not produce text output';

  { Every existing install, which has never named a provider. }
  DefaultProviderKey = 'fireworks';

type
  { Owns the provider instances. Declared BEFORE the functions that mention it:
    a forward type declaration cannot be completed later in the same interface
    section, so the class has to come first and the functions follow. }
  TProviderModelRegistry = class
  private
    FItems: TList;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TLLMProvider;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(AProvider: TLLMProvider);
    function ByKey(const AKey: string): TLLMProvider;
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TLLMProvider read GetItem; default;
  end;

{ REGISTRATION HOOK. The adapters live in LLMProviders, which depends on this
  unit for the seam - so this unit cannot depend on it, and a plain forward
  declaration would be unsolvable. LLMProviders installs its registrar in its
  own initialization instead, which keeps the dependency one-way: adding a
  vendor is a new unit plus one line there, never an edit to the seam. }
type
  TProviderRegistrar = procedure(ARegistry: TProviderModelRegistry);

var
  ProviderRegistrar: TProviderRegistrar = nil;

{ The label to show for a model. Prefers the vendor's own name; otherwise the
  id's last path segment, qualified by its parent when two leaves collide. The
  Fireworks catalogue really does serve `rune` twice - as models/rune and
  routers/rune - and a dropdown showing bare `rune` for both is a bug.

  Never use the result as a key: it is display text and is not unique. }
function ModelLabel(const AModel: TProviderModel;
  const ASiblings: TProviderModelArray): string;

{ The providers this build knows, in a stable order. }
function RegisteredProviders: TProviderModelRegistry;

{ '' resolves to Fireworks, because that is what every existing install is. }
function ProviderByKey(const AKey: string): TLLMProvider;

implementation

function ModelLabel(const AModel: TProviderModel;
  const ASiblings: TProviderModelArray): string;
var
  I, P: Integer;
  Leaf, Parent, SiblingLeaf: string;
  Collides: Boolean;
begin
  if AModel.DisplayName <> '' then
    Exit(AModel.DisplayName);

  Leaf := AModel.Id;
  P := LastDelimiter('/', Leaf);
  if P > 0 then
    Leaf := Copy(Leaf, P + 1, MaxInt);
  if Leaf = '' then
    Leaf := AModel.Id;

  { Qualify only when it is needed: `deepseek-v4p1-flash-1017` is already clear,
    and prefixing every label with `models` would be noise. }
  Collides := False;
  for I := 0 to High(ASiblings) do
  begin
    if ASiblings[I].Id = AModel.Id then
      Continue;
    SiblingLeaf := ASiblings[I].Id;
    P := LastDelimiter('/', SiblingLeaf);
    if P > 0 then
      SiblingLeaf := Copy(SiblingLeaf, P + 1, MaxInt);
    if SiblingLeaf = Leaf then
    begin
      Collides := True;
      Break;
    end;
  end;

  if not Collides then
    Exit(Leaf);

  { The parent segment is what distinguishes them: models/rune vs routers/rune. }
  Parent := '';
  P := LastDelimiter('/', AModel.Id);
  if P > 1 then
  begin
    Parent := Copy(AModel.Id, 1, P - 1);
    P := LastDelimiter('/', Parent);
    if P > 0 then
      Parent := Copy(Parent, P + 1, MaxInt);
  end;
  if Parent = '' then
    Exit(Leaf);
  Result := Leaf + ' (' + Parent + ')';
end;

{ --- TLLMProvider -------------------------------------------------------- }

function TLLMProvider.ModelsNeedKey: Boolean;
begin
  Result := True;
end;

function TLLMProvider.ModelsUrl(const AChatEndpoint: string): string;
begin
  { '' on purpose: a vendor with no catalogue must say so rather than inherit a
    guess. A provider that has one overrides this. }
  Result := '';
end;

function TLLMProvider.ParseModels(const ABody: string;
  out AModels: TProviderModelArray; out AError: string): Boolean;
begin
  AModels := nil;
  AError := 'this provider has no model catalogue';
  Result := False;
end;

function TLLMProvider.ListModels(const AContext: TProviderContext;
  AFetch: TModelFetch; out AModels: TProviderModelArray; out AError: string;
  out AStatus: Integer): Boolean;
var
  Url, Body, FetchError: string;
  Key: string;
begin
  AModels := nil;
  AError := '';
  AStatus := 0;
  Url := ModelsUrl(AContext.Endpoint);
  if Url = '' then
  begin
    AError := 'this provider has no model catalogue';
    Exit(False);
  end;
  if not Assigned(AFetch) then
  begin
    AError := 'no transport for model listing';
    Exit(False);
  end;
  { Only send a key to a vendor that expects one. OpenRouter's catalogue is
    public, and an install with no stored key must still be able to browse. }
  Key := '';
  if ModelsNeedKey then
    Key := AContext.ApiKey;
  if not AFetch(Url, Key, Body, FetchError, AStatus) then
  begin
    AError := FetchError;
    Exit(False);
  end;
  if (AStatus < 200) or (AStatus >= 300) then
  begin
    AError := 'HTTP ' + IntToStr(AStatus);
    Exit(False);
  end;
  Result := ParseModels(Body, AModels, AError);
end;

procedure TLLMProvider.DecorateRequest(const AContext: TProviderContext;
  ARoot: TJSONObject);
begin
  { Nothing by default: the neutral body is already a valid request for a vendor
    that adds nothing. }
end;

procedure TLLMProvider.ExtraHeaders(AHeaders: TStrings);
begin
end;

function TLLMProvider.InspectChunk(const AJson: TJSONObject;
  out AProviderError, AFinishHint: string): Boolean;
begin
  AProviderError := '';
  AFinishHint := '';
  Result := True;
end;

{ --- registry ------------------------------------------------------------ }

constructor TProviderModelRegistry.Create;
begin
  inherited Create;
  FItems := TList.Create;
end;

destructor TProviderModelRegistry.Destroy;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    TLLMProvider(FItems[I]).Free;
  FItems.Free;
  inherited Destroy;
end;

procedure TProviderModelRegistry.Add(AProvider: TLLMProvider);
begin
  if AProvider <> nil then
    FItems.Add(AProvider);
end;

function TProviderModelRegistry.ByKey(const AKey: string): TLLMProvider;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if SameText(TLLMProvider(FItems[I]).Key, AKey) then
      Exit(TLLMProvider(FItems[I]));
  Result := nil;
end;

function TProviderModelRegistry.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TProviderModelRegistry.GetItem(AIndex: Integer): TLLMProvider;
begin
  Result := TLLMProvider(FItems[AIndex]);
end;

{ The provider instances live for the process lifetime, in one list built on
  first use. Registered here rather than in each adapter so that adding a vendor
  touches one line in one place. }
var
  GSoleRegistry: TProviderModelRegistry = nil;

function RegisteredProviders: TProviderModelRegistry;
begin
  if GSoleRegistry = nil then
  begin
    GSoleRegistry := TProviderModelRegistry.Create;
    if Assigned(ProviderRegistrar) then
      ProviderRegistrar(GSoleRegistry);
  end;
  Result := GSoleRegistry;
end;

function ProviderByKey(const AKey: string): TLLMProvider;
begin
  { '' is every install that has never configured a provider, so it means
    Fireworks rather than "no provider". }
  if AKey = '' then
    Result := RegisteredProviders.ByKey(DefaultProviderKey)
  else
    Result := RegisteredProviders.ByKey(AKey);
end;

finalization
  FreeAndNil(GSoleRegistry);

end.
