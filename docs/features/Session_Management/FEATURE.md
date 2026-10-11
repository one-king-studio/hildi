# Session Management

## Overview

A `/sessions` command that opens a modal over the Harness TUI listing the
sessions of the current workspace, with search, and the ability to name, pin,
and delete/archive a session. Paired with it: **reply metadata**, so a session
is identified by a human-readable name instead of a hex id.

The two are one feature because the modal is useless without something to
distinguish rows by. A session today is only its 32-hex id (the header shows the
first 12 characters). The list needs a title, and the source of a title is the
model itself: a **substantive** reply opens with a small **YAML frontmatter
block** carrying a `title` and a set of `keywords`. The runtime extracts that
metadata at the completed-turn boundary; the TUI renders the title and keyword
chips on the assistant item and never draws the block as markdown.

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
  newest-updated first, filtered by a search input (title and keywords).
- Each row shows a human-readable title, not an id — taken from a substantive
  reply's frontmatter `title`, falling back to the id.
- The title tracks recent activity: it is re-derived from the latest reply that
  carries one, not frozen at the first.
- A substantive reply's **keywords** are recorded per reply, so the modal can
  filter by them and the operator can see what a reply is about.
- The operator can **pin**, **rename** (explicit override), and **archive**
  (soft-delete) a session from the modal.
- The design follows the existing modal/theme language (see
  `docs/design/chat_panel_tui.md` and `docs/design/TUI_Design_Language.md`).

## User Stories

- As an operator, I want to list the sessions of my workspace so I can find the
  one I want without knowing its id.
- As an operator, I want to search the list by name or keyword so I can narrow a
  long history quickly.
- As an operator, I want each session to show a readable name so I can tell them
  apart at a glance.
- As an operator, I want the name to reflect what the session is currently about,
  so a stale title from its first message does not mislead me.
- As an operator, I want to override the name when the extracted one is wrong, so
  I keep control of the label I rely on.
- As an operator, I want to pin the sessions I care about so they stay at the top
  and survive cleanup.
- As an operator, I want to archive a session I am done with so the list stays
  short without losing its history.
- As an operator, I want an archived session to be recoverable (or at least not
  destroyed) so a mistaken archive is not data loss.

## Acceptance Criteria

### Functional Requirements

Reply metadata (frontmatter)

- [ ] A **substantive** assistant reply may open with a YAML frontmatter block
      (delimited by `---`) carrying `title` and `keywords`. A non-substantive
      reply (a terse acknowledgement) may omit it entirely.
- [ ] The runtime extracts the block at the completed-turn boundary and persists
      the `title` (per session) and the `keywords` (per reply, as a set).
- [ ] Extraction is a pure, tolerant function (no YAML dependency): top-level
      `key: value`, `key: [a, b, c]`, or `key:` + `- item` lines; unknown keys
      are ignored; malformed input yields no metadata and does not raise.
- [ ] The frontmatter block is **never rendered as markdown**: it is stripped
      from the body before the body reaches the renderer, and the extracted
      metadata is drawn through a dedicated presentation (a title line and
      keyword chips) on the assistant item.
- [ ] Only a **leading** block is frontmatter; a `---` later in the body is an
      ordinary thematic break.
- [ ] While a reply streams, a detected leading frontmatter block is suppressed
      (its bytes are not shown) until the block closes; the title/keyword
      presentation then appears and the body streams normally.
- [ ] The session's displayed title is the latest reply's `title`; a reply with
      no frontmatter leaves the previous title unchanged.
- [ ] An explicit rename is an **override**: once set, extracted titles no longer
      replace it until the operator clears the override.
- [ ] A session with no title is displayed by a short form of its id.
- [ ] The raw reply is stored **verbatim** (frontmatter included), so a session
      can be replayed from the raw message rather than re-composed from pieces.

The prompt

- [ ] The system prompt instructs the model to open a **substantive** reply with a
      frontmatter block carrying `title` (a short subject) and `keywords` (3–8
      lowercase topical terms), and that a terse acknowledgement need not.
- [ ] The system prompt names the preferred markdown flavor: CommonMark with GFM
      pipe tables — exactly the dialect the in-tree parser already renders
      (headings, lists, fenced code, quotes, rules, tables).
