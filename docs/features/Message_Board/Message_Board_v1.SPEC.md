# Component Specification: Workspace Board v1

**Related Feature:** [FEATURE.md](FEATURE.md)
**Depends on:** `hildi.store` (SQLite + the v13 schema),
`hildi.approval` (moderation only), `hildi.workspace.changes`
(the staleness annotation), `hildi.agent` (the `tools` dispatch seam).
**Depended on by:** nothing (a leaf capability).

## Purpose

A board per workspace with a fixed structure, serving two purposes through one
table: peer communication when several agents share a workspace, and a knowledge
base when one agent is alone.

Append-only. Corrections **supersede** rather than edit, so a topic has a current
truth *and* a history. The per-request tail carries a **table of contents, never
bodies** — roughly 30 tokens, flat in board size.

## Prior art and reuse

| Need | Existing | Change |
| --- | --- | --- |
| Persistence + migrations | `hildi.store` | one additive migration (v14) |
| Path-change history for staleness | `workspace.changes` / `file_changes` | reuse; annotate a read |
| The tail block | `hildi.wrap` (`FormatTail`) | add a `<board>` element |
| Provider seam | `IToolProvider` (`Prepare`/`Specs`/`PromptFragment`) | **reuse**: the board is a provider |
| Approval for moderation | `IApprovalService` | reuse, one ask per destructive op |
| FTS search | the existing `messages_fts` | a second FTS table |

The genuinely new work: the schema, three tools, supersession resolution, the
TOC, and the staleness join.

## Requirements

### Functional

- [ ] `board_post(kind, topic, title, body, reply_to?, supersedes?, paths?)`
      appends an entry. **No approval.**
- [ ] `board_read(topic?, kind?, since?, limit?)` returns entries newest-first,
      each annotated with staleness.
- [ ] Reading a topic marks the newest non-deleted, non-superseded entry as
      **current**.
- [ ] `board_moderate(op, id, note?)` requires approval; a denial changes nothing.
- [ ] Deletion is **soft**: the row is retained with `deleted_at` and excluded
      from default reads.
- [ ] The tail carries a TOC (unread count, kind counts, last-post age) **capped**
      and never carrying bodies.
- [ ] Board notices are **transient**: they ride the tail and are never persisted
      as conversation rows.
- [ ] `decision` and `finding` are **never pruned**; `note` and `status` are.
- [ ] The FTS index covers board entries.

### Non-Functional

- [ ] The TOC is bounded by a fixed token budget, so a large board costs the same
      as a small one.
- [ ] Notice fan-out is coalesced: one line per drain, never one per entry.
- [ ] Posting is capped per turn, so an agent cannot spend a turn writing.
- [ ] No new dependency; rides the vendored SQLite.
- [ ] `make check` green; leak-clean.

## Contracts & Interfaces

### The record

```pascal
unit hildi.board;

type
  TBoardKind = (
    bkNote,      // a scratchpad line
    bkQuestion,  // blocked, asking anyone
    bkAnswer,    // a reply to a question
    bkDecision,  // a choice that was settled, with its rationale
    bkFinding,   // a discovered fact
    bkStatus);   // what I am working on right now

  TBoardEntry = record
    Id: Integer;
    WorkspaceId: Integer;
    Kind: TBoardKind;
    Topic: string;            // slug: the page identity
    Title: string;            // one line: what a notice shows
    Body: string;             // Markdown
    ReplyTo: Integer;         // 0 => not a reply
    Supersedes: Integer;      // 0 => not a correction
    Paths: TStringArray;      // workspace paths this entry is about
    FromSession, FromLabel: string;
    DeletedAt: Int64;         // 0 => live
    CreatedAt: Int64;
    { Read-only, filled by board_read: }
    Current: Boolean;         // the newest live, non-superseded entry in its topic
    StaleSince: Integer;      // changes to Paths since this was written; 0 => fresh
    DeletedBy: string;        // '' unless deleted
  end;

  TBoardEntryArray = array of TBoardEntry;
  TBoardFilter = record
    Topic: string;            // '' => any
    Kind: TBoardKind;
    KindSet: Boolean;         // False => any kind
    SinceId: Integer;         // 0 => from the beginning
    Limit: Integer;           // 0 => default
    IncludeDeleted: Boolean;
  end;
```

### The store seam

