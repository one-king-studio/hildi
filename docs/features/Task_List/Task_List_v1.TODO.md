# Implementation Plan: Task List v1

**Related Specification:** `Task_List_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

A shared task list per workspace: mutable cards with a claim CAS, a bounded work
queue in the tail, and reassign/delete behind approval. TDD-first; `make check`
before moving on.

> **Prerequisite (done):** the tail block and its provider seam. The board's TOC
> and this work queue share the mechanism.

> **Deliberate refinement over the FEATURE:** `BlockedOn: Integer` became
> `BlockedOnId` + `BlockedOnKind`. An id alone cannot say whether it names a card
> or a board question, and guessing from a shared id space would resolve to the
> wrong thing the first time two tables disagree.

## Implementation Tasks

### Phase 1: Schema and store

- [ ] **Migration**: `task_cards` plus the three indexes; additive.
- [ ] **Test**: a fresh database has the table and the schema version advanced.
- [ ] **Implement** `ITaskStore` + `TSqliteTaskStore`.
- [ ] **Test**: `Add` then `Get` round-trips every field, including the blocker
      pair and the claim timestamps.
- [ ] **Test**: `List` filters by status, by `mine`, by parent; ordering is by
      `position` then `updated_at`.

### Phase 2: The claim CAS

- [ ] **Test (the one that matters)**: two claims in sequence — the first wins; the
      second returns `AClaimed = False`, the holder's session, and its claim time;
      the card is still the first claimer's.
- [ ] **Implement** `Claim` as one `UPDATE ... WHERE status = tsOpen`, using
      `sqlite3_changes` to decide, then a re-read to name the holder.
- [ ] **Test**: claiming a `done` card is refused and names the status, not the
      holder.
- [ ] **Test**: a card in another workspace cannot be claimed.

### Phase 3: Guarded transitions

- [ ] **Test**: each legal transition in the SPEC's table succeeds from its `From`
      status.
- [ ] **Test**: each illegal one is refused naming the actual state — notably
      `task_done` from `open`, and any transition by a session that does not hold
      the claim.
- [ ] **Implement** `Transition` with the `AND status = AFrom AND claimed_by = ABy`
      guard.
- [ ] **Test**: `release` clears `claimed_by`/`claimed_at`.
- [ ] **Test**: `unblock` preserves `claimed_by` while moving to `claimed`.
- [ ] **Test**: `block` with a card blocker and a question blocker both resolve; an
      unresolvable one is refused by name.
- [ ] **Implement** the blocker resolution seam.
- [ ] **Test**: `drop` without a reason is refused; with one, `done_note` and
      `status_at` are set.

### Phase 4: Nesting and edit

- [ ] **Test**: a subtask of a top-level card is allowed; a subtask of a subtask is
      refused.
- [ ] **Test**: a parent whose children are all `done` stays `open` — no auto-close.
- [ ] **Test**: `task_edit` changes title/body and leaves status, claim and
      timestamps untouched; a `status` argument is refused rather than ignored.
- [ ] **Implement** `Edit` with an explicit status refusal.

### Phase 5: Gating

- [ ] **Test**: `task_reassign` asks for approval; a denial changes nothing.
- [ ] **Test**: `task_delete` asks; a denial changes nothing; an approval removes
      the row.
- [ ] **Test**: every other verb runs with no approval service configured at all,
      proving they are ungated rather than merely unasked.
- [ ] **Implement** the two asks.

### Phase 6: The tail work queue

- [ ] **Test**: `mine` is present whenever this session holds a claim, with its age.
- [ ] **Test**: at most three `open` cards are listed, then `+N more`.
- [ ] **Test**: a `blocked` card appears only when it is this session's or older
      than the threshold.
- [ ] **Test**: the rendered element stays under 400 bytes with 100 cards present.
- [ ] **Test**: drop order under pressure removes the `open` list first, then
      `blocked`, and never `mine`.
- [ ] **Implement** the provider fragment and its `StableText` contribution.

### Phase 7: Retention

- [ ] **Test**: `done`/`dropped` beyond the count window are pruned.
- [ ] **Test**: `open`/`claimed`/`blocked` are never pruned, however old.
- [ ] **Test**: a finished card that is another card's `parent` or `BlockedOnId` is
      never pruned — the reference must not dangle.
- [ ] **Implement** `Prune` and call it at the turn boundary, swallowed on failure.

### Phase 8: Wiring

- [ ] **Register** the ten tools in the harness session, beside the file tools.
- [ ] **Test**: a real session advertises them and can add, claim and complete.
- [ ] **Update** `FEATURES.md`; rename this TODO to `Task_List_v1.DONE.md`.

## Deviations

- (record here)

## Notes

- **The CAS is the feature.** Everything else is CRUD; the claim is what turns a
  list into coordination. Its refusal message — who holds it, since when — is the
  product, not an error string.
- **Status is not editable.** Every transition is a verb with an actor, so the row
  answers "who moved this and why". A free-form status write would lose that.
- **A parent does not auto-close.** "All subtasks done" and "the task is done" are
  different claims, and conflating them hides incomplete thinking.
- **Nothing here may fail a turn.** A tail failure omits the element; a tool
  failure is a tool error.
- **This is not a scheduler.** No assignment, no dispatch, no fairness. If a change
  only makes sense with something deciding for the agents, it belongs elsewhere.
