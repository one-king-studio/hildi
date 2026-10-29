# Animation Clock

## Overview

The TUI drives every widget from one clock: `TTuiApp` wakes on a fixed interval
(`DefaultTickMs`, 10 ms = 100 Hz) whenever *anything* reports `Animating`, and a
widget reports `Animating` by being asked. That is the right shape — one clock,
no per-widget timers — but the rate is fixed at the fastest animation, and the
demand is discovered by walking the tree every frame.

The common idle case is a blinking caret: `TTextEdit.Animating` returns
`FActive` (true whenever the compose box is focused) and the caret blinks every
530 ms. So an idle, focused TUI runs a **100 Hz** loop — a hundred tree walks a
second, each visiting every chat block — to service a **~2 Hz** blink, and a
backgrounded terminal keeps doing it.

This feature makes the clock **demand-driven and focus-aware**: each animation
registers itself and the interval it needs; the clock runs at the fastest
registered interval, or idles when nothing is registered; and focus changes
(compose inactive, terminal unfocused) withdraw the registration.

## Problem Statement

- The tick rate is fixed at the fastest animation (100 Hz), so a 2 Hz caret costs
  ~50× more frames than it needs.
- Demand is discovered by walking the tree (`Animating`), and that walk is
  proportional to the chat's block count; a widget cannot say "I animate every
  250 ms".
- A terminal that has lost OS focus keeps animating and ticking.
- The caret keeps blinking when the compose box is not the focus of interaction
  (a modal is up) and when the terminal is unfocused.

Measured on a 700-block session: the compose caret alone kept the TUI at 100 Hz
and ~1–2% CPU while completely idle. (`TChatStack.LayoutRuns`-style diagnostics
and `sample` confirmed the loop, not a hot path.)

## Decision

**Committed: a demand-driven animation clock with a frame-rate registry, plus
terminal focus reporting.**

- A widget **registers** an animation with the interval it needs, and updates or
  removes it; the app no longer walks the tree to discover demand.
- The clock's frame interval is the **minimum** registered interval (the fastest
  animation), or the idle wait when none is registered.
- **"One clock, no per-widget timers" is preserved.** The registry negotiates the
  clock's *rate*; widgets still derive content as `f(now)` through `Advance`, and
  the app still advances the whole tree once per frame.
- **Focus is an input to registration.** The caret registers only while the
  compose is active and the terminal is focused, and renders as a steady box
  otherwise. Losing terminal focus withdraws all animation.
- **The chat stack stops walking its blocks.** `TChatStack` tracks how many
  blocks animate, so `Animating` is O(1) and `Advance` skips the loop when none
  do — the same registration idea at the one place the "tree" is large.

### Shape (the SPECs formalize it)

```text
registry   TAnimationClock: Register(widget, intervalMs) / Unregister / MinIntervalMs
clock      TTuiApp frame interval = MinIntervalMs, else the idle wait
widgets    caret ~250 ms; thinking sparkle ~30 ms; a live stream ~30 ms
focus      DECSET 1004 -> CSI I / CSI O -> TerminalFocused; unfocused withdraws all
```

## Goals

- The clock runs at the fastest registered animation, not a fixed 100 Hz.
- A widget declares its animation and its interval once; no per-frame tree walk.
- Idle-with-caret ticks at ~4 Hz; a live turn ticks at the sparkle's rate.
- A backgrounded terminal animates nothing (near-zero idle frames).
- The caret is a steady box when the compose is inactive or the terminal is
  unfocused.

## Non-Goals

- Per-widget timers or threads — the single clock stays.
- A general "request a repaint" API beyond the existing `Invalidate`.
- Easing, tweening, or interpolation.
- Mouse-hover or pointer-driven animation.

## User Stories

- As an **operator**, I want the TUI to use almost no CPU when idle and focused,
  so it does not drain the battery while I read.
- As an **operator**, I want a backgrounded terminal to cost nothing.
- As an **operator**, I want the caret to stop blinking when I cannot see it, so
  it is not a distraction and does not keep the machine awake.
- As a **harness author**, I want to declare an animation's rate once, so the
  clock is as fast as the fastest animation and no faster.
- As a **harness author**, I want focus to be an input to animation, so a caret
  or spinner stops when it cannot be seen.

## Acceptance Criteria

### Functional Requirements

- [ ] A widget can register an animation with a frame interval, update the
      interval, and unregister it.
- [ ] The app's frame interval is the minimum registered interval, or the idle
      wait when nothing is registered.
- [ ] The app does not walk the widget tree to discover animation demand.
- [ ] `TChatStack.Animating` is O(1) and `TChatStack.Advance` visits only
      animating blocks (none when there are none), not all blocks.
- [ ] The compose caret registers at a low interval (~250 ms) and only while the
      compose is active.
