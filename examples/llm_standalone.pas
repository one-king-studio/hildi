program llm_standalone;
{ The isolation proof for the provider library.

  Compiles against src/llm ONLY - `make llm-standalone` puts no other source
  directory on the search path. Every unit here is therefore forced to be
  self-contained: if LLMClient, LLMProvider, LLMEnv or LLMTLS ever reaches for
  HildiStore, HildiAgent or the application's policy, this program stops
  compiling and the gate fails.

  That is the whole point. A library that quietly depends on its application is
  not a library, and the failure has to be a build error rather than a review
  comment nobody reads.

  It also exercises the seam with no network: a catalogue body in, normalised
  models out. }

{$mode delphi}{$H+}

uses
  SysUtils, Classes, fpjson, LLMEnv, LLMTLS, LLMProvider, LLMClient,
  { Linked for its initialization: it INSTALLS the vendor registrar. Without it
    the registry is empty, ByKey returns nil, and the first provider dereference
    is an EObjectCheck. }
  LLMProviders;

var
  Failures: Integer;

procedure Check(const AName: string; AOk: Boolean);
begin
  if AOk then
    WriteLn('  ok    ', AName)
  else
  begin
    WriteLn('  FAIL  ', AName);
    Inc(Failures);
  end;
end;

{ A tiny Fireworks-shaped catalogue: no friendly names, capability flags
  present, and two entries sharing a leaf so the label has to disambiguate. }
const
  FireworksBody =
    '{"data":[' +
    '{"id":"accounts/fireworks/models/rune","supports_chat":true,' +
    '"supports_tools":true,"context_length":1048576},' +
    '{"id":"accounts/fireworks/routers/rune","supports_chat":true,' +
    '"supports_tools":true,"context_length":null},' +
    '{"id":"accounts/fireworks/models/qwen3-embedding-8b",' +
    '"supports_chat":false,"supports_tools":false,"context_length":40960}' +
    ']}';

function ProviderCount: Integer;
var
  Reg: TProviderModelRegistry;
begin
  Reg := RegisteredProviders;
  try
    Result := Reg.Count;
  finally
    { NOT freed: RegisteredProviders returns a library-owned singleton, so
      freeing it leaves the global pointing at released memory. }
  end;
end;

function FireworksProvider: TLLMProvider;
var
  Reg: TProviderModelRegistry;
begin
  Reg := RegisteredProviders;
  try
    Result := Reg.ByKey('fireworks');
  finally
    { NOT freed. RegisteredProviders returns a library-owned SINGLETON, so
      freeing it leaves that global pointing at released memory - and the next
      call returns the dangling pointer rather than rebuilding, because the field
      is still non-nil. That is the whole bug: the example destroyed the
      registry, then read it. }
    
  end;
end;

procedure RunSeam;
var
  P: TLLMProvider;
  Models: TProviderModelArray;
  Err: string;
  I, Embeddings: Integer;
begin
  { The registry resolves the three vendors. }
  Check('three providers registered', ProviderCount = 3);
  P := ProviderByKey('');
  Check('an empty key resolves to Fireworks', P <> nil);

  { The neutral catalogue, with no http. }
  P := FireworksProvider;
  Check('the fireworks body parses',
    P.ParseModels(FireworksBody, Models, Err));
  Check('three models', Length(Models) = 3);

  Embeddings := 0;
  for I := 0 to High(Models) do
    if not Models[I].Usable then
      Inc(Embeddings);
  Check('the embedding entry is not usable', Embeddings = 1);

  { The disambiguation that the real catalogue needs: `rune` is served twice. }
  Check('a colliding leaf is qualified',
    Pos('(', ModelLabel(Models[0], Models)) > 0);
  Check('a unique leaf stays bare', ModelLabel(Models[2], Models) =
    'qwen3-embedding-8b');

  { A vendor with no catalogue must say so rather than invent a URL. }
  Check('models url is derived', P.ModelsUrl('https://x/v1/chat/completions') <> '');
end;

begin
  Failures := 0;
  WriteLn('llm-standalone: the provider library, on its own');
  RunSeam;
  if Failures > 0 then
  begin
    WriteLn('FAILED: ', Failures);
    Halt(1);
  end;
  WriteLn('all library checks passed');
end.