- [ ] The instruction lives where the base system prompt is assembled
      (`DefaultSystemPrompt` / the session's `SystemPrompt`), so it applies to
      every turn without being persisted to the ledger.
- [ ] The prompt change is additive and does not disturb tool-calling or ambient
      turns (an ambient/checkpoint reply is not required to carry frontmatter).

Pins and archival

- [ ] A session can be pinned and unpinned; pinned sessions sort ahead of
      unpinned ones, then by most-recently-updated.
- [ ] A session can be archived; an archived session is excluded from the default
      list and is **not** deleted from the ledger.
- [ ] An archived session can be restored.
- [ ] Pin and archive are columns on the `sessions` row (`pinned`, `archived`),
      added by an additive migration — not a separate table and not the store's
      soft-delete.

The modal

- [ ] `/sessions` is registered in the command palette and opens the modal.
- [ ] The modal lists the workspace's sessions, newest-updated first, pinned
      first, archived excluded; the current session is always the first row,
      marked as current.
- [ ] The modal has a search input; typing filters the list live by **title and
      keyword** (a reply's keywords are searched), and by the id, so a pasted id
      finds its row.
- [ ] Up/Down/Home/End move the selection; Escape closes the modal. **Activating
      a row (opening another session) is deferred** — see Decisions.
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

- **The format depends on the model.** Frontmatter is only as reliable as the
  prompt's compliance: a model that ignores the instruction yields no title or
  keywords. Mitigation: the instruction is explicit and the format is simple; an
  absent block leaves the previous title unchanged (never clears it); the rename
  override is always available; and extraction is tolerant (a malformed block
  yields nothing rather than raising).
- **The block leaking into the display.** The frontmatter streams *before* the
  body, so a naive render shows `title: …` typing out. Mitigation: the streaming
  path suppresses a leading block until it closes (Decision 10); only a leading
  block is treated as frontmatter, so a later `---` stays a rule.
- **Identity mismatch.** Titles and keywords are extracted in the **runtime**
  (which owns the loop and the store), so a client that attaches later must read
  them from the store, not recompute them. Mitigation: persist at the boundary,
  as Context Checkpoint does for checkpoints.
- **Title churn.** A title that changes every turn can be disorienting.
  Mitigation: keep the pin and the explicit override; treat "latest wins" as the
  default with a documented rationale (the title should describe *now*).
- **Archive vs. delete confusion.** Operators may expect delete to be permanent.
  Mitigation: archive is explicitly non-destructive; a hard delete, if ever
  added, is a separate, confirmed action.

## Out of Scope

- Cross-workspace session browsing (the modal is scoped to the current
  workspace).
- Opening/activating another session from the modal (deferred — the driver seam;
  Decision 5).
- Deleting a session's **history** (rows in the ledger). v1 archives, it does not
  destroy.
- A separate summarizer model or a new tool call for naming.
- A session-wide keyword aggregation or a word cloud (keywords are per reply;
  Decision 7).
- Session **forking / branching** and per-session workspace snapshots (see
  Workspace Snapshots).
- A semantic "topic" embedding or classifier.
- Merging sessions.

## Future Considerations

- Full-text (FTS5) search across session **contents**, not just titles — the
  `messages_fts` index added for Context Checkpoint already exists and could back
  "find the session where I asked about X".
- Auto-archive of stale sessions past an age or count threshold.
- A `name_session` tool so the model can name a session explicitly (deferred: it
  adds a tool call to every turn for something the reply already carries).
- Titles surfaced in the session header and in `--attach` listings.

## Decisions

Resolved before the SPEC (Stage 2):

1. **Title source of truth.** Two columns: `title` (the extracted one) and
   `title_override` (operator-set), resolved at read. Two columns make "clear the
   override" trivial and keep the generated title available. Do **not** reuse the
   existing `sessions.label` — that is a subagent-label concept (written only by
   `CreateChildSession`, read by `ChildrenOf`); overloading it would corrupt the
   Subagents sidebar.
2. **Search.** Title **and keywords**, plus the id. Keywords are searched from
   the per-reply keyword set (see 7). No derived "topic"; no checkpoint-summary
   term.
3. **Pinned/archived persistence.** Columns on `sessions` (`pinned`, `archived`),
   additive migration — not a separate table, not the store's soft-delete.
4. **Archived visibility.** Hidden by default; an explicit toggle shows archived
   rows dimmed with an archive glyph.
5. **Open behaviour — deferred.** Activating a row (opening a different session)
   is **out of v1**. It needs the driver seam (the TUI binds one session at
   startup and there is no runtime re-attach), so it is its own increment. v1 is
   management only.
6. **Current session.** Always the first row, marked as current, so `/sessions`
   can rename the session you are in.
7. **Keywords are per reply, not per session.** A substantive reply's frontmatter
   carries a **set** of keywords; each set is stored against that reply. There is
   no session-wide aggregation and no word cloud (the earlier cloud idea is
   dropped). A keyword query matches any reply carrying it.
8. **Frontmatter is expected only for substantive replies.** A terse
   acknowledgement may omit it; absence leaves the session's title unchanged and
   adds no keywords.
9. **The raw reply is stored verbatim** (frontmatter included). The ledger keeps
   the original message so a session can be replayed from it; the stripped body
   and the extracted metadata are derived views, not the source of truth.
10. **The frontmatter block is never rendered as markdown.** It is extracted as
    metadata and drawn through a dedicated presentation (a title line and keyword
    chips) on the assistant item; the body it is stripped from streams normally.
    While a reply streams, a leading frontmatter block is suppressed until it
    closes.

### Storage shape (from the decisions)

- `sessions`: add `title`, `title_override`, `pinned`, `archived` (migration v7,
  additive).
- `messages`: the assistant row already holds the **raw** reply text (decision 9);
  no change needed to store it.
- `reply_keywords(message_id, keyword)`: one row per keyword per reply, normalized
  so a keyword query is an index lookup and a reply's keyword set is a
  `SELECT keyword WHERE message_id = ?`.

## Notes

The 32-hex id is currently shown as `Copy(Id, 1, 12)` in the messages-panel
header; a title would replace or prefix that.

Subagent sessions share the `sessions` table and carry a `label`. The modal is
about **root** sessions (the workspace's conversations); children are the
Subagents sidebar's concern. Whether a child ever appears here is part of Open
Question 5's neighborhood and should be settled in the SPEC.

The runtime, not the TUI, owns the loop and the store, so the title/keyword
extraction and persistence belong on the runtime's completed-turn path — the same
place the Context Checkpoint turn commits. The TUI modal only reads titles and
keywords.

### ICE score

Impact **7** — sessions are otherwise unmanageable and unidentifiable; this
unblocks real use of the ledger. Confidence **7** — the store and widget
primitives exist; the only genuinely new piece (title extraction) is small and
pure. Ease **7** — one modal, one additive migration, one pure function, and a
handful of store methods. A worthwhile, self-contained increment.
