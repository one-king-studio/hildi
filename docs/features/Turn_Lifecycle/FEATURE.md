# Turn Lifecycle

## Overview

Make a session's turns **always reach a terminal state**, so a session can never
be left "mid-turn" — no orphaned running turns, no worker blocked on an
approval nobody can answer, no resume fed a dangling tool call.

A turn is opened (`tsRunning`) when a prompt starts and closed
(`tsCompleted` / `tsFailed` / `tsCancelled`) by the agent loop. Today, **any
path that ends the turn without the loop unwinding leaves the turn `tsRunning`
forever**, and nothing reconciles it. This feature closes that gap: reconcile on
runtime start, finalize on client loss and shutdown, and bound the approval
wait.

## Problem Statement

A live session can end up in a **non-stable state**: the turn row is
`tsRunning` with no driver, a pending approval, or a tool call recorded with no
result. The store shows it plainly — **3 sessions with orphaned `tsRunning`
turns** at the time of writing, e.g.:

```
session 8cf8…  turn seq 56  status=0 (tsRunning)  begun 08:07:08, requests=4 (all tool_calls), never finished
```

Root causes (all structural):

- **`BeginTurn` does not reconcile a prior open turn** — it just inserts a new
  `tsRunning` row. So any turn that ends without `FinishTurn` is orphaned
  permanently, and a later turn stacks on top of it.
- **A turn is only closed by the loop reaching a terminal state.** If the loop
  is abandoned mid-flight — the client disconnects, the TUI is killed, the
  runtime restarts, the worker is cancelled without unwinding — `FinishTurn`
  never runs.
- **Long-running tool calls widen the window.** `make check` (the gate) runs as
  a `run_command` for minutes; during that window the operator quits, the client
  drops, or the process is restarted, tearing the loop down *between* the tool
  call and its result (recorded `tool_ok=0`, no paired result).
- **The approval gate never times out.** `TApprovalGate.Create(FQueue)` is
  passed `FTimeoutMs = 0` (wait forever). A driver that disconnects while an
  approval is showing leaves the worker blocked indefinitely.

Consequences (the "annoying" state the operator reports): pending approvals with
no driver, failed/unresolved tool calls, a `LastTurn` that is a zombie, and a
resume that replays a history ending mid-tool-call.

## Goals

- **No orphaned running turns.** On runtime start, every `tsRunning` turn for
  the session is finalized (`tsCancelled`, reason recorded).
- **The in-flight turn is finalized on client loss and on shutdown** — not
  abandoned. Cancelling the worker and finishing the turn are one action.
- **The approval wait is bounded.** An approval that no client answers within a
  configurable window is denied, and the turn continues (or is cancelled) —
  never blocks forever.
- **`BeginTurn` is self-healing**: opening a turn finalizes any prior open turn
  for that session.
- **Resume is clean**: a history ending in a dangling tool call is repaired (the
  call is answered with a synthetic "not executed" result or dropped) so the
  model is never fed a malformed conversation.

## User Stories

- As an **operator**, I want a killed/crashed session to come back usable, not
  stuck mid-turn, so I never have to hand-edit the store.
- As an **operator**, I want quitting the TUI during a long `make check` to
  leave a cleanly cancelled turn, so the next prompt starts fresh.
- As an **operator**, I want an approval prompt that was never answered to
  resolve (deny) rather than hang the session forever.
- As a **reviewer**, I want turns to be a state machine that always terminates,
  so "running" is a transient state, not a possible resting state.

## Acceptance Criteria

### Functional Requirements

- [ ] **Startup reconcile**: when a runtime opens a session, it finalizes every
      `tsRunning` turn for that session as `tsCancelled` (reason
      `recovered_on_start`), rolling up its request/message counts. A session
      can never be opened with an open turn.
- [ ] **`BeginTurn` self-heals**: if the session already has a `tsRunning` turn,
      it is finalized (`tsCancelled`, reason `superseded`) before the new turn
      opens.
- [ ] **Finalize on client loss**: when the last driver disconnects mid-turn,
      the runtime cancels the worker (`RequestCancel`) and the turn is finalized
      (`tsCancelled`, reason `client_disconnected`).
- [ ] **Finalize on shutdown**: `scShutdown`, SIGTERM/SIGINT, and idle-exit all
      cancel the in-flight worker and finalize the turn before exiting (reason
      `shutdown`).
- [ ] **Bounded approval gate**: the gate takes a timeout; on expiry it denies
      the ask and the loop proceeds (the existing `TApprovalGate` timeout path).
      Default bounded (e.g. 300000 ms); `0` remains "never" only if explicitly
      configured.
- [ ] **Resume repair**: loading a session whose last message is a `tool_call`
      with no matching `tool` result repairs it — a synthetic tool result
      ("tool not executed: session interrupted") is appended, or the dangling
      call is dropped — so the replayed conversation is well-formed.
- [ ] The turn's terminal status is **observable** (the `ekLoopExited` /
      `turn_finished` event and the store row agree).

### Non-Functional Requirements

- [ ] Recovery is **idempotent**: running it twice changes nothing the second
      time (no already-terminal turn is touched).
- [ ] No new dependency; POSIX (macOS/Linux).
- [ ] `make check` green; leak-clean.

## Success Metrics

### Quantitative

- Zero `tsRunning` turns remain after any runtime start (target: the count of
  orphaned running turns drops from 3 to 0 and stays 0).
- A killed-mid-turn session resumes cleanly and accepts a new prompt without
  manual repair.

### Qualitative

- "Running" is a transient turn state; there is no resting state that looks
  mid-turn.

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`; reuse `TSqliteStore` turn methods,
  `TApprovalGate` (already timeout-capable), `TTurnWorker.RequestCancel`.
- POSIX.

## Dependencies

### Internal

- `hildegard.helper.store` (`BeginTurn`, `FinishTurn`, a new "finalize running
  turns" query).
- `hildegard.helper.session.runtime` (startup, client loss, shutdown).
- `hildegard.helper.harness.turn` (`TApprovalGate` timeout).
- `hildegard.helper.harness.session` (gate creation).

### External

- None.

## Risks

- **Recovering a turn that is genuinely live.** A runtime that is *actively*
  running a turn must not have it recovered by a second runtime. Mitigation: the
  socket is the liveness authority (a live socket means the runtime owns the
  session); reconcile runs only in the process that **acquired** the session
  (bound the socket), so a live turn is never stolen.
- **Recovery finalizing a turn that just finished.** Mitigation: idempotent —
  only `tsRunning` rows are touched, and finalizing is a single guarded UPDATE.
- **Changing the gate default** could surprise a long deliberate approval.
  Mitigation: the bound is generous and configurable.

## Out of Scope

- **Resuming a turn** (continuing an interrupted turn's work). Recovery *closes*
  it; the operator re-prompts.
- **Crash-safe checkpointing** of an in-flight response.
- **Multi-runtime turn ownership.**

## Future Considerations

- A `turns` "interrupted" status distinct from `tsCancelled`.
- Auto-resume of a recovered turn's pending tool calls.
- A runtime build-id vs. store check that warns when a stale runtime attaches.

## Notes

- **ICE score: Impact 8, Confidence 8, Ease 6.** The failure is systemic (3
  sessions affected), the fixes are small and local, and the payoff is that a
  session can never be left mid-turn.
- This is the third manifestation of the "the agent lives in the runtime"
  theme; here it is the *turn row* that outlives the loop that opened it.
