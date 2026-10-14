# Implementation Plan: Subagent Spy v2

**Related Specification:** `Subagent_Spy_v2.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Make the observe-only spy usable: a real enter/leave cycle, a header indicator,
and no interleaving with the parent's transcript. The spy and the sidebar already
exist (`Subagent_Sidebar_v1.DONE.md`); this is the missing input/state layer.
TDD-first; `make check` before moving on. `main` only.

## Implementation Tasks

### Phase 1: Leave the spy (Escape)

- [x] **Test**: Escape while spying clears `SpiedSessionId`, restores the
      composer, and re-renders the parent (`test_harness_app`).
- [x] **Implement**: `HandleEscape` checks `FSpyId <> ''` after the modal and
      calls `LeaveSpy`; `LeaveSpy` rebuilds the parent transcript.
- [x] **Test**: Escape priority - with the `/sessions` modal open, Escape closes
      the modal, not the spy.

### Phase 2: The indicator

- [x] **Test**: while spying, the messages-panel header's left shows
      `spying · …` (the child's label, else the id prefix).
- [x] **Implement**: `ShowSpy` sets the header left to the spy indicator and
      `LeaveSpy` restores it (via `UpdateStats` -> `UpdateHeader`).

### Phase 3: Render the child, not the parent

- [x] **Test**: entering the spy rebuilds the panel with the **child's** history
      (a seeded child message is shown; the parent's is not).
- [x] **Implement**: `RenderSpyHistory` (a bounded tail read from the store by
      the child id) replacing the panel contents.
- [x] **Test**: while spying, a **parent** event does not append to the panel.
- [x] **Implement**: `DrainQueue` while spying handles only the state events
      (`teDone`/`teError` -> busy; `teSubagent` -> roster) and drops the draw
      events (they persist in the store and reappear on leave).

### Phase 4: Failure and validation

- [x] **Test**: an unknown child id leaves the parent view and shows an error.
- [x] **Implement**: `ShowSpy` reports the error and does not enter spy mode.

### Phase 5: The sidebar is actually drawn (found during implementation)

- [x] **Test**: `TestSidebarRendersItsRows` - with a roster entry, Ctrl+B puts
      the child's label on the surface.
- [x] **Implement**: `TSidebarOverlay` composites the sidebar over the chat panel
      and routes input to it while shown (global keys fall through); `BuildTree`
      returns it.

### Phase 6: Validation & docs

- [x] **Run**: `make test SUITE=THarnessAppTest,TSubagentSpyTest`
- [x] **Run**: `make check` (all gates) - 1317 tests, leak-clean
- [x] **Update the SPEC** if behaviour diverged; rename this TODO to
      `Subagent_Spy_v2.DONE.md`; add the row to `FEATURES.md`.

## Files to Create/Modify

### New Files

```
docs/features/Subagents/Subagent_Spy_v2.SPEC.md
docs/features/Subagents/Subagent_Spy_v2.TODO.md
```

### Modified Files

```
src/hildegard.helper.harness.app.pas          (overlay, HandleEscape, ShowSpy/LeaveSpy, drain)
src/hildegard.helper.harness.subagent.spy.pas (CreateStub)
tests/test_harness_app.pas                    (the enter/leave/indicator/render tests)
docs/features/FEATURES.md                     (the Subagents row)
```

## Dependencies & Ordering

### Must Complete Before Starting

- `Subagents_v1`, `Subagent_Sidebar_v1` (both done).

### Critical Path

1 (leave) -> 2 (indicator) -> 3 (render the child) -> 4 (failure) -> 5.

## Success Criteria

- [x] All tasks checked
- [x] Every SPEC acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] Entering and leaving the spy is reversible; the indicator names the child
- [x] A parent event never lands in the child's view

## Notes & Considerations

- **The spy exists; this is the missing input/state layer.** Don't rebuild the
  spy or the sidebar - wire them up.
- **While spying, the parent's events are dropped, not queued.** They persist in
  the store and reappear via `RenderHistory` on leave; queuing risks the bounded
  mailbox dropping them anyway.
- **The child view is a simple tail** (no checkpoint/page logic) - a child has no
  checkpoints in v1.
- Record deviations from the SPEC here.

## Outcome

Implemented on `main` (`5e87658`): the sidebar overlay, the Escape leave path,
the `spying · …` indicator, the child-transcript render, parent-event
suppression, and the `OnSpyFactory` / `CreateStub` test seams. `make check`
green (1317 tests, leak-clean).

**Deviations from the SPEC, with reasons:**

- **A bigger bug was found and fixed: the sidebar was never drawn or fed input.**
  `BuildTree` created `FSidebar` and set `OnSelect`, but nothing added it to the
  tree, so `Ctrl+B` toggled a widget nobody rendered and the sidebar's Enter
  could never fire - the spy was unreachable. Added `TSidebarOverlay` (base
  renders, sidebar on top; input to the sidebar while shown, global keys falling
  through), which is the wiring the SPEC assumed existed.
- **Escape also dismisses the sidebar** (before leaving the spy), and the
  sidebar's shown-flag is cleared on spy entry so Escape leaves the spy rather
  than re-showing the sidebar.
- **A test seam was added** (`TSubagentSpy.CreateStub` + `THarnessApp.OnSpyFactory`)
  so the spy state machine is testable without a live child socket; the real
  socket path stays covered by `TSubagentSpyTest`.

Deferred (unchanged): the live smoke.

**Follow-up (delivered): the spy's Abort/Release actions bar.** The compose gives
way to a CTA actions bar while spying (`a abort`, `r release`, `esc leave`);
Abort/Release route through the parent driver. The bar is a new **reusable**
widget (`hildegard.helper.tui.actions`, `TActionsBar`), and the chat panel swaps
compose <-> actions (`SetActionsMode`), so the same take-over + CTA machinery can
back a read-only view of **any** session, not only a subagent spy.
