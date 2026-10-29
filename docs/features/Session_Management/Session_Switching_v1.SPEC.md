# Component Specification: Session Switching v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildi.tui.sessionsmodal` (the `/sessions` modal),
`hildi.harness.app` (`THarnessApp`, the connect lifecycle, the
windowed transcript), `hildi.harness.view` (`TSessionView`,
`Open`/`EnsureSession`), `hildi.harness.driver` (`ISessionDriver`,
`RemoteDriver`), `hildi.session` (`TSessionRow`).

**Depended on by:** nothing (the composition root wires it).

## Purpose

Close the deliberate v1 gap: **activating a row in `/sessions` opens that
session**. Session Modal v1 was management-only (Decision 5) because opening a
session needs the driver seam — the TUI bound one session at startup and had no
re-attach. TUI Startup has since supplied that seam (`Attach`/`EnsureSession`,
the lazy session, the bounded window), so switching is now a small increment:
the modal raises an *activate* event, and the app swaps the active
session+driver and rebuilds the window for it.

## Prior art and reuse

| Need | Existing unit | What changes |
| --- | --- | --- |
| Open a named session's view | `TSessionView.Open` (named id path) | none — reuse |
| Connect/spawn a runtime for it | `RemoteDriver` (`Spawn := True`) | none — reuse |
| Swap the active session + rebuild | `THarnessApp.Attach` (the connect lifecycle) | factor the window rebuild; add `SwitchSession` |
| Reject an action cleanly | `AppendError` / `ConnState` guards | none — reuse |
| The row the operator picked | `TSessionsModal.SelectedSessionId` | add an activate event on Enter |

No new dependency; no new store method; no new migration. The switching
increment is a modal key, an app callback, and a composition-root method.

## Requirements

### Functional

- [ ] **Enter activates the selected row**: the modal raises `OnActivate` with the
      selected session id; Escape still closes (Enter is no longer inert).
- [ ] The modal's footer advertises the binding (`enter open`), dimmed like the
      others.
- [ ] Activating the **current** session is a no-op beyond closing the modal.
- [ ] On activation the app asks its `OnSwitchSession` callback to open the
      target; on success it swaps the active `TSessionView` and `ISessionDriver`,
      closes the previous driver, and **rebuilds the window** for the new session
      (a fresh tail: no older pages, not at head, no stale live blocks).
- [ ] The transcript, header, status bar, and stats reflect the new session.
- [ ] A **failure** to open the target (spawn timeout, unknown id, no callback)
      is an in-app error line; the current session and transcript are unchanged.
- [ ] Switching is **allowed while a turn is in flight**: closing the old driver
      **detaches** from its runtime, which keeps the turn running and persists it
      (the work is not lost, only the live view), and the new session starts
      fresh. `CancelTurn` clears the busy state, since the old turn is no longer
      ours to show.
- [ ] A switch does **not** create a session row for the session being left (the
      lazy path must not persist an empty session).

### Non-Functional

- [ ] No leaks: the callback's view and driver are owned by the caller; the app
      holds only references. `make check` green, leak-clean.
- [ ] macOS + Linux, `{$mode delphi}`, FPC 3.3.1.
- [ ] The Process Split holds: the app links no agent/runtime unit; the
      composition root (which may) supplies the callback.

## Contracts & Interfaces

> Pascal type declarations; bodies are the implementer's.

### The modal (an activate event)

```pascal
unit hildi.tui.sessionsmodal;

type
  { Fired when the operator activates a row (Enter): open that session. Separate
    from the management actions (pin/rename/archive) so the host can swap the
    whole session rather than write a row. }
  TSessionActivateEvent = procedure(const ASessionId: string) of object;

  TSessionsModal = class(TWidget)
  public
    { Enter on the selected row. Not fired for an empty list. }
    property OnActivate: TSessionActivateEvent read FOnActivate write FOnActivate;
  end;
```

### The app (the switch seam)

```pascal
unit hildi.harness.app;

type
  { Opens a different session for the app: returns its view and driver, or False
    + AError. The callback retains ownership of both (the app holds references
    only). Wired by the composition root, which can spawn a runtime. }
  TSwitchSessionEvent = function(const ASessionId: string;
    out ASession: TSessionView; out ADriver: ISessionDriver;
    out AError: string): Boolean of object;

  THarnessApp = class
  public
    { The composition root's open-a-session hook. Unset => switching is refused
      with a status line (the widget is still usable). }
    property OnSwitchSession: TSwitchSessionEvent read FOnSwitchSession
      write FOnSwitchSession;
    { The active session's id, '' when there is none (an idle lazy app). }
    property SessionId: string read GetSessionId;
    { Activate another session: refuse if busy or the callback fails; else swap
      and rebuild the window. Public so it is testable and reusable. }
    procedure SwitchSession(const ASessionId: string);
  end;
```

### Data flow

1. **Activate** — Enter in the modal raises `OnActivate(id)`.
2. **Guard** — `SwitchSession` refuses an empty id, the current id (no-op), or a
   missing callback. A live turn does **not** block: the switch detaches.
3. **Open** — `OnSwitchSession(id, ...)` opens the target view and driver.
4. **Swap** — close the old driver, adopt the new view+driver, set
   `csConnected`, reset the window, rebuild the transcript, refresh
   header/stats/status, close the modal.
5. **Failure** — an error line; nothing is swapped.

## Validation and error handling

- Empty id or the current id: a no-op (the modal just closes).
- A live turn: not an error — the switch detaches (the old runtime keeps the
  turn; the new session is fresh).
- No callback: `this build cannot switch sessions`.
- Callback `False`: `could not open session: <AError>`.
- All are status lines, never exceptions; the app stays usable on the old
  session.

## Testing strategy

### Unit tests

- [ ] **Modal**: Enter raises `OnActivate` with the selected id; Enter on an empty
      list does not fire; Escape still closes.
- [ ] **App**: activating another session swaps the transcript to that session's
      history and updates `SessionId`.
- [ ] **App**: activating the current session does not switch.
- [ ] **App**: a switch during a live turn detaches (the new session is shown,
      busy cleared) rather than refusing.
- [ ] **App**: a callback returning `False` leaves the current session and shows
      the error.
- [ ] **App**: a switch with no callback is refused with a status line.

### Integration tests

- [ ] A store seeded with two sessions: open `/sessions`, activate the other,
      assert the new transcript and header.

## Performance targets

- One `TSessionView.Open` + one driver connect per switch (the same cost as a
  launch). No per-keystroke work; the modal is unchanged otherwise.

## Security considerations

- The target id comes from the workspace's own session list (the modal is
  workspace-scoped), so it is not an arbitrary path. `TSessionView.Open` still
  validates `SessionExists`.

## Success criteria

- [ ] All contracts implemented; all tests passing (`make check`).
- [ ] No leaks; the Process Split test still passes.
- [ ] The modal opens another session; the window/transcript/header all follow.

## Out of scope (documented, not built)

- **Returning to the previous session** (a back-stack) — activate it again.
- **Cross-workspace switching** — the modal is workspace-scoped.
- **Keeping both runtimes warm** — a switch connects the target on demand.
- **Attaching the new driver to the old session's still-running turn** — the
  switch detaches (the old turn keeps running and is persisted), but the new
  session does not resume rendering the detached turn live.

## Future considerations

- Switch while busy by handing the in-flight turn to the runtime (detach) and
  resyncing on return.
- A `/switch <id>` command as an alternative entry point.
- Remembering the last-N visited sessions in the modal's ordering.
