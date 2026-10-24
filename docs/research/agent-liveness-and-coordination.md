# Agent Presence, Liveness, and Coordination

**Status:** Design settled 2026-10-24. Implementation not started.

**Depends on:** [Message Board](../features/Message_Board/FEATURE.md),
[Task List](../features/Task_List/FEATURE.md),
[Workspace Changes](../features/File_Changes/FEATURE.md).

**Related:** [`workspace-changes-and-board.md`](workspace-changes-and-board.md) —
the original double-duty design this refines.

## The one rule everything follows from

> **A session id is a long-lived identity. A runtime row is a live process.
> Everything about *presence* reads the runtime; everything about *history*
> reads the session.**

That sentence resolves revival, liveness, claims, cursors, and named agents
consistently. Where this document and older prose disagree, this document wins.

## The principle underneath every decision

**Never let an absence look like a fact.**

Every rule below is an instance:

- unread is `≥N`, never a confident `N`
- "the board has been pruned since you last read", never an invented count
- a revived session is *old*, not *current*
- a solo workspace is not *uncoordinated*, it is *alone*
- a new session did not *miss* anything; it was not there

This is the same failure class as three bugs found earlier in the project: a guard
that disowned its own advisory, a pure command that hid its substitution, and a
`q=` count that never cleared after an answer. Each stated something the system
could not actually know.

## 1. Identity: session vs. runtime

| | Session | Runtime |
| --- | --- | --- |
| Table | `sessions` | `session_runtimes` |
| Lifetime | months | as long as the process |
| Carries | `id`, `label`, `depth`, cursor, claims | `pid`, `socket_path`, `status`, heartbeats |
| Answers | "who is this, what did it do" | "is it here *now*" |

**Revival is the same session id.** A new session id is a **different agent**, with
no inherited history — that is the point of long-lived sessions.

**Named agents (future)** are therefore close to free: a stable session id plus a
`label` and role metadata. `sessions.label` and `sessions.depth` already exist. Do
not introduce a second identity concept until something genuinely needs one.

### Two kinds of co-presence, and they are not the same problem

| | **Subagents** | **Peer sessions** |
| --- | --- | --- |
| Who starts it | a parent session, via `delegate_task` | **the operator**, by opening another instance |
| Structure | parent → child, `depth > 0`, lineage | flat; no rank, no lineage |
| Lifetime | short; ends when the task does | long; a session can live for months |
| Authority | child reports up, parent decides | nobody decides; peers negotiate |
| Termination | parent may `abort_task` | nobody may terminate a peer |
| Sharing | inherits the parent's workspace | shares a workspace by coincidence of cwd |

**"Multi-agent" in this design means PEER SESSIONS**, not subagents. The operator
opening a second instance is the case every rule here exists for: two long-lived
sessions, neither in charge, each with its own context, meeting in a shared
workspace.

Subagents are a *different* pattern and mostly a solved one: lineage gives them an
owner, so coordination is dispatch and a child does not negotiate with a sibling.
Applying peer rules to them would be wrong — a child does not "agree protocols by
consensus" with its parent.

**Consequence for detection.** `DetectCoordinationMode` currently reports
multi-mode when `depth > 0` (`crSpawnedChild`). That is correct — a spawned child
genuinely is not alone — but it must not be conflated with `crPeerRuntime`, which
means *another independent session is live here*. The two reasons produce the same
mode today yet call for different behaviour:

- `crSpawnedChild` — coordinate with a known owner; the parent decides.
- `crPeerRuntime` — coordinate with an equal; there is no decider.

### Dead subagent vs. dead peer

The impersonation risk differs, and this is the part worth stating plainly:

- A **dead subagent** belonged to a parent that is still live. The parent is
  responsible for its claims, and lineage makes the owner findable.
- A **dead peer** has **no owner**. Nothing but liveness says it is gone, and no
  one may terminate it on its behalf.

So heartbeat-plus-expiry is load-bearing for peers specifically. For subagents,
`abort_task`/`release_task` is the primary path and expiry is the backstop.


## 2. Liveness is the authority; the claim lease narrows

### The defect this fixes

