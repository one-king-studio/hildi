# Feature: Task List

**Status:** Proposed.

**Related:** [Workspace Board](../Message_Board/FEATURE.md) ·
[Subagents](../Subagents/FEATURE.md) ·
[File Changes](../File_Changes/FEATURE.md) ·
[Context Checkpoint](../Context_Checkpoint/FEATURE.md) ·
[workspace-changes-and-board](../../research/workspace-changes-and-board.md)

## Overview

A **long-lived, shared task list per workspace** — a Trello-shaped board the
agents work from rather than a todo list one agent keeps in its head.

A task outlives a turn, a session, and a context window. It can be claimed by
exactly one agent at a time, blocked on something specific, decomposed into
subtasks, and completed or dropped with a reason. Several agents sharing a
workspace see the same list and can claim different cards instead of colliding on
the same work.

This is **not** the [Workspace Board](../Message_Board/FEATURE.md). That is an
append-only record of what was said and what is known; this is mutable state
about what is being done. The distinction is the whole reason they are separate
features, and it is set out below.

## Why this is separate from the board

A board entry is an **append-only fact**: it is never edited, a correction
supersedes it, and the history is the point. A card's status is **mutable state**
by definition — `open` → `claimed` → `done` is the entire idea.

One table cannot hold both disciplines:

- Edit a board entry in place and you lose `"why did we believe that then?"`, plus
  any hope of concurrent agents not clobbering each other.
- Model a card as an append-only log of transitions and every query becomes a
  scan, the board fills with `moved to done` noise, and the tail block — which is
  the one scarce resource — pays for it.

So: **append-only for what was said, mutable for where it is.** Two tables, two
features, and one shared mechanism (the tail block) so the agent sees both in one
place.

| Question | Answered by |
| --- | --- |
| What do we know? What was decided? Who asked what? | [Workspace Board](../Message_Board/FEATURE.md) |
| What is left? Who is doing what? What is blocked? | **Task List** |

## The problem

Today an agent plans inside a turn and forgets at the boundary:

- **Plans die with the turn.** A five-step plan announced in turn 3 is gone by
  turn 4 unless it is re-read out of the message history.
- **Nothing survives a resume.** A resumed session restarts from the ledger,
  which records *messages*, not *intentions*.
- **Parallel agents duplicate work.** Ten subagents told "fix the tests" all fix
  the same test, and nothing anywhere records that card #41 is already taken.
- **The operator cannot see the plan.** The only view of intended work is the
  model's reasoning, which is prose.

Ponytail check: could this be a board `note` or a `HANDOFF.md`? A note has no
lifecycle and no ownership; a handoff file is prose the agent must parse and
re-write wholesale. Neither can answer "what is unclaimed" in one query, which is
the whole purpose.

## The card

```pascal
TTaskStatus = (tsOpen, tsClaimed, tsBlocked, tsDone, tsDropped);

TTaskCard = record
  Id: Integer;
  Title: string;             // required, one line
  Body: string;              // optional: acceptance criteria, context
  Status: TTaskStatus;
  ClaimedBy: string;         // a session id; '' when unclaimed
  ClaimedAt: Int64;
  StatusAt: Int64;           // when it entered its current status
  BlockedOn: Integer;        // 0 => not blocked; else a card or question id
  Parent: Integer;           // 0 => top level; ONE level of nesting
  Position: Integer;         // manual order within its column
  FromSession, FromLabel: string;   // who created it
  CreatedAt, UpdatedAt: Int64;
end;
```

### Five statuses, and why exactly these

| Status | Means | Set by |
| --- | --- | --- |
| `open` | nobody has it | creation |
| `claimed` | I am working on it | the claimant |
| `blocked` | waiting on something **named** | the claimer |
| `done` | finished | the claimer |
| `dropped` | deliberately abandoned, with a reason | the claimer or a moderator |

`blocked` requires `BlockedOn` to point at something real — another card, or a
board `question`. That is the one pointer that earns its place: a card blocked on
nothing is just an `open` card with anxiety, while a card blocked on *something
named* is what makes the dependency graph inspectable. An orchestrator can then
answer "what is the critical path" without reading prose.

### One level of nesting, deliberately

`Parent` is a single level: a card may have subtasks, a subtask may not. Arbitrary
depth brings cycle detection, orphan handling, and completion-rollup semantics
(does a parent close when its children do?) for a capability nobody has asked
for. One level is a checklist; deeper is a project manager.

A parent does **not** auto-close when its children finish. It is `done` when
somebody says so, because "all subtasks done" and "the task is done" are
different claims and conflating them hides incomplete thinking.

