# Component Specification: Tool-Call Reason

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

This component adds a **required, short, human-readable `reason`** to every tool
call the model makes. It exists so the operator can see *why* the agent is
asking to run something, and so approval prompts and audit records carry intent
rather than bare arguments.

It is a change to the shared tool contract in `hildi.agent`, not a
`run_command`-only parameter: the requirement is enforced by the registry and the
loop for every registered tool, so a tool author cannot forget it. It is specced
here because the Command Tool's approval and audit are the first consumers.

> **Cross-feature note:** this modifies the Agent Loop's tool contract
> (`hildi.agent`) and the transcript (`hildi.transcript`).
> When implemented, the Agent Loop feature should be updated to reference this
> spec, and `Agent_Loop_v1.SPEC.md`'s `TToolCallEvent` contract superseded.

## Requirements

### Functional

- [ ] Every tool spec advertised to the provider declares a `reason` string
      parameter and lists it as required, guaranteed by registration rather than
      by each tool author.
- [ ] Before dispatching a tool call, the loop extracts `reason` from the
      arguments JSON and requires it to be a non-empty string.
- [ ] A call with a missing, blank, or non-string `reason` is not executed; it
      produces an error tool result and the loop continues.
- [ ] The extracted reason is delivered on the tool-call event so it can be
      displayed.
- [ ] The tool handler still receives the full arguments JSON, including
      `reason`; extraction does not alter or strip the arguments.
- [ ] Registering a tool whose schema already includes `reason` is idempotent
      (it is required, never duplicated).

### Non-Functional

- [ ] Leak-clean under `make test-leak`.
- [ ] No behaviour change for a well-formed call beyond the extra required field.
- [ ] The reason is treated as opaque display/storage text; it is never parsed
      as a command, path, or policy input.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies. This section describes
> the delta to `hildi.agent`; unchanged types are as in
> `Agent_Loop_v1.SPEC.md`.

### Changed public API

```pascal
unit hildi.agent;

type
  { CHANGED: gains AReason, the model's stated reason for the call ('' if none
    or invalid). Fires before dispatch, on the loop's calling thread. }
  TToolCallEvent = procedure(const AId, AName, AArguments, AReason: string)
    of object;

const
  ToolReasonParamName = 'reason';

{ Returns True and sets AReason when the arguments JSON contains a non-empty
  string "reason". On failure AError explains why; AReason is ''. }
function ExtractToolReason(const AArgumentsJson: string;
  out AReason: string; out AError: string): Boolean;
```

`TToolRegistry`, `TRegisteredTool`, `TAgentEvents`, `TAgentLoop`, and
`TToolHandler` keep their existing shapes; only the event callback signature and
the registry's registration behaviour change.

### Data Contracts

- Advertised schema guarantee: after `TToolRegistry.Add`, every
  `TToolSpec.ParametersJson` is a JSON object whose `properties` contains a
  `reason` object of `"type":"string"`, and whose `required` array contains
  `"reason"`. Existing tool-defined parameters are preserved.
- A missing `reason` becomes an error **tool result** of the form
  `error: tool "<name>" missing required "reason"`, appended like any other
  result; it is not a loop failure.

### Event Contracts

- `OnToolCall(Id, Name, Arguments, Reason)` fires once per call before dispatch,
  with `Reason = ''` when extraction failed, so the transcript can still show the
  attempted call.
- `OnToolResult` is unchanged and follows with the error result.
- Both fire on the calling thread during `Send`.

## Architecture

### Prior Art & Reuse

- `hildi.agent` already owns the registry and dispatch; this is a
  small extension, not a new path.
- `fpjson`/`jsonparser` (already used by the LLM client) is reused to inspect and
  augment the arguments/schema JSON; no string concatenation of JSON.
- The transcript's existing tool-call line gains the reason; no new renderer.

### Component Boundaries

- **Responsibilities:** guarantee the reason parameter exists in every advertised
  schema; extract and validate it before dispatch; surface it on the event.
