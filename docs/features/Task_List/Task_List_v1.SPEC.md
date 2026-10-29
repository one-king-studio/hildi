# Component Specification: Task List v1

**Related Feature:** [FEATURE.md](FEATURE.md)
**Depends on:** `hildi.store` (SQLite + the v13/v14 schema),
`hildi.approval` (reassign and delete only),
`hildi.agent` (`IToolProvider` + the tail block).
Optionally the [Workspace Board](../Message_Board/Message_Board_v1.SPEC.md), for
`BlockedOn` naming a question.
**Depended on by:** nothing (a leaf capability).

## Purpose

A long-lived, shared task list per workspace. A card outlives a turn, a session
and a context window; it can be **claimed** by exactly one agent at a time,
**blocked** on something named, decomposed one level, and completed or dropped
with a reason.

This is **mutable state**, which is exactly why it is not the Workspace Board: a
board entry is an append-only fact, and one table cannot hold both disciplines.

## Prior art and reuse

| Need | Existing | Change |
| --- | --- | --- |
| Persistence + migrations | `hildi.store` | one additive migration (v14 or v15) |
| The tail block | `hildi.wrap.FormatTail` | a `<tasks>` element |
| Provider seam | `IToolProvider` | **reuse**: the task list is a provider |
| Approval | `IApprovalService` | reuse for `reassign` and `delete` |
| The CAS idiom | `changes.log.CheckWrite` | the same shape, applied to a status |

The genuinely new work: the schema, the ten tools, the claim CAS, and the tail
work queue.

## Requirements

### Functional

- [ ] `task_add(title, body?, parent?)` creates an `open` card. **No approval.**
- [ ] `task_claim(id)` succeeds **only** from `tsOpen`; a second claim reports the
      current holder and when they took it.
- [ ] `task_block(id, blocked_on)` requires a `blocked_on` that resolves to a real
      card **or** a board question.
- [ ] `task_done(id, summary?)` and `task_drop(id, reason)` record who and when;
      `drop` requires a reason.
- [ ] `task_reassign(id, session)` and `task_delete(id)` require approval; a denial
      changes nothing.
- [ ] `task_edit(id, title?, body?)` **cannot** change status.
- [ ] A card may have subtasks to exactly **one** level; a deeper parent is refused.
- [ ] A parent does **not** auto-close when its subtasks finish.
- [ ] The tail shows `mine`, up to three `open`, and blocks worth seeing, within a
      fixed budget.
- [ ] `done`/`dropped` are pruned by age and count; open/claimed/blocked never are.

### Non-Functional

- [ ] Every status transition is attributable and timestamped.
- [ ] Claiming is atomic under concurrent agents: a single CAS statement, never a
      read-then-write.
- [ ] The tail cost is fixed and does not grow with the number of cards.
- [ ] No new dependency; rides the vendored SQLite.
- [ ] `make check` green; leak-clean.

## Contracts & Interfaces

### The record

```pascal
unit hildi.tasks;

type
  TTaskStatus = (tsOpen, tsClaimed, tsBlocked, tsDone, tsDropped);

  { What a `blocked_on` may point at. A card is work; a board question is an
    answer someone owes. Both resolve through the same integer, discriminated
    here rather than by guessing from the id space. }
  TBlockerKind = (tbkNone, tbkCard, tbkQuestion);

  TTaskCard = record
    Id: Integer;
    WorkspaceId: Integer;
    Title: string;             // required, one line
    Body: string;              // optional: acceptance criteria, context
    Status: TTaskStatus;
    ClaimedBy: string;         // a session id; '' when unclaimed
    ClaimedAt: Int64;
    StatusAt: Int64;           // when it entered its current status
    BlockedOnId: Integer;      // 0 => not blocked
    BlockedOnKind: TBlockerKind;
    Parent: Integer;           // 0 => top level; ONE level of nesting
    Position: Integer;         // manual order within its column
    FromSession, FromLabel: string;
    DoneNote: string;          // the summary or drop reason
    CreatedAt, UpdatedAt: Int64;
  end;

  TTaskCardArray = array of TTaskCard;

  TTaskFilter = record
    Status: TTaskStatus;
    StatusSet: Boolean;        // False => any status
    Mine: Boolean;             // only cards claimed by the asking session
    Parent: Integer;           // 0 => any; >0 => that card's subtasks
    Limit: Integer;            // 0 => default
  end;
```

### The store seam

