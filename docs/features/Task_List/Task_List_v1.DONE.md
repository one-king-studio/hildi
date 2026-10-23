# Implementation Plan: Task List v1 — DONE

**Related Specification:** `Task_List_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Outcome

Shipped. Six commits, 1,767 tests, leak-clean.

| Commit | What |
| --- | --- |
| `8679b03` | Types, `ITaskStore` + `TSqliteTaskStore`, migration v15 |
| `3e5401b` | The transition table and the unknown-id error, both previously unused |
| `7b5d712` | The count rule (`AKeepDone` was in the signature and unused) |
| `3a514a5` | Six tools carrying the ten verbs, plus the tail work queue |
| `6d2382c` | Session wiring; found and fixed the `StablePrompt` wipe |
| `56b09b2` | `StaleBlockMinutes` was dead, so the tail showed the wrong blocks |

## Implementation Tasks

### Phase 1: Schema and store — done

- [x] **Migration**: `task_cards` plus the three indexes; additive.
- [x] **Test**: a fresh database has the table and the schema version advanced.
- [x] **Implement** `ITaskStore` + `TSqliteTaskStore`.
- [x] **Test**: `Add` then `Get` round-trips every field, including the blocker
      pair and the claim timestamps.
- [x] **Test**: `List` filters by status, by `mine`, by parent; ordering is by
      `position` then `updated_at`. *(`TestList*`, added during close-out — the
      filters were previously only exercised indirectly.)*

### Phase 2: The claim CAS — done

- [x] **Test (the one that matters)**: two claims in sequence — the first wins;
      the second returns `AClaimed = False`, the holder's session, and its claim
      time; the card is still the first claimer's.
- [x] **Implement** `Claim` as one `UPDATE ... WHERE status = tsOpen`, using
      `sqlite3_changes` to decide, then a re-read to name the holder.
- [x] **Test**: claiming a `done` card is refused and names the status, not the
      holder.
- [x] **Test**: a card in another workspace cannot be claimed.
- [x] **Test**: the tool's refusal names the holder *and its age* — the message
      is the feature.

### Phase 3: Guarded transitions — done

- [x] **Test**: each legal transition in the SPEC's table succeeds from its `From`
      status.
- [x] **Test**: each illegal one is refused naming the actual state — notably
      `task_done` from `open`, and any transition by a session that does not hold
      the claim.
- [x] **Implement** `Transition` with the `AND status = AFrom AND claimed_by = ABy`
      guard, **plus an explicit `IsLegalTransition` check** — see Deviation 2.
- [x] **Test**: `release` clears `claimed_by`/`claimed_at`.
- [x] **Test**: `unblock` preserves `claimed_by` while moving to `claimed`.
- [x] **Test**: `block` with a card blocker and a question blocker both resolve; an
      unresolvable one is refused by name.
- [x] **Implement** the blocker resolution seam (`IBoardQuestionExists`).
- [x] **Test**: `drop` without a reason is refused; with one, `done_note` and
      `status_at` are set.
- [x] **Test**: an unclaimed card can be dropped, and another session's claim
      cannot — see Deviation 3.

### Phase 4: Nesting and edit — done

- [x] **Test**: a subtask of a top-level card is allowed; a subtask of a subtask is
      refused.
- [x] **Test**: a parent whose children are all `done` stays `open` — no auto-close.
- [x] **Test**: `task_edit` changes title/body and leaves status, claim and
      timestamps untouched; a `status` argument is **refused** rather than ignored.
- [x] **Implement** `Edit` with an explicit status refusal. An absent field keeps
      its current value rather than blanking.

### Phase 5: Gating — done

- [x] **Test**: `task_reassign` asks for approval; a denial changes nothing.
- [x] **Test**: `task_delete` asks; a denial changes nothing; an approval removes
      the row.
- [x] **Test**: every other verb runs with no approval service configured at all,
      proving they are ungated rather than merely unasked.
- [x] **Implement** the two asks, `ref = 'task:moderate'`, summary naming the card.

### Phase 6: The tail work queue — done

- [x] **Test**: `mine` is present whenever this session holds a claim, with its age.
- [x] **Test**: at most three `open` cards are listed, reporting the **true** total
      and `+N more` — see Deviation 4.
- [x] **Test**: a `blocked` card appears only when it is this session's or older
      than `StaleBlockMinutes`.
- [x] **Test**: the rendered element stays under 400 bytes.
- [x] **Test**: drop order under pressure removes the `open` list first, then
      `blocked`, and never `mine`.
- [x] **Implement** the provider fragment and its stable-text contribution.

### Phase 7: Retention — done

- [x] **Test**: `done`/`dropped` beyond the count window are pruned.
- [x] **Test**: `open`/`claimed`/`blocked` are never pruned, however old.
- [x] **Test**: a finished card that is another card's `parent` or `BlockedOnId` is
      never pruned — the reference must not dangle. Tested for both exclusions.
- [x] **Implement** `Prune` (age **and** count) and call it at the turn boundary,
      swallowed on failure.

### Phase 8: Wiring — done

- [x] **Register** the tools in the harness session, beside the file tools.
- [x] **Test**: a real session advertises them and can add a card through the
      registered handler.
- [x] **Test**: `TaskStableText` rides `StablePrompt` beside the board's.
- [x] **Update** `FEATURES.md`; renamed this TODO to `DONE.md`.

## Deviations

1. **Six tools carry the ten verbs.** The SPEC lists ten tool names; the
   implementation registers `task_list`, `task_add`, `task_claim`, `task_update`,
   `task_edit`, `task_moderate`. The five update verbs share `task_update` and the
   two moderate verbs share `task_moderate`, discriminated by `op`. Gating is
   **per-verb inside the tool**, so `task_reassign`/`task_delete` still ask while
   their siblings never do — the reach rule is unchanged. Reason: the tools array
   is the largest recurring per-request cost, and this is the same economy the
   board already makes. The ten verb *names* survive in the description and the
   enum, so a model reads the same verbs.

2. **`Transition` checks `IsLegalTransition` explicitly.** The SPEC's guard
   (`AND status = AFrom AND claimed_by = ABy`) says the row is in `AFrom`; it does
   not say `ATo` is reachable. The `claimed_by` half hides this for a normal verb,
   but an operator action (`ABy = ''`) drops that half — leaving a guard that
   would let `done -> claimed` reopen a finished card. Found by a test, fixed
   before the tools were written.

3. **`drop` from `open` needed the "or unclaimed" half.** The SPEC's table says
   drop is guarded by "claimed by me, **or unclaimed**"; a bare `claimed_by = ?`
   refuses an unclaimed card, whose holder is `''`. The guard is now
   `(claimed_by = ? OR claimed_by = '')` for `tsDropped` only.

4. **`OpenCount` and `BlockedCards` were added to `ITaskStore`.** The SPEC's
   `open="4"` example means how many open cards *exist*, which a capped
   `OpenCards` cannot report — forty open cards rendered as `open="3"` before this.
   `BlockedCards` exists because the staleness rule must see blocks held by
   *other* sessions, which `Mine` can never show.

5. **`Claim` return signature:** `var APrevious` (not `out`) and an added
   `out AFound`, so a caller can distinguish "not found" from "not open". The
   original `out` version could not tell them apart.

6. **`TBlockerKind` gained `tbkNone`** as its first ordinal, so a zeroed record is
   "not blocked" rather than "blocked on a card with id 0".

7. **A stale claim is now *recovered*, not only *detectable*.** The SPEC, and the
   risk table in `FEATURE.md` ("Claim-and-vanish"), settled for mitigation by
   visibility: `ClaimedAt` shows, so a stale claim is detectable, and
   `task_reassign` (gated) can take it back. That is a mitigation that needs the
   operator to be present and watching, which is the case least likely to hold on
   a remote device. The claim is deliberately **not a lock** — the CAS guards a
   single transition, it does not hold anything between turns — so a session that
   dies mid-card held it forever.

   Two halves close it, and they belong together (`ITaskStore`, after the tools
   were written):

   - **`RenewClaims`** moves `claimed_at` to now for every card this session
     holds. It is called at the **turn boundary**, because opening a turn *is*
     the heartbeat: an agent that is working never looks dead, and no background
     timer is needed. This is why the lease is a duration rather than a
     liveness probe.
   - **`ReclaimStale`** returns a claim older than the lease to `open`, unheld,
     recording who held it in `done_note`. A card silently reappearing as open
     loses the fact that anyone had it; the note keeps it.

   It never touches a fresh claim (someone is working), an unclaimed card, or a
   finished one. Wired in `THarnessSession` beside `Prune`, both failures
   swallowed — nothing in the tail may fail a turn.

   **Cost:** a session older than the lease that is *not* opening turns is
   indistinguishable from a dead one, so its card can be reclaimed. That is the
   intended trade — a live claim that is silently stale is the bug being fixed —
   but it does mean the lease is a real setting, not a formality.

## Bugs found during implementation

- **`Transition` never called `IsLegalTransition`** — dead code with passing tests.
- **`Edit`/`Delete` returned True on an UPDATE/DELETE matching no rows** — an
  unknown id was a silent no-op, which the SPEC forbids by name.
- **`Claim` took `APrevious` by value**, so the re-read wrote into a local copy and
  the caller never saw the holder. The CAS worked; the message that makes it
  useful was lost.
- **`AKeepDone` was in `Prune`'s signature and unused.**
- **`StaleBlockMinutes` was declared and never read**, and the rule it should have
  driven used `AgeLabel(...) <> ''` — always true. A block held by another session
  could never appear at all.
- **`List` had no tiebreaker** after `updated_at`, so cards added in one second
  came back arbitrarily and the tail named the wrong three.
- **`ReconcileMcpSkills` assigned `StablePrompt := FSkills.StableText`, wiping the
  board prose** — in every session that had a store, i.e. exactly where it
  mattered. Fixed by extracting `ComposeStablePrompt`, called from both Init and
  the reconcile.

Seven of the eight were dead code or an unused branch — the pattern this repo
keeps finding. Each was caught by a test that failed before the fix.

## Notes

- **The CAS is the feature.** Everything else is CRUD; the claim is what turns a
  list into coordination. Its refusal message — who holds it, since when — is the
  product, not an error string.
- **Status is not editable.** Every transition is a verb with an actor, so the row
  answers "who moved this and why".
- **A parent does not auto-close.** "All subtasks done" and "the task is done" are
  different claims.
- **Nothing here may fail a turn.** A tail failure omits the element; a tool
  failure is a tool error.
- **This is not a scheduler.** No assignment, no dispatch, no fairness.
