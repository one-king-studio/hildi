# Component Specification: TUI Animation v1

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

Give the TUI one synchronized clock. `TTuiApp` owns the frame cadence, advances
every widget by time each frame, composites once, and diffs once. Widgets derive
time-based content from the frame time; animations are pure functions of it.

## Requirements

### Functional

- [x] A monotonic millisecond clock.
- [x] `TWidget.Advance(ANowMs)` (no-op by default) and `TWidget.Animating`.
- [x] `TTuiApp` advances the tree, composites, and flushes once per frame.
- [x] The app waits on input to the next frame while animating, and indefinitely
      when idle.
- [x] `TSpinner` and `TProgress` are the first time-based widgets.
- [x] `Tick(ANowMs)` advances a frame deterministically for tests.

### Non-Functional

- Performance: an unchanged frame emits zero bytes; one changed cell costs one
  cell; the per-frame diff is O(cells).
- Reliability: no timers leak; `make check` green.
- Portability: monotonic source only; no wall-clock time in animations.

## Contracts & Interfaces

### Clock — `hildegard.helper.tui.clock`

```pascal
{ Monotonic milliseconds since an unspecified epoch. Never wall-clock; backed by
  GetTickCount64 (clock_gettime(CLOCK_MONOTONIC) on Unix). }
function MonotonicMs: Int64;

const
  DefaultTickMs = 10;   // 100 Hz frame cadence
```

### Widget time hook — `hildegard.helper.tui.widget`

```pascal
TWidget = class
  { Update time-based content to ANowMs. Default: no-op. Must not arrange.
    Returns True when the content changed, so the app repaints only the frames
    that actually differ (the clock ticks at 100 Hz; the screen does not). }
  function Advance(const ANowMs: Int64): Boolean; virtual;
  { True while this widget (or a descendant) has time-based content. }
  function Animating: Boolean; virtual;
end;
```

- `TContainer.Advance` forwards to every child and ORs their results;
  `TContainer.Animating` is the OR of its children.
- `TSpinner`/`TProgress` return True only when the frame index / bounce cell
  actually moves, so a 90 ms spinner repaints ~11 times a second, not 100.

### App frame loop — `hildegard.helper.tui.app`

```pascal
type
  { Returns True to stop the run loop (a signal, a quit flag). }
  TStopCheck = function: Boolean;
  { Called once per Run iteration (drain queues, update external state). }
  TLoopHook = procedure of object;

TTuiApp = class
  constructor Create(const ASurface: ISurface; const AInput: IInputSource;
    ARoot: TWidget; ATickMs: Integer = DefaultTickMs);

  { Advance a frame to an explicit time: advance the whole tree and repaint only
    when a widget reports a change (or the layout is dirty). Deterministic; the
    test seam. }
  procedure Tick(const ANowMs: Int64);

  { Milliseconds until the next frame (0..TickMs), or -1 when idle (nothing
    animating and not Busy). Exposed so the gating is testable. }
  function NextFrameDelayMs: Integer;

  procedure Run(ACheckStop: TStopCheck = nil; AOnLoop: TLoopHook = nil);

  property TickMs: Integer read FTickMs write FTickMs;
  property NowMs: Int64 read FNowMs;
  property Animating: Boolean read GetAnimating;   // OR over all planes
  property Busy: Boolean read FBusy write FBusy;   // out-of-band work pending
end;
```

`Run` loop (prose; `Step`/`Tick` are the tested units):

1. Render the first frame immediately (an idle loop would otherwise wait out the
   idle timeout before anything appears).
2. `Timeout := NextFrameDelayMs` (`-1` ⇒ the idle timeout below).
3. `if Input.Wait(Timeout, E)` handle the event.
4. `AOnLoop` (drain an external queue); `Busy` may change here.
5. If `Animating` or `Busy`, advance the frame when due and repaint **only if a
   widget reports a change** (or the layout is dirty); otherwise repaint only on
   input or a dirty layout.
6. Repeat until `Stop`, or until `ACheckStop` returns True.