## Claiming is the coordination primitive

`task_claim(id)` is a **compare-and-swap**: it succeeds only when
`Status = tsOpen`. Two agents reaching for the same card, one wins, and the other
is told `already claimed by session 9afd… since 14:03`.

This is the same discipline as hash-anchored CAS on file writes — turn a silent
double-work into a visible conflict — applied to *work* rather than bytes. It is
the closest thing to real coordination this design offers, and it is also the
place to be precise about what it does not do:

- **It prevents two agents from starting the same card.** It does not prevent two
  agents from fixing the same bug under two different cards. That is a
  decomposition problem, not a locking one — a well-decomposed tree makes
  duplicate cards visible as siblings rather than invisible as strangers.
- **A claim is a courtesy, not a lock.** Nothing prevents an agent ignoring the
  list. The forcing function is that duplicate work becomes visible.

`task_release` returns a claim to `open` (I have changed my mind), and
`task_reassign` moves a claim to another session — the latter behind approval,
since it takes work away from an agent mid-flight.

## The tail block gets a work queue

The board's tail shows a table of contents ("you know some things"). The task
list's shows a **job**:

```
<tasks mine="#41 wire the board drain" open="4" blocked="#38 on #37">
  #43 parser: $() guard · #44 dry-run flag · #45 +1 more
</tasks>
```

Roughly 60 tokens. Three parts, deliberately asymmetric:

- **`mine`** is always shown — it is the agent's own commitment, and losing it
  mid-turn is how work gets abandoned.
- **`open`** is capped at three, most-recently-touched first, with a `+N more`
  count. A full list would let a big backlog crowd out everything else in the
  tail.
- **`blocked`** is shown only when the block is *this* agent's, or when it has sat
  longer than a threshold. A blocked card nobody owns is the orchestrator's
  problem, not every agent's.

Budget it hard: this rides every request for the life of the session.

## Tools

| Tool | Effect | Gate |
| --- | --- | --- |
| `task_list(status?, mine?)` | read cards | none |
| `task_add(title, body?, parent?)` | create a card, `open` | none |
| `task_claim(id)` | CAS `open` → `claimed` by me | none |
| `task_release(id)` | my claim → `open` | none |
| `task_block(id, blocked_on)` | my claim → `blocked`, naming the blocker | none |
| `task_unblock(id)` | `blocked` → `claimed` | none |
| `task_done(id, summary?)` | `claimed` → `done` | none |
| `task_drop(id, reason)` | `claimed`/`open` → `dropped` | none |
| `task_edit(id, title?, body?)` | amend text, **not** status | none |
| `task_reassign(id, session)` | move a claim to another agent | **approval** |
| `task_delete(id)` | remove a card | **approval** |

The gating rule is the same one the board uses — gate what has reach:

- **Everything on your own claim is ungated.** Claiming, blocking, finishing, and
  releasing change only what *you* are doing, and a false `done` is visible and
  correctable.
- **Destructive or other-taking operations are gated.** `task_delete` destroys
  history; `task_reassign` takes work away from another agent mid-flight. Both are
  the moderator-class moves the board already gates.
- **`task_edit` may not change status.** Status transitions go through the verbs
  above so each one is attributable and reason-carrying; a free-form status edit
  would let an agent silently reopen or close anything.

## Retention

- **`done` and `dropped` cards are retained** for a bounded window (count and
  age), then pruned. They are a work record, not knowledge: once a task is
  finished, its value is in the *commit* and the board's `decision`/`finding`
  entries, not in the card.
- **Open, claimed and blocked cards are never pruned.** They are live state; a
  memory system that forgets what is unfinished is worse than no list.
- Pruning is skipped entirely if a task references an unfinished card or is
  referenced by one.

## Where this stops being a scheduler

Stated plainly, because "Trello for agents" invites the wrong expectation:

- **The list does**: publish intended work, let an agent claim it, show what is
  claimed by whom and what is stuck.
- **The list does not**: decide who does what. There is no dispatcher handing
  card #41 to a free agent, no fairness, no load balancing, no priority
  inversion prevention. Nothing is *assigned*; things are *taken*.
- **The forcing function is social.** An agent honours a claim because the
  alternative is visible duplication — not because the system enforces it.

The test for the boundary: **swap the agents for ten humans.** If the design
still makes sense, it is a work list. If it only works with something deciding
for them, it is a scheduler and belongs somewhere else.

## Relationship to a within-turn todo

Deliberately **not provided**, and not by this feature either. The two have
opposite economics:

