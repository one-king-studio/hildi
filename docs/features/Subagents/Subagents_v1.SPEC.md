# Subagents — Core v1 — Technical Specification

## Overview

This spec defines **delegated task execution** for the helper: the parent agent
hands a task to a **subagent** — a brand-new, independent session with its own
context window, its own headless runtime process and socket, and a durable
lineage link to the session that spawned it. Delegation is **asynchronous**: the
spawn returns immediately, and the subagent's final response is delivered back
to the parent later as an **ambient notification** that wakes a parent turn.

It covers the **core**: lineage in the store, the delegation tool family, the
supervisor inside the parent's per-session runtime, ambient delivery, lineage-wide
approvals, the headless auto-deny safety, and the child lifecycle. The TUI
sidebar and spy view are specified separately in
`Subagent_Sidebar_v1.SPEC.md`.

Scope is deliberately **1 level deep**: a child may not itself delegate.

## Prior Art and Reuse (Ponytail)

The hard part already exists. This spec designs only the gap.

| Need | Already exists | Reuse |
| --- | --- | --- |
| A child agent session | `hildegard.helper.session.runtime` (`TSessionRuntime`) | Spawn one per child; it is an ordinary session |
| Spawn / attach / drive a child | `hildegard.helper.session.client` (`TSessionClient`, connect-or-spawn, `srDrive`) | The supervisor is a client of each child |
| Line framing | `hildegard.helper.session.socket` (`ExtractLine`/`ReadLineTimeout`/`SendAll`) | Not re-implemented |
| Durable lineage | `hildegard.helper.store` (`sessions` table, migrations) | Additive migration v3 |
| History + ambient rows | `hildegard.helper.session.store` (`TSqliteConversationStore`) | New `mrAmbient` role + `AppendAmbient` |
| Tool contract + reason gate | `hildegard.helper.agent` (`TToolRegistry`/`TToolSpec`, `ExtractToolReason`) | Register four tools |
| Approvals + scopes | `hildegard.helper.approval` (+ `.store`) | Lineage = one shared session scope (see §7) |
| Ambient message wrapper | hildegard main `src-backend/lib/main-agent/message-formatter.ts` (`formatCurrentMessage`, `formatSystemMessage`) | Port the pattern; wrap only at API-build time |
| Turn boundary | `hildegard.helper.harness.turn` / `.worker` | `TTurnWorker` variant for an ambient turn |

**New code (no equivalent):** the lineage columns and queries; the four
delegation tools; the runtime-side supervisor; the ambient record kind, its
API-time wrapper, and its renderer; the protocol additions; the lineage-wide
approval context; and the headless auto-deny.

## Architecture

```
parent runtime (single-threaded select loop)
├── THarnessSession (loop, tools, queue, gate, approval service)   [exists]
├── TSubagentSupervisor  ── owns ──▶ TSessionClient(child)  ──▶ child runtime process
│     • spawn child session (store) + runtime (client connect-or-spawn)
│     • attach as the child's DRIVER; send the task prompt
│     • queue child events for the runtime thread (thread-safe)
│     • relay child approval asks up; relay decisions down
│     • enforce depth/capacity; terminate children on parent exit
└── delegation tools (delegate_task, message_task, abort_task, release_task)
      └── call the supervisor through ISubagentService
```

- The runtime stays **single-threaded**: every child event that crosses from a
  child's reader thread is enqueued by the supervisor and drained by the runtime
  loop, exactly as `DrainTurn` drains the turn queue. No callback mutates runtime
  state off the runtime thread.
- The child is an **ordinary session**: its own `TSessionRuntime`, its own
  socket, its own ledger rows. The parent observes it like any other session.
- Approvals are **lineage-wide** (§7): all sessions in a lineage resolve against
  one shared session scope, so a grant for one is in force for all.

## Contracts

### 1. Lineage (store)

`TSessionSummary` gains lineage fields (additive; existing callers ignore them):

```pascal
TSessionSummary = record
  Id: string;
  CreatedAtMs: Int64;
  UpdatedAtMs: Int64;
  MessageCount: Integer;
  TurnCount: Integer;
  { Lineage (v3). A root session has ParentId = '' and Depth = 0. }
  ParentId: string;
  Depth: Integer;
  LabelText: string;   // 'Label' is a reserved word in FPC
end;
```

