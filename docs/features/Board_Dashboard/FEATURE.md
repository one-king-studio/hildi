# Feature: Board Dashboard

**Status:** Proposed — no spec yet. A layout mock exists
(`examples/dashboard_mock.pas`, `make dashboard-mock`).

**Related:** [Workspace Board](../Message_Board/FEATURE.md) ·
[Task List](../Task_List/FEATURE.md) ·
[Headless Sessions](../Headless_Sessions/FEATURE.md) ·
[Process Split](../Process_Split/FEATURE.md) ·
[Sessions and Ledger](../Sessions_And_Ledger/FEATURE.md) ·
[Session Management](../Session_Management/FEATURE.md) ·
[Subagents](../Subagents/FEATURE.md)

## Overview

A **separate binary** that shows one workspace's coordination state at a glance:
the message board, the task list as a kanban, and the sessions working in it. The
operator watches and, when needed, posts an announcement that agents pick up on
their next turn.

It is a **viewer with one write**. Everything else it shows is data the harness
already stores; the dashboard just stops requiring an agent as the intermediary
to read it.

## The problem

The harness has grown a coordination substrate — a board with topics, kinds,
questions and answers; a task list with a claim/transition model; sessions with
ledgers and lives. Every one of those was built so that *agents* could coordinate
with each other. None of it is legible to the person running the machine.

Today, to answer "what is happening?", the operator has three bad options:

| Option | Cost |
| --- | --- |
| Ask an agent to run `board_read` / `task_list` | Costs a turn, perturbs the agents, and the answer is a wall of text in a transcript |
| Open `sqlite3` against `store.db` | Requires knowing the schema; the tables are an implementation detail, not a UI |
| Read the TUI | Shows *one* session — the one you are attached to. The other sessions are invisible |

That last row is the sharpest. The [Process Split](../Process_Split/FEATURE.md)
moved the loop out of the UI process deliberately, and the TUI became a client to
**one** session. At the same time the harness gained **many** — subagents, and
several sessions in one workspace. So the architecture created a class of
information (what my peers are doing) that no existing surface displays. The
`/sessions` modal lists sessions; it does not show what they are doing.

The subagent sidebar narrows the gap for *your own* children — and only yours,
only while your TUI is open. It is a per-session view of a per-session tree. The
dashboard is the workspace-level view that none of these are.

**Ponytail check: does this need to be built?** Partly it already is. Three
existing surfaces answer fragments: the `/sessions` modal (who exists), the
subagent sidebar (my children, live), and `board_read` through an agent (content,
at the cost of a turn). The dashboard is justified only if it is *cheaper* than
the alternatives — not a turn, not a schema, not one session. That is the bar it
must clear, and it is why v1 is deliberately read-mostly.

## Goals

- **Legibility.** The workspace's coordination state in one frame: who is
  working, what is claimed, what is waiting on the operator.
- **Zero perturbation.** Watching must not cost an agent a turn, change its
  prompt, or (in the default mode) attach to anything.
- **A channel for the operator.** Announcements reach agents through the board
  they already read, rather than through a new mechanism.
- **A natural home for the next operator tool.** Whatever the operator needs
  next — approvals queue, change review, cost — has somewhere to go.

## User Stories

- As an **operator**, I want to see which sessions are working and what they are
  working on, so that I can tell whether the machine is busy or stuck without
  interrupting anyone.
- As an **operator**, I want the task list as columns I can scan, so that I can
  see what is claimed, by whom, and what is blocked without reading a table dump.
- As an **operator**, I want to leave an announcement for the agents, so that I
  can redirect work without typing a prompt into one session and hoping the
  others notice.
- As an **operator**, I want the board's open questions in front of me, so that I
  know when an agent is blocked *on me* specifically.
- As a **harness author**, I want a second consumer of the store, so that the
  "one binary, one concern" boundary of the [Process Split](../Process_Split/FEATURE.md)
  gets a real test rather than a diagram.

## The shape: three zones

