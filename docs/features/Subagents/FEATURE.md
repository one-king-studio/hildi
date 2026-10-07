# Subagents

## Overview

The agent can currently only work inside one conversation, in one context window.
Long, exploratory, or independent sub-tasks (search a large tree, draft a
document, run a migration and report back) either consume the parent's context or
block the parent from doing anything else.

This feature gives the helper **delegated task execution**: the parent agent
hands a task to a **subagent** — a *completely new, independent session* with its
own context window, its own headless process and socket, and a lineage link back
to the session that spawned it. Delegation is **asynchronous**: the parent keeps
working, and the subagent's final response is delivered back later as an
**ambient notification**. The parent supplies the context; the child inherits the
parent's permissions and behaviour prompt but nothing of its conversation.

Subagents are not a new kind of thing to build — they are ordinary sessions with
a parent. This feature adds the **lineage**, the **delegation tools**, the
**ambient result delivery**, **approval relaying up the lineage**, and a **TUI
sidebar** for the operator to watch (and abort) live subagents. The existing
`hildegard.helper.pool` (a bounded shell-command fan-out) is a different concern
and is left alone.

## Problem Statement

The harness survey (`docs/research/cli-agent-harness-parity.md`) calls subagents
the **single biggest gap** versus OpenCode, Codex CLI, Claude Code, and DeepSeek
Harness, all of which ship task delegation. Today hildegard-helper's only
"parallelism" is a pool that runs *shell commands* — no model, no context, no
reasoning, no result to feed back. A parent agent that needs a bounded,
independent piece of work done has nowhere to put it.

Three costs follow:

- **Context pressure.** Every sub-task's exploration (file reads, searches, tool
  output) lands in the parent's context window, crowding out the actual task.
  Delegation gives the sub-task its own window and returns only the result.
- **Serialisation.** A single-threaded loop means the parent cannot do A while B
  runs. Async delegation lets independent work proceed in parallel.
- **No isolation of blast radius.** An exploratory or long-running task shares the
  parent's lifecycle and attention. A separate session can be watched, steered,
  and aborted independently.

Applying the Ponytail ladder: the **session runtime, protocol, client, ledger,
approvals engine, tool registry, and reason gate all already exist** and are
session-agnostic — a subagent is "just another session" that already works. The
genuine gap is narrow: a **lineage** (parent/child/depth/count) in the store, a
**`delegate_task` tool family** that spawns and talks to a child session, an
**ambient delivery path** that wakes the parent, **approval relay** up and down
the lineage, and a **sidebar** to observe children. We build exactly that.

## Goals

- Let the parent agent delegate a task to a subagent that runs as a **new,
  independent session** (own context, own headless process and socket).
- Make delegation **asynchronous**: the spawn returns immediately with a handle,
  and the result arrives later as an **ambient notification** that wakes the
  parent.
- Track **lineage** — parent→child and child→parent — plus **depth** and a
  **live-child count**, so the tree is bounded and the parent can manage its
  delegation capacity.
- Let the parent **follow up** with a child, **abort** it, or **release** it
  (detach without aborting).
- Preserve the trust model: children **inherit the parent's permissions**,
  approvals are **lineage-wide** and relayed to the operator, and a purely
  headless child **auto-denies** rather than hanging.
- Give the operator **visibility**: a sidebar of the parent's active children,
  with the ability to **spy** on any child's full session and **abort** it.
- Keep **cost attribution clean**: a child's usage and cost bind to the child
  session only; there is **no rollup** to the parent.

## User Stories

- As the **parent agent**, I want to delegate a bounded task to a subagent so I
  can make progress on independent work without filling my context window.
- As the **parent agent**, I want to be notified when a delegated task finishes
  (with which task it was and how long it took) so I can act on the result
  without polling.
- As the **parent agent**, I want to send a follow-up to a subagent by its
  session id so I can steer or extend a task I already started.
- As the **parent agent**, I want to abort a subagent whose work is no longer
  needed so I can reclaim capacity and avoid wasted work.
- As the **parent agent**, I want to see how many delegation slots remain so I can
  manage my resources.
- As the **operator**, I want a sidebar of the active subagents of my session so I
  can watch what each one is doing.
- As the **operator**, I want to spy into a subagent's full session (including
  its reasoning and tool output) so I can judge whether it is on track.
- As the **operator**, I want to abort a misbehaving subagent from the sidebar so
  I can stop wasted work and let the parent react.
- As the **operator**, I want a subagent's approval request to surface in my TUI
  so I stay the gate, even though the child is headless.
- As the **operator**, I want a purely headless child to auto-deny unanswered
  asks so an unattended agent never hangs.
- As the **operator**, I want a subagent's cost to stay on the subagent so my
  parent session's accounting is not inflated.

## Acceptance Criteria

### Functional Requirements

Lineage and capacity

- [ ] A session can spawn a child session; the child records its
      `parent_session_id` and `depth`, and the parent can enumerate its children.
- [ ] Lineage is durable: parent/child links survive a process restart and are
      readable from the store.
