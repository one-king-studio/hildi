# Feature: Workspace Board

**Status:** Proposed.

**Related:** [Context Checkpoint](../Context_Checkpoint/FEATURE.md) ·
[File Changes](../File_Changes/FEATURE.md) ·
[Workspace Snapshots](../Workspace_Snapshots/FEATURE.md) ·
[Skills](../Skills/FEATURE.md) ·
[Subagents](../Subagents/FEATURE.md) ·
[prompt-cache-and-injection](../../research/prompt-cache-and-injection.md) ·
[workspace-changes-and-board](../../research/workspace-changes-and-board.md)

## Overview

A **message board per workspace** with a predefined structure, serving two
purposes with one mechanism:

1. **Peer communication** when several agents work in the same workspace — ask,
   answer, announce, coordinate.
2. **A knowledge base** when only one agent is working — decisions, findings and
   open questions it wants to keep beyond its context window.

The two are the same table. A single agent writing `decision` entries is
journaling; ten agents writing `finding` entries are building a wiki. Nothing in
the schema switches between the modes, because nothing needs to.

Deliberately **append-only**. Entries are never edited in place; a correction is a
new entry that *supersedes* an older one. That gives one table the property a
wiki needs (a current truth per topic) and the property a message board needs (a
history that cannot be quietly rewritten), and it means two agents can never
structurally conflict.

## The problem

An agent's knowledge dies with its context window. Today that costs:

- **Re-derivation.** A fact established in turn 20 is unavailable in turn 60; the
  agent re-reads the same files to rediscover it, paying tokens to learn something
  it already knew.
- **No memory across sessions.** A resumed session starts from the ledger, which
  holds *messages*, not *conclusions*.
- **No coordination.** With subagents, two agents can be editing one tree with no
  channel between them — they collide silently (`workspace-changes-and-board.md`
  §4) and cannot ask each other anything.
- **A wiki that isn't one.** An agent can already `file_write` a notes file, but
  it is a single mutable blob: no author, no time, no history, no query, and it
  costs an approval to write.

Ponytail check: does this need to be built, or can files do it? Files are
artifacts; the board is what the agent *knows* about the artifacts. The
distinction is load-bearing and is a rule below rather than a hope.

## The rule: artifact or knowledge?

> **Something that belongs in the repository becomes a file. Something
> provisional, exploratory, or session-scoped belongs on the board.**

| Goes in a file | Goes on the board |
| --- | --- |
| An ADR, a design doc, a committed note | "I think the bug is in `ParseWord`" |
| Anything the operator should review and commit | "chose X over Y for now" |
| Anything that must be diffable or undoable | "waiting on the parser rewrite" |
| Anything another tool will read | "the `$()` guard is in the lexer, not the parser" |

Board knowledge is **not** in git, not diffable, and not undoable. That is the
correct trade for transient reasoning and the wrong one for durable artifacts, so
the rule matters. Agents will sometimes get it wrong; a moderation move (below)
is the remedy, not a schema constraint.

## Structure

Four fields, six kinds. Enough to query and render; not so much that posting
becomes a form to fill in.

```pascal
TBoardKind = (
  bkNote,      // a scratchpad line: "remind myself later"
  bkQuestion,  // blocked on something, asking anyone
  bkAnswer,    // a reply to a question
  bkDecision,  // a choice that was settled, with its rationale
  bkFinding,   // a discovered fact about the codebase or the task
  bkStatus);   // what I am working on right now

TBoardEntry = record
  Id: Integer;
  Kind: TBoardKind;        // required
  Topic: string;           // required slug: the page this belongs to
  Title: string;           // required, one line: what a notice shows
  Body: string;            // freeform Markdown: the detail
  ReplyTo: Integer;        // 0 => not a reply
  Supersedes: Integer;     // 0 => not a correction
  Paths: TStringArray;     // workspace paths this entry talks about
  FromSession, FromLabel: string;
  CreatedAt: Int64;
end;
```

The kinds are chosen by the question an agent actually asks, not by taxonomy:

| Kind | Answers | One agent | Several agents |
| --- | --- | --- | --- |
| `note` | "what was I in the middle of?" | scratchpad | broadcast |
| `question` | "what is blocking me?" | own TODO | asks peers |
| `answer` | "who replied?" | — | the reply |
| `decision` | "what did we settle, and why?" | journal | shared record |
| `finding` | "what do we know about X?" | wiki page | wiki page |
| `status` | "who is on what?" | — | coordination |

**Deliberately absent:** `claimed_by`, `owner`, `blocks`. Those mean nothing to a
single agent, and encoding them would make the solo case carry coordination
machinery it never uses. Coordination lives in the kind vocabulary and the text —
which is precisely what lets one table serve both modes.

