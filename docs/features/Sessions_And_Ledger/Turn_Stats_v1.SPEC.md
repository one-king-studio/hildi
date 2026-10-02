# Component Specification: Turn Stats v1

**Related Feature:** `FEATURE.md` (Sessions and Ledger)

## Purpose

Render the metrics the history collects - token usage, cache hit rate, duration,
and request count - in the status bar, and make the resumed view **identical** to
the live one: the same turn metrics appear in the same place, so an operator who
resumes a session picks up exactly where they left off.

The interaction hints move out of the status bar into the CTA strip above the
compose, which becomes the context toolbar.

## Requirements

### Functional

- [ ] `TSqliteStore.MostRecentTurn(const ASessionId: string;
      out ATurn: TTurnRecord; out AError: TStoreError): Boolean` returns the
      session's latest turn; `seNotFound` when there are none.
- [ ] `THarnessSession.LastTurn: TTurnRecord` returns that turn (a zero record
      when the session has no store or no turns).
- [ ] `FormatTurnStats(const ATurn: TTurnRecord): string` renders a turn's
      metrics deterministically: tokens in/out, reasoning tokens when present,
      cache hit %, duration, request count.
- [ ] `TChatPanel` gains a right-aligned stats line in the status row
      (`SetStats`), beside the existing left-aligned status (`SetStatus`).
- [ ] `THarnessApp` sets the stats from `FSession.LastTurn` on startup and after
      every turn (done or error), so live and resumed are identical.
- [ ] The status bar keeps the workspace and the state on the left; the CTA strip
      holds the hints.
- [ ] The CTA's newline hint reads `⇧+↵` (was `⇧↵`).

### Non-Functional

- [ ] Leak-clean; `MostRecentTurn` is one indexed query.
- [ ] The formatter is pure (no clock, no store), so it is identical on both
      paths by construction.
- [ ] `make check` passes.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

### Store (`hildegard.helper.store`)

```pascal
function TSqliteStore.MostRecentTurn(const ASessionId: string;
  out ATurn: TTurnRecord; out AError: TStoreError): Boolean;
```

### Harness session (`hildegard.helper.harness.session`)

```pascal
type
  THarnessSession = class
    ...
    { The latest turn, for the status bar; a zero record when there is none. }
    function LastTurn: TTurnRecord;
  end;
```

### Stats (`hildegard.helper.harness.stats`)

```pascal
{ A compact, deterministic one-line summary of a turn's metrics. }
function FormatTurnStats(const ATurn: TTurnRecord): string;
```

### Chat panel (`hildegard.helper.tui.chatpanel`)

```pascal
type
  TChatPanel = class(TWidget)
    ...
    procedure SetStatus(const AText: string);   // left: workspace + state
    procedure SetStats(const AText: string);    // right: the turn metrics
  end;
```

### Data Contracts

The status line is `FormatTurnStats(LastTurn)`, and it is the same string whether
the turn just streamed or was loaded from disk.

Format (fields separated by ` · `):

| Field | When | Example |
| --- | --- | --- |
| `<prompt> in` | always | `1.2k in` |
| `<completion> out` | always | `310 out` |
| `<reasoning> think` | reasoning tokens > 0 | `120 think` |
| `<n>% cached` | prompt tokens > 0 | `92% cached` |
| `<duration>` | always | `3.4s` |
| `<n> req` | always | `2 req` |

- Token counts are abbreviated: `< 1000` plain, else one decimal with a `k`/`M`
  suffix (`1.2k`, `3.4M`).
- Cache hit % is `round(cached / prompt * 100)`.
- Duration is `Xms` under a second, else seconds with one decimal (`8.2s`), else
  `XmYYs`.
- A zero turn (no turns yet) formats as the empty string.

## Architecture

### Prior Art & Reuse

- `TTurnRecord` (Sessions v2) already carries everything needed; the metrics are
  collected, not re-derived.
- `TTextBlock` already supports `Align := taRight`, so the stats line needs no new
  widget.
- `TChatPanel` already lays out a status row and a CTA strip.

### Component Boundaries

- **Store** answers one indexed query for the latest turn.
- **`hildegard.helper.harness.stats`** owns the format; it depends only on
  `hildegard.helper.session`.
- **`TChatPanel`** owns the two status lines and the CTA strip.
- **`THarnessApp`** composes them from the session's last turn.

### Data Flow

1. A turn streams and the loop closes it (`FinishTurn`), persisting its rollup.
2. The app drains `teDone`/`teError`, reads `FSession.LastTurn`, formats it, and
   sets the stats line.
3. On startup the app reads the same record and sets the same line.

### Integration Patterns

- The store is the single source of truth, so the live and resumed strings come
  from the same query and the same pure formatter; they cannot drift.

## Validation Rules

- A session id is required; an unknown session has no turns (`seNotFound`).
- The formatter never reads the clock or the store.

## Error Handling

- `MostRecentTurn` returns `seNotFound` when there are no turns; `LastTurn`
  returns a zero `TTurnRecord` in that case and the stats line is empty.
- A store error is swallowed by `LastTurn` (the status line is a display, not a
  control path).

## Testing Requirements

### Unit Tests

- [ ] `TestFormatTurnStatsFull` - tokens, reasoning, cache, duration, requests.
- [ ] `TestFormatTurnStatsOmitsCacheWhenNoPromptTokens`.
- [ ] `TestFormatTurnStatsAbbreviatesTokens` - 999, 1.2k, 3.4M.
- [ ] `TestFormatTurnStatsDuration` - ms, seconds, minutes.
- [ ] `TestFormatTurnStatsZeroTurnIsEmpty`.
- [ ] `TestMostRecentTurnReturnsLatest` / `TestMostRecentTurnNotFound`.
- [ ] `TestLastTurnEmptyWithoutTurns`.

### Integration Tests

- [ ] `TestStatusShowsStatsAfterATurn` - the app's status text after a live turn
      contains the token summary.
- [ ] `TestResumeStatusMatchesLive` - capture the status after a live turn,
      reopen the session, and assert the status text is identical.
- [ ] `TestCtaHoldsTheHints` - the CTA contains `⇧+↵` and the status does not.

## Performance Targets

- One indexed query per turn; no per-frame work.

## Security Considerations

- The stats are derived numbers; no content is added to the status line.

## Success Criteria

### Functional

- [ ] Contracts implemented; the status bar shows the turn metrics.
- [ ] A resumed session shows the identical line.

### Quality

- [ ] `make check` green; no leaks.

## Future Considerations

- A session-cumulative line, or a toggle between last-turn and session totals.
- Per-request breakdown, per-block durations (the design's `Thought · 8.2s`), and
  a stats view over the history.
