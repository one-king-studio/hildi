# Subagents — Core v1 — Implementation Plan

Reference: `Subagents_v1.SPEC.md`. TDD-first: each task begins with a failing
test, then the minimum to pass. `make check` before moving on. Files under
`src/` are `hildegard.helper.*`; tests are `tests/test_<unit>.pas` and must be
registered in `tests/hildegard_helper_tests.pas` (integrator-owned).

## Phase 1 — Lineage in the store

- [x] **Test** (`tests/test_store.pas`): `TestChildSessionLineage` (create a
      root, a child, assert parent/depth/label), `TestChildrenOf`,
      `TestLineageRootDefaults`, `TestMigrationV3IsAdditive` (a v2 database opens
      and keeps its history).
- [x] **Implement**: migration v4 (`parent_session_id`, `depth`, `label`,
      `idx_sessions_parent`, `messages.ref_session_id`); `CreateChildSession`,
      `SessionLineage`, `ChildrenOf`; extend `TSessionSummary`; extend
      `QueryMessages`/`AppendMessage` for `ref_session_id`; `StoreSchemaVersion`.
  - Files: `src/hildegard.helper.store.pas`, `src/hildegard.helper.session.pas`.
- [x] **Check**: `make test SUITE=TStoreTest`.

## Phase 2 — Ambient record and wrapper

- [x] **Test** (`tests/test_session.pas`): `TestAppendAmbientRoundTrip` (kind,
      ref session, elapsed survive), `TestComposeWrapsAmbientAsUser`
      (`<ambient timestamp=... session=...>` + instructions, role user),
      `TestFormatAmbientEscapes`.
- [x] **Implement**: `mrAmbient`; `IConversationStore.AppendAmbient`; the ambient
      wrapper (a pure function in a new `hildegard.helper.ambient` unit) and its
      use in `TSqliteConversationStore.Compose`; in-memory store degradation
      (append as a plain user message).
  - Files: `src/hildegard.helper.session.pas`,
    `src/hildegard.helper.session.store.pas`, `src/hildegard.helper.ambient.pas`
    (new), `src/hildegard.helper.agent.pas`.
- [x] **Check**: `make test SUITE=TSessionTest`.

## Phase 3 — Prompt queue kinds and the ambient turn

- [x] **Test** (`tests/test_agent.pas`): `TestQueuedAmbientDrainsAsAmbient`
      (a `pkAmbient` prompt appends an ambient record, not a user message),
      `TestSendAmbientStartsWithoutUserMessage`, `TestSendAmbientDrainsQueuedAmbient`.
- [x] **Implement**: `TPromptKind`; `TPromptQueue.PushAmbient`; `DrainQueued`
      branching; `OnAmbient` in `TAgentEvents`; `TAgentLoop.SendAmbient`;
      `TTurnWorker.CreateAmbient`.
  - Files: `src/hildegard.helper.agent.pas`,
    `src/hildegard.helper.harness.turn.pas`,
    `src/hildegard.helper.harness.turn.worker.pas`.
- [x] **Check**: `make test SUITE=TAgentLoopTest`.

## Phase 4 — Delegation tools

- [x] **Test** (`tests/test_subagent.pas`): `TestDelegateTaskSpec`,
      `TestDelegateTaskRequiresReason`, `TestDelegateTaskReturnsSessionAndCapacity`,
      `TestMessageAbortReleaseSpecs`, `TestUnknownChildIdErrors`,
      `TestApprovalAskShape` (`subagent:<verb>` refs, default ask).
- [x] **Implement**: `hildegard.helper.subagent` — `ISubagentService`,
      `TSubagentSpawnResult`, the four `IApprovableTool`s, and a
      `RegisterSubagentTools(ATools, AService, AApproval)` helper.
  - Files: `src/hildegard.helper.subagent.pas` (new).
- [x] **Check**: `make test SUITE=TSubagentToolTest`.

## Phase 5 — Supervisor

- [x] **Test** (`tests/test_subagent_supervisor.pas`): with an in-process child
      runtime over a real socket (an injectable client factory) —
      `TestDelegateSpawnsChildWithLineage`, `TestDelegateReturnsSessionAndCapacity`,
      `TestCapacityCapFailsCleanly`, `TestDepthCapFailsCleanly`,
      `TestResultCapturedFromChild`, `TestAbortReleasesSlot`,
      `TestReleaseDetachesWithoutAbort`, `TestUnknownChildIdErrors`,
      `TestTerminateAllOnShutdown`.
      *(Deferred to a later phase: `TestChildApprovalRelayed` and
      `TestAutoDenyWhenHeadless` — they need a scripted approval-producing child.
      The relay/auto-deny code paths are implemented; only their tests are
      pending.)*
