# Component Specification: Chat Panel v1

**Related Feature:** [FEATURE.md](FEATURE.md)
**Builds on:** `Harness_UI_v1.SPEC.md` (implemented), `Text_Edit_v1/v2` (implemented)

## Purpose

Move the chat panel that was prototyped in `examples/tui_layout_demo.pas` into
the toolkit and bind it to the agent loop, so `make tui-agent` runs the designed
conversation view instead of the plain appended transcript. Three new library
units (`chat`, `compose`, `chatpanel`) plus a rewiring of `THarnessApp`; the demo
switches to the library and drops its private copies.

## Requirements

### Functional

- [ ] A chat stream widget renders a column of message blocks: raised user
      bubbles, plain assistant text, error lines, dimmed collapsible thought
      blocks, full-contrast collapsible tool blocks, and an animated thinking
      indicator.
- [ ] A collapsed thought block is a dimmed thin rule; a collapsed tool block is
      a thin rule in full contrast whose title is the model's stated reason, so
      the collapsed lines read as a story of the agent's decisions.
- [ ] Items are mutable, so streaming appends to the item in place, and a block
      can be removed (the thinking indicator's lifecycle).
- [ ] A compose box wraps `TTextEdit` in the designed chrome and submits on
      `Enter` (Shift+Enter adds a line).
- [ ] A chat panel composes the messages panel, the compose overlay, a
      call-to-action strip and a status line, and keeps the stream scrolled to
      the newest block unless the user has scrolled away.
- [ ] `THarnessApp` renders history, streams assistant text and reasoning into
      the panel, shows tool calls and results as blocks, shows the thinking
      indicator while a turn runs, and renders errors; the approval modal is
      unchanged.
- [ ] The layout demo uses the library widgets and keeps behaving as it does
      today.

### Non-Functional

- No new dependency; the widgets are leaves over the existing toolkit.
- Testable headlessly with `TSurfaceMemory` and the scripted input source.
- Leak-clean under `make test-leak`; `make check` green.

## Contracts & Interfaces

### `hildi.tui.surface` additions

```pascal
{ Put one cell, and one string of cells, at (X, Y). Small conveniences the
  widgets would otherwise each re-implement. }
procedure PutCh(const S: ISurface; X, Y: Integer; const ACh: UnicodeString;
  const AAttr: TAttr);
procedure PutText(const S: ISurface; X, Y: Integer; const AText: UnicodeString;
  const AAttr: TAttr);
```

### `hildi.tui.chat`

```pascal
type
  TChatKind = (ckUser, ckAssistant, ckError, ckThought, ckTool, ckThinking);

  { One message block. Mutable so a stream can append to it in place. }
  TChatItem = class(TWidget)
  public
    constructor Create(AKind: TChatKind; const ALabel, AText: string;
      const ATheme: TTheme);
    { Replace or append the body text (streaming). }
    procedure SetText(const AText: string);
    procedure AppendText(const AText: string);
    function Text: string;
    property Kind: TChatKind read FKind;
    { The title: a tool block's reason, or a thought block's label. }
    property Label_: string read FLabel write FLabel;
    property Expanded: Boolean read FExpanded write FExpanded;
    property OnToggle: TNotifyEvent read FOnToggle write FOnToggle;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { A scrolling column of blocks with the scrollbar in the panel border. }
  TChatStream = class(TWidget)
  public
    constructor Create(const ATheme: TTheme);
    function Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
    procedure Clear;
    function Count: Integer;
    function ItemAt(AIndex: Integer): TChatItem;
    function Last: TChatItem;
    { Drop and free one block, e.g. the thinking indicator. }
    procedure Remove(AItem: TChatItem);
    { Re-stick the view to the newest block. }
    procedure FollowBottom;
    property OnToggle: TNotifyEvent read FOnToggle write SetOnToggle;
    property OnChange: TNotifyEvent read FOnChange write SetOnChange;
  end;
```

### `hildi.tui.compose`

```pascal
type
  TComposeSubmittedEvent = procedure(const AText: string) of object;

  { The input box: raised, heavy-topped, wrapping a TTextEdit. }
  TComposeBox = class(TWidget)
  public
    constructor Create(const ATheme: TTheme; const AInfo: string);
    procedure Clear;
    function NeededHeight(AWidth: Integer): Integer;
    function Text: UnicodeString;
    property OnSubmit: TComposeSubmittedEvent read FOnSubmit write FOnSubmit;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;
```

### `hildi.tui.chatpanel`

```pascal
type
  { The chat column: a bordered messages panel with the compose overlaying it,
    a CTA strip above the compose, and a status line below. }
  TChatPanel = class(TWidget)
  public
    constructor Create(const ATheme: TTheme; const AInfo, ACta: string);
    property Stream: TChatStream read FStream;
    property Compose: TComposeBox read FCompose;
    procedure SetStatus(const AText: string);
    procedure SetCta(const AText: string);
    procedure SetComposeActive(AValue: Boolean);
  end;
```

## Architecture

### Prior Art & Reuse

The demo already contains all of this, verified against the design doc: the block
kinds, the collapsed/expanded rules, the overlay compose, the scrollbar in the
panel border (`TScrollContainer.TrackVisible`), the CTA strip and the status
line. This spec moves those classes into `src/` unchanged where possible, adds
the mutation needed for streaming, and wires them to `TTurnEvent`.

- `hildi.tui.edit` (`TTextEdit`) is the compose's editor; v1/v2
  already give it the caret, selection and word motion.
- `hildi.tui.theme` supplies the surfaces (`RaisedBg`, `SunkenBg`) and
  the `OnBg`/`WithStyle` helpers.
- `hildi.tui.panel` supplies the bordered messages panel.
- `hildi.tui.scroll` supplies the scrolling and the bar geometry.
- `hildi.tui.conversation` (`TConversationView`) is superseded for the
  harness and is deleted with its tests once the panel is in place.

### Component Boundaries

- **Responsibilities:** `TChatItem` owns one block's text and expanded state;
  `TChatStream` owns the item list, the scroll and the sticky bottom; `TChatPanel`
  owns the chrome and the layout; `THarnessApp` owns the mapping from turn events
  to blocks.
- **Dependencies:** the chat widgets depend only on the toolkit; `THarnessApp`
  is the only unit that knows both the toolkit and the agent.
- **Side effects:** none; the widgets paint into the surface.

### Data Flow

1. `THarnessApp` builds the panel once and replays the session history into the
   stream.
2. On submit: echo a user block, disable the compose, append a thinking block.
3. `teAssistantDelta` replaces the thinking block with an assistant block on the
   first delta and appends to it thereafter; `teReasoningDelta` does the same
   into a thought block.
4. `teToolCall` appends a collapsed tool block; `teToolResult` fills its body and
   marks the outcome.
5. `teDone`/`teError` finish the turn, re-enable the compose and set the status.
6. Every mutation calls `FollowBottom` so the stream stays pinned to the newest
   block unless the user scrolled up.

### Integration Patterns

Synchronous, single-threaded on the UI thread, as the rest of the toolkit. The
worker thread still communicates only through `TTurnQueue`.

## Validation Rules

- `Add` never returns nil; an empty label or text is allowed.
- `AppendText` on a non-text kind is ignored (the thinking block has no body).
- `SetComposeActive(False)` leaves the text intact and only stops input.

## Testing Requirements

### Unit Tests

- [ ] `chat`: add/clear/count/item access; `SetText`/`AppendText` change the
      measured height; user/assistant/thought/tool blocks render their distinct
      chrome (bubble border, rule, box, sunken background) on `TSurfaceMemory`;
      a click toggles a thought or tool block and fires `OnToggle`; the thinking
      block animates and reports `Animating`.
- [ ] `chat`: the stream keeps the newest block visible as items are added.
- [ ] `compose`: `NeededHeight` grows with the wrapped text; Enter submits and
      clears; Shift+Enter adds a line; the info line renders.
- [ ] `chatpanel`: the compose overlays the messages panel without reflowing it;
      the status line and CTA render; `SetComposeActive(False)` stops input.
- [ ] `surface`: `PutCh`/`PutText` place cells and clip at the surface bounds.
- [ ] Resource cleanup: no leaks under `make test-leak`.

### Integration Tests

- [ ] `THarnessApp`: a streamed turn renders into the panel and re-enables the
      compose; a tool call renders a tool block; an error renders an error block;
      the approval modal still resolves; one frame per step is preserved.
- [ ] The demo builds and behaves as before (scripted pty capture).

## Performance Targets

- Unchanged: message-sized buffers; one layout pass per frame; the existing
  changed-cell diff still limits the output.

## Success Criteria

### Functional

- [ ] All contracts implemented; `make check` green; `make tui-agent` runs the
      panel.

### Quality

- [ ] No memory leaks; the demo has no private copy of the widgets.

## Future Considerations

- Markdown rendering inside assistant blocks (`Markdown_v1`).
- A file/diff viewport pane beside the chat panel.
- Editing files from the TUI (the editor panel adopting `TTextEdit`).
