# TUI Harness

## Overview

A full-screen interactive terminal UI for hildegard-helper: a composable pane
layout (nested grid of containers), independently scrollable panes, modal
overlays for confirmations and approvals, and markdown-coloured agent text. It
is an **additional** front end; the existing pipe-friendly CLI remains the
default and is not replaced.

The harness already executes shell commands, persists state, and runs a working
agent loop. What it lacks is a live, persistent view: a file/diff viewport beside
a streaming conversation, a status region, and modal prompts, without shelling
out to `$PAGER` or re-running the program. This feature builds the layout and
rendering foundation for that view.

## Problem Statement

The current interface is line-based and defers scrolling to `$PAGER`
(`agent ... | less -R`). That choice was deliberate and stays, because it is pure,
pipeable, and trivially composable. But a coding harness wants a persistent,
reactive view: watch the agent work while keeping a file open, respond to an
approval prompt without losing the transcript, and resize with the terminal.

The terminal-control problem is already solved by the platform: FPC's `video`
unit provides a dynamic cell buffer with a diffing flush, Unicode grapheme cells,
cursor control, raw input via `keyboard`, and resize via `TIOCGWINSZ`. Free
Vision (`fv`) provides a whole widget toolkit, but it is a heavyweight,
overlapping-window, 16-colour model that does not match a modern tiled layout.
`fcl-fpterm` provides a terminal-emulator cell model and a backend seam, but not
widgets, layout, or an editor.