- [x] **Implement**: `hildegard.helper.subagent.supervisor` —
      `TSubagentSupervisor`, the per-child client, the event queue
      (`Poll`), `Delegate/Message/Abort/Release/Status`, `AnswerChildAsk`,
      `TerminateAll`, auto-deny deadlines (`TickAutoDeny`), `HasClient`.
      Children are freed via a deferred graveyard (`ReapPending`) so a client is
      never closed from its own reader thread.
  - Files: `src/hildegard.helper.subagent.supervisor.pas` (new);
    `src/hildegard.helper.session.client.pas` (`ReaderDone`).
- [x] **Check**: `make test SUITE=TSubagentSupervisorTest` and `make test-leak`.

## Phase 6 — Approvals: lineage-wide scope

- [x] **Test** (`tests/test_approval.pas`): `TestChildResolvesAgainstRootScope`
      (a grant under the root allows the child), `TestGrantForOneChildAppliesToSibling`.
- [x] **Implement**: `THarnessSessionConfig.ApprovalRootSessionId`; the approval
      context `SessionId` set to the root; thread it through
      `THarnessSession`/`TSessionView`/`TSessionRuntimeConfig`/
      `TSessionClientConfig` and the runtime `--approval-root` arg; the
      supervisor sets a child's root to its parent.
  - Files: `src/hildegard.helper.harness.session.pas`,
    `src/hildegard.helper.harness.view.pas`,
    `src/hildegard.helper.session.runtime.pas`,
    `src/hildegard.helper.session.client.pas`,
    `src/hildegard.helper.subagent.supervisor.pas`.
- [x] **Check**: `make test SUITE=TApprovalTest`.

## Phase 7 — Protocol additions

- [x] **Test** (`tests/test_session_protocol.pas`): `TestRoundTripAmbient`,
      `TestRoundTripSubagent`, `TestRoundTripSubagentAsk`,
      `TestRoundTripAbortReleaseCommands`; `FillEvent` covers the new kinds.
- [x] **Implement**: append `ekAmbient`, `ekSubagent`, `ekSubagentAsk`;
      `scAbortSubagent`, `scReleaseSubagent`; the new `TSessionEvent`/
      `TSessionCommand` fields; wire names; encode/decode. The runtime accepts
      the new commands as a no-op reply until Phase 8 routes them.
  - Files: `src/hildegard.helper.session.protocol.pas`,
    `src/hildegard.helper.session.runtime.pas`.
- [x] **Check**: `make test SUITE=TSessionProtocolTest`.

## Phase 8 — Runtime integration

- [x] **Test** (`tests/test_session_runtime.pas`):
      `TestAbortReleaseCommandsRouteToSupervisor` (the abort/release commands are
      routed to the supervisor and fail cleanly on an unknown child),
      `TestAbortRefusedForObserver` (drive-only).
      *(Deferred: `TestRuntimeSpawnsChildOnDelegate` and
      `TestChildResultBecomesAmbientTurn` — a full parent→child turn is not
      hermetic because the spawned child builds its own LLM transport. The
      spawn/result/relay paths are covered by `TSubagentSupervisorTest`, which
      runs a child in-process with an injected transport.)*
- [x] **Implement**: create/destroy the supervisor in `Open`/`Destroy` (with an
      owning interface ref, since the tools hold a second ref); register the
      delegation tools when `CanDelegate`; `DrainSubagents` in the select loop
      (roster/ambient/ask relay, ambient turn start, auto-deny); handle
      `scAbortSubagent`/`scReleaseSubagent`; route `scApprove` for a namespaced
      child ask; maintain `HasClient`; `TerminateAll` on every exit reason.
  - Files: `src/hildegard.helper.session.runtime.pas`,
    `src/hildegard.helper.harness.session.pas` (ApprovalService accessor),
    `src/hildegard.helper.subagent.supervisor.pas` (CanDelegate,
    ParentApprovalRoot).
- [x] **Check**: `make test SUITE=TSessionRuntimeTest`.

## Phase 9 — Configuration and CLI

- [x] **Test** (`tests/test_subagent.pas`): `TestSubagentConfigDefaults`
      (`HILDEGARD_SUBAGENT_MAX` = 10, `_DEPTH` = 1, `_AUTO_DENY_MS` = 60000),
      `TestSubagentConfigOverridesAndBounds`.
- [x] **Implement**: pure resolvers `ResolveSubagentMax`/`_Depth`/`_AutoDenyMs`
      in `hildegard.helper.subagent` (raw value in, default/bounds applied); the
      runtime reads the env vars and delegates to them.
  - Files: `src/hildegard.helper.subagent.pas`,
    `src/hildegard.helper.session.runtime.pas`.
- [x] **Check**: `make test SUITE=TSubagentToolTest`.

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
