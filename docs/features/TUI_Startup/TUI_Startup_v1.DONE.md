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

### Phase 1: The connect lifecycle (`hildi.harness.app`)

> **Done** (commit `a18eca2`), extended with the lazy-session half (`a5521c7`,
> `be40988`): `TConnState` is `csIdle`/`csConnecting`/`csConnected`/`csFailed`;
> the app enters `csIdle` when there is no session and no driver, and
> `OnNeedConnect` lets the first submit trigger the connect.

- [x] **Define** `TConnState` (`csIdle`/`csConnecting`/`csConnected`/`csFailed`)
      and the `FConnState` field; `Create` accepts a nil driver.
- [x] **Test**: the app constructs with a nil driver and no session, and
      `ConnState = csIdle`.
- [x] **Implement**: the nil-driver path — `RenderHistory` is skipped; an idle or
      connecting frame is drawn.
- [x] **Test**: `Attach(session, driver)` moves to `csConnected` and renders the
      tail (flushing a prompt held from idle).
- [x] **Implement**: `Attach`.
- [x] **Test**: `FailConnect(msg)` moves to `csFailed`, shows `msg`, and the app
      remains usable (a quit path exists; no exception escapes).
- [x] **Implement**: `FailConnect`, and the failed-state frame.
- [x] **Test**: `SetConnectPhase('loading history')` changes the connecting
      frame's label.
- [x] **Implement**: `SetConnectPhase` and the phase label.
- [x] **Test**: a command (submit / checkpoint / interrupt) while not connected
      is refused with a status line and does not raise.
- [x] **Implement**: guard the command entry points on `ConnState`.
- [x] **Test**: a submit while idle fires `OnNeedConnect`; the held prompt runs
      after `Attach`.
- [x] **Implement**: `OnNeedConnect` + the held-prompt flush.

### Phase 1b: The lazy session (`hildi.harness.view`)

> **Done** (`a5521c7`): a view opened with no session id and `LazySession` set
> creates no session row until `EnsureSession`; the composition root wires the
> connect on the first prompt.

- [x] **Add** `THarnessSessionConfig.LazySession`; `Init` skips `CreateSession`
      when set (and no id and not resuming).
- [x] **Test**: a lazy view opens with a store but `HasSession = False`.
- [x] **Implement**: `HasSession` / `EnsureSession` (idempotent; no-op for a
      named/resumed/ephemeral view).
- [x] **Test**: `EnsureSession` creates the session on demand and is idempotent.
- [x] **Implement**: the composition root (`examples/tui_agent.pas`).

### Phase 2: Tail-first history (`hildi.harness.view` + store)

> **Done** (`a006fbe`, `5c190d8`): the queries and the bounded `RenderHistory`.

- [x] **Add** `TSessionView.HistoryTail(AMax): TMessageRecordArray` (the last
      `AMax` messages, oldest first).
- [x] **Test**: `HistoryTail(N)` returns at most `N` messages, oldest first, from
      a seeded store (and all of them when the session is smaller than `N`).
- [x] **Implement**: `HistoryTail` (`QueryActiveMessagesTail`).
- [x] **Add** `TSessionView.HistoryPage(ABeforeSeq, AMax)` (the strictly-earlier
      page, oldest first).
- [x] **Test**: `HistoryPage` returns the page before a boundary and an empty
      array at the head.
- [x] **Implement**: `HistoryPage` over `QueryMessagesBefore`.
- [x] **Test**: `RenderHistory` builds from `HistoryTail(StartupTailCount)`, not
      the whole history.
- [x] **Add** `MessageCount` (store + view), the virtual-extent input.

### Phase 3: Back-pagination in the app (`hildi.harness.app`)

> **Done** (`5c190d8`, `b7407c5`, `458b090`, `d4a3f4a`). The loads are
> **synchronous** (a local SQLite query), so there is no in-flight moment and no
> "loading older messages" line; the window grows inline. The head guard
> (`FAtHead`) is the "start of session" state.

- [x] **Test**: scrolling to the top issues a page (the tail grows with
      `FOlderPages`; `TestTranscriptIsBoundedToTheTail`).
- [x] **Implement**: the scroll-to-top trigger (`NeedOlderHistory`).
- [x] **Test**: a prepended page preserves the top anchor (the stream's
      `PreserveAnchor`, existing; the window re-render uses it).