- [ ] Depth is bounded (default **1**: a child may not spawn). A child at the
      depth cap does **not** advertise the delegation tools.
- [ ] Live children per parent are bounded (default **10**), configurable. At the
      cap, a spawn fails cleanly with a message the parent can act on.
- [ ] Spawning a child and finishing a child both update the parent's live-child
      count, which is advertised in the spawn response.

Delegation tools

- [ ] `delegate_task` spawns a child session for a task and **returns
      immediately** (non-blocking) with the child's **session id**, the task
      label, and the parent's remaining capacity (`<n> available`).
- [ ] `message_task` sends a follow-up message to a child by session id, for
      continuity on an existing subagent.
- [ ] `abort_task` stops a child's work and releases its slot; `release_task`
      detaches from a child **without** aborting it (fire-and-forget), also
      releasing the slot. Abort implies release, but they remain distinct
      actions.
- [ ] Every delegation tool call carries the required non-empty `reason`, and is
      approval-gated like any other tool.

Ambient result delivery

- [ ] A subagent's completion is delivered to the parent as an **ambient
      notification**: a persisted ledger record of a distinct kind that
      **auto-starts a parent turn**.
- [ ] The ambient record is stored with an internal/system role but is
      **hijacked on delivery to the API** into a `user` message: an
      `<ambient timestamp="ISO_DATE">` envelope holding a `<message
      source="delegate_task" id="<child-id>" label="..." status="...">` element
      (the result) and an `<instructions>` element, auto-injected and never
      visible to the user. The `<message source=...>` field is the extension
      point for future async producers; `status` distinguishes completed /
      failed / aborted / gone.
- [ ] The ambient payload carries the child's **final assistant response**, the
      **child session id**, and the **elapsed time** of the task.
- [ ] The parent sees **only** the child's assistant responses; the child's
      reasoning, tool calls, and tool output are visible to the operator (via
      spy) but not to the parent.
- [ ] If the parent is mid-turn when a notification arrives, it is **queued** and
      injected at the next loop boundary (no interruption of the in-flight turn).
- [ ] An **abort** — by operator or parent — also produces an ambient
      notification, carrying the **partial final assistant text if any** and an
      "aborted" status. When the aborting actor is the parent, it receives an
      immediate response instead.

Approvals across the lineage

- [ ] A child **inherits the parent's permissions**; an approval decided once is
      in force for the **entire lineage** (relayed up, then broadcast down to
      every child).
- [ ] A child's approval request is **relayed to the parent** and surfaced in the
      operator's TUI, identified by the subagent's **reason/label** (ids
      available by configuration).
- [ ] A **purely headless** child auto-denies an unanswered ask after a bounded
      window (default **60s**, configurable) rather than hanging; the child is
      told it was auto-denied and continues.
- [ ] Supervision lives in the per-session runtime: it subscribes to its
      children's streams, re-emits their approval asks, and relays decisions
      back down.

Operator visibility (sidebar)

- [ ] The TUI shows a **floating sidebar** listing the active child sessions of
      the current (parent) session.
- [ ] Selecting a child **spies** on it in the main chat panel (full session
      detail, including reasoning and tool output).
- [ ] In spy mode the composer is **replaced** by session actions
      (**Abort** / **Release**); spy is observe-only.