New store methods on `TSqliteStore`:

```pascal
{ Create a session whose parent is AParentId ('' for a root). ADepth is the
  child's depth (parent depth + 1). ALabel is a short human label. }
function CreateChildSession(AWorkspaceId: Integer; const AParentId: string;
  ADepth: Integer; const ALabel: string; out AId: string;
  out AError: TStoreError): Boolean;

{ A session's lineage; seNotFound when the id is unknown. Root: ParentId='',
  Depth=0, Label=''. }
function SessionLineage(const AId: string; out AParentId: string;
  out ADepth: Integer; out ALabel: string; out AError: TStoreError): Boolean;

{ Direct children of a session, newest updated first. }
function ChildrenOf(const AParentId: string;
  out AChildren: TSessionSummaryArray; out AError: TStoreError): Boolean;
```

`CreateSession` (root) is unchanged; it writes `parent_session_id = ''`,
`depth = 0`, `label = ''` by column default.

### 2. Delegation identity and tools

```pascal
unit hildegard.helper.subagent;

const
  { Model-visible tool names. }
  SubagentDelegateTool = 'delegate_task';
  SubagentMessageTool  = 'message_task';
  SubagentAbortTool    = 'abort_task';
  SubagentReleaseTool  = 'release_task';

{ The four tools report their approval asks through the shared engine, one ask
  per call, subject ref `subagent:<verb>` (tool-level; params are deferred). }
```

`delegate_task` parameters (JSON object; `reason` is injected by the registry):

```jsonc
{
  "reason":  "string, required (injected) - why the delegation is happening",
  "task":    "string, required - the instruction for the subagent",
  "context": "string, required - the context the parent supplies (the child has
             no access to the parent's conversation)",
  "label":   "string, optional - a short human label for the sidebar/dialog"
}
```

Result (immediate, non-blocking), as tool-result text:

```
subagent <child-id> spawned for "<label>"; <available> of <max> slots available.
You will be notified when it finishes; use message_task to follow up.
```

`message_task` parameters: `reason`, `session_id` (required), `message`
(required). Result: an acknowledgement that the follow-up was queued to the
child.

`abort_task` parameters: `reason`, `session_id` (required). Aborts the child and
releases its slot; the parent receives an immediate tool result. An ambient
notification for the abort is **not** sent to the parent when the parent is the
aborting actor (it already has the immediate result).

`release_task` parameters: `reason`, `session_id` (required). Detaches from the
child **without** aborting it (fire-and-forget) and frees the slot.

### 3. `ISubagentService` (tools → supervisor)

```pascal
unit hildegard.helper.subagent;

type
  TSubagentSpawnResult = record
    Ok: Boolean;
    SessionId: string;
    Label: string;
    Error: string;
    Available: Integer;   // slots free after this call
    Max: Integer;         // the configured cap
  end;

  { What the delegation tools may do. Implemented by the runtime-side
    supervisor; the tools never touch sockets or the store directly. }
  ISubagentService = interface
    { Spawn a child for a task. Non-blocking: returns once the child session
      exists and its runtime is spawned; its first turn runs asynchronously. }
    function Delegate(const ATask, AContext, ALabel: string;
      out AResult: TSubagentSpawnResult): Boolean;
    { Send a follow-up message to an existing child by session id. }
    function Message(const ASessionId, AText: string;
      out AError: string): Boolean;
    { Abort a child and release its slot. }
    function Abort(const ASessionId: string; out AError: string): Boolean;
    { Detach from a child without aborting it; free its slot. }
    function Release(const ASessionId: string; out AError: string): Boolean;
    { The child's current status for a tool acknowledgement. }
    function Status(const ASessionId: string): string;
    property Available: Integer read GetAvailable;
    property Max: Integer read GetMax;
  end;
```

The four tools are `IApprovableTool`s constructed with an `ISubagentService` and
an `IApprovalService`. Their `ApprovalAsks` produce one ask with
`Subject.Ref = 'subagent:<verb>'` (e.g. `subagent:delegate_task`), a summary
naming the task/label, and the reason from the arguments. Default decision is
`adAsk` (no implicit allow).

### 4. Supervisor (runtime side)