`DefaultClaimLeaseSec = 30 * 60`, renewed at the **turn boundary**. That is an
*activity* signal standing in for a *liveness* signal. It produces a false negative
we documented ourselves:

> an agent that thinks for over 30 minutes without opening a turn loses its card.

and a two-clock problem: a heartbeat measures seconds, the lease measures turns,
and the two disagree about the same fact.

### The rule

| Question | Answered by |
| --- | --- |
| Is this session alive? | **runtime heartbeat** — an existence fact |
| Is this *live* session still working on this card? | **claim lease** — an intent fact |

So the lease does not disappear; it **narrows** from "is it alive?" (which we now
know) to "is it still interested?" (which we cannot know, so we infer from
elapsed time).

Consequences:

- A session whose runtime row is **gone** has its claims reclaimed **immediately**.
  No waiting out a lease for a fact we can observe.
- A session that is **live** but stopped working keeps the lease, because
  abandonment and death are different conditions.
- Renewal moves to the **heartbeat**, not the turn boundary. Thinking no longer
  costs you your card.

## 3. Heartbeat

Runs on the runtime tick, unconditional in every mode.

- Stamps `session_runtimes.updated_at`.
- Renews the session's claim clock (`RenewClaims`) — the same call the turn
  boundary makes today, on a better clock.
- A runtime whose row is not renewed within `RuntimeExpirySec` is **expired**: the
  row is removed, and its claims become reclaimable.

**Deregistration on shutdown is best-effort.** A clean exit calls `ClearRuntime`
(already implemented, `session.runtime.pas:443`); a crash cannot, so expiry is the
backstop. Correctness must not depend on a graceful exit.

### Why the heartbeat is unconditional

It is one `UPDATE` per tick. Making it conditional on multi-mode creates a
transition race: a solo agent's claims go unrenewed because "single mode needs no
coordination", a peer joins, and the first reclaim steals live work. The ambient
mode-change notice would arrive **after** the damage.

**Only the notices are conditional. Renewal is not.**

## 4. Board cursors and revive honesty

Storage: `board_reads (session_id, last_id)`, already keyed by session.

| Event | Cursor behaviour |
| --- | --- |
| `board_read` | advances to the highest id read |
| a notice (`NoticeBoard`, per tick) | **reads** the cursor, never advances it |
| **revival** (same session id) | **keeps** the cursor; reports the gap |
| **new session** | **starts current**, not at zero |

That last row matters: a brand-new agent did not miss 200 messages — it was not
there. Greeting it with a backlog is the same category of error as an invented
unread count.

### Unread must be honest about pruning

Only `note` and `status` are pruned; `decision`, `finding`, `question` and
`answer` never are. So a cursor can point at ids that no longer exist:

- Report **`≥N unread`** with an explicit note that the board has been pruned.
- Never compute an exact "you missed 47" — if pruning ran while nobody watched we
  cannot distinguish 47 from 200. State what is known: *pruned since*.

### Recording the gap

A reset is an **event**, not a silent no-op. Add `last_seen_at` to `board_reads`
and surface it once:

> "You were away since <time>. The board has been pruned since you last read.
> ≥N entries are readable now."

Without this the revived session is confidently *wrong* rather than merely uninformed.

### Revival notice also reports lost claims

A revived session has probably had its claims reclaimed — correctly, because it was
dead. It returns believing it holds work it does not. The notice should say so:

> "You held #41 and #43; both were reclaimed while you were away."

`ReclaimStale` already records the former holder in `done_note`, so this is
assembly rather than new storage.

## 5. Staleness: contribution survival, not a timer

**Primary rule:** a session is *part of the conversation* if any of its entries
survives on the board. If none do, it is a stranger and starts current.

This is self-describing and needs no threshold, which is why it is primary. A
time-based cutoff (`StaleSessionSec`) is a backstop, not the rule.

**Open question, decided deliberately rather than by accident:** does "surviving"
count `note`? Notes are pruned, so a session that only ever posted scratch notes
becomes a stranger fastest. Either answer is defensible; it must be chosen.

## 6. Conditional coordination

`DetectCoordinationMode` already returns `cmSingle` / `cmMulti` / `crUnknown`.