```pascal
type
  IBoardQuestionExists = function(AWorkspaceId, AId: Integer): Boolean of object;

  ITaskStore = interface
    ['{B2C3D4E5-6F7A-4B8C-9D0E-1F2A3B4C5D6E}']
    function Add(const ACard: TTaskCard; out AId: Integer;
      out AError: string): Boolean;
    function Get(AWorkspaceId, AId: Integer; out ACard: TTaskCard;
      out AFound: Boolean; out AError: string): Boolean;
    function List(AWorkspaceId: Integer; const AFilter: TTaskFilter;
      out ACards: TTaskCardArray; out AError: string): Boolean;

    { THE CAS. Succeeds only when the card is currently open; returns the holder
      and time when it is not, so the caller can name them. One statement. }
    function Claim(AWorkspaceId, AId: Integer; const ABy: string;
      out APrevious: TTaskCard; out AClaimed: Boolean; out AError: string): Boolean;

    { A guarded transition: the card must currently be in AFrom and claimed by
      ABy (unless ABy is '' for an operator action). Returns False + AError when
      the guard fails, naming the actual state. }
    function Transition(AWorkspaceId, AId: Integer;
      AFrom, ATo: TTaskStatus; const ABy: string;
      ABlockedOnId: Integer; ABlockedOnKind: TBlockerKind;
      const ADoneNote: string; out AError: string): Boolean;

    function Edit(AWorkspaceId, AId: Integer; const ATitle, ABody: string;
      out AError: string): Boolean;
    function Delete(AWorkspaceId, AId: Integer; out AError: string): Boolean;

    { Retention: drop finished cards beyond a window. Never touches live state. }
    function Prune(AWorkspaceId, AKeepDone: Integer;
      out AError: string): Boolean;
  end;

type
  TSqliteTaskStore = class(TInterfacedObject, ITaskStore)
    constructor Create(AStore: TSqliteStore);
  end;
```

### The tools

```pascal
const
  TaskListToolName     = 'task_list';
  TaskAddToolName      = 'task_add';
  TaskClaimToolName    = 'task_claim';
  TaskReleaseToolName  = 'task_release';
  TaskBlockToolName    = 'task_block';
  TaskUnblockToolName  = 'task_unblock';
  TaskDoneToolName     = 'task_done';
  TaskDropToolName     = 'task_drop';
  TaskEditToolName     = 'task_edit';
  TaskReassignToolName = 'task_reassign';
  TaskDeleteToolName   = 'task_delete';

type
  TTaskTool = class
  public
    constructor Create(const AStore: ITaskStore; AWorkspaceId: Integer;
      const ASessionId, ALabel: string; AService: IApprovalService;
      AQuestionExists: IBoardQuestionExists);
    procedure Register(ATools: TToolRegistry);
    { Public for direct testing. One method per tool, matching TToolHandler. }
    function ListCards(const AArgumentsJson: string; out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function AddCard(const AArgumentsJson: string; out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    { Claim/release/block/unblock/done/drop share one transition helper; each has
      its own entry point so the handler signature stays uniform. }
    function ClaimCard(const AArgumentsJson: string; out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function TransitionCard(const AArgumentsJson: string;
      out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function ModerateCard(const AArgumentsJson: string;
      out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;
```

## Architecture

### Schema (additive migration)

```sql
CREATE TABLE task_cards (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  workspace_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  status INTEGER NOT NULL DEFAULT 0,      -- tsOpen
  claimed_by TEXT NOT NULL DEFAULT '',
  claimed_at INTEGER NOT NULL DEFAULT 0,
  status_at INTEGER NOT NULL DEFAULT 0,
  blocked_on_id INTEGER NOT NULL DEFAULT 0,
  blocked_on_kind INTEGER NOT NULL DEFAULT 0,
  parent INTEGER NOT NULL DEFAULT 0,
  position INTEGER NOT NULL DEFAULT 0,
  from_session TEXT NOT NULL DEFAULT '',
  from_label TEXT NOT NULL DEFAULT '',
  done_note TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_tasks_ws_status ON task_cards (workspace_id, status, position);
CREATE INDEX idx_tasks_ws_parent ON task_cards (workspace_id, parent);
CREATE INDEX idx_tasks_ws_claim  ON task_cards (workspace_id, claimed_by);
```

### The claim CAS, in one statement

```sql
UPDATE task_cards
   SET status = ?, claimed_by = ?, claimed_at = ?, status_at = ?, updated_at = ?
 WHERE workspace_id = ? AND id = ? AND status = ?   -- 0 == tsOpen
```

`sqlite3_changes` distinguishes the two outcomes: 1 means this caller won, 0 means
someone else holds it (or it is no longer open), and the caller then re-reads the
row to name the holder. That is the whole concurrency story — no lock, no lease,
and no held state across a model's thinking time, which is the reason a literal
lock was rejected in the FEATURE.

`Transition` uses the same guard shape (`AND status = AFrom AND claimed_by = ABy`),
so a stale actor cannot drive a card it no longer owns.

### Statuses and legal transitions

