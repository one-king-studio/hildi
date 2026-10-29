# Live Smoke

**Status:** Implemented (v1) — `Live_Smoke_v1.DONE.md`. `make smoke` runs five
scenarios in ~3 s; `make smoke-list` names them.

## Overview

One scripted, hermetic end-to-end check that proves the harness works **as a
running program**: a fake OpenAI-compatible provider on loopback, the real
headless runtime spawned against it, a real socket client attached, a turn
driven to completion, a tool call gated and approved, and the result persisted
and recoverable on re-attach.

Today there is no such check. Four features — [Agent Loop](../Agent_Loop/FEATURE.md),
[File Tools](../File_Tools/FEATURE.md), [TUI Harness](../TUI_Harness/FEATURE.md),
[Lazy MCP](../Lazy_MCP/FEATURE.md) — carry "live smoke pending" or "live terminal
sign-off remains" as their *only* remaining gap, and two of them have been in that
state for several features' worth of work. Those rows cannot close because the
project has no way to demonstrate that the assembled binary does what the unit
tests say its parts do.

## Problem Statement

The suite is 1416 tests and every one of them is a **unit or component** test.
They prove the parts in isolation:

- `test_llm` proves the client parses canned SSE through a fake transport.
- `test_agent` proves the loop drives tools through a fake provider.
- `test_session_runtime` proves the runtime serves a wire protocol, with the LLM
  transport injected as a seam.
- `test_harness_*` prove the pieces of the harness session.

Every one of them injects the seam that would fail in production. The transport
is fake, so no real HTTP is spoken; the runtime is in-process, so no `exec` is
crossed; the store is opened directly, so no detached process writes it. **No test
starts the program the operator starts.**

That gap has a cost that is not hypothetical:

- `test_session_runtime` has a `TestSpawnAndAttach` that re-executes the test
  binary as a runtime — the closest thing to an end-to-end check, and it stops at
  "hello, attached". It never runs a turn.
- A spawned runtime gets its endpoint from `--endpoint` only. `SpawnDetached` does
  not pass one and `ResolveLLMConfig` does not read `HILdegard_LLM_ENDPOINT` from
  the environment, so **a spawned runtime cannot be pointed at a test endpoint at
  all** — which is precisely why no test drives a spawned turn.
- The composed-tool-sandbox episode recorded the same lesson from the other side:
  three narrow probes each ran a failing file cleanly, and only the *assembled*
  runner reached the fault. Single-layer tests systematically miss integration
  faults, and they miss them last.

The honest state is that the project asserts "it works" from unit evidence and
asks the operator to confirm the rest by hand. That is a standing invitation for
an integration regression to sit undetected until someone happens to launch it.

## Goals

- **One command** (`make smoke`) drives a full turn end to end and exits non-zero
  on any assertion failure.
- **Hermetic**: loopback only, an ephemeral port, a temporary workspace and store,
  no network, no credentials, no Docker. It must be safe to run in `make check`.
- **The real binary**: the runtime is a spawned process, not an in-process object.
  The socket, the detach, the argv, and the store are all exercised as shipped.
- **A tool call actually happens**: the fake provider asks for `file_write`, the
  gate raises an approval ask, the client approves, the file lands in the temp
  workspace, and the result is observable on the wire.
- **Persistence is proven**: re-attaching to the same session renders the turn
  from the ledger, so "live" and "resumed" are the same bytes by test rather than
  by hope.
- **Cheap to extend**: a new scenario is a fake-provider script plus assertions,
  not a new harness.

## User Stories

- As the **operator**, I want `make smoke` to tell me the assembled program works
  end to end before I launch it by hand, so a launch failure is caught on my
  machine in seconds rather than discovered mid-session.
- As the **agent working on this codebase**, I want an integration failure to name
  the layer it failed at (provider / transport / runtime / wire / gate / store),
  so I do not start by guessing.
- As a **feature owner**, I want to close a feature whose only gap is "live smoke
  pending" by pointing at a passing scenario, so the index stops lying about what
  remains.
- As a **reviewer**, I want the smoke to assert the *same* invariants the specs
  claim (reason required, gate authoritative, live and resumed agree), so a
  green smoke is evidence rather than a formality.

## Acceptance Criteria

### Functional Requirements

- [ ] A **fake provider** serves `POST` with an OpenAI-compatible SSE stream on a
      loopback ephemeral port, and can be scripted per scenario: text deltas,
      reasoning deltas, a tool call (`name` + streamed `arguments`), a finish
      reason, a usage frame, and a mid-stream error.
- [ ] The fake provider **records each request body** so a scenario can assert
      what the harness sent (the tool schema, the wrapper, the reason).
- [ ] The **real headless runtime** is spawned as a separate process with
      `--session-runtime`, `--workspace`, `--store`, `--endpoint`, `--model`,
      `--idle-ms`, and the client attaches to its socket with `Spawn := False`.
- [ ] A **text-only turn** streams to the client and finishes; the assembled
      assistant message is persisted exactly once.
