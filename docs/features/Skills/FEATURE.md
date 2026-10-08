# Skills

## Overview

A **skill** is a named, on-demand capability — instructions and/or tools — that
the agent discovers from a manifest and activates only when it needs it. This
matches Anthropic's **Agent Skills** model as closely as our harness allows:
skills are the unit of "a thing the agent can acquire", they are described by a
short name + description that is always visible, and their body is loaded on
demand rather than carried in every request.

Our deltas from Anthropic's model, driven by our use cases:

- **A skill may contribute tools, not only instructions.** An MCP server is a
  skill: its tools exist only while it is active.
- **Activation decays by idle time**, not per turn (see Lifetime). Anthropic
  unloads at the end of a turn; we keep a frequently used skill alive.
- **The state is always visible.** The manifest says, per skill, whether it is
  *loaded* or *unloaded*, so the model knows whether it must load it again.

MCP servers are the first provider (`Lazy_MCP`); file-based instruction packs are
the next, on the same mechanism.

## Definition (matching Anthropic)

Anthropic's Agent Skill is a folder — a `SKILL.md` of instructions plus optional
resources — whose **name and description** are surfaced to the model up front and
whose **body is loaded on demand**, either when the model judges it relevant or
when the operator invokes it. Progressive disclosure: the index is cheap, the
chapter is paid for only when opened.

We adopt that shape and extend it with two things we need:

| Aspect | Anthropic | Here |
| --- | --- | --- |
| What a skill contains | Instructions (+ resources/scripts) | Instructions **and/or tools** |
| Discovery | Name + description in the prompt | A manifest in the wrapped prompt, **with state** |
| Activation | Model-invoked or `/name` | `load_skill(name)` or operator-invoked |
| Lifetime | The conversation/turn | **Decays by idle time** (see below) |
| Isolation | May fork into a subagent | Subagents exist; skill-fork is a later option |

## Problem Statement

- **Every tool is always paid for.** A tool schema is context in *every* request,
  and a large tool surface degrades selection. That is fine for a handful of
  built-ins and wrong for anything open-ended (MCP, integrations, domain packs).
- **There is no capability layer.** MCP contributes tools through a provider, but
  there is no shared vocabulary for "a capability the model can acquire", and no
  way to offer one *without* its tools.
- **MCP is wired as a startup subsystem** rather than an on-demand capability, so
  it costs startup latency and can fail a launch (`Lazy_MCP`).

Prior art: the Hildegard main project (`src-backend/lib/main-agent/skills.ts`,
`tools.ts`) — a `SKILL_CATALOG`, a manifest injected as a system message,
`load_skill`, and tools scoped to one agentic loop. And this repo's
`Turn_Injection` already specifies the contributor seam (tools + prompt per turn)
that skills plug into.

## Decision

**Adopt Anthropic-shaped skills: a manifest that is always in context, activation
on demand, and decay by idle time.**

- **A skill is declared** with a name, a stable key, a description, a
  when-to-use hint, and either instructions (a prompt fragment) and/or a way to
  obtain tools.
- **The manifest is always in the wrapped prompt** — for every skill, its name,
  description, when-to-use, and **current state (loaded / unloaded)**. There is
  **no `list_available_skills` tool**: availability and state are context, not a
  call.
- **`load_skill(name)` activates** the skill: its instructions are injected for as
  long as it is active, and its tools are registered. An unknown or unavailable
  name returns a structured error.
- **Lifetime is decay, not turn scope.** An active skill is **kept alive while it
  is used**; once idle for longer than its TTL it is **unloaded** (instructions
  withdrawn, tools removed). A skill used frequently stays; one used once in 30
  minutes does not stay resident.
- **State is dynamic context.** Because the manifest carries loaded/unloaded, the
  model is never surprised: it can see a skill it used earlier is now unloaded and
  load it again.
- **Instructions decay too, but usually harmlessly.** A behaviour-prompt skill
  whose instructions were injected early tends to remain in the conversation for
  the session; decay simply stops re-injecting. Instruction-only skills have no
  keep-alive of their own — they decay like any other.
- **Tool names are explicit and namespaced**: `mcp_<id>_<tool>`, where `<id>` is a
  unique snake_case identifier for the provider (see Naming).
- **The seam is `Turn_Injection`'s contributor**: a skill contributes `Specs` +
  `PromptFragment` for the turn, and the loop composes and routes them. Skills
  own the *semantics* (what a skill is, the manifest, activation, decay); the
  contributor seam owns the *composition*.
- **Loaded tools obey everything the built-ins do**: the required `reason`, the
  approval gate, the context budget.

### Lifetime (the part that differs from Anthropic)

```text
activate   load_skill(name) -> instructions injected, tools registered
keep alive every use (a tool call, or a reference) resets the idle timer
decay      idle > TTL -> unload: withdraw instructions, remove tools
state      the manifest reports loaded/unloaded, so the model knows to reload
```

