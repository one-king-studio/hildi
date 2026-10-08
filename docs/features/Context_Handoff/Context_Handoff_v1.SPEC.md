# Component Specification: Context Handoff v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.store` (lineage, messages),
`hildegard.helper.session.protocol`, `hildegard.helper.session.runtime`,
`hildegard.helper.harness.session` / `view`, `hildegard.helper.tui.app`.

## Purpose

Implement a recoverable handoff: the current agent generates a handoff document;
the operator edits it; a **child session** is created, seeded with the handoff
as its first message and linked to the predecessor; the TUI switches; the old
runtime exits cleanly. The successor can recall from the predecessor.

## Requirements

### Functional

- [ ] **Protocol**: `scHandoff` (driver-only) asks the runtime to generate a
      handoff draft; `scHandoffCommit` (driver-only, carries the edited text)
      applies it. Events: `ekHandoffReady` (draft text), `ekHandoffCommitted`
      (child session id).
- [ ] **Generate**: the runtime runs one bounded LLM request (a handoff
      instruction against the current context) and emits the draft as
      `ekHandoffReady`. It does not modify the session.
- [ ] **Commit**: the runtime creates a child session
      (`CreateChildSession(workspace, current, depth+1, 'handoff')`), seeds it
      with the handoff text as its **first message** (`mrAmbient`,
      `ref_session_id` = the predecessor), emits `ekHandoffCommitted`, and
      **exits cleanly** (Runtime Lifecycle).
- [ ] **Switch**: the TUI, on `ekHandoffCommitted`, detaches from the old
      runtime and **spawns + attaches** a runtime for the child session,
      rendering the seeded handoff as the first block.
- [ ] **Edit**: the TUI presents the draft in an editable buffer before commit;
      an empty/unchanged draft is refused.
- [ ] **Nudge**: the TUI shows a non-blocking hint when the context crosses a
      configurable threshold (default 80%), suggesting `/handoff`; it never
      triggers a handoff.
- [ ] **Recall into the predecessor**: the successor can read the predecessor's
      history (by session id). The seed carries the predecessor id.
- [ ] The handoff is retrievable as a durable artifact (the child's first
      message), independent of the summary being lossy.

### Non-Functional

- [ ] **Non-destructive**: the predecessor session, turns, and messages are not
      modified by a handoff (only the normal turn lifecycle runs).
- [ ] **Bounded generation**: the handoff request fits even near the context
      limit (reserved output budget); if it cannot, the operator is told.
- [ ] `make check` green; leak-clean.

## Contracts & Interfaces

```pascal
unit hildegard.helper.session.protocol;   // additions

type
  TSessionCommandKind = (
    // ... existing ...
    scShutdown,
    { Ask the runtime to draft a handoff (driver-only). }
    scHandoff,
    { Apply an edited handoff: create+seed the child session (driver-only). }
    scHandoffCommit);

  TSessionEventKind = (
    // ... existing ...
    { A handoff draft is ready for review. Text carries it. }
    ekHandoffReady,
    { The handoff was committed; SubSessionId carries the child session id. }
    ekHandoffCommitted);

  TSessionCommand = record
    // ... existing ...
    HandoffText: string;   // scHandoffCommit: the (edited) handoff document
  end;
```

```pascal
unit hildegard.helper.harness.session;   // addition

type
  THarnessSession = class
    // ... existing ...
    { Generate a handoff draft from the current conversation. One bounded LLM
      request; the session is not modified. }
    function DraftHandoff(out AText: string; out AError: string): Boolean;
  end;
```

```pascal
unit hildegard.helper.store;   // reuse (no change)

type
  TSqliteStore = class
    // existing: CreateChildSession(AWorkspaceId, AParentId, ADepth, ALabel,
    //           out AId, out AError)
    // existing: AppendMessage (mrAmbient carries RefSessionId + LabelText)
  end;
```

### Data Contracts

- **Handoff document** (agent-generated, operator-editable): free text. The
  generate instruction asks for: current objective, decisions **and why**,
  lessons/gotchas, open threads, and in-flight work. It is seeded verbatim.
