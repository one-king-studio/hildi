# TUI Core v1 — Specification

**Status:** Implemented.
**Feature:** [TUI Harness](../TUI_Harness/FEATURE.md) · [TUI Widgets](../TUI_Widgets/FEATURE.md)

## Purpose

Split the TUI toolkit into two directories that mirror `src/shell/` and
`src/async/`, where the **directory is the unit namespace**. The split encodes a
purity boundary that was previously only a convention:

- `src/tui/core/` — pure substrate. No widget-kit dependency, no harness
  dependency. Reusable by anything.
- `src/tui/widgets/` — composite components. May depend on core and on harness
  units.

This spec documents the split as implemented, including the two defects the
move exposed.

## Naming

| Directory | Unit namespace | Example |
| --- | --- | --- |
| `src/tui/core/` | `tui.*` | `tui.base`, `tui.surface`, `tui.widget` |
| `src/tui/widgets/` | `tui.widgets.*` | `tui.widgets.panel`, `tui.widgets.chatpanel` |

Core keeps the `tui.*` names it already had, so the 14 core unit names stay
stable for consumers. Only the 19 widget units are renamed. Renaming all 33 was
rejected as churn with no benefit: a consumer importing `tui.base` learns
nothing from it being called `tui.core.base`.

This matches `src/changes/` (`changes.store`) and `src/fileignore/`
(`fileignore.rules`), which also carry the directory as a prefix.

## Membership

**Core (14)** — `app`, `base`, `clock`, `compact`, `encoder`, `grapheme`,
`input`, `input.decode`, `input.fd`, `input.terminal`, `surface`,
`surface.video`, `theme`, `widget`.

Dependency-verified acyclic: each depends only on other core units. Leaves are
`base`, `clock`, `compact`, `grapheme`, `input.fd`. `widget` requires
`base clock input surface`.

**Widgets (19)** — `actions`, `approvalmodal`, `button`, `chat`, `chatpanel`,
`compose`, `edit`, `focus`, `list`, `markdownview`, `palette`, `panel`,
`progress`, `prompt`, `scroll`, `sessionsmodal`, `sidebar`, `spinner`, `text`.

Five of these reach into the harness, and that is *why* they are not core:
`approvalmodal` → `approval`; `chat`, `markdownview` → `markdown`;
`palette` → `fuzzy`; `sessionsmodal` → `fuzzy`, `session`;
`sidebar` → `harness.subagent`.

## Requirement: the purity proof

`make tui-standalone` must compile and run
`examples/tui_standalone.pas` with **only `-Fu$(SRC)/tui/core`** on the search
path. If any core unit reaches into the widget kit or the harness, that build
fails. This is the same gate `shell-standalone` and `changes-standalone` apply.

The program is a behaviour check as well as a link check: it renders a widget
into `TSurfaceMemory` and asserts the resulting cells.

**Invariant asserted, not assumed:** every theme role carries `sfScreenBg`
rather than its own `Bg`; the palette index arrives from `SetScreenBg` at paint
time. An earlier draft asserted `Theme.Base.Bg = Theme.Bg` and failed, because
`MakeAttr` starts from `DefaultAttr`.

## Requirement: boundary tests must not silently pass


`tests/test_split.pas` resolves units by path. Before this change it knew only
`src/<unit>.pas` and `src/async/<unit>.pas`. After the move, every TUI unit
became unresolvable — and `CollectClosure` **stops** at a missing file, so all
three boundary assertions would have passed on a truncated closure while
checking nothing. Green, and worthless.

Two requirements follow:

1. `UnitPath` resolves the library subdirectories (`async`, `shell`, `changes`,
   `fileignore`, `tui/core`, `tui/widgets`).
2. `TestEveryLibraryUnitIsResolvable` asserts that every `.pas` file in every
   library directory resolves back to its own path. This turns the silent-drift
   failure into a red test.

## Requirement: no behavioural regression

The failing-test set must be **identical to the pre-change baseline at the same
commit**, not merely equal in count. Verified by building a pristine worktree at
`dad0e6a` and diffing the failing test names: 36 failures before, 36 after,
identical names. The 36 are pre-existing intra-process pollution, documented on
the board; this change neither fixes nor worsens them.

## Build changes

`LIB_SRCS := $(wildcard $(SRC)/*.pas)` does not recurse, so the moved units are
invisible to it. Every compile line gains
`-Fu$(SRC)/tui/core -Fu$(SRC)/tui/widgets`. `TUILIB_SRCS` is added for target
dependencies.

## Out of scope

- **Fixing the pollution.** 36 failures are routed around, not repaired.
- **`markdown`/`fuzzy` placement.** `hildi.markdown` depends on
  `tui.base`, a layering inversion: a "helper" unit sitting below the UI
  library. Both belong in core or a sibling text library, but moving them is a
  separate change with its own blast radius.
- **Historical docs.** 258 references in `.SPEC.md`/`.DONE.md`/`.TODO.md` files
  correctly describe their moment and are left alone.

## Deviation

Implementation preceded this spec. The repo's workflow requires the spec first;
the split was performed on explicit operator instruction and the spec written
afterwards. Recorded rather than hidden.