```
╭─ Sessions ────────────╮╭─ Board · coordination ── q 0 · d 0 · f 0 ╮
│ ⠹ main · Board dash…  ││ [answer]  Correction: your answer…  2h -> #1│
│ ○ tasks · Claim rec…  ││ [status]  Four docs files uncomm…   3h      │
│ ✓ docs · The recorder…││ open questions 0 · decisions 0 · all answered│
│ ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈││                                          │
│ ❯ announce to coord…  ││                                          │
╰───────────────────────╯╰──────────────────────────────────────────╯
╭─ Tasks ───────────────────── 4 live · 2 done ───────────────────────╮
│ OPEN 1  │ CLAIMED 1 │ BLOCKED 0 │ DONE 2     │ DROPPED 0            │
│ ┌─────┐ │ ┌───────┐ │           │ ┌───────┐  │                      │
│ │#1 … │ │ │#2 …   │ │           │ │#3 …   │  │                      │
│ └─────┘ │ └───────┘ │           │ └───────┘  │                      │
╰──────────────────────────────────────────────────────────────────────╯
```

**Why this arrangement.** The kanban takes the bottom strip because five columns
need *width* and only about three cards need *height*; placed left or right it
would collapse to two visible columns and lose the left-to-right reading that
makes a kanban a kanban. Sessions and board are both vertical lists, so they take
the upper band and split it.

**Why sessions on the left.** The left edge is where the eye starts, and "who is
doing what" is the question that frames everything else in the frame.

## The hard part: a live turn title does not exist

This is the design decision the rest of the spec hangs on, and the mock does not
solve it.

A session's **title** is extracted from a *completed* reply — `replymeta` parses a
YAML frontmatter block at the turn boundary and stores it per session
(`SetSessionTitle`), with an operator override alongside. So the store can answer:

- the resolved title of the session's **last finished** reply,
- turn/message counts, `updated_at`, pinned/archived,
- the runtime row's pid/socket (advisory; the socket is the authority).

It **cannot** answer "what is this session doing *right now*". That lives only in
the live event stream (`ekLoopStarted`, `ekAssistantDelta`, `ekToolCall`, …) over
the session's Unix socket. There are two honest ways to show near-realtime state:

| Mode | Mechanism | Truthfulness | Cost |
| --- | --- | --- | --- |
| **A — store poll** | Read `sessions`/`turns`/`messages` on a timer | "working" = an unfinished `tsRunning` turn exists; the title is the last finished one | One connection, no attach; a few ms per poll |
| **B — observer attach** | Attach to each session socket as `srObserve`, consume the event stream | Live turn text, streaming tool calls, real "working" state | One socket per session; the dashboard becomes a client of every runtime |