- [ ] The caret renders as a steady box when the compose is inactive.
- [ ] The terminal's focus is tracked (DECSET 1004); when unfocused, all
      animation is withdrawn and the caret is a steady box.
- [ ] Focus reporting is enabled on entry and disabled on exit, and the input
      decoder yields a focus event for `CSI I` / `CSI O`.

### Non-Functional Requirements

- [ ] One clock; no per-widget timers or threads.
- [ ] Idle CPU (focused, caret only) is materially below the 100 Hz baseline
      (target: a few tenths of a percent).
- [ ] No per-frame walk proportional to the chat's block count.
- [ ] Portability: macOS and Linux, FPC 3.3.1; a terminal without 1004 support
      degrades to "always focused" and behaves as today.
- [ ] `make check` passes (functional tests plus the leak gate).

## Success Metrics

### Quantitative

- Idle TUI CPU (focused, caret only) below 0.5% on a 700-block session.
- Idle TUI CPU with the terminal unfocused near 0%.
- A live turn keeps its current smoothness (the clock still runs at the
  sparkle/stream rate while a turn is in flight).

### Qualitative

- A widget's animation is one registration, not a tree-walk contract.
- Focus behaviour is obvious: nothing animates when nothing can be seen.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- Must preserve the "one clock, no per-widget timers" rule: the registry changes
  the clock's rate, not the model.
- The registry is a small, allocation-light structure; register/unregister must
  be safe from the UI thread (all animation changes are UI-thread events).
- The input decoder and the video surface already own their escape sequences;
  focus reporting extends them rather than adding a new path.

### Business / Time

- No deadline. Work on `main`, TDD-first, one logical commit per step.

## Dependencies

### Internal

- `hildi.tui.clock` — the clock, `MonotonicMs`, `DefaultTickMs`; the
  natural home for the registry.
- `hildi.tui.app` — `Animating`, `NextFrameDelayMs`, `Tick`,
  `AdvanceTree`.
- `hildi.tui.edit` / `.compose` — the caret and its `Active` state.
- `hildi.tui.input.decode` / `.terminal` — the key decoder and the
  tty reader.
- `hildi.tui.surface.video` — terminal control sequences at
  init/teardown.
- `hildi.tui.chat` — the chat stack's block list.

### External

- DECSET 1004 focus reporting (a widely supported xterm extension); no new
  dependency.

## Risks

- **Terminal support for 1004.** Not every terminal implements it. Mitigation:
  treat "no focus event" as focused, so the behaviour is exactly today's.
- **A missed unregister** keeps the clock fast (a CPU cost, not a correctness
  bug). Mitigation: registrations are owned by a widget and withdrawn on
  destroy/state change; a diagnostic can assert the registry is empty at idle.
- **Rate thrash.** An animation that toggles its interval every frame would make
  the clock interval jitter. Mitigation: intervals change on discrete state
  transitions, not per frame; the app clamps the interval.
- **Focus-out during a turn.** A live turn must not stop being served. Mitigation:
  focus-out withdraws *animation*; a busy turn keeps the clock at the stream
  rate regardless.
- **Regression of the caret UX.** A steady box must still read as a caret.
  Mitigation: keep the block glyph, drop only the blink.

## Out of Scope

- Per-widget timers.
- Adaptive animation beyond the registered interval (no frame-rate smoothing).
- Detecting terminal focus by any means other than 1004.
- Windows.

## Future Considerations

- A per-widget "dirty" subscription so `Advance` visits only changed widgets.
- Mouse-driven animation (hover) with its own interval.
- Letting the streaming turn lower its own rate when the model is idle between
  chunks.

## Notes

- **The invariant this rests on:** the animating state changes only on discrete
  events (a block added/removed, a state change, focus in/out), never
  continuously. That is what lets registration replace a per-frame walk.
- **Why the rate, not just a boolean.** A boolean "something animates" still
  forces one rate (the fastest). Carrying the interval lets the common case
  (caret only) run slowly while a turn runs fast.
- **Code facts this rests on** (verified): `TTextEdit.Animating` returns
  `FActive` (default `True`) and `Advance` toggles the caret every 530 ms;
  `TChatStack.Animating`/`Advance` loop every block; `TTuiApp.NextFrameDelayMs`
  returns `FTickMs` while `Animating or FBusy`; the video surface already writes
  terminal control sequences at init/teardown; the decoder switches on the CSI
  final byte.
- **ICE score.** Impact 7 (idle CPU and battery, not throughput), Confidence 8
  (the mechanism is small and the demand is already discrete), Ease 6 (registry
  + decoder + surface + caret, several tests). Priority: medium-high.
- **Related:** `docs/guidelines/tui-rendering.md` (the layout thrash and the
  select-timeout rule found while investigating this).
