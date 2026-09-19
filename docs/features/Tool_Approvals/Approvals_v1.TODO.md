# Implementation Plan: Tool Approvals v1

**Related Specification:** `Approvals_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

> **Progress:** Phases 2-4 (matching, store, service) and the store-backed
> `IApprovalStore` are implemented and committed (20 tests in `TestApproval`).
> Remaining: Phase 5 (command adapter) and Phase 6 (CLI wiring). The checkboxes
> below have not all been ticked retroactively; trust this note and the tests.

## Overview

Build `hildegard.helper.approval`: the generic rule model, matcher, scope
resolution, store-backed and in-memory `IApprovalStore`, the `IApprovalService`
that prompts and persists tool-owned options, and the command tool's
`IApprovableTool` adapter. Depends on Workspaces (context) and precedes/parallels
Sessions (session context).

> `main`-only project: no feature branch.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [ ] Add `tests/test_approval.pas` to the uses clause of
      `tests/hildegard_helper_tests.pas`
- [ ] Create `src/hildegard.helper.approval.pas` with the interface from the SPEC
- [ ] Create `tests/test_approval.pas` with an empty `TTestCase`

### Phase 2: Matching (TDD, pure)

- [ ] **Test**: `TestExactRefAndParamsMatch`, `TestExactParamsRejectDifferentArgs` - red
- [ ] **Test**: `TestAnyParamsPrefixMatches`, `TestAnyParamsRejectsDifferentPrefix`,
      `TestEmptyAnyParamsMatchesWholeRef`
- [ ] **Test**: `TestRefMismatchDoesNotMatch`
- [ ] **Implement**: `ApprovalMatches`
- [ ] **Test**: `TestDenyWinsOverAllow`,
      `TestScopePrecedenceSessionOverWorkspaceOverGlobal`, `TestNoMatchAsks`
- [ ] **Implement**: `Decide`

### Phase 3: Store (TDD)

- [ ] **Add** migration v3 `approvals(id INTEGER PK, effect INTEGER, scope INTEGER,
      workspace_id INTEGER, session_id TEXT, ref TEXT, params TEXT, any_params
      INTEGER, created_at INTEGER)` with a uniqueness constraint
- [ ] **Test**: `TestSaveLoadRemoveRoundTrip` on a temp db - red
- [ ] **Implement**: `TSqliteStore.LoadApprovals`, `SaveApproval`, `RemoveApproval`
- [ ] **Test**: `TestDuplicateRulesSuppressed`
- [ ] **Implement**: duplicate suppression on the uniqueness key
- [ ] **Create** `TMemoryApprovalStore` (in `src`, not just tests) for the
      no-store fallback and for tests
- [ ] **Test**: `TestInMemoryStoreDoesNotTouchSqlite`

### Phase 4: Service (TDD)

- [ ] **Test**: `TestBatchDenyPreScanDoesNotPrompt`
- [ ] **Test**: `TestPromptPersistsChosenRuleAtChosenScope`
- [ ] **Test**: `TestOnceChoiceDoesNotPersist`
- [ ] **Test**: `TestMissingPromptDenies`
- [ ] **Implement**: `TApprovalService.Resolve` (load once, deny pre-scan, ask-only
      where no allow, prompt with the ask's options, persist the choice)
- [ ] **Test**: `TestNoLeaks`

### Phase 5: Command adapter (TDD)

- [ ] **Test**: ref/params derivation: `cat test` -> `run_command:cat` params
      `[test]`; bare `cat` -> params `[]`
- [ ] **Implement**: `TCommandTool` implements `IApprovableTool.ApprovalAsks`,
      one ask per parsed segment, options: once / exact / any / prefix where a
      non-flag prefix exists
- [ ] **Test**: `TestCommandOptionsOfferExpectedPatterns`
- [ ] **Refactor**: `TCommandTool.Run` to use `IApprovalService` per segment;
      remove `ICommandPolicySource`, `command.policy.*` settings, `=`,
      interleaved `*`, `any_params`-by-string, and the requests-table audit
- [ ] **Test**: `TestAllowExecutes`, `TestDenyDoesNotExecute`,
      `TestAlwaysPersistsAndLaterRunDoesNotPrompt`
- [ ] **Test**: path checks use the workspace root; redirection targets still ask

### Phase 6: CLI wiring & docs

- [ ] Build `TApprovalService` in `examples/agent_cli.pas`: store-backed
      `IApprovalStore` (or `TMemoryApprovalStore` when no store), console prompt
      showing the ask summary and the tool's options plus scope choice
- [ ] Update `.env.example` / usage if needed
- [ ] Update `FEATURES.md` / `HANDOFF.md`

### Phase 7: Validation

- [ ] `make test SUITE=TApprovalTest`, `make test`, `make test-leak`, `make check`
- [ ] Manual smoke: global read command approved once; scoped command asks in a
      different workspace

## Dependencies & Ordering

- Workspaces v1 must land first (context ids and root).
- Sessions v1 needed for session-scope persistence; global/workspace approvals
  work without it.
- Removes the superseded command tool's policy/audit code.

## Files to Create/Modify

### New Files

```
src/hildegard.helper.approval.pas
tests/test_approval.pas
```

### Modified Files

```
src/hildegard.helper.store.pas        (migration v3, approval methods)
src/hildegard.helper.command.tool.pas (IApprovableTool adapter; drop policy/audit)
tests/test_command_tool.pas           (rewrite for approvals)
examples/agent_cli.pas                (wire service + prompt)
tests/hildegard_helper_tests.pas
```

## Success Criteria

- [ ] All tasks checked; every SPEC acceptance criterion has a test
- [ ] Generic matcher tested without store or prompt
- [ ] `run_command` offers and persists its own options
- [ ] `make check` passes; no leaks

## Notes & Considerations

- Fail closed everywhere: no store, no prompt, or any error denies.
- `any_params` on an interpreter is broad trust; the label/reason must say so.
- Keep the command parser (`command.policy`) untouched except for what the adapter
  needs; delete the retired classification/pattern code rather than leaving it
  dead.
