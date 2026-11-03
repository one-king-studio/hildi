# MCP Management Dialog v1 — SPEC

## 1. Three states, and why conflating them makes the UI lie

The design's load-bearing distinction. There are **three** independent facts
about a server, not two, and each answers a different question.

| | Connection | Enabled | Active |
| --- | --- | --- | --- |
| Question | Is the transport up right now? | May the LLM use it? | Is it loaded into this session's context? |
| Source of truth | A **live probe**, by the manager | The `mcp_servers` row | The session's loaded set |
| Persisted? | **No** — observed, never stored | Yes (`enabled`) | No — in-context state, derived from the store |
| Changes when | A transport dies, a token expires, a probe fails | The operator edits the record | `load_mcp` loads it; a checkpoint rewinds context |
| Cost | A probe (possibly a spawn or HTTP call) | A store read | A store read |
| Visible to the model? | No | Yes — it is in the manifest | Yes — its body is in context |

**Enabled** is the manifest question. An enabled server is listed and callable
with `load_mcp`.

**Active** is the context question. An active server's instructions are in the
session's context right now. A server can be enabled and inactive — that is the
normal lazy case, not an error — and unenabled means it is not offered at all.

**Connection** is the transport question, and only a probe answers it.

The eight combinations are not eight UI states; three columns of two-ish values
is enough, and the one that matters is **enabled + disconnected**, which is the
only combination where something is promised and unavailable.

### 1.1 Scope, and precedence

A record is **workspace-only or global**. When a key exists in both, the
**workspace record wins** — no merge, no per-field override. One record is
authoritative for a key in a given workspace, so a name can never resolve to two
definitions.

This mirrors `ResolveMcpConfig`'s existing behaviour and is why the dialog shows
the winning record's scope, not both.

## 2. Where each piece lives

The TUI **may not** reach the MCP manager: `HildiMCPClient` is not in its import
closure, and `TSplitBoundaryTest` exists to keep it that way. So:

```
TUI (HildiHarnessApp)          Runtime (HildiSessionRuntime → THarnessSession → TMcpManager)
  /mcp  ──── scMcpList ─────────►  ListMcpServers (store) + state per server
        ◄─── ekMcpList ─────────  [{key, label, description, transport,
                                    connection, activation, error}]
        ──── scMcpProbe ────────►  probe EVERY server now (bounded)
        ◄─── ekMcpProbeResult ──  [{key, connection, error}]
        ──── scMcpReconnect ────►  CloseServer + OpenServer for one key
        ◄─── ekMcpReconnectDone ►  [{key, connection, error}]
        ──── scMcpAdd ──────────►  ValidateMcpServerRow + SaveMcpServer + reconcile
        ◄─── ekMcpList ─────────  (reuses the list reply — one shape)
```

Four commands, three events. `ekMcpList` is the single carrier of list state, so
add and reconnect both answer with it rather than inventing a result shape.

### 2.1 Why probe is its own command, not a flag on list

`scMcpList` must stay cheap: it is answered from the store plus in-memory state,
and the dialog calls it every time it opens. Probing may **spawn a process** or
make an HTTP call per server. Mixing them would make opening the dialog cost a
subprocess spawn per row, which is exactly the per-open latency the operator
would notice. Separate commands let the dialog render the list immediately and
fill status in behind it.

## 3. Protocol additions

