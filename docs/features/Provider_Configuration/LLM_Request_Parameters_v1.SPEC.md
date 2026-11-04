# Component Specification: LLM Request Parameters v1

**Related Feature:** [FEATURE.md](FEATURE.md) — Stage 1.

## Purpose

Add the sampling and control parameters of an OpenAI-compatible chat-completions
request to what hildi can send, with **nothing sent unless the operator asked for
it**. This is the first slice of Provider Configuration and it is deliberately
small: environment in, JSON body out, no schema change and no protocol change.

## Requirements

### Functional

- [ ] Seven optional parameters are resolvable from the environment:
      `temperature`, `top_p`, `max_tokens`, `stop`, `frequency_penalty`,
      `presence_penalty`, `seed`.
- [ ] Each is **tri-state**: unset, or set to a value. Unset means the key is
      absent from the JSON body.
- [ ] A set-but-invalid value is a `leConfig` error naming the variable and the
      offending text, raised before any network I/O.
- [ ] `stop` accepts a comma-separated list and is sent as a JSON **array**.
- [ ] With no parameter set, the body is byte-identical to today's.
- [ ] `ResolveLLMConfig` is the single resolution point, so the CLI, the runtime
      and the TUI's display all agree.

### Non-Functional

- Performance: resolution is a handful of `getenv` calls per client construction,
  not per request.
- Reliability: no new allocation ownership; no leaks under the heaptrc gate.
- Portability: `GetEnvLegacy` already abstracts the env read.

## Contracts & Interfaces

### Configuration

```pascal
type
  { One optional request parameter. Tri-state on purpose: a zero temperature and
    an absent temperature are different requests, so a sentinel would be a lie. }
  TLLMParam = record
    Set_: Boolean;      // False => the key is absent from the body
    Value: Double;      // used by the numeric parameters
  end;

  TLLMConfig = record
    Endpoint: string;
    Model: string;
    ApiKey: string;
    ConnectTimeoutMs: Integer;
    ReadTimeoutMs: Integer;
    { NEW: all optional; Set_ = False leaves the key out of the request. }
    Temperature: TLLMParam;
    TopP: TLLMParam;
    MaxTokens: TLLMParam;        // Integer semantics, carried as Double
    FrequencyPenalty: TLLMParam;
    PresencePenalty: TLLMParam;
    Seed: TLLMParam;             // Integer semantics, carried as Double
    Stop: TStringArray;          // empty => no `stop` key; one entry => one-element array
  end;
```

The implementer chooses the concrete field shape; the contract is only the
tri-state semantics and that an unset parameter produces no key.

### Resolution

```pascal
{ Fills the optional parameters from the environment, leaving any already-set
  field alone (so an explicit config still wins). Returns False and fills AError
  naming the variable when a value is present but unparseable. Pure apart from
  the environment read, so it is testable. }
function ResolveLLMConfig(const AConfig: TLLMConfig;
  out AError: string): Boolean;
```

### Environment variables

| Variable | JSON key | Type | Range |
| --- | --- | --- | --- |
| `HILDI_LLM_TEMPERATURE` | `temperature` | float | 0–2 (provider convention) |
| `HILDI_LLM_TOP_P` | `top_p` | float | 0–1 |
| `HILDI_LLM_MAX_TOKENS` | `max_tokens` | integer | > 0 |
| `HILDI_LLM_STOP` | `stop` | comma-separated string | 1–4 entries |
| `HILDI_LLM_FREQUENCY_PENALTY` | `frequency_penalty` | float | −2–2 |
| `HILDI_LLM_PRESENCE_PENALTY` | `presence_penalty` | float | −2–2 |
| `HILDI_LLM_SEED` | `seed` | integer | ≥ 0 |

All carry the `GetEnvLegacy` fallback to the `HILDEGARD_LLM_*` spelling, matching
`HILDI_LLM_MODEL` and `HILDI_LLM_API_KEY`.

### Serialisation

The body gains its keys **after** `stream_options` and **before** `messages`:

```jsonc
{
  "model": "…",
  "stream": true,
  "stream_options": {"include_usage": true},
  "temperature": 0.2,          // only when set
  "top_p": 0.95,               // only when set
  "max_tokens": 4096,          // only when set
  "stop": ["</answer>"],       // only when non-empty; always an array
  "frequency_penalty": 0.0,    // only when set — 0.0 IS a choice
  "presence_penalty": 0.0,     // only when set
  "seed": 42,                  // only when set
  "messages": [ … ],
  "tools": [ … ]
}
```