- [ ] A **tool-call turn** raises `ekApprovalRequest` with the tool's `reason`,
      the client answers with `scApprove`, the tool runs, `ekToolResult` carries
      the tool's text, and the turn finishes.
- [ ] The tool's effect is **real**: the file exists in the temp workspace with
      the expected content.
- [ ] A **denied** approval yields a denial the model sees (the tool result is a
      denial, the turn continues) — not a hung turn.
- [ ] **Re-attach** to the same session renders the same turn from the ledger:
      the same user text, the same tool call, the same result. Live and resumed
      agree.
- [ ] Every exit path **cleans up**: the runtime process is terminated, the
      socket is removed, and the temp directory is deleted, pass or fail.
- [ ] The smoke **never hangs**: every wait has a deadline and a named failure.

### Non-Functional Requirements

- [ ] **Hermetic**: loopback only; no external network, no credentials, no Docker.
      Safe in `make check` on a machine with no API key.
- [ ] **Fast**: the default scenario set completes in a few seconds.
- [ ] **Diagnosable**: a failure prints which stage failed and the last events
      seen, not just an assertion number.
- [ ] **Portable**: macOS + Linux, arm64 + x86-64, FPC 3.3.1. No new dependency.
- [ ] `make check` green; leak-clean. `make smoke` is a separate target (it forks
      a process) so the unit gate's shape does not change.

## Success Metrics

### Quantitative

- The four In Progress features citing a live gap can each point at a named
  scenario that covers their claim.
- The smoke adds no more than ~600 lines (fake provider + one scenario file +
  assertions) and no new build dependency.
- Wall time under ~5 s for the default set.

### Qualitative

- A launch regression (a bad argv, a missing env fallback, a socket path change)
  fails the smoke rather than the operator's first session.
- "Live smoke pending" stops being a permanent footnote in the feature index.

## Constraints

### Technical

- **No fcl-web.** `fphttpserver` buffers the response and would not let a
  scenario stream deltas over time — the property being tested. The fake provider
  is a small raw-socket server (`BaseUnix`/`Sockets`), which also keeps the
  dependency surface unchanged.
- **The runtime needs `--endpoint` explicitly.** `ResolveLLMConfig` reads the
  model and key from the environment but *not* the endpoint, and `SpawnDetached`
  passes no `--endpoint`. The smoke therefore spawns the runtime itself rather
  than using `TSessionClient.Open(Spawn := True)`. (Recorded as a real gap: a
  spawned runtime cannot be pointed anywhere but the default endpoint.)
- **`TLLMClient` requires a non-empty model and API key** even for a local
  endpoint, so the smoke supplies a dummy key. That is a product wart worth
  recording, not a reason to weaken the check.

### Operational

- Must not disturb a real runtime: use a fresh session id, and a `--store` inside
  the temp directory.

## Dependencies

### Internal

`hildi.session.runtime` (the spawned program),
`hildi.session.client` (the wire), `hildi.session.protocol`
(the codec), `hildi.store` (ledger read-back),
`hildi.harness.session` (approval defaults).

### External

FPC's `Sockets`/`BaseUnix` only.

## Risks

- **Flaky timing.** A spawned process plus a socket plus a stream has more
  scheduling than a unit test. Mitigation: every wait is a deadline with a tight
  poll, the turn has a hard ceiling, and the scenarios are sized so the default
  run is far inside it.
- **Port collisions.** Mitigation: bind port 0 and read back the assigned port.
- **Zombie runtimes.** A failed scenario could leave a process listening.
  Mitigation: cleanup in a `finally`, terminate-then-kill, and assert the socket
  is gone at the end.
- **Duplicating the unit suite.** The smoke must not become a second, slower way
  to test parsing. It exists for the seams the units inject away; anything
  provable in a unit stays in a unit.

## Out of Scope

- The **TUI** itself. Driving a terminal needs a pty and is a separate feature; the
  smoke exercises the runtime and the wire, which is what the TUI consumes. A
  pty-driven TUI scenario is future work (and would be the honest way to close
  TUI Harness's manual sign-off).
- Real models, real MCP servers, Docker, the network.
- Load, soak, and wall-clock performance (that is `make bench`).

## Future Considerations

- A `--record` mode that writes a passing run's wire log, so a regression can be
  diffed against a known-good transcript.
- Scenarios as data (a small script file) rather than code, if the set grows past
  a handful.
- A pty variant for the TUI, reusing the same provider and the same assertions.

## Notes

- Precedent for a local server in the suite already exists:
  `tests/tls_test_server.c` is a real HTTP/TLS server linked into the test binary.
- `TestSpawnAndAttach` proves the spawn path works to "hello, attached". This
  feature is the missing half: it proves a *turn* works through that path.
- Related: [Process Split](../Process_Split/FEATURE.md) (the two-binary boundary
  this exercises for real), [Tool Approvals](../Tool_Approvals/FEATURE.md) (the
  gate the scenario drives).
