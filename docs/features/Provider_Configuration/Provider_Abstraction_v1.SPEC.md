# Component Specification: Provider Abstraction v1

**Related Feature:** [FEATURE.md](FEATURE.md) — the seam that Stages 2–5 sit on.
**Supersedes:** the "one OpenAI-compatible client" assumption in `LLM_Client_v1`.

## Purpose

hildi speaks exactly one provider dialect today: whatever the hardest-coded
OpenAI chat-completions subset happens to accept. Supporting a second provider
means either a second copy of `HildiLLM` or a seam. This is the seam.

A `TLLMProvider` normalises **three** things that genuinely differ between
vendors — the models catalogue, the request body, and the error/finish-reason
vocabulary — behind one interface, so the harness never learns a vendor name.

## What actually differs (measured, not assumed)

Both catalogues were fetched live at spec time. This is the evidence the design
rests on.

| | Fireworks | OpenRouter | OpenAI |
| --- | --- | --- | --- |
| Models endpoint | `GET /inference/v1/models` | `GET /api/v1/models` | `GET /v1/models` |
| Auth for models | **required** (Bearer) | **none** (public) | **required** (Bearer) |
| Entries returned | 30 (paged, no token) | **455**, with `total_count` and `links` | list, `{object:"list", data:[…]}` |
| **Friendly name** | **absent** | **`name`, on all 455** (`"Z.ai: GLM 5.3 FlashX Legal"`) | **absent** |
| Chat capability | `supports_chat: bool` | `architecture.output_modalities` contains `"text"` | **absent** |
| Tool capability | `supports_tools: bool` | `"tools" ∈ supported_parameters` | **absent** |
| Context length | `context_length` (absent on 3 of 30) | `context_length` on all 455 | **absent** |
| Extras | `kind` (`HF_BASE_MODEL`/`ROUTER`/`EMBEDDING_MODEL`) | `pricing`, `description`, `top_provider`, `reasoning` | `shutdown_date` |
| Streaming usage | via `stream_options.include_usage` | **always sent**; the final chunk has a **non-empty** `choices` array | via `include_usage` (identical to ours) |
| Finish reasons | OpenAI's | OpenAI's **plus `error`** | OpenAI's, **incl. the deprecated `function_call`** |
| Tool-capable count | 26 / 30 | 390 / 455 | not declared |

Three consequences drive the design:

1. **A friendly name cannot be required.** OpenRouter has one for every model;
   Fireworks and OpenAI have none. The interface must express "no name" and the
   UI must fall back to the id leaf.
2. **Fireworks' model leaf is not unique** (`rune` and `auto` each appear twice,
   across `routers/` and `models/`). Anything shown to an operator must
   disambiguate, and the **full id is the only key**.
3. **Absence of a capability flag is not a claim of incapability.** OpenAI
   declares no `supports_chat`, no `supports_tools` and no context length at
   all. `Usable` must therefore be a *tri-state* — usable, unusable, unknown —
   and an unknown model must be **offered**, not hidden. Filtering on a flag that
   is merely absent would hide every OpenAI model.
4. **Finish reasons differ three ways**: OpenRouter adds `error`, OpenAI
   documents `function_call` (deprecated) which `SetFinish` drops to
   `frUnknown`. Both are silent failures: an `error` stream yields an empty
   answer, and a `function_call` yields a turn that looks like it stopped.

## Requirements

### Functional

- [ ] A provider is a named implementation with three capabilities: list models,
      build a request body, interpret a stream chunk.
- [ ] Adding a provider requires **no edit** to `HildiAgent`, the session, or the
      UI — only a new unit plus a registration line.
- [ ] An unknown/absent model name resolves to the provider's first usable model,
      never a crash.
- [ ] `error` as a finish reason is surfaced as a provider error with its
      message, not as an empty successful response.
- [ ] Everything the abstraction returns is **provider-neutral**: a model has an
      id, an optional display name, an optional context length, and optional
      capability flags.

### Non-Functional

- [ ] No new dependency: `fpjson` and the existing `TLLMTransport`.
- [ ] The abstraction adds no allocation ownership; the leak gate stays clean.
- [ ] A provider unit must not depend on `HildiAgent` (the Process Split).
- [ ] Secrets never leave the `Authorization` header.

