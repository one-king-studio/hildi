# Component Specification: Tool Approvals

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildi.approval` is the generic, durable whitelist for tool calls. It
stores approval rules, matches a call's **ref** + **params** against them, and
resolves a decision (allow / ask / deny) across the global, workspace, and
session scopes.

Crucially, the **tool owns the approval granularity**: a tool reports the subject
of a call and the approval options it offers. The harness only provides the
prompt, the scope choice, and persistence, so tools with different shapes (the
shell command, an MCP tool) each get appropriate choices without harness
knowledge.

## Requirements

### Functional

- [ ] Store approval rules: `(effect, scope, workspace, session, ref, params,
      any_params)`.
- [ ] Match a subject `(ref, params)` against a rule: ref equal, and params
      either exact or an `any_params` prefix.
- [ ] Resolve across scopes: any matching deny denies; otherwise a matching allow
      at session, workspace, or global allows; otherwise ask.
- [ ] Load the rules relevant to a context (global + workspace + session) in one
      call.
- [ ] Save a rule, suppressing exact duplicates; remove a rule.
- [ ] Define a tool adapter (`IApprovableTool`) that reports the call's approval
      asks: subject, display summary, and the options offered.
- [ ] Resolve a batch of asks: deny-first pre-scan, then ask-only where no allow
      matches, prompting with the tool's options and persisting the choice.
- [ ] Keep the store optional behind `IApprovalStore`; an in-memory implementation
      supports tests.

### Non-Functional

- [ ] Pure matching is unit-testable without a store or prompt.
- [ ] Leak-clean; no global state.
- [ ] Security: no match means ask; matching never evaluates the call.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

### Public API

```pascal
unit hildi.approval;

interface

uses
  SysUtils;

