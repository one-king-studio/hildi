# Component Specification: TUI Startup

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

Make the TUI paint **before** it is connected: create the surface, input, and app
first, render a **connecting** frame, then perform the connect (store open +
connect-or-spawn + handshake), then render the transcript **tail-first** with
older history paged in on demand. It removes the blank-terminal window and turns
a failed connect into an in-app, survivable error.

Two changes, both reordering rather than new machinery:

1. **The composition root draws before it connects** (`examples/tui_agent.pas`).
2. **`THarnessApp` gains a connect lifecycle** (`connecting | connected | failed`)
   and a tail-first transcript with back-pagination.

## Prior art and reuse

The design adds one state machine and one paging path; everything else exists.

| Need | Existing unit | What changes |
| --- | --- | --- |
| The app, its tree, its run loop | `hildegard.helper.harness.app` (`THarnessApp`, `TTuiApp.Run`/`Step`/`OnLoop`) | a lifecycle enum + a late driver; `RenderHistory` splits into tail + page |
| The transcript view | `hildegard.helper.tui.chat` (`TChatPanel`, the stream) | prepend a page; keep the scroll anchor |
| Driver connect | `hildegard.helper.harness.driver` (`ISessionDriver`, `TRemoteDriver`) | none (still blocking in v1) |
| Session/store/view | `hildegard.helper.harness.view` (`TSessionView.Open`, `History`) | a tail-limited `History` (a new query) |
| Windowed history query | `hildegard.helper.store` (`QueryMessagesBefore`, `QueryActiveMessages`) | reuse `QueryMessagesBefore` for pages; add a tail-limited active query |
| The scroll container | `hildegard.helper.tui.scroll` (`TScrollContainer`) | none (already anchors) |

`QueryMessagesBefore(ASessionId, ABeforeSeq, ALimit, ...)` already returns the
last `ALimit` messages at or before a boundary, oldest first — the paging
primitive. v1 reuses it; it does **not** add a new store method except a
tail-limited variant of `History` (see Contracts).

## Requirements

### Functional

- [ ] The TUI renders a first frame **before** the driver reports connected.
- [ ] `THarnessApp` exposes a connect lifecycle: `connecting`, `connected`,
      `failed`; the frame reflects it.
- [ ] The app can be constructed **without** a driver and handed one later
      (`AttachDriver`); until then it renders the connecting state.
- [ ] While connecting, commands (submit, checkpoint, interrupt) are **refused
      cleanly** (no crash, no silent loss) — a status line says why.
- [ ] On a successful connect the connecting state is replaced by the transcript;
      on failure the error is shown in-app and the app stays usable (quit works).
- [ ] The first frame's transcript is a **bounded tail** (the last `N` messages),
      not the whole session.
- [ ] Scrolling to the top backfills the previous page: a visible "loading older
      messages" line, then the older blocks prepend, and the visible scroll
      anchor does not jump.
- [ ] Once fully paged in, the transcript is identical to today's (and to a
      resumed session).
- [ ] The headless agent's context is unaffected (the loop reads the ledger; the
      TUI history is display-only).

### Non-Functional

- [ ] Cold start to first frame ≤ 250 ms with MCP configured and a 3,904-message
      session.
- [ ] The connect does not spin the UI thread: the block is bounded and its state
      is visible (v1 is paint-then-block; the async driver is future work).
- [ ] No new threads beyond the established worker+queue pattern (v1 adds none).
- [ ] The Process Split is preserved: the TUI links no agent/tool/runtime unit.
- [ ] `make check` green; macOS and Linux; FPC 3.3.1; `{$mode delphi}`.

## Contracts & Interfaces

> Contracts are Pascal type declarations. Bodies are the implementer's.

### The connect lifecycle

```pascal
type
  { Where the app is in the startup sequence. }
  TConnState = (
    csConnecting,   // no driver yet: draw the connecting frame
    csConnected,    // driver attached; the transcript is live
    csFailed        // the connect failed; show the error, stay usable
  );
```

### A late driver and the lifecycle (THarnessApp additions)

```pascal
type
  THarnessApp = class
  public
    { Existing ctor gains a nil-driver path: ASession may be nil while
      connecting, ADriver may be nil. }
    constructor Create(const ASurface: ISurface; const AInput: IInputSource;
      ASession: TSessionView; ADriver: ISessionDriver;
      AMode: TThemeMode; ALightDetected: Boolean);

    { Hand the app its session and driver after the connect succeeded; moves
      csConnecting -> csConnected and renders the transcript tail. }
    procedure Attach(const ASession: TSessionView; const ADriver: ISessionDriver);

    { Report a failed connect; moves to csFailed and shows AError. }
    procedure FailConnect(const AError: string);

    { A phase label for the connecting frame (e.g. 'connecting', 'loading
      history'), so the wait is honest. }
    procedure SetConnectPhase(const APhase: string);

    property ConnState: TConnState read FConnState;
  end;
```

### Tail-first history and paging — the window

The transcript is a **bounded window** over the session, not the whole history.
The window is continuous: tail (newest) → older active messages → archived
(pre-checkpoint) pages.