- [ ] A multi-layered lineage renders as a **tree** (deferred — v1 shows the
      parent's direct children; see Out of Scope).

Lifecycle

- [ ] A child is **one-shot by default** (task → turn → result) but is a normal
      session and **accepts follow-ups**, so it is interactive when the parent
      keeps it alive.
- [ ] A finished or idle child **idle-exits** on the existing timeout, freeing
      its slot; `abort_task`/`release_task` free it sooner.
- [ ] When the **parent session ends**, its children are terminated (bounded),
      not orphaned.
- [ ] A child inherits the parent's **workspace**, **model/config**, **approval
      lineage**, and **behaviour prompt**; the parent supplies the task context
      as the child's first user message.
- [ ] Shutdown and teardown are **leak-clean** under the heaptrc gate.

Cost

- [ ] A child session's token usage and cost bind to the child session only; the
      parent's stats are unchanged by delegated work (no rollup).

### Non-Functional Requirements

- [ ] Portability: macOS and Linux, FPC 3.3.1; no new runtime dependency.
- [ ] Performance: a spawn returns promptly (it must not block on the child's
      first turn); a slow or dead child never wedges the parent session.
- [ ] Reliability: a crashed child degrades only itself; its slot is reclaimed
      and the parent is notified.
- [ ] Testability: lineage, the delegation tools, ambient formatting/delivery,
      approval relay, and the sidebar model are tested against in-process fakes
      and scripted sessions; no real LLM or network in the suite.
- [ ] `make check` passes (functional tests plus the leak gate), including
      child-process teardown.

## Success Metrics

### Quantitative

- A `delegate_task` call returns in well under a second, before the child's turn
  begins (async, not blocking).
- A completed subagent's result reaches the parent as an ambient notification
  that starts exactly one parent turn.
- A child at the depth cap never advertises the delegation tools; a parent at
  capacity never spawns an 11th child.

### Qualitative

- Delegation is configuration-light for the operator and invisible-plumbing for
  the parent: the parent uses ordinary tools and sees ordinary messages.
- The trust model survives delegation without a bypass: children inherit
  permissions, approvals are lineage-wide, and a headless child cannot hang.
- The operator can always see and stop what a subagent is doing.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- Must **reuse**: `hildegard.helper.session.runtime` / `.client` / `.protocol` /
  `.socket` (child sessions and their streams), `hildegard.helper.session.store`
  and `hildegard.helper.store` (lineage persistence), the approval engine
  (refs/asks), `TToolRegistry`/`TToolSpec` (registration), the ledger, and the
  required-reason contract.
- **New code required**: the lineage fields and queries; the delegation tool
  family; the ambient record kind, its API-time wrapper, and its TUI renderer;
  the approval relay up/down the lineage; the auto-deny safety; and the sidebar.
- Store changes are an **additive migration** (no reset of history): lineage
  columns on `sessions` (parent, depth, label) and an index for child lookup.
- The ambient wrapper is a **port** of the dynamic user message formatter in the
  hildegard main project (`src-backend/lib/main-agent/message-formatter.ts`) —
  only the uncached/current message carries volatile metadata; once answered, the
  message persists as a normal message.
- No implementation without a specification; TDD-first.

### Business / Time

- No deadline. Multi-layered delegation (depth > 1) and the tree sidebar are
  explicitly deferred.

## Dependencies

### Internal

- `hildegard.helper.session.runtime` / `.client` / `.protocol` / `.socket` — the
  child session and its observable event stream.
- `hildegard.helper.store` / `.session.store` — lineage rows and the ledger.
- `hildegard.helper.approval` / `.store` — lineage-wide approvals and relay.
- `hildegard.helper.agent` — `TToolRegistry`/`TToolSpec`, the loop, the prompt
  queue (ambient delivery at loop boundaries), and the reason gate.
- `hildegard.helper.harness.*` and the TUI widgets — the sidebar and spy view.

### External

- `fpjson` and the existing Unix-socket machinery — already available; no new
  dependency.

## Risks

- **Ambient loop storms.** A child completing could wake a parent that spawns
  more children indefinitely. Mitigation: bounded depth (1) and live-child cap
  (10); the parent is told its remaining capacity in every spawn response.
- **Approval relay complexity.** Relaying asks up and decisions down across
  processes is fiddly. Mitigation: keep supervision in the per-session runtime
  (already the process that owns the loop and children); lineage-wide grants are
  broadcast from the parent.
- **Hanging headless children.** A child with an unanswered ask could stall.
  Mitigation: auto-deny after a bounded window for purely headless sessions.
- **Orphaned children.** A parent exit could strand child processes. Mitigation:
  terminate children with the parent; reclaim slots on crash; leak gate.
- **Volatile-message drift.** The ambient wrapper must not leak into persisted
  history. Mitigation: persist the plain message; wrap only at API-build time
  (the message-formatter pattern).
- **Scope creep into a supervisor daemon.** A general session supervisor is
  tempting. Mitigation: supervision stays inside the per-session runtime for v1
  (a marked `ponytail:` ceiling); the daemon remains Remote Agent Link's work.

## Out of Scope

- **Multi-layered delegation (depth > 1)** and the **tree** sidebar — v1 is
  1 deep.
- A general session **supervisor daemon** (the reserved "Session Host").
- **Driving** a child from the sidebar (spy is observe-only; the parent drives).
- **Cost rollup** from children to the parent (explicitly not wanted).
- **Cross-machine** delegation.
- Windows.
- Replacing or extending the existing shell-command pool.

## Future Considerations

- Depth > 1 with a bounded spawn tree and the sidebar rendered as a tree.
- Sidebar-driven child driving (type/approve in spy mode).
- Per-subagent token/cost budgets.
- A shared "Session Host" that supervises many sessions and hosts the link.

## Notes

- **ICE score: Impact 8, Confidence 6, Ease 4.** High leverage (it is the field's
  table-stakes gap) and the session runtime already does the hard part, but the
  async delivery, approval relay, and lineage plumbing are real work.
- **Naming.** Tools: `delegate_task`, `message_task`, `abort_task`,
  `release_task`. Abort implies release but they are distinct actions; release is
  detach-without-abort (fire-and-forget).
- **Ambient format.** `<ambient timestamp="ISO_DATE"><message source="delegate_task" id="<child-id>" label="..." status="completed|failed|aborted|gone">…</message><instructions>…</instructions></ambient>`,
  delivered as a `user` message with auto-injected handling instructions.
- **Config knobs.** `HILDEGARD_SUBAGENT_MAX` (default 10),
  `HILDEGARD_SUBAGENT_DEPTH` (default 1), and an auto-deny timeout (default 60s).
- **Prior art.** The dynamic user message wrapper lives in the hildegard main
  project at `src-backend/lib/main-agent/message-formatter.ts`
  (`formatCurrentMessage`, `formatPastMessage`, `formatSystemEventMessage`); the
  `<ambient>` convention is already used there for injected context.