```pascal
{ Persistence, over the v13-era SQLite. Errors are strings, not exceptions: a
  board failure must never fail a turn. }
type
  IBoardStore = interface
    ['{A1B2C3D4-5E6F-4A7B-8C9D-0E1F2A3B4C5D}']
    function Append(const AEntry: TBoardEntry; out AId: Integer;
      out AError: string): Boolean;
    function Read(AWorkspaceId: Integer; const AFilter: TBoardFilter;
      out AEntries: TBoardEntryArray; out AError: string): Boolean;
    function Get(AWorkspaceId, AId: Integer; out AEntry: TBoardEntry;
      out AFound: Boolean; out AError: string): Boolean;
    { The newest live, non-superseded entry per topic: what "current" means. }
    function CurrentOf(AWorkspaceId: Integer; const ATopic: string;
      out AEntry: TBoardEntry; out AFound: Boolean; out AError: string): Boolean;
    { Soft delete / restore / lock. ALock is board-level policy per topic. }
    function MarkDeleted(AWorkspaceId, AId: Integer; ADeleted: Boolean;
      const ABy: string; out AError: string): Boolean;
    { Counts for the tail TOC, in one query. }
    function Toc(AWorkspaceId: Integer; const ASinceId: Integer;
      out AUnread, AQuestions, ADecisions, AFindings: Integer;
      out ALastAt: Int64; out AError: string): Boolean;
    { The per-session read cursor. }
    function CursorOf(const ASessionId: string; out AId: Integer;
      out AError: string): Boolean;
    function SetCursor(const ASessionId: string; AId: Integer;
      out AError: string): Boolean;
  end;

{ The SQLite implementation. Owns its own tables, like the change log's adapter. }
type
  TSqliteBoardStore = class(TInterfacedObject, IBoardStore)
    constructor Create(AStore: TSqliteStore);
  end;
```

### The three tools

```pascal
{ Registered like any other tool: a required non-empty `reason`.
  board_post and board_read are ungated; board_moderate is gated. }
const
  BoardPostToolName = 'board_post';
  BoardReadToolName = 'board_read';
  BoardModerateToolName = 'board_moderate';

type
  TBoardTool = class
  public
    constructor Create(const AStore: IBoardStore; AWorkspaceId: Integer;
      const ASessionId, ALabel: string; AService: IApprovalService;
      AChanges: IChangeStore);
    procedure Register(ATools: TToolRegistry);
    { Public for direct testing, matching TToolHandler. }
    function Post(const AArgumentsJson: string; out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function ReadEntries(const AArgumentsJson: string;
      out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function Moderate(const AArgumentsJson: string;
      out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;
```

## Architecture

### Schema (migration v14, additive)

```sql
CREATE TABLE board_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  workspace_id INTEGER NOT NULL,
  from_session TEXT NOT NULL DEFAULT '',
  from_label TEXT NOT NULL DEFAULT '',
  kind INTEGER NOT NULL,
  topic TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  reply_to INTEGER NOT NULL DEFAULT 0,
  supersedes INTEGER NOT NULL DEFAULT 0,
  paths TEXT NOT NULL DEFAULT '',        -- newline-separated, workspace-relative
  deleted_at INTEGER NOT NULL DEFAULT 0,
  deleted_by TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_board_ws_topic ON board_entries (workspace_id, topic, id);
CREATE INDEX idx_board_ws_kind  ON board_entries (workspace_id, kind, id);

CREATE TABLE board_reads (
  session_id TEXT NOT NULL,
  last_id    INTEGER NOT NULL,
  PRIMARY KEY (session_id)
);

CREATE TABLE board_lock (
  workspace_id INTEGER NOT NULL,
  topic        TEXT NOT NULL,
  locked_by    TEXT NOT NULL,
  locked_at    INTEGER NOT NULL,
  PRIMARY KEY (workspace_id, topic)
);
```

`paths` is newline-separated rather than a join table: the count is small, the
only query is "which of these changed", and a second table would buy nothing.

### Supersession, and what "current" means

`CurrentOf(topic)` is the **highest id among live, non-superseded entries** for
that topic. The rule the query implements:

1. Exclude `deleted_at <> 0`.
2. Exclude any entry whose id appears in another live entry's `supersedes`.
3. Take the maximum remaining id.