```pascal
type
  { The TUI's history query, bounded for the first frame and for each extension. }
  TSessionView = class
    { The last AMax messages of the active window (oldest first), for the first
      frame. Bounded: the first paint does not read the whole session. }
    function HistoryTail(AMax: Integer): TMessageRecordArray;
    { The page strictly before ABeforeSeq: the last AMax messages with
      seq < ABeforeSeq (oldest first). Empty at the head. Used for both the
      older-active window and the archived pages. }
    function HistoryPage(ABeforeSeq: Int64; AMax: Integer): TMessageRecordArray;
    { The whole session's message count, for the virtual scroll extent. }
    function MessageCount: Integer;
  end;
```

- `HistoryTail` is the first-frame window; `HistoryPage` is the scroll-up
  backfill (one primitive for both the active window and the archived pages —
  the checkpoint boundary is just a `seq`). Both map onto the store
  (`QueryActiveMessagesTail` for the tail; `QueryMessagesBefore` for the page).
- **The window state (app).** `FWindowFirstSeq` / `FWindowLastSeq` bound the
  loaded range; scrolling near the top loads the previous page
  (`HistoryPage(FWindowFirstSeq, PageSize)`), scrolling near the bottom (when a
  newer range exists) loads the next. New live messages extend the bottom.
- **The anchor rule.** When a page prepends, the app records the top visible
  message's identity before the insert and restores it after, so the viewport
  does not jump. The scroll container's existing anchor support is the seam.

### The virtual extent (the coarse scrollbar)

The scrubber must reflect the **whole session**, not the loaded window.

```pascal
type
  { A cheap total-row estimate from the message count, so the page bar spans the
    session while only a window is loaded. Refined as real pages load. }
  TWindowExtent = record
    MessageCount: Integer;    // the session's total
    LoadedCount: Integer;     // the window's real count
    EstimatedRowHeight: Integer;
    function VirtualMaxScroll(const AViewportH: Integer): Integer;
    function WindowRowRange(...): TRowRange;   // the loaded window's sub-range
  end;
```

- The page scrubber maps a segment to a **fraction of the virtual extent**; a
  jump into an unloaded region triggers the loads that cover it.
- `StreamScrolled`'s page index still keys on the checkpoint boundary
  (`FCheckpointBlock`), which remains correct because the boundary block stays in
  the window whenever the window overlaps it.

### Passive trim

```text
rule    once the operator has not scrolled within X messages of an older
        loaded region for Y time, unload it (drop the blocks + the window range)
guards  never trim the region the viewport is in or near; never move the
        viewport; never trim below the tail window
clock   checked on the frame tick (the one-clock rule), not a new timer
```

- Trimming keeps the loaded set bounded: a session scrolled through then left
  idle releases the old blocks. The window shrinks from the top (and, when far
  below, the middle), and the virtual extent is unchanged (only `LoadedCount`
  drops).

### Composition root ordering (`examples/tui_agent.pas`)

```text
surface + input + app(csConnecting)   -> paint a connecting frame
connect (store open + RemoteDriver)   -> success: Attach ; failure: FailConnect
history (tail) + first transcript     -> the live view
```

## Data flow

- **Connect (v1, paint-then-block).** The first `Run` iteration paints the
  connecting frame; the connect runs on the next loop step; success calls
  `Attach`, failure calls `FailConnect`. The UI thread is blocked only for the
  connect itself (bounded; ~30 ms once MCP is lazy, ≤ the client's spawn budget
  otherwise).
- **Paging.** The app tracks the smallest loaded `Seq`. When the scroll position
  reaches the top, it calls `HistoryPage(MinSeq, PageSize)`, shows the loading
  line, prepends the blocks, and restores the anchor. No page in flight = no
  request.
- **Display-only.** The loop's context is assembled by the runtime from the
  ledger (`TSqliteConversationStore.Compose`); the TUI's tail/paging never
  affects it.

## Validation and error handling

- A failed connect sets `csFailed` with the error text; the app remains
  interactive and quit works. No bare exit.
- A command issued while `csConnecting`/`csFailed` is refused with a status line
  (never a crash, never silently dropped).
- An empty page (no older history) shows a terminal "start of session" state, not
  an endless "loading".
- A `HistoryPage` store error surfaces as an error line and leaves the transcript
  unchanged.

## Testing strategy

What must be covered (the tester chooses how):

- The app constructs with a nil driver and reports `csConnecting`; `Attach` moves
  it to `csConnected`; `FailConnect` to `csFailed`.
- A first frame is rendered while `csConnecting` (assert a frame, not a blank
  surface).
- A command during `csConnecting` is refused with a status, and does not raise.
- `HistoryTail(N)` returns at most `N` messages, oldest first, from a seeded
  store; `HistoryPage` returns the strictly-earlier page and an empty page at the
  head.
- Paging prepends older blocks and preserves the top anchor (the visible message
  is unchanged after the insert).
- A fully-paged transcript equals the un-paged history (same order, same content).
- A failed connect leaves the app usable (a quit path exists; no exception
  escapes).

## Performance

- First frame independent of session size: only the tail window is read and built.
- Page size bounds per-scroll work; the loading line is shown only while a page is
  in flight.
- No per-frame timer is added; the one-clock rule holds.

## Open questions (settle at implementation)

1. Connecting-state content: a single line, or line + phase + elapsed time?
2. First-window size and page size: a message count, or a token budget?
3. Does the connecting state render in the chat area or as a centred panel?
