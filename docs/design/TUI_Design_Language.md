# TUI Design Language (v0 — first pass)

A reference for the look and feel of hildegard-helper's TUI: which glyphs to use,
how to animate, how to colour, and how to lay out screens. It is exploratory —
the visual source of truth is the companion
[`tui_design_language.html`](tui_design_language.html) (self-contained; open it
in a browser).

This is a **living document**, not a feature spec: the widget kit
(`docs/features/TUI_Widgets/`) is the implementation, and the palette/glyph
choices here feed it.

## 1. Principles

1. **Restrained.** A coding harness is read for hours; prefer structure and
   contrast over decoration. Colour marks meaning, not mood.
2. **Information-dense but legible.** Use the whole terminal; separate regions
   with borders and spacing, not blank lines.
3. **Keyboard first, mouse supported.** Every action reachable with keys;
   focus is always visible.
4. **256 colours, not truecolour.** FPC `video` tops out at palette indices; the
   design uses indices 0–255.
5. **Grapheme- and width-aware.** Wide (CJK) and combining clusters are first
   class; never assume one code point = one column.
6. **Sanitized.** Untrusted text (model/command/file output) is rendered as
   cells; control characters become `U+FFFD` at the encoder.
7. **Degrade gracefully.** If a glyph is missing (fonts, Nerd Font absent), the
   fallback must still be readable.

## 2. Glyphs

### 2.1 Box drawing (U+2500–U+257F)

| Family | Chars | Use |
| --- | --- | --- |
| Light | `─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼` | default panel/box borders |
| Heavy | `━ ┃ ┏ ┓ ┗ ┛ ┣ ┫ ┳ ┻ ╋` | emphasis, active pane |
| Double | `═ ║ ╔ ╗ ╚ ╝ ╠ ╣ ╦ ╩ ╬` | rare; modal headline |
| Rounded | `╭ ╮ ╰ ╯` | softer panels (mixed with light) |
| Dashed | `┄ ┅ ┈ ┉` | separators, “placeholder” regions |

Rule: one border weight per nesting level; don’t mix light and heavy in the same
frame.

### 2.2 Blocks and bars (U+2580–U+259F)

- Full/partial: `█ ▉ ▊ ▋ ▌ ▍ ▎ ▏` — horizontal progress with 1/8 resolution.
- Shades: `░ ▒ ▓` — dim fills, disabled regions, heat.
- Vertical eighths: `▁ ▂ ▃ ▄ ▅ ▆ ▇` — sparklines / level meters.
- Quadrants: `▖ ▘ ▝ ▗ ▙ ▟` — small inline indicators.

### 2.3 Symbols

- Arrows: `← ↑ → ↓ ▲ ▼ ◀ ▶ ‹ › « »`
- Bullets: `• ◦ ‣ · ∙`
- Status: `✓ ✗ ✔ ✘ ☐ ☑ ☒ ⚠ ℹ`
- Chevrons/pointers: `❯ ›` (prompt, list cursor)

**Avoid** for layout-critical UI: emoji (ambiguous width), Nerd Font icons
(absent font), and box drawing beyond the common BMP ranges. They are fine inside
free-flowing text where a wrong width only shifts that line.

### 2.4 Spinners and motion

| Name | Frames | Notes |
| --- | --- | --- |
| Braille | `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` | smooth, single cell, widely supported |
| Braille dots | `⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷` | denser |
| Line | `\| / - \\` | ASCII fallback |
| Arc | `◜ ◝ ◞ ◟` | subtle |
| Circle | `◐ ◓ ◑ ◒` | two-tone |
| Pulse | `▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ▇ ▆ ▅ ▄ ▃ ▂` | activity/heartbeat |
| Bounce | `[▁▂▃▄▅▆▇█]` with a moving block | progress-unknown |
| Bar | `█▉▊▋▌▍▎▏` | determinate progress |

Cadence: **~80–120 ms/frame**. One timer for the whole app, paused when the
window is not visible; a spinner must not force a full repaint beyond its cell.

## 3. Colour

### 3.1 The 256 palette

- `0–15` — base ANSI colours; terminal themes remap these, so they are the most
  portable but least predictable.
- `16–231` — 6×6×6 cube: `16 + 36r + 6g + b`, each channel 0–5.
- `232–255` — greyscale ramp, `232 + 10·n`.

Design rules:
- Prefer the **cube and greyscale** for a stable look across terminals; use base
  0–15 only for semantic red/green/yellow when you accept theme remapping.
- Backgrounds from the greyscale ramp (`234–238`) keep a dark UI consistent.
- Keep body text at a high-contrast index (e.g. `252`) and reserve saturated
  colour for emphasis.

### 3.2 Semantic roles (mirrors `TTheme`)

| Role | Purpose | Dark (index) | Light (index) |
| --- | --- | --- | --- |
| Base | screen background | 234 | 255 |
| Panel | panel/box fill | 236 | 254 |
| Border | frame | 240 | 245 |
| Title | panel titles | 81 | 25 |
| Text | primary | 252 | 235 |
| Muted | secondary/hints | 244 | 244 |
| Accent | focus/selection | 81 | 25 |
| Error | failures | 203 | 160 |
| Success | success | 114 | 28 |

### 3.3 Contrast and accessibility

