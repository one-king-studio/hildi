# Component Specification: Interrupt and Compose Keys v1

**Related Feature:** `FEATURE.md` (Sessions and Ledger / TUI Harness)

## Purpose

Give the operator a way to **interrupt a running turn** without quitting the
app, and give the compose box the editing keys it is missing. Interrupting is a
two-step gesture so a stray Escape cannot cancel work by accident: the first
Escape asks, the second cancels. Quitting with `Ctrl+C` is guarded so it can no
longer discard typed input.

## Requirements

### Functional

Interrupt

- [ ] A turn can be cancelled from the UI; the loop stops at the next boundary
      (between LLM requests, after the current stream) and the turn is closed.
- [ ] The loop takes a cancel check and returns `leCancelled` when it fires.
- [ ] A cancelled turn is recorded with a `tsCancelled` status.
- [ ] `Escape` while a turn runs arms the interrupt and the toolbar shows
      `press esc again to cancel`; a second `Escape` cancels.
- [ ] The armed prompt expires after a short window (2 s) and restores the
      previous state; it also clears when the turn ends.
- [ ] `Escape` while idle does nothing.

Compose keys

- [ ] `Ctrl+U` clears the compose's current logical line.
- [ ] `Ctrl+C` clears the whole compose box when it has any text.
- [ ] `Ctrl+C` with an empty compose quits (as before); with text it never
      quits.
- [ ] `Ctrl+D` still quits unconditionally.

### Non-Functional

- [ ] Leak-clean; the cancel check is a plain flag read at loop boundaries.
- [ ] The loop still makes no provider-specific assumptions; the check is a
      callback.
- [ ] `make check` passes.

## Contracts & Interfaces

### LLM (`hildegard.helper.llm`)

```pascal
type
  TLLMErrorCode = (..., leProvider, leCancelled);
```

### Session model (`hildegard.helper.session`)

```pascal
type
  TTurnStatus = (tsRunning, tsCompleted, tsFailed, tsCancelled);
```

### Agent (`hildegard.helper.agent`)

```pascal
type
  { Returns True when the caller wants the loop to stop at the next boundary. }
  TAgentCancelCheck = function: Boolean of object;

  TAgentLoop = class
    ...
    property CancelCheck: TAgentCancelCheck read FCancel write FCancel;
  end;
```

The loop consults `CancelCheck` at the top of each iteration (before building a
request). It never breaks a tool batch part-way: the assistant's tool calls and
their results must stay paired.

### Turn worker (`hildegard.helper.harness.turn`)

```pascal
type
  TTurnWorker = class(TThread)
    ...
    function Cancelled: Boolean;   // bound to the loop as its CancelCheck
  end;
```

### Compose (`hildegard.helper.tui.edit`)

```pascal
type
  TTextEdit = class(TWidget)
    ...
    { Clear the logical line the caret is on; no-op on an empty line. }
    procedure ClearLine;
  end;
```

`HandleEvent` maps `Ctrl+U` to `ClearLine` (handled) and `Ctrl+C` to `Clear`
(handled only when the buffer is non-empty, so an empty box falls through to the
shell's quit).

### App shell (`hildegard.helper.harness.app`)

```pascal
type
  TQueryEvent = function: Boolean of object;

  TAppShell = class(TSingleChild)
  public
    constructor Create(AChild: TWidget; AOnQuit, AOnEscape: TNotifyEvent;
      ACanQuit: TQueryEvent);
  end;

  THarnessApp = class
    ...
    property InterruptArmed: Boolean read FInterruptPending;
  end;
```

The shell routes `Ctrl+C` to `ACanQuit`: when it returns False the child clears
the compose and the key is consumed; otherwise it quits. `Escape` calls
`AOnEscape`. `Ctrl+D` quits.

## Architecture

### Prior Art & Reuse

- `TTurnWorker.RequestCancel` and the loop already exist; the check is the
  missing wire between them.
- `TTextEdit` already has `Clear`, `DeleteRange`, and cluster-aware line logic;
  `ClearLine` reuses them.
- The toolbar state from Turn Stats v1 gains one value (`psInterrupt`).
- `TAppShell` already intercepts global keys; it gains two callbacks.

### Component Boundaries

- **Agent** owns the cancel check and the cancelled outcome.
- **Turn worker** owns the flag and binds it to the loop for the turn's duration.
- **Text edit** owns the editing keys.
- **App shell** owns the global key routing; **HarnessApp** owns the interrupt
  state machine.

### Data Flow

1. `Escape` reaches the shell, which calls the app.
2. The app arms the interrupt, shows the prompt, and starts the window.
3. A second `Escape` sets the worker's flag; the loop sees it at the next
   boundary and returns `leCancelled`.
4. The worker emits the error; the app closes the turn without an error block.

## Validation Rules

- The interrupt is only armed while a turn is in flight.
- The window is 2 s; an expired prompt restores `thinking` (or `ready`).
- `Ctrl+C` never quits while the compose holds any text.

## Error Handling

- A cancelled turn is `tsCancelled`, not `tsFailed`.
- The app does not draw an error block for `leCancelled`.

## Testing Requirements

### Unit Tests

- [ ] `TestClearLineClearsTheCaretLine`.
- [ ] `TestClearLineOnEmptyLineIsNoOp`.
- [ ] `TestCtrlUClearsTheLine`.
- [ ] `TestCtrlCClearsTheBufferAndReportsHandled`.
- [ ] `TestCtrlCOnEmptyBufferReportsUnhandled`.
- [ ] `TestLoopStopsWhenCancelled` (agent: the cancel check fires before the
      second request).
- [ ] `TestCancelledTurnStatus` (agent: the outcome is `tsCancelled`).

### Integration Tests

- [ ] `TestEscapeArmsThenCancels` (app: the prompt, then the cancel).
- [ ] `TestEscapeWindowExpires` (app: the prompt clears after the window).
- [ ] `TestCtrlCQuitsOnlyWhenComposeIsEmpty`.

## Performance Targets

- One boolean read per loop iteration; no per-frame work while idle.

## Security Considerations

- None; the cancel is local.

## Success Criteria

### Functional

- [ ] Contracts implemented; a turn can be interrupted from the UI.
- [ ] The compose keys work and `Ctrl+C` is guarded.

### Quality

- [ ] `make check` green; no leaks.

## Future Considerations

- A transport-level cancel so an in-flight stream aborts immediately.
- A visible interrupt key in the toolbar hints.
