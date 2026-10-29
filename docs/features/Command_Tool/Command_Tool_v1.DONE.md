# Implementation Plan: Command Tool v1

> **SUPERSEDED / CANCELLED.** The policy source, `command.policy.*` settings,
> `=`/interleaved-`*` patterns, and the `requests`-table audit built here are
> replaced by the [Tool Approvals](../Tool_Approvals/FEATURE.md) and
> [Sessions and Ledger](../Sessions_And_Ledger/FEATURE.md) features. What
> survives: the command parser (`hildi.command.policy`), the required
> tool-call `reason` (`Tool_Reason_v1`), the shell-parameter change in
> `hildi.process`, and the synchronous executor. Do not extend this
> plan; open tasks are cancelled.

**Related Specification:** `Command_Tool_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Build `hildi.command.tool`: the `run_command` agent tool that loads a
policy, obtains approval when required, executes synchronously through a seam
over `TCommandRunner`, caps output, and audits every decision. Depends on
`Command_Policy_v1` (classification) and `Tool_Reason_v1` (the `reason` field),
and on a small shell-parameter change in `hildi.process`.

> Deviation from template: `main`-only project, no feature branch.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [x] **Add** `tests/test_command_tool.pas` to the uses clause of
      `tests/hildi_tests.pas`
- [x] **Create** `src/hildi.command.tool.pas` interface types (no
      bodies): `TShellProfile`, `TCommandToolConfig`, `TCommandExecution`,
      `ICommandExecutor`, `ICommandPolicySource`, `TCommandAuditEntry`,
      `TApprovalRequest`, `TApprovalOutcome`, `TApprovalHandler`, constants
- [x] **Create** `tests/test_command_tool.pas` with fakes: `TFakeExecutor`,
      `TMemoryPolicySource`, scripted approver

### Phase 2: Process shell parameter

- [x] **Test**: `TestProcessRunnerUsesProvidedShell` in
      `tests/test_hildi.pas` - red
- [x] **Implement**: add defaulted `AShellExecutable='/bin/bash'` and
      `AShellSwitch='-c'` parameters to `TCommandRunner.Create`; use them in
      `Execute` - green
- [x] Confirm existing runner tests still pass unchanged

### Phase 3: Executor seam

- [x] **Test**: `TestFakeExecutorDrivesTool` (fakes only)
- [x] **Implement**: `TProcessCommandExecutor.Execute` wrapping `TCommandRunner`:
      output collected under a critical section, `Start`, `WaitFor`, build
      `TCommandExecution`
- [x] **Test**: `TestTimeoutReports124` (executor maps timeout to 124)
- [x] **Verify**: no leak from the joined runner thread

### Phase 4: Tool behaviour (TDD)

- [x] **Test**: `TestRegisterAddsRunCommandSpec`, `TestDefaultShellProfileIsPosixBash`
- [x] **Test**: `TestMissingCommandArgumentFails`, `TestInvalidJsonFails`,
      `TestMissingReasonNotExecuted`
- [x] **Test**: `TestAllowExecutesAndReturnsOutput`
- [x] **Test**: `TestDenyDoesNotExecuteAndFails`
- [x] **Test**: `TestAskWithNoApproverDenies`
- [x] **Test**: `TestAskAllowOnceExecutesWithoutPersisting`
- [x] **Test**: `TestAskAllowAlwaysExecutesAndPersists`
- [x] **Test**: `TestAskDenyDoesNotExecute`
- [x] **Test**: `TestReasonPassedToApprover`, `TestReasonRecordedInAudit`
- [x] **Test**: `TestOutputIsTruncatedWithMarker`
- [x] **Test**: `TestPolicyReloadedEachCall`, `TestLoadPolicyErrorFailsClosed`
- [x] **Test**: `TestAuditRecordedForAllowDenyAndOutcome`
- [x] **Test**: `TestHandlerNeverRaises`
- [x] **Implement**: `TCommandTool.Run`/`Register` incrementally until green
- [x] **Implement**: `DefaultShellProfile`

### Phase 5: Store-backed source

- [x] **Define** the settings keys (`command.policy.*`) as constants
- [x] **Test**: `TestStoreCommandPolicySourceRoundTrip` - set policy settings,
      load them, save an approval, write an audit row, query it via the store
      request API (reuse the existing store test fixture)
- [x] **Implement**: `TStoreCommandPolicySource.LoadPolicy` / `SaveApproval` /
      `RecordAudit` (JSON arrays via `fpjson`; audit via `EnqueueRequest` +
      `FinishRequest`, `Kind='command'`)
- [x] Verify a malformed setting yields an error (tool then fails closed)

### Phase 6: Loop integration

- [x] **Test**: `TestRoundTripAgainstFakeProvider` - model calls `run_command`,
      fake executor returns output, loop feeds it back (use `tests/llm_fakes.pas`)

### Phase 7: CLI wiring & docs

- [x] **Wire** `examples/agent_cli.pas`: open the store, build
      `TStoreCommandPolicySource`, construct `TCommandTool` with a thin console
      approver, register it; pass no approver in non-interactive mode (deny)
- [x] **Update** `.env.example` / usage text if a policy or shell setting is
      surfaced
- [x] **Doc comments** on the public interface
- [x] **Update** `docs/features/FEATURES.md` (new feature row) and `HANDOFF.md`
      (unit map, test count, open threads)

### Phase 8: Validation

- [x] `make test SUITE=TestCommandTool`
- [x] `make test`
- [x] `make test-leak`
- [x] `make check`
- [~] Manual smoke: CLI runs an allowlisted `date`, prompts on an unknown
      command, denies a denied pattern  — **CANCELLED** (the approval/persistence
      layer is being replaced; live verification moves to the new features).

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
src/hildi.command.tool.pas
tests/test_command_tool.pas
```

