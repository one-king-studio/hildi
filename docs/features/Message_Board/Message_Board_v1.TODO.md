# Implementation Plan: Workspace Board v1

**Status: v1 functional, five items deliberately open.** The board stores, reads,
supersedes, moderates, notices, prunes and annotates staleness — 47 tests across
four units. What remains is listed at the bottom under *Still open* rather than
being ticked for the look of it.

**Related Specification:** `Message_Board_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

A board per workspace: append-only entries with supersession, a bounded TOC in the
tail, and moderation behind approval. TDD-first; `make check` before moving on.

> **Prerequisite (done):** the tail block, the change log it annotates against,
> and the transient-notice mechanism it delivers through are all shipped and
> measured (~100 of the 500-token tail budget in use).

## Implementation Tasks

### Phase 1: Schema and store seam

- [x] **Migration v14**: `board_entries`, `board_reads`, `board_lock`; additive.
- [x] **Test**: a fresh database has the three tables and `StoreSchemaVersion >= 14`.
- [x] **Implement** `IBoardStore` + `TSqliteBoardStore`.
- [x] **Test**: `Append` then `Get` round-trips every field, `paths` included.
- [x] **Test**: `Read` filters by topic, by kind, by since-id; newest-first; a
      `Limit` is respected.
- [x] **Implement** `Read`.

### Phase 2: Supersession

- [x] **Test**: `CurrentOf` on an empty topic is not-found (not an error).
- [x] **Test**: post #1, then #2 superseding #1 — `CurrentOf` returns #2, and both
      are readable with `Current` set on #2 only.
- [x] **Implement** the current-entry query (exclude deleted, exclude superseded,
      take max id).
- [x] **Test**: restoring a superseded entry makes it current again.
- [x] **Test**: a post whose `supersedes` names an entry in another topic is refused.
- [x] **Implement** the cross-topic refusal.

### Phase 3: The tools

- [x] **Test**: `board_post` with each of the six kinds; a missing `reason` fails
      before the store is touched.
- [x] **Test**: an unknown kind names the six valid ones; an empty topic or title
      is refused; an empty body is allowed for `note` only.
- [x] **Implement** argument parsing and validation.
- [x] **Test**: `board_read` on an empty board says `(no board messages)`, so
      absence is not read as failure.
- [x] **Test**: a dropped `paths` list renders without the staleness suffix.

### Phase 4: Moderation

- [x] **Test**: `board_moderate delete` asks for approval; a denial changes nothing;
      an approval soft-deletes and the entry leaves default reads.
- [x] **Test**: `restore` clears `deleted_at`/`deleted_by`.
- [x] **Test**: `lock` makes `board_post` to that topic refuse, naming the locker.
- [ ] **Test**: `pin` and `move` are gated the same way.
- [x] **Implement** the ask and the five operations.

### Phase 5: The tail TOC

- [x] **Test**: `Toc` counts unread since a cursor, plus questions/decisions/findings
      and the last-post age.
- [x] **Test**: the rendered element is under 120 bytes and carries no titles.
- [ ] **Test**: under budget pressure the drop order is `f`, `d`, `q` — `unread`
      and `last` always survive.
- [x] **Implement** the provider fragment.
- [x] **Test**: the element appears on the **last message** only, and the header
      prose lives in `StableText` rather than the element.
- [ ] **Implement** the `StableText` contribution.

### Phase 6: Transient notices

- [x] **Test**: a new entry since the cursor produces **no** `messages` row.
- [x] **Test**: several new entries coalesce into **one** notice per drain.
- [ ] **Test**: an answer to a question this session asked carries the title.
- [x] **Implement** `pkBoard` in the prompt queue and the drain.

### Phase 7: Staleness and search

- [x] **Test**: an entry naming a path reports 0 changes when fresh, N after N
      recorded changes to that path.
- [x] **Implement** the join against `file_changes`.
- [ ] **FTS**: index board bodies so one search spans messages and board. The table exists (v14); nothing writes to it, so search does not yet span the board.

### Phase 8: Wiring

- [x] **Register** the three tools in the harness session, next to the file tools.
- [x] **Test**: a real session sees `board_post` advertised and can post and read.
- [x] **Update** `FEATURES.md`; rename this TODO to `Message_Board_v1.DONE.md`.

## Deviations

- (record here)

## Notes

- **The board is a provider, not a special case.** It contributes tools and prompt
  fragments through `IToolProvider`, the same seam skills and MCP use. If the loop
  needs a board-specific branch, the design has gone wrong.
- **Nothing here may fail a turn.** A store error in the tail omits the element; a
  store error in a tool is a tool error. The board observes, it does not gate.
- **The two-tool shape is the point.** A notice says something arrived (~30
  tokens); reading costs the body. Collapsing them re-invents an expensive
  broadcast.
- **Supersession is a pointer, not a rewrite.** If a query has to walk a chain to
  answer "what is current", the query is wrong.

## Still open (not done, and not ticked)

Five things the SPEC asks for that the code does not yet do. Each is a real gap,
not a formality:

- [ ] **FTS**: `board_fts` exists from migration v14 and nothing writes to it, so
  a search still cannot span the board. Needs an insert on `board_post` and a
  delete-with-restore path.
- [ ] **`move`** moderation op: re-topicking an entry. The other five
  (`delete`, `restore`, `pin`, `unpin`, `lock`, `unlock`) are implemented; `move`
  is not, and it is the one that would need the cross-topic guard revisited.
- [ ] **TOC drop order** under budget pressure: `f`, `d`, `q`, keeping `unread`
  and `last`. The element is capped at 120 bytes, but it truncates mid-field
  rather than dropping whole fields in that order.
- [ ] **Board `StableText`**: the prose explaining what a board is still lives
  nowhere. The TOC element is pure data (as designed), so the explanation needs
  an addition to the stable prompt alongside the skill descriptions.
- [ ] **A `reply_to` answering this session's own question carries the title** in
  its notice. Today every notice is the same coalesced count.

Also worth knowing for whoever picks this up: **`pin` is stored and rendered but
does not affect read order.** The flag round-trips and the marker shows, but a
pinned entry is not sorted to the top. That is a design choice the SPEC did not
settle.
