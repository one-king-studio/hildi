# Component Specification: Parallel Tool Calls v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.agent` (`TAgentLoop`, `TToolHandler`,
`TToolSpec`), `hildegard.helper.approval` (`IApprovalService`,
`TApprovalService`), `hildegard.helper.harness.turn` (`TApprovalGate`),
`async.concurrency` (`TExecutorScheduler`), `hildegard.helper.tui.chatpanel` +
`hildegard.helper.harness.app` (output routing), `hildegard.helper.tool.stream`
(the observer seam).

**Depended on by:** nothing (it changes an existing path).

## Purpose

Run the tool calls of one assistant message **concurrently**, without weakening
the approval gate. The gate stays the single authority; it simply becomes a step
**inside** each call's async pipeline, so approval is concurrent with — and
independent of — the other calls' work.

## Prior art and reuse

| Need | Existing | Change |
| --- | --- | --- |
| A bounded thread pool | `async.concurrency.TExecutorScheduler` (`Schedule`, `ScheduleCancellable`) | none - reuse |
| A fan-out-then-join precedent | `hildegard.helper.pool` (`TAgentPool`) | model the join on it |
| The turn already runs on the pool | `TTurnWorker` (`IAsyncScheduler`) | pass the session pool down |
| Ordered stream merge | `async.observable` (`Merge`, `Zip`) | reuse for output |
| The gate's prompt bridge | `TApprovalGate.Prompt` -> `TApprovalService` | make it concurrent |
| The app's one-modal queue | `THarnessApp.EnqueueAsk`/`ShowNextAsk` | already a queue; keep |

The gap is the **concurrent gate** and the **fan-out/join + ordered results**.

## Requirements

### Functional

- [ ] `ExecuteToolCalls` fans the batch out on the executor and joins before
      returning; the loop's `AAllOk` reflects every call.
- [ ] Each call's pipeline is unchanged in order: validate `reason`, resolve the
      tool, run the handler (which resolves approval internally), produce a
      result.
- [ ] **The gate accepts concurrent asks**: N calls may have outstanding asks at
      once; each `Ask` blocks only its own caller; answering one releases only
      that call; a timeout denies only that call.
- [ ] **Permission checks are serialized** so the pre-scan + apply of one call's
      resolution is atomic with respect to another's (a rule granted by call A is
      seen by call B, and neither double-prompts for a rule just granted).
- [ ] Results are appended in **call order**, each paired to its `tool_call_id`.
- [ ] Tool output is routed **per call** (keyed by tool id) so concurrent streams
      land in their own block; blocks appear in call order.
- [ ] A **turn interrupt** cancels every in-flight call and joins them; each gets
      a paired cancellation result.
- [ ] A tool may declare itself **not parallel-safe**; such a call runs in a
      **serialized lane** (still through the gate), never concurrently with
      another call.

### Non-Functional

- [ ] Bounded: concurrency is capped by the executor's worker count; a batch of
      N calls does not create N threads.
- [ ] No leaks; every scheduled job is joined before `ExecuteToolCalls` returns.
- [ ] Deterministic under test (scripted transport + fake tools with controllable
      gates).

## Contracts & Interfaces

> Pascal type declarations; bodies are the implementer's.

### The concurrent gate (`hildegard.helper.harness.turn`)

```pascal
type
  { A concurrent approval gate. Many calls may have outstanding asks; each Ask
    blocks only its caller until its own ask is answered or times out. Exactly
    one ask is *presented* at a time (the app shows one modal); the rest wait in
    the queue. Replaces the single-pending-ask design. }
  TApprovalGate = class
  public
    constructor Create(AQueue: TTurnQueue; ATimeoutMs: Integer = 0);
    { Worker thread (any number concurrently). Posts teApprovalAsk with a fresh
      RequestId and waits for Answer/Cancel of *that* id, or the timeout. }
    function Ask(const AAsk: TApprovalAsk): TApprovalChoice;
    { TApprovalPrompt-compatible. }
    function Prompt(const AAsk: TApprovalAsk): TApprovalChoice;
    { UI thread. Resolves the ask with ARequestId; a no-op for an unknown id. }
    procedure Answer(ARequestId: Integer; const AChoice: TApprovalChoice);
    { Deny every outstanding ask (teardown / interrupt). }
    procedure CancelAll;
  end;
```

### The serialized permission check (`hildegard.helper.approval`)

```pascal
type
  { The batch resolution must be atomic with respect to other concurrent calls:
    load -> deny-first scan -> prompt -> apply/persist is one critical section,
    so two calls cannot both prompt for, or race on, the same rule. The prompt
    itself (FPrompt) blocks on the gate *inside* the section for this call only;
    other calls' sections queue behind it, but their *tool work* does not. }
  TApprovalService = class(TInterfacedObject, IApprovalService)
  private
    FLock: TCriticalSection;
    function Resolve(const AAsks: TApprovalAskArray;
      out AResult: TApprovalBatchResult): Boolean;
  end;
```

> **Note.** The lock serializes the *decision* path, not the *work*. A call that
> resolves to `allow` (or has no asks) leaves the section immediately and runs;
> a call that must prompt holds the section while its dialog is up, so the next
> call's decision waits behind it — but a call that is already decided runs
> concurrently with that wait. This preserves the "gate is authoritative" while
> removing head-of-line blocking of *work*.

### Tool parallel-safety (`hildegard.helper.agent`)

