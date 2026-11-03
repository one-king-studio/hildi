# Workspace Instructions (AGENTS.md)

**Related:** [Workspace_Instructions_v1.SPEC.md](Workspace_Instructions_v1.SPEC.md)

## Overview

Load the workspace's own instructions — `AGENTS.md`, or a README standing in for
it — and deliver them to the model as part of the prompt, re-read at every turn
so an edit takes effect without restarting the session.

This document also records the **prompt split** the work forced: which guidance
is static enough to be sent once, and which has to be rebuilt every turn.

## Problem Statement

Every repository accumulates rules that a worker must know: how to build it, what
"done" means here, which paths are off limits, which conventions are not
negotiable. A human reads `CONTRIBUTING.md` or `AGENTS.md` on day one. An agent
arriving in the workspace today has no way to be told.

The cost is not hypothetical and it is repetitive:

- The operator retypes standing instructions into the first prompt of every
  session, and again after every `/checkpoint`.
- The model guesses at build commands, and gets them wrong in ways that cost
  whole turns of tool calls.
- Knowledge that lives only in the operator's head cannot be delegated. A
  subagent gets none of it.

There is an existing partial answer — the `AGENTS.md` convention itself, already
present in this repo — but nothing in the harness reads it.

## Goals

- The workspace's instructions reach the model with no operator action.
- An edit to the file is visible on the **next turn**, not the next session.
- The file can never outrank the harness's own rules, however it is written.
- Standing guidance stops being re-sent on every request where it need not be.

## User Stories

- As an operator, I want the repository's build and review rules to reach the
  agent automatically, so I do not restate them in every session.
- As an operator, I want to fix a rule mid-session and have the fix take effect
  on the next turn, so a long session is not stranded on stale instructions.
- As a harness author, I want static guidance out of the per-turn text, so it is
  cached rather than re-billed on every request.

## Acceptance Criteria

### Functional Requirements

- [x] `AGENTS.md` at the workspace root is read and injected into the prompt.
- [x] When it is absent, the first of `README.md`, `readme.md`, `README`,
      `readme` stands in.
- [x] The prompt states **which file** the text came from, in the prose and in
      the wrapping element.
- [x] The text is wrapped in `<agents_md source="...">` and named as file
      contents, explicitly subordinate to the harness's rules.
- [x] The file is re-read at every turn boundary, so an edit is picked up
      without a restart.
- [x] An absent, unreadable, empty or binary file is silently omitted — no error
      and no empty wrapper.
- [x] Oversized files are truncated with a `[truncated at N bytes]` marker.
- [x] Static guidance — the shell tier's rules and the board/task rules — is
      delivered in the system prompt, once per session.
- [x] Genuinely variable guidance — the coordination **mode** line — stays in
      the per-turn text.

### Non-Functional Requirements

- [x] No new dependency; the file is read with the RTL.
- [x] Injected text cannot exceed the cap, so it cannot silently consume the
      context window.
- [x] A malformed file never fails a turn.
- [x] `make check` green, leak-clean.

## Success Metrics

### Quantitative

- The file is read once per turn — one `stat` + one read per candidate, stopping
  at the first hit.
- Cap: 32 KB, comfortably below a context window and above any real instructions
  file.

### Qualitative

- A new contributor's rules reach the agent without the operator typing them.
- The model treats the file as context about the project, not as orders.

## Decision: the prompt split

The work turned on a distinction worth recording, because the naive version is
wrong in a way that fails silently.

**The system message is written once and never rewritten** (`HildiAgent.pas:1831`
appends it only when the store has no messages). Anything placed there is frozen
for the session's life.

That is correct for genuinely static guidance and fatal for anything else:

| Guidance | Varies mid-session? | Placement |
| --- | --- | --- |
| Base + behavioural instructions | no | system prompt |
| Shell tier rules (`BuiltinCommandList`) | no — generated from the dispatch table | system prompt |
| Board / task **rules** | no — fixed prose | system prompt |
| **Coordination mode** line | **yes** — a peer can attach | per-turn stable text |
| **Workspace instructions** | **yes** — the operator edits them | per-turn stable text |
| Skill catalogue | yes — a skill can be loaded | per-turn stable text |

Putting the mode line in the system prompt would freeze *"You are ALONE in this
workspace"* for a session that later gains a peer — the exact state the sentence
exists to prevent. So `CoordinationPromptFor` was split into
`CoordinationRulesText` (static) and `CoordinationModeLine` (per turn).

**Cacheability.** The system prompt is byte-identical for the whole session, and
the per-turn text is byte-identical *within* a turn — rebuilt at the boundary,
then stable across that turn's requests. Only the volatile tail (`<context>`,
guard, advisory) rides the newest message. So the split costs one re-send per
turn for the parts that can change, and nothing for the parts that cannot.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`.
- The system prompt is assembled in `THarnessSession.Open`; it must stay
  assembled before the loop is created.
- `HildiFiles.ReadTextFile` is implementation-only, so the read is local rather
  than widening that unit's interface for one caller.

### Security

**The file is repository content, and therefore attacker-influenced.** Any repo
the operator clones can carry an `AGENTS.md`; a prompt-injection payload there
would be read by the model on the first turn with no operator action. That is why
the text is:

- wrapped in a named element, so it is never mistaken for harness instructions;
- described as *context written by whoever authored the repository*;
- explicitly subordinated — instructions to conceal something from the operator,
  or to disregard the rules, are to be ignored.

The harness keeps the last word by naming the source, not by trusting it.

## Dependencies

### Internal

- `HildiHarnessSession` — assembles both prompts.
- `HildiCoordination` — `CoordinationRulesText` / `CoordinationModeLine`.
- `HildiShellCommands` — `BuiltinCommandList`.

### External

None.

## Risks

- **An oversized file crowds out work.** Mitigation: 32 KB cap with a visible
  truncation marker, so the model knows it is reading a prefix.
- **A project file contradicts the operator.** Mitigation: the subordination
  paragraph; the harness's rules are stated as outranking the file.
- **The split drifts** — something variable creeps into the system prompt.
  Mitigation: `TestTheCoordinationTextRidesTheSystemPrompt` asserts the mode line
  is *absent* from the system prompt.

## Out of Scope

- Nested or per-directory instructions (`src/AGENTS.md` and the like). Root only.
- Merging several files, or any precedence chain beyond the first hit.
- Watching the file for changes between turns; a turn boundary is the cadence.
- Editing the file from the TUI.
- Any other convention (`CLAUDE.md`, `.cursorrules`, …).

## Future Considerations

- Per-directory instructions, which is where a monorepo would want this.
- A TUI affordance for "which instructions am I running under".
- Reporting a shadowed file — if both `AGENTS.md` and `README.md` exist, the
  README is silently unused, and the operator may not know why their edit did
  nothing.
