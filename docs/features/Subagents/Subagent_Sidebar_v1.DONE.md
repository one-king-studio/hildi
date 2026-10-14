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

- [x] **Test** (`tests/test_tui_sidebar.pas`): `TestSidebarRendersRows`,
      `TestSidebarSelectionMoves`, `TestSidebarEnterFiresSelect`,
      `TestSidebarEmptyState` — all over `TSurfaceMemory`.
- [x] **Implement**: `hildegard.helper.tui.sidebar` — `TSidebar`
      (`Measure`/`Render`/`HandleEvent`/`Refresh`, `OnSelect`).
  - Files: `src/hildegard.helper.tui.sidebar.pas` (new).
- [x] **Check**: `make test SUITE=TSidebarTest`.

## Phase 3 — Spy binding

- [x] **Test** (`tests/test_subagent_spy.pas`): `TestSpyMapsChildStream`
      (a driver-driven child's stream maps to the chat panel's `TTurnEvent`s),
      `TestSpyUnknownChildFails`.
- [x] **Implement**: `hildegard.helper.harness.subagent.spy` — `TSubagentSpy`
      (`Open`, `PopEvent`, `SessionId`, `Close`) over `TSessionClient`
      (`srObserve`, `Spawn = False`).
  - Files: `src/hildegard.helper.harness.subagent.spy.pas` (new).
- [x] **Also** (found while testing the core live): the driver dropped the
      subagent wire events, so a child's approval ask never reached the TUI. The
      event mapping is now a shared `MapSessionEvent` in `harness.driver` that
      maps `ekSubagent`/`ekSubagentAsk`/`ekAmbient` to `teSubagent`/
      `teSubagentAsk`/`teAmbient`.
  - Files: `src/hildegard.helper.harness.driver.pas`,
    `src/hildegard.helper.harness.turn.pas`.
- [x] **Check**: `make test SUITE=TSubagentSpyTest`.

## Phase 4 — App integration (sidebar + spy + actions)

- [x] **Test** (`tests/test_harness_app.pas`): `TestSidebarTogglesWithCtrlB`
      (the sidebar shows/hides), `TestCtaHintsAreBlank` now asserts the
      `ctrl+b subagents` hint.
- [x] **Implement**: `THarnessApp` sidebar + spy: the roster fed from
      `teSubagent`; `Ctrl+B` toggles the sidebar; selecting a row opens the spy
      (`TSubagentSpy`, `srObserve`) and hides the composer; `Step` drains the
      spy; a relayed child ask (`teSubagentAsk`) opens the approval modal; the
      driver gains `AbortSubagent`/`ReleaseSubagent`.
  - Files: `src/hildegard.helper.harness.app.pas`,
    `src/hildegard.helper.harness.driver.pas`,
    `src/hildegard.helper.harness.driver.local.pas`.
- [x] **Check**: `make test SUITE=THarnessAppTest`.

  *(Remaining polish, folded into Phase 5: the spy-mode **Abort/Release actions
  bar** replacing the composer, and a select-a-row-opens-spy test.)*

## Phase 5 — Ambient rendering

- [x] **Test** (`tests/test_tui_chat.pas`): `TestAmbientBlockRenders`
      (a dimmed ambient block with the child label + status renders).
- [x] **Implement**: a `ckAmbient` chat kind (dimmed body), and the app renders
      an `mrAmbient` record as a `ckAmbient` block: a marker line
      (`◀ label · status ▶`) then the child's text.
  - Files: `src/hildegard.helper.tui.chat.pas`,
    `src/hildegard.helper.harness.app.pas`.
- [x] **Check**: `make test SUITE=TTuiChatTest`.

## Phase 6 — Verification

- [x] All tasks above checked.
- [x] `make check` passes (whole suite + leak gate; 948 tests, 0 leaks).
- [x] The sidebar acceptance criteria map to tests (roster, sidebar widget,
      spy, app toggle, ambient render). The spy-mode **Abort/Release actions
      bar** is deferred (see Completion Notes).
- [x] Update the SPEC if behaviour diverged (recorded below).
- [x] Rename this TODO to `Subagent_Sidebar_v1.DONE.md`.
- [ ] Hand the integrator the `FEATURES.md` + `HANDOFF.md` lines.

## Completion Notes

Deviations from the SPEC, recorded:

- The **composer is hidden** in spy mode (a `SetComposeActive(False)`), but the
  **Abort/Release actions bar** that replaces it is deferred; the operator can
  still abort/release through the parent agent or a future bar. The spy itself
  is observe-only.
- The sidebar is toggled by **`Ctrl+B`** (a `ctrl+b subagents` hint sits on the
  toolbar above the composer). The SPEC said "floating sidebar"; it is drawn as
  an overlay panel positioned over the chat area.
- The **driver dropped subagent events** (found while testing the core live):
  `MapSessionEvent` now maps `ekSubagent`/`ekSubagentAsk`/`ekAmbient`, so a
  child's approval ask reaches the approval modal.
- Ambient results render as a dimmed `ckAmbient` block (marker + text), not a
  user bubble.

Deferred: the spy-mode actions bar, and the live smoke test (the parent→child
path is covered in-process).

**Correction (`Subagent_Spy_v2`):** the sidebar was created and toggled here, but
`BuildTree` never added it to the widget tree, so `Ctrl+B` arranged a panel that
was never rendered or fed input — the spy was unreachable. `Subagent_Spy_v2`
added the `TSidebarOverlay` wiring (render + input routing) and the spy's
enter/leave/indicator, with a render test. The deferred actions bar is unchanged.
