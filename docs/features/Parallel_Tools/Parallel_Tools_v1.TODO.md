# Implementation Plan: Parallel Tool Calls v1

**Related Specification:** `Parallel_Tools_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Fan a batch of tool calls out on the Async Core executor and join, with the
approval gate made **concurrent but still authoritative**. Results in call order;
output streamed live, per call. TDD-first; `make check` before moving on.
`main` only.

## Implementation Tasks

### Phase 1: The concurrent gate (`hildegard.helper.harness.turn`)

- [x] **Test**: two concurrent `Ask`s both receive their own answer; answering #2
      releases #2 and leaves #1 waiting (`test_harness_turn`).
- [x] **Implement**: replace the single pending ask with a per-ask registry
      (id -> event + choice); `Ask` registers, posts, waits on its own event.
- [x] **Test**: a timeout denies only the timed-out ask; `CancelAll` denies every
      outstanding ask.
- [x] **Implement**: `CancelAll`; per-ask timeout.
- [x] **Test**: `Answer` for an unknown id is a no-op (late/duplicate answer).

### Phase 2: Serialize the permission decision (`hildegard.helper.approval`)

- [x] **Test**: two concurrent `Resolve`s do not double-prompt for a rule one
      just granted; deny-first still short-circuits (`test_approval`).
- [x] **Implement**: a lock around the load -> scan -> prompt -> apply section.

> **Note (deviation):** the *prompt* is serialized by a second lock
> (`FPromptLock`) but the *decision snapshot* by `FDecisionLock`; the
> already-allowed fast path never touches `FPromptLock`, so a cleared call is not
> blocked behind a prompting sibling. The persist+publish of a grant is atomic
> under `FDecisionLock`. See `a094053`.

### Phase 3: Fan-out and join (`hildegard.helper.agent`)

- [x] **Test**: `ExecuteToolCalls` stores and emits results in **call order**
      when calls complete out of order (a fake tool with a controllable delay).
- [x] **Implement**: schedule each `RunToolCall` on an injected executor; join
      with a countdown latch; append in index order.
- [x] **Test**: a batch of K calls runs with bounded concurrency (a probe records
      the max simultaneous calls <= the worker count).
- [x] **Implement**: the executor is injected (default: a small pool); bounded.
- [x] **Test**: a not-parallel-safe tool never overlaps another call.
- [x] **Implement**: `TToolSpec.ParallelSafe`; a serialized lane for it.
- [x] **Test**: a gated call + an ungated call - the ungated completes while the
      gated is still awaiting approval.
- [x] **Implement**: the per-call pipeline resolves approval inside the handler,
      so the wait is per-call.

> **Deviations (Phase 3):**
> - `TToolSpec.ParallelSafe` defaults **False** (opt-in), not True as the SPEC
>   proposed: an unmarked tool must never run concurrently, so adding
>   parallelism cannot silently race an unsafe handler.
> - **Runs, not the whole batch.** Only *consecutive* parallel-safe calls fan
>   out; a mixed batch runs in order, parallelizing the safe stretches. This
>   preserves **execution order** (a `[write, read]` batch must not reorder),
>   which the SPEC left implicit.
> - **A separate tool pool.** The turn runs on the turn pool, so tool jobs use a
>   distinct `FToolPool` (4 workers); sharing the turn pool would serialize or
>   deadlock at low concurrency.

### Phase 4: Output routing and cancellation

- [ ] **Test**: concurrent tool output is routed per call (keyed by tool id) and
      the blocks appear in call order (headless surface).
- [ ] **Implement**: `OnToolOutput` carries the id; the app/panel routes per id.
- [ ] **Test**: an interrupt cancels and joins every in-flight call; each gets a
      paired result.
- [ ] **Implement**: `ScheduleCancellable` per call; trip the token on interrupt;
      `CancelAll` the gate.

### Phase 5: Validation & docs

- [ ] **Run**: `make test SUITE=TAgentLoopTest,TApprovalTest,THarnessTurnTest,THarnessAppTest`
- [ ] **Run**: `make check` (all gates)
- [ ] **Update the SPEC** if behaviour diverged; rename this TODO to
      `Parallel_Tools_v1.DONE.md`; add the row to `FEATURES.md`.

## Files to Create/Modify

### New Files

```
docs/features/Parallel_Tools/FEATURE.md
docs/features/Parallel_Tools/Parallel_Tools_v1.SPEC.md
docs/features/Parallel_Tools/Parallel_Tools_v1.TODO.md
```

### Modified Files

```
src/hildegard.helper.harness.turn.pas   (concurrent TApprovalGate)
src/hildegard.helper.approval.pas        (serialize the decision section)
src/hildegard.helper.agent.pas           (fan-out/join, ParallelSafe, ordered results)
src/hildegard.helper.harness.session.pas (inject the executor into the loop)
src/hildegard.helper.harness.app.pas     (per-call output routing)
tests/test_harness_turn.pas              (the concurrent gate)
tests/test_approval.pas                  (serialized resolution)
tests/test_agent.pas                     (ordering, concurrency, lanes)
tests/test_harness_app.pas               (output routing)
```

## Dependencies & Ordering

### Must Complete Before Starting

- Nothing external; the executor and observables exist.

### Can Be Done in Parallel

- Phase 1 (gate) and Phase 3 (fan-out) are independent until Phase 3 needs the
  concurrent gate to actually overlap approvals.

### Critical Path

1 (gate) -> 2 (serialize decision) -> 3 (fan-out/join) -> 4 (routing/cancel) -> 5.

## Success Criteria

- [ ] All tasks checked
- [ ] Every SPEC acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] A gated call no longer blocks an ungated sibling's work
- [ ] Results and blocks are in call order; the gate remains authoritative

## Notes & Considerations

- **The gate is authoritative.** This feature never skips a gated call's ask;
  auto-approval modes will sit on top of the gate later.
- **The lock serializes the decision, not the work.** A decided call runs
  concurrently with another call's wait.
- **`All`/`ForkJoin` are blocked** (nested generics) - the join is a countdown
  latch, as `TAgentPool` does.
- **Call order, not completion order.** Index-tag every result.
- Record deviations from the SPEC here.
