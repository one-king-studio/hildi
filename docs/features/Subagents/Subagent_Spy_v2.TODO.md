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

- [ ] **Test**: Escape while spying clears `SpiedSessionId`, restores the
      composer, and re-renders the parent (`test_harness_app`).
- [ ] **Implement**: `HandleEscape` checks `FSpyId <> ''` after the modal and
      calls `LeaveSpy`; `LeaveSpy` rebuilds the parent transcript.
- [ ] **Test**: Escape priority - with the `/sessions` modal open, Escape closes
      the modal, not the spy.

### Phase 2: The indicator

- [ ] **Test**: while spying, the messages-panel header's left shows
      `spying · …` (the child's label, else the id prefix).
- [ ] **Implement**: `UpdateHeader` (or `ShowSpy`/`LeaveSpy`) sets the header
      left to the spy indicator and restores it on leave.

### Phase 3: Render the child, not the parent

- [ ] **Test**: entering the spy rebuilds the panel with the **child's** history
      (a seeded child message is shown; the parent's is not).
- [ ] **Implement**: a child-history render (a bounded tail read from the store
      by the child id) replacing the panel contents.
- [ ] **Test**: while spying, a **parent** event does not append to the panel.
- [ ] **Implement**: `DrainQueue` while spying handles only the state events
      (`teDone`/`teError` -> busy; `teSubagent` -> roster) and drops the draw
      events (they persist in the store and reappear on leave).

### Phase 4: Failure and validation

- [ ] **Test**: an unknown child id leaves the parent view and shows an error.
- [ ] **Implement**: `ShowSpy` reports the error and does not enter spy mode.

### Phase 5: Validation & docs

- [ ] **Run**: `make test SUITE=THarnessAppTest,TSubagentSpyTest`
- [ ] **Run**: `make check` (all gates)
- [ ] **Update the SPEC** if behaviour diverged; rename this TODO to
      `Subagent_Spy_v2.DONE.md`; add the row to `FEATURES.md`.

## Files to Create/Modify

### New Files

```
docs/features/Subagents/Subagent_Spy_v2.SPEC.md
docs/features/Subagents/Subagent_Spy_v2.TODO.md
```

### Modified Files

```
src/hildegard.helper.harness.app.pas   (HandleEscape, ShowSpy/LeaveSpy, header, drain)
tests/test_harness_app.pas             (the enter/leave/indicator/suppression tests)
docs/features/FEATURES.md              (the Subagents row)
```

## Dependencies & Ordering

### Must Complete Before Starting

- `Subagents_v1`, `Subagent_Sidebar_v1` (both done).

### Critical Path

1 (leave) -> 2 (indicator) -> 3 (render the child) -> 4 (failure) -> 5.

## Success Criteria

- [ ] All tasks checked
- [ ] Every SPEC acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] Entering and leaving the spy is reversible; the indicator names the child
- [ ] A parent event never lands in the child's view

## Notes & Considerations

- **The spy exists; this is the missing input/state layer.** Don't rebuild the
  spy or the sidebar - wire them up.
- **While spying, the parent's events are dropped, not queued.** They persist in
  the store and reappear via `RenderHistory` on leave; queuing risks the bounded
  mailbox dropping them anyway.
- **The child view is a simple tail** (no checkpoint/page logic) - a child has no
  checkpoints in v1.
- Record deviations from the SPEC here.
