# Subagent Sidebar — v1 — Technical Specification

## Overview

The operator's window into delegated work. The parent TUI gains a **floating
sidebar** listing the active subagents of the current (parent) session. Selecting
one **spies** on it: the main chat messages panel is fed by that child's live
session stream instead of the parent's, and the composer is replaced by session
actions (**Abort** / **Release**). Spy is **observe-only** — the parent agent
remains the child's driver.

This is the second component of the Subagents feature; the delegation core is
`Subagents_v1.SPEC.md`. It depends on the core's protocol additions
(`ekSubagent`, `ekSubagentAsk`, `ekAmbient`) and the roster the parent runtime
publishes.

## Prior Art and Reuse (Ponytail)

| Need | Already exists | Reuse |
| --- | --- | --- |
| A list widget | `hildi.tui.list` (`TListView`) | The roster rows |
| The chat rendering | `hildi.tui.chat` (`TChatStream`) + `TChatPanel` | Spy feeds the same stream |
| Attach to a live session | `hildi.session.client` (`TSessionClient`, `srObserve`) | Spy is a second observer |
| Map a child's wire events | `hildi.harness.driver` (`TRemoteDriver`, `TRemoteSink`) | A child driver for spy |
| A floating panel | `hildi.tui.panel` / planes (`TTuiApp.PushPlane`) | The sidebar is a non-modal plane or an overlay panel |
| Compose replacement | `hildi.tui.chatpanel` (`SetComposeActive`, CTA) | Hide the compose, show an actions bar |

**New code:** the roster model; the sidebar widget; the spy binding (a child
driver whose events render into the chat panel); and the actions bar.

## Architecture

```
THarnessApp (TUI)
├── TChatPanel            the main messages panel + compose
│     ├── (normal)         the parent session's stream, composer active
│     └── (spy)            the selected child's stream, compose hidden
├── TSubagentRoster       active children of the parent (from ekSubagent)
├── TSidebar              floating list of roster entries; select to spy
└── spy: TSessionClient(child, srObserve) → TChildDriver → chat stream
```

- The **roster** is fed by the parent runtime's `ekSubagent` events (spawned /
  running / completed / aborted / released / gone). The TUI never enumerates
  children itself; it renders what the runtime publishes.
- **Spy** opens a fresh `TSessionClient` to the child with `Role = srObserve`,
  `Spawn = False` (the child already runs). Its events map onto the same
  `TTurnEvent` shape the chat panel already consumes, so spy reuses the rendering
  path with no new drawing code.
- **Observe-only:** the spy client never claims drive. Abort/Release are sent as
  parent-socket commands (`scAbortSubagent` / `scReleaseSubagent`), not to the
  child directly — the runtime routes them to the supervisor.

## Contracts

### 1. Roster

```pascal
unit hildi.harness.subagent;

type
  TSubagentStatus = (ssSpawned, ssRunning, ssCompleted, ssFailed, ssAborted,
    ssReleased, ssGone);

  TSubagentEntry = record
    SessionId: string;
    Label: string;
    Status: TSubagentStatus;
    UpdatedMs: Int64;
  end;

  TSubagentEntryArray = array of TSubagentEntry;

  { The active children of the parent, fed from ekSubagent events. Not
    thread-safe; the TUI thread owns it. }
  TSubagentRoster = class
  public
    { Apply an ekSubagent event. A terminal status (completed/failed/aborted/
      released/gone) keeps the entry visible until the operator dismisses it or
      the child is pruned, so a result is not lost from view. }
    procedure Apply(const ASessionId, ALabel, AStatus: string);
    function Entries: TSubagentEntryArray;
    function Count: Integer;
    function Find(const ASessionId: string): Integer;   // -1 when absent
    procedure Prune;   // drop terminal entries older than a grace window
  end;
```

### 2. Sidebar widget

