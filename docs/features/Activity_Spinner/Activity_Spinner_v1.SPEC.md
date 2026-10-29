# Component Specification: Activity Spinner v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildi.tui.chat` (the stream, the item boxes, the
sparkle), `hildi.tui.chatpanel` (the toolbar state),
`hildi.tui.spinner` (the existing `TSpinner` and its frames).

## Purpose

Replace the pulsing sparkle with a **spinning line** everywhere activity is
shown, hold a live thinking block's height steady once it is past the minimum,
and add the spinner to the **bottom-right of the active box** so a long tool
call shows movement where the work is.

## Requirements

### Functional

- [ ] **The toolbar spinner.** The run-state indicator (`psThinking`, `psTool`)
      draws the **braille spinner frame** for the current time instead of the
      sparkle glyph. It advances every `SpinnerIntervalMs` (90 ms) and stays in
      step with every other spinner (the frame is a pure function of time).
- [ ] **The thinking indicator.** The stream's `ckThinking` row draws the same
      spinner frame. Its `Advance`/`Animating` drive the frame from time, as
      today, but over the spinner frames rather than the sparkle set.
- [ ] **Stable live height.** A live (`FLive`) thought/tool block whose wrapped
      body exceeds `LiveTailLines` shows exactly `LiveTailLines` body rows plus
      the two borders, **including when the tail ends in blank rows**. Today the
      tail is `Rows[Length-LiveTailLines .. High]` and a trailing blank row makes
      the block one row shorter, so it shifts as the stream crosses a blank line.
      The fix pads the tail to `LiveTailLines` when fewer wrapped rows exist.
- [ ] **The box spinner.** An **active** box (a live thought or tool block — the
      long-running command case) draws the spinner at the **bottom-right of its
      border**, in the position the caret occupies when idle. The caret is not
      drawn while the block is live (they share the slot).
- [ ] **One frame source.** `ActivityFrame(ANowMs)` is the single function every
      site uses, so the toolbar, the thinking row, and the box spinners are in
      step by construction.

### Non-Functional

- [ ] No new unit; the frames come from `hildi.tui.spinner`
      (`BrailleFrames`).
- [ ] The frame is a pure function of `ANowMs`; no per-widget timer.
- [ ] Animation registration is unchanged in kind: an active box registers at
      the spinner interval, an idle one does not.
- [ ] `make check` green; no rendering regressions in the existing chat tests.

## Contracts & Interfaces

```pascal
{ hildi.tui.chat }
const
  { The activity spinner's frame interval and frames (the shared source). }
  SpinnerIntervalMs = 90;

{ The spinner frame for time ANowMs. Pure; every activity site uses it, so they
  are in step. }
function ActivityFrame(ANowMs: Int64): UnicodeString;

{ Kept for compatibility with the toolbar, now returning the spinner frame
  (the sparkle is retired). }
function ThinkingSparkle(ANowMs: Int64): UnicodeString;
```

### Behaviour

- `ActivityFrame(ANowMs) = BrailleFrames[(ANowMs div SpinnerIntervalMs) mod
  Length(BrailleFrames)]`.
- `TChatPanel.RenderState` draws `ActivityFrame(FNowMs)` for the animated states
  (the non-animated states keep their icons).
- `TChatItem` (`ckThinking`) draws `ActivityFrame` in its single row.
- A live `ckThought`/`ckTool` box, in `Render`, draws the spinner at
  `(R - 2, B)` — the caret slot — and suppresses the caret.
- `ApplyDisplay`, live branch: build the tail as the last `LiveTailLines`
  wrapped rows, then, while the tail has fewer than `LiveTailLines` rows, pad
  with an empty row **at the top** (so the newest text stays at the bottom and
  the height is constant).

### Data Contracts

- The spinner is a single display column; the box reserves one column at the
  bottom-right (the caret's slot), so the border rule shortens by one there.
- The live tail is exactly `LiveTailLines` rows whenever the body wraps to more
  than `LiveTailLines` rows.

## Architecture

- `ActivityFrame` lives in `chat` (the shared display module) and reads the
  frames from `spinner`.
- The toolbar (`chatpanel`) and the item (`chat`) both call it; neither keeps
  its own frame set.
- The box spinner is drawn by `TChatItem.Render`, which already owns the border
  drawing and the caret slot.

## Validation and error handling

- An empty body renders no spinner (nothing is active).
- A body shorter than `LiveTailLines` shows its rows without padding (nothing to
  stabilise).
- The spinner never widens the box: it occupies the caret's reserved column.

## Testing requirements

### Unit tests (`tests/test_tui_chat.pas`, extended)

- [ ] `TestActivityFrameAdvances`: `ActivityFrame` returns different frames
      `SpinnerIntervalMs` apart and the same frame within one interval; it
      cycles through `BrailleFrames`.
- [ ] `TestLiveThoughtKeepsAStableHeight`: a live block whose tail ends in a
      blank row measures the same height as one whose tail does not.
- [ ] `TestLiveBoxDrawsTheSpinner`: an active (live) thought/tool box renders the
      spinner glyph at the bottom-right; the caret is not drawn.
- [ ] `TestIdleBoxShowsTheCaret`: a settled (not live) collapsible box still
      draws its caret at the bottom-right.
- [ ] `TestThinkingRowDrawsTheSpinner`: the `ckThinking` row renders the current
      spinner frame.

### Regression

- [ ] The existing chat tests (collapsed thought/tool rules, carets, the live
      tail, the thinking indicator) still pass.

## Performance targets

- `ActivityFrame` is O(1); no allocation beyond the returned string.
- A live box re-renders only on a frame change (as today).

## Security considerations

- None: display only.

## Success criteria

- [ ] All contracts implemented; `make check` green.
- [ ] The toolbar, the thinking row, and an active box all show the same spinner
      frame at the same instant.
- [ ] A live thinking block's height does not change when a blank line enters
      its tail.

## Out of scope

- A spinner anywhere other than the toolbar, the thinking row, and an active
  box.
- Changing the settle (a live block still becomes a settled block).
- Configurable frames (the braille set is fixed).
