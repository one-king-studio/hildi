# Process Split

## Overview

Split hildegard-helper into two programs: a **headless agent** that runs a
session's loop with no terminal, and a **TUI client** that renders and drives it
with no loop. Today one binary is both — `examples/tui_agent.pas` re-executes
itself with `--session-runtime` to spawn the loop — so each process maps the
whole program while using half of it.

The split gives each program only its half: the headless agent links no widget,
no terminal escape or OSC handling, no markdown renderer; the TUI links no agent
loop, no tool registry, no runtime server. It also trims the duplication the
current shape hides — the runtime loads message history it never reads, and the
TUI (in `NoLoop` mode) builds an LLM client and registers the default tools it
never uses — and windows the TUI's chat list, which today holds every block ever
rendered and dominates the TUI's footprint.

## Problem Statement

The headless-session work put the loop in its own process, which was right, but
left both processes as the same binary. The costs are structural, not runtime
throughput:

- **The headless agent carries UI it can never use.** A binary deployed to a
  remote device links the widget kit, the terminal input decoder, OSC background
  detection, and the markdown renderer — all reachable code on a machine with no
  terminal. That is surface and size the agent should not have.
- **The TUI carries the loop it never runs.** `examples/tui_agent.pas` uses
  `harness.driver`, which uses the full `harness.session` and the
  `session.runtime` server; the TUI therefore links the agent loop, the command
  tool, the file tools, the recall tool, and the conversation store. In
  `NoLoop` mode `THarnessSession.Init` even constructs a `TLLMClient` and calls
  `RegisterDefaultTools` before exiting — objects the TUI immediately drops.
- **The runtime loads history it never reads.** `THarnessSession.Init` queries
  every message into `FHistory` before the `NoLoop` early-exit, but the loop
  never calls `History`; `TSqliteConversationStore.Compose` re-queries from
  SQLite per request. The load is pure waste in the runtime.
- **The TUI's memory grows with the session.** `TChatList` holds
  `FItems: array of TChatItem` — every block, with its styled spans and rendered
  markdown — for the whole transcript.

Measured on a live session (macOS, `vmmap -summary`): the TUI process has a
56.6 MB physical footprint, the runtime 12.7 MB, and both map the same 6.4 MB
binary. The second process is cheap; the split is not about reclaiming RAM that
one binary "doubled" — it is about separation, deployment surface, and the TUI's
own unbounded chat list.

**Ponytail check.** Nothing here is new capability: the protocol, the runtime,
the client, the chat list, and the process spawner all exist. This feature
removes code from each binary and bounds a growing list. It is a refactor with a
measurable outcome, not a new subsystem.

## Decision

**Committed: two programs, split along the client/server seam that already
exists in the code.**

- The **headless agent** (`hildegard-helper-agent`) hosts the session runtime:
  `RunSessionRuntime`, the loop, the tools, the store. No TUI unit.
- The **TUI client** (`hildegard-helper-tui`) renders and drives: the widget kit,
  the app, the remote driver, the client session view. No agent/tool/runtime
  unit.
- The **split is enforced by unit boundaries**, not by a build flag: the client
  half (`session.client`, the session view, the turn *types*) is separated from
  the server half (`session.runtime`, the turn *worker*, the full session) so the
  compiler's `uses` closure keeps each binary honest.
- **Runtime discovery:** the TUI spawns the headless binary located by
  `HILDEGARD_RUNTIME_BIN`, else a sibling of the TUI executable.
- **`TLocalDriver` stays**, in its own unit, for tests and demos.
- **The chat list is windowed:** it holds the visible range plus a bounded tail,
  not every block.

## Goals

- Two independently built binaries; the headless agent links no TUI unit and the
  TUI links no agent/tool/runtime unit.
- The runtime opens a session without loading its history; the client opens a
  session without building an LLM client or the tool registry.
- The TUI's footprint does not scale with the number of rendered blocks.
- No behaviour change: the same protocol, the same rendering, and live/resume
  parity are preserved.
- The client/server seam is expressed in units, so the boundary is enforced by
  the compiler rather than by discipline.

## Non-Goals

- Cross-process shared memory for the transcript. The SQLite store on disk is the
  shared truth; the in-memory copies are the client's render state and the loop's
  current request, which are different representations with different lifetimes.
- Removing the TUI's direct store access. It still reads history and stats from
  SQLite; streaming the ledger over the wire is Remote Agent Link's territory.
- The daemon/supervisor and the network transport (Remote Agent Link).
- Windows.

## User Stories

- As an **operator deploying to a remote device**, I want a headless binary with
  no terminal or UI code, so the surface I ship is only the agent.
- As an **operator**, I want the TUI to stay small on a long session, so a large
  transcript does not grow its memory without bound.
- As a **harness author**, I want the client/server seam expressed in units, so
  the TUI cannot accidentally link the loop and the runtime cannot link a widget.
- As a **harness author**, I want the two binaries built and tested separately,
  so I can ship the agent without the interface.

## Acceptance Criteria

### Functional Requirements

Binaries

- [ ] `hildegard-helper-agent` runs the session runtime (`RunSessionRuntime`) and
      links no TUI unit.