All appended last, and **all must appear in `CommandKindNames` / `EventKindNames`
in the same commit** — those arrays are indexed in enum order, so a missing name
mis-maps every later kind (the trap recorded in board #105).

```pascal
TSessionCommandKind = (
  ..., scLoadSkill, scSkills, scSkillDetail,
  { MCP management. Appended last so stored ordinals are unchanged. }
  scMcpList, scMcpProbe, scMcpReconnect, scMcpAdd);
```

`TSessionCommand` gains:
- `McpKey: string` — the target server, for probe/reconnect.
- `McpRow: TMcpServerRow` — the definition, for add.

`TSessionEvent` gains:
- `McpServers: array of TMcpRowStatus` — for `ekMcpList`.

```pascal
TMcpConnection = (mcUnknown, mcConnected, mcDisconnected);

{ Whether a remote server needs OAuth, learned when the record is added so the
  dialog can say so without probing. }
TMcpAuthKind = (maNone, maOAuth);

TMcpRowStatus = record
  Key: string;             // the unique key
  LabelText: string;       // '' => render the key
  Description: string;     // '' => render nothing; "when to use"
  Transport: TMcpTransportKind;
  Scope: TMcpScope;        // which record won: workspace or global
  Connection: TMcpConnection;   // mcUnknown until a probe answers
  Enabled: Boolean;        // may the LLM use it (manifest)
  Active: Boolean;         // loaded into this session's context
  Auth: TMcpAuthKind;      // OAuth required? learned at add time
  Error: string;           // '' unless the last probe/reconnect failed
end;
```

`mcUnknown` matters: the list arrives before any probe, and rendering a
not-yet-probed server as `disconnected` would be a false claim.

`Enabled` and `Active` are **separate booleans**, not one tri-state, because they
are asked by different consumers: the manifest reads `Enabled`, the loaded set
reads `Active`.

## 4. Schema: two new columns

`label` and `description` are **additive** columns on `mcp_servers`, added by the
next migration version (currently 8, so this is v9). Both default `''`, so every
existing row stays valid and renders as it does today.

```sql
ALTER TABLE mcp_servers ADD COLUMN label TEXT NOT NULL DEFAULT '';
ALTER TABLE mcp_servers ADD COLUMN description TEXT NOT NULL DEFAULT '';
```

`TMcpServerRow` gains `Label: string` and `Description: string`;
`ListMcpServers`/`SaveMcpServer` carry them; `LoadMcpServers` selects them.

### 4.1 The description reaches the model

`TMcpProvider.StatusText` currently emits `<mcp name="browser" state="closed"/>`.
It gains the description, so tool selection is informed:

```xml
<mcp name="browser" state="open" use="control the user's Chrome: navigate, click, read"/>
```

Omitted when empty, so an undescribed server is unchanged. This is the half of
the feature that pays off even if the dialog is never opened.

## 5. Probing

**Owner:** the `TMcpManager`, on an as-needed basis. Not the runtime, not the TUI,
not a timer. The manager owns connection lifecycle, so it owns the probe, and
`hildi-agent-cli mcp probe` can reuse it.

**Trigger:** the dialog's open, and the explicit `r` action. Nothing else. No
polling, ever — the harness already has enough periodic work, and a probe may
spawn a process or make an HTTP call.

**Shape:** `scMcpProbe` with an empty key means *all servers*. The runtime asks the
manager and answers with **one** `ekMcpProbeResult` carrying a row per server.

**Bounded:** each probe uses the existing `ListTimeoutMs`, and the whole sweep is
bounded so a wedged server cannot stall the dialog. A server that times out
reports `mcDisconnected` with `Error = 'probe timed out'`, never an exception.

**Off the UI thread:** the TUI sends `scMcpProbe` and renders `mcUnknown` until
`ekMcpProbeResult` arrives. It never blocks.

## 6. Reconnect

`r` on a `mcDisconnected` row sends `scMcpReconnect(key)`. In the runtime:

```pascal
FManager.CloseServer(Key);      // drop the dead transport
Ok := FManager.OpenServer(Key); // re-open; the OAuth path refreshes on expiry
```

Reconnect **must not** touch activation. It is a transport operation. This is the
operator's explicit requirement and the reason `Active` is a separate field.

Disabled/not-enabled servers: reconnect returns the list unchanged with
`Error = 'not enabled'` — enabling is a config change, not a reconnect.

## 7. Add form

Fields, in the order the dialog asks for them:

| Field | Required | Validation |
| --- | --- | --- |
| Key | **yes** | `IsValidMcpName`; unique across scope |
| Label | no | free text |
| Description | no | free text, one line |
| Transport | yes | stdio (default) / http |
| Command, Args | stdio only | non-empty command |
| URL, Headers | http only | non-empty URL |
| Env | no | `NAME=VALUE` lines; secrets belong here, not argv |
| Working dir | no | '' => process cwd |
| List/Call timeout | no | 0 => client default |

Validation reuses `ValidateMcpServerRow`, so the dialog and the CLI cannot
disagree. On failure the form stays open with the message against the field.

**Scope:** the form offers **workspace** or **global**, defaulting to workspace
when one is present. The choice is recorded on the row, and a key already present
in the other scope does not block the add — it shadows it for this workspace,
which is the defined precedence, so the form says so rather than refusing.

### 7.1 Adding never connects

Add **writes a record**. It does not open the transport. That is deliberate:
connecting is `r`'s job, and an add that connects would block the dialog on a
spawn or an OAuth browser flow.

The one exception is a **remote (HTTP) server, which is auth-checked at add time**
so the dialog can record whether OAuth is required. That check is a probe of the
authorization requirement, not a connection: it must be bounded by
`ListTimeoutMs` and must fail open — if the check cannot determine the answer,
save the row with `Auth = maNone` and let the first `r` discover the truth. A
record that cannot be saved because an auth probe failed would be worse than an
imprecise `Auth` field.

`TMcpServerRow` therefore carries `Auth: TMcpAuthKind`, persisted, so the list can
show "needs auth" without probing every time.

## 8. The dialog

`TMcpModal = class(TModal)` — the shared base gives the frame, title, footer
CTA pairs, and scroll container, so this class owns only its rows.

```
┌ MCP servers ───────────────────────────────────────────┐
│ browser       control the user's Chrome      ● up  · active│
│ playwright    drive a headless browser       ○ down · active│
│ toughleaf     staging API                    · —    · off   │
│                                                             │
│ ＋ add a server                                             │
├─────────────────────────────────────────────────────────────┤
│ a add   r reconnect   enter details   esc close             │
└─────────────────────────────────────────────────────────────┘
```

- Status glyphs are **two separate columns**, so `down · active` (needs action)
  is visually distinct from `— · off` (dormant).
- `enter` opens a read-only detail view (v1: connection params, last error).
- The list is workspace-scoped first, then global, with the scope named per row
  when a key exists in both.

## 9. Testing strategy

Non-tautological tests only — each must be verified to fail without the change.

| Test | Asserts |
| --- | --- |
| Two statuses are independent | A row that is connected+inactive and one disconnected+active render differently, and neither is reported as the other |
| Probe is explicit | Opening the dialog sends `scMcpProbe` once; a tick with no action sends none |
| Unknown is not disconnected | A list before any probe renders `mcUnknown`, not `mcDisconnected` |
| Reconnect keeps activation | After `r`, `Active` is unchanged and `Connection` becomes connected |
| Probe timeout is per-row | A timed-out server emits `ekMcpProbeResult` with `Error` set, others unaffected |
| Add validates | A duplicate key and an invalid name are refused with the form still open |
| Description reaches the model | `StatusText` contains `use="..."` when set and omits it when empty |
| Wire round trip | Every new command/event kind encodes and decodes; the name arrays stay in step |

## 10. What this does not fix

The known `TSessionRuntimeTest` flakes are unrelated. `state="closed"` in the
harness context is *not* removed by this work — it becomes legible, which is the
next best thing, and the MCP split may remove it separately.
