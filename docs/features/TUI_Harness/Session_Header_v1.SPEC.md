# Component Specification: Session Header v1

**Related Feature:** `FEATURE.md` (TUI Harness)
**Builds on:** `Chat_Panel_v1.SPEC.md`, `Turn_Stats_v2.SPEC.md`

## Purpose

Put the session identity and the **context usage** on the messages panel's
**top border**: the session id at the left, the context (tokens, bar,
percentage) at the right. The operator can then see, at a glance, which session
they are in and how close the context is to its limit. The session's
**consumption** (billed in/out, cache hit, time, requests) stays on the status
bar's right, beside the workspace.

Cost is deliberately omitted: it will be tracked per turn, alongside the
provider and model that produced it, as future work.

## Requirements

### Functional

Panel border titles

- [ ] `TBoxStyle` gains `TitleRight: string`. `TPanel` renders it right-aligned
      on the top border, mirroring `Title` (left-aligned); the middle stays
      dashes. A right title is drawn only when it does not collide with the
      left one.
- [ ] `TChatPanel.SetHeader(const ALeft, ARight: string)` sets the messages
      panel's left/right border titles and invalidates.

The header content

- [ ] `FormatContextUsage(ATokens, ALimit: Integer): string` renders
      `<count> [<shades>] <pct>%`: the final context, a ten-cell shades bar
      (`▓` per 10%, `▒` for a >=5% remainder, `░` background), and the
      percentage. With no limit (`<= 0`), just `<count>`.
- [ ] `FormatSessionStats(const ATurn: TTurnRecord): string` renders
      `<in> in · <out> out · <cached>% cached · <time> · <req> req`, or `''`
      for a session with no requests — the consumption, shown on the status
      bar. `in`/`out` are the billed sums over every request; the cache hit is
      Σcached/Σprompt.
- [ ] `THarnessApp` sets the header on startup and after every turn: the left
      is the session id's first 12 hex characters, the right is
      `FormatContextUsage(FSession.SessionTotals.ContextTokens,
      FSession.MaxContextTokens)`.
- [ ] The status bar keeps the workspace on the left and carries the
      consumption on the right.

### Non-Functional

- [ ] `FormatContextUsage` / `FormatSessionHeader` are pure (no clock, no
      store).
- [ ] The header is set once per turn, never per frame; leak-clean; `make check`
      passes.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

### Panel (`hildi.tui.panel`)

```pascal
TBoxStyle = record
  Border: Boolean;
  Rounded: Boolean;
  Title: string;        // left-aligned on the top border
  TitleRight: string;   // right-aligned on the top border (new)
  Padding: Integer;
end;
```

### Chat panel (`hildi.tui.chatpanel`)

```pascal
procedure TChatPanel.SetHeader(const ALeft, ARight: string);
```

### Stats (`hildi.harness.stats`)

```pascal
function FormatContextUsage(ATokens, ALimit: Integer): string;
function FormatSessionStats(const ATurn: TTurnRecord): string;
```

### Data Contracts

Header line (rounded border, width `W`):

```
╭ <id> ───────────────────── <context> ─╮
```

- `id` = the session id's first 12 hex characters.
- `<context>` = `121k [▓░░░░░░░░░] 12%`: the final context (`FormatTokens`), a
  ten-cell shades bar (`▓` per full tenth, `▒` for a remainder of 5% or more,
  `░` for the background), and the percentage. With no limit, just `121k`.

Status bar (the workspace on the left, the consumption on the right):

```
 <workspace>       <in> in · <out> out · <cached>% cached · <time> · <req> req
```

- `<in>`/`<out>` = `FormatTokens` of the billed prompt/completion sums over
  every request.
- `<cached>` = `round(Σcached * 100 / Σprompt)`; omitted with no prompt.
- `<time>` = `FormatDurationMs(duration)`; `<req>` = the request count.
- Empty when the session has no requests.

## Architecture

### Prior Art & Reuse

- `TPanel` already draws a title on the top border; the right title is its
  mirror.
- `FormatTokens` / `FormatDurationMs` (Turn Stats v2) already format the
  numbers; the session aggregate already carries the context and the
  consumption sums.
- `Session.MaxContextTokens` (Turn Stats v2) is the limit the bar is measured
  against.

### Component Boundaries

- **`tui.panel`** owns the two border titles.
- **`tui.chatpanel`** exposes the header seam on the messages panel.
- **`harness.stats`** owns the format; it depends only on `hildi.session`.
- **`harness.app`** composes the header from the session.

### Data Flow

1. A turn streams and closes; the session's rollups update.
2. The app reads `SessionTotals` and `MaxContextTokens`, formats the header, and
   sets it.
3. On startup it sets the same header from the same query.

## Validation Rules

- The formatters never read the clock or the store.
- A zero session formats as the empty string; a zero limit omits the percentage
  and the bar.

## Error Handling

- A store error is swallowed (the header is a display); the header falls back to
  the id alone.

## Testing Requirements

### Unit Tests

- [ ] `TestPanelDrawsLeftAndRightTitle` - both titles on the top border, dashes
      between.
- [ ] `TestPanelSkipsRightTitleWhenTooNarrow` - the right title is not drawn
      over the left.
- [ ] `TestFormatContextUsage` - count, bar, percent.
- [ ] `TestFormatContextUsageNoLimit` - count only.
- [ ] `TestFormatSessionStats` - in, out, cached, time, requests.
- [ ] `TestFormatSessionStatsEmpty` - no requests, empty string.

### Integration Tests

- [ ] `TestHeaderShowsSessionIdAndContext` - the header carries the id prefix
      and the context, and not the consumption.
- [ ] `TestStatusShowsWorkspaceAndConsumption` - the workspace on the left and
      the consumption on the right.
- [ ] `TestStatusSumsTurns` - the consumption sums both turns.
- [ ] `TestResumeHeaderMatchesLive` - a resumed header matches the live one.

## Performance Targets

- One aggregate query per turn (the existing `SessionTotals`); no per-frame
  work.

## Security Considerations

- The header shows derived numbers and the public session id; no content.

## Success Criteria

### Functional

- [ ] The top border carries the id (left) and the context (right).
- [ ] The status bar carries the workspace and the session's consumption.

### Quality

- [ ] `make check` green; no leaks.

## Future Considerations

- Per-turn cost, provider, and model (a price source), shown in the header or a
  stats view.
- A warning colour as the context nears its limit.
- A new job for the status bar.
