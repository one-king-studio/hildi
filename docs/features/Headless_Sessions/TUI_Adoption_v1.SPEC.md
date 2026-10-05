# Component Specification: TUI Adoption v1

**Related Feature:** [FEATURE.md](FEATURE.md)
**Implements:** [Session Protocol v1](Session_Protocol_v1.SPEC.md),
[Session Runtime v1](Session_Runtime_v1.SPEC.md)

## Purpose

Make the full-screen harness a headless-session *client*. Today `THarnessApp`
owns the agent loop in-process (`TTurnWorker` + `TTurnQueue` + `TApprovalGate`);
after this slice it drives a `TSessionClient` instead, so the loop lives in the
runtime and the TUI can share a session with other clients (a CLI observer, a
second TUI) and survive its own restart.

The UI, the widgets, the rendering, the approval modal, the history, and the
stats are unchanged. What changes is where turns come from and where commands
go.

## Requirements

### Functional

**The driver seam**

- [ ] The app drives turns through a small interface, not a concrete worker:
      `StartTurn`, `QueuePrompt`, `Interrupt`, `AnswerAsk`, `PopEvent`,
      `Close`.
- [ ] `TLocalDriver` keeps the current in-process behaviour (a `TTurnWorker`
      over the session's `TTurnQueue`/`TApprovalGate`); it is what the app's
      existing tests and the ephemeral path use.
- [ ] `TRemoteDriver` drives a `TSessionClient`.

**The remote driver**

- [ ] It maps wire events to the app's `TTurnEvent`:
      `user_message`→`teUserMessage`, `assistant_delta`→`teAssistantDelta`,
      `reasoning_delta`→`teReasoningDelta`, `tool_call`→`teToolCall`,
      `tool_result`→`teToolResult`, `approval_request`→`teApprovalAsk` (with the
      wire `ask_id` as the ask reference), `turn_finished`→`teDone`,
      `error`→`teError`.
- [ ] Its `ISessionSink` runs on the client's reader thread and pushes the mapped
      events onto a thread-safe queue; the UI drains it (the existing thread
      boundary is preserved - no callback touches a widget off the UI thread).
- [ ] `StartTurn` sends `prompt`; `QueuePrompt` also sends `prompt` (the runtime
      queues it while a turn is in flight); `Interrupt` sends `interrupt`;
      `AnswerAsk` sends `approve`.
- [ ] It reconnects on demand: if the connection is gone when a turn starts, it
      closes and re-opens (connect-or-spawn) before sending, so a runtime that
      idle-exited or crashed does not wedge the TUI.

**The app**

- [ ] `THarnessApp` takes an `ISessionDriver` and no longer creates or owns a
      `TTurnWorker`; `Submit` calls `StartTurn`/`QueuePrompt`.
- [ ] `teUserMessage` is handled: the block is added when the runtime echoes the
      prompt (the local driver synthesises the same event), so the user block
      appears uniformly and an early cancel can still restore the prompt.
- [ ] `OnApprovalChosen` calls `AnswerAsk`; `InterruptTurn` calls `Interrupt`;
      `FinishTurn`/`CancelTurn` no longer join a worker, and `CancelTurn` closes
      the driver on quit.
- [ ] History, stats, the workspace, and the model still come from the
      store-backed session handle (the runtime writes the ledger, the TUI reads
      it), so a resumed view is identical to the live one.

**The bootstrap**

- [ ] `THarnessSession` gains `NoLoop` (default False). With `True` it opens
      the workspace/store/session and loads history, but does not build the LLM
      client, tools, loop, gate, or queue - the TUI process does not own the
      loop.
- [ ] `tui-agent` opens the session with `NoLoop = True`, creates a
      `TRemoteDriver` (connect-or-spawn), and runs the app. The existing
      `--session`/`--continue` flags select the session; the runtime is spawned
      if none is live.
- [ ] `--no-store` is removed from the TUI: the runtime is store-backed.

### Non-Functional

- [ ] Portability: macOS and Linux.
- [ ] The UI thread never blocks on the client except during teardown.
- [ ] Reliability: leak-clean under the heaptrc gate with a runtime, a client,
      and the UI running.
- [ ] Testability: the remote driver is tested over a real runtime with the fake
      LLM transport; the app tests keep using the local driver.

## Contracts & Interfaces

```pascal
unit hildegard.helper.harness.driver;

type
  { Where the app's turns come from. Local = the in-process worker;
    Remote = a TSessionClient. }
  ISessionDriver = interface
    { Start a new turn. }
    procedure StartTurn(const AText: string);
    { Inject a prompt into the running turn (the runtime queues it). }
    procedure QueuePrompt(const AText: string);
    { Ask the runtime to cancel the live turn. }
    procedure Interrupt;
    { Resolve a pending approval ask by its reference. }
    procedure AnswerAsk(const AAskRef: string; const AChoice: TApprovalChoice);
    { UI thread: pop the next event, if any. }
    function PopEvent(out AEvent: TTurnEvent): Boolean;
    { Release the connection and join any thread. Idempotent. }
    procedure Close;
  end;

  TLocalDriver = class(TInterfacedObject, ISessionDriver) ... end;
  TRemoteDriver = class(TInterfacedObject, ISessionDriver) ... end;

function LocalDriver(ASession: THarnessSession): ISessionDriver;
function RemoteDriver(const AConfig: TSessionClientConfig): ISessionDriver;
```

`TTurnEvent` gains `AskRef: string` - the approval reference (`RequestId` as a
string for the local driver, the wire `ask_id` for the remote one). The app
answers by `AskRef`.

## Architecture

### Prior Art & Reuse

- `TTurnEvent` / `TTurnQueue` stay the app's currency and thread boundary; the
  remote driver maps the wire onto them, so the UI logic is reused unchanged.
- `TSessionClient` / `ISessionSink` are the transport; the driver is a thin
  adapter.
- `THarnessSession` remains the store/history/stats/workspace/model handle; only
  its loop construction becomes optional.

### Component Boundaries

- **Responsibilities:** the driver owns the connection and the command direction;
  the app owns the UI and the block state machine; the session handle owns the
  store.
- **Dependencies:** the driver unit uses the runtime (sockets); the app stays
  socket-free and depends only on the driver interface.
- **Side effects:** the socket, the store rows (written by the runtime).

### Data Flow

1. `tui-agent` opens the session handle (`BuildLoop=False`), creates a
   `TRemoteDriver`, and hands it to the app.
2. `Submit` → `StartTurn` → the client sends `prompt`; the runtime runs the turn
   and streams events; the driver maps them onto the queue; the app drains and
   renders.
3. An approval ask becomes a modal; the choice becomes `approve`; the runtime
   resolves the gate and the turn continues.
4. On quit the driver closes the client; the runtime keeps running (or
   idle-exits).

## Validation Rules

- A driver must be given a live session handle (remote) or a session with a
  built loop (local); the factories return a driver only when they can.
- `AnswerAsk` with an unknown reference is a no-op (the runtime ignores a stale
  `approve`).

## Error Handling

- **Connection lost** → the driver marks itself detached; the next `StartTurn`
  reconnects (connect-or-spawn). A send that fails mid-turn surfaces as the
  runtime's `detached` event, which the app renders as an error block.
- **Spawn failure** → `RemoteDriver` returns nil with a message; `tui-agent`
  reports it and exits.

## Testing Requirements

### Unit Tests

- [ ] `TestLocalDriverEmitsUserMessageAndDone` - the local driver synthesises
      `teUserMessage` and forwards the worker's events.
- [ ] `TestLocalDriverAnswerAskResolvesGate`.

### Integration Tests

- [ ] `TestRemoteDriverRendersATurn` - a real runtime, a remote driver, a
      scripted app drain; the assistant text and `teDone` arrive.
- [ ] `TestRemoteDriverApprovalRoundTrip` - an ask reaches the driver and the
      choice unblocks the turn.
- [ ] `TestRemoteDriverInterrupt` - `Interrupt` cancels the live turn.
- [ ] `TestRemoteDriverReconnectsAfterRuntimeExit` - after the runtime exits, a
      `StartTurn` reconnects and runs.
- [ ] `TestAppRemoteTurnRenders` - the app over a remote driver renders a turn
      identically to the local path.

## Performance Targets

- No change to the frame budget; the UI drains a queue as before.

## Security Considerations

- The socket is `0700` in the runtime directory; the TUI is same-user only.
- The API key stays in the runtime process; the TUI never holds it (the spawned
  runtime reads it from the environment).

## Success Criteria

### Functional

- [ ] `make tui-agent` attaches to a runtime; a second client (CLI or TUI) sees
      the same session.
- [ ] The runtime survives the TUI exiting.
- [ ] `make check` passes.

### Quality

- [ ] The app tests still pass on the local driver.
- [ ] No leaks with a runtime, a client, and the UI running.

## Future Considerations

- The TUI as a *second* window on a session a CLI is driving (observe mode in the
  UI).
- Subagent sessions shown in the UI (a child session per subagent).
