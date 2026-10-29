# Component Specification: Subagent Spy v2

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `Subagents_v1` (the supervisor + child runtime), `Subagent_Sidebar_v1`
(the sidebar + the observe-only `TSubagentSpy`), TUI Startup (`Attach`, the bounded
window), Session Switching (`ResetWindow` + the transcript rebuild).

## Purpose

Make the observe-only **subagent spy usable**. `Subagent_Sidebar_v1` shipped the
spy (`TSubagentSpy`, `srObserve`) and the sidebar, but left it a trap:

- **No way out.** `LeaveSpy` is called only from `ShowSpy` (to reset before
  opening); nothing in the input path calls it. Entering a row is one-way.
- **No indicator.** `FSpyId` is tracked but never drawn, so the panel silently
  changes whose session it shows.
- **The child's events append into the parent's transcript** (`DrainSpy` ->
  `HandleTurnEvent` -> `FPanel.Stream`), interleaving with any live parent turn.

This increment makes spying a first-class read-only view: enter it deliberately,
see whose session it is, and leave it.

## Prior art and reuse

| Need | Existing | Change |
| --- | --- | --- |
| Observe a child | `TSubagentSpy` (`srObserve`, `Spawn = False`) | none - reuse |
| Rebuild the transcript | `THarnessApp.ResetWindow` + `RenderHistory` | a session-id-parametrised variant |
| The indicator | the messages-panel header / status line | reuse |
| Leave on Escape | `THarnessApp.HandleEscape` (modal -> interrupt) | add the spy step |
| The child's history | the parent's `TSqliteStore` (session-scoped queries) | read by the child id |

## Requirements

### Functional

- [ ] Selecting a sidebar row enters **spy mode**: the panel is rebuilt to show
      the **child's** transcript - its history (a bounded tail from the store),
      then its live stream.
- [ ] A visible **indicator** shows the spy: the messages-panel header reads
      `spying · <label or short id>` (label from the roster entry when known,
      else the id prefix).
- [ ] **Escape leaves spy mode**, restoring the parent's transcript and the
      composer, and re-showing the sidebar if it was shown. Escape priority: the
      `/sessions` modal, then the spy, then the turn interrupt.
- [ ] While spying, the **parent's** driver events are **consumed but not drawn**
      (its turn keeps running in its runtime and is persisted; only the busy
      state is updated), so the two streams never interleave.
- [ ] The spy is **observe-only**: it never drives the child; the child keeps
      running on leave.
- [ ] A spy that cannot attach (unknown or dead child) shows an error line and
      leaves the parent view in place.
- [ ] Entering the spy while the parent is **busy** is allowed (the common case:
      the parent delegated and kept working).

### Non-Functional

- [ ] No leaks; `make check` green; the Process Split holds (the spy links no
      agent/runtime unit).
- [ ] Escape always exits the spy - never a dead end.

## Contracts & Interfaces

> Pascal type declarations; bodies are the implementer's.

```pascal
unit hildi.harness.app;

type
  THarnessApp = class
  public
    { The spied child's session id, '' when not spying (exists). }
    property SpiedSessionId: string read SpyId;
  end;
```

The indicator reuses `SetHeader` (the left title becomes `spying · …` while
spying, and is restored on leave).

## Data flow

1. **Enter** - the sidebar raises `OnSelect(childId)` -> `ShowSpy(childId)` opens
   the spy (`srObserve`), sets `FSpyId`, rebuilds the panel for the child, and
   sets the header indicator.
2. **Watch** - `DrainSpy` renders the child's live events; `DrainQueue` still
   consumes the parent's events but draws nothing while spying.
3. **Leave** - Escape -> `LeaveSpy`: close the spy, clear `FSpyId`, rebuild the
   parent's transcript (`ResetWindow` + `RenderHistory`), restore the header and
   the composer.
4. **Failure** - an unreachable child: an error line, no mode change.

## Validation and error handling

- Unknown or dead child: `could not open the child session: <err>`; the parent
  view is unchanged.
- Leaving when not spying: a no-op (idempotent).
- The child's history read is bounded (a tail), so a long child does not stall
  the switch.

## Testing strategy

### Unit / integration (`test_harness_app.pas`)

- [ ] **Enter**: selecting a sidebar row sets `SpiedSessionId` and rebuilds the
      panel with the child's transcript (a seeded child message is shown).
- [ ] **Indicator**: while spying, the header's left shows `spying · …`.
- [ ] **Leave**: Escape clears `SpiedSessionId`, restores the composer, and the
      parent's transcript is back.
- [ ] **Escape priority**: with the `/sessions` modal open, Escape closes the
      modal, not the spy.
- [ ] **Suppression**: while spying, a parent event does not append to the panel.
- [ ] **Failure**: an unknown child id leaves the parent view and shows an error.

## Performance targets

- One child-history read (a bounded tail) per enter; the live stream is drained
  per frame as today.

## Security considerations

- The child id comes from the roster (children of this session); the spy still
  attaches `srObserve` and `Spawn = False`, so it cannot drive or spawn.

## Success criteria

- [ ] All contracts implemented; all tests passing (`make check`).
- [ ] No leaks; the Process Split test still passes.
- [ ] Entering and leaving the spy is reversible; the indicator names the child.

## Out of scope (documented, not built)

- ~~The spy-mode **Abort/Release actions bar**~~ - **delivered** (`Subagent_Spy_v2`
  follow-up): the compose gives way to a reusable CTA actions bar (`TActionsBar`)
  with `a abort` / `r release` / `esc leave`.
- **Driving** the child from the spy (type / approve) - the spy is observe-only.
- A **separate pane/scrollback** for the spy - v2 takes over the panel.

## Future considerations

- A **read-only view of any session** (not just a child) reusing the same take-over
  + actions-bar machinery (the panel mode is already generic).
- A spy that follows the child's *turn boundary* with the parent's dividers.
- Sidebar-driven child driving (type/approve in spy mode).