- [x] **Implement**: record the top before prepend; restore after (`PreserveAnchor`).
- [x] **Test**: an empty page / the head stops the endless load (`FAtHead`; the
      content height does not grow).
- [x] **Implement**: the end-of-history state (`FAtHead`).
- [x] **Add**: the coarse scrubber over the whole session (`CoarseScrollTarget`,
      real DB counts) and the passive trim (`ShouldTrimHistory`).
- [x] **Test**: a fully-paged transcript is continuous: every message exactly
      once, in order, no gap or duplication at a page seam
      (`TestFullPagingIsContinuous`; it caught the head guard firing on stale
      content height — fixed to key on `FWindowStart`).

### Phase 4: Composition root (`examples/tui_agent.pas`)

> **Done** (`be40988`, `8ba7302`).

- [x] **Test**: `TestPaintBeforeConnectOrder` asserts the app paints a frame
      while idle, before any connect.
- [x] **Implement**: the reorder — surface, input, app (nil driver), paint, then
      connect (`TLauncher.Connect`); `Attach` on success, `FailConnect` on failure.
- [x] **Test**: a failed connect leaves the app running (the error is shown; the
      app stays steppable) — `TestFailConnectShowsErrorAndStaysUsable`.
- [x] **Implement**: the failure path in the composition root (`FailConnect`).

### Phase 5: Validation & docs

- [x] **Run**: `make test SUITE=THarnessAppTest,TSessionTest` (green)
- [x] **Run**: `make test` (whole suite)
- [x] **Run**: `make test-leak` (no leaks)
- [x] **Run**: `make check` (all gates) — 1240 tests, 0 failures, leak-clean
- [~] **Run**: `make tui-agent` builds and the frame appears first (manual, real
      terminal) — **deferred** (needs a real terminal; the build is covered by
      `make check` and the example compiles)
- [x] **Update** `FEATURES.md` (row -> Implemented).
- [x] **Rename** this TODO to `TUI_Startup_v1.DONE.md`.

## Modified Files

```
src/hildi.harness.app.pas    (TConnState, Attach, FailConnect, paging)
src/hildi.harness.view.pas   (HistoryTail, HistoryPage)
src/hildi.store.pas          (a tail-limited active query, if not reused)
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

- [x] All tasks checked (the manual real-terminal check is deferred, `[~]`)
- [x] Every SPEC acceptance criterion maps to a passing test
- [x] `make check` passes (tests + leak gate)
- [x] A first frame is on screen before the driver connects; a failed connect is
      an in-app error
- [x] The first frame is independent of session size (tail only)

## Notes & Considerations

- **v1 is paint-then-block.** The connect still blocks the UI thread, but only
  for the connect (bounded). The async driver is a documented future item.
- **Display-only history.** The loop's context is unaffected; the tail/paging
  changes only what is on screen.
- **Reuse, don't add.** `QueryMessagesBefore` is the page primitive; prefer it
  over a new store method. Mark any shortcut with a `ponytail:` comment.
- Record deviations from the SPEC here.

## Outcome

Implemented on `main` (`a18eca2`, `a5521c7`, `be40988`, `a006fbe`, `5c190d8`,
`b7407c5`, `458b090`, `d4a3f4a`, `8ba7302`, `648e25f`, `5f75807`): the connect
lifecycle (`TConnState`, `Attach`/`FailConnect`/`BeginIdle`/`SetConnectPhase`,
`OnNeedConnect`), the lazy session, the bounded tail window with back-pagination,
the coarse scrubber, the passive trim, and the paint-first composition root.
`make check` green (1240 tests at the time; the suite has grown since).

**Deviations from the SPEC, with reasons:**

- **Synchronous page loads.** A local SQLite query needs no in-flight moment, so
  there is no "loading older messages" line — the window grows inline. The head
  guard (`FAtHead`) is the start-of-session state.
- **The head guard keys on `FWindowStart`,** not the content height: the
  height is stale for one frame after a prepend, which fired the guard early and
  left a gap (`TestFullPagingIsContinuous` caught it).
- **The manual real-terminal check remains deferred** (`[~]`), like the other
  TUI features' sign-offs; the automated gates and the example build stand in.