- [ ] `hildegard-helper-tui` drives a runtime and links no `agent`,
      `harness.session` (the loop), `harness.turn.worker`, `command.tool`,
      `files`, `recall.tool`, `session.store`, or `session.runtime` unit.
- [ ] The TUI spawns the headless binary, located by `HILDEGARD_RUNTIME_BIN`,
      else a sibling of the TUI executable; a missing binary is a clear error.
- [ ] `agent_cli` uses the client units and no longer hosts the runtime.

Bootstrap trimming

- [ ] The runtime opens a session without loading its message history.
- [ ] The client opens a session without constructing an LLM client or
      registering the default tools.

Chat windowing

- [ ] The chat list renders only the visible window plus a bounded tail and
      scrolls correctly without retaining every block.
- [ ] Live streaming (a growing tool block) and resumed rendering both work
      against the windowed list.

### Non-Functional Requirements

- [ ] No protocol or rendering behaviour change: a resumed view matches the live
      view, and the wire schema is unchanged.
- [ ] The TUI's physical footprint no longer scales with the number of rendered
      blocks (measured before and after).
- [ ] `TLocalDriver` is retained for tests and demos, in its own unit.
- [ ] Portability: macOS and Linux, FPC 3.3.1.
- [ ] `make check` passes (functional tests plus the leak gate).

## Success Metrics

### Quantitative

- TUI footprint on a fixed, large transcript: **materially lower than the 56.6 MB
  baseline**, and flat as the transcript grows.
- The TUI binary's link closure excludes the agent/tool/runtime units (verified
  by the unit graph, not by size alone).

### Qualitative

- The headless agent reads as a single-purpose program.
- The client/server boundary is obvious from the unit names.
- No new special-casing in the app, the driver, or the protocol.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- Must reuse the existing protocol, runtime, client, chat list, and process
  spawner; the split moves code between units, it does not rewrite it.
- Unit names stay stable where the type is widely used (`harness.turn` keeps the
  turn *types*); the agent-coupled type moves out, not the widely-used one.
- No new runtime dependency; both binaries stay self-contained.

### Business / Time

- No deadline. Work on `main`, TDD-first, one logical commit per step.

## Dependencies

### Internal

- `hildegard.helper.session.protocol` — the shared, versioned wire schema; the
  split removes the server from the client, not the schema.
- `hildegard.helper.session.runtime` — the runtime server, split from the client.
- `hildegard.helper.harness.session` — the full loop bootstrap, split from the
  client-only session view.
- `hildegard.helper.harness.turn` — the turn types, split from the worker.
- `hildegard.helper.harness.driver` — the remote driver stays; `TLocalDriver`
  moves to its own unit.
- `tui.widgets.chat` / `.chatpanel` — the chat list that becomes
  windowed.

### External

- Unix domain sockets and the detached-process spawn idiom — already in use; no
  new dependency.

## Risks

- **Unit-split churn.** Moving `TSessionClient`, the turn types, and the session
  view touches many `uses` clauses and several tests. Mitigation: keep the
  widely-used unit names stable; move the agent-coupled declarations out.
- **Two binaries drift.** The client and server must agree on the protocol.
  Mitigation: the protocol unit is shared and versioned; the split is a
  dependency change, not a schema change.
- **Runtime discovery.** A TUI without a matching headless binary cannot spawn.
  Mitigation: an explicit env var with a sibling fallback and a clear error.
- **Windowing correctness.** A windowed list must still measure and render
  exactly, including a live-growing item. Mitigation: window the item list, not
  the layout geometry, and keep the existing measurement path.
- **Hidden coupling.** A unit may pull the agent through a transitive `uses` the
  split misses. Mitigation: assert the boundary in a test (a link-closure check
  over the client units).

## Out of Scope

- Shared memory / `mmap` of the transcript between the two processes.
- Streaming ledger history over the wire (the TUI keeps reading the store).
- The daemon and the network transport.
- Windows.

## Future Considerations

- A link-closure assertion in `make check`, so a stray `uses` cannot re-couple
  the binaries.
- Streaming history over the wire, which would let the TUI drop its store
  dependency entirely.
- A single supervisor that spawns and reaps runtimes (Remote Agent Link).

## Notes

- **Measurements (live, macOS).** TUI `34808`: 56.6 MB footprint. Runtime
  `34811`: 12.7 MB (peak 16.0 MB). Both map the same 6.4 MB binary, so the OS
  shares their read-only pages — the same binary is not what inflates memory; the
  TUI's chat list is. `ps` VSZ (~443 MB each) is address space, not memory.
- **Why not shared memory.** The transcript on disk is already the shared copy.
  An `mmap` region for a variable-length object graph would add a layout, a
  lock, and a lifetime problem to save a few megabytes the runtime does not even
  hold today.
- **ICE score.** Impact 6 (deployment surface and TUI growth, not throughput),
  Confidence 8 (the seam exists; the split is mechanical), Ease 5 (many units,
  several tests). Priority: medium-high.
- **Code facts this rests on** (verified): the TUI links the agent stack via
  `harness.driver` → `harness.session` and via `session.runtime`; `harness.turn`
  bundles `TTurnEvent`/`TTurnQueue` with `TTurnWorker` (agent); `harness.session`
  bundles the store/history view with the loop; `session.runtime` bundles the
  server with `TSessionClient`; `TChatList.FItems` holds every item.
