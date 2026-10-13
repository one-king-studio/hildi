# Implementation Plan: Session Switching v1

**Related Specification:** `Session_Switching_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Close Session Modal v1's deferred activation: Enter opens the selected session.
The modal raises `OnActivate`; the app swaps the active view+driver and rebuilds
the window; the composition root opens the target (view + `RemoteDriver`).
TDD-first; `make check` before moving on. `main` only.

> **Prerequisite:** TUI Startup (`Attach`/`EnsureSession`, the bounded window)
> and Session Modal v1 — both done.

## Implementation Tasks

### Phase 1: The modal's activate key (`hildegard.helper.tui.sessionsmodal`)

- [ ] **Add** `TSessionActivateEvent` and the `OnActivate` property.
- [ ] **Test**: Enter raises `OnActivate` with the selected id; Enter on an empty
      list does not fire (`test_tui_sessionsmodal`).
- [ ] **Implement**: route `kkEnter` (non-renaming) to `OnActivate`.
- [ ] **Test**: the footer advertises `enter open`.
- [ ] **Implement**: add the footer hint.

### Phase 2: The app's switch (`hildegard.helper.harness.app`)

- [ ] **Add** `TSwitchSessionEvent`, the `OnSwitchSession` property, the
      `SessionId` read, and `SwitchSession`.
- [ ] **Test**: activating another session swaps the transcript and `SessionId`
      (`test_harness_app`).
- [ ] **Implement**: the swap + window rebuild (factor `Attach`'s rebuild).
- [ ] **Test**: the current session is a no-op; a busy app is refused; a failing
      callback keeps the old session and shows the error; no callback is refused.
- [ ] **Implement**: the guards and the error lines.
- [ ] **Wire**: `OnActivate` in `ShowSessions` to `SwitchSession`.

### Phase 3: The composition root (`examples/tui_agent.pas`)

- [ ] **Implement**: `TLauncher.Switch` (open the target view + `RemoteDriver`),
      keeping opened views alive to shutdown; wire `App.OnSwitchSession`.
- [ ] **Free**: the launcher's opened views at shutdown (leak-clean); free the
      app before the launcher.

### Phase 4: Validation & docs

- [ ] **Run**: `make test SUITE=TSessionsModalTest,THarnessAppTest`
- [ ] **Run**: `make check` (all gates)
- [ ] **Update the SPEC** if behaviour diverged; rename this TODO to
      `Session_Switching_v1.DONE.md`.
- [ ] **Update** `FEATURE.md` (Decision 5 -> opened; activation is now in scope).

## Files to Create/Modify

### New Files

```
docs/features/Session_Management/Session_Switching_v1.SPEC.md
docs/features/Session_Management/Session_Switching_v1.TODO.md
```

### Modified Files

```
src/hildegard.helper.tui.sessionsmodal.pas   (OnActivate, Enter, footer hint)
src/hildegard.helper.harness.app.pas          (TSwitchSessionEvent, SwitchSession)
examples/tui_agent.pas                        (TLauncher.Switch + wiring)
tests/test_tui_sessionsmodal.pas              (the activate key)
tests/test_harness_app.pas                    (the switch)
```

## Dependencies & Ordering

### Must Complete Before Starting

- TUI Startup + Session Modal v1 (both done).

### Critical Path

1 (modal key) -> 2 (app swap) -> 3 (composition root) -> 4.

## Success Criteria

- [ ] All tasks checked
- [ ] Every SPEC acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] Activating a row opens that session; the transcript/header/window follow
- [ ] A failed or refused switch leaves the current session intact

## Notes & Considerations

- **Activation is not a row action.** It gets its own event (`OnActivate`), not a
  `TSessionAction`: the host swaps a session rather than writing a store row.
- **Refuse while busy.** The in-flight turn belongs to the old driver; live
  detach is a separate increment (SPEC Out of Scope).
- **The callback owns the view and driver.** The app holds references; the
  launcher keeps its opened views alive to shutdown so nothing dangles.
- Record deviations from the SPEC here.
