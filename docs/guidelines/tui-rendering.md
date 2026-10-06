# TUI Rendering and Layout Invariants

Hard-won constraints for the widget toolkit (`src/hildegard.helper.tui.*`) and
the app loop. Each one cost real debugging time; check them before changing a
widget's measure/arrange, the chat stack, or the app loop.

## Measure and Arrange must lay children out at the same width

A widget's `Measure(AAvail)` and `Arrange(ABounds)` are separate calls and a
parent may pass a different width to each. If a widget derives its children's
layout width from the *argument* in one and something else in the other, the two
widths disagree and every per-width memo (a block's height, a text block's
wrapped lines) misses on every call.

`TChatStack` did exactly this: `Measure` laid out at `ItemWidth(AAvail.W - 1)`
while `Arrange` used `ItemWidth(ABounds.W)`, so `EnsureLayout` alternated between
item width 78 and 76 and re-measured **every block on every frame**.

The symptom is CPU that scales with the number of blocks:

| blocks | render only | keystroke (layout + render) |
| --- | --- | --- |
| 10 | 0.43 ms | 0.54 ms |
| 200 | 0.46 ms | 4.25 ms |
| 700 | 0.47 ms | **16.06 ms** |

Typing at ~10 keys/s is ~16% CPU; during streaming the app repaints at the tick
rate (100 Hz) and the core saturates — 100% CPU and choppy updates.

**Fix:** lay out at one width. `TChatStack.Measure` uses the stack's own arranged
width (`FBounds.W`) and falls back to `AAvail.W - 1` only before the first
`Arrange`. 16.06 ms → 0.685 ms at 700 blocks.

### The chat window amplified it, not caused it

`TChatStack` releases an off-screen block's rendered layout and rebuilds it on
return. That is only cheap because the height is memoised and the layout does not
re-run. When the width thrashed, `Measure`'s self-clean re-materialised and
**re-parsed every block's markdown** every frame: a layout thrash became a
markdown-parser storm. **A memo that survives a layout release must also survive
a steady-state frame**; if it does not, the release is a regression, not an
optimisation.

## Diagnostics

- `TChatStack.LayoutRuns` — how often the block layout was rebuilt. A steady
  measure/render cycle must not increase it.
  `TestStackLayoutDoesNotThrashAcrossMeasureAndArrange` asserts exactly that.
- `TChatStack.MaterializedCount` — how many blocks hold a rendered layout.
- `TSurfaceMemory.LastFrameChangedCells` — diff locality.
- `sample <pid> <seconds> -f out` (macOS) finds the hot stack. A
  `Measure → Materialize → Rebuild → SetSource → Finish` chain is this bug.
- A quick end-to-end number: build `THarnessApp` over a seeded store, then time
  `Step` at a few chat sizes; the cost must be flat in the block count.

## A comment is not a guard

`TChatStack.ItemWidth` already said *"Measure and Arrange must agree, or the text
layout cache thrashes between two widths"* — and the code still disagreed. When a
comment states an invariant, back it with a diagnostic and a test.

## Never return 0 from a select timeout unless you are about to exit

`0` means "poll without blocking". The session runtime's `NextTimeout` returned
`0` once the idle deadline passed; with a client attached the loop never exits
(the idle-exit condition also requires no clients), so `select` returned
immediately forever and the agent pinned a core at 100%. A client keeps the
runtime up, so it must block there — `RuntimeSelectTimeout` does. The same rule
holds for the TUI loop (see "Never busy-poll a TUI loop" in `HANDOFF.md`): a
blocking wait with a finite timeout, never a 0-delay poll.

## Animation is registered, not discovered

A widget that animates must **register** it: `SetAnimation(intervalMs)` on start
and `ClearAnimation` on stop (`0` unregisters). The app's frame rate is the
fastest registered interval; `Animating` no longer walks the tree. A widget that
reports `Animating = True` but never registers will not be advanced — the walk
was removed deliberately, because it cost a full traversal every frame and forced
one rate (the fastest) on everything.

Registration happens on **discrete state changes only** — a caret gains focus, a
spinner starts, a thinking block is added — never per frame. Register the real
interval: a caret that blinks every 530 ms registers ~250 ms, not the frame
cadence. A widget whose "tree" is large (`TChatStack` and its blocks) keeps an
O(1) count instead of scanning.

The `Animating` hook still exists (a container forwards it, tests assert it), but
it is no longer how the app decides to tick. Focus is an input to registration:
`TTuiApp.Animating` is false while the terminal is unfocused, so a backgrounded
terminal does no work.

## Idle work should be small and infrequent

The TUI's idle loop wakes on a finite timeout (`IdleWaitMs`) so a resize is
noticed and the idle hook runs. Input — and a signal, via `EINTR` — wakes the tty
`select` immediately, so the timeout is not a repaint cadence and can be
generous. Each wake does two `ioctl(TIOCGWINSZ)` calls and an `Animating` walk
over the whole tree, so a 100 ms interval is a steady ~1-2% CPU on a large
conversation for no visible benefit; 250 ms is plenty. If idle CPU matters,
lower the wake rate before adding caches.

## Related

- `HANDOFF.md` — "Lessons learned" has the headlines.
- `docs/guidelines/testing.md` — FPC/FCL test gotchas.
- `docs/features/Process_Split/Chat_Window_v1.SPEC.md` — the layout release and
  the window.