| From | To | Verb | Guard |
| --- | --- | --- | --- |
| — | `open` | `task_add` | parent exists and is top-level |
| `open` | `claimed` | `task_claim` | — (the CAS) |
| `claimed` | `open` | `task_release` | claimed by me |
| `claimed` | `blocked` | `task_block` | claimed by me; blocker resolves |
| `blocked` | `claimed` | `task_unblock` | claimed by me |
| `claimed` | `done` | `task_done` | claimed by me |
| `claimed`/`open` | `dropped` | `task_drop` | claimed by me, or unclaimed |
| any | any | `task_edit` | **status is not editable** |

`task_done` from `open` is refused: finishing what nobody claimed hides who did
it, and the claim is the attribution.

### One level of nesting

`task_add(parent=X)` is allowed only when `X` is `tsOpen`-or-later and itself has
`parent = 0`. A card with a parent may not be a parent. This is enforced at add
time and re-checked in `Transition` if a card is ever reparented (v1 does not
offer reparenting, so the check exists to reject a forged `parent`).

A parent does **not** auto-close when its children finish — "all subtasks done"
and "the task is done" are different claims.

### The tail work queue

Contributed through `IToolProvider.PromptFragment`, so it rides the same tail as
the board's TOC and the skills state. **Budget: 400 bytes** — larger than the
board's 120 because a work queue is only useful if the cards are named.

```
<tasks mine="#41 wire the board drain (14m)" open="4" blocked="#38 on #37">
  #43 parser: $() guard · #44 dry-run flag · #45 +1 more
</tasks>
```

Three parts, deliberately asymmetric:

- **`mine`** — always shown. It is the agent's own commitment, and losing it
  mid-turn is how work gets abandoned. ~20 tokens well spent.
- **`open`** — at most three, most recently updated first, then `+N more`. A large
  backlog must not crowd out everything else in the tail.
- **`blocked`** — only when the block is *this* session's, or has sat longer than
  `StaleBlockMinutes` (default 30). A blocked card nobody owns is the
  orchestrator's problem, not every agent's.

Drop order under budget pressure: the `open` list first (down to zero, keeping the
count), then `blocked`, then the `mine` duration — never `mine` itself.

### Retention

- `done`/`dropped` cards are pruned by count (default 200 kept) and age.
- `open`/`claimed`/`blocked` are **never** pruned.
- A card referenced as another card's `parent` or `BlockedOnId` is never pruned,
  even if finished: the reference would dangle.

### Gating, by reach

| Ungated | Gated |
| --- | --- |
| `task_list`, `task_add`, `task_claim`, `task_release`, `task_block`, `task_unblock`, `task_done`, `task_drop`, `task_edit` | `task_reassign`, `task_delete` |

Everything on your **own** claim changes only what you are doing, and a false
`done` is visible and correctable. `task_reassign` takes work away from another
agent mid-flight; `task_delete` destroys the record. Both ask, `ref` =
`'task:moderate'`, with the card's title in the summary.

## Validation and error handling

- An unknown `id` is an error naming the id, never a silent no-op.
- `task_claim` on a non-open card reports **who holds it and since when**; that
  message is the feature's whole point and must not be generic.
- `task_block` with a `blocked_on` that resolves to neither a live card nor a board
  question is refused, naming what was tried.
- `task_drop` without a reason is refused.
- `task_add` with a `parent` that does not exist, is itself a subtask, or is in
  another workspace is refused.
- A store failure in the **tail** omits the element; a store failure in a tool is a
  tool error.

## Testing Requirements

- [ ] `task_add` creates `open`; every field round-trips.
- [ ] **The CAS, tested twice in sequence**: two claims on one card — the first
      succeeds, the second reports the holder and its claim time, and the card is
      still claimed by the first.
- [ ] A claim on a `done` card is refused the same way, naming the status.
- [ ] `task_release` returns to `open` and clears the claim fields.
- [ ] `task_block` with a card blocker and with a question blocker both resolve;
      an unresolvable one is refused.
- [ ] `task_unblock` returns to `claimed`, preserving `claimed_by`.
- [ ] `task_done` from `open` is refused; from `claimed` it sets `done_note` and
      `status_at`.
- [ ] `task_drop` requires a reason; from `open` and from `claimed` both work.
- [ ] `task_edit` cannot change status — a status field in the arguments is ignored
      or refused, and the card is unchanged either way.
- [ ] A subtask of a subtask is refused; a subtask of a top-level card is allowed.
- [ ] A parent with all children done is **not** auto-closed.
- [ ] `task_reassign` and `task_delete` require approval; a denial changes nothing.
- [ ] The tail shows `mine` first, at most three `open`, and honours the drop order.
- [ ] Retention prunes finished cards but never a live one, and never one that is
      someone's parent or blocker.
- [ ] `make check` green; leak-clean.