## Architecture

### Prior Art & Reuse

- `TLLMConfig` + `ResolveLLMConfig` (`src/HildiLLM.pas`) already exist and already
  do env-with-legacy-fallback for `model` and `ApiKey`. This extends that record
  and that function; no new unit.
- `GetEnvLegacy` (`src/HildiEnv.pas`) is the established env accessor and already
  handles the rename fallback.
- `BuildRequestBody` already builds a `TJSONObject` and is already asserted on by
  `tests/TestLLM.pas` through `TFakeTransport.LastBody`. The tests extend rather
  than invent.
- `fpjson` serialises floats and arrays directly; no formatting code is needed.

### Component Boundaries

- **`HildiLLM`** owns the parameter set, its resolution, and its serialisation.
  It stays the only unit that knows the provider JSON shape.
- **`HildiCLI` / `HildiSessionRuntime` / `HildiHarnessView`** are not touched in
  v1. They read `TLLMConfig` through `ResolveLLMConfig`, so any display they do
  later automatically agrees with the request.
- **`HildiStore`** is not touched.

### Data Flow

1. A caller constructs a `TLLMConfig` (usually `Default(TLLMConfig)`).
2. `TLLMClient.Create` calls `ResolveLLMConfig`, which fills unset fields from the
   environment and fails on an unparseable value.
3. `Complete` validates model/key/TLS, then `BuildRequestBody` emits only the keys
   whose field is set.
4. Nothing is persisted. Stage 5 of the FEATURE records it on the turn.

## Validation Rules

### Input

- A numeric value that does not parse, or is outside its documented range, is a
  configuration error. It is **not** clamped: silently substituting a value the
  operator did not ask for is worse than refusing.
- `max_tokens` and `seed` must parse as integers; `1.5` for `max_tokens` is an
  error, not a truncation.
- `stop` is split on `,`; empty segments are dropped. A `stop` that yields no
  entries is treated as unset.

### Output Guarantees

- An unset parameter emits no key at all (asserted per parameter).
- A set parameter emits exactly the JSON type the provider expects: number,
  integer, or array of strings.
- `Authorization` is the only place the key appears.

## Error Handling

- Reuse `TLLMError` with `leConfig`. The message names the variable
  (`HILDI_LLM_TEMPERATURE`) and the detail carries the offending text, so an
  operator can fix it without guessing.
- A configuration error is terminal: `IsRetryable` already returns False for
  `leConfig`.

## Testing Requirements

All tests extend `tests/TestLLM.pas` and use the existing `TFakeTransport`, whose
`LastBody` is the exact string sent. No network.

### Unit Tests

- [ ] With nothing set, the body has none of the seven keys (guards the default
      path against drift).
- [ ] Each parameter, set alone, appears with the right key and JSON type.
- [ ] `temperature=0` is present in the body — proves tri-state, and would fail
      for a sentinel-zero design.
- [ ] `stop="a,b"` becomes `["a","b"]`; `stop=""` emits no key.
- [ ] An unparseable value returns `False` with `leConfig` and names the variable.
- [ ] An out-of-range value is rejected, not clamped.
- [ ] `ResolveLLMConfig` legacy fallback: `HILDEGARD_LLM_TEMPERATURE` is honoured
      when the `HILDI_` spelling is unset, and the new name wins when both are set.
- [ ] An explicitly-set field in the input config is not overwritten by the
      environment.

## Performance Targets

Negligible: seven `getenv` calls per `TLLMClient` construction.

## Security Considerations

- No parameter is a secret, so none needs masking.
- The API key must not become a flag or a stored plaintext row in this stage; v1
  does not touch key handling at all.
- An error detail echoes the offending **value**, which is safe for these
  parameters and deliberately does not echo the key.

## Success Criteria

### Functional

- [ ] All seven parameters work from the environment, and are omitted when unset.
- [ ] The default-path byte-identity test passes.
- [ ] All validation cases return `leConfig` before any I/O.

### Quality

- [ ] `make check` green (both suite passes and both isolation checks).
- [ ] No leaks.
- [ ] `FEATURE.md` stage 1 boxes ticked; `FEATURES.md` row added.

## Future Considerations

- `TLLMConfig` gains a `Provider: TProviderId` and the parameters come from a
  stored provider row instead of the environment (stage 2). The resolution order
  becomes store → env → default, and this SPEC's environment path becomes the
  fallback.
- A turn records the resolved parameters (stage 5), which means the store needs
  the values at `BeginRequest` time — already available, since the client holds
  the resolved config.
