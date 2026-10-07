# Subagents — Core v1 — Implementation Plan

Reference: `Subagents_v1.SPEC.md`. TDD-first: each task begins with a failing
test, then the minimum to pass. `make check` before moving on. Files under
`src/` are `hildegard.helper.*`; tests are `tests/test_<unit>.pas` and must be
registered in `tests/hildegard_helper_tests.pas` (integrator-owned).

## Phase 1 — Lineage in the store

- [ ] **Test** (`tests/test_store.pas`): `TestChildSessionLineage` (create a
      root, a child, assert parent/depth/label), `TestChildrenOf`,
      `TestLineageRootDefaults`, `TestMigrationV3IsAdditive` (a v2 database opens
      and keeps its history).
- [ ] **Implement**: migration v3 (`parent_session_id`, `depth`, `label`,
      `idx_sessions_parent`, `messages.ref_session_id`); `CreateChildSession`,
      `SessionLineage`, `ChildrenOf`; extend `TSessionSummary`; extend
      `QueryMessages`/`AppendMessage` for `ref_session_id`; `StoreSchemaVersion`.
  - Files: `src/hildegard.helper.store.pas`, `src/hildegard.helper.session.pas`.
- [ ] **Check**: `make test SUITE=TStoreTest`.

## Phase 2 — Ambient record and wrapper

- [ ] **Test** (`tests/test_session.pas`): `TestAppendAmbientRoundTrip` (kind,
      ref session, elapsed survive), `TestComposeWrapsAmbientAsUser`
      (`<ambient timestamp=... session=...>` + instructions, role user),
      `TestAmbientElapsed`.
- [ ] **Implement**: `mrAmbient`; `IConversationStore.AppendAmbient`; the ambient
      wrapper (a pure function in a new `hildegard.helper.ambient` unit) and its
      use in `TSqliteConversationStore.Compose`; in-memory store degradation
      (append as a plain user message).
  - Files: `src/hildegard.helper.session.pas`,
    `src/hildegard.helper.session.store.pas`, `src/hildegard.helper.ambient.pas`
    (new), `src/hildegard.helper.agent.pas`.
- [ ] **Check**: `make test SUITE=TSessionStoreTest`.

## Phase 3 — Prompt queue kinds and the ambient turn

- [ ] **Test** (`tests/test_agent.pas`): `TestQueuedAmbientDrainsAsAmbient`
      (a `pkAmbient` prompt appends an ambient record, not a user message),
      `TestSendAmbientStartsWithoutUserMessage`, `TestAmbientQueuedMidTurn`.
- [ ] **Implement**: `TPromptKind`; `TPromptQueue.PushAmbient`; `DrainQueued`
      branching; `OnAmbient` in `TAgentEvents`; `TAgentLoop.SendAmbient`;
      `TTurnWorker.CreateAmbient`.
  - Files: `src/hildegard.helper.agent.pas`,
    `src/hildegard.helper.harness.turn.pas`,
    `src/hildegard.helper.harness.turn.worker.pas`.
- [ ] **Check**: `make test SUITE=TAgentLoopTest`.

## Phase 4 — Delegation tools

- [ ] **Test** (`tests/test_subagent.pas`): `TestDelegateTaskSpec`,
      `TestDelegateTaskRequiresReason`, `TestDelegateTaskReturnsSessionAndCapacity`,
      `TestMessageAbortReleaseSpecs`, `TestUnknownChildIdErrors`,
      `TestApprovalAskShape` (`subagent:<verb>` refs, default ask).
- [ ] **Implement**: `hildegard.helper.subagent` — `ISubagentService`,
      `TSubagentSpawnResult`, the four `IApprovableTool`s, and a
      `RegisterSubagentTools(ATools, AService, AApproval)` helper.
  - Files: `src/hildegard.helper.subagent.pas` (new).
- [ ] **Check**: `make test SUITE=TSubagentToolTest`.

## Phase 5 — Supervisor

- [ ] **Test** (`tests/test_subagent_supervisor.pas`): with a scripted stub
      runtime binary over a real socket — `TestSpawnCreatesChildAndPrompts`,
      `TestCapacityCapFailsCleanly`, `TestDepthCapFailsCleanly`,
      `TestResultCapturedFromChild`, `TestAbortReleasesSlot`,
      `TestReleaseDetachesWithoutAbort`, `TestChildApprovalRelayed`,
      `TestAutoDenyWhenHeadless`, `TestTerminateAllOnShutdown`.