`NextFrameDelayMs` returns `-1` when `not (Animating or Busy)`; otherwise
`max(0, min(TickMs, TickMs - (NowMs - LastTickMs)))`.

**The tick and the repaint are decoupled.** `Tick` advances the tree every frame,
but calls `Present` only when `Advance` returned True or the layout is dirty. A
100 Hz clock therefore does not mean 100 recomposes per second: a 90 ms spinner
repaints ~11 times a second. `Run` also draws the first frame before waiting.

**`Busy` vs `Animating`.** `Animating` is "a widget has time-based content".
`Busy` is "the owner has out-of-band work pending" (a worker streaming into a
queue): it keeps the frame cadence so streamed output appears promptly, without
the owner falling back to a 1 ms busy poll. The harness sets `Busy` from its
in-flight turn.

**Idle wait.** The terminal `Wait` blocks on `select`, so a keypress wakes the
loop immediately - a poll-then-sleep `Wait` delayed the first key by up to the
whole timeout and read as a laggy UI. When idle, `Run` still uses a short
`IdleWaitMs` (100 ms) timeout so a signal or a resize is noticed promptly; that
is a wake-up cadence, not a repaint cadence.

### Spinner — `hildegard.helper.tui.spinner`

```pascal
type
  TSpinnerFrames = array of UnicodeString;

  TSpinner = class(TWidget)
  public
    { FPC cannot default a record parameter, so the attr is an overload. }
    constructor Create(const AFrames: array of UnicodeString;
      AIntervalMs: Integer = 90); overload;
    constructor Create(const AFrames: array of UnicodeString;
      AIntervalMs: Integer; const AAttr: TAttr); overload;
    procedure Advance(const ANowMs: Int64); override;   // frame = f(now - origin)
    function Animating: Boolean; override;              // True when frames exist
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;

    property Frames: TSpinnerFrames;   // read
    property IntervalMs: Integer;
    property Attr: TAttr;
    property Index: Integer;           // read; current frame (tests)
  end;

const
  BrailleFrames: array[0..9] of UnicodeString =
    ('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏');
  LineFrames: array[0..3] of UnicodeString = ('|','/','-','\');
```

- `Measure` is one row by the widest frame.
- The frame is a pure function of `ANowMs` (and the first call's time as the
  phase origin), so two spinners started together stay in step.

### Progress — `hildegard.helper.tui.progress`

```pascal
type
  TProgress = class(TWidget)
  public
    constructor Create(AWidthCells: Integer); overload;
    constructor Create(AWidthCells: Integer; const AAttr: TAttr); overload;
    procedure Advance(const ANowMs: Int64); override;   // indeterminate only
    function Animating: Boolean; override;              // Indeterminate
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;

    property Value: Integer;        // 0..Max, determinate
    property Max: Integer;          // default 100
    property Indeterminate: Boolean;
    property WidthCells: Integer;
    property Attr: TAttr;
    property Position: Integer;     // read; bounce cell (tests)
  end;
```

- Determinate: `round(Value / Max * WidthCells * 8)` eighths rendered with
  `█▉▊▋▌▍▎▏`, then blanks to the width.
- Indeterminate: a single block bounces across the inner width (one cell margin
  at each end, positions `1..WidthCells-2`) as a function of `ANowMs`.

## Architecture

### Prior Art & Reuse

- `TTuiApp` already composites planes and flushes once; `Tick` reuses
  `RenderFrame`.
- `hildegard.helper.tui.encoder` diffs cells, so an unchanged frame emits nothing.
- `IInputSource.Wait(ATimeoutMs, E)` already blocks with a timeout.
- `hildegard.helper.tui.theme` supplies attributes; `panel`/`focus` compose them.
- Monotonic time: RTL `unix.fpgettimeofday` (the benchmark already uses it).

Gap designed here: the clock, the `Advance`/`Animating` hook, and the two
time-based widgets.

### Component Boundaries

