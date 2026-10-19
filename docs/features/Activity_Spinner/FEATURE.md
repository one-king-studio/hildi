# Activity Spinner

## Overview

Show activity with a **spinning line** rather than a pulsing sparkle, in all
three places the harness indicates work: the toolbar run-state, the thinking
row, and the **bottom-right of an active block** — so a long tool call (a slow
`run_command`) shows movement where the work is, not only in the toolbar.

It also stops a live thinking block from **changing height** as it streams: the
tail is padded to a constant row count, so a blank line entering the tail no
longer shrinks the box.

## Problem Statement

Two display problems, both about *seeing* that work is happening:

1. **The sparkle reads as decoration, not progress.** The thinking indicator
   cycles a burst glyph (`∙ • ● ◉ ❂ ✴ …`) every 90 ms. A burst that grows and
   fades reads as a pulse; a spinner reads as *working*. The project already has
   a `TSpinner` with braille frames — the sparkle predates it and the two
   coexist.
2. **A long tool call shows no motion where it is happening.** While a tool
   runs, the toolbar says `running run_command` and animates, but the tool's own
   block — the thing the operator is watching — sits still. A slow command looks
   frozen in the place it matters.

And one layout problem:

3. **A live thinking block shifts as it streams.** The live tail is the last
   `LiveTailLines` (6) wrapped rows. When the tail ends in a blank row — a
   paragraph break arriving mid-stream — the block renders one row shorter and
   the box jumps. The height should be constant once the body is past the
   minimum.

## Decision

**One frame function, three call sites.** `ActivityFrame(ANowMs)` returns the
braille spinner frame for the time; the toolbar, the thinking row, and an active
box all call it, so they are in step by construction and no site keeps its own
frame set. The sparkle is retired.

**The active box shows the spinner in its caret slot.** An active (live)
thought/tool box draws the spinner at the bottom-right of its border, the column
the caret occupies when the block is settled. They are mutually exclusive: a
live block is not toggleable, so it has no caret to show.

**A live block's tail is padded to a constant height.** Past the minimum, the
tail is exactly `LiveTailLines` rows, padded at the top, so the newest text
stays at the bottom and the height does not move.

## Goals

- Every activity indicator is the same spinner, in step.
- An active block shows the spinner at its bottom-right.
- A live block's height is constant once past the minimum.
- No new dependency; the frames are the existing `BrailleFrames`.

## Non-Goals

- **Not a general spinner widget rollout.** The `TSpinner` widget stays as it is;
  this changes the chat surface's indicators.
- **Not a change to when blocks settle.** A live block still becomes a settled,
  toggleable block.
- **Not configurable frames.** The braille set is fixed (with the ASCII
  `LineFrames` already available in the unit, unused here).
- **Not the toolbar icons.** `psReady`/`psApproval`/`psError`/`psInterrupt` keep
  their static glyphs.

## User Stories

- As an **operator**, I want a long command to show a spinner on its own block,
  so I can tell it is still running without looking at the toolbar.
- As an **operator**, I want the thinking block to stop jumping as it streams,
  so I can read it.
- As a **reviewer**, I want one frame source, so the indicators cannot drift out
  of step.

## Acceptance Criteria

- [ ] The toolbar run-state, the thinking row, and an active box show the same
      spinner frame at the same instant.
- [ ] A live thought/tool block shows exactly `LiveTailLines` body rows when its
      body is longer, regardless of trailing blank rows.
- [ ] An active box draws the spinner at its bottom-right; a settled box draws
      its caret there.
- [ ] The sparkle glyphs are no longer drawn anywhere.
- [ ] `make check` green.

## Success Metrics

- The three indicators are pixel-identical in the frame they show.
- A live block's measured height is constant across a blank line entering the
  tail.

## Constraints

- FPC 3.3.1; no new unit or dependency.
- The frame is a pure function of time (the virtual frame clock).