```pascal
type
  TToolSpec = record
    Name: string;
    Description: string;
    ParametersJson: string;
    { When False, the loop runs this tool's calls in a serialized lane: never
      concurrently with any other call. Default True. }
    ParallelSafe: Boolean;
  end;
```

### The fan-out and join (`hildegard.helper.agent`)

```pascal
type
  TAgentLoop = class
  private
    { Runs the batch concurrently and joins; results in call order. }
    procedure ExecuteToolCalls(const ACalls: TChatToolCallArray;
      const AEvents: TAgentEvents; out AAllOk: Boolean);
    { The per-call pipeline, run on a pool worker. Index is the call's position
      (for ordering); the result is written to AResults[Index]. }
    procedure RunToolCall(AIndex: Integer; const ACall: TChatToolCall;
      const AEvents: TAgentEvents);
  end;
```

### Event contract (call order + per-call routing)

```pascal
type
  { Emitted for every call up front, in call order, before any runs — so the UI
    creates the tool blocks in order. }
  TToolCallEvent = procedure(const AId, AName, AArguments, AReason: string)
    of object;
  { Chunks carry the tool id, so the UI routes each to its call's block. }
  TToolOutputEvent = procedure(const AId, AName, AText: string) of object;
  { Emitted in call order after the join. }
  TToolResultEvent = procedure(const AId, AName, AResult: string;
    AOk: Boolean) of object;
```

## Architecture

### Component Boundaries

- **`TAgentLoop.ExecuteToolCalls`** owns the fan-out, the join, ordering, and the
  serialized lane. It emits the events; it does not know about the UI.
- **`TApprovalGate`** owns the ask queue and per-ask release. It does not decide;
  it presents and waits.
- **`TApprovalService`** owns the decision (match, prompt, persist) and
  serializes it.
- **The app** routes per-call output to blocks and shows one modal at a time
  (its existing ask queue already does this).

### Data Flow

1. **Emit** `OnToolCall` for each call, in order.
2. **Schedule** each call's `RunToolCall` on the executor (except not-parallel-safe
   calls, which are scheduled on a serialized lane).
3. Each `RunToolCall`: validate `reason`; resolve the tool; run the handler, which
   resolves approval (blocking on the gate if it must prompt) and streams output
   via a per-call observer that forwards `OnToolOutput(id, ...)`.
4. **Join** when every scheduled job completes (countdown latch).
5. **Append** the stored tool results in call order; emit `OnToolResult` in call
   order.

### Integration Patterns

- Concurrency via `TExecutorScheduler` (bounded). The join is a counter +
  `TSimpleEvent` (or the executor's own wait), since `All`/`ForkJoin` are the
  structurally-blocked generic family.
- The gate is `TCriticalSection`-guarded; `Ask` registers its id and waits on its
  **own** event (a per-ask event, not a single shared one).
- Cancellation: the executor's `ScheduleCancellable` per call; a turn interrupt
  trips the token and `CancelAll`s the gate.

## Validation Rules

### Input

- A call with an invalid/missing `reason` fails **that call** (as today), without
  disturbing siblings.

### Output Guarantees

- Every call in the batch yields exactly one stored tool result, in call order,
  paired by `tool_call_id`.
- `AAllOk` is False iff any call failed (invalid, unknown tool, denied, error).

## Error Handling

- A **denied** call: its result is the denial reason; siblings unaffected.
- A **timed-out** ask: denied for that call only.
- A **handler exception**: caught per call (as today); the call fails, siblings
  continue.
- A **store error** during a result append: surfaces as today; the join still
  completes.

## Testing Requirements

### Unit Tests

- [ ] `TApprovalGate`: two concurrent `Ask`s both get their own answer; answering
      #2 releases #2, not #1; a timeout denies only the timed-out ask; `CancelAll`
      denies all outstanding.
- [ ] `TApprovalService`: concurrent resolutions do not double-prompt for a rule
      one of them just granted; deny-first still short-circuits.
- [ ] `ExecuteToolCalls`: results are stored and emitted in **call order**
      regardless of completion order (a fake tool that completes out of order).
- [ ] A not-parallel-safe tool never overlaps another call (assert via a
      concurrency probe).
- [ ] Concurrency is bounded (a probe records the max simultaneous calls <= the
      executor's worker count).
- [ ] A gated call + an ungated call: the ungated one completes while the gated
      one is still awaiting approval.
- [ ] Interrupt: in-flight calls are cancelled and joined; each gets a result.
- [ ] A single-call batch is unchanged.

### Integration Tests

- [ ] Through `TAgentLoop.Send` with a scripted transport emitting a 2-call
      batch: the loop proceeds after both, in order.
- [ ] The app routes concurrent tool output to the correct block (headless
      surface).

## Performance Targets

- A batch of K independent reads completes in ~`max` (not `sum`) of their
  durations, up to the concurrency cap.
- No unbounded thread growth; the pool is shared with the turn.

## Security Considerations

- The gate is **never bypassed**: every gated call resolves approval before
  running. Auto-approval is a future layer feeding the same service.
- A per-call temp path or shared resource must be safe; the parallel-safe flag
  keeps unsafe tools serialized.

## Success Criteria

- [ ] All contracts implemented; `make check` green; no leaks.
- [ ] A gated call no longer blocks an ungated sibling's work.
- [ ] Results and blocks are in call order; output streams live per block.
- [ ] The gate remains authoritative (every gated call asks).

## Future Considerations

- Auto-approval policies on top of the gate.
- Per-class concurrency limits.
- A single combined approval dialog for several waiting gated calls.