- **Why not per turn.** A per-turn unload forces a reload round trip even for a
  skill used on every turn; a decay window matches how a capability is actually
  used — hot for a while, then cold.
- **TTL is per skill** (a server may be cheap or expensive to reconnect), with a
  documented default. MCP connections reuse the manager's existing lifecycle.
- **Decay is observable.** Unloading is recorded as a session event and reflected
  in the manifest state.

## Goals

- The default tool surface is O(base tools), independent of how many skills exist.
- A capability can be added without adding tokens to every request.
- The model always knows what it can acquire *and* whether it is currently active.
- A frequently used skill stays resident; a cold one is released.
- One mechanism serves instruction skills and tool providers (MCP first).

## Non-Goals

- File-based / user-authored skill packs (a later provider on the same seam).
- Skill composition, dependencies, or versioning.
- Tiering, entitlement, or unlock gating.
- Automatic intent-based preloading (a possible later optimisation).
- Changing the built-in tools.
- A skill-management UI (the future feature that will also auto-generate names).

## User Stories

- As an **operator**, I want a small, stable tool surface, so the model selects
  well and I am not paying for capabilities I am not using.
- As an **operator**, I want the model to know a capability exists without it
  being loaded, so it can decide to use it.
- As an **operator**, I want a skill I use repeatedly to stay available without
  re-loading each turn, and a skill I used once to release itself.
- As an **operator**, I want to invoke a skill by name without waiting for the
  model to decide.
- As a **harness author**, I want one place to add a capability — a skill — that
  works the same whether it is instructions or an MCP server.
- As a **harness author**, I want activation to be observable, so I can see what is
  resident and why.

## Acceptance Criteria

### Functional Requirements

- [ ] A skill is declared with a name, a stable key, a description, a when-to-use
      hint, and its contribution (instructions and/or tools); the registry can
      list, find, and render them.
- [ ] The manifest — name, description, when-to-use, **and loaded/unloaded state**
      — is present in every request as a non-persisted system fragment before the
      first user message, and is never written to the ledger.
- [ ] There is **no** `list_available_skills` tool; availability is context.
- [ ] `load_skill(name)` activates the skill: injects its instructions and
      registers its tools; an unknown or unavailable name returns a structured
      error and changes nothing.
- [ ] An active skill is **kept alive by use**: a tool call or an explicit
      reference resets its idle timer.
- [ ] An active skill idle beyond its TTL is **unloaded** — instructions withdrawn,
      tools removed — and the manifest state changes to unloaded.
- [ ] After decay, the model can see the skill is unloaded and `load_skill` again.
- [ ] Tools contributed by a skill are namespaced (`mcp_<id>_<tool>`) and a called
      name resolves to exactly one handler.
- [ ] Base/always-on tools are unaffected: present whether or not any skill is
      loaded.
- [ ] A contributed tool is subject to the same `reason` requirement, approval
      gate, and context budget as a built-in.
- [ ] The system prompt explains that skills load on demand, decay when idle, and
      that the manifest shows the current state.

### Non-Functional Requirements

- [ ] The default tool surface is O(base), independent of the number of skills;
      adding a skill adds no request tokens until it is loaded.
- [ ] The manifest is **stable per state change**: it changes only when a skill's
      availability or state changes, so the injected prefix stays cache-friendly.
- [ ] No leaks: an unloaded skill's tools, instructions, and provider-owned
      resources are released (the heaptrc gate enforces this).
- [ ] Decay does not spin: the idle timer is checked at turn boundaries (and on
      use), not polled per frame.
- [ ] `make check` passes; macOS and Linux, FPC 3.3.1; `{$mode delphi}`.
- [ ] The Process Split is preserved (a client links no agent/tool unit).

## Success Metrics

### Quantitative

- The advertised tool count with no skill loaded equals the base count, regardless
  of how many skills are configured.
- Adding a capability adds **0** request tokens until it is loaded.
- A skill used every turn is never reloaded; a skill idle for its TTL is unloaded
  within one turn of the deadline.

### Qualitative

- Adding a capability is "declare a skill", not "edit the tool registry".
- The model's tool list is small and predictable; the manifest is the index and
  the state is honest.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- The contributor seam is `Turn_Injection`'s; skills must not add a second seam.
- The manifest is injected where the loop already injects request-only system
  fragments, and is never persisted.
- Decay is driven by the turn boundary and the monotonic clock (no per-frame
  timer), consistent with the one-clock rule.
- Tool names are strings the model sees and part of the approval `ref`; the
  namespace scheme must be stable and documented.

### Business / Time

- No deadline. `main` only, TDD-first, one logical commit per step.

## Naming

- **A skill's key is explicit and stable.** For an MCP server, the tool namespace
  is `mcp_<id>_<tool>`, where `<id>` is a unique **snake_case** identifier for the
  connection.