## Current truth by supersession, not editing

A wiki needs a current answer; an append-only log has none. The join is
supersession:

```
#14  decision  topic=retry-policy  "exponential backoff, 5 attempts"
#39  decision  topic=retry-policy  supersedes=#14
                "full jitter in [0, base·2^n], 8 attempts"
```

Reading a topic yields the chain; the newest non-superseded entry is current.
Nothing is lost, no update races, and *"why did we believe that then?"* stays
answerable — which an editable wiki cannot do.

Two agents posting contradictory findings both survive, both visible, neither
silently overwriting the other. Same philosophy as hash-anchored CAS on writes:
turn a silent loss into a visible disagreement.

## The tail carries a table of contents, not the content

Memory you must remember to look up is not memory; memory injected wholesale is
permanent prompt cost that grows with use. The resolution is a **TOC in the tail
block** (`prompt-cache-and-injection.md`), ~30 tokens:

```
<board unread="2" topics="3">decisions(4) · findings(7) · open(1) · last 2m</board>
```

Enough to know *that* it knows something and *where*, without loading bodies. The
agent reads when it matters. This is deliberately the same shape as the skills
manifest — declared but unloaded, loaded on demand — so one mental model covers
both.

At **ten agents** the notice must coalesce: one line per drain, not one per post,
or every agent pays for every peer's traffic (`workspace-changes-and-board.md`
§3).

## Staleness: the payoff for building both features

Knowledge rots. "The parser lives in `src/parse.pas`" becomes a confident lie the
moment the file moves — worse than not knowing. Files do not have this problem;
they *are* the artifact.

So entries may reference workspace paths, and the [file change
log](../File_Changes/FEATURE.md) knows when those changed:

```
[finding topic=parser] the `$()` guard is in ParseWord, not the lexer
   src/…/shell.parser.pas  ·  changed 14 times since  ·  ⚠ stale
```

Neither feature is as useful alone as the pair: the board says what was believed,
the change log says whether the ground moved under it. Reading a topic annotates
each entry with "referenced files changed since this was written".

## Two tools, and moderation behind approval

**Posting is ungated.** It cannot mutate the workspace, it is bounded by byte
caps, and gating it would make the single-agent scratchpad worthless. Same
reasoning the effect-scoped gate uses: an operation with no reach does not need a
gate.

**Moderation is gated.** The operations a forum moderator performs are the ones
that destroy or restrict others' contributions, and those ask:

| Tool | Effect | Gate |
| --- | --- | --- |
| `board_post` | append an entry | none |
| `board_read` | read entries by topic / kind / since | none |
| `board_moderate` | `delete`, `restore`, `lock`, `unlock`, `pin`, `move` | **approval** |

Moderation is agent-callable — an agent may propose that a topic is stale, or
that a mis-filed finding belongs elsewhere — but the **operator approves each
one**, because it destroys or restricts knowledge another agent may depend on.
Deletion is soft (`deleted_at`), so a moderator's mistake is recoverable and the
operator can see what an agent wanted gone.

No other operation needs a gate. Editing is not offered at all: corrections
supersede. That leaves exactly one destructive verb family, which is the property
that makes "approve the moderation" a small, comprehensible rule.

## Retention

- **`decision` and `finding` are never pruned.** They are the knowledge base; a
  memory system that forgets is not one.
- **`note` and `status` are pruned** by a bounded window (age and count), since
  they are the noise class: "remind myself later" and "working on X" stop being
  useful quickly, and ten agents emitting status would otherwise crowd out the
  knowledge.
- Moderation tombstones are retained with the entry so the operator can audit
  what was removed and by whom.
- The [file change log](../File_Changes/FEATURE.md)'s patches **are** pruned —
  they are a record of activity, not knowledge — which is the distinction between
  this feature and that one.

## Operator surface

The knowledge base is the operator's too, not only the agents':

- **A UI to manage it** is the eventual home (`/board`, list by topic/kind,
  read, search, moderate) — a later feature, on the same seam the `/sessions`
  modal uses.
- **An export** to Markdown so the knowledge can be reviewed and, if it deserves
  to be, committed as files. This is what keeps "board or file?" honest: the
  shelf life of a finding is decided by promoting it, not by it silently ageing
  in SQLite.
- Both are out of scope for v1, but the schema is designed for them: `topic` is a
  stable slug, `kind` is an enum, and every entry is attributable.

## Goals

- An agent can record and retrieve durable knowledge across turns and sessions.
- Agents sharing a workspace can ask, answer, and announce without a broker.
- Injected cost stays ~flat regardless of how much is on the board (a TOC, not
  the content).
- Knowledge is never silently lost: append-only, supersession instead of editing,
  soft deletes, no pruning of the knowledge kinds.
