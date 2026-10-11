# Session Management

## Overview

A `/sessions` command that opens a modal over the Harness TUI listing the
sessions of the current workspace, with search, and the ability to name, pin,
and delete/archive a session. Paired with it: **generated titles**, so a session
is identified by a human-readable name instead of a hex id.

The two are one feature because the modal is useless without something to
distinguish rows by. A session today is only its 32-hex id (the header shows the
first 12 characters). The list needs a title, and the cheapest source of a title
is the model itself: every assistant reply is markdown, and a reply that leads
with an H1 (`# …`) hands us a title for free — no extra tool call, no separate
summarizer model.

## Problem Statement

The harness can create many sessions in a workspace but gives the operator no way
to see or manage them.

- **They are invisible.** `Store.ListSessions` exists and is exercised, but
  nothing in the TUI calls it. A returning operator has no list; they get the
  most recent session or nothing.
- **They are unidentifiable.** A session is a random 128-bit id rendered as
  `Copy(Id, 1, 12)` in the header. Two sessions in the same workspace are
  indistinguishable at a glance, and a session's *subject* is not recorded
  anywhere a human reads.
- **They cannot be managed.** There is no rename, no pin, no archive/delete from
  the UI. Nothing lets an operator say "keep this one, drop that one".

The cost is that sessions accumulate as anonymous, unpruned history. The value
the ledger already stores (who asked what, and what came back) is inaccessible
because there is no index into it.

Applying the Ponytail ladder before proposing anything:

- **Rung 1 — does this need building?** The *modal* is a thin surface over APIs
  that already exist; the *title* is the only genuinely new behaviour, and the
  rest is a small schema addition. The title is what makes the modal worth
  building, so both belong together. Justified.
- **Rung 2 — does it already exist here?** Substantially. `TSqliteStore` already
  has `ListSessions` (newest-updated first), `TouchSession`, `SessionLineage`,
  `ChildrenOf`, `sessions.updated_at`, and a `label` column on `sessions` (added
  by migration v4 for subagents). The TUI already has `TCommandPalette`,
  `TListView`, the modal-plane mechanism (`TTuiApp.PushPlane`/`TPlane` with
  `DimBackground`), and `TApprovalModal` as the modal design precedent. The
  command registry is `THarnessApp.DefaultCommands` / `RunCommand`.
- **Rung 3/4/5 — RTL / platform / `deps`?** Nothing new is needed; the store is
  the vendored SQLite and the UI is in-tree.

So the gap is narrow: a **title** on the session, a small amount of **session
lifecycle state** (pin, archive), the **store API** for both, and the **modal**.

## Goals

- A `/sessions` command opens a modal listing the current workspace's sessions,
  newest-updated first, filtered by a search input (title or topic).
- Each row shows a human-readable title, not an id — generated from the model's
  own reply when one leads with a markdown H1, falling back to the id.
- The title tracks recent activity: it is re-derived from the latest reply, not
  frozen at the first.
- The operator can **pin**, **rename** (explicit override), and **archive**
  (soft-delete) a session from the modal.