- **Names are explicit in v1** (operator-set). A future skill-management UI will
  auto-generate and let the operator edit them; the scheme must survive that
  (`mcp_<id>_<tool>` stays valid as an id, so auto-generated ids must be
  snake_case).
- The namespace is part of the approval `ref`, so renaming orphans approvals;
  treat `<id>` as stable.

## Dependencies

### Internal

- `docs/features/Turn_Injection/FEATURE.md` — the contributor seam
  (`Prepare`/`Specs`/`PromptFragment`/`Find`) skills plug into.
- `hildegard.helper.agent` — `IToolProvider`, `TToolRegistry`, `BuildRequest`
  (where a `PromptFragment` is injected), the tool-call budget, the turn boundary.
- `hildegard.helper.harness.session` — where contributors are registered.
- `hildegard.helper.tui.clock` — `MonotonicMs` for the decay timer.
- `hildegard.helper.store` — the ledger, which must not see the manifest.
- `docs/features/Lazy_MCP/FEATURE.md` — the first provider.

### External

- None new.

## Risks

- **The model may not load a needed skill.** Mitigation: the manifest is always
  present *with state*; the system prompt is explicit; the operator can load by
  name.
- **The load round trip.** "Load, then call" costs one turn. Mitigation: an
  explicit/preload path; and decay (not per-turn unload) means the cost is paid
  once per hot period, not once per turn.
- **Decay fires mid-task.** A skill could unload between two turns that needed it.
  Mitigation: use resets the timer; the manifest tells the model it must reload;
  TTL is per skill and generous for cheap skills.
- **Manifest metadata is a prompt-injection surface.** Mitigation: descriptions
  and when-to-use are user/curated; a provider's server-authored text (e.g. MCP
  `initialize.instructions`) is **never** placed in the manifest.
- **Injecting the manifest into the volatile surface.** If it were placed in the
  user-message/ambient wrapper it would change per request and bust the prompt
  cache. Mitigation: it is a stable system fragment (`PromptFragment`).
- **Instruction skills and decay.** A skill whose value is its *instructions*
  cannot be "kept alive" by tool use; once injected they tend to persist in the
  conversation, so decay only stops re-injection. Acceptable, and stated.
- **Namespace drift.** Renaming a provider key orphans approvals that reference the
  tool name. Mitigation: `<id>` is stable; the scheme is documented.

## Out of Scope

- File-based / user-authored skill packs.
- Skill composition, dependencies, versioning.
- Entitlements / tiers.
- Automatic intent-based preloading.
- A skill-management UI and auto-generated names.
- Changing the built-in tools.
- Windows.

## Future Considerations

- **A file-based skill provider** (`SKILL.md`-style), reusing this mechanism.
- **A skill-management UI** that auto-generates `id`s and descriptions, and lets
  the operator edit them.
- **Preload / explicit load** — operator-invoked (`/skill`), or caller-invoked, to
  skip the model's decision round trip.
- **Skill-fork into a subagent**, mirroring Anthropic's `context: fork`.
- **Per-skill TTL policy** — a cheap instruction skill vs an expensive server.

## Open Questions

1. **TTL defaults.** One global default, or per skill/provider? (MCP servers
   probably want a shorter one than an instruction pack.)
2. **What counts as "use"** — a tool call only, or also the model referencing the
   skill's instructions?
3. **Is the manifest per skill or grouped** (all MCP servers as one block)?
4. **Do instructions re-inject on reload** if they are already in the conversation
   from an earlier activation (avoid duplication)?

## Notes

- **The seam exists.** `Turn_Injection` already specifies the contributor
  interface (`Prepare`/`Specs`/`PromptFragment`/`Find`) and the per-turn
  composition; `IToolProvider` is the current form of it. Skills are a change of
  *what a contributor contributes* and *how long it stays*, not a new plumbing
  path.
- **Why decay beats turn scope.** A turn is the wrong unit: it forces a reload
  even for a skill used on every turn, and it is invisible to the model. Time
  since last use matches how a capability is actually consumed, and the state is
  something the model can see.
- **Why no `list_available_skills`.** A discovery tool is a chicken-and-egg — the
  model must call it before it knows what exists. Making availability context
  removes the round trip and the "did it list?" failure mode.
- **Anthropic alignment.** Anthropic's skills are `SKILL.md` instructions with
  progressive disclosure (description always, body on demand). We keep the
  discovery/lazy-load shape and add tools + a decay lifetime.
- **ICE score.** Impact 8 (tool-surface economy; the substrate for MCP and every
  future capability), Confidence 7 (the seam exists; decay needs calibration),
  Ease 6 (a registry, activation, decay, the manifest, several tests).
  Priority: high.
- **Related:** `docs/features/Turn_Injection/FEATURE.md` (the seam),
  `docs/features/Lazy_MCP/FEATURE.md` (the first provider),
  `docs/features/Dynamic_Tools/FEATURE.md` (the MCP reconcile it builds on),
  `docs/features/TUI_Startup/FEATURE.md` (the startup work this enables).