## Contracts & Interfaces

### The neutral model

```pascal
type
  { One model, normalised. Only Id is guaranteed: every other field is honestly
    optional, because Fireworks serves no name and omits context_length for
    embedding entries, OpenRouter serves all of it, and OpenAI serves none of it
    beyond the id.

    THE CAPABILITY FLAGS ARE TRI-STATE, not Boolean. OpenAI's model object
    declares no chat or tool capability at all, so "absent" must mean UNKNOWN,
    not "false" - a picker that treated absent as false would hide every OpenAI
    model. }
  TProviderModel = record
    Id: string;              // the ONLY key; what a provider row stores
    DisplayName: string;     // '' => the caller derives one from Id
    ChatCapability: TCapability;   // Unknown when the vendor does not say
    ToolCapability: TCapability;
    ContextLength: Integer;  // 0 => unknown
    { True only when a vendor POSITIVELY says the model cannot serve a turn (an
      embedding or rerank entry). Unknown models are offered. }
    Usable: Boolean;
  end;

  TCapability = (capUnknown, capYes, capNo);

  TProviderModelArray = array of TProviderModel;

{ The label to show for a model. DisplayName when the provider serves one, else
  the id's last path segment, disambiguated by its parent when two leaves
  collide ('rune (routers)' vs 'rune (models)'). Pure, so it is tested without a
  catalogue. }
function ModelLabel(const AModel: TProviderModel;
  const ASiblings: TProviderModelArray): string;
```

### The provider seam

```pascal
type
  { A provider's identity and its wire dialect. Implementations live in their own
    unit (HildiProviderFireworks, HildiProviderOpenRouter) and are registered in
    one place, so adding a vendor touches no shared code. }
  TLLMProvider = class
  public
    { The stable key stored on a provider row and in `settings`. }
    function Key: string; virtual; abstract;
    { A human label for the provider picker. }
    function DisplayName: string; virtual; abstract;
    { The default chat endpoint when a row leaves it empty. }
    function DefaultEndpoint: string; virtual; abstract;
    { The endpoint that lists models, derived from the chat endpoint so a
      self-hosted or proxied install works. Nil when the vendor has none. }
    function ModelsEndpoint(const AChatEndpoint: string): string; virtual;

    { Fetch the catalogue. False on transport/HTTP failure with AError set; a
      partial or empty catalogue is TRUE with an empty array, because "this
      vendor listed nothing" is not an error. }
    function ListModels(const AConfig: TLLMConfig;
      out AModels: TProviderModelArray; out AError: TLLMError): Boolean; virtual;

    { Add provider-specific request fields. Called after the neutral body is
      built, so a provider only ever ADDS or REWRITES what it owns and can never
      corrupt the message array. }
    procedure DecorateRequest(const AConfig: TLLMConfig;
      ARoot: TJSONObject); virtual;

    { Extra headers beyond Authorization/Content-Type/Accept. OpenRouter's
      attribution headers are the only use today. }
    procedure ExtraHeaders(AHeaders: TStrings); virtual;

    { Interpret one stream chunk BEFORE the neutral parser sees it: report a
      provider error carried inside an otherwise-successful stream, and map the
      vendor's finish-reason vocabulary. }
    function InspectChunk(const AJson: TJSONObject; out AProviderError: string;
      out AFinishHint: string): Boolean; virtual;
  end;
```

### Registry

```pascal
{ The providers this build knows. Ordered, so a picker is stable. }
function RegisteredProviders: TLLMProviderArray;
{ '' => the Fireworks provider, which is what every existing install is. }
function ProviderByKey(const AKey: string): TLLMProvider;
```

## Architecture

### Prior Art & Reuse

- **`TLLMClient` + `TLLMTransport`** stay exactly as they are. The abstraction
  sits *above* the transport and *below* the client: a provider contributes body
  fields, headers, and chunk interpretation; the client still owns SSE, retry and
  cancellation. `TFakeTransport` therefore keeps working unchanged.