type
  TApprovalScope = (asGlobal, asWorkspace, asSession);
  TApprovalEffect = (aeAllow, aeDeny);
  TApprovalDecision = (adAllow, adAsk, adDeny);

  TStringArray = array of string;

  { A persisted rule. Params is an ordered token list; AnyParams makes the
    stored tokens a prefix (a terminal wildcard). }
  TApprovalRule = record
    Effect: TApprovalEffect;
    Scope: TApprovalScope;
    WorkspaceId: Integer;   // 0 for global
    SessionId: string;      // '' unless session scope
    Ref: string;            // 'run_command:cat', 'browser:navigate_to_url'
    Params: TStringArray;
    AnyParams: Boolean;
  end;

  TApprovalRuleArray = array of TApprovalRule;

  { What a call looks like to the matcher. }
  TApprovalSubject = record
    Ref: string;
    Params: TStringArray;
  end;

  { An option a tool offers the operator for a specific subject. }
  TApprovalOption = record
    Key: string;            // 'once', 'exact', 'any', 'prefix', ...
    Caption: string;        // human text ('Label' is a Pascal keyword)
    Persists: Boolean;      // False for "once"
    Rule: TApprovalRule;    // Scope filled in by the service
  end;

  TApprovalOptionArray = array of TApprovalOption;

  { One approval unit reported by a tool. }
  TApprovalAsk = record
    Summary: string;                    // shown to the operator
    Subject: TApprovalSubject;
    Options: TApprovalOptionArray;
  end;

  TApprovalAskArray = array of TApprovalAsk;

  { A tool participates by reporting its asks. }
  IApprovableTool = interface
    function ApprovalAsks(const AArgumentsJson: string): TApprovalAskArray;
  end;

  { Persistence seam. }
  TApprovalContext = record
    WorkspaceId: Integer;
    SessionId: string;
  end;

  IApprovalStore = interface
    function Load(const AContext: TApprovalContext;
      out ARules: TApprovalRuleArray; out AError: string): Boolean;
    function Save(const ARule: TApprovalRule; out AError: string): Boolean;
    function Remove(const ARule: TApprovalRule; out AError: string): Boolean;
  end;

  { The operator's answer to one ask. }
  TApprovalChoice = record
    Allowed: Boolean;
    OptionKey: string;      // '' when denied
    Scope: TApprovalScope;  // chosen scope for a persisting option
  end;

  { Provided by the harness. Fires on the calling thread. }
  TApprovalPrompt = function(const AAsk: TApprovalAsk): TApprovalChoice
    of object;

  TApprovalBatchResult = record
    Allowed: Boolean;
    Denied: Boolean;
    Reason: string;         // names the matching/denying rule
  end;

  { Orchestrates matching, prompting, and persistence. }
  IApprovalService = interface
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;

function ApprovalMatches(const ARule: TApprovalRule;
  const ASubject: TApprovalSubject): Boolean;
function Decide(const ARules: TApprovalRuleArray;
  const ASubject: TApprovalSubject): TApprovalDecision;
function DefaultApprovalRule(const AEffect: TApprovalEffect): TApprovalRule;
```

### Store additions (`hildi.store`)

```pascal
function TSqliteStore.LoadApprovals(const AContext: TApprovalContext;
  out ARules: TApprovalRuleArray; out AError: TStoreError): Boolean;
function TSqliteStore.SaveApproval(const ARule: TApprovalRule;
  out AError: TStoreError): Boolean;
function TSqliteStore.RemoveApproval(const ARule: TApprovalRule;
  out AError: TStoreError): Boolean;
```

### Data Contracts

- Rule matching:
  - `Ref` must be equal.
  - `AnyParams = False` -> `Params` must equal the subject's params exactly
    (including both empty).
  - `AnyParams = True` -> `Params` must be a prefix of the subject's params
    (empty prefix matches any).
- Duplicate suppression key: `(scope, workspace, session, effect, ref, params,
  any_params)`.
- `TApprovalOption.Rule.Scope`/`WorkspaceId`/`SessionId` are ignored on input; the
  service sets them from the chosen `TApprovalChoice.Scope` and the context.

### Event Contracts

`TApprovalPrompt` runs on the loop's calling thread (single-threaded); no locking
is required by the caller.

## Architecture

### Prior Art & Reuse

- `hildi.store` migrations and typed methods.
- Workspaces and Sessions features provide the context ids.
- No general matcher exists; the rule is tiny and unit-tested.

### Component Boundaries

- **Responsibilities:** rule model, matching, scope resolution, batch
  orchestration, the adapter interface.
- **Dependencies:** `SysUtils`; the store (for the DB-backed store implementation).
- **Side effects:** store writes when an operator persists an option.

### Data Flow

1. A tool computes `ApprovalAsks` for its call (the command tool computes one ask
   per parsed segment).
2. `Resolve` loads rules for the context once.
3. Pre-scan: if any ask's subject matches a deny rule -> denied, no execution.
4. For each ask: if a session/workspace/global allow matches -> continue; if ask
   -> prompt with the tool's options; on a persisting choice, save the rule at
   the chosen scope; on deny -> denied.
5. If all asks resolve allowed -> `Allowed`; the tool executes.

### Integration Patterns

- Synchronous and in-process; no threads.
- The harness constructs the `IApprovalService` (store-backed `IApprovalStore`
  plus the console `TApprovalPrompt`) and gives it to the tool, along with the
  active workspace. The tool only declares its asks/options and consumes the
  decision.

## Validation Rules

- An empty `Ref` never matches.
- `AnyParams = True` with empty params matches the whole ref.
- A tool with no asks (nothing approvable) is allowed by definition.
- A persisting option with an empty `Key` is invalid (the service rejects it).

## Error Handling

### Error Types

- **Store:** load/save/remove failure -> `AError`; the service fails closed
  (deny), never proceeds.
- **Operator:** a deny or an unavailable prompt (no handler) -> deny, never
  allow.

### Error Contracts

No `TLLMError`. The tool converts a denied resolve into an error tool result
naming the ask summary and the rule reason.

## Testing Requirements

### Unit Tests (`tests/test_approval.pas`)

- [ ] `TestExactRefAndParamsMatch`
- [ ] `TestExactParamsRejectDifferentArgs`
- [ ] `TestAnyParamsPrefixMatches`
- [ ] `TestAnyParamsRejectsDifferentPrefix`
- [ ] `TestEmptyAnyParamsMatchesWholeRef`
- [ ] `TestRefMismatchDoesNotMatch`
- [ ] `TestDenyWinsOverAllow`
- [ ] `TestScopePrecedenceSessionOverWorkspaceOverGlobal`
- [ ] `TestNoMatchAsks`
- [ ] `TestDuplicateRulesSuppressed` (store)
- [ ] `TestSaveLoadRemoveRoundTrip` (store, temp db)
- [ ] `TestInMemoryStoreDoesNotTouchSqlite`
- [ ] `TestNoLeaks`

### Integration Tests

- [ ] `TestBatchDenyPreScanDoesNotPrompt`
- [ ] `TestPromptPersistsChosenRuleAtChosenScope`
- [ ] `TestOnceChoiceDoesNotPersist`
- [ ] `TestMissingPromptDenies`

## Performance Targets

- One rules load per call; matching is a linear scan of the relevant rules.

## Security Considerations

- Fail closed: no prompt, no store, or any error denies.
- Deny always wins, in any scope.
- The matcher compares stored ref/params only; it never parses or evaluates the
  call's content.
- An `any_params` approval on an interpreter effectively grants broad trust; the
  option label and reason must say so.

## Success Criteria

### Functional

- [ ] Contracts implemented; scopes and matching per the rules above.
- [ ] `make check` passes.

### Quality

- [ ] Matching tested without store or prompt.
- [ ] Store round trip and duplicate suppression tested.
- [ ] No leaks.

## Future Considerations

- Richer rule display and a `policy list`/`remove` CLI.
- Rule expiry and per-tool defaults.
- Server-side mirroring via Agent to Agent (A2A).
