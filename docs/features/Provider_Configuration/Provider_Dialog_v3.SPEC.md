# Component Specification: Provider Dialog v3

**Related Feature:** [FEATURE.md](FEATURE.md) — Stage 3.
**Depends on:** Stage 2 (`providers` table), Stage 4 (`ListModels` / `THTTPModelFetch`).

## Purpose

A `/provider` command that lists configured providers, selects the active one, and
edits a provider's connection settings — without hand-writing SQL into the store.

## The shape the existing code dictates

Three facts, read from `main` rather than assumed, determine the design:

1. **The slash-command pattern is three parts**, all in `HildiHarnessApp.pas`:
   `DefaultCommands` registers, `ComposeChanged` opens the palette on a lone
   `/token`, and `PaletteRun` → `RunCommand` dispatches by name.
2. **Order inside `RunCommand` is load-bearing.** Commands that read the store
   (`/sessions`, `/new`) sit *before* the `FConnState <> csConnected` guard;
   commands needing a live driver (`/mcp`, `/skill`, `/undo`) sit *after* it.
3. **Modal hosts defer their close.** `TSkillModal`'s host uses
   `FModal` + `FCloseModal` + `SyncXModal`, because the widget sets the close flag
   from inside `HandleEvent` and the `PopPlane` must happen on a later frame.

**Therefore `/provider` needs no driver at all.** It reads and writes the
`providers` table the TUI already owns: no `teProvider*` events, no protocol
change, no runtime round-trip. It belongs in the **first** group with `/sessions`,
and works while connecting.

## Requirements

### Functional

- [ ] `/provider` opens a dialog listing every stored provider, marking the active one.
- [ ] **`/provider` does NOT switch providers.** It lists, configures and manages.
      Switching is `/model`, which chooses a provider+model pair. A list view that
      silently changed what a session talks to would be the wrong affordance.
- [ ] The dialog shows the provider's endpoint, model and non-default parameters.
- [ ] Deleting the active provider is allowed (board decision: it leaves no active row).
- [ ] The dialog works with no runtime attached.
- [ ] The active provider is shown as a fact (a marker), never as a control.
- [ ] A provider whose `Key` is not a registered adapter is shown as unusable,
      not hidden.

### Non-Functional

- [ ] No new dependency; `TModal` already exists.
- [ ] The dialog reads the store once on open, not per frame.
- [ ] The API key is never rendered.

## Contracts & Interfaces

```pascal
type
  { One row as the dialog needs it: the store row plus the facts the UI must
    show. Built by a PURE function so it is testable without a dialog. }
  TProviderListItem = record
    Name: string;          // the operator's label
    Key: string;           // the provider slug
    Endpoint: string;
    Model: string;
    Active: Boolean;
    { False when Key names no registered adapter. The row is still SHOWN: a
      provider that cannot resolve is a fact the operator must see and fix, not
      one to hide. }
    Usable: Boolean;
    { A short human line: "openrouter · openai/gpt-4o · temp 0.3" }
    Summary: string;
  end;

  TProviderListItemArray = array of TProviderListItem;

{ Pure: rows + a resolver function -> display items. No store, no dialog. }
function ProviderListItems(const ARows: TProviderRowArray;
  AHasAdapter: TProviderHasAdapter): TProviderListItemArray;
```

The dialog itself is a `TModal` descendant following `TSkillModal`'s host shape.

## Architecture

### Prior Art & Reuse

- **`TSkillModal` + `SyncSkillModal`** (`HildiHarnessApp.pas`) — the host shape to copy verbatim, including the deferred close.
- **`TMcpModal`** (`HildiMcpModal.pas`) — a `TModal` list dialog landed by the MCP lane; the closest single-purpose precedent. Its `/mcp` command is **not** wired (board #126), so copy the *widget*, not a command arm.
- **`ProviderByKey`** (`LLMProvider.pas`) — resolves a slug to an adapter, so "usable" is a fact, not a guess.
- **`SaveProvider` / `ListProviders` / `SetActiveProvider` / `DeleteProvider`** (Stage 2) — the whole store surface already exists and is tested.
- **`ListModels` + `THTTPModelFetch`** (Stage 4) — model discovery, for the edit form.

### Component Boundaries

- `src/HildiProviderDialog.pas` — the widget and the pure `ProviderListItems`.
- `src/HildiHarnessApp.pas` — registration, the `/provider` arm, the host.
- No change to the runtime, the protocol, or `src/llm/`.

## Validation Rules

- A provider row with an empty `Name` is skipped (the store already refuses it).
- A row whose `Key` is empty is shown as unusable with the reason stated — it
  means the row predates the Name/Key split or was written by hand.
- Editing an endpoint to something that is not an absolute URL is refused in the
  dialog, with the reason shown, before it reaches the store.

## Error Handling

- A store failure opening the dialog is surfaced as an error block, not an empty
  list — an empty list means "no providers", which is a different fact.
- Selecting a provider that fails to activate leaves the previous one active
  (`SetActiveProvider` already rolls back on an unknown name).

## Testing Requirements

### Unit Tests

- [ ] `TestProviderListItemsSummarisesEachRow` — the summary names endpoint, model and parameters.
- [ ] `TestAProviderWithNoAdapterIsShownUnusable` — not hidden.
- [ ] `TestTheActiveProviderIsMarked`.
- [ ] `TestAnEmptyStoreGivesNoItems` — and the dialog says "no providers", not blank.
- [ ] `TestASecretNeverAppearsInASummary`.

### Integration Tests

- [ ] `/provider` reaches the dialog with no runtime attached.

## Success Criteria

- [ ] `/provider` is in `RunCommand` **before** the connection guard.
- [ ] An operator can list, select and delete a provider with no SQL.
- [ ] `make check` green.

## Out of Scope

- The add/edit form's full field set. v1 lists and selects; editing is a v2 once
  the list is proven, because the form is where most of the UI risk lives.
- Model discovery in the picker (Stage 4's cache lands separately).