- **`BuildRequestBody`** already builds a `TJSONObject`; `DecorateRequest` gets
  that object rather than a new code path.
- **`ReadUsage`** already normalises three vendor spellings. It needs no change —
  verified: OpenRouter's `usage` arrives before the `choices` guard, and its
  non-empty-choices final chunk is therefore already handled.
- **`ResolveLLMConfig`** (Stage 1) owns environment resolution; the provider
  supplies only `DefaultEndpoint`, so there is one place a vendor default lives.
- **`HildiMCPProvider`** is the existing precedent for "a registered thing that
  contributes tools and prompt text behind an interface". Same shape, different
  domain.

### Component Boundaries

- `HildiLLMProvider.pas` — the interface, the registry, `TProviderModel`,
  `ModelLabel`, `TCapability`. No HTTP, no vendor knowledge.
- `HildiProviderFireworks.pas` — the Fireworks dialect.
- `HildiProviderOpenRouter.pas` — the OpenRouter dialect.
- `HildiProviderOpenAI.pas` — the OpenAI dialect. The **simplest** of the three
  and the one that must stay working, because "OpenAI-compatible" is what most
  self-hosted and proxied installs actually speak: `GET /v1/models` with a
  Bearer, the `{object:"list", data:[…]}` envelope, and a model object whose only
  useful field is `id`.
- `HildiLLM.pas` — unchanged except `TLLMConfig` gaining `Provider: string`.

### Data Flow

1. A provider row (Stage 2) or the environment names a provider key.
2. `ProviderByKey` resolves it; an unknown key is a configuration error naming
   the key, not a silent fallback to Fireworks.
3. `ListModels` populates a picker; `Usable` filters it.
4. A turn builds a neutral body, then `DecorateRequest` runs.
5. Each chunk is offered to `InspectChunk` before the neutral parser.

## Validation Rules

- A model id from a picker is stored **verbatim** — never a display name.
- `ModelLabel` output is never used as a key.
- A provider key that is not registered is `leConfig` before any I/O.

## Reasoning: a parameter with no capability signal

The Fireworks docs document `reasoning_effort` (`"medium"`, …) as a request
field, and `reasoning_content` on the response message. Two facts matter:

- **`reasoning_content` already works.** `TSSEParser` reads `delta.reasoning_content`
  (falling back to `delta.reasoning`), and `TChatResult.ReasoningContent` carries
  it. No change needed for any of the three providers.
- **`reasoning_effort` is not discoverable.** I checked the live Fireworks
  catalogue: its model entries expose only `supports_chat`, `supports_tools`,
  `supports_image_input` and `context_length`. Nothing says whether a model
  reasons. OpenRouter is the exception — it serves a `reasoning` object on 334 of
  455 models and lists `reasoning_effort` in `supported_parameters`.

So `reasoning_effort` is an operator-facing setting, not a catalogue-derived one:
a fourth `TLLMParam`-style field on the request config, omitted unless set, sent
by the provider that supports it. A model that ignores it returns an unchanged
response rather than an error, so a wrong guess is cheap.

```pascal
{ On the request config, alongside temperature. Omitted unless set, like every
  other Stage 1 parameter: a provider that ignores it is harmless, and an empty
  string is not a valid effort level. }
ReasoningEffort: string;   // '' => omit; 'low' | 'medium' | 'high'
```

Fireworks also documents `service_tier: "priority"` for its serverless modes.
That is a genuinely vendor-specific field with no cross-provider meaning, which
makes it the **first real customer of `DecorateRequest`** rather than a field on
the neutral config.

## Error Handling

- Model listing failure is reported but must not fail a session: the operator can
  still type a model id.
- **`finish_reason: "error"`** becomes `leProvider` with the vendor's `message`.
  Today it would be `frUnknown` with empty content — a silent empty answer, which
  is the worst possible failure mode.
- An HTTP 200 whose body is not a model list is `leProvider`, never an empty
  catalogue presented as "no models".

## Testing Requirements

All offline. `TFakeTransport` already captures the request body; model listing
needs a small seam for returning a canned body.

### Unit Tests

