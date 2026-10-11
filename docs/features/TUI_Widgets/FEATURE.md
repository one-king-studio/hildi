# TUI Widgets

## Overview

A small widget kit on top of TUI Core that makes building screens convenient:
a single-child base to remove composite boilerplate, a themed panel, a focus
model, and the first controls (button, list). It is reusable UI, not application
logic; the Harness UI and the demo can adopt it.

## Problem Statement

TUI Core gives a correct, tested rendering foundation, but composing anything
beyond a leaf is boilerplate: a composite must hand-forward
`Measure`/`Arrange`/`Render`/`HandleEvent`, there is no focus model
(`TContainer.HandleEvent` offers each event to every visible child), no theme
(attributes are literals), and no reusable panel/button/list. The demo carries
its own `TPanel`; each new screen would reinvent the same pieces.

Apply the Ponytail ladder: the four-method widget protocol, the grid layout,
`TScrollContainer`, and the surfaces already exist, so this is a thin layer over
them, not a framework.

## Goals

- Remove composite boilerplate with a single-child base.
- A themed panel (background, optional border/title, padding).
- A focus model: `Tab`/`Shift-Tab` to move, click to focus, and a visible focus
  indicator.
- First controls: a button and a selectable list.
- A theme record so widgets do not hard-code colours.
- Everything testable headlessly with the memory surface and scripted input.

## User Stories

- As a **harness author**, I want to wrap a widget in a panel with a border and
  title by writing one line, so screens are quick to assemble.
- As a **harness author**, I want a composite widget to inherit its child
  plumbing, so I only write what is different.
- As an **operator**, I want `Tab`/`Shift-Tab` and clicking to move focus, with a
  visible indicator, so I can drive the UI from the keyboard or mouse.
- As an **operator**, I want a button and a selectable list, so I can act and
  choose without the app inventing controls.
- As a **harness author**, I want a theme record, so colours live in one place
  and light/dark is a swap.

## Acceptance Criteria

### Functional Requirements

- [x] `TSingleChild` owns one child and forwards `Measure`/`Arrange`/`Render`/
      `HandleEvent` to it; subclasses override only what differs.
- [x] `TPanel` draws a background, an optional border (box-drawing) and title,
      and insets its child by a padding; `Measure` accounts for border/padding.
- [x] `TTheme` maps named roles (base, panel, border, title, text, muted, accent,
      error, success) to `TAttr`; `DarkTheme`/`LightTheme` are provided.
- [x] `TFocusable` exposes `Focused`; `TFocusGroup` cycles focus with `Tab` and
      `Shift-Tab`, focuses on left-click, and routes keys to the focused child.
- [x] `TButton` has a caption and an `OnClick`; `Enter`/`Space` (when focused)
      and a click invoke it.
- [x] `TList` has items and a selected index; `Up`/`Down` move the selection and
      `Enter` activates; it scrolls when placed in a `TScrollContainer`.
- [x] The focused control is visually distinct.

### Non-Functional Requirements

- [x] No new dependency; reuses TUI Core and the encoder.
- [x] Testable headlessly; leak-clean under `make test-leak`; `make check` green.
- [x] Style: `{$mode delphi}{$H+}`, units named `hildegard.helper.tui.*`.

## Success Metrics

### Quantitative

- Every acceptance criterion maps to at least one named fpcunit test.
- A panel with a bordered, titled, padded child renders in one `Render` pass.
- `make check` green.

### Qualitative

- Adding a control is a local change (a `TFocusable` subclass).
- A screen reads declaratively: panels and tracks, no manual forwarding.

## Constraints

### Technical

- Build with FPC 3.3.1, `{$mode delphi}`; keep `make check` green.
- Build only on TUI Core; no terminal dependency in the core units.
- Work on `main`; spec-first, TDD.

### Business / Time

- Operator-requested; unblocks faster screen assembly for the Harness UI.

## Dependencies

### Internal

- `hildegard.helper.tui.base/widget/text/scroll/surface/app` (TUI Core).

### External

- None.

## Risks

- **Focus model creep** (full event dispatch, focus scopes). Mitigation: a flat
  focus group with `Tab`/click only; nested groups are out of scope.
- **Layout vs. padding.** Mitigation: `TPanel` insets its child in `Arrange` and
  reports the inflated size in `Measure`.
- **Theme sprawl.** Mitigation: a fixed role set, no per-widget colours.

## Out of Scope

- Nested/overlapping focus scopes, accelerator keys, tab stops per widget.
- Text input beyond the existing `TPromptLine`.
- A general layout language, borders beyond a single box, shadows.
- Menus, tables, trees, dialogs beyond the existing approval modal.
- Mouse hover, drag-select, clipboard.

## Future Considerations

- `TMenu`, `TTable`, `TTabs`; scrollable focus groups.
- A theme file/loader; per-widget theme overrides.
- Adopting the kit in `tui_demo`/`Harness UI`.

## Notes

- **ICE score: Impact 7, Confidence 8, Ease 7.** High impact for screen
  assembly; high confidence (thin layer over working Core); moderate ease (focus
  routing and list scrolling are the fiddly parts).
