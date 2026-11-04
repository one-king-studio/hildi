# TUI Web Components: a visual twin, not a render path

**Status:** Idea, documented. Not scheduled, not implemented.
**Related:** [TUI Design Language](../design/tui_design_language.html),
[TUI Library](../features/TUI_Library/FEATURE.md),
`src/tui/widgets/`, [tui-rendering.md](../guidelines/tui-rendering.md)

## The idea in one line

Give the TUI components a **parallel web-component representation** — `<tui-modal>`,
`<tui-panel>`, `<tui-list>` — so the design language can be viewed, edited and
discussed without a terminal, and changes can be ported back to Pascal.

## What the design doc is today

`docs/design/tui_design_language.html` is 930 lines of raw styled HTML. Its
"mocks" are not representations of widgets; they are **box-drawing characters
typed into `<pre>` blocks**, with colour applied by spans:

```html
<div class="mock"><span class="b">╭─</span><span class="t"> Panel </span>…</div>
```

| Class | Count |
| --- | --- |
| `.card` | 45 |
| `.mock` | 23 |
| `.m` | 14 |
| `.note`, `.legend` | 11 each |
| `.bar` | 10 |

Nothing in it corresponds to a widget in `src/tui/widgets/`. It is a picture of a
screen, not a model of one. Consequences:

- **Every change is re-typed.** Adding a row to a dialog means editing glyphs by
  hand in two places — the Pascal and the `<pre>`.
- **It drifts silently.** There is no mechanism connecting the doc to the code,
  so a widget change leaves the doc wrong with nothing to notice.
- **It cannot be interactive.** A hover or a selected row is a fixed span, not a
  state you can put the picture into.
- **Box-drawing alignment is manual.** The classes do disable ligatures and
  kerning so columns line up, which is correct — and a great deal of care spent
  on making typed art into a grid.

## The proposal

Define a small set of custom elements, one per TUI component class, that render
the way their Pascal counterparts do:

| Pascal | Web component | Renders |
| --- | --- | --- |
| `TModal` | `<tui-modal>` | frame, title, 80% cap, heavy bottom edge, CTA footer |
| `TPanel` | `<tui-panel>` | border, optional title, padding |
| `TListView` | `<tui-list>` | rows, selection, focus ring |
| `TScrollContainer` | `<tui-scroll>` | viewport, thumbs on the border |
| `TButton` | `<tui-button>` | caption, focus, pressed |
| `TTextBlock` | `<tui-text>` | spans, wrap mode, alignment |

Then the design doc becomes:

```html
<tui-modal title="Approval needed">
  <tui-text slot="body">rm -rf /tmp/scratch</tui-text>
  <tui-cta slot="footer" key="enter" action="accept" accent></tui-cta>
</tui-modal>
```

State is an attribute, not a frozen picture: `selected="2"`, `hovered="3"`,
`focused="true"`. The same markup shows a widget in any state by changing a value.

## Two different things that are easy to confuse

This is the distinction that matters, because I conflated them earlier:

**1. A generated surface dump** (a `THtmlSurface` implementing `ISurface`).
Takes a real widget tree, renders it, and emits HTML from the resulting cell
grid. *Implementation-first.* Faithful by construction — it cannot disagree with
the code, because it *is* the code's output. But it is a screenshot: no
components, no reuse, no editing. Good for "what does this actually look like at
80 columns".

**2. A hand-authored component kit** (this document). Web components that mirror
the TUI classes. *Design-first.* Composable, editable, stateful, and it can be
written before the Pascal exists. But it can disagree with the implementation,
because it is a second description of the same thing.

They are complementary, not alternatives, and the second is what this note is
about. If both are ever built, the generated dump is the natural way to *check*
the component kit — render the same widget both ways and diff.

## What this is not

**Not HTML in the render path.** `ISurface` remains the only thing widgets draw
into; `TSurfaceVideo` and `TSurfaceMemory` remain its implementations. The web
components are a separate representation used for design and discussion. Nothing
in `src/tui/` imports, emits or depends on HTML.

**Not a replacement for the terminal.** A terminal is where the thing runs. This
is a way to look at it without one.

**Not generated from the feature index.** It would be hand-maintained, with the
same drift risk the current doc has — unless the generated dump exists to check
it against.

## Why the library extraction makes it tractable

The class vocabulary is now stable and legible, which it was not before:

- one class per concept, in a flat list of 17 widget units
- a shallow hierarchy — `TWidget`, `TModal`, `TSingleChild`, `TFocusable` — that
  maps cleanly onto a component tree
- a `TTheme` record of named colour roles (`Base`, `Panel`, `Border`, `Text`,
  `Muted`, `Accent`, `AccentSoft`, `Warn`), which becomes CSS custom properties
  with no translation layer
- the Hildi-specific dialogs have moved out, so the doc would describe the
  *library's* vocabulary rather than one application's screens

A `TTheme` role is already almost a CSS variable. That is the whole mapping.

## Porting, both directions

**Design → code.** Lay out a dialog in components, look at it, then implement
the Pascal to match. Faster than typing box-drawing into a `<pre>` and guessing
how it looks in a terminal.

**Code → design.** When a widget changes, update its component. The doc stays a
description of what exists rather than a snapshot of what once did.

Neither direction is automatic without the generated dump, which is the honest
limitation.

## Costs and risks

- **A second description of the same thing.** This is the real cost. The
  component kit can drift exactly like the `<pre>` mocks do, and having a nicer
  vocabulary does not fix that — only a check does.
- **Box-drawing fidelity.** Terminal cells are rectangular and monospace; the web
  is not. Every component needs `font-variant-ligatures:none`, `font-kerning:none`
  and explicit column widths, or the frame edges will not meet. The existing doc
  already does this, and it was clearly hard-won.
- **Wide-character and combining-mark behaviour** would have to be reproduced in
  CSS to be faithful, which is somewhere between fiddly and impossible.
- **Nobody asked for it yet.** It is a design tool, and design tools become
  liabilities when the design settles.

## What I would build first, if asked

Not the whole kit. One dialog — `TModal` — and one row-list, because those two
carry the most layout risk and the most operator-facing change. If those two map
cleanly, the rest follow; if they do not, the idea is wrong and cost three
hundred lines to find out.

## Notes

**ICE score: Impact 5, Confidence 6, Ease 6.**

Impact is real but indirect — it makes visual review possible without a terminal,
which is the gap that has produced every visual defect in the TUI work so far.
Confidence is moderate because the drift risk is genuine. Ease is moderate: the
theme mapping is trivial, the cell arithmetic in CSS is not.

Worth doing after the TUI library lands and selection is finished, when the
widget vocabulary has stopped moving.