- Destructive operations are the operator's decision, not an agent's.

## Non-Goals

- **Not a file store.** Artifacts stay files (see the rule).
- **Not a scheduler.** The board makes work *visible*; it does not divide it.
  Ten agents told "fix the tests" still all fix the same test.
- **Not a merge tool.** Two agents editing one file still produce a conflict; the
  board may warn, the change log detects, nothing reconciles.
- **Not a place to put authority.** A board entry can never approve a tool call,
  spawn a subagent, or change configuration. It is text from a peer, and the
  wrapper says so.
- **Not a replacement for the ledger.** Messages remain the record of the
  conversation; the board is the record of conclusions.

## Acceptance Criteria

### Functional

- [ ] `board_post(kind, topic, title, body, reply_to?, supersedes?, paths?)`
      appends an entry; no approval is asked.
- [ ] `board_read(topic?, kind?, since?)` returns entries newest-first, with a
      per-entry staleness annotation when a referenced path has changed.
- [ ] Reading a topic resolves supersession: the newest non-deleted,
      non-superseded entry per topic is marked current.
- [ ] `board_moderate(op, id)` requires approval; a denial leaves the board
      unchanged.
- [ ] Deletion is soft: the entry is retained with `deleted_at` and is not
      returned by default reads.
- [ ] The tail block carries a TOC (unread count, kind counts, last-post age),
      capped hard, and never carries entry bodies.
- [ ] Board notices are **transient**: they ride the tail and are never persisted
      as conversation rows.
- [ ] `decision` and `finding` entries are never pruned; `note` and `status` are
      pruned by age and count.
- [ ] The FTS5 index covers board entries, so one search spans messages and board.

### Non-Functional

- [ ] The TOC is bounded (a fixed token budget), so a large board costs the same
      as a small one.
- [ ] Notice fan-out is coalesced: one line per drain, not one per entry.
- [ ] Posting is capped per turn, so an agent cannot spend a turn writing.
- [ ] No new dependency; rides the vendored SQLite (WAL already enabled).
- [ ] `make check` green; leak-clean.

## Success Metrics

- An agent that established a fact in turn 20 can retrieve it in turn 60 in one
  tool call, without re-reading files.
- A resumed session can answer "what did we decide about X?" from the board.
- The tail cost of the board is under ~40 tokens and flat in board size.
- With two agents in one workspace, each observes the other's posts within one
  tick and neither blocks on the other.

## Dependencies

### Internal

- `hildegard.helper.store` — the board tables and their migration; the FTS5 index.
- `hildegard.helper.agent` — the prompt-queue seam (`pkBoard`) and the tail block.
- `hildegard.helper.wrap` — `FormatTail` carries the TOC.
- `hildegard.helper.approval` — the moderation ask.
- `hildegard.helper.session.runtime` — the tick that drains notices.
- `hildegard.helper.workspace.changes` — the path history the staleness rule reads.

### External

None.

## Risks

- **Chatter.** Agents will use it as a chat room. Mitigation: a per-turn post cap,
  a notice that never invites a reply, and instructions saying a board message is
  advisory and must never be waited on.
- **N² fan-out.** Mitigation: coalesce per drain.
- **Deadlock by politeness.** A asks, B waits for A. Mitigation: the wrapper says
  continue your own work; the notice is not a blocking wait.
- **Trust.** A board entry is **model-authored text entering another model's
  context** — the prompt-injection class. Mitigation: a weaker wrapper than the
  ambient one, and no authority of any kind.
- **Stale knowledge presented as fact.** Mitigation: the staleness annotation via
  the change log, and the export/promote path so durable facts become files.
- **It becomes a second unwritten wiki.** The rule and a moderation move are the
  mitigations; both are social, not structural. Say so rather than pretending
  otherwise.

## Out of Scope

- The operator UI (`/board`) and the Markdown export — designed for, built later.
- Directed/private messages (`to_session` is in the schema, unused, so threading
  and broadcast do the work now).
- Voting, reactions, or reputation.
- Cross-workspace boards.
- Composing checkpoints from the board (`Context_Checkpoint` could later
  summarise `decisions` + `findings` instead of regenerating from raw messages —
  a real upgrade, noted for the future).

## Notes

- **Why one table for two purposes.** A message board that only works at N≥2 has
  no users at N=1, so it never gets exercised until the hard case. A knowledge
  base that works at N=1 is useful immediately, and gains peers for free.
- **Why append-only.** Editing is a lost-update race between agents and destroys
  *"why did we think that?"*. Supersession gives current truth without either.
- **Prior art, briefly.** The shape is a forum (topics, posts, replies,
  moderation) crossed with a personal wiki (pages, current truth). It is
  deliberately not a chat log: a chat log has no topic, so it cannot be asked a
  question.
