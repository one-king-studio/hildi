# Turn Injection

## Overview

Let the agent loop **assemble its tool list and prompt fresh for every turn**
from registered *contributors*, instead of reading a registry fixed at session
open. Each contributor offers tools and a prompt fragment; the loop composes
them into the turn's request and routes tool calls back to the contributor that
offered them.

This is the generalisation of the MCP boundary reconcile: MCP becomes one
contributor, and **skills** — which need both tools *and* prompt text injected
for the duration of their activation — become another. Trust is unchanged:
every contributed tool is still approval-gated by its ref.

## Problem Statement

The loop's tools are a `TToolRegistry` built once and read per request; the
system prompt is written to the conversation once at turn start. Two needs break
that model:

- **Dynamic tool loading** is now partly solved (the MCP boundary reconcile adds
  and removes MCP tools per turn), but it is **MCP-specific**: the session calls
  `McpReconcile` directly. There is no seam for *another* source of tools.
- **Skills** need to inject **both** a prompt fragment (instructions describing
  how to use the skill) **and** the skill's tools, for as long as the skill is
  active — and withdraw both when it is not. A registry mutation cannot inject
  prompt; the current hook carries no contribution.

Ponytail check: the loop already rebuilds `Result.Tools` every request and
already builds the message list in `BuildRequest`. The genuine gaps are (a) a
**contributor interface** that returns tools + prompt, (b) composing the turn's
tool list from base + contributors, (c) routing dispatch to the contributor, and
(d) injecting the prompt fragment request-only. Nothing needs a new trust
mechanism.

## Goals

- A **contributor** seam: `Prepare` (once per turn), `Specs`, `PromptFragment`,
  `Find`. Contributors supply tools **and** prompt.
- The loop **composes the turn's tool list** from the base registry plus every
  contributor, and resolves a called tool against both.
- **Prompt injection** is request-only: a contributor's fragment shapes the
  current turn's request and is never appended to the stored conversation.
- MCP becomes a contributor (retiring the MCP-specific session wiring); a skill
  provider is a future contributor on the same seam.
- Trust unchanged: contributed tools are approval-gated; prompt injection is
  operator/agent-controlled, never model-authored.

## User Stories

- As a **skill author**, I want a skill to contribute its tools and its
  instructions for the turns it is active, so the model can use it, and to
  withdraw both when it is not.
- As the **MCP client**, I want to be just another contributor, so the loop has
  no MCP-specific branch.
- As a **reviewer**, I want every contributed tool to be approval-gated and the
  injected prompt to be non-persistent, so injection cannot become a bypass.
- As an **operator**, I want the tool list and prompt to reflect current
  contributors each turn, so activation/deactivation needs no restart.

## Acceptance Criteria

### Functional Requirements

- [ ] A contributor interface exists: `Prepare` (called once at turn start, on
      the loop's thread), `Specs: TToolSpecArray`, `PromptFragment: string`,
      `Find(name, out tool): Boolean`.
- [ ] `TAgentLoop` holds zero or more contributors (`AddProvider`); at turn
      start it calls `Prepare` on each, in registration order.
- [ ] `BuildRequest` composes `Result.Tools` from the **base registry specs plus
      every contributor's `Specs`**; a name collision between contributors is a
      contributor's responsibility (the MCP provider already namespaces).
- [ ] Tool dispatch resolves a called name against the base registry, then each
      contributor's `Find`. An unknown name fails as today.
- [ ] Non-empty `PromptFragment`s are injected into the request **only** (a
      request-only `crSystem` message, or an equivalent prepend); they are
      **never** appended to the stored conversation. An empty set injects
      nothing.
- [ ] `Prepare` is the contributor's chance to reconcile/activate; a contributor
      that contributes nothing is a no-op.
- [ ] MCP is refactored into a contributor: `THarnessSession` registers an MCP
      contributor instead of setting `OnTurnStart := McpReconcile`; the MCP
      behaviour (enable/disable/remove/reconnect) is unchanged.
- [ ] Trust is unchanged: every contributed tool routes through the same
      approval engine; the prompt fragment is operator/agent-controlled (a
      contributor is registered in code/config, not by the model).

### Non-Functional Requirements

- [ ] Per-turn assembly is O(contributors × tools); a contributor with no change
      does no work.
- [ ] `Prepare` runs on the loop's thread; assembly is race-free with dispatch.
- [ ] Request-only injection does not grow the stored history (no prompt
      duplication across turns).
- [ ] `make check` passes, including the leak gate.

## Success Metrics

### Quantitative

- A contributor added between turns has its tools and fragment in the **next**
  turn's request (target: 0 restarts).
- The stored conversation is unchanged by injection (message count identical
  with and without a fragment).

### Qualitative

- The loop has no source-specific branch (MCP is a contributor like any other).
- A skill is expressible as one contributor (tools + prompt) with no loop change.

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`; `make check` green.
- Reuse `TToolRegistry`, `TToolSpec`/`TRegisteredTool`, `TMcpManager`, and the
  existing `OnTurnStart` call site.
- POSIX (macOS/Linux); no new dependency.

### Business / Time

- v1 is the seam + the MCP refactor. A skills provider is a later feature that
  rides the seam.

## Dependencies

### Internal

- `hildi.agent` (loop, registry, `BuildRequest`, `ExecuteToolCalls`).
- `hildi.mcp.client` (the MCP manager, refactored to a contributor).
- `hildi.harness.session` (registration).
- `docs/features/Dynamic_Tools/` (the reconcile this generalises).

### External

- None.

## Risks

- **Prompt injection as a capability change** — Mitigation: contributors are
  registered in code/config (operator/agent), never by the model; the fragment
  is request-only and auditable; tools remain approval-gated.
- **Dispatch ambiguity** (two contributors offering the same name) — Mitigation:
  first-registered wins, and the MCP provider namespaces; a SPEC rule pins it.
- **Tool list churn per turn** (token cost, cache misses) — Mitigation: the list
  is stable when contributors are stable; a contributor with no change adds
  nothing.

## Out of Scope

- **Model-triggered skill activation** (the model choosing to load a skill). v1
  assembles from contributors that are active by config/operator; a model-driven
  activation is a later feature.
- **Prompt *rewriting*** (editing the stored system prompt). v1 injects
  request-only fragments; it does not mutate history.
- **Non-tool contributor effects** (e.g. a contributor that changes sampling
  parameters). v1 contributes tools + prompt only.
- **The skills feature itself** — this feature builds the seam; skills ride it.

## Future Considerations

- A **skills provider**: activation state, a prompt fragment, and the skill's
  tools, all via this seam.
- **Per-request** assembly (currently per-turn).
- Contributor **priorities / ordering** beyond registration order.
- A contributor that contributes **no tools** but a prompt fragment (a pure
  context injector).

## Notes

- **ICE score: Impact 8, Confidence 7, Ease 6.** It unblocks skills, removes the
  MCP-specific branch, and reuses the per-request rebuild already present; the
  main new surface is the request-only prompt injection.
- This supersedes the MCP-specific wiring from `Dynamic_Tools` (the reconcile
  moves behind the contributor interface), but keeps the reconcile behaviour.