So supersession is a **pointer**, not a rewrite: `#39 supersedes #14` leaves both
rows intact, and `#14` drops out of "current" only because something points at it.
Reading a topic returns the chain oldest-first with `Current` set on the last.

Restoring a superseding entry (moderation) makes the entry it superseded current
again — which is the behaviour a wiki wants: undoing a correction restores the
earlier belief.

### The tail TOC

Contributed through `IToolProvider.PromptFragment`, so it rides `FormatTail` on the
**last message** and costs only what follows the stable prefix:

```
<board unread="2" q="1" d="4" f="7">last 2m</board>
```

Six fields, no prose, no titles. **Budget: 120 bytes.** The manifest header that
explains the element lives in `StableText` (the system prompt), so the per-request
element is pure data — the same split the skills manifest uses.

If the element would exceed its budget, fields are dropped in this order:
`f`, `d`, `q`, leaving `unread` and `last` always. A TOC that says only "2 unread"
is still actionable; one truncated mid-field is not.

### Notices are transient

A new entry since the session's cursor produces a `pkBoard` prompt-queue item, not
a stored message. `DrainQueued` delivers it in the tail and forgets it. **Coalesce
per drain**: one notice per tick naming the total, never one per entry — otherwise
ten agents posting is O(agents × entries) of noise.

The one exception is a `reply_to` a question **this** session asked: that notice
carries the title, because it is the answer to something the agent is waiting on.

### Staleness

`board_read` joins `paths` against `file_changes`: for each entry, count the
changes to those paths with `id > ` the change id current when the entry was
written. That baseline is the entry's own `created_at` translated through the log,
or simpler and good enough: **count all changes to those paths since the entry was
created** (timestamps are comparable within one store).

An entry with a non-zero count is rendered:

```
[finding parser] the `$()` guard is in ParseWord  ·  src/…/shell.parser.pas
   changed 14× since  ⚠ may be stale
```

Staleness is **advisory and never blocks**: a stale entry is still the best record
of what was believed, and the annotation says exactly that.

### Moderation

| Op | Effect | Gate |
| --- | --- | --- |
| `delete` | soft (`deleted_at`, `deleted_by`) | **approval** |
| `restore` | clears them | **approval** |
| `lock` / `unlock` | a topic refuses new posts | **approval** |
| `pin` | marks the entry as topic header (a flag on the entry) | **approval** |
| `move` | re-topics an entry | **approval** |

One ask per operation, `ref = 'board:moderate'`, carrying the operation and the
entry's title in the summary. The denial path changes nothing and returns a
tool-level error naming the refusal.

**Why moderation is gated and posting is not**: posting cannot destroy anything,
moderation destroys or restricts knowledge another agent depends on. That is the
same reach-based rule the shell's effect gate uses.

## Validation and error handling

- An unknown `kind` is an error naming the six valid ones.
- An empty `topic` or `title` is an error; `body` may be empty for `note`.
- `supersedes` must point at a live entry **in the same topic**; otherwise the post
  is refused (superseding across topics would silently retire another page).
- `reply_to` must point at a live entry.
- A locked topic refuses `board_post` with the locker's label.
- Reading an empty board returns `(no board messages)` rather than an empty string,
  so the model does not read absence as failure.
- A store failure in the **tail** is swallowed (the element is omitted); a store
  failure in `board_post` is a tool error.

## Testing Requirements

- [ ] `board_post` appends each of the six kinds; the row round-trips every field
      including `paths`.
- [ ] `supersedes` makes the target non-current and leaves both rows readable.
- [ ] Superseding across topics is refused.
- [ ] `board_read` filters by topic, kind, and since-id; newest-first; `Limit`
      respected.
- [ ] `CurrentOf` returns the newest live non-superseded entry; after a restore it
      returns the older one again.
- [ ] A soft delete excludes the entry from reads but keeps the row.
- [ ] `board_moderate` requires an approval; a denial leaves the board unchanged.
- [ ] A locked topic refuses a post.
- [ ] The TOC fields are correct, and dropping order under budget pressure is `f`,
      `d`, `q` — never `unread` or `last`.
- [ ] A notice is **not** persisted: after a post, no new `messages` row exists.
- [ ] Staleness: an entry naming a path reports 0 changes when fresh, and N after N
      recorded changes to that path.
- [ ] FTS: a body term is findable through the search index.
- [ ] `make check` green; leak-clean.
