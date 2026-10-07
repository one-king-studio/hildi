# Subagent Sidebar — v1 — Implementation Plan

Reference: `Subagent_Sidebar_v1.SPEC.md`. Depends on the core
(`Subagents_v1.SPEC.md`) protocol additions. TDD-first; `make check` before
moving on. Register new tests in `tests/hildegard_helper_tests.pas`
(integrator-owned).

## Phase 1 — Roster model

- [x] **Test** (`tests/test_subagent_sidebar.pas`): `TestApplyMapsStatuses`,
      `TestApplyUpdatesInPlace`, `TestTerminalEntriesPersist`,
      `TestRosterFind`, `TestPruneDropsOldTerminalOnly`.
- [x] **Implement**: `hildegard.helper.harness.subagent` — `TSubagentStatus`,
      `TSubagentEntry`, `TSubagentRoster` (`Apply`, `Entries`, `Count`, `Find`,
      `Prune`).
  - Files: `src/hildegard.helper.harness.subagent.pas` (new).
- [x] **Check**: `make test SUITE=TSubagentRosterTest`.

## Phase 2 — Sidebar widget

- [ ] **Test** (`tests/test_tui_sidebar.pas`): `TestSidebarRendersRows`,
      `TestSidebarSelectionMoves`, `TestSidebarEnterFiresSelect`,
      `TestSidebarEmptyState` — all over `TSurfaceMemory`.
- [ ] **Implement**: `hildegard.helper.tui.sidebar` — `TSidebar`
      (`Measure`/`Arrange`/`Render`/`HandleEvent`/`Refresh`, `OnSelect`).
  - Files: `src/hildegard.helper.tui.sidebar.pas` (new).
- [ ] **Check**: `make test SUITE=TSidebarTest`.

## Phase 3 — Spy binding

- [ ] **Test** (`tests/test_subagent_spy.pas`): `TestSpyMapsChildStream`
      (a scripted child stream maps to the chat panel's `TTurnEvent`s),
      `TestSpyDetach`, `TestSpyNeverDrives`.
- [ ] **Implement**: `hildegard.helper.harness.subagent.spy` — `TSubagentSpy`
      (`Open`, `PopEvent`, `SessionId`, `Close`) over `TSessionClient`
      (`srObserve`, `Spawn = False`).
  - Files: `src/hildegard.helper.harness.subagent.spy.pas` (new).
- [ ] **Check**: `make test SUITE=TSubagentSpyTest`.

## Phase 4 — App integration (sidebar + spy + actions)

- [ ] **Test** (`tests/test_harness_app.pas`): `TestSidebarTogglesAndSpies`
      (selecting a child swaps the stream source), `TestSpyHidesCompose`,
      `TestSpyAbortSendsParentCommand`, `TestSpyReleaseSendsParentCommand`,
      `TestLeaveSpyRestoresParent`, `TestSubagentAskOpensModalWithLabel`.
- [ ] **Implement**: `THarnessApp` view mode (`vmParent`/`vmSpy`); the sidebar
      plane; the spy drain in `Step`; the actions bar (`TSpyActions`) replacing
      the compose; routing `ekSubagent`/`ekSubagentAsk`/`ekAmbient`; the toggle
      keybinding; esc-to-leave.
  - Files: `src/hildegard.helper.harness.app.pas`,
    `src/hildegard.helper.tui.chatpanel.pas` (compose toggle/actions bar),
    `src/hildegard.helper.tui.sidebar.pas`.
- [ ] **Check**: `make test SUITE=THarnessAppTest`.

## Phase 5 — Ambient rendering

- [ ] **Test** (`tests/test_tui_chat.pas`): `TestAmbientBlockRenders`
      (a dimmed ambient marker with the child label and elapsed, never the
      instruction text).
- [ ] **Implement**: the ambient custom renderer in the chat stream (a distinct
      block style); the `OnAmbient` event wiring in the app.
  - Files: `src/hildegard.helper.tui.chat.pas`,
    `src/hildegard.helper.harness.app.pas`.
- [ ] **Check**: `make test SUITE=TChatStreamTest`.

## Phase 6 — Verification

- [ ] All tasks above checked.
- [ ] `make check` passes (whole suite + leak gate).
- [ ] Every acceptance criterion in the sidebar section of `FEATURE.md` maps to
      a named test.
- [ ] Update the SPEC if behaviour diverged.
- [ ] Rename this TODO to `Subagent_Sidebar_v1.DONE.md`.
- [ ] Hand the integrator the `FEATURES.md` + `HANDOFF.md` lines.
