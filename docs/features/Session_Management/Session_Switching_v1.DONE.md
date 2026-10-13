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

- [x] **Add** `TSessionActivateEvent` and the `OnActivate` property.
- [x] **Test**: Enter raises `OnActivate` with the selected id; Enter on an empty
      list does not fire (`test_tui_sessionsmodal`).
- [x] **Implement**: route `kkEnter` (non-renaming) to `OnActivate`.
- [x] **Test**: the footer advertises `enter open`.
- [x] **Implement**: add the footer hint.

### Phase 2: The app's switch (`hildegard.helper.harness.app`)

- [x] **Add** `TSwitchSessionEvent`, the `OnSwitchSession` property, the
      `SessionId` read, and `SwitchSession`.
- [x] **Test**: activating another session swaps the transcript and `SessionId`
      (`test_harness_app`).
- [x] **Implement**: the swap + window rebuild (factor `Attach`'s rebuild).
- [x] **Test**: the current session is a no-op; a busy app is refused; a failing
      callback keeps the old session and shows the error; no callback is refused.
- [x] **Implement**: the guards and the error lines.
- [x] **Wire**: `OnActivate` in `ShowSessions` to `SwitchSession`.

### Phase 3: The composition root (`examples/tui_agent.pas`)

- [x] **Implement**: `TLauncher.Switch` (open the target view + `RemoteDriver`),
      keeping opened views alive to shutdown; wire `App.OnSwitchSession`.
- [x] **Free**: the launcher's opened views at shutdown (leak-clean); free the
      app before the launcher.

### Phase 4: Validation & docs

- [x] **Run**: `make test SUITE=TSessionsModalTest,THarnessAppTest`
- [x] **Run**: `make check` (all gates) — 1300 tests, 0 failures, leak-clean
- [x] **Update the SPEC** if behaviour diverged; rename this TODO to
      `Session_Switching_v1.DONE.md`.
- [x] **Update** `FEATURE.md` (Decision 5 -> opened; activation is now in scope).

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

- [x] All tasks checked
- [x] Every SPEC acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] Activating a row opens that session; the transcript/header/window follow
- [x] A failed or refused switch leaves the current session intact

## Notes & Considerations

- **Activation is not a row action.** It gets its own event (`OnActivate`), not a
  `TSessionAction`: the host swaps a session rather than writing a store row.
- **Refuse while busy.** The in-flight turn belongs to the old driver; live
  detach is a separate increment (SPEC Out of Scope).
- **The callback owns the view and driver.** The app holds references; the
  launcher keeps its opened views alive to shutdown so nothing dangles.
- Record deviations from the SPEC here.

## Outcome

Implemented on `main` (`c7921a9`, `4ce8334`, `23e6163`): the modal's Enter key,
the app's `SwitchSession` swap, and the composition root's `TLauncher.Switch`.
`make check` green (1300 tests, leak-clean); the example compiles.

**Deviations from the SPEC, with reasons:**

- **The modal pop is deferred by one `Step`.** `OnActivate` fires from inside the
  modal's own `HandleEvent`, so popping the plane there would free the widget
  mid-dispatch. `SwitchSession` swaps the session inline but sets `FCloseSessions`;
  `SyncSessionsModal` (called at the top of `Step`/`OnLoop`, beside `CloseModal`)
  performs the pop. The SPEC's "close the modal" is therefore "close it on the
  next frame", which is invisible to the operator.
- **`SyncSessionsModal` also fixes a latent dangling pointer.** An unhandled
  Escape pops the sessions plane inside `TTuiApp.DispatchEvent` (the modal
  returns False for it), leaving `FSessionsModal`/`FSessionsShown` stale — a
  subsequent `/sessions` or action would touch a freed widget. The reconcile
  clears the app's state whenever the plane is gone, whatever popped it.
- **`THarnessApp.SessionId` added** (not in the SPEC's contract block) so the
  active session is observable for the header, tests, and future commands.
