# TUI Startup

## Overview

The TUI paints nothing until it has connected to — or spawned — the session's
headless runtime. `examples/tui_agent.pas` runs `TSessionView.Open` (store) →
`RemoteDriver` (connect-or-spawn, blocking) → `TSurfaceVideo` /
`TInputSourceTerminal.Create` → `THarnessApp.Create` → `RenderHistory` (loads and
builds the whole transcript) → `Run` (first frame). The screen is blank for all of
it.

This feature makes the TUI **paint before it is connected**: the surface, input,
and app are created first, a **connecting state** is drawn, and the connect
happens after that first frame. The transcript is rendered **tail-first** and older
history is paged in on demand, so the first frame is not O(session).

It is the general safety net for startup latency. `Lazy_MCP` removes the current
2 s cause (MCP on the runtime's bind path); this feature covers the residual (store
+ spawn + history) and any future slow subsystem.

## Problem Statement

- **Nothing is drawn until the driver connects.** The operator sees a blank
  terminal for the whole window: store open + connect-or-spawn + handshake +
  transcript load. Measured at **2.06 s** with MCP configured (0.056 s without) —
  and after `Lazy_MCP`, still ~0.5 s of avoidable blank screen.
- **The transcript is O(session) before the first frame.** `RenderHistory` queries
  all messages and builds one block per message. Measured ~0.35 s per ~900
  messages; the active session holds 3,904.
- **It looks like a hang.** There is no signal that anything is happening, and the
  failure case ("runtime did not start in time") surfaces with no prior state.
- **The intermittency misleads.** Fast when the runtime is still alive (attach),
  slow after it idle-exits (spawn).

## Decision

**Paint first, connect second; render the tail, page the rest.**

- **Reorder the composition root.** Create the surface, input, and app *before*
  the connect; render a **connecting** frame; then perform the connect. The
  cheapest shape is *paint then block*: the first frame shows "connecting…", the
  first loop iteration performs the blocking connect, and the app repaints when
  the driver is attached.
- **The app has a connecting state** and can be handed a driver after creation:
  before that, it renders the connecting state and refuses (or queues) commands;
  after, it renders the transcript.
- **Failure is visible and survivable.** A failed connect shows the error in the
  app and leaves it usable (the operator can quit) rather than exiting with a bare
  message.
- **History is tail-first with back-pagination.** Load the last N messages for the
  first frame; scrolling to the **top** backfills the previous page, shows a
  "loading older messages" line, reflows, and lets the operator keep scrolling
  further up. The headless agent's context is unaffected — the *loop* reads the
  ledger, and the TUI's history is display-only. This is the same back-pagination
  primitive `Context_Handoff` needs for archived messages, so build it once.
- **The transcript is a bounded window, not the whole history.** The TUI is a
  view; it does not maintain context, so it holds only a slice of the most recent
  messages and extends it upward as the operator scrolls. This is the same
  mechanism as pre-checkpoint back-pagination, one continuous window: tail →
  older active messages → archived pages, seamlessly. Older *loaded* messages are
  **passively trimmed** once the operator has stayed away from them (past X
  messages for Y time), so a long session does not grow the TUI's memory without
  bound.
- **The coarse (page) scrollbar stays correct over the window.** The scrollbar
  must reflect the whole session's extent, not just the loaded slice: scrolling
  the bar jumps into the window (loading that region), and the page index still
  tracks the checkpoint boundary. A **virtual extent** (an estimated total row
  height from the message count) drives the bar; the loaded window is a real
  sub-range of it.
- **The async driver is deferred.** A background connect (a driver state, drained
  like `TTurnQueue`) is the eventual shape; v1 does paint-then-block.
- **No session, no runtime, until the first prompt.** A TUI launched without a
  session id must not *create* a session row or *spawn* a runtime at startup.
  Opening the view opens the workspace and the store (cheap, local), but the
  session is created and the runtime spawned **lazily, on the first submit**. So
  the connecting frame becomes an **idle/ready-to-start** state: the operator can
  quit without ever touching the store or spawning a process. A resumed or named
  session still connects eagerly (its id already exists).

