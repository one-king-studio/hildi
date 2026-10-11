# Component Specification: Skills v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.agent` (`IToolProvider`, `TToolRegistry`,
`TToolSpec`, `TRegisteredTool`, `TToolHandler`, `MakeToolSpec`, `BuildRequest`,
`PrepareProviders`), `SysUtils` (`GetTickCount64`).
**Depended on by:** `Lazy_MCP` (an MCP connection becomes a skill); the future
file-based instruction packs.

## Purpose

Give the loop a **capability layer**: a *skill* is a named, on-demand capability
(instructions and/or tools) advertised by a manifest and activated by
`load_skill`. The default tool surface stays O(base); a skill costs nothing until
it is loaded, and it is released when idle.

This is the mechanism, not a provider. MCP is the first provider
(`Lazy_MCP`); it supplies an `ISkillToolSource` that connects on load.

## Prior art and reuse

The seam already exists; this adds the registry and one tool.

| Need | Existing unit | What changes |
| --- | --- | --- |
| The contributor seam | `hildegard.helper.agent` `IToolProvider` (`Prepare`/`Specs`/`PromptFragment`/`Find`) | `TSkillRegistry` **implements** it — no new seam |
| Request-only prompt injection | `TAgentLoop.BuildRequest` (already injects provider `PromptFragment` as `crSystem`, never persisted) | none — the manifest rides it |
| Tool dispatch + approval | `ExecuteToolCalls` → `FTools.Find` then provider `Find` | none — loaded tools resolve through `Find` |
| Turn boundary | `TAgentLoop.PrepareProviders` (`OnTurnStart` + each `Prepare`) | the registry's `Prepare` runs decay here |
| The clock | `SysUtils` `GetTickCount64` (monotonic) | reuse for the idle TTL — **not** `tui.clock` (the registry must not link a TUI unit; the Process Split forbids it) |
| Spec building | `MakeToolSpec` (adds the required `reason` param) | reuse for `load_skill` and tool specs |

New unit: `hildegard.helper.skills`. Nothing else is new.

## Requirements

### Functional

- [ ] A skill is declared with a **key** (stable, snake_case), a name, a
      description, a when-to-use hint, optional instructions, and an optional
      **tool source** (`ISkillToolSource`). A registry can `Add`, list, and find
      them.
- [ ] `TSkillRegistry` is an `IToolProvider`: its `PromptFragment` is the
      **manifest**, its `Specs` are the active skills' tools plus the always-on
      `load_skill`, and its `Find` resolves a called name.
- [ ] The manifest lists **every** skill — name, description, when-to-use, **and
      state (loaded/unloaded)** — and is stable per state change.
- [ ] `load_skill(name)` activates: calls the source's `Activate` (connect +
      discover), injects the instructions, and offers the tools. An unknown key,
      or an `Activate` failure, returns a **structured error** and changes nothing.
- [ ] An active skill is **kept alive by use**: a `Find` hit on one of its tools,
      or a re-`load_skill`, resets its idle timer.
- [ ] An active skill idle beyond its TTL is **unloaded** at the next turn
      boundary (`Prepare`): instructions withdrawn, source `Deactivate`d, tools
      removed; the manifest reports `unloaded`.
- [ ] A skill's tools are **namespaced by the source** (`mcp_<id>_<tool>`); a
      called name resolves to exactly one handler (first provider wins, then the
      base registry).