- [ ] **Implement**: `hildegard.helper.subagent.supervisor` —
      `TSubagentSupervisor`, the roster, the per-child client, the event queue
      (`Poll`), `Delegate/Message/Abort/Release/Status`, `AnswerChildAsk`,
      `TerminateAll`, auto-deny deadlines, `HasClient`.
  - Files: `src/hildegard.helper.subagent.supervisor.pas` (new).
- [ ] **Check**: `make test SUITE=TSubagentSupervisorTest` and `make test-leak`.

## Phase 6 — Approvals: lineage-wide scope

- [ ] **Test** (`tests/test_approval.pas`): `TestChildResolvesAgainstRootScope`
      (a grant under the root allows the child), `TestGrantForOneChildAppliesToSibling`.
- [ ] **Implement**: `THarnessSessionConfig.ApprovalRootSessionId`; the approval
      context `SessionId` set to the root; thread it through
      `THarnessSession`/`TSessionView`.
  - Files: `src/hildegard.helper.harness.session.pas`,
    `src/hildegard.helper.harness.view.pas`,
    `src/hildegard.helper.approval.pas` (if a helper is needed).
- [ ] **Check**: `make test SUITE=TApprovalTest`.

## Phase 7 — Protocol additions

- [ ] **Test** (`tests/test_session_protocol.pas`): `TestRoundTripAmbient`,
      `TestRoundTripSubagent`, `TestRoundTripSubagentAsk`,
      `TestRoundTripAbortReleaseCommands`.
- [ ] **Implement**: append `ekAmbient`, `ekSubagent`, `ekSubagentAsk`;
      `scAbortSubagent`, `scReleaseSubagent`; the new `TSessionEvent`/
      `TSessionCommand` fields; wire names.
  - Files: `src/hildegard.helper.session.protocol.pas`.
- [ ] **Check**: `make test SUITE=TSessionProtocolTest`.

## Phase 8 — Runtime integration

- [ ] **Test** (`tests/test_session_runtime.pas`): `TestRuntimeSpawnsChildOnDelegate`,
      `TestChildResultBecomesAmbientTurn`, `TestChildAskRelayedToParent`,
      `TestAbortSubagentCommand`, `TestReleaseSubagentCommand`,
      `TestNoDelegationToolsAtDepthCap`.
- [ ] **Implement**: create/destroy the supervisor in `Open`/`Destroy`; register
      the delegation tools when depth < max; `DrainSubagents` in the select loop;
      handle `scAbortSubagent`/`scReleaseSubagent`; route `scApprove` for child
      asks; maintain `HasClient`.
  - Files: `src/hildegard.helper.session.runtime.pas`.
- [ ] **Check**: `make test SUITE=TSessionRuntimeTest`.

## Phase 9 — Configuration and CLI

- [ ] **Test** (`tests/test_cli.pas` or config test):
      `TestSubagentConfigDefaults` (`HILDEGARD_SUBAGENT_MAX` = 10,
      `HILDEGARD_SUBAGENT_DEPTH` = 1, `HILDEGARD_SUBAGENT_AUTO_DENY_MS` = 60000).
- [ ] **Implement**: resolve the three env knobs (a small helper reused by the
      runtime and the CLI); the runtime reads them in `Open`.
  - Files: `src/hildegard.helper.subagent.pas` (resolver),
    `src/hildegard.helper.session.runtime.pas`.
- [ ] **Check**: `make test SUITE=TSubagentToolTest`.

## Phase 10 — Verification

- [ ] All tasks above checked.
- [ ] `make check` passes (whole suite + leak gate), including child-process
      teardown.
- [ ] Every acceptance criterion in `FEATURE.md` (lineage, tools, ambient,
      approvals, lifecycle, cost) maps to a named test.
- [ ] Update the SPEC if behaviour diverged; bump the version for a major
      revision.
- [ ] Rename this TODO to `Subagents_v1.DONE.md`.
- [ ] Hand the integrator the `FEATURES.md` + `HANDOFF.md` lines.
