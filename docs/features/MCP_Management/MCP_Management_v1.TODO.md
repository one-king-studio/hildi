# MCP Management Dialog v1 — TODO

Ordered so each phase ends at a green gate, and the model-facing half of the
feature (the description) lands before the dialog that displays it.

## Phase 1 — the description field (model-facing, no UI)

The half that pays off without the dialog. If this project stalls, the harness is
still better off.

- [ ] Migration v9: `ALTER TABLE mcp_servers ADD COLUMN label TEXT NOT NULL
      DEFAULT ''` and `... description TEXT NOT NULL DEFAULT ''`.
- [ ] `TMcpServerRow` gains `Label`, `Description`.
- [ ] `SaveMcpServer` writes them; `ListMcpServers` reads them;
      `LoadMcpServers` selects them.
- [ ] `ValidateMcpServerRow` bounds both (one line each, length cap).
- [ ] `TMcpProvider.StatusText` emits `use="<description>"` when set, omits it
      when empty.
- [ ] Test: `StatusText` contains `use="..."` when set; omits the attribute
      entirely when empty (not `use=""`).
- [ ] Test: a row round-trips both fields through save/list.
- [ ] Gate.

## Phase 2 — the wire: four commands, three events

No UI yet. This phase is provably correct on its own and is the riskiest for
silent breakage (enum/name arrays).

- [ ] `scMcpList`, `scMcpProbe`, `scMcpReconnect`, `scMcpAdd` appended to the
      enum **and** to `CommandKindNames`, in the same edit.
- [ ] `ekMcpList`, `ekMcpProbeResult`, `ekMcpReconnectDone` appended to the enum
      **and** to `EventKindNames`, in the same edit.
- [ ] `TMcpConnection`, `TMcpRowStatus`; carry on `TSessionCommand` / `TSessionEvent`.
- [ ] Encoder + decoder for every new field.
- [ ] Test: round-trip fixture covering every new kind and field (extend the
      existing every-kind test rather than adding a parallel one).
- [ ] Test: the name arrays stay index-parallel with the enums (a count assertion,
      cheap and it catches the removal-while-leaving-the-name trap).
- [ ] Gate.

## Phase 3 — runtime handlers

- [ ] `HandleMcpList` — store rows + in-memory state, answered to the asking
      client only (not broadcast; it is a request/response, and putting it in the
      replay ring would replay it to every later attach).
- [ ] `HandleMcpProbe` — bounded per-server probe; `mcUnknown` never returned
      here, only `mcConnected` / `mcDisconnected` + `Error`.
- [ ] `HandleMcpReconnect` — `CloseServer` then `OpenServer`; activation untouched;
      `not enabled` is an error, not a reconnect.
- [ ] `HandleMcpAdd` — validate, save, reconcile, answer with a fresh
      `ekMcpList`.
- [ ] Test: probe timeout produces a per-row error and does not fail the sweep.
- [ ] Test: reconnect leaves `Active` unchanged and sets `Connection`.
- [ ] Gate.

## Phase 4 — the dialog

- [ ] `TMcpModal = class(TModal)`: rows with key/label, description, two status
      columns, per-row error.
- [ ] Probe on open → `scMcpProbe`; render `mcUnknown` until the answer arrives.
- [ ] `r` on a down row → `scMcpReconnect`.
- [ ] `enter` → read-only detail (connection params + last error).
- [ ] Footer CTA pairs via `TModal` (`a add`, `r reconnect`, `enter details`,
      `esc close`), matching the approval dialog's spacing style.
- [ ] Test: two-status independence — connected+inactive vs disconnected+active
      render differently.
- [ ] Test: `mcUnknown` is not rendered as disconnected.
- [ ] Gate.

## Phase 5 — the add form

- [ ] Field list per SPEC §7, in that order, with transport-conditional fields.
- [ ] `ValidateMcpServerRow` drives the errors; the form stays open on failure.
- [ ] Scope: workspace when present, else global.
- [ ] Save → `scMcpAdd` → list refreshes without a restart.
- [ ] Test: duplicate key refused; invalid name refused; valid row appears in the
      refreshed list.
- [ ] Gate.

## Phase 6 — wiring and cleanup

- [ ] `/mcp` in `RunCommand` (store-only, so it works while connecting — same
      early branch as `/sessions`).
- [ ] Command palette entry.
- [ ] `FEATURES.md` row.
- [ ] Rename this TODO to `MCP_Management_v1.DONE.md`, ticking only what landed.
- [ ] Full gate + leak gate.

## Open questions to settle during implementation

1. ~~Does the store own `enabled`, or the session?~~ **Settled.** The record owns
   `enabled` (may the LLM use it — manifest + `load_mcp`). `active` is separate:
   is it loaded into the session's context. Two booleans, two consumers.
2. ~~Where does the probe's bounded sweep live?~~ **Settled.** The
   `TMcpManager`, on an as-needed basis.
3. ~~Does adding over HTTP with OAuth block?~~ **Settled.** Add writes a record
   and never connects; a remote server gets a **bounded auth check** at add time
   so `Auth` is known without probing, and that check fails open.

## Decided

- **No curated metadata table.** `McpCuratedMeta` is deleted. Every MCP is a row
  in `mcp_servers`; nothing hardcoded may compete with a stored definition, so a
  name can never resolve to two descriptions. **Templates** (a later phase) may
  pre-fill the add form, but a template is a starting point — once added, the
  record is the only definition.
  Blast radius: one call site (`HildiMCPProvider.pas:178`), the declaration and
  body, and two assertions in `TestMCPProvider.pas`.
- **Three states, not two.** `Connection` (probed), `Enabled` (record), `Active`
  (session context). See SPEC §1.
- **Scope precedence.** Workspace wins over global for the same key — whole
  record, no field merge. The dialog names the winning scope.
- **`TMcpServerConfig` must carry `LabelText`, `Description`, `Auth`**, because
  the provider now reads the record rather than the table.