```pascal
unit hildi.tui.sidebar;

type
  TSubagentSelectedEvent = procedure(const ASessionId: string) of object;

  { A floating list of roster entries. Non-modal: the parent view stays visible
    behind it. Keyboard: up/down move the selection, enter spies, esc closes.
    Mouse: hover highlights, click selects. }
  TSidebar = class(TWidget)
  private
    FTheme: TTheme;
    FRoster: TSubagentRoster;
    FSelected: Integer;
    FOnSelect: TSubagentSelectedEvent;
  public
    constructor Create(const ATheme: TTheme; ARoster: TSubagentRoster);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    { Rebuild from the roster; called when the roster changes. }
    procedure Refresh;
    property Selected: Integer read FSelected;
    property OnSelect: TSubagentSelectedEvent read FOnSelect write FOnSelect;
  end;
```

Each row renders the label, a status glyph, and (by configuration) the child
session id. The selected row uses the theme's accent; terminal rows are dimmed.

### 3. Spy binding

```pascal
unit hildi.harness.subagent.spy;

type
  { A second observer of one child session: attaches with srObserve, maps the
    child's events onto TTurnEvents on a queue the app drains, and detaches on
    close. It never drives. }
  TSubagentSpy = class
  public
    class function Open(const ASessionId: string;
      const AConfig: TSessionClientConfig; out AError: string): TSubagentSpy;
    destructor Destroy; override;
    function PopEvent(out AEvent: TTurnEvent): Boolean;
    function SessionId: string;
    procedure Close;
  end;
```

`AConfig` reuses the parent's store/workspace with `Spawn = False`,
`Role = srObserve`, and `SessionId = ASessionId`.

### 4. App integration

`THarnessApp` gains a **view mode**: `vmParent` or `vmSpy(child)`.

- **Entering spy:** from `TSidebar.OnSelect`, the app opens a `TSubagentSpy`,
  clears the chat stream, renders the child's history from the store, and
  switches the panel to spy mode.
- **Spy rendering:** the app drains the spy queue each `Step` and applies the
  same `HandleTurnEvent` mapping, so a child's assistant/reasoning/tool blocks
  render identically to the parent's.
- **Compose in spy:** `SetComposeActive(False)` hides the composer; an actions
  bar (`TSpyActions`) offers **Abort** and **Release**, which send
  `scAbortSubagent` / `scReleaseSubagent` on the parent socket.
- **Approval asks in spy:** an `ekSubagentAsk` for the spied child renders the
  existing `TApprovalModal`, tagged with the child's label; the decision is sent
  as a parent `scApprove` routed to the child. (A headless parent auto-denies
  instead; see the core spec.)
- **Leaving spy:** `esc` closes the spy client, restores the parent stream, and
  re-enables the composer.

### 5. Approvals surfaced in the parent

`ekSubagentAsk` (a child's ask) shows in the parent's `TApprovalModal` regardless
of view mode, identified by the child's **reason/label** (the child session id is
available by configuration). This is the same modal path the parent's own asks
use, so there is no second approval UI.

## Validation and Error Handling

- Selecting a child whose runtime has exited: the spy attach fails; the sidebar
  marks it `gone` and the app shows a one-line notice instead of an empty panel.
- A spy that detaches (child idle-exited): the app falls back to the parent view
  and marks the entry `gone`.
- Abort/Release on an already-terminal child: a no-op with an inline notice.
- The sidebar never blocks the app: the spy client runs on its own reader
  thread, and the app drains its queue each frame.

## Testing Strategy

- **Roster:** apply each status; terminal entries persist; prune; find.
- **Sidebar widget:** rendered rows from a roster, selection movement, enter
  fires `OnSelect`, over a `TSurfaceMemory` (no terminal).
- **Spy mapping:** a scripted child stream maps to the same `TTurnEvent`s the
  chat panel consumes; detach handling.
- **App integration:** entering/leaving spy swaps the stream source and toggles
  the composer; Abort/Release send the right parent command; an `ekSubagentAsk`
  opens the modal tagged with the child label.
- No terminal in the suite; all widget tests run on `TSurfaceMemory`.

## Performance and Security

- The sidebar is a small list; it re-measures only when the roster changes.
- Spy adds one observer connection per viewed child; closing it releases the
  socket.
- Spy is read-only: it never claims drive, so two windows can never fight over a
  child; abort/release are explicit operator commands.