- **Seed message**: `mrAmbient`, `Content` = the handoff text,
  `RefSessionId` = predecessor session id, `LabelText` = `'handoff'`,
  `Source` = `'handoff'`. It is the child session's first message and is
  **persisted** (visible in the transcript).
- **Lineage**: `parent_session_id` = predecessor, `depth` = predecessor + 1,
  `label` = `'handoff'`. The existing `ChildrenOf`/`SessionLineage` walk it.
- **Recall**: the successor may query the predecessor's messages/artifacts by
  the id in its seed. (A general "recall from session X" capability; the
  existing `recall_tool_result` scoping is the seam.)
- **Switch**: the old runtime is shut down via the Runtime Lifecycle path (it
  finalizes its in-flight turn, unregisters, exits); the child runtime is
  spawned by the client and attached.

### Event Contracts

- `ekHandoffReady` carries the draft `Text`.
- `ekHandoffCommitted` carries the child session id in `SubSessionId` (reusing
  the lineage event field) and the reason `handoff`.
- Events fire on the runtime's loop thread, delivered to the client as usual.

## Architecture

### Prior Art & Reuse

- **Lineage** (`CreateChildSession`, `parent_session_id`, `depth`, `label`,
  `ChildrenOf`, `SessionLineage`) — already built for subagents; a handoff is a
  child session with `label = 'handoff'`.
- **`mrAmbient` + `ref_session_id`** — already built; the seed is an ambient
  message pointing at the predecessor.
- **Runtime Lifecycle** (`scShutdown`, signals, exit-when-idle) — the old
  runtime's clean exit.
- **`recall_tool_result`** — the recall seam for reading the predecessor.
- **`TSessionClient` spawn/attach** — the TUI already spawns and attaches a
  runtime for a session; the switch reuses it.
- **Genuine gap:** the generate request, the commit (child + seed), the protocol
  verbs/events, the TUI switch, and the predecessor recall.

### Component Boundaries

- **Responsibilities:** draft generation, child creation + seed, the switch, the
  nudge, predecessor recall.
- **Dependencies:** the loop (draft), the store (child + seed), the client (spawn).
- **Side effects:** creates a session and a message; shuts down the old runtime.

## Validation Rules

- `scHandoff`/`scHandoffCommit` are driver-only.
- An empty or whitespace-only handoff is refused.
- A handoff on an empty session (no messages) is refused.

## Error Handling

- Generation failure ⇒ `ekError`, no child created.
- Commit failure (store) ⇒ `ekError`, no switch; the session is unchanged.
- The old runtime always exits cleanly (never aborts mid-switch).

## Testing Requirements

### Unit Tests

- [ ] `DraftHandoff` produces text against a fake transport; the session is
      unchanged (message count identical).
- [ ] The seed is an `mrAmbient` message with `ref_session_id` = predecessor.
- [ ] `CreateChildSession` with `label = 'handoff'` links lineage (covered by
      the store tests; add a handoff-label case).

### Integration Tests (`tests/test_session_runtime.pas`)

- [ ] `scHandoff` emits `ekHandoffReady`; `scHandoffCommit` creates the child,
      seeds it, emits `ekHandoffCommitted` with the child id, and the runtime
      exits.
- [ ] The predecessor's message count is unchanged after a handoff.
- [ ] The child session's first message is the handoff with the right ref.

### TUI Tests

- [ ] The nudge appears past the threshold and never triggers a handoff.

## Performance Targets

- Draft generation is one bounded request; the switch is a spawn + attach.

## Security Considerations

- Driver-only; the child inherits the workspace (approvals scope carries
  workspace/global; session-scoped grants reset — a deliberate decision).
- The predecessor is read-only to the successor (recall, never write).

## Success Criteria

- [ ] A session can be handed off to a child that starts from the seed and can
      recall the predecessor; `make check` green.

## Future Considerations

- Automatic handoff at a hard threshold (operator-confirmed).
- A handoff-chain browser.
- Structured (JSON) handoffs; carrying selected session-scoped approvals.
