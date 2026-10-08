# Context Handoff

## Overview

Replace destructive **context compaction** with a **generative, recoverable
handoff**: instead of summarizing a session and *replacing* its history, the
current agent writes a handoff summary, a **new session is seeded with it**, and
the TUI switches to that successor. The old session stays **intact** in the
store, and the successor can `recall` from it — so the prompt gets small without
anything becoming unrecoverable.

It is the session-scoped, agent-generated sibling of the hand-curated
`HANDOFF.md`: state, decisions, lessons, and open threads, written at the moment
of handoff and carried into the next session.

> Name note: `Session_Handoff/` already exists for a **different, superseded**
> meaning (moving a live loop between devices). This feature is deliberately
> **Context Handoff** to avoid the collision.

## Problem Statement

Long sessions hit the context limit. The common answer is **compaction**:
summarize the history and drop the original. That is **destructive** — the
summary is lossy, and when it drops a decision or a subtlety, the detail is
gone. The operator's own words: "I really don't want to reduce an entire session
down to something unrecoverable if things go wrong."

A handoff avoids that by **not discarding anything**:

- The **old session is preserved** (history, ledger, everything).
- The **new session starts from a concise seed** (the handoff), so its prompt is
  small.
- The **successor can query the predecessor** — the recoverability backbone.

So the summary is lossy *in the prompt* but not *in the system*. This is
strictly better than compaction: small prompt **and** full recoverability.

## Goals

- A deliberate, operator-owned **handoff** action (`/handoff`), with a
  **threshold nudge** (e.g. at 80% context) but never automatic.
- The **agent writes** the handoff; the **operator reviews and edits** it before
  the switch (like a commit message — it is their context).
- A **new session** is created, seeded with the handoff, and **linked** to the
  predecessor via the existing lineage (`parent_session_id`).
- The **TUI switches** to the new session; the old runtime **exits cleanly**
  (reusing Runtime Lifecycle).
- The successor can **`recall` from the predecessor's full history** — the
  property that makes this recoverable rather than destructive.
- The handoff is a **durable artifact** (inspectable, like `HANDOFF.md`) as well
  as the successor's seed.

## User Stories

- As an **operator**, I want to carry a long session forward without losing its
  detail, so I can keep working when context fills.
- As an **operator**, I want to review and edit the handoff before the new agent
  starts, so the successor begins with *my* framing.
- As the **agent**, I want the successor to be able to pull any detail from my
  session, so I do not have to cram everything into the summary.
- As a **reviewer**, I want the old session untouched, so a bad handoff is never
  a data loss.

## Acceptance Criteria

### Functional Requirements

- [ ] `/handoff` (operator) triggers a handoff; a **nudge** suggests it at a
      configurable context threshold but never fires it automatically.
- [ ] The current agent generates a **handoff document** (see Contents); the
      operator may **edit** it before confirming.
- [ ] On confirm, a **new session** is created in the same workspace as a
      **child** of the current session (`CreateChildSession`: `parent_session_id`
      = current, `depth` = parent + 1, `label` = e.g. `handoff`).
- [ ] The handoff is persisted as the new session's **first message**, visible
      in its transcript, and carrying a reference to the predecessor
      (`ref_session_id` = old session) — the "ambient initial message" the
      operator described.
- [ ] The **TUI switches** to the new session (spawn its runtime, attach, render
      the handoff); the old runtime **exits cleanly** (Runtime Lifecycle).
- [ ] The successor can **read the predecessor's history** (a recall path into
      `ref_session_id`), so any detail omitted from the summary is retrievable.
- [ ] The handoff is a **durable artifact** retrievable later (a session
      document / message), not only the seed.
- [ ] A handoff with no changes since the last one (or an empty session) is
      refused with a clear message.

### Non-Functional Requirements

- [ ] **Nothing destructive**: the old session, its turns, and its messages are
      never modified by a handoff (except the normal turn lifecycle).
- [ ] The handoff generation is bounded (it is one request against the current
      context; if the context is nearly full it must still fit).
- [ ] `make check` green; leak-clean.

## Success Metrics

### Quantitative

- A handed-off session resumes with a **bounded** seed (target: well under the
  context limit) while the predecessor's full history remains queryable.
- Zero data loss: the predecessor's message count is unchanged by the handoff.

### Qualitative

- Operators stop fearing the context limit; a handoff is cheap and reversible.
- The successor feels "briefed", not "reset".

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`; reuse `TSqliteStore.CreateChildSession`,
  `SessionLineage`, `ChildrenOf`, `ref_session_id`, `mrAmbient` (already added by
  the subagents work), and the Runtime Lifecycle shutdown.
- POSIX.

## Dependencies

### Internal

- `hildegard.helper.store` (lineage + a handoff artifact).
- `hildegard.helper.session.protocol` / `runtime` (a handoff command; spawn the
  successor).
- `hildegard.helper.harness.session` / `view` (create the child session).
- `hildegard.helper.tui.app` (the switch UX).
- Turn Lifecycle (clean shutdown), Subagents lineage (the child-session model).

### External

- None.

## Risks

- **The handoff request itself overflows the context.** Mitigation: generate the
  handoff with a reserved output budget; if the context is too full, offer
  "handoff now with what fits" or a two-step (free a little first). This is the
  subtle one.
- **A bad handoff** (the agent writes a poor summary). Mitigation: operator
  edits it; the predecessor is intact and queryable regardless.
- **Session-scoped approvals reset** in the new session. Mitigation: a
  deliberate decision (below); workspace/global rules carry.
- **Orphaned runtimes on switch.** Mitigation: Runtime Lifecycle already
  finalizes and exits cleanly.

## Out of Scope

- **Automatic** handoff (no threshold-triggered switch in v1; the nudge is
  advisory).
- **Compaction** — this feature replaces it, it does not implement it.
- **Multi-hop chain UI** (walking a long handoff lineage) — the lineage exists;
  a browser is later.
- **Cross-workspace** handoff.

## Future Considerations

- Automatic handoff at a hard threshold, with the operator confirming.
- A handoff **chain browser** (walk `parent_session_id` back through history).
- **Structured handoff** (a JSON template: facts vs narrative) so tooling can
  render it.
- Carrying selected **session-scoped approvals** into the successor.
- A `/handoff` variant that seeds **multiple** successors (fan-out).

## Notes

- **ICE score: Impact 8, Confidence 7, Ease 5.** The payoff is real (fearless
  long sessions, zero data loss) and much of the machinery exists (lineage,
  ambient role, clean shutdown); the new surface is the handoff generation, the
  operator edit step, and the TUI switch.
- The distinction from compaction, in one line: **compaction replaces history; a
  handoff adds a successor beside it.**