- [ ] `TestModelLabelFallsBackToTheIdLeaf` — Fireworks and OpenAI have no names.
- [ ] `TestModelLabelDisambiguatesCollidingLeaves` — `rune` appears twice.
- [ ] `TestModelLabelPrefersTheProviderName` — OpenRouter's `name`.
- [ ] `TestFireworksModelParsesItsCaps` — `supports_tools`/`context_length`.
- [ ] `TestOpenRouterModelParsesItsCaps` — `supported_parameters`,
      `output_modalities`.
- [ ] `TestOpenAIModelIsUsableWithNoCapabilityFlags` — the regression that
      matters: absent flags must not hide every OpenAI model.
- [ ] `TestAnEmbeddingModelIsNotUsable` — Fireworks and OpenRouter.
- [ ] `TestMissingContextLengthIsZeroNotACrash` — 3 of 30 Fireworks entries, and
      every OpenAI one.
- [ ] `TestDecorateRequestAddsOnlyItsOwnFields`.
- [ ] `TestErrorFinishReasonBecomesAProviderError` — OpenRouter.
- [ ] `TestDeprecatedFunctionCallFinishReasonIsToolCalls` — OpenAI.
- [ ] `TestUnknownProviderKeyIsAConfigError`.
- [ ] `TestOpenRouterUsageChunkWithNonEmptyChoicesIsRead`.
- [ ] `TestReasoningEffortIsOmittedWhenUnset` — the same tri-state rule as Stage 1.
- [ ] `TestFireworksServiceTierRidesDecorateRequest` — vendor-only field, neutral
      body untouched.

### Integration Tests

- [ ] A recorded OpenRouter SSE transcript (the docs' documented shape) replays
      through the unmodified parser and yields content, tool calls and usage.

## Three transports, one seam

Fireworks documents itself as reachable three ways: its own SDK, an
**OpenAI-compatible** endpoint (`https://api.fireworks.ai/inference/v1`), and an
**Anthropic-compatible** endpoint (`https://api.fireworks.ai/inference`). Two
conclusions:

1. **`https://api.fireworks.ai/inference/v1` being the OpenAI shape is the
   strongest argument for the `HildiProviderOpenAI` adapter**, not just for
   OpenAI's own API. Any Base-URL-compatible server — a local llama.cpp, an
   internal proxy, a Fireworks alias — is that adapter with a different endpoint.
   This is why it must be the simplest unit and the one that cannot regress.
2. **A fourth provider is not needed for Fireworks' Anthropic endpoint.** That
   would be a *transport* the harness does not speak: Anthropic's shape has
   `content` blocks, `tool_use`/`tool_result`, a top-level `system` parameter, and
   **`max_tokens` required**. Adding it means a new `TLLMClient`, not a new
   provider — a real second dialect, and out of scope for v1. Recorded here so
   nobody mistakes an endpoint swap for an adapter.

The one field Fireworks documents as required that we currently omit is
`max_tokens` on the Anthropic shape; the OpenAI shape is fine. That asymmetry is
the clearest evidence the two are not the same adapter with a different URL.

## Security Considerations
- The API key travels only in `Authorization`. Neither provider needs it in a
  body or a query string.
- `ListModels` for OpenRouter needs **no** key (verified); sending one anyway is
  harmless but must not be *required*, or an install with no key cannot browse.
- A model's `description` and `name` are attacker-influenceable strings rendered
  in a picker. Treat as text, never as markup.

## Success Criteria

- [ ] Three providers registered (Fireworks, OpenRouter, OpenAI); `HildiAgent` and
      the session compile unchanged against the seam.
- [ ] An existing Fireworks install behaves identically with no config change.
- [ ] Adding a third provider requires only a new unit and a registry line.
- [ ] `make check` green.

## Future Considerations

- **A third provider** (Anthropic-native, a local llama.cpp) is the test of the
  seam. If it needs an edit outside its own unit, the seam is wrong.
- **Pricing** is served by OpenRouter and would let Stage 5 report cost. Out of
  scope here, but it is one field on `TProviderModel` away.
- **Model caching**: 455 entries is ~800 KB. A `/provider` dialog must not refetch
  on every keystroke; a `provider_models` table keyed by provider plus a fetch
  timestamp is the natural home.