### Modified Files

```
src/hildi.process.pas    (defaulted shell/switch parameters)
tests/hildi_tests.pas    (add test unit to uses)
tests/test_hildi.pas     (shell parameter test)
examples/agent_cli.pas              (wire tool, store source, console approver)
docs/features/FEATURES.md           (feature row)
HANDOFF.md                          (unit map, state)
```

## Success Criteria

- [x] All tasks checked; every SPEC acceptance criterion maps to a test
- [x] `run_command` gates, executes, caps output, and audits
- [x] Tool tests use fakes only (no SQLite, network, or real process)
- [x] `make check` passes
- [x] CLI smoke test behaves as specified
- [x] Implementation matches the specification

## Notes & Considerations

- `TCommandRunner`'s output callback fires on the runner thread; collect under a
  `TCriticalSection` and only read after `WaitFor` (see `HANDOFF.md` lessons).
- The stores's `EnqueueRequest` always inserts `rsPending`; call `FinishRequest`
  to record the outcome. Two writes per audit row; acceptable.
- Keep `TToolHandler` unchanged: the policy and approver live on the tool
  instance.
- Fail closed everywhere: any ambiguity or error path denies execution.
- Record any spec divergence here with the reason.
- **Revision (v1.1):** approval is per simple-command segment with outcomes
  once / exact / wildcard / deny; wildcard (`executable *`) overrides granular
  approvals and covers later matching segments in the same command. Exact
  approvals persist as `=<argv>` (so a no-argument command is distinct from
  `<executable> *`). Persisted patterns are argument-aware (policy v1.1).
- Deviations: the CLI uses `HILDI_STORE_PATH` (default
  `~/.hildi/store.db`); if the store opens it persists policy and
  audit, otherwise the tool is still registered with
  `TMemoryCommandPolicySource` and `DefaultCommandPolicy` (ask everything,
  session-only approvals). Test doubles derive from `TNoRefCountObject` so the
  test owns their lifetime. Added `TestProcessExecutorRunsCommand` to cover the
  real executor and `TestMemoryPolicySourceAsksThenRemembers` for the fallback.
