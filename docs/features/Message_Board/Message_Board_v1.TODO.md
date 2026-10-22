# Implementation Plan: Workspace Board v1

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

- [ ] **Migration v14**: `board_entries`, `board_reads`, `board_lock`; additive.
- [ ] **Test**: a fresh database has the three tables and `StoreSchemaVersion >= 14`.
- [ ] **Implement** `IBoardStore` + `TSqliteBoardStore`.
- [ ] **Test**: `Append` then `Get` round-trips every field, `paths` included.
- [ ] **Test**: `Read` filters by topic, by kind, by since-id; newest-first; a
      `Limit` is respected.
- [ ] **Implement** `Read`.

### Phase 2: Supersession

- [ ] **Test**: `CurrentOf` on an empty topic is not-found (not an error).
- [ ] **Test**: post #1, then #2 superseding #1 — `CurrentOf` returns #2, and both
      are readable with `Current` set on #2 only.
- [ ] **Implement** the current-entry query (exclude deleted, exclude superseded,
      take max id).
- [ ] **Test**: restoring a superseded entry makes it current again.
- [ ] **Test**: a post whose `supersedes` names an entry in another topic is refused.
- [ ] **Implement** the cross-topic refusal.

### Phase 3: The tools

- [ ] **Test**: `board_post` with each of the six kinds; a missing `reason` fails
      before the store is touched.
- [ ] **Test**: an unknown kind names the six valid ones; an empty topic or title
      is refused; an empty body is allowed for `note` only.
- [ ] **Implement** argument parsing and validation.
- [ ] **Test**: `board_read` on an empty board says `(no board messages)`, so
      absence is not read as failure.
- [ ] **Test**: a dropped `paths` list renders without the staleness suffix.

### Phase 4: Moderation

- [ ] **Test**: `board_moderate delete` asks for approval; a denial changes nothing;
      an approval soft-deletes and the entry leaves default reads.
- [ ] **Test**: `restore` clears `deleted_at`/`deleted_by`.
- [ ] **Test**: `lock` makes `board_post` to that topic refuse, naming the locker.
- [ ] **Test**: `pin` and `move` are gated the same way.
- [ ] **Implement** the ask and the five operations.

### Phase 5: The tail TOC

- [ ] **Test**: `Toc` counts unread since a cursor, plus questions/decisions/findings
      and the last-post age.
- [ ] **Test**: the rendered element is under 120 bytes and carries no titles.
- [ ] **Test**: under budget pressure the drop order is `f`, `d`, `q` — `unread`
      and `last` always survive.
- [ ] **Implement** the provider fragment.
- [ ] **Test**: the element appears on the **last message** only, and the header
      prose lives in `StableText` rather than the element.
- [ ] **Implement** the `StableText` contribution.

### Phase 6: Transient notices

- [ ] **Test**: a new entry since the cursor produces **no** `messages` row.
- [ ] **Test**: several new entries coalesce into **one** notice per drain.
- [ ] **Test**: an answer to a question this session asked carries the title.
- [ ] **Implement** `pkBoard` in the prompt queue and the drain.

### Phase 7: Staleness and search

- [ ] **Test**: an entry naming a path reports 0 changes when fresh, N after N
      recorded changes to that path.
- [ ] **Implement** the join against `file_changes`.
- [ ] **FTS**: index board bodies so one search spans messages and board.

### Phase 8: Wiring

- [ ] **Register** the three tools in the harness session, next to the file tools.
- [ ] **Test**: a real session sees `board_post` advertised and can post and read.
- [ ] **Update** `FEATURES.md`; rename this TODO to `Message_Board_v1.DONE.md`.

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