- The chosen session can be opened (the modal's activate action), so management
  and navigation are one surface.
- The design follows the existing modal/theme language (see
  `docs/design/chat_panel_tui.md` and `docs/design/TUI_Design_Language.md`).

## User Stories

- As an operator, I want to list the sessions of my workspace so I can find the
  one I want without knowing its id.
- As an operator, I want to search the list by name or topic so I can narrow a
  long history quickly.
- As an operator, I want each session to show a readable name so I can tell them
  apart at a glance.
- As an operator, I want the name to reflect what the session is currently about,
  so a stale title from its first message does not mislead me.
- As an operator, I want to override the name when the generated one is wrong, so
  I keep control of the label I rely on.
- As an operator, I want to pin the sessions I care about so they stay at the top
  and survive cleanup.
- As an operator, I want to archive a session I am done with so the list stays
  short without losing its history.
- As an operator, I want to open a session from the list so management and
  navigation are the same surface.
- As an operator, I want an archived session to be recoverable (or at least not
  destroyed) so a mistaken archive is not data loss.

## Acceptance Criteria

### Functional Requirements

Titles

- [ ] When an assistant reply contains a top-level markdown heading (`# …`), the
      session's generated title is set to that heading's text.
- [ ] A reply with no H1 leaves the previous title unchanged (it does not clear
      it and does not fall back to the id).
- [ ] The generated title tracks activity: a later reply that carries an H1
      replaces the earlier generated title.
- [ ] An explicit rename is an **override**: once set, generated titles no longer
      replace it until the operator clears the override.
- [ ] The title is derived **from the assistant reply itself** — no additional
      tool call and no separate summarizer model.
- [ ] Title extraction is a pure function over reply text (headings, multiple
      headings, headings inside fenced code blocks, empty heading text), so it is
      unit-testable without a store or a model.
- [ ] A session with no title is displayed by a short form of its id.

Pins and archival

- [ ] A session can be pinned and unpinned; pinned sessions sort ahead of
      unpinned ones, then by most-recently-updated.
- [ ] A session can be archived; an archived session is excluded from the default
      list and is **not** deleted from the ledger.
- [ ] An archived session can be restored.
- [ ] (Decision pending — see Open Questions) whether archival is a soft flag on
      the session or reuses the existing soft-delete on the store.

The modal

- [ ] `/sessions` is registered in the command palette and opens the modal.
- [ ] The modal lists the workspace's sessions, newest-updated first, pinned
      first, archived excluded.
- [ ] The modal has a search input; typing filters the list live by title (and,
      per Open Questions, topic/derived keywords).
- [ ] Up/Down/Home/End move the selection; Enter opens the selected session;
      Escape closes the modal.
- [ ] Per-row actions are reachable by keys (pin/unpin, rename, archive/restore);
      the exact bindings are fixed in the SPEC and shown, dimmed, in the modal.
- [ ] Rename opens an inline text input seeded with the current title; empty
      input cancels, and a submitted value becomes the override.
- [ ] The modal dims the screen behind it and traps input, matching
      `TApprovalModal`.

### Non-Functional Requirements

- [ ] Performance: opening the modal and filtering are O(sessions) over an
      already-loaded list; no query per keystroke.
- [ ] Reliability: no leaks (`make test-leak`); no crash on an empty workspace, a
      store-less session, or a session with a missing title.
- [ ] Portability: macOS + Linux, `{$mode delphi}`, FPC 3.3.1; `make check` green.
- [ ] Accessibility: state is not carried by colour alone (pinned and archived
      each get a glyph, per the design language).
- [ ] The design matches the existing modal and theme (roles from `TTheme`; no
      hard-coded attributes).

## Success Metrics

### Quantitative

- A workspace with N sessions is fully browsable and filterable from one modal.
- Title extraction is covered by table-driven tests over reply samples.
- `make check` (functional + heaptrc) stays green.

### Qualitative

- A returning operator can identify and reopen a session in a few keystrokes.
- Session titles read as a subject, not an id.
- No new dependency; the feature is a thin surface over the existing store.

## Constraints

### Technical

- Free Pascal 3.3.1, `{$mode delphi}`; `make check` green.
- No new dependency; reuse the vendored SQLite store and the in-tree widgets.
- Store changes are additive migrations (the project's established pattern:
  v1..v9); a full schema reset is not acceptable for this feature.

### Business / Time

- No deadline. Small enough to land as one SPEC after the open questions are
  resolved.

## Dependencies

### Internal

- `hildegard.helper.store` — `sessions` table, `ListSessions`, `TouchSession`,
  `sessions.label`, migrations.
- `hildegard.helper.session` — `TSessionSummary`.
- `hildegard.helper.session.runtime` — where the assistant reply is committed
  (the natural place to derive the title), alongside the existing checkpoint-turn
  hook.
- `hildegard.helper.harness.app` — command registry, modal planes, driver seam.
- `hildegard.helper.tui.palette`, `hildegard.helper.tui.list`,
  `hildegard.helper.tui.approvalmodal`, `hildegard.helper.tui.theme`.
- Related features: Sessions and Ledger, Headless Sessions (runtime ↔ store),
  Context Checkpoint (the ambient reply path is the precedent for acting on a
  completed turn), Subagents (child sessions share the `sessions` table).

### External

- None.

## Risks

- **Noisy or missing titles.** A model that omits an H1 leaves the title stale; a
  model that emits several leaves the pick ambiguous. Mitigation: define the rule
  in the SPEC (first H1 outside code fences; ignore `##`+), never clear a title
  on absence, and make the rename override always available.
- **Identity mismatch.** Titles are generated in the **runtime** (which owns the
  loop and the store), so a client that attaches later must read them from the
  store, not recompute them. Mitigation: persist the title at the boundary, as
  Context Checkpoint does for checkpoints.
- **Title churn.** A title that changes every turn can be disorienting.
  Mitigation: keep the pin and the explicit override; treat "latest wins" as the
  default with a documented rationale (the title should describe *now*).
- **Archive vs. delete confusion.** Operators may expect delete to be permanent.
  Mitigation: archive is explicitly non-destructive; a hard delete, if ever
  added, is a separate, confirmed action.

## Out of Scope

- Cross-workspace session browsing (the modal is scoped to the current
  workspace).
- Deleting a session's **history** (rows in the ledger). v1 archives, it does not
  destroy.
- A separate summarizer model or a new tool call for naming.
- Session **forking / branching** and per-session workspace snapshots (see
  Workspace Snapshots).
- A dedicated semantic "topic" embedding or classifier (see Open Questions for
  the fallback).
- Merging sessions.

## Future Considerations

- Full-text (FTS5) search across session **contents**, not just titles — the
  `messages_fts` index added for Context Checkpoint already exists and could back
  "find the session where I asked about X".
- Auto-archive of stale sessions past an age or count threshold.
- A `name_session` tool so the model can name a session explicitly (deferred: it
  adds a tool call to every turn for something the reply already carries).
- Titles surfaced in the session header and in `--attach` listings.

## Open Questions

These must be resolved before the SPEC (Stage 2):

1. **Title source of truth.** Store a single resolved `title` column (generated
   unless overridden), or store the generated title and the override separately
   and resolve at read time? (The latter is cleaner for "clear the override".)
2. **"Name or topic" search.** v1 searches the title. Is a lightweight topic
   derived from the checkpoint summary (which already summarizes the session)
   enough to search too, or is title-only acceptable for v1?
3. **Pinned/archived persistence.** Columns on `sessions`, or a small
   `session_flags` table? (Recommendation: columns — the store already adds
   columns by additive migration.)
4. **Archived visibility.** Hidden entirely, shown dimmed with a toggle, or shown
   only when the search is empty?
5. **Open behaviour.** Does activating a row switch the *running* TUI to that
   session (driver re-attach), or spawn a new client process? This touches the
   Headless Sessions driver seam and may be its own increment.
6. **Naming the current session.** Should the modal always include the current
   session as the first row (so `/sessions` can rename the session you are in)?

## Notes

The 32-hex id is currently shown as `Copy(Id, 1, 12)` in the messages-panel
header; a title would replace or prefix that.

Subagent sessions share the `sessions` table and carry a `label`. The modal is
about **root** sessions (the workspace's conversations); children are the
Subagents sidebar's concern. Whether a child ever appears here is part of Open
Question 5's neighborhood and should be settled in the SPEC.

The runtime, not the TUI, owns the loop and the store, so the title derivation
and persistence belong on the runtime's completed-turn path — the same place the
Context Checkpoint turn commits. The TUI modal only reads titles.

### ICE score

Impact **7** — sessions are otherwise unmanageable and unidentifiable; this
unblocks real use of the ledger. Confidence **7** — the store and widget
primitives exist; the only genuinely new piece (title extraction) is small and
pure. Ease **7** — one modal, one additive migration, one pure function, and a
handful of store methods. A worthwhile, self-contained increment.
