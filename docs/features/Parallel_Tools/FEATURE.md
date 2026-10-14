# Parallel Tool Calls

## Overview

When one assistant message carries **several tool calls**, run them **concurrently**
instead of one after another — while the **approval gate stays authoritative**.
Results are returned to the model in **call order** (the pairing contract); the
tool output streams live, merged in order; and a call that is waiting on the
operator does **not** hold up a sibling that is already cleared to run.

This is not a bypass of the gate. It is the opposite: the gate becomes a step
**inside** each call's asynchronous pipeline, so approval happens concurrently
with — and independently of — the other calls' work.

## Problem Statement

`TAgentLoop.ExecuteToolCalls` runs a batch in a plain `for` loop: each call is
awaited to completion before the next starts. Two costs follow.

- **Latency is the sum, not the max.** Four `file_grep`s over a large tree take
  four times one call, though they are independent.
- **Approval serializes the whole batch.** The approval gate sits *inside* the
  tool handler (a gated tool calls `IApprovalService.Resolve` before it does its
  work). Today that runs on the single loop thread, so if call #1 needs operator
  approval and call #2 does not, #2 cannot start until #1 is approved — even
  though #2 is ready to go. The operator's thinking time blocks work that needs
  no decision.

The gate being authoritative is **not** the problem; the problem is that
"authoritative" is implemented as "one-at-a-time on one thread". A gate that is
correct under concurrency fixes both costs without weakening it.

Applying the Ponytail ladder: the concurrency substrate **already exists** — the
Async Core `TExecutorScheduler` (bounded pool, `Schedule`/`ScheduleCancellable`),
the observables (`Merge`/`Zip`), the turn already runs as a job on that executor,
and `TAgentPool` is an in-repo precedent for fan-out-then-join. The genuine gap
is narrow: a **concurrent approval gate** (many outstanding asks, one modal), a
**fan-out/join** over the batch, and an **ordered merge** of per-call output.

## Goals

- Run the tool calls of one batch **concurrently** on a bounded executor.
- Keep the **gate authoritative**: every gated call still asks, deny-first is
  preserved, and a persisted rule is visible to every other call in the batch.
- Let a call whose approval is **already resolved run while a sibling waits** on
  the operator — no head-of-line blocking.
- Present **one approval modal at a time**; a queue of asks, each answer
  releasing **only its own** call.
- Return results **in call order**; stream tool output live, **merged in order**.
- Make cancellation (turn interrupt) **fan out** to the in-flight calls.

## User Stories

- As the model, I want my independent tool calls to run at once, so a batch of
  reads does not take the sum of their times.
- As the operator, I want a gated call to wait for me **without** stalling the
  ungated calls beside it, so my decision time does not freeze the turn.
- As the operator, I still want to approve or deny **every** gated call, one
  dialog at a time, exactly as today.
- As the model, I want the results back in the order I asked, so my next request
  reads correctly.
- As the operator, I want to see output stream live as each call runs.

## Acceptance Criteria

### Functional Requirements

- [ ] The tool calls of one assistant message run **concurrently**, on a bounded
      executor (not unbounded threads).
- [ ] **The gate is never bypassed**: every gated call resolves its approval
      before running; deny-first holds; a denial fails that call, not the batch.
- [ ] A call whose approval resolves immediately (an allow rule, or a tool with
      no asks) **runs to completion while another call is still awaiting** the
      operator.
- [ ] **One modal at a time**: concurrent asks are shown in order; answering one
      releases **only** that call. (Extends today's one-modal app behaviour to
      concurrent producers.)
- [ ] **Rule visibility under concurrency**: a persisted approval from one call's
      answer is seen by the other calls' permission checks (no lost update, no
      double-prompt for a rule just granted).
- [ ] Results are appended to the conversation in **call order**, each paired to
      its `tool_call_id`.
- [ ] Tool output streams **live**, merged in call order (a chunk from call 2
      never appears before a chunk from call 1).
- [ ] A **turn interrupt** cancels the in-flight calls; each gets its paired
      cancellation result; no call is left running.
- [ ] A single-call batch and a tool that is not parallel-safe behave exactly as
      today.

### Non-Functional Requirements

- [ ] No leaks (`make test-leak`); every scheduled job is joined before the turn
      ends.
- [ ] Bounded concurrency: the executor's worker count caps simultaneous calls;
      N calls do not spawn N threads.
- [ ] Portability: macOS + Linux, FPC 3.3.1; `make check` green.
- [ ] Determinism in tests: a scripted transport + fake tools make ordering and
      concurrency assertable without timing flakiness.

## Success Metrics

- A batch of K independent reads completes in ~`max` rather than `sum` of their
  durations.
- A batch with one gated and one ungated call: the ungated call completes before
  the gated one is approved.
- `make check` stays green; no new leak.

## Constraints

- No new dependency; the Async Core executor and the observables are in-tree.
- The approval gate remains the single authority; **auto-approval modes** are a
  future layer that will sit **on top of** the gate (it feeds the same
  `IApprovalService`), never beside it. This feature must not assume any call is
  "safe to skip".
- Store access stays lock-guarded; tool handlers that touch shared state must be
  made safe for concurrent calls or declared not-parallel-safe.

## Dependencies

### Internal

- `async.concurrency` (`TExecutorScheduler`), `async.observable` (`Merge`),
  `async.future`.
- `hildegard.helper.approval` (`IApprovalService`, `TApprovalService`,
  `TApprovalAsk`) and `hildegard.helper.harness.turn` (`TApprovalGate`).
- `hildegard.helper.agent` (`TAgentLoop.ExecuteToolCalls`, `TToolHandler`,
  `IToolProvider`).
- `hildegard.helper.tool.stream` (the observer seam) and the app's ask queue.

### External

- None.

## Risks

- **Gate correctness under concurrency.** The current gate holds one pending ask;
  concurrent asks must be queued with per-ask release, and permission checks
  serialized, or two calls could double-prompt or clobber a decision. This is
  the load-bearing change and gets the most tests.
- **Thread-unsafe tools.** A handler that mutates shared state (a shared temp
  path, a non-reentrant cache) would race. Mitigation: a per-tool
  **parallel-safe** declaration; a not-parallel-safe tool runs in a serialized
  lane (still through the gate).
- **Result ordering.** Completion order ≠ call order; the join must reorder.
  Mitigation: index-tagged results, appended in index order.
- **Cancellation.** A fan-out must be cancellable per call and joined, or an
  interrupt leaks a running call.

## Out of Scope

- **Auto-approval modes** (e.g. "trust this session", allowlists by policy) — a
  future layer on top of the gate; not here.
- **Ungating any tool** — every gated call still asks (subject to the rules).
- **Parallel subagents** — delegation is already async and separate.
- **Parallelizing across turns** or across sessions.
- Reordering the model's calls or running a later round's calls early.

## Future Considerations

- Auto-approval policies feeding the same gate.
- A concurrency limit tuned per tool class (reads wide, shell narrow).
- Streaming the *set* of asks as one dialog when several gated calls are waiting.