| | Within-turn todo | Task card |
| --- | --- | --- |
| Lifetime | one turn | days |
| Owner | exactly one agent, never shared | claimable by any |
| Visibility | the operator, maybe | every agent in the workspace |
| Cost of a stale entry | zero — it dies with the turn | rot, and it crowds the tail |
| Storage | nowhere; loop state | durable |

If an in-turn checklist is ever wanted it belongs in the loop as ephemeral state
with no storage and no tail presence. Unifying them is how a task list becomes an
unreadable log of every turn's scratch work.

## Relationship to the board

They compose rather than overlap:

- A card is **work**; a board `finding` is **what the work discovered**. Finishing
  a card is a natural moment to post the finding it produced.
- A card blocked on a board `question` is how coordination actually happens:
  post the question, block the card on it, and an answer both notifies and
  unblocks. `BlockedOn` accepting a question entry id is what lets the two
  features cooperate without either knowing much about the other.
- Both ride the tail, so the agent sees its knowledge summary and its work queue
  in one place.

## Acceptance Criteria

### Functional

- [ ] `task_add` creates an `open` card; no approval.
- [ ] `task_claim` succeeds only from `tsOpen`; a second claim is refused with the
      current holder and its claim time.
- [ ] `task_block` requires a `blocked_on` that resolves to a real card or board
      question.
- [ ] `task_done` and `task_drop` record who and when; `task_drop` requires a
      reason.
- [ ] `task_reassign` and `task_delete` require approval; a denial changes
      nothing.
- [ ] `task_edit` cannot change status.
- [ ] A card may have subtasks to exactly one level; a deeper parent is refused.
- [ ] A parent does not auto-close when its subtasks finish.
- [ ] The tail block shows `mine`, up to three `open`, and blocks worth seeing,
      within a fixed budget.
- [ ] `done`/`dropped` cards are pruned by age and count; open/claimed/blocked
      never are.

### Non-Functional

- [ ] Every status transition is attributable and timestamped.
- [ ] Claiming is atomic under concurrent agents (a single CAS statement, not a
      read-then-write).
- [ ] The tail cost is fixed and does not grow with the number of cards.
- [ ] No new dependency; rides the vendored SQLite.
- [ ] `make check` green; leak-clean.

## Success Metrics

- An agent that planned five steps in turn 3 can resume them in turn 40 with one
  tool call.
- With two agents and one card, exactly one claim succeeds and the other is told
  who holds it.
- A resumed session can answer "what is left and who has it?" from the list.
- The tail cost stays under ~60 tokens with 100 cards on the list.

## Non-Goals

- **Not a scheduler.** No assignment, no dispatch, no fairness (see above).
- **Not a Gantt chart.** No dates, durations, estimates, or critical-path
  computation. `blocked_on` gives a dependency *edge*, not a schedule.
- **Not the board.** Knowledge and decisions stay on the
  [Workspace Board](../Message_Board/FEATURE.md).
- **Not a within-turn todo.** That would be ephemeral loop state, not this.
- **Not a ticket system.** No priorities, labels, sprints, or story points.
- **Not an approval mechanism.** A card is a plan, never authority.

## Out of Scope

- The operator UI (a `/tasks` board view) — designed for, built later, on the same
  seam `/sessions` uses.
- Multiple named boards or configurable columns per workspace (that is Jira).
- Time tracking.
- Cross-workspace tasks.

## Risks

- **It becomes a graveyard.** Cards are created and never closed, and the tail
  fills with ancient `open` items. Mitigation: a `dropped` verb with a reason
  (so abandonment is a decision, not neglect), and the tail capping `open` to the
  most recently touched.
- **Agents create cards instead of doing work.** Mitigation: a per-turn creation
  cap, and the tail showing `mine` first so a queued backlog is not an escape
  hatch from the current card.
- **Claim-and-vanish.** An agent claims a card and dies. Mitigation: `ClaimedAt`
  is visible, so a stale claim is detectable; reassignment exists and is gated.
- **Decomposition thrash.** Agents split work endlessly. Mitigation: one level of
  nesting, hard.
- **Duplicated cards.** Two agents create the same task. Mitigation: none
  structural — visible duplication is the forcing function, as with claims.

## Notes

- **Why the tail must show `mine` first.** The single most expensive failure in a
  multi-agent setup is a half-finished task nobody remembers starting. It costs
  ~15 tokens to prevent and nothing to display.
- **Why `blocked_on` points at a board question.** It is the one field that makes
  the two features cooperate: asking a peer and blocking on the answer is the
  whole coordination loop, and it needs no new mechanism.
- **Why status is not editable.** Every transition is a verb with a reason and an
  actor, so the history answers "who moved this and why" — the same property the
  board's supersession gives knowledge.
