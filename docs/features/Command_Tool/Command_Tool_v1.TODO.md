# Implementation Plan: Command Tool v1

**Related Specification:** `Command_Tool_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Build `hildegard.helper.command.tool`: the `run_command` agent tool that loads a
policy, obtains approval when required, executes synchronously through a seam
over `TCommandRunner`, caps output, and audits every decision. Depends on
`Command_Policy_v1` (classification) and `Tool_Reason_v1` (the `reason` field),
and on a small shell-parameter change in `hildegard.helper.process`.

> Deviation from template: `main`-only project, no feature branch.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [ ] **Add** `tests/test_command_tool.pas` to the uses clause of
      `tests/hildegard_helper_tests.pas`
- [ ] **Create** `src/hildegard.helper.command.tool.pas` interface types (no
      bodies): `TShellProfile`, `TCommandToolConfig`, `TCommandExecution`,
      `ICommandExecutor`, `ICommandPolicySource`, `TCommandAuditEntry`,
      `TApprovalRequest`, `TApprovalOutcome`, `TApprovalHandler`, constants
- [ ] **Create** `tests/test_command_tool.pas` with fakes: `TFakeExecutor`,
      `TMemoryPolicySource`, scripted approver

### Phase 2: Process shell parameter

- [ ] **Test**: `TestProcessRunnerUsesProvidedShell` in
      `tests/test_hildegard_helper.pas` - red
- [ ] **Implement**: add defaulted `AShellExecutable='/bin/bash'` and
      `AShellSwitch='-c'` parameters to `TCommandRunner.Create`; use them in
      `Execute` - green
- [ ] Confirm existing runner tests still pass unchanged

### Phase 3: Executor seam

- [ ] **Test**: `TestFakeExecutorDrivesTool` (fakes only)
- [ ] **Implement**: `TProcessCommandExecutor.Execute` wrapping `TCommandRunner`:
      output collected under a critical section, `Start`, `WaitFor`, build
      `TCommandExecution`
- [ ] **Test**: `TestTimeoutReports124` (executor maps timeout to 124)
- [ ] **Verify**: no leak from the joined runner thread

### Phase 4: Tool behaviour (TDD)

- [ ] **Test**: `TestRegisterAddsRunCommandSpec`, `TestDefaultShellProfileIsPosixBash`
- [ ] **Test**: `TestMissingCommandArgumentFails`, `TestInvalidJsonFails`,
      `TestMissingReasonNotExecuted`
- [ ] **Test**: `TestAllowExecutesAndReturnsOutput`
- [ ] **Test**: `TestDenyDoesNotExecuteAndFails`
- [ ] **Test**: `TestAskWithNoApproverDenies`
- [ ] **Test**: `TestAskAllowOnceExecutesWithoutPersisting`
- [ ] **Test**: `TestAskAllowAlwaysExecutesAndPersists`
- [ ] **Test**: `TestAskDenyDoesNotExecute`
- [ ] **Test**: `TestReasonPassedToApprover`, `TestReasonRecordedInAudit`
- [ ] **Test**: `TestOutputIsTruncatedWithMarker`
- [ ] **Test**: `TestPolicyReloadedEachCall`, `TestLoadPolicyErrorFailsClosed`
- [ ] **Test**: `TestAuditRecordedForAllowDenyAndOutcome`
- [ ] **Test**: `TestHandlerNeverRaises`
- [ ] **Implement**: `TCommandTool.Run`/`Register` incrementally until green
- [ ] **Implement**: `DefaultShellProfile`

### Phase 5: Store-backed source

- [ ] **Define** the settings keys (`command.policy.*`) as constants
- [ ] **Test**: `TestStoreCommandPolicySourceRoundTrip` - set policy settings,
      load them, save an approval, write an audit row, query it via the store
      request API (reuse the existing store test fixture)
- [ ] **Implement**: `TStoreCommandPolicySource.LoadPolicy` / `SaveApproval` /
      `RecordAudit` (JSON arrays via `fpjson`; audit via `EnqueueRequest` +
      `FinishRequest`, `Kind='command'`)
- [ ] Verify a malformed setting yields an error (tool then fails closed)

### Phase 6: Loop integration

- [ ] **Test**: `TestRoundTripAgainstFakeProvider` - model calls `run_command`,
      fake executor returns output, loop feeds it back (use `tests/llm_fakes.pas`)

### Phase 7: CLI wiring & docs

- [ ] **Wire** `examples/agent_cli.pas`: open the store, build
      `TStoreCommandPolicySource`, construct `TCommandTool` with a thin console
      approver, register it; pass no approver in non-interactive mode (deny)
- [ ] **Update** `.env.example` / usage text if a policy or shell setting is
      surfaced
- [ ] **Doc comments** on the public interface
- [ ] **Update** `docs/features/FEATURES.md` (new feature row) and `HANDOFF.md`
      (unit map, test count, open threads)

### Phase 8: Validation

- [ ] `make test SUITE=TestCommandTool`
- [ ] `make test`
- [ ] `make test-leak`
- [ ] `make check`
- [ ] Manual smoke: CLI runs an allowlisted `date`, prompts on an unknown
      command, denies a denied pattern

## Dependencies & Ordering

### Must Complete Before Starting

- `Tool_Reason_v1` (the `reason` field and event signature)
- `Command_Policy_v1` (parser/classifier)
- Process shell parameters (Phase 2) before the executor (Phase 3)

### Can Be Done in Parallel

- Store-backed source (Phase 5) and CLI wiring (Phase 7) once the tool interface
  is stable

### Critical Path

1. Process shell parameter
2. Executor seam
3. Tool policy/approval/execution
4. Store source + audit
5. CLI + `make check`

## Files to Create/Modify

### New Files

```
src/hildegard.helper.command.tool.pas
tests/test_command_tool.pas
```

### Modified Files

```
src/hildegard.helper.process.pas    (defaulted shell/switch parameters)
tests/hildegard_helper_tests.pas    (add test unit to uses)
tests/test_hildegard_helper.pas     (shell parameter test)
examples/agent_cli.pas              (wire tool, store source, console approver)
docs/features/FEATURES.md           (feature row)
HANDOFF.md                          (unit map, state)
```

## Success Criteria

- [ ] All tasks checked; every SPEC acceptance criterion maps to a test
- [ ] `run_command` gates, executes, caps output, and audits
- [ ] Tool tests use fakes only (no SQLite, network, or real process)
- [ ] `make check` passes
- [ ] CLI smoke test behaves as specified
- [ ] Implementation matches the specification

## Notes & Considerations

- `TCommandRunner`'s output callback fires on the runner thread; collect under a
  `TCriticalSection` and only read after `WaitFor` (see `HANDOFF.md` lessons).
- The stores's `EnqueueRequest` always inserts `rsPending`; call `FinishRequest`
  to record the outcome. Two writes per audit row; acceptable.
- Keep `TToolHandler` unchanged: the policy and approver live on the tool
  instance.
- Fail closed everywhere: any ambiguity or error path denies execution.
- Record any spec divergence here with the reason.