| | Single mode | Multi mode |
| --- | --- | --- |
| Board as journal | yes | yes |
| Heartbeat + claim renewal | **yes** | yes |
| Cross-session unread | no | yes |
| Mode notices | n/a | yes |

**"Conditional coordination" means the machinery is conditional, never the
board's usefulness.** A solo agent journaling decisions to the board is the
original double-duty design and must keep working.

### Mode transitions raise an ambient notice

- `cmSingle → cmMulti`: "another session joined; switch to coordination mode."
- `cmMulti → cmSingle`: "you are alone again."

Because renewal is unconditional, the transition changes *behaviour* and never has
to repair *state*.

## 7. Addressing: two distinct notions, never merged

`TBoardEntry.ReplyTo` already exists and `board_post` accepts it.

| Notion | Means | Used by |
| --- | --- | --- |
| **answered** | a live `answer` replies to it | the `q=` count |
| **has responses** | any live entry replies to it | a new "traction" count |

These must stay separate. Broadening "answered" to any kind would silently stop
every question with a reply from counting as open — the same class of quiet
semantic change as the `q=` bug itself.

## 8. Scope: coordination, not persistence

**This is the correction this document exists to make.**

| | Coordination state | Durable artifact |
| --- | --- | --- |
| Examples | who is alive, who holds #41, what did we agree yesterday | specs, decisions, the SDD chain |
| Lives in | board / task tables | **files in the repo** |
| Lifetime | pruned by policy | forever, diffable, reviewable |
| Visible to | agents with a dashboard | anyone who clones |

**An artifact that must survive a clone belongs in a file.** The board is for what
is true *now*.

### The failure mode to name

The board is frictionless, so it **quietly replaces the durable record**. Design
reasoning written into a card body because the card was open is:
- invisible to anyone reading the repo,
- pruned by retention policy,
- lost entirely on a fresh clone.

That is worse than the alternative, because the loss is **silent**.

This project already did it twice during the same session: the `$()` TOCTOU
analysis and the shell coverage decisions were both recorded as card bodies
instead of documents.

### Rules

1. **Reference, never reproduce.** A card may name a doc path. It must not copy
   the doc's content, or there are two versions and no way to tell which is
   current.
2. **Say it where the agent reads it.** The rule belongs in
   `CoordinationStableText`, which rides every request — not only in this file.
3. **The dashboard must not legitimise drift.** A live view that renders board
   state makes ephemeral content *look* durable. It should say what it is.

## 9. File-backed mode (parked)

A workspace may later choose `.hildegard/messages` and `.hildegard/tasks` instead
of SQLite. **Design only; not scheduled.**

The paradox worth recording: persisting the board to files makes it a *durable
artifact*, which is the opposite of §8. That mode is therefore a **different
contract**, not the same board with different storage — a statement that this
workspace wants its coordination history auditable.

Decisions required before implementation:

- **Commit or gitignore?** Committed is an audit trail, but every post is a diff
  and N agents will conflict. Gitignored keeps it ephemeral, just in files.
- **Merge semantics.** SQLite serialises writes; two agents editing one file do
  not. **One file per entry, append-and-supersede** — never a single
  `messages.jsonl`, which two concurrent posts would clobber.
- **Pruning becomes deletion**, and in git the history survives the trim. Feature
  or bug depending on intent.

The merge story is where this succeeds or fails, and it is cheaper to decide than
to retrofit.

## Implementation order

1. **§8 scope correction** — prompt line + docs pass. Cheapest, most preventive,
   independent of everything else.
2. **Ownership rendering** — render `FromSession`/`FromLabel` on board entries and
   cards; show authorship on **open** cards, not just claimed ones (today an open
   card and an abandoned one are indistinguishable).
3. **Presence unit** — heartbeat, expiry, deregistration, and `RenewClaims` moved
   onto the heartbeat. Includes narrowing the lease to abandonment.
4. **Cursor honesty** — `last_seen_at`, `≥N` unread, new-session-starts-current,
   revival notice including reclaimed claims.
5. **Conditional coordination** — cross-session unread (computed on demand, not
   per tick), mode-transition notices.

Steps 3 and 4 are independent and can land in either order.
