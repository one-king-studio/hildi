# Component Specification: Animation Clock

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

Replace the TUI's fixed 100 Hz tick — taken whenever anything reports
`Animating` — with a demand-driven clock: widgets register an animation and the
interval it needs, and the app runs at the fastest registered interval (or idles
when nothing is registered). Also remove the two O(blocks) walks the chat stack
still does.

## Requirements

### Functional

- [ ] A widget can register an animation with an interval, update the interval,
      and unregister it.
- [ ] The app's frame interval is the fastest registered interval; when nothing
      is registered it uses the idle wait.
- [ ] The app does not walk the widget tree to discover animation demand.
- [ ] `TChatStack.Animating` is O(1); `TChatStack.Advance` skips its block loop
      when no block animates.
- [ ] The compose caret registers at ~250 ms while active and unregisters when
      inactive.

### Non-Functional

- Register/unregister is cheap and allocation-light (UI thread only).
- The "one clock, no per-widget timers" rule is preserved: the registry changes
  the clock's rate, not the model.
- macOS and Linux, FPC 3.3.1; `make check` green.

## Contracts & Interfaces

### `hildi.tui.clock` — the registry

The clock unit already owns `MonotonicMs` and `DefaultTickMs`; it gains the
registry. A single instance serves the process (the TUI is one app per process,
as `MonotonicMs` already assumes).

```pascal
type
  TAnimationClock = class
  public
    { Register AWidget's animation at AIntervalMs, or replace its interval.
      AIntervalMs <= 0 unregisters. }
    procedure Register(AWidget: TObject; AIntervalMs: Integer);
    procedure Unregister(AWidget: TObject);
    { The fastest registered interval in ms, or 0 when none is registered. }
    function MinIntervalMs: Integer;
    { Diagnostic: how many animations are registered. }
    function Count: Integer;
  end;

{ The process clock. }
function AnimationClock: TAnimationClock;
```

A `TWidget` helper keeps call sites terse and symmetric:

```pascal
type
  TWidget = class
  public
    { Register/unregister this widget's animation; the default interval is the
      widget's own. Safe to call with the same value repeatedly. }
    procedure SetAnimation(AIntervalMs: Integer);
    procedure ClearAnimation;
  end;
```

### `TTuiApp` — the rate

```pascal
type
  TTuiApp = class
  private
    { The idle wait is the floor when nothing animates. }
    function FrameIntervalMs: Integer;   // AnimationClock.MinIntervalMs, else IdleWaitMs
    function GetAnimating: Boolean;      // AnimationClock.MinIntervalMs > 0
  public
    property Animating: Boolean read GetAnimating;
  end;
```

`NextFrameDelayMs` returns the remaining time to the next frame when
`Animating or FBusy`, computed from `FrameIntervalMs`; otherwise `-1` (idle).
`Tick`/`AdvanceTree`/`Present` are unchanged — the tree is still advanced once
per frame, but the frame is now as slow as the slowest demand allows.

### `TChatStack` — O(1) animation state

The block kind is fixed at construction, so only `Add`/`Remove`/`Clear` change
whether a block animates.

```pascal
type
  TChatStack = class(TWidget)
  private
    FAnimatingBlocks: Integer;   // blocks whose kind is ckThinking
  public
    function Animating: Boolean; override;               // FAnimatingBlocks > 0
    function Advance(const ANowMs: Int64): Boolean; override;
    function AnimatingCount: Integer;                    // diagnostic
  end;
```

`Advance` returns `False` immediately when `FAnimatingBlocks = 0`; otherwise it
advances (and the sparkle is the only animating kind, so it may advance just
those blocks).

### `TTextEdit` / `TCompose` — the caret

```pascal
type
  TTextEdit = class(TWidget)
  private
    FActive: Boolean;
    FBlinkIntervalMs: Integer;   // default CaretBlinkIntervalMs (~250)
    procedure SetActive(AValue: Boolean);
  public
    property Active: Boolean read FActive write SetActive;
  end;

const
  CaretBlinkIntervalMs = 250;   // the caret toggles every 530 ms; 250 is plenty
```

`SetActive` registers the caret with the clock while active and clears it when
not; `Animating` stays `FActive` (used by nothing but the registry now).

## Architecture

### Prior Art & Reuse

The clock unit (`MonotonicMs`, `DefaultTickMs`), the `TWidget.Advance`/`Animating`
model, and the app loop all exist. The new pieces are the registry, the app's
rate lookup, the chat stack counter, and the caret's registration.

### Component Boundaries

- **Responsibilities:** the registry owns the demand set and the fastest
  interval; the app owns the loop and reads the interval; a widget owns its
  registration (register on start, clear on stop).
- **Dependencies:** `tui.clock` (registry) is depended on by `tui.widget` (the
  helper), `tui.app` (the rate), `tui.edit` (the caret), and `tui.chat` (the
  counter does not need the registry — it is self-contained).
- **Side effects:** the registry mutates a small table on UI-thread events only.

### Data Flow

1. A widget starts animating → `SetAnimation(interval)` → the registry stores it.
2. The app, each iteration, reads `MinIntervalMs` to choose the frame delay.
3. The app advances the tree once per frame (unchanged).
4. A widget stops → `ClearAnimation` → the registry drops it.

### Integration Patterns

- Single-threaded, UI only; no locks.
- The registry is a small map keyed by widget identity; iteration is avoided on
  the hot path (`MinIntervalMs` is maintained incrementally or computed over a
  handful of entries).

## Validation Rules

### Input

- `Register` with `AIntervalMs <= 0` is equivalent to `Unregister`.
- `Unregister` of an unknown widget is a no-op.
- The app clamps `FrameIntervalMs` to `[1, IdleWaitMs]`.

### Output Guarantees

- `MinIntervalMs` is the minimum registered interval, or 0.
- With no registrations, the app behaves as today's idle loop.

## Error Handling

- **A leaked registration** (a widget destroyed without clearing): the clock
  stays fast. Mitigation: a diagnostic test asserts the registry is empty after
  the app tears down; the caret and stack clear on their state changes.

## Testing Requirements

### Unit Tests

- [ ] Registry: register/replace/unregister; `MinIntervalMs` is the minimum;
      `Count` tracks entries; `<= 0` unregisters; unknown unregister is a no-op.
- [ ] `TTuiApp.FrameIntervalMs`: fastest registered wins; idle wait when empty.
- [ ] `TChatStack`: `AnimatingCount` tracks thinking blocks across
      `Add`/`Remove`/`Clear`; `Advance` is a no-op (returns `False`) with none;
      `Animating` is `False` with none.
- [ ] `TTextEdit`: `Active` registers/clears the caret; `Active := False` clears.

### Integration Tests

- [ ] A memory surface + scripted input: with only the caret registered, the app
      takes the caret's interval, not `DefaultTickMs`.
- [ ] Tearing the app down leaves the registry empty.

## Performance Targets

- Idle (caret only) frame interval ~250 ms instead of 10 ms.
- `TChatStack.Animating`/`Advance` no longer proportional to the block count.

## Security Considerations

- None; no new input or privilege.

## Success Criteria

### Functional

- [ ] All contracts implemented; all tests passing (`make check`).

### Quality

- [ ] Idle CPU (focused, caret only) materially below the baseline.
- [ ] Documentation updated (`FEATURES.md`, `HANDOFF.md`, the guideline).

## Future Considerations

- A per-widget dirty subscription so `Advance` visits only changed widgets.
- Smoothing the clock interval so a registration change does not jitter a frame.
