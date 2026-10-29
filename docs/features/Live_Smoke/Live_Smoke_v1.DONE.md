# Implementation Plan: Live Smoke v1

**Status: DONE.** Five scenarios green; `make smoke` exits non-zero on failure
(verified by a deliberate break); `make check` unaffected at 1424 tests.

**Related Specification:** `Live_Smoke_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

A fake OpenAI-compatible provider on loopback, a scenario runner that spawns the
REAL headless runtime against it, and `make smoke`. TDD-first; `make check` before
moving on. `main` only.

> **Prerequisite found while speccing (file separately, do not block on it):**
> `HILDI_LLM_ENDPOINT` is advertised in `hildi.cli`'s help text and
> never read, and `SpawnDetached` passes no `--endpoint`/`--model`. A spawned
> runtime therefore cannot be aimed at a test endpoint by any supported route.
> The smoke spawns with an explicit argv instead, which is also the stronger test.

## Implementation Tasks

### Phase 1: The fake provider (`tests/smoke_provider.pas`)

- [ ] **Test**: `Start` binds `127.0.0.1:0`, `Port` is non-zero, and a second
      `Start` on the same instance is a no-op returning True.
- [ ] **Implement**: the listener socket (`Sockets`, `SO_REUSEADDR`, port 0,
      `fpGetSockName` to read the assigned port).
- [ ] **Test**: one `POST` with a one-frame script yields exactly the frames, in
      order, and the recorded body equals the request body.
- [ ] **Implement**: the accept loop on a thread; the minimal HTTP/1.1 parse
      (`Content-Length`, no chunked, one request per connection).
- [ ] **Test**: a script with `StatusCode := 400` returns that status and a body
      the client surfaces.
- [ ] **Implement**: the status path; `FrameDelayMs`.
- [ ] **Test**: two scripts run in order, the second request gets the second
      script, and a third request repeats the last.
- [ ] **Implement**: the script queue.
- [ ] **Test**: `Stop` closes the listener and the worker thread without leaking
      (the test suite's leak gate covers it if this unit is registered).
- [ ] **Implement**: `Stop`/`Destroy`.

### Phase 2: Frame builders

- [ ] **Reuse, do not rewrite**: `tests/llm_fakes.pas` already has `SSE`,
      `TextDelta`, `ToolNameFrame`, `ToolArgsFrame`, `FinishFrame`, `UsageFrame`,
      `DoneFrame`. Add `smoke_provider` to that unit's consumers rather than
      copying them; if the unit is too test-specific, move the builders to a tiny
      shared helper both use. **One implementation of the wire shape.**

### Phase 3: The runner (`tests/smoke_runner.pas`)

- [ ] **Test**: `ScenarioNames` is non-empty and sorted; an unknown name returns
      `Ok = False` with `Stage = 'scenario'`.
- [ ] **Implement**: the scenario registry.
- [ ] **Test**: `TSmokeHost.StartRuntime` fails with a named stage when the binary
      path does not exist (no hang, no crash).
- [ ] **Implement**: `TProcess` spawn with the explicit argv; `WaitForSocket` with
      a deadline.
- [ ] **Test**: cleanup removes the socket and the temp directory even when a
      scenario fails (force one to fail and assert).
- [ ] **Implement**: the `finally` cleanup: terminate, then kill,
      `DeleteSocket`, `RemoveDir`.
- [ ] **Test**: `WaitFor` returns False at the deadline with the reason.
- [ ] **Implement**: the poll helper.

### Phase 4: Scenarios

- [ ] **Test `text`**: a text-only script → ≥2 `ekTextDelta`, exactly one
      `ekTurnFinished`, exactly one assistant message in the store. Negative: no
      `ekToolCall`.
- [ ] **Test `tool`**: a tool-call script → `ekToolCall`, then
      `ekApprovalRequest` whose `Ask.Reason` is non-empty, then `ekToolResult`
      with `Ok`, then `ekTurnFinished`; the file exists with the expected bytes.
- [ ] **Test `denied`**: answer `scApprove` with a denial → the turn reaches
      `ekTurnFinished` (does not hang) and the tool result reports the denial.
- [ ] **Test `resume`**: after `tool`, close the client, re-attach, and read the
      ledger: the same user text, tool name and result text appear.
- [ ] **Test `introspect`**: the recorded request body advertises every registered
      tool with a `reason` property in its schema.
- [ ] Implement each until green.

### Phase 5: Wiring

- [ ] **Add** `make smoke` (and `make smoke SCENARIO=<name>`, `make smoke-list`),
      building the runner with the same unit path as the suite.
- [ ] **Verify**: `make smoke` exits non-zero when a scenario fails (temporarily
      assert a falsehood and confirm).
- [ ] **Verify**: `make check` unchanged and green (the smoke is NOT in it).
- [ ] **Update** the four features whose only gap is a live check, pointing each
      at its scenario: Agent Loop (`text`), File Tools (`tool`),
      Tool Approvals (`tool`, `denied`), Headless Sessions (`resume`).

## Deviations

- (record here)

## Notes

- **Do not let this become a second unit suite.** It exists for the seams the
  unit tests inject away — real HTTP, real `exec`, real detached process, real
  socket, a store written by another process. Anything provable in a unit stays in
  a unit.
- The provider must stream with a delay; writing all frames at once would make the
  streaming path look like the buffered path and hide exactly the bug the smoke is
  for.

## Deviations

- **`resume` reads the ledger directly** rather than re-rendering through a
  client. Re-attaching after a finished turn replays nothing (the ring holds the
  *live* turn, and a finished turn is not live), so a wire assertion would have
  been vacuous. The scenario instead reopens the store and asserts the persisted
  message set — user text, tool call with its name, tool result with its success,
  exactly one user message — and then re-attaches only to prove the session is
  still joinable. That is the honest form of "live and resumed agree".
- **`introspect` reads the request body, not the response.** The advertised tool
  schema is an input, so it is asserted on what the harness *sent*.
- **The smoke pre-creates the session row.** The runtime exits with
  `unknown session: <id>` for an id it cannot find, because in production a
  client always creates it before spawning. This was the first real defect the
  harness found; it is now documented behaviour in the runner rather than a
  surprise.
- **Not in `make check`.** It forks a process, so it stays a separate `make smoke`
  target. Adding it as a third gate is a later decision, and only once it has a
  track record of not flaking.

## Found while building it (all fixed)

1. **The runtime refuses an unknown session id** — a client must create the row
   first (`EnsureWorkspace` + `CreateSession`). Nothing documented this.
2. **`HILDI_LLM_ENDPOINT` is advertised in the CLI help and never read**, and
   `SpawnDetached` passes no `--endpoint`/`--model` — so a spawned runtime cannot
   be aimed at a local provider by any supported route. Filed as a separate
   product gap; the smoke works around it by spawning with an explicit argv.
3. **An allow must name one of the ask's own options.** `TApprovalService`
   rejects a key it did not offer (correct), so a client cannot invent a grant.
4. **`poUsePipes` with nothing draining it** would fill and block the child; the
   runtime now inherits the smoke's streams so a spawn failure explains itself.
5. **`fpjson`'s `AsJSON` spaces JSON** (`"k" : "v"`), which defeats exact-substring
   assertions on frames.

## Still open

- A **pty-driven TUI scenario** would close TUI Harness's terminal sign-off. Same
  provider, same assertions, a different front end. Out of scope for v1.
- A **live model-provider** check (needs a key, so it can never be committed).