**Decision for v1: mode A, and say so in the UI.** A session shows *"last finished
turn"* plus an elapsed clock, and a turn in flight shows as a spinner with the
turn's start time — not a fabricated title. Mode B is deferred (see [Future
Considerations](#future-considerations)) because attaching an observer to every
session in a workspace is a much larger commitment than it looks: it is a durable
client on every runtime, it must survive runtime restarts, and it changes what
"one driver, many observers" is expected to carry.

The alternative — interpolating a title from the streaming text — would be
*plausible and wrong*, which is the worst combination in an ops surface.

## Reading the store from a second process

The store is SQLite in `WAL` mode with a `busy_timeout`, opened by the runtime and
by every CLI invocation already. A second reader is therefore **supported**, not
novel:

- readers do not block the writer under WAL;
- the dashboard holds a read connection and never holds a write transaction
  across a poll;
- a busy database is a *slow poll*, not an error — the last good snapshot stays on
  screen with its age.

The one rule: **the dashboard never opens the store for writing except to post.**
A viewer that takes a write lock on a 140 MB database to repaint a spinner would
be a self-inflicted outage.

## The one write: an operator announcement

Posting is the dashboard's only mutation, and it is the feature's reason to exist
beyond passive watching.

The board's own model says posting is **ungated** — it cannot mutate the
workspace, it is byte-capped, and gating it would ruin the agent scratchpad.
An operator post inherits that reasoning and adds one more: the operator is the
authority the gates exist to protect, so asking them to approve their own post is
theatre.

### The authorship gap

Every board entry today carries `FromSession` and `FromLabel`, stamped from the
session that posted it. An operator has **no session**. This is unresolved and
must be settled in the SPEC:

| Option | Consequence |
| --- | --- |
| A synthetic session id (`operator`) | Cheapest. Pollutes the session namespace; `ReplyTo` links to an entry whose author is not a session |
| A real origin field (`origin IN (session, operator)`) | Honest and queryable; a migration, and `TBoardEntry` grows |
| Reuse `FromLabel` only, `FromSession = ''` | No migration; `''` already means "not from a session" in the task store's operator actions |

The third is probably right, for consistency with `Transition`'s `ABy = ''`
operator case. The SPEC decides it; the mock does not pretend it is settled.

## Kanban: read-only in v1

The task store supports operator actions already — `Transition` treats `ABy = ''`
as an operator move, bypassing the claim guard. So drag-to-done is *feasible*.

It is **out of scope for v1**, deliberately. A drag is a state transition on work
an agent may be actively holding, and the failure mode is silent: two agents and
an operator all moving a card, with the operator's move looking like a claim that
was never made. Reading columns is cheap and safe; writing them needs its own
design (who wins, what the card's note says, whether the agent is told).

v1 renders the columns, their counts, card holders and ages. It does not move
cards.

## Acceptance Criteria

### Functional Requirements

- [ ] A separate binary (`make dashboard`) that links no agent-loop unit — the
      same closure discipline the TUI client is held to.
- [ ] Three zones: sessions, board (one topic, switchable), tasks as five
      status columns.
- [ ] Sessions show label, resolved title, state, and elapsed; a session with an
      unfinished turn is visibly *working*.
- [ ] Board shows entries newest-first with a kind chip, title, age, and reply
      linkage; the footer states open questions, decisions and findings.
- [ ] Board is readable by topic, with a way to change topic.
- [ ] Tasks show per-column counts and per-card holder and age.
- [ ] The operator can compose and post an announcement to the current topic.
- [ ] A stale read (store busy, runtime gone) leaves the last snapshot on screen
      with its age, never a blank frame or a crash.
- [ ] Every zone is keyboard-navigable; focus is always visible and never colour
      alone.

### Non-Functional Requirements

- [ ] Poll does not block the runtime's writes: no long-lived write transaction,
      WAL readers only.
- [ ] Idle CPU is low: no busy poll, no per-widget timers; one clock.
- [ ] `make check` green and leak-clean; the dashboard does not regress the gate.
- [ ] macOS + Linux; no new dependency.
- [ ] Non-ASCII titles render (the `cwstring`/`UTF8Encode` boundary rules).

## Success Metrics

### Quantitative

- **Time to answer "who is working?"** — under 2 s from launch on a warm store.
- **Poll cost** — a full three-zone refresh under ~10 ms on a 10³-entry board.
- **Perturbation** — zero agent turns spent answering operator questions that the
  dashboard now answers (currently one per question).
- **Startup** — a first frame painted before the first poll completes.

### Qualitative

- The operator can tell "stuck" from "busy" without opening a transcript.
- An announcement is posted in one focus cycle, not a schema.
- The frame is readable at 100×30 without truncating the question count.

## Constraints

### Technical

- Free Pascal 3.3.1, `{$mode delphi}`; `cthreads` first, `cwstring` next.
- The store is read through its existing interfaces (`IBoardStore`,
  `ITaskStore`, the session listings) rather than raw SQL where a store method
  exists — the schema is the store's business.
- Must honour the [Process Split](../Process_Split/FEATURE.md) boundary: a
  dashboard that links the agent loop has re-merged two processes by accident.

### Business / Time

No deadline. v1 is a viewer; the only write is the announcement.

## Dependencies

### Internal

- **Board** (`IBoardStore`: `Read`, `Toc`, `Append`, topic locks) — see
  [Workspace Board](../Message_Board/FEATURE.md).
- **Task List** (`ITaskStore`: `List`, `OpenCount`, `BlockedCards`) — see
  [Task List](../Task_List/FEATURE.md).
- **Sessions** (`ListSessions`, `ListSessionRows`, the runtime row) — see
  [Sessions and Ledger](../Sessions_And_Ledger/FEATURE.md).
- **TUI toolkit** (`tui.*`) for the frame, themes, and input.
- **Store** (`hildegard.helper.store`, vendored SQLite) as the read connection.

### External

None. No new dependency; no network.

## Risks

- **A snapshot that looks live and isn't.** Mitigation: the age of the read is
  always on screen; "working" means an unfinished turn, not a guess; the UI never
  interpolates a title. This is the same failure the board's `q` count had — a
  number that kept saying "someone is waiting" after the answer landed.
- **A stale runtime makes the whole view lie.** The runtime is a detached
  process; a rebuilt binary does not restart it. Mitigation: show the runtime's
  start time and the poll age side by side, so "old process" is visible rather
  than inferred.
- **Polling a large database.** The store here is ~140 MB. Mitigation: poll
  cheap aggregates (`Toc`, `OpenCount`) rather than full rows on every tick;
  full lists only on change or on demand.
- **The authorship gap leaks into the schema.** Mitigation: settle it in the
  SPEC before implementing, rather than discovering it in a migration.
- **Scope creep into a control plane.** The seductive next step is drag-to-done,
  then reassign, then approve. Mitigation: v1 is a viewer with one write; every
  further verb needs its own justification (this doc names the reason for each
  deferral).
- **Two surfaces disagreeing.** The TUI shows one session; the dashboard shows all
  of them. Mitigation: they read the same store, and the dashboard never renders
  a live turn it did not attach to.

## Out of Scope

- **Live turn text** (mode B). Deferred; see Future Considerations.
- **Kanban mutation** — dragging cards, claiming, reassigning.
- **Approvals.** An approval must go to the session that asked; a queue in a
  separate window would be a second, conflicting approver.
- **Chat.** The dashboard does not drive a session. Driving stays in the TUI.
- **Write access to the workspace.** No file tools, no shell.
- **Remote / network.** Local only, same as everything before
  [Remote Agent Link](../Remote_Agent_Link/FEATURE.md).
- **Multi-workspace.** One workspace per process in v1.

## Future Considerations

- **Mode B: observer attach.** Attach as `srObserve` per session for real live
  titles, streaming tool calls, and true "working" state. This is the natural v2
  and the reason to keep the driver seam clean.
- **Kanban mutation**, designed properly: operator transitions, what the card note
  records, how the holding agent is told.
- **Change review.** The [Workspace Snapshots](../Workspace_Snapshots/FEATURE.md)
  TUI surface is unbuilt, and per-turn diffs are the operator's most-requested
  kind of visibility. The dashboard is a plausible home.
- **Cost and throughput.** Turn stats already exist per session; the dashboard is
  where they belong at workspace level.
- **A `--watch` text mode** for SSH: the same three zones as plain lines, no
  alternate screen. Cheap, and it would let the binary run over a pipe.

## Notes

- **The mock is the design.** `examples/dashboard_mock.pas` renders all three
  zones from static data pasted in from a real workspace, so the layout could be
  judged before any store code was written. It reads nothing and writes nothing.
  **It has not been visually verified** — it compiles and links, but no headless
  render has been dumped. Do that first; layout bugs found by eye are cheap.
- **Why a second binary rather than a TUI panel.** The TUI is a client of one
  session; the dashboard is a view of the workspace. Making it a panel would
  either give the TUI a second data source with a different lifetime, or force
  the operator to attach to a session to see the others. Separate binary keeps the
  Process Split honest and lets this be read-only.
- **Why the kanban is the right task view here.** The task list's tail shows a
  capped list of open cards because tails are prompts. A dashboard has a screen,
  so it can show the real shape: every status, the true counts, and which column
  is backing up.
- **ICE score.** Impact **7** (the operator's blind spot is real and growing with
  the number of sessions), Confidence **7** (the data all exists; the one
  unknown is the authorship field), Ease **6** (a mock already exists; the work is
  polling, layout fidelity and one write). Total **20/30** — worth building, after
  the in-flight correctness work rather than ahead of it.
