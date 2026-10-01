# TUI Animation

## Overview

A single, app-owned **frame clock** that drives all time-based UI. Widgets stop
owning timers and instead derive their content from the current frame time;
every frame the app advances the widget tree, composites it, diffs it, and writes
only what changed. Animations become pure functions of the clock, so any timeline
can be expressed against one frequency and stays deterministic and testable.

## Problem Statement

Today the TUI is purely event-driven: the app processes one input event per
`Step` and renders, and the example loops spin at `Sleep(1)`. There is no shared
notion of time, so a spinner would need its own timer — many widgets animating
means many timers that drift apart, wake the CPU independently, and are hard to
test. A busy UI should repaint on one rhythm; an idle UI should repaint only when
something changes.

Apply the Ponytail ladder: the surface, the encoder diff, and the input source
(with `Wait(timeout)`) already exist, so this is a thin clock plus a widget hook,
not a new rendering model.

## Goals

- One monotonic frame clock owned by the app; no per-widget timers.
- Widgets update from time via `Advance(ANowMs)` and report `Animating`.
- One composite + diff + flush per frame; unchanged frames emit nothing.
- Idle never wakes at a frame rate: wait on input indefinitely when nothing
  animates.
- Animations are pure functions of time (a timeline), so they are deterministic
  and unit-testable.
- First clients: a spinner and a progress bar; adopt in the demos.

## User Stories

- As an **operator**, I want spinners and progress to animate smoothly and in
  step, without the UI pegging a core.
- As a **harness author**, I want to write an animation as a function of time
  (frame = f(now)), so it is easy to reason about and test.
- As a **harness author**, I want the app to sleep when nothing is animating, so
  an idle harness costs nothing.
- As a **tester**, I want to advance time explicitly, so animations are asserted
  without wall-clock waits.

## Acceptance Criteria

### Functional Requirements

- [x] `TTuiApp` owns a monotonic clock and a configurable tick period (default
      10 ms / 100 Hz).
- [x] Each frame calls `Advance(ANowMs)` on the root, which forwards to the whole
      tree.
- [x] `TWidget.Animating` reports whether any time-based content is active;
      `TTuiApp` uses it to decide whether to schedule the next frame.
- [x] The app waits on input to the next frame while animating, and on a long idle
      timeout when idle.
- [x] A frame composites all planes and flushes once; the encoder writes only
      changed cells.
- [x] `TSpinner` renders a frame set at a configurable interval from the clock.
- [x] `TProgress` renders determinate (eighths) and indeterminate (bounce)
      progress from the clock.
- [x] `Tick(ANowMs)` lets tests advance time deterministically; no test waits on
      the wall clock.
- [x] The demos use the clock and a spinner/progress.

### Non-Functional Requirements

- [x] No per-widget timers; exactly one clock and one frame cadence.
- [x] An idle app makes no periodic wakeups at the frame rate.
- [x] Deterministic tests; leak-clean under `make test-leak`; `make check` green.
- [x] No new dependency; style `{$mode delphi}{$H+}`, `hildegard.helper.tui.*`.

## Success Metrics

### Quantitative

- Every acceptance criterion maps to a named fpcunit test.
- An unchanged frame emits zero bytes; a one-frame spinner change emits one cell.
- `make check` green; `make perf` budgets still met.

### Qualitative

- An animation reads as `f(now)`; there is no timer bookkeeping.
- Adding a time-based widget is a local change (`Advance` + `Animating`).

## Constraints

### Technical

- Build with FPC 3.3.1, `{$mode delphi}`; keep `make check` green.
- Reuse `IInputSource.Wait`, `ISurface`, and the encoder; no terminal dependency
  in the core units.
- Work on `main`; spec-first, TDD.

### Business / Time

- Operator-requested; unblocks spinners/status and future motion.

## Dependencies

### Internal

- `hildegard.helper.tui.app` (`TTuiApp`), `.widget` (`TWidget`/`TContainer`),
  `.surface`, `.input`, and the widget kit (`theme`, `panel`, `focus`).

### External

- A monotonic clock: RTL `unix.fpgettimeofday` (or `clock_gettime`).

## Risks

- **Clock drift / platform time.** Mitigation: a monotonic source; wall-clock
  time is never used for animation.
- **Busy-wake.** Mitigation: `Animating` gates the frame timeout; idle blocks.
- **Timeline sprawl.** Mitigation: v1 is frame selection from time; a keyframe
  helper is deferred.

## Out of Scope

- A keyframe/easing library and declarative timelines (v1: `f(now)` functions).
- Frame-accurate physics, spring/tween engines, transitions between layouts.
- Partial-region invalidation beyond the encoder's cell diff.
- Rewriting the agent loop to use the clock (the harness UI can later).

## Future Considerations

- `TTimeline`/keyframes and easing helpers.
- `TStatusBar` with a spinner slot; `TTabs`, `TTable`.
- A global `HILDEGARD_TUI_ANIM_MS` override and a "reduce motion" mode.

## Notes

- **ICE score: Impact 6, Confidence 8, Ease 8.** Moderate impact (unblocks
  motion), high confidence (thin layer over working parts), high ease.