### Shape (the SPEC formalizes it)

```text
order      surface + input + app(connecting) -> paint -> connect -> attach -> history
state      THarnessApp: connecting | connected | failed
history    tail window first; page older on demand; scroll stays put
lazy       no session id => idle; the first submit creates the session + spawns
future     an async driver that never blocks the UI thread
```

## Goals

- A frame is on screen before the runtime is reachable.
- The operator can tell "connecting" from "hung".
- A failed connect is an in-app error, not a bare exit.
- The first frame does not depend on the transcript's size.
- The transcript is complete and correct once loaded, and the scroll stays put as
  older history is paged in.

## Non-Goals

- Removing MCP from the runtime's startup path (`Lazy_MCP` does that).
- An async/background driver (deferred; see Future Considerations).
- A splash screen, branding, or animation.
- Loading the **whole** session into memory at any point (the transcript is a
  window; see the Decision).
- Windows.

## User Stories

- As an **operator**, I want the TUI to appear immediately and tell me it is
  connecting, so a slow start does not look like a hang.
- As an **operator** on a long session, I want the transcript to appear promptly,
  not after a multi-second scan.
- As an **operator**, I want a failed connect to leave me in the app with the
  error, not at a shell with a one-line message.
- As a **harness author**, I want the app's first frame to be independent of the
  store's size and the runtime's readiness, so a future slow subsystem cannot
  regress it.

## Acceptance Criteria

### Functional Requirements

- [ ] The TUI renders a first frame **before** the session driver reports
      connected.
- [ ] While connecting, the app shows a connecting state; on success it is
      replaced by the transcript; on failure it shows the error and stays usable
      (the operator can quit).
- [ ] Commands issued while connecting are queued or refused cleanly (no crash, no
      silent loss).
- [ ] The first frame is not O(session): it is drawn after a **bounded** number of
      messages (the tail).
- [ ] Scrolling to the top backfills the previous page with a visible "loading
      older messages" line, reflows, and lets the operator keep scrolling up; the
      visible scroll anchor does not jump.
- [ ] The window is **continuous**: tail → older active messages → archived
      (pre-checkpoint) pages, with no gap and no duplication at the seams.
- [ ] Older **loaded** messages are **passively trimmed** once the operator has
      not scrolled near them for a time (past X messages for Y time), so a long
      session's TUI memory stays bounded; trimming never moves the viewport.
- [ ] The coarse (page) scrollbar reflects the **whole** session's extent, not
      just the loaded window; dragging it jumps into the window and loads that
      region; the page index still tracks the checkpoint boundary.
- [ ] The transcript, once fully loaded, is identical to today's (and to a resumed
      session).
- [ ] The headless agent's context is unaffected: the loop still reads the full
      ledger.

### Non-Functional Requirements

- [ ] Cold start to first frame ≤ 250 ms with MCP configured and a 3,904-message
      session (today ≥ 2 s).
- [ ] The connect does not spin the UI thread; the blocking call is bounded and
      its state is visible.
- [ ] No new threads beyond the established worker+queue pattern (v1 adds none).
- [ ] `make check` passes; macOS and Linux, FPC 3.3.1; `{$mode delphi}`.
- [ ] The Process Split is preserved (the TUI links no agent/tool/runtime unit).

## Success Metrics

### Quantitative

- First frame: ≤ 250 ms with MCP configured and the active session's history
  (from ~2.0 s).
- Transcript tail visible ≤ 500 ms after attach.
- No user-visible "hang" window: the connecting state appears within one frame.

### Qualitative

- The app never looks frozen or blank during startup.
- A failed connect is an error in the app, not an exit.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- The one-clock rule holds: the connecting state does not add per-widget timers.
- The composition root (`tui_agent.pas`) is the ordering change; the app gains a
  connecting state and a late driver.
- History is display-only: the loop's context comes from the ledger in the
  runtime, so a tail-first view cannot change what the model sees.

### Business / Time

- No deadline. `main` only, TDD-first, one logical commit per step.