- [ ] `load_skill` is **always present** (independent of any skill's state).
- [ ] Base tools are unaffected: present whether or not any skill is loaded.
- [ ] Loaded tools obey the built-ins' rules: the required `reason`, the approval
      gate, the context budget.

### Non-Functional

- [ ] With no skill loaded, the request's tool count equals the base count plus
      one (`load_skill`), regardless of how many skills are declared.
- [ ] Adding a skill adds **0** request tokens until it is loaded (the manifest
      line is the only cost, and it is constant).
- [ ] The manifest changes only on a state change (cache-friendly prefix).
- [ ] No leaks: an unloaded skill's tools, instructions, and source resources are
      released (heaptrc gate).
- [ ] Decay is checked at turn boundaries and on use — **never** per frame.
- [ ] `make check` green; macOS and Linux; FPC 3.3.1; `{$mode delphi}`.

## Contracts & Interfaces

> Pascal type declarations; bodies are the implementer's.

### The skill and its tool source

```pascal
unit hildegard.helper.skills;

uses hildegard.helper.agent;

type
  TSkillState = (ssUnloaded, ssLoaded);

  { What a skill needs to connect and offer tools. Nil for an instruction-only
    skill (which activates with instructions alone). The registry never calls
    Deactivate on a source it did not Activate. }
  ISkillToolSource = interface
    { Connect + discover. False + AError on failure, leaving nothing half-open.
      Idempotent: activating an active source is a no-op that succeeds. }
    function Activate(out AError: string): Boolean;
    { Release the connection and any provider-owned resources. Idempotent. }
    procedure Deactivate;
    { The tools while active (already reason-augmented; namespaced by the
      source). Empty when inactive. }
    function Specs: TToolSpecArray;
    { Resolve a called name to a handler. }
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
  end;

  { A declared skill. Key is the stable, snake_case identity (part of the
    approval ref via the tool namespace); Name/Description/WhenToUse are
    CURATED (operator or a template) - never a provider's server-authored text. }
  TSkill = record
    Key: string;
    Name: string;
    Description: string;
    WhenToUse: string;
    Instructions: string;   // injected while loaded; '' for a tool-only skill
    TTLMs: Int64;           // idle TTL; 0 => DefaultSkillTtlMs
  end;
```

### The registry

```pascal
  { The manifest/activation engine. One registry per session, registered with
    the loop as an IToolProvider. Loop-thread only (like every provider). }
  TSkillRegistry = class(TInterfacedObject, IToolProvider)
  public
    constructor Create;
    { Declare a skill. ASource is nil for an instruction-only skill. The same
      key twice replaces the declaration. }
    procedure Add(const ASkill: TSkill; const ASource: ISkillToolSource = nil);

    { Activate by key. False + AError (structured) on unknown key or a source
      failure; nothing changes on failure. Resets the idle timer. }
    function LoadSkill(const AKey: string; out AError: string): Boolean;
    { The current state of a declared key. }
    function StateOf(const AKey: string): TSkillState;
    { The rendered manifest (stable per state change). }
    function Manifest: string;

    { IToolProvider }
    procedure Prepare;                                        // decay
    function Specs: TToolSpecArray;                           // active + load_skill
    function PromptFragment: string;                          // = Manifest
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
  end;

const
  { The default idle TTL for a skill that does not set one. }
  DefaultSkillTtlMs = 600000;   // 10 minutes
  { The always-present activation tool's name. }
  LoadSkillToolName = 'load_skill';
```

### The `load_skill` tool (registry-owned)

```text
name        load_skill
params      { "reason": string (required, as for every tool),
              "name":   string (the skill key) }
result      ok: "loaded <key>; tools: a, b" | "already loaded"
error       "unknown skill: <key>" | "load failed: <source error>"
approval    NOT approval-gated (a control verb, like subagent_message); the
            tools it enables are each gated as usual
```

### Manifest format (a `crSystem` fragment; never persisted)

```text
Skills (load on demand; load_skill to activate, state shown):
- notion (unloaded): Read and write Notion pages. Use when the task concerns the user's Notion workspace.
- mcp_playwright (loaded): Browser automation. Use for tasks needing a real browser.
```

- One line per declared skill; deterministic order (declaration order); the state
  is the only thing that changes.

## Data flow

- **Turn start** (`Prepare`): run decay — for each active skill, if
  `MonotonicMs - LastUsedMs > TTL`, `Deactivate` the source and mark unloaded.
- **Request assembly** (`BuildRequest`): the registry's `PromptFragment` (the
  manifest) is injected as a request-only system fragment; `Specs` (active tools +
  `load_skill`) join the tool list. Nothing is persisted.
- **`load_skill` call**: `Find` resolves it; the handler validates the key, calls
  `Activate`, records `LastUsedMs`, and returns the tool names. A failure returns
  the structured error and changes nothing.
- **Tool use**: `Find` on a namespaced name resolves through the owning skill's
  source and **resets that skill's idle timer**.
- **Decay**: at the next `Prepare` after the TTL, the skill is unloaded; the
  manifest's next render shows `unloaded`, so the model knows to reload.

## Validation and error handling

- **Unknown key**: `load_skill` returns `unknown skill: <key>`; no state change.
- **Activate failure**: the source's `AError` is returned as `load failed: ...`;
  the skill stays unloaded and no tools are added.
- **Double load**: a no-op success (`already loaded`), timer reset.
- **Decay of an unused skill**: silent except the manifest state; recorded as a
  session event (observability).
- **A broken source** never wedges the loop: `Prepare`/`Specs`/`Find` are already
  wrapped by the loop; the registry additionally guards each source call.

## Testing strategy

What must be covered (the tester chooses how; a fake `ISkillToolSource`):

- Declare skills; `Manifest` lists all with state; a state change changes exactly
  one line.
- `load_skill` on a known key activates: instructions present in the fragment,
  the source's tools in `Specs`, state `loaded`; on an unknown key returns the
  error and changes nothing.
- `Activate` failure returns the error; the skill stays unloaded.
- A `Find` hit on a loaded skill's tool resets its timer; an idle skill is
  unloaded at the next `Prepare` (advance the clock); the manifest then shows
  `unloaded`.
- With no skill loaded, `Specs` = base + `load_skill` only; loading adds the
  source's tools.
- Tool namespacing: a namespaced name resolves to one handler; an unloaded
  skill's tools are gone.
- `load_skill` is present regardless of state.
- No leak: loading then unloading releases the source and its tools.

## Performance

- The manifest is a constant-size fragment; adding skills adds no request tokens
  until loaded.
- Decay is O(active skills) at the turn boundary; no per-frame work, no timer
  thread.
- `Specs`/`Find` are O(active skills) and O(tools) — small.

## Open questions (settle at implementation)

1. `load_skill` approval: confirmed **not** gated (control verb); revisit if a
   loaded server can be dangerous on connect alone.
2. TTL default (10 min here) and whether MCP overrides it per server
   (`Lazy_MCP` decides).
3. Manifest wording/placement: after the base system message (as
   `BuildRequest` already does) — confirmed.
4. Is a curated `whenToUse` required, or may it default to the description?
   (Default: required for MCP, optional otherwise.)