- Never encode meaning in colour alone: pair it with a glyph (`✓`/`✗`) or weight.
- Assume colour-blind users; red/green carry `✓`/`✗`.
- Honour `NO_COLOR`/dumb terminals by falling back to bold/reverse.

## 4. Layout

### 4.1 The grid

Tracks are `fixed` (exact cells), `auto` (max-content), `fill` (weighted share).
A vertical stack is a one-column grid; a horizontal stack a one-row grid. Gaps
space tracks; nesting composes screens.

```
┌─ Header (fixed 1) ────────────────────────────────┐
├─ Main (fill) ────────────────┬─ Sidebar (fixed 30) ┤
│  scrollable conversation     │  file / details     │
├─ Status (fixed 1) ───────────┴─────────────────────┤
└─ Prompt (fixed 1) ─────────────────────────────────┘
```

### 4.2 Panels

A panel = background + optional border + title + padding. Padding is 1 cell by
default; the title sits in the top border, inset by one space.

```
╭─ Files ──────────────╮
│ alpha.txt            │
│ beta.txt             │
╰──────────────────────╯
```

### 4.3 Text and overflow

- **Clip by default**; wrapping is a container concern (deferred).
- Truncate with `…` when a single-line value must not clip mid-word.
- Right-align numbers; left-align prose; keep columns of a table consistent.

### 4.4 Focus and selection

- Focus: reverse video (portable) and/or the accent colour; a `❯` cursor in
  lists. Never rely on colour alone.
- Selection in a list: accent foreground; the focused list also reverses the
  selected row.
- One focused control at a time per focus group; `Tab`/`Shift-Tab` cycle,
  click focuses.

## 5. Components

| Component | Status | Notes |
| --- | --- | --- |
| `TPanel` | implemented | border/title/padding |
| `TTextBlock` | implemented | styled spans, clip/opt-in wrap |
| `TScrollContainer` | implemented | clip + wheel/drag scrollbar |
| `TPromptLine` | implemented | single-line editor, history |
| `TConversationView` | implemented | sticky-to-bottom transcript |
| `TApprovalModal` | implemented | option list + scope |
| `TListView` | implemented | selection + activate |
| `TButton` | implemented | focus + click |
| `TFocusGroup` | implemented | Tab/click focus |
| `TStatusBar` | proposed | left/right segments, spinner slot |
| `TTabs` | proposed | tab strip + content |
| `TTable` | proposed | columns, alignment, scroll |
| `TSpinner` | proposed | frame set + cadence |
| `TProgress` | proposed | determinate bar (eighths) |

## 6. Motion and state

- **Busy**: spinner in the status bar and/or the pane title; never block input.
- **Streaming**: append text; do not animate the transcript.
- **Transient**: a one-line toast/status for success/error, auto-clearing.
- **Idle**: no animation at all (save CPU/battery).

### 6.1 The frame clock and timelines

There is one clock, owned by the app, and no per-widget timers. The app advances
every widget each frame (`Advance(nowMs)`), composites once, and diffs once; only
changed cells reach the terminal.

- **Cadence** is a property of the app (`TickMs`, default **10 ms / 100 Hz**),
  not of a widget. A widget only *derives* its content from the frame time:
  `frame = f(nowMs)` (a spinner uses `((now - origin) div IntervalMs) mod N`, so
  two spinners advanced together stay in step).
- **Idle means silent.** A widget reports `Animating`; when nothing animates the
  app stops scheduling frames and waits on input (a long timeout, since
  `IInputSource.Wait` has no blocking form) instead of waking at the frame rate.
  "100 Hz" is a ceiling while motion is on screen, not a forced refresh.
- **Composite once.** Each frame advances the tree, then clears, renders the
  planes, dims, renders modals, and flushes once; the encoder writes only changed
  cells.
- **Timelines are functions of time.** An animation is `value = f(nowMs)` (or a
  keyframe list sampled by time). No easing engine is required in v1; a timeline
  helper can come later.
- **Determinism.** Because everything is a function of `nowMs`, tests advance a
  synthetic clock and assert exact cells — no wall-clock waits.
- **Cost.** An unchanged frame emits zero bytes; a spinner changes one cell per
  frame. The only per-frame work is the O(cells) diff (~4k cells at 80×50).

| Animation | Typical interval | Notes |
| --- | --- | --- |
| Spinner | 90 ms | one cell; braille preferred, line fallback |
| Progress (indeterminate) | 90 ms | one block bouncing, margin at each end |
| Progress (determinate) | on change | not time-based; repaint when `Value` changes |
| Status/toast | 300 ms | coarse; auto-clears |

## 7. Implementation notes

- Glyph and colour choices map to `TAttr` and cell text; the encoder sanitizes
  control characters and positions absolutely.
- Wide clusters occupy two columns; the layout must not place a glyph in the
  trailing cell.
- A spinner is just a one-cell text block whose content changes on a timer; keep
  it out of the diff when unchanged.
- **Rendering the docs:** the diagrams assume one monospace font that covers the
  box-drawing range (U+2500–U+257F), ligatures disabled, and whitespace
  preserved; the HTML companion enforces this in CSS.

## 8. Open questions

- Do we ship a glyph capability probe (query the font/terminal) or assume the
  common BMP set?
- Should animation be globally disableable (`HILDEGARD_TUI_NO_ANIM=1`)?
- Light theme: is a full light palette worth maintaining, or a single dark one?
- Status bar vs. per-pane status: which scales better for many panes?