## Dependencies

### Internal

- `examples/tui_agent.pas` — the ordering change.
- `hildegard.helper.harness.app` — `THarnessApp`, the connecting state, the
  transcript, `RenderHistory`.
- `hildegard.helper.harness.driver` — `ISessionDriver` / `TRemoteDriver`.
- `hildegard.helper.harness.view` — `TSessionView.Open`, `History`, `Turns`.
- `hildegard.helper.tui.app` — `Run`, `Present`, `Tick`, the `OnLoop` hook.
- `hildegard.helper.tui.chat` — the stream and its windowed layout.

### External

- None new.

## Risks

- **The connecting state must be honest.** A static "connecting…" that never
  resolves is worse than blank. Mitigation: it resolves to the transcript or a
  concrete error, with the elapsed time if the wait is long.
- **The block freezes input.** Paint-then-block means input is not serviced during
  the connect. Mitigation: acceptable while the connect is ~30 ms (`Lazy_MCP`);
  the async driver removes it entirely.
- **Scroll jitter on back-pagination.** Prepending older blocks can move the
  viewport. Mitigation: preserve the visible anchor (the block at the top of the
  viewport) across the prepend.
- **Tail-first completeness.** A partially loaded transcript must not look
  complete. Mitigation: show that older history exists and is loadable.
- **Driver lifecycle.** The app must handle "not yet connected" for every command
  and the connect arriving mid-frame. Mitigation: an explicit state machine; no
  command reaches the driver before `connected`.
- **A regression of the resume invariant.** "The resumed view is identical to the
  live view" must still hold once fully paged. Mitigation: keep the render path
  unchanged; only the *number loaded at first paint* changes.

## Out of Scope

- Removing MCP from the runtime's startup path (`Lazy_MCP`).
- An async/background driver.
- A windowed store query as the primary history path.
- A splash screen or startup animation.
- Windows.

## Future Considerations

- **Async driver** — connect on a worker thread, report `connecting` / `connected`
  / `failed` through the existing queue pattern, so the UI is never blocked.
- **Windowed history query** — `LIMIT/OFFSET` (or keyset) paging so a session with
  a million messages loads in constant time.
- **A startup trace / budget test** — a deterministic assertion that a cold start
  does bounded work, so a future slow subsystem fails a gate rather than a
  stopwatch.

## Open Questions

1. **What does the connecting state say** — a single line, or a line plus elapsed
   time and the phase (store / connect / history)?
2. **Back-pagination page size** — a message count, a token budget, or a
   screenful? (The trigger is decided: scroll-to-top backfills.)
3. **How many messages is the first window** (a count, or a token budget)?
4. **Does the connecting state render in the chat area**, or as a centered panel
   (like the empty-state logo that was prototyped)?

## Notes

- **The order is the bug.** The composition root connects before it can draw; the
  fix is to draw first. Nothing about the driver or the protocol changes.
- **Why tail-first is safe.** The TUI's history is a *view*. The loop's context is
  assembled from the ledger by the runtime (`TSqliteConversationStore`), so
  loading only the tail cannot change what the model sees — it only changes what
  is on screen at first paint.
- **Measured.** First output 0.048 s (fresh store) → 0.056 s (906 msgs, no MCP) →
  2.059 s (906 msgs, MCP); settled 0.79 s → 1.14 s → 3.76 s. History ≈ 0.35 s per
  ~900 messages.
- **ICE score.** Impact 7 (a visible multi-second blank window and the failure
  case), Confidence 8 (the cause is measured; the reorder is small), Ease 6 (a
  composition-root reorder, an app state, tail-first history, several tests).
  Priority: high (after `Lazy_MCP`).
- **Related:** `docs/features/Lazy_MCP/FEATURE.md`,
  `docs/features/Skills/FEATURE.md`,
  `docs/features/Context_Handoff/FEATURE.md` (the archive/snapshot model that
  consumes back-pagination),
  `docs/features/Headless_Sessions/FEATURE.md`,
  `docs/guidelines/tui-rendering.md`.