- `clock` is pure and terminal-free; `spinner`/`progress` are pure widgets.
- `TTuiApp` owns the clock and the loop; widgets never read the clock themselves.

### Data Flow

1. `Run` waits (input or frame timeout).
2. On a frame: `NowMs := MonotonicMs; Root.Advance(NowMs)`.
3. If layout is dirty, arrange; then `RenderFrame` composites and flushes.
4. The encoder emits only changed cells.

### Integration Patterns

- No threads; no per-widget timers.
- Tests call `Tick(t)` directly; `NowMs` is explicit, so assertions are exact.
- An animation is a function `frame = f(now)`; a timeline is just such a function.

## Validation Rules

- `TickMs >= 1`; `IntervalMs >= 1`.
- `Value` clamps to `[0, Max]`; `Max >= 1`; `WidthCells >= 1`.
- `Advance` never arranges or flushes; it only updates content.

## Error Handling

- No exceptions to callers; a zero-length frame set renders nothing and reports
  `Animating = False`.

## Testing Requirements

### Unit Tests

- [x] `MonotonicMs` is non-decreasing.
- [x] `TContainer.Advance` reaches every child; `Animating` is the OR.
- [x] `TTuiApp.Tick`: advances the tree, renders once, and an unchanged frame
      emits zero changed cells; a changed frame emits only those cells.
- [x] `NextFrameDelayMs`: `-1` when idle; otherwise within `[0, TickMs]`.
- [x] `TSpinner`: frame advances with `now` at the interval; two spinners with
      the same origin are in phase; `Animating` is True.
- [x] `TProgress`: determinate renders the right number of eighths at 0/50/100%;
      indeterminate bounces between the inner cells; `Animating` follows
      `Indeterminate`.
- [x] Determinism: the same `ANowMs` sequence yields identical cells.

### Integration Tests

- [x] A panel containing a spinner and a progress bar composites and diffs in one
      frame; only the animated cells change between two ticks.

### Leak Tests

- [x] `make test-leak` clean.

## Performance Targets

- An idle frame (no change) emits zero bytes; the O(cells) diff is the only cost.
- A 100 Hz tick with a single spinner changes one cell per frame.

## Security Considerations

- None new: content is cell text and the encoder sanitizes control characters.

## Success Criteria

### Functional

- [x] All contracts implemented; all validation rules enforced.
- [x] Every acceptance criterion maps to a test; `make check` passes.

### Quality

- [x] No per-widget timers; idle is input-blocked.
- [x] Animations are pure functions of `ANowMs`.

## Implementation Notes

- **`{$codepage utf8}` is required in any unit with non-ASCII string literals**
  (the braille frames, the eighth blocks). Without it FPC stores the literal
  bytes one-per-code-unit and the glyphs render as `?`. The unit directive is
  preferred over `WideChar($XXXX)` for literal-heavy sources.
- **A wrapper widget must forward `Advance`/`Animating`.** The ad-hoc shells in
  the demos silently swallowed their subtree's clock until they were rebased on
  `TSingleChild`. Extend `TSingleChild` (or `TContainer`) rather than wrapping
  `TWidget` by hand.
- `Animating` is the OR across **all planes**, not just the base, so a spinner in
  a modal also keeps the frame clock running.
- FPC cannot give a record parameter a default value, so `TSpinner`/`TProgress`
  expose an `overload` for the attribute.
- **The harness no longer busy-polls.** `tui_agent` used
  `while Step do Sleep(1)` - about 1000 full recomposes per second (a stack
  sample sat in `nanosleep`), roughly 8% CPU while idle, and the per-frame
  managed-cell churn made RSS oscillate (FPC has no GC; that is allocator churn).
  It now runs through `THarnessApp.Run` -> `TTuiApp.Run` with `Busy`, so an idle
  app waits on input (~0% CPU, stable RSS) and only a streaming turn keeps the
  frame cadence.

## Future Considerations

- `TTimeline`/keyframes and easing; `TStatusBar` spinner slot.
- `HILDEGARD_TUI_ANIM_MS` override and a reduce-motion mode.