- **Dependencies:** `fpjson`, `SysUtils`.
- **Side effects:** none beyond altering the stored/advertised `ParametersJson`
  at registration.

### Data Flow

1. `TToolRegistry.Add` augments `ParametersJson` to require `reason`.
2. `TAgentLoop.BuildRequest` advertises the augmented specs unchanged.
3. On a tool-call turn, `ExecuteToolCalls` extracts `reason` per call.
4. If extraction fails: emit `OnToolCall` (reason `''`), append the error tool
   result, mark the call not-ok, continue.
5. Otherwise: emit `OnToolCall` with the reason, dispatch the handler, and
   continue as today.

### Integration Patterns

- Synchronous and in-process; no ownership changes. The augmented schema string
  is owned by `TToolSpec` as before.

## Validation Rules

### Input

- `reason` must be present, a JSON string, and non-empty after trimming.
- A handler whose tool schema is malformed (not a JSON object) causes `Add` to
  reject the spec (ignore it, consistent with the existing empty-name rule) or to
  raise a documented error - the implementer pins one behaviour with a test.

### Output Guarantees

- Every advertised tool regardless of origin has the same required `reason`
  contract.
- Extraction never throws for arbitrary input; bad JSON yields `False` + error.

## Error Handling

### Error Types

- **Validation:** missing/blank/non-string reason -> error tool result, not an
  exception.
- **Schema:** malformed `ParametersJson` at registration -> documented
  rejection; does not corrupt other tools.

### Error Contracts

The reason failure is a `TToolHandler`-style content error (a `crTool` message),
not a `TLLMError`. No new error codes.

## Testing Requirements

> What to test; the implementer decides how. Additions to `tests/test_agent.pas`
> and `tests/test_transcript.pas`.

### Unit Tests

- [ ] `TestRegistrationAddsRequiredReasonParam`
- [ ] `TestRegistrationPreservesExistingParams`
- [ ] `TestRegistrationIsIdempotent`
- [ ] `TestExtractReasonAcceptsNonEmpty`
- [ ] `TestExtractReasonRejectsMissing`
- [ ] `TestExtractReasonRejectsBlank`
- [ ] `TestExtractReasonRejectsNonString`
- [ ] `TestExtractReasonRejectsInvalidJson`
- [ ] `TestCallWithoutReasonReturnsErrorAndContinues`
- [ ] `TestHandlerReceivesFullArgumentsIncludingReason`
- [ ] `TestToolCallEventCarriesReason`
- [ ] `TestPromptAdvertisesReasonRequired` (request JSON contains the reason param)
- [ ] `TestNoLeaks` (enforced by `make test-leak`)

### Integration Tests

- [ ] `TestRoundTripWithReasonAgainstFakeTransport` - a canned tool call that
      includes `reason` executes and feeds back.
- [ ] `TestTranscriptShowsToolCallReason` - the transcript renders the reason.

## Performance Targets

- One extra JSON parse per tool call; negligible.

## Security Considerations

- The reason is untrusted, model-authored text: it is displayed and stored, never
  executed or trusted. Approval must never rely on the reason being truthful -
  the policy decision is made from the parsed command, and the reason is
  context for the human only.
- Requiring a reason is not a security control; it is an accountability and UX
  control. The SPEC must not imply otherwise.

## Success Criteria

### Functional

- [ ] Every advertised tool carries a required `reason`.
- [ ] Calls without a reason are rejected as error tool results.
- [ ] The reason reaches the transcript, and (via the command tool) approval and
      audit.
- [ ] `make check` passes.

### Quality

- [ ] No leaks; no regression in existing Agent Loop tests beyond the event
      signature change.

## Future Considerations

- A maximum reason length, to bound prompt/audit growth.
- Per-tool overrides for tools where a reason is meaningless.
- Surfacing reasons in the transcript's summary line rather than inline.
- Using reasons to improve approval lists ("recently approved because ...").
