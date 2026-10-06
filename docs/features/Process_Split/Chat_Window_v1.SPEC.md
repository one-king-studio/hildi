# Component Specification: Chat Window

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

Bound the TUI's chat memory. Today `TChatStack` holds every block in the session
(`FItems: array of TChatItem`) and every block keeps its laid-out body — a
`TTextBlock` or `TMarkdownView` with wrapped rows and spans. A live session of
713 blocks costs a 56.6 MB footprint, almost all of it rendering structure and
allocator overhead rather than text (~720 KB). This component keeps every
block's *data* and *height*, but materializes the rendered layout only for the
visible window.

## Requirements

### Functional

- [ ] The chat stack retains only the visible range's rendered layouts (plus a
      small overscan); off-screen blocks keep their data and height, not their
      layout.
- [ ] The scroll extent stays exact: a block's height is memoized per width and
      is not lost when its layout is released.
- [ ] The live (streaming) tail block is always materialized.
- [ ] Adding a block, streaming into the tail, toggling expansion, removing the
      thinking indicator, and resizing all behave as today.
- [ ] Scrolling to any position renders the same cells as the un-windowed list.

### Non-Functional

- [ ] Steady-state retained layout is O(viewport), independent of block count.
- [ ] No change to the rendered output; existing chat/layout tests pass.
- [ ] Leak-clean; `make check` passes.
- [ ] Portability: macOS and Linux, FPC 3.3.1.

## Contracts & Interfaces

### `TChatItem` — a layout-materialization seam

```pascal
type
  TChatItem = class(TWidget)
  public
    { Build the rendered body (spans or markdown) from FBody. Idempotent. }
    procedure Materialize;
    { Free the rendered body, keeping FBody and the memoized height. }
    procedure Dematerialize;
    function Materialized: Boolean;
    // ... existing surface unchanged
  end;
```

`Materialize` is what `Rebuild` does today. `Dematerialize` frees `FText` (and
its spans) or `FMarkdown`, and must not invalidate `FHeight`/`FHeightValid`: the
memoized height is the scroll math's only source and must survive a release.

### `TChatStack` — a window over the blocks

```pascal
type
  TChatStack = class(TWidget)
  private
    { Every block is retained; only the visible window's rendered layout is.
      A block's height is memoized on the item itself. }
    FItems: array of TChatItem;
    // ...
  public
    // existing API unchanged: Add, Remove, ItemAt, Count, Clear,
    // Measure, Arrange, Render, HandleEvent, Advance
    { How many blocks currently hold a rendered layout. Diagnostic. }
    function MaterializedCount: Integer;
  end;
```

`Render` computes the visible index range from the offset arrays and the clip,
materializes that range plus `WindowOverscan` blocks on each side, and
dematerializes the rest. `Measure` builds a block's body only when its height
must be recomputed, then releases it again unless it was already held — so a
layout pass measures every block without retaining every block's layout. The
overscan keeps a block that just left the viewport (a short scroll) from
rebuilding.

`ItemAt` returns the retained `TChatItem` (materialized or not); `Text` reads
the body without needing the layout, so `THarnessApp` needs no change beyond the
constructor taking a `TSessionView`.

### `TChatStream` / `TChatPanel`

The public surface is unchanged: `Add`, `Remove`, `Last`, `ItemAt`, `Count`,
`FollowBottom`, and the `OnToggle`/`OnChange` callbacks. `TChatPanel` and
`THarnessApp` need no change beyond the constructor taking a `TSessionView`.

## Architecture

### Prior Art & Reuse

The measurement and rendering are reused unchanged: `TChatItem.Measure` already
memoizes per width, `TChatStack.EnsureLayout` already computes the offset array,
and `TChatStack.Render` already draws only the visible blocks. The gap is that
every block keeps its *layout*; this component adds release/materialize and a
windowed item set around the existing logic.

### Component Boundaries

- **Responsibilities:** `TChatItem` owns one block's data and (when
  materialized) its layout; `TChatStack` owns the block list, the height memo,
  and the window; `TChatStream` owns scroll-follow.
- **Dependencies:** unchanged TUI units.
- **Side effects:** none beyond freeing and rebuilding layouts.

### Data Flow

1. **Add:** append a `TChatItem`; its height is unknown until measured and its
   rendered body is not built.
2. **Layout:** `EnsureLayout` computes offsets; a block with a memoized height
   for the current width contributes it without a layout; a block without one is
   materialized to measure, its height stored, and released again.
3. **Render:** compute the visible index range from the offsets and the clip,
   materialize those items plus an overscan, arrange their bodies, render them,
   and dematerialize items that left the window.
4. **Change:** streaming into the tail updates its body and invalidates its
   height; the tail stays materialized because it is in the window.

### Integration Patterns

- Single-threaded on the UI thread, as today; no new threading.
- A width change invalidates every height and forces a measure pass; the pass
  may transiently materialize blocks to measure them. Steady-state retention
  stays O(viewport).

## Validation Rules

### Input

- `ItemAt(AIndex)` outside `[0, Count)` returns `nil`, as today.
- `Dematerialize` on an unmaterialized item is a no-op.

### Output Guarantees

- `Measure` returns the same total as the un-windowed list for the same blocks
  and width.
- A released-then-materialized item renders identically.

## Error Handling

- **Width change:** heights recompute; no stale offset is used for a new width.
- **Streaming tail removed:** the window shrinks; the next `Last` is the new
  tail.

## Testing Requirements

### Unit Tests

- [ ] `TChatItem.Materialize`/`Dematerialize`: the height survives a release; a
      released item renders the same as before.
- [ ] `TChatStack`: as blocks grow, the number of materialized items stays
      bounded (a diagnostic count), while `Measure` still returns the exact
      extent.
- [ ] `TChatStack`: scrolling to the top, middle, and bottom renders the correct
      blocks (compare against the un-windowed rendering).
- [ ] `TChatStack`: toggling a block's expansion re-measures it and shifts the
      offsets correctly.
- [ ] `TChatStack`: a live tail that grows stays materialized and re-measures.
- [ ] `TChatStream`/`TChatPanel`: existing behaviour (follow bottom, thinking
      indicator removal) unchanged.

### Integration Tests

- [ ] `THarnessApp` renders a large history without materializing every block
      (a diagnostic assertion), and the rendered surface matches the current
      implementation.

## Performance Targets

- TUI footprint on a large transcript is materially below the 56.6 MB baseline
  and does not grow with block count.
- No regression in the existing layout/animation budgets (`make perf`).

## Security Considerations

- None; this is a rendering change with no new input.

## Success Criteria

### Functional

- [ ] All contracts implemented; existing chat/layout tests pass.
- [ ] `make check` passes, leak-clean.

### Quality

- [ ] The retained-layout count is bounded and asserted by a test.
- [ ] Measured footprint improvement recorded in the DONE record.

## Future Considerations

- A store-backed source, so history is paged in rather than held in memory.
- A per-block height cache that survives a width change by scaling, avoiding the
  re-measure pass.
