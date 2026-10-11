# Implementation Plan: TUI Startup v1

**Related Specification:** `TUI_Startup_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Paint first, connect second; render the tail, page the rest. Two pieces: the
`THarnessApp` connect lifecycle (a late driver) and tail-first history with
back-pagination, then the composition-root reorder in `examples/tui_agent.pas`.
TDD-first; `make check` before moving on. `main` only.

> **Decision (from the SPEC's open questions):** the connecting state is a
> **single centred line with a phase label**; the first window and page size are
> **message counts** (constants, `StartupTailCount` / `StartupPageSize`); the
> connecting state renders **in the chat area** (the panel is empty anyway).

## Implementation Tasks

### Phase 1: The connect lifecycle (`hildegard.helper.harness.app`)

- [ ] **Define** `TConnState` (`csConnecting`/`csConnected`/`csFailed`) and the
      `FConnState` field; `Create` accepts a nil driver.
- [ ] **Test**: the app constructs with a nil driver and `ConnState =
      csConnecting`.
- [ ] **Implement**: the nil-driver path — `RenderHistory` is skipped while
      connecting; a connecting frame is drawn.
- [ ] **Test**: `Attach(session, driver)` moves `csConnecting -> csConnected` and
      renders the tail.
- [ ] **Implement**: `Attach`.
- [ ] **Test**: `FailConnect(msg)` moves to `csFailed`, shows `msg`, and the app
      remains usable (a quit path exists; no exception escapes).
- [ ] **Implement**: `FailConnect`, and the failed-state frame.
- [ ] **Test**: `SetConnectPhase('loading history')` changes the connecting
      frame's label.
- [ ] **Implement**: `SetConnectPhase` and the phase label.
- [ ] **Test**: a command (submit / checkpoint / interrupt) while `csConnecting`
      is refused with a status line and does not raise.
- [ ] **Implement**: guard the command entry points on `ConnState`.

### Phase 2: Tail-first history (`hildegard.helper.harness.view` + store)

- [ ] **Add** `TSessionView.HistoryTail(AMax): TMessageRecordArray` (the last
      `AMax` messages, oldest first).
- [ ] **Test**: `HistoryTail(N)` returns at most `N` messages, oldest first, from
      a seeded store (and all of them when the session is smaller than `N`).
- [ ] **Implement**: `HistoryTail` (a tail-limited active query; reuse the store's
      boundary logic).
- [ ] **Add** `TSessionView.HistoryPage(ABeforeSeq, AMax)` (the strictly-earlier
      page, oldest first).
- [ ] **Test**: `HistoryPage` returns the page before a boundary and an empty
      array at the head.
- [ ] **Implement**: `HistoryPage` over `QueryMessagesBefore`.
- [ ] **Test**: `RenderHistory` builds from `HistoryTail(StartupTailCount)`, not
      the whole history.

### Phase 3: Back-pagination in the app (`hildegard.helper.harness.app`)

- [ ] **Test**: scrolling to the top issues a page (a spy view counts calls) and
      shows a "loading older messages" line while in flight.
- [ ] **Implement**: the scroll-to-top trigger and the loading line.
- [ ] **Test**: a prepended page preserves the top anchor (the visible message is
      unchanged after the insert).
- [ ] **Implement**: record the top message before prepend; restore after.
- [ ] **Test**: an empty page shows the "start of session" state, not an endless
      loading line.
- [ ] **Test**: a fully-paged transcript equals the un-paged history (same order
      and content).
- [ ] **Implement**: the end-of-history state.

### Phase 4: Composition root (`examples/tui_agent.pas`)

- [ ] **Test**: a startup-trace harness (a headless `THarnessApp`) asserts the
      order surface+input+app -> first frame -> connect -> attach -> tail, with
      the connect NOT before the first frame.
- [ ] **Implement**: reorder — create surface, input, app (nil driver), paint,
      then connect; `Attach` on success, `FailConnect` on failure.
- [ ] **Test**: a failed connect leaves the app running (the error is shown; the
      process does not exit with a bare message).
- [ ] **Implement**: the failure path in the composition root.

### Phase 5: Validation & docs

- [ ] **Run**: `make test SUITE=THarnessAppTest,TSessionTest` (green)
- [ ] **Run**: `make test` (whole suite)
- [ ] **Run**: `make test-leak` (no leaks)
- [ ] **Run**: `make check` (all gates)
- [ ] **Run**: `make tui-agent` builds and the connecting frame appears first
      (manual, real terminal)
- [ ] **Update** `FEATURES.md`; rename this TODO to `TUI_Startup_v1.DONE.md`

## Modified Files

```
src/hildegard.helper.harness.app.pas    (TConnState, Attach, FailConnect, paging)
src/hildegard.helper.harness.view.pas   (HistoryTail, HistoryPage)
src/hildegard.helper.store.pas          (a tail-limited active query, if not reused)
tests/test_harness_app.pas              (lifecycle + paging tests)
tests/test_session.pas                  (HistoryTail/HistoryPage tests)
examples/tui_agent.pas                  (the reorder)
docs/features/FEATURES.md
```

## Dependencies & Ordering

### Must Complete Before Starting

- Nothing external. `Lazy_MCP` is **not** required (this is the general net).

### Can Be Done in Parallel

- Phase 2 (`HistoryTail`/`HistoryPage`) and Phase 1 (the lifecycle) are
  independent; Phase 3 needs both.

### Critical Path

1 (lifecycle) + 2 (tail queries) -> 3 (paging) -> 4 (composition root) -> 5.

## Success Criteria

- [ ] All tasks checked
- [ ] Every SPEC acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] A first frame is on screen before the driver connects; a failed connect is
      an in-app error
- [ ] The first frame is independent of session size (tail only)

## Notes & Considerations

- **v1 is paint-then-block.** The connect still blocks the UI thread, but only
  for the connect (bounded). The async driver is a documented future item.
- **Display-only history.** The loop's context is unaffected; the tail/paging
  changes only what is on screen.
- **Reuse, don't add.** `QueryMessagesBefore` is the page primitive; prefer it
  over a new store method. Mark any shortcut with a `ponytail:` comment.
- Record deviations from the SPEC here.
