# Component Specification: Focus Reporting

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

Track whether the terminal has OS focus (DECSET 1004) so the TUI can stop
animating when it cannot be seen: the caret becomes a steady box and the
animation registry is cleared. A terminal without 1004 support never sends a
focus event, so the app stays "focused" and behaves exactly as today.

## Requirements

### Functional

- [ ] The video surface enables focus reporting on entry and disables it on exit.
- [ ] The input decoder yields a focus event for `CSI I` (focus in) and `CSI O`
      (focus out).
- [ ] The app tracks `TerminalFocused`; on focus-out it withdraws animation (the
      caret's registration) and on focus-in it restores it.
- [ ] The caret renders as a steady box while unfocused.
- [ ] A turn in flight keeps being served while unfocused (only *animation* is
      withdrawn, not the turn).

### Non-Functional

- No new dependency; the sequences reuse the surface's existing init/teardown
  writes and the decoder's CSI path.
- macOS and Linux; `make check` green.

## Contracts & Interfaces

### `hildegard.helper.tui.input` — the event

A focus change is an input event, so it flows through the existing event path.
The kind is appended last, per the project's enum rule, so stored ordinals are
unchanged.

```pascal
type
  TInputEventKind = (
    ikKey, ikPaste, ikMouse, ikResize,
    { The terminal gained or lost OS focus (DECSET 1004). }
    ikFocus);

  TInputEvent = record
    // ...
    Focused: Boolean;   // ikFocus: True on focus in, False on focus out
  end;
```

### `hildegard.helper.tui.input.decode` — the sequences

```pascal
{ In the CSI switch on the final byte:
    'I' -> ikFocus, Focused := True
    'O' -> ikFocus, Focused := False }
```

`CSI I` / `CSI O` carry no parameters; a final byte of `I`/`O` with no private
prefix maps to a focus event. Any other final byte is unchanged.

### `hildegard.helper.tui.surface.video` — the enable/disable

```pascal
{ Init, alongside the existing control writes: }
WriteOut(#27'[?1004h');   { focus reporting on }

{ Done, before restoring autowrap: }
WriteOut(#27'[?1004l');   { focus reporting off }
```

### `hildegard.helper.tui.app` — the focus state

```pascal
type
  TTuiApp = class
  private
    FTerminalFocused: Boolean;
    { Called when an ikFocus event is dispatched. }
    procedure SetTerminalFocused(AValue: Boolean);
  public
    property TerminalFocused: Boolean read FTerminalFocused;
    { True while the app should animate: focused and something registered. }
    function Animating: Boolean;   // FTerminalFocused and (MinIntervalMs > 0)
  end;
```

Focus-out does not clear the registry; it suppresses animation, so focus-in
restores the exact prior demand without re-registration. (The caret's
registration is owned by the compose's `Active` state, which focus does not
change.)

### `hildegard.helper.tui.edit` — the steady caret

```pascal
{ The caret renders as a block whether or not it is blinking; only the blink is
  suppressed while unfocused. The compose's Render reads the focus state (via the
  app's TerminalFocused, threaded through the surface or a small seam) to draw
  the caret solid. }
```

The simplest seam: `TTextEdit` gains a `Blinking: Boolean` (default `True`); the
app sets it `False` on focus-out. `Advance` then holds `FBlinkOn := True` while
`Blinking` is `False`.

## Architecture

### Prior Art & Reuse

The surface already writes terminal control sequences at init/teardown; the
decoder already parses CSI with a final-byte switch; the app already dispatches
input events. Focus reporting is three small extensions, not a new path.

### Component Boundaries

- **Responsibilities:** the surface owns the terminal mode; the decoder owns the
  bytes; the app owns the focus flag and the animation suppression; the edit owns
  the caret's steady/blinking choice.
- **Dependencies:** `tui.input.decode` → `tui.input` (the event); `tui.app` →
  `tui.input` and `tui.clock`; `tui.edit` ← a focus/blinking flag.
- **Side effects:** writes `CSI ? 1004 h/l` to the tty at init/teardown only.

### Data Flow

1. Surface init writes `CSI ? 1004 h`.
2. The terminal sends `CSI I` / `CSI O` on focus changes.
3. The decoder turns them into `ikFocus` events.
4. The app sets `TerminalFocused`, suppresses `Animating`, and marks the caret
   steady.
5. Surface teardown writes `CSI ? 1004 l`.

### Integration Patterns

- The focus event is a normal input event (dispatched like a resize).
- The app's `Animating` combines focus with the registry; `FBusy` (a live turn)
  is independent and keeps the clock running.

## Validation Rules

### Input

- A terminal that never sends `CSI I`/`CSI O` leaves `TerminalFocused = True`.
- `ikFocus` events are idempotent (repeated focus-in is a no-op).

### Output Guarantees

- Focus reporting is always disabled on exit, even on an error path (the surface
  teardown already runs in a `finally`-style path).

## Error Handling

- **A terminal that echoes the sequence or misparses it:** the decoder treats an
  unknown final byte as before; the mode write is best-effort.

## Testing Requirements

### Unit Tests

- [ ] Decoder: `CSI I` → `ikFocus` focused; `CSI O` → `ikFocus` unfocused; other
      final bytes unchanged.
- [ ] `TTuiApp`: `TerminalFocused` toggles with the event; `Animating` is `False`
      while unfocused even with a registration; focus-in restores it.
- [ ] `TTextEdit`: `Blinking := False` holds the caret solid across `Advance`.

### Integration Tests

- [ ] Memory surface + scripted `ikFocus` events: the app takes the idle wait
      while unfocused and the caret's interval when focused.
- [ ] The video surface's init writes `CSI ? 1004 h` and teardown `CSI ? 1004 l`
      (assert on the emitted byte stream, as the surface tests do).

## Performance Targets

- Unfocused idle: no animation frames beyond the idle wait.

## Security Considerations

- The mode is per-terminal and reset on exit; a crash leaves it on, which is
  harmless (the shell's terminal resets on the next full-screen app, and the
  sequence is inert elsewhere).

## Success Criteria

### Functional

- [ ] All contracts implemented; all tests passing (`make check`).

### Quality

- [ ] A backgrounded terminal animates nothing.
- [ ] Documentation updated.

## Future Considerations

- Focus-aware streaming (a backgrounded turn could coalesce its updates).
- Detecting focus by other means where 1004 is unavailable.
