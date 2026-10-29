# Component Specification: Turn Stats v2

**Related Feature:** `FEATURE.md` (Sessions and Ledger)
**Builds on:** `Turn_Stats_v1.SPEC.md` (the per-turn status line)

## Purpose

Three follow-ups the v1 status line left open, so an operator can see the cost of
a session, the cost of each loop, and how long the model spent thinking:

1. **The status bar shows the session's usage for cost.** Prefixed `total `, it
   shows the final context (the window in play), the billed total (every
   request's prompt plus its completion), the token-weighted cache hit, the wall
   time, and the request count. The context is the final one, not a sum of the
   re-sent prompts; the billed total is a sum, because every request is billed
   for its whole prompt.
2. **Each successful loop ends with a divider.** A dimmed thin rule with that
   loop's metrics right-aligned and a single trailing rule, so the transcript
   reads as a sequence of loops with their cost.
3. **Per-block durations are collected.** The loop times the reasoning and
   content phases of every response and persists them, so a thought block can
   read `Thought for 2.3s` (live and on resume, from the same value).

The live and resumed views stay identical by construction: every displayed
number comes from the same persisted record, or from the same measured value
that was persisted.

## Requirements

### Functional

Cumulative status

- [ ] `TSqliteStore.SessionTotals(const ASessionId: string;
      out ATurn: TTurnRecord; out AError: TStoreError): Boolean` returns one
      row: the **billed sums** (prompt, completion, cached, reasoning over every
      request), the **final context** (`MAX(prompt_tokens)`) in `ContextTokens`,
      `Usage.TotalTokens` (prompt + completion), the summed turn durations and
      request count, and `Id = 1` when the session has requests (0 when none).
      One query.
- [ ] `THarnessSession.SessionTotals: TTurnRecord` returns that record (a zero
      record when there is no store).
- [ ] `FormatSessionStats(const ATurn: TTurnRecord): string` renders
      `total <context> ctx · <used> used · <cache%> cached · <duration> ·
      <req> req`, or `''` for a session with no requests. `<used>` is prompt +
      completion; the cache hit is Σcached/Σprompt (token-weighted, the
      cost-relevant rate).
- [ ] `FormatDurationMs` extends to hours (`1h30m`), so a long session reads
      sensibly.
- [ ] `THarnessApp` sets the status stats from `FSession.SessionTotals` on
      startup and after every turn.

Context guard

- [ ] `THarnessSessionConfig.MaxContextTokens` (0 => the
      `HILDI_MAX_CONTEXT_TOKENS` env var, else the agent default) overrides
      the loop's context guard. The limit is a model property the app does not
      know yet; this is the stopgap until it is pulled from the model API.
- [ ] `THarnessSession.MaxContextTokens` exposes the resolved value.

Per-loop divider

- [ ] `TChatKind` gains `ckTurn`: a one-row, dimmed rule with its body text
      right-aligned and a single trailing `─`, e.g.
      ` ──────────────────── 1.2k in · 310 out · 3.4s · 2 req ─`.
- [ ] `THarnessApp` appends a `ckTurn` block after a **successful** loop
      (`teDone`), carrying `FormatTurnStats(FSession.LastTurn)`; a failed or
      cancelled loop gets none.
- [ ] `RenderHistory` appends the same divider after each **completed** turn
      (`tsCompleted`) when restoring, so a resumed transcript matches the live
      one.

Per-block durations

- [ ] The agent loop times each response's reasoning phase (first reasoning
      delta → first content delta, or the end when there is no content) and
      content phase (first content delta → the request's end).
- [ ] `IConversationStore.AppendReasoning` gains an `ADurationMs`; the reasoning
      row records the reasoning duration, and the assistant message records the
      content duration.
- [ ] The loop reports the reasoning duration to the UI as it ends, so the live
      thought block shows it. `TTurnEventKind` gains `teReasoningDone`
      (`ElapsedMs`); the runtime carries it as the `reasoning_done` session
      event; the remote driver maps it back.
- [ ] `FormatThoughtLabel(ADurationMs: Int64): string` renders `Thought` when
      there is no duration, else `Thought for <duration>`; the app uses it live
      (at finalize) and on resume (from the record).

### Non-Functional

- [ ] `SessionTotals` is one indexed aggregate query; the status line is still
      set once per turn, never per frame.
- [ ] `FormatSessionStats`, `FormatTurnStats` and `FormatThoughtLabel` are pure
      (no clock, no store).
- [ ] Leak-clean; `make check` passes.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

### Store (`hildi.store`)

```pascal
{ The session's billed sums (prompt/completion/cached/reasoning), the final
  context, and the totals; Id = 1 when there are requests (0 when none). }
function TSqliteStore.SessionTotals(const ASessionId: string;
  out ATurn: TTurnRecord; out AError: TStoreError): Boolean;
```

### Harness session (`hildi.harness.session`)

```pascal
function THarnessSession.SessionTotals: TTurnRecord;   // cumulative
function THarnessSession.Turns: TTurnRecordArray;      // ordered, for restore
```

### Stats (`hildi.harness.stats`)

```pascal
function FormatTurnStats(const ATurn: TTurnRecord): string;      // v1
function FormatSessionStats(const ATurn: TTurnRecord): string;   // 'total …'
function FormatThoughtLabel(ADurationMs: Int64): string;         // 'Thought …'
function FormatDurationMs(AMs: Int64): string;                   // '3.4s'
```

### Conversation store (`hildi.agent`)

```pascal
procedure IConversationStore.AppendReasoning(const AText: string;
  ADurationMs: Int64);
```

### Turn events (`hildi.harness.turn`)

```pascal
TTurnEventKind = (..., teReasoningDone, ...);   // ElapsedMs = reasoning ms
```

### Session protocol (`hildi.session.protocol`)

```pascal
TSessionEventKind = (..., ekReasoningDone, ...);   // wire: 'reasoning_done'
// carries elapsed_ms
```

### Chat stream (`hildi.tui.chat`)

```pascal
TChatKind = (ckUser, ckAssistant, ckError, ckThought, ckTool, ckThinking, ckTurn);
```

### Data Contracts

Divider (width `W`, stats width `S`):

```
 ─────────────────────────── <stats> ─
```

- `FormatSessionStats` = `total <context> ctx · <used> used · <cache%> cached ·
  <duration> · <req> req`, empty for a session with no requests. `<context>` is
  the largest prompt the session sent; `<used>` is Σprompt + Σcompletion; the
  cache hit is Σcached/Σprompt.
- `FormatThoughtLabel(0)` = `Thought`; else `Thought for ` + `FormatDurationMs`.
- Only `tsCompleted` turns get a divider; the divider's text is exactly
  `FormatTurnStats(turn)`.

## Architecture

### Prior Art & Reuse

- `TTurnRecord` already carries the rollup; `FormatTurnStats` already renders it.
- The turn metrics are already persisted (`turns`), so the cumulative line is a
  `SUM` over the same table.
- `TChatItem` already renders a one-row dimmed rule for a collapsed thought/tool
  block; `ckTurn` is the same shape with the rule split around right-aligned
  text.
- `TTurnWorker`/`TSessionRuntime` already translate loop callbacks into events;
  `teReasoningDone` follows the existing `teToolResult` path.

### Component Boundaries

- **Store** answers the aggregate and the turn list.
- **`harness.stats`** owns every format; it depends only on `hildi.session`.
- **`tui.chat`** owns the divider block.
- **`harness.app`** composes the status, the divider and the thought label.
- **`agent`** owns the timing; **`harness.turn`**/**`session.runtime`** carry it.

### Data Flow

1. The client streams; the loop timestamps the first reasoning delta, the first
   content delta, and the request end.
2. The loop persists the reasoning and content durations and reports the
   reasoning duration on `teReasoningDone` as the content starts.
3. The app finalizes the thought block with `FormatThoughtLabel(duration)`.
4. On a successful stop, the loop's turn is rolled up; the app appends the
   `ckTurn` divider from `LastTurn` and refreshes the status from `SessionTotals`.
5. On restore, `RenderHistory` reads the same records and turns, and draws the
   same labels and dividers.

### Integration Patterns

- The store is the single source of truth for the status and the dividers; the
  reasoning duration is measured once and both persisted and streamed, so the
  live label and the resumed label are the same number.

## Validation Rules

- A session id is required; a session with no requests yields `Id = 0`.
- The formatters never read the clock or the store.
- A zero-duration thought shows `Thought`; a zero session shows no status text.

## Error Handling

- `SessionTotals` returns a zero record (and `Turns` an empty array) for an
  unknown or request-less session; the harness passes that through and the UI
  draws nothing.
- A store error is swallowed (the display is not a control path).

## Testing Requirements

### Unit Tests

- [ ] `TestFormatSessionStatsPrefixesTotal` / `TestFormatSessionStatsEmpty`.
- [ ] `TestFormatThoughtLabel` (zero, ms, seconds).
- [ ] `TestSessionTotalsContextAndGenerated` / `TestSessionTotalsEmpty`.
- [ ] `TestMaxContextTokensFromConfig`.
- [ ] `TestDividerRendersStatsRightAligned` (a `ckTurn` block).
- [ ] `TestReasoningDoneRoundTrip` (the protocol event).
- [ ] `TestLoopRecordsReasoningDuration` / `TestLoopRecordsContentDuration`
      (the loop persists both; a delayed fake makes them non-zero).

### Integration Tests

- [ ] `TestStatusShowsSessionTotals` - after two turns the status contains the
      final context, the billed `used` total and `total `.
- [ ] `TestTurnDividerAfterSuccessfulTurn` - a completed turn ends with a
      `ckTurn` block carrying the loop's stats.
- [ ] `TestNoDividerAfterFailedTurn` - a failed turn ends with no `ckTurn`.
- [ ] `TestResumeRendersTurnDividers` - a resumed transcript has the same
      dividers as the live one.
- [ ] `TestThoughtShowsDuration` - a thought with a delayed reasoning stream is
      labelled `Thought for …`, live and on resume identically.

## Performance Targets

- One aggregate query per turn for the status; no per-frame work.

## Security Considerations

- The stats are derived numbers; no content is added to the status or divider.

## Success Criteria

### Functional

- [ ] The status bar shows cumulative session totals, prefixed `total `.
- [ ] Each successful loop ends with a divider of its metrics.
- [ ] Thought blocks show their duration; a resumed view matches the live one.

### Quality

- [ ] `make check` green; no leaks.

## Future Considerations

- A toggle between last-turn and session totals.
- A full stats view over the history (per-request breakdown, token spend).
- Folding the assistant's duration into the divider once a turn-level rollup of
  block durations exists.