Applying the Ponytail ladder (`docs/guidelines/ponytail.md`): rung 1 ("does it
need to be built at all?") does **not** hold, because the operator explicitly
asked for a TUI. Rungs 3/5 hold for the terminal layer (`video`, `keyboard`), so
we reuse them and design only the gap: a small layout engine, a widget protocol,
a text viewport, scroll containers, modal planes, and markdown colourisation.

> **Decision reversal.** `HANDOFF.md` records "CLI, not TUI... Do not build a TUI
> unless asked." The operator has now asked. This feature is that reversal; the
> CLI is retained, not removed.

## Goals

- Be aware of terminal size and react to size changes.
- Hold nested containers whose grid tracks are sized like CSS grid columns/rows:
  fixed (`10ch`/rows), `auto` (content), and `fill` (remaining space).
- Allow containers to nest as stacks (`auto` rows or `auto` columns) or as
  explicit grids.
- Allow a container to overflow with its own independent scrollbar.
- Provide a basic leaf block that holds text, rendered with the full 256-colour
  palette and correct UTF-8/grapheme-cluster/wide-character handling.
- Provide a modal overlay layer that reuses the same layout/container objects on
  a separate plane.
- Colourise markdown block content through a small mapping from markdown blocks
  and inline spans to text attributes.
- Remain testable without a terminal, by keeping the render target injectable.
- Reuse existing libraries; add no new dependency.

## User Stories

- As a **user**, I want a live pane with the agent conversation beside a file
  viewport, so I can follow the work without leaving the program.
- As a **user**, I want panes to resize with my terminal and scroll
  independently, so long content stays readable.
- As a **user**, I want modal prompts for approvals and confirmations, so I can
  respond to the agent without losing sight of the transcript.
- As a **user**, I want markdown from the model (headings, emphasis, inline code,
  fenced code) rendered with colour, so output is easy to scan.
- As a **harness author**, I want an injectable render surface, so layout, text
  wrapping, and scrolling are unit-tested with no terminal attached.
- As a **harness author**, I want to add a new widget with a local change
  (`Measure`/`Arrange`/`Render`/`HandleEvent`), so the UI can grow without a
  framework rewrite.
- As an **operator**, I want macOS and Linux support with no new dependencies, so
  the helper stays self-contained.

## Acceptance Criteria

### Functional Requirements

Terminal and rendering

- [ ] The UI reads the terminal size at startup and reacts to resize events
      without restarting.
- [ ] All drawing goes through an abstract surface; a concrete surface renders to
      the terminal and an in-memory surface is available for tests.
- [ ] A frame is composed by clearing, drawing the plane stack in order, and
      flushing once; only changed cells reach the terminal.
- [ ] The full 256-colour extended palette is supported: base ANSI colours
      (0..15), the 6x6x6 colour cube (16..231), and greyscale (232..255),
      addressed by palette index. Truecolour is explicitly not required.
- [ ] UTF-8 text is rendered by extended grapheme cluster, and wide (East Asian)
      characters occupy the correct number of columns.

Layout

- [ ] Containers support grid tracks on both axes with kinds `fixed`, `auto`, and
      `fill` (with weights); `auto` resolves to the content's preferred size and
      `fill` shares the remaining space.
- [ ] Contained tracks are expressed in character cells (columns) and rows; a
      `fixed` track is an exact size.
- [ ] Containers nest arbitrarily; a vertical stack is a one-column grid and a
      horizontal stack is a one-row grid of `auto` tracks.
- [ ] Grid gaps (row and column spacing) are supported.
- [ ] Layout is deterministic and independent of render order.

Overflow and scrolling

- [ ] A container whose content exceeds its bounds clips its content and exposes
      an independent scrollbar.
- [ ] Scrolling one container does not affect any other container.
- [ ] A scrollbar reports position and is operable by keyboard; its geometry is
      correct for content smaller than, equal to, and larger than the viewport.

Text

- [ ] A text block renders styled spans (256-colour foreground/background and
      rendition flags) and supports UTF-8.
- [ ] Text wrapping (character and word) measures width by display columns, not
      code units, and is correct across combining marks and wide characters.
- [ ] Text is clipped to the block's bounds.

Modals

- [ ] Modal content is drawn on a separate plane above the base tree, using the
      same widgets and layout.
- [ ] The modal frame is drawn in order: base content first, then a dim effect
      over the rendered background, then the modal on top. The dim must mute the
      base without erasing it, so the main content stays visible underneath the
      overlay.
- [ ] While a modal is present, input is delivered only to the topmost modal.
- [ ] A modal can be dismissed by a key and by returning a result to the caller.

Markdown

- [ ] A supported subset of markdown (headings, paragraphs, lists, blockquotes,
      fenced code, horizontal rules, GFM pipe tables; inline bold, italic, code,
      links) parses to blocks of styled spans.
- [ ] A theme maps block kinds and inline styles to text attributes.
- [ ] A table is drawn at its content width when it fits the container, and
      compresses and wraps its columns when the content is wider.
- [ ] Unsupported syntax renders literally rather than erroring.
- [ ] Incrementally appended text (streaming) does not require re-parsing
      completed blocks.

Demonstration

- [ ] An example program demonstrates a nested layout with at least two
      independently scrolling panes, a modal, and markdown-coloured text, and
      responds to terminal resize.

### Non-Functional Requirements

- [ ] Testability: layout, wrapping, scrolling, and markdown parse are exercised
      by fpcunit tests against an in-memory surface, with no terminal attached.
- [ ] Portability: builds on macOS and Linux with Free Pascal 3.3.1; any threads
      list `cthreads` first on Unix.
- [ ] Reliability: leak-clean under `make test-leak`; the surface and input
      sources are released on every path.
- [ ] Dependencies: no new dependency; uses FPC `video`/`keyboard` and the RTL
      Unicode helpers already present.
- [ ] Performance, verifiable: a full 80x50 repaint is at most 10 ms
      (>= 100 fps) and a one-line content change at most 5 ms (>= 200 fps) on the
      development machine; streaming sustains >= 60 fps. The operator can verify
      these with `make bench`, which prints ms/frame and fps per scenario.
- [ ] Diff locality: a one-line append changes cells only on the affected
      row(s), and an unchanged frame changes zero cells, asserted in `make check`
      (work, not wall-clock, so it cannot flake).
- [ ] No per-frame heap growth at a fixed size beyond a small tolerance.
- [ ] Style: `{$mode delphi}{$H+}`, units named `hildegard.helper.tui.*`.
- [ ] `make check` passes (functional tests plus the leak gate).

## Success Metrics

### Quantitative

- Every acceptance criterion above maps to at least one named fpcunit test.
- The example runs, resizes correctly, and scrolls two panes independently.
- `make check` is green; the leak gate reports no leaks.
- `make bench` prints a table where the `full` scenario is >= 100 fps and the
  `append` scenario is >= 200 fps on the development machine, with a per-frame
  changed-cell count that stays proportional to the change (not the screen).
- A frame for an 80x50 terminal is composed and flushed within the existing test
  suite's time budget (no perceptible cost).

### Qualitative

- Adding a widget is a local change: implement `Measure`/`Arrange`/`Render`/
  `HandleEvent` and drop it into a container.
- The layout is predictable: a track's size is explained by `fixed`/`auto`/`fill`
  alone, with no hidden magic.
- The terminal layer is invisible to widget authors.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- Reuse FPC `video` for the cell buffer, diff flush, cursor, and size, and
  `keyboard` for input. No `crt`/`ncurses` (rejected by this project).
- The render surface must be injectable (an interface) so core logic is testable
  without a terminal.
- `auto` tracks are defined as **max-content** (preferred size); wrapping text
  must live in `fixed` or `fill` tracks. This deliberately avoids CSS's
  fixed-point width/height iteration.
- A scroll container takes its available size (acts as `fill`) and does not
  contribute its content's size upward.
- Work on `main` (no branches, per `HANDOFF.md`); spec-first, TDD.

### Business / Time

- This is an operator-requested capability; it unblocks the interactive harness
  work (editor viewport, chat pane, approval modals) that follows.

## Dependencies

### Internal

- None required for the core; it is a standalone front-end foundation.
- `hildegard.helper.ansi` is **not** reused for rendering: it emits SGR for a
  stream and never buffers or positions the cursor. It remains the CLI's styling
  layer.
- `hildegard.helper.transcript` is CLI-oriented; the TUI is a separate renderer.
- Follow-on (separate specs): `Harness_UI_v1` wires panes to the agent loop;
  `Editor_v1` (if ever) adds an editable text buffer.

### External

- FPC `video` (dynamic enhanced cell buffer, diffing `UpdateScreen`, cursor,
  `TIOCGWINSZ` resize, `StringDisplayWidth`).
- FPC `keyboard` (raw mode and key decoding), RTL `graphemebreakproperty` and
  `eastasianwidth` for cluster/width handling.
- Reference only (not necessarily a dependency): `fcl-fpterm` (`fpterm.base`
  cell/attribute model and `TTerminalView` backend seam) and Free Vision
  (`fv`) as prior art.

## Risks

- **`auto` sizing with nesting.** Intrinsic sizes can depend on allocated sizes,
  which CSS resolves iteratively. Mitigation: define `auto` as max-content and
  require wrapping text to live in `fixed`/`fill` tracks (no fixed-point
  iteration).
- **UTF-8 width correctness.** Byte or code-unit counting breaks wrapping and
  clipping. Mitigation: measure by grapheme cluster with East Asian width, using
  the RTL helpers `video` already relies on; test combining marks and CJK.
- **Scrollbar geometry off-by-ones.** Classic source of bugs. Mitigation: pure,
  table-driven tests for content < viewport, = viewport, > viewport, at both
  ends.
- **Scope creep into an editor/framework.** Full editing, syntax highlighting,
  z-order windows, and mouse are tempting. Mitigation: explicit out-of-scope
  list; `auto`/`fixed`/`fill` only; tiled planes, never overlapping windows.
- **Streaming markdown instability.** A fence or emphasis can be half-received.
  Mitigation: finalise completed blocks and re-parse only the trailing unstable
  block.
- **macOS `video` behaviour.** The unit is present on darwin, but resize and
  cursor details must be calibrated. Mitigation: verify early in the spike and
  record findings in `docs/guidelines/testing.md`.
- **No-terminal testability.** Real-terminal-only design would make TDD
  impossible. Mitigation: the surface interface from day one, with an in-memory
  implementation used by all core tests.

## Out of Scope

- An editable text buffer/editor (hybrid edit mode) - a later component.
- Syntax highlighting beyond markdown's own spans.
- Mouse support (deferred; the input contract leaves room).
- Overlapping windows, z-order, shadows, palette indirection (Free Vision
  features we deliberately do not adopt).
- Multiple simultaneous modals beyond a simple stack (possible, not required).
- Horizontal scrolling in v1 (vertical scroll is the requirement).
- Full CommonMark: reference links, HTML, nested list depth, setext (GFM pipe
  tables are supported by Markdown Tables v1).
- Wiring to the agent loop, approvals, or sessions (a follow-on spec).
- Windows and other non-Unix targets.

## Application: Harness UI (v1)

The toolkit above has no consumer yet; `Harness_UI_v1` is the actual application
that binds it to the agent. It is the TUI counterpart to the CLI and shares the
same configuration and trust model. Agent execution runs off the UI thread so the
interface stays interactive while a turn streams.

### Goals

- A prompt/response loop inside the TUI: type a prompt, submit, watch the answer.
- Live streaming of assistant text and reasoning while a turn runs.
- Tool activity (call, reason, result) shown as labelled lines as it happens.
- Approvals presented as modal dialogs, answered without losing the transcript.
- Durable sessions: workspace, session id, and ledger in the SQLite store, with
  resume; in-memory when no store is configured.
- UI stays responsive (input, scroll, resize) throughout a turn.

### User Stories

- As an **operator**, I want to type a prompt and watch the reply stream in, so I
  can follow the agent without leaving the program.
- As an **operator**, I want to see each tool call, its stated reason, and its
  result as they happen, so I know what the agent is doing.
- As an **operator**, I want to approve or deny a command in a modal, with the
  same once/exact/wildcard/deny choices as the CLI, so the transcript stays
  visible.
- As an **operator**, I want to resume a session and see earlier messages, so I
  can continue prior work.
- As an **operator**, I want to quit at any time (including mid-turn) and have my
  terminal restored, so the TUI is never dangerous to my shell.
- As a **harness author**, I want the agent loop to run off the UI thread behind
  an event queue, so the UI never blocks on the network and stays testable.

### Acceptance Criteria

#### Functional Requirements

Prompt and turn lifecycle

- [ ] A single-line prompt editor accepts typed characters, Backspace/Delete,
      Home/End, and left/right cursor movement; Enter submits the line.
- [ ] Up/Down recalls previously submitted prompts (history).
- [ ] Submitting echoes the prompt into the conversation and starts a turn; the
      prompt editor is disabled until the turn ends.
- [ ] While a turn runs the UI keeps processing input (scroll, resize, quit).
- [ ] Assistant text (and, when present, reasoning) appears incrementally as it
      streams, appended to the conversation, which auto-scrolls to the newest
      line unless the user has scrolled away.
- [ ] Each tool call renders a labelled line with the tool name, the model's
      reason, and its arguments; each result renders a labelled outcome line.
- [ ] When an approval ask arrives, a modal shows the summary and its options;
      choosing an option resolves the ask (persisting the rule per its scope when
      the option persists) and the turn resumes; deny refuses the call.
- [ ] LLM and tool errors render as error lines; the prompt editor re-enables.
- [ ] On completion the final assistant text is in the conversation and the
      prompt editor re-enables.
- [ ] Quitting mid-turn denies any pending ask, stops the worker, joins it, and
      restores the terminal.

Persistence and configuration

- [ ] With a store configured, the workspace is ensured, a session is created (or
      resumed), and every user/assistant/reasoning/tool message is appended to the
      ledger as it occurs.
- [ ] On resume, prior messages are rendered into the conversation before the
      first new turn.
- [ ] With no store, the app runs against an in-memory conversation and
      session-only approvals (never silently disabled).
- [ ] Model, endpoint, workspace, session, and system prompt come from the same
      environment/`.env`/flags resolution the CLI uses.

#### Non-Functional Requirements

- [ ] The UI thread never performs network or blocking I/O; a turn runs on a
      worker thread and communicates only through a thread-safe queue.
- [ ] Input-to-visible latency stays under 50 ms while a turn streams;
      interactive frame rate stays >= 60 fps (measured work, not wall-clock, in
      `make check`; wall-clock via `make bench`).
- [ ] The worker thread is always joined and its objects freed on every exit
      path; leak-clean under `make test-leak`.
- [ ] `cthreads` is listed first in the example program on Unix.
- [ ] Builds on macOS and Linux with FPC 3.3.1; no new dependency.
- [ ] `make check` is green.

### Out of Scope (Harness UI v1)

- Markdown rendering (deferred to `Markdown_v1`, which is spec-only).
- A file/diff viewport pane (a later spec).
- Editing files, an editor buffer, or syntax highlighting.
- Multiple concurrent turns or subagent panes.
- Horizontal scrolling in the conversation.
- The Remote Agent Link.

## Future Considerations

- `Harness_UI_v1`: the real application - conversation pane, file/diff viewport,
  status line, approval modal - bound to `TAgentLoop` (specified in
  `Harness_UI_v1.SPEC.md`). **Implemented.**
- `Chat_Panel_v1`: the designed conversation view (message blocks, overlay
  compose, stats/status lines) bound to `TTurnEvent`, replacing the plain
  transcript (specified in `Chat_Panel_v1.SPEC.md`). **Implemented.**
- Editable text: reuse FPC's gap-buffer editor model (`packages/fv/src/editors`)
  rather than writing one.
- A terminal pane that hosts a real command via a pty, rendering through
  `fcl-fpterm`'s controller on Linux.
- Mouse: click to focus, wheel to scroll (the input contract already allows it).
- Horizontal scroll and tab stops.
- Themes beyond a single small theme record.

## Notes

- **ICE score: Impact 8, Confidence 7, Ease 6.** Impact is high for the
  interactive harness but not for the headless core (the CLI already works).
  Confidence is good because the terminal layer is solved and the hard parts
  (layout, wrap, scroll) are pure and testable. Ease is moderate: the layout
  engine and UTF-8 wrapping carry the genuine effort.
- **Sequencing:** independent of the trust-model and remote-link features. It is
  a foundation for the eventual interactive harness; `Harness_UI_v1` depends on
  it.
- **Reuse note (Ponytail):** `video` covers cell buffer, diff, cursor, and resize;
  `keyboard` covers input decoding. Neither layout nor widgets nor an editor
  exist, so only those are specified. Free Vision would climb past the needed
  rung (whole overlapping-window toolkit for a tiled pane layout).
