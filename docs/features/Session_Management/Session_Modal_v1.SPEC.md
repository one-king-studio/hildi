# Component Specification: Session Modal v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.store` (`ListSessions`, the v10 columns,
`reply_keywords`), `hildegard.helper.harness.app` (`THarnessApp`, the command
registry), `hildegard.helper.tui.palette` (`TCommand`, `TCommandPalette`),
`hildegard.helper.tui.list` (`TListView`), `hildegard.helper.tui.approvalmodal`
(the modal precedent), `hildegard.helper.tui.theme` (`TTheme`).

**Depended on by:** nothing (a leaf surface).

## Purpose

A `/sessions` modal over the Harness TUI: list the current workspace's sessions,
search them, and manage each row — **rename**, **pin/unpin**, **archive/restore**.
It reads the titles and keywords that Reply Metadata persists; it does not derive
them. **Opening** another session is out of v1 (the driver seam; see Decisions).

## Prior art and reuse

| Need | Existing unit | What changes |
| --- | --- | --- |
| A modal over the app | `TTuiApp.PushPlane` / `TPlane` (`DimBackground`) | none — reuse the plane mechanism |
| The modal design/keys | `TApprovalModal` | follow it (dim, trap input, key hints) |
| A scrollable selectable list | `TListView` | reuse for the rows |
| Search input | `TComposeBox` / the editor | a single-line filter field |
| Command entry | `THarnessApp.DefaultCommands` / `RunCommand` | add a `sessions` command |
| Session data | `TSqliteStore.ListSessions` | a v10-enriched variant (title, pinned, archived) |
| Theme roles | `TTheme` | no hard-coded attributes |

No new dependency; the modal is a thin surface over the store and the widget kit.

## Requirements

### Functional

- [ ] `/sessions` is a palette command that opens the modal (and Escape closes it).
- [ ] The modal lists the workspace's sessions **pinned first, then
      most-recently-updated**, with **archived excluded** by default.
- [ ] Each row shows the resolved **title** (override else extracted) and, when
      present, its **keywords**; a session with no title shows a short id.
- [ ] The **current** session is always the first row, marked as current.
- [ ] A **search** field filters live over title, keywords, and id — filtering the
      already-loaded list (no query per keystroke).
- [ ] Up/Down/Home/End move the selection; the list scrolls to keep it visible.
- [ ] Per-row keys: **pin/unpin**, **rename** (inline input seeded with the
      current title; empty cancels), **archive/restore**. Bindings are fixed in
      the SPEC and shown dimmed.
- [ ] An **archived toggle** reveals archived rows (dimmed, with an archive
      glyph); the default view hides them.
- [ ] Activating a row (opening a session) is **not** in v1 — Enter is inert or
      reserved; the modal is management only.

### Non-Functional

- [ ] Filtering is O(sessions) over the loaded list; the modal opens in one frame.
- [ ] No leaks; `make check` green; macOS + Linux; FPC 3.3.1.
- [ ] State is not carried by colour alone (pinned/archived/current each get a
      glyph); roles come from `TTheme`.
- [ ] The Process Split holds (the modal links no agent/runtime unit).

## Contracts & Interfaces

> Pascal type declarations; bodies are the implementer's.

### The modal

```pascal
unit hildegard.helper.tui.sessionsmodal;

type
  { What the modal does when a row action fires; the app performs the store
    write and refreshes. }
  TSessionAction = (saRename, saTogglePin, saToggleArchive);

  TSessionsModal = class(TWidget)
  public
    constructor Create(const ATheme: TTheme);
    { Replace the row set (already resolved: title, keywords, flags). }
    procedure SetRows(const ARows: TSessionRowArray);
    procedure SetCurrent(const ASessionId: string);
    function SelectedSessionId: string;
    { Fired on a row action; the caller writes the store and re-calls SetRows. }
    property OnAction: TSessionActionEvent read FOnAction write FOnAction;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;
```

### The row model (resolved for display)

```pascal
type
  TSessionRow = record
    Id: string;
    Title: string;             // resolved (override else extracted else '')
    Keywords: TStringArray;    // the latest reply's, for the row
    Pinned: Boolean;
    Archived: Boolean;
    IsCurrent: Boolean;
    UpdatedAtMs: Int64;
  end;
  TSessionRowArray = array of TSessionRow;
```

### Store additions (the modal's reads/writes)

```pascal
type
  { List a workspace's sessions with the v10 fields, pinned-first then newest. }
  function ListSessionRows(AWorkspaceId: Integer; AIncludeArchived: Boolean;
    out ARows: TSessionRowArray; out AError: TStoreError): Boolean;
  function SetSessionPinned(const ASessionId: string; APinned: Boolean;
    out AError: TStoreError): Boolean;
  function SetSessionArchived(const ASessionId: string; AArchived: Boolean;
    out AError: TStoreError): Boolean;
  { Set/clear the operator override (reuses Reply Metadata's method). }
  function SetSessionTitleOverride(const ASessionId, AOverride: string;
    out AError: TStoreError): Boolean;
```

## Data flow

- Open: `ListSessionRows(workspace, includeArchived=False)` → `SetRows`; the
  current session marked; the first row selected.
- Filter: keystrokes narrow the in-memory rows (title/keyword/id substring).
- Action: the modal raises `OnAction`; the app calls the matching store method
  and re-reads the rows.
- Archive toggle: re-reads with `includeArchived=True` and dims those rows.

## Validation and error handling

- Empty workspace: an empty-state line, no crash.
- A store-less session: the command is a no-op (a status note), not a crash.
- A row with no title: a short id.
- A store write failure: a status line; the list is unchanged.

## Testing strategy

- Sorting: pinned-first, then newest; archived excluded by default.
- Filter: matches title, keyword, and id; empty query shows all.
- Actions: pin/archive/rename each call the right store method (a fake store
  records the call); the row set refreshes.
- Keys: Up/Down/Home/End; the archived toggle; rename input seeded and cancelled.
- Rendering: headless against `TSurfaceMemory` — the current row is marked, the
  dimmed archived state, the empty state.

## Performance

- One `ListSessionRows` per open/refresh; filtering is in-memory; no per-keystroke
  query.

## Open questions (settle at implementation)

1. Exact key bindings (`P` pin, `A` archive, `R` rename, `X` toggle archived?).
2. Is the row keyword line truncated to a width, and how (a chip run vs. commas)?
3. Does the archived toggle persist across opens, or reset to hidden each time?