```pascal
unit hildegard.helper.subagent.supervisor;

type
  { A child event surfaced to the runtime loop, in arrival order. }
  TSubagentEventKind = (
    sekSpawned,        // the child's runtime is up
    sekResult,         // the child's turn finished; Result holds its final text
    sekAborted,        // the child was aborted (operator or parent)
    sekApprovalAsk,    // the child is blocked on an approval ask
    sekGone            // the child's runtime exited / detached
  );

  TSubagentEvent = record
    Kind: TSubagentEventKind;
    SessionId: string;
    Label: string;
    Result: string;    // sekResult: the child's final assistant text
    ElapsedMs: Int64;  // sekResult: the task duration
    AskId: string;     // sekApprovalAsk: the child's ask id
    Ask: TApprovalAsk; // sekApprovalAsk
    Error: string;     // sekGone
  end;

  { Callbacks the runtime provides. Emit is called on the runtime thread. }
  TSubagentEmitEvent = procedure(const AEvent: TSessionEvent) of object;

  TSubagentSupervisor = class
  public
    constructor Create(const AConfig: TSubagentSupervisorConfig;
      AEmit: TSubagentEmitEvent);
    destructor Destroy; override;
    { Drain child events for the runtime loop (non-blocking). }
    function Poll(out AEvent: TSubagentEvent): Boolean;
    { Spawn / message / abort / release / status — the ISubagentService surface. }
    function Delegate(const ATask, AContext, ALabel: string;
      out AResult: TSubagentSpawnResult): Boolean;
    function Message(const ASessionId, AText: string;
      out AError: string): Boolean;
    function Abort(const ASessionId: string; out AError: string): Boolean;
    function Release(const ASessionId: string; out AError: string): Boolean;
    function Status(const ASessionId: string): string;
    { Relay an operator's decision for a child ask back down to the child. }
    procedure AnswerChildAsk(const ASessionId, AAskId: string;
      const AChoice: TApprovalChoice);
    { Terminate every supervised child (bounded). Called on parent shutdown. }
    procedure TerminateAll;
    property Available: Integer read GetAvailable;
    property Max: Integer read GetMax;
    property HasClient: Boolean read FHasClient write FHasClient;
  end;
```

`TSubagentSupervisorConfig` carries: `WorkspacePath`, `StorePath`,
`RuntimeCommand`, `ParentSessionId`, `ParentDepth`, `ParentWorkspaceId`,
`MaxChildren`, `MaxDepth`, `IdleExitMs`, `AutoDenyMs`, and the runtime's own
`ISubagentService` is satisfied by the supervisor (the supervisor implements it).

**Spawn flow (prose).** `Delegate` (a) checks `depth + 1 <= MaxDepth` and
`ActiveCount < MaxChildren`, failing cleanly otherwise; (b) creates the child
session via `CreateChildSession`; (c) opens a `TSessionClient` for the child
with `Spawn = True`, `Role = srDrive`, the shared store/workspace, and the
runtime binary; (d) sends `scPrompt` with the composed task prompt; (e) records
the child in the roster and emits `sekSpawned`. The composed prompt is:

```
Context from the delegating agent:
<context>

Your task:
<task>
```

**Child result.** The supervisor tracks each child's last assistant block from
its stream; on the child's `ekTurnFinished` it records `sekResult` with that text
and the turn's elapsed. The runtime reads the final text from the store if the
stream carried none (durable truth).

**Child approvals.** A child's `ekApprovalRequest` becomes `sekApprovalAsk`. The
runtime re-emits it on the parent socket (§5). The operator's decision returns as
a parent command; the runtime calls `AnswerChildAsk`, which sends `scApprove` to
the child.

**Auto-deny.** The supervisor tracks, per pending child ask, a deadline
(`NowMs + AutoDenyMs`). When the runtime loop sees the deadline pass and the
supervisor has **no attached interactive client** (`HasClient = False`), it
auto-denies: `AnswerChildAsk` with a deny choice, and records that the child was
told it was auto-denied. A purely headless parent therefore never hangs.

**Teardown.** `TerminateAll` sends each child an interrupt and closes its client
(bounded); a child that does not exit is killed by the runtime's own idle-exit.
Children are terminated when the parent session ends.

### 5. Protocol additions

Appended last to preserve stored ordinals (`hildegard.helper.session.protocol`).

```pascal
TSessionEventKind = ( ...existing..., ekAmbient, ekSubagent, ekSubagentAsk);

TSessionCommandKind = ( ...existing..., scAbortSubagent, scReleaseSubagent);

TSessionEvent = record
  ... existing fields ...
  { ekSubagent: the roster entry. Status is one of the wire strings below. }
  SubStatus: string;   // 'spawned' | 'running' | 'completed' | 'failed'
                       // | 'aborted' | 'released' | 'gone'
  { ekAmbient: the delivered subagent result. }
  ElapsedMs: Int64;    // reuse: task duration
end;

TSessionCommand = record
  ... existing fields ...
  { scAbortSubagent / scReleaseSubagent: the child to act on. Reuse Text. }
  SessionId: string;
end;
```

- `ekAmbient` carries `SessionId` (the child), `Text` (the result), `ElapsedMs`.
- `ekSubagent` carries `SessionId`, `Text` (label), `SubStatus`.
- `ekSubagentAsk` is the child's approval ask relayed up: it carries
  `SessionId` (the child), `AskId` (the child's ask id, namespaced), and `Ask`.
- `scAbortSubagent` / `scReleaseSubagent` carry `SessionId`; the runtime routes
  them to the supervisor. They are **drive** commands (operator only).

### 6. Loop and ambient delivery

**Ambient record.** `TMessageRole` gains `mrAmbient` (appended last). The
`messages` table gains `ref_session_id` (the child session id); the elapsed is
stored in the existing `duration_ms`.

`IConversationStore` gains:

```pascal
{ Append an ambient (subagent result) notification. Delivered to the provider as
  a user message wrapped by the ambient format; persisted as its own kind. }
procedure AppendAmbient(const AText, ARefSessionId: string; AElapsedMs: Int64);
```

**Prompt queue.** `TPromptQueue` carries a kind per item:

```pascal
TPromptKind = (pkUser, pkAmbient);
{ Existing Push(AText) appends a pkUser prompt. }
procedure PushAmbient(const AText, ARefSessionId: string; AElapsedMs: Int64);
```

`DrainQueued` appends `crUser` for `pkUser` and calls `AppendAmbient` for
`pkAmbient`, and reports each to the caller (a new `OnAmbient` event) so the UI
renders it specially.

**Loop entry for an ambient turn.**

```pascal
{ Run a turn whose opening content is already queued as an ambient notification:
  no user message is appended; the queue is drained at the first boundary. }
function SendAmbient(const AEvents: TAgentEvents;
  out AAnswer: string; out AError: TLLMError): Boolean;
```

`TAgentEvents` gains `OnAmbient: TAmbientEvent` (the text + child id + elapsed).
`TTurnWorker` gains `CreateAmbient(ALoop, AQueue)` that calls `SendAmbient`.

**Waking the parent.** The runtime, on a `sekResult`/`sekAborted` event:
- appends an ambient prompt to the loop's queue (`PushAmbient`); and
- if no turn is active, starts an ambient turn (`TTurnWorker.CreateAmbient`),
  which drains the queue and delivers the notification;
- if a turn is active, the running turn drains the queue at its next boundary
  (no interruption).

### 7. Approvals: one scope for the lineage

A child **inherits the parent's permissions** and approvals are **lineage-wide**.
The mechanism: every session in a lineage resolves approvals against the
**root session id** as its approval-context `SessionId`. So:

- The child runtime is spawned with its approval context `SessionId` set to the
  lineage root (the parent's id for depth 1). `THarnessSessionConfig` gains
  `ApprovalRootSessionId` (empty = the session's own id).
- A grant made for one child is stored under the root scope and is immediately in
  force for the parent and every sibling — the "broadcast down" effect, with no
  explicit broadcast.
- A child's ask still surfaces to the operator (§4/§5), so the operator remains
  the gate.

The child's **conversation** session id stays its own (the ledger is per-session).

### 8. Runtime integration

`TSessionRuntime` gains:

- A `TSubagentSupervisor` created in `Open` when the session is eligible (depth <
  max depth) and destroyed in `Destroy`.
- Registration of the four delegation tools into `FSession.Tools`, each built
  with the supervisor (as `ISubagentService`) and the session's approval service,
  **only** when the session's depth is below `MaxDepth`.
- A `DrainSubagents` pass in the select loop (after `DrainTurn`) that polls the
  supervisor and, per event: emits `ekSubagent`/`ekAmbient`, injects the ambient
  prompt and starts an ambient turn, relays `sekApprovalAsk` as
  `ekSubagentAsk`, and enforces the auto-deny deadlines.
- Command handling for `scAbortSubagent`/`scReleaseSubagent`, and routing of
  `scApprove` for a child ask to `AnswerChildAsk`.
- `HasClient` on the supervisor maintained from the attached-client count, so
  auto-deny applies only when no interactive client is attached.

### 9. Configuration

| Knob | Default | Meaning |
| --- | --- | --- |
| `HILDEGARD_SUBAGENT_MAX` | 10 | Max live children per parent session |
| `HILDEGARD_SUBAGENT_DEPTH` | 1 | Max depth (1 = children may not delegate) |
| `HILDEGARD_SUBAGENT_AUTO_DENY_MS` | 60000 | Headless child ask auto-deny window |

## Data Model and Migrations

Additive migration **v3** (no reset; existing history untouched):

```sql
ALTER TABLE sessions ADD COLUMN parent_session_id TEXT NOT NULL DEFAULT '';
ALTER TABLE sessions ADD COLUMN depth INTEGER NOT NULL DEFAULT 0;
ALTER TABLE sessions ADD COLUMN label TEXT NOT NULL DEFAULT '';
CREATE INDEX idx_sessions_parent ON sessions (parent_session_id);
ALTER TABLE messages ADD COLUMN ref_session_id TEXT NOT NULL DEFAULT '';
```

`StoreSchemaVersion` becomes 3.

## Validation and Error Handling

- Spawn at the depth cap: `Delegate` fails with a clear message; the tool returns
  it as a tool result (the parent sees it and adapts). A child at the cap never
  registers the delegation tools.
- Spawn at the capacity cap: fails with `<available> of <max>` so the parent can
  release/abort and retry.
- Unknown child id on `message_task`/`abort_task`/`release_task`: a clean tool
  error naming the id.
- A child that crashes or detaches: `sekGone`; its slot is reclaimed; the parent
  is notified (an ambient "subagent <id> exited").
- Ambient delivery to a parent with no store: the ambient is not persisted (the
  in-memory store appends it as a plain user message) — a documented degradation.
- Every delegation tool validates the required non-empty `reason` before
  dispatch (the registry guarantees the schema; the loop enforces it).

## Testing Strategy

- **Lineage:** create/child/lineage/children queries; migration v3 is additive
  (a v2 database opens and keeps its history); root defaults.
- **Tools:** each tool's spec, `reason` enforcement, approval ask shape, and
  argument parsing (task/context/label, session id) — pure, no sockets.
- **Ambient:** `AppendAmbient` round-trip; `Compose` wraps `mrAmbient` into the
  `<ambient timestamp session>` user message with instructions; the elapsed and
  child id survive.
- **Supervisor:** with a scripted fake child over a real socket (a stub runtime
  binary), spawn/message/abort/release, capacity and depth enforcement, roster
  events, result capture, and approval relay.
- **Approvals:** a child resolving against the root scope sees the parent's
  grants; a grant made for one child is in force for a sibling.
- **Auto-deny:** with no attached client, a pending child ask is denied after the
  window and the child continues.
- **Lifecycle:** children terminate on parent shutdown; the leak gate stays
  green (threads joined, clients freed).

No network, no real LLM: the child runtime is driven through an injected
transport.

## Performance and Security

- Spawn must not block on the child's first turn (it returns once the runtime
  socket is up).
- The parent's registry lookup stays O(1)-ish; listing happens once per child.
- Approval inheritance is a scope id, not a new mechanism — no extra prompt.
- Children run with the parent's workspace confinement and approval lineage; the
  model cannot add a server or widen scope. `subagent:*` refs are never
  permissive by default.
- A child cannot exceed the depth/capacity caps; a runaway child is bounded by
  the turn's existing tool-call budget and the runtime's idle-exit.
