# Component Specification: Harness UI v1

**Related Feature:** [FEATURE.md](FEATURE.md) (section "Application: Harness UI (v1)")

## Purpose

Harness UI is the application that binds the TUI Core toolkit
(`TUI_Core_v1.SPEC.md`) to the agent loop and the store: a prompt editor, a
streaming conversation pane, tool-activity lines, an approval modal, and durable
session persistence. It is the full-screen counterpart to `examples/agent_cli.pas`
and shares the same configuration and trust model.

The defining constraint is that the agent runs off the UI thread, so there is a
clear seam between the worker (network, tools, agent loop) and the UI (widgets,
input, rendering): a thread-safe event queue plus an approval bridge.

## Requirements

### Functional

- [ ] Prompt editor: single line, cursor editing, Enter submits, Up/Down history.
- [ ] A submitted prompt is echoed into the conversation and starts a turn.
- [ ] Assistant text and reasoning stream in incrementally while the turn runs.
- [ ] Tool calls (name, model reason, arguments) and results render as labelled
      lines as they happen.
- [ ] Approval asks open a modal with the ask's options; the answer resolves the
      ask, persists the rule when the option persists, and the turn resumes.
- [ ] LLM/tool errors render as error lines; the prompt re-enables.
- [ ] The prompt re-enables on `teDone`.
- [ ] Session/ledger persistence when a store is configured; in-memory otherwise.
- [ ] Resume renders prior messages before the first new turn.
- [ ] Quit mid-turn denies pending asks, joins the worker, restores the terminal.
- [ ] The UI stays interactive (scroll, resize, quit) throughout a turn.

### Non-Functional

- Performance: input-to-visible < 50 ms while streaming; >= 60 fps; the queue is
  drained fully once per `Step`, then a single frame is rendered.
- Reliability: the worker is always joined and freed; leak-clean under
  `make test-leak`.
- Portability: macOS and Linux; `cthreads` first on Unix; no new dependency.

## Contracts & Interfaces

> Pascal types only; the implementer decides the bodies. Callbacks state the
> thread they fire on.

### Turn events and queue

Unit: `hildegard.helper.harness.turn`.

```pascal
type
  TTurnEventKind = (
    teUserMessage,      // the submitted prompt, echoed back
    teAssistantDelta,   // a chunk of assistant text
    teReasoningDelta,   // a chunk of reasoning text (display-only)
    teToolCall,         // a tool call was dispatched
    teToolResult,       // a tool returned
    teApprovalAsk,      // the worker is blocked awaiting an answer
    teDone,             // the turn completed successfully
    teError             // the turn failed
  );

  TTurnEvent = record
    Kind: TTurnEventKind;
    Text: string;              // message/delta/result text; error message
    Answer: string;            // final assistant text (teDone)
    Detail: string;            // error detail
    ToolId: string;
    ToolName: string;
    ToolArguments: string;     // raw JSON arguments
    ToolReason: string;        // the model's reason ('' when absent/invalid)
    ToolOk: Boolean;           // teToolResult
    RequestId: Integer;        // teApprovalAsk; 0 otherwise
    Ask: TApprovalAsk;         // teApprovalAsk
    ErrorCode: TLLMErrorCode;  // teError
    ElapsedMs: Int64;          // teDone/teError
  end;

  { Thread-safe FIFO. Push from the worker; Pop from the UI thread. Unbounded;
    a turn's output bounds its memory in practice (see Risks). }
  TTurnQueue = class
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(const AEvent: TTurnEvent);
    function Pop(out AEvent: TTurnEvent): Boolean;
    function IsEmpty: Boolean;
  end;
```

### Approval bridge

```pascal
type
  { Bridges the worker's approval prompt to the UI thread. The worker's Ask
    blocks; the UI thread only ever Answers or Cancels (never blocks). At most
    one ask is pending at a time. }
  TApprovalGate = class
  public
    constructor Create(AQueue: TTurnQueue; ATimeoutMs: Integer = 0);
    destructor Destroy; override;

    { Worker thread. Posts teApprovalAsk (with a fresh RequestId) and waits for
      Answer/Cancel, or until ATimeoutMs elapses (then denies). }
    function Ask(const AAsk: TApprovalAsk): TApprovalChoice;

    { TApprovalPrompt-compatible; passes through to Ask. Wire into
      TApprovalService.Create so command approvals reach the UI. }
    function Prompt(const AAsk: TApprovalAsk): TApprovalChoice;

    { UI thread. Resolve the pending ask and unblock the worker. Ignored when
      ARequestId is not the pending ask. }
    procedure Answer(ARequestId: Integer; const AChoice: TApprovalChoice);

    { UI thread. Deny any pending ask and unblock the worker (used on quit). }
    procedure Cancel;
  end;
```

### Turn worker

```pascal
type
  { Runs one TAgentLoop.Send on a worker thread, translating its events into
    TTurnEvents on the queue. Owned by the app; always joined before freeing. }
  TTurnWorker = class(TThread)
  protected
    procedure Execute; override;
  public
    constructor Create(ALoop: TAgentLoop; AQueue: TTurnQueue;
      const AUserText: string);
    { UI thread. Requests cancellation. Best-effort: the loop is synchronous
      and the transport has no cancel hook, so the worker stops after the
      current stream completes or the read timeout fires. }
    procedure RequestCancel;
  end;
```

### Harness session (config, bootstrap, ownership)

Unit: `hildegard.helper.harness.session`.

```pascal
type
  THarnessSessionConfig = record
    WorkspacePath: string;        // '' => process working directory
    StorePath: string;            // '' => in-memory, no persistence
    SessionId: string;            // '' => create new (store) or ephemeral
    Resume: Boolean;              // require SessionId to exist when True
    Model: string;                // '' => resolved from env/.env
    Endpoint: string;             // '' => resolved from env/.env
    SystemPrompt: string;         // '' => DefaultSystemPrompt (as the CLI)
    MaxToolIterations: Integer;   // 0 => DefaultMaxToolIterations
  end;

  { Owns the whole agent-side object graph for one UI run: workspace, optional
    store, conversation store, LLM client, tool registry (builtins +
    run_command), approval service, turn queue, approval gate, and agent loop.
    Not thread-safe; the app uses Queue/Gate across the thread boundary only. }
  THarnessSession = class
  public
    { Resolves config, opens the workspace and optional store, ensures the
      workspace and session, builds the tools/approvals/loop. Returns nil with
      AError on failure. }
    class function Open(const AConfig: THarnessSessionConfig;
      out AError: string): THarnessSession;
    destructor Destroy; override;

    property Loop: TAgentLoop read FLoop;
    property Queue: TTurnQueue read FQueue;
    property Gate: TApprovalGate read FGate;
    property SessionId: string read FSessionId;
    property WorkspaceRoot: string read FWorkspaceRoot;
    property Store: TSqliteStore read FStore;   // nil when unconfigured

    { Prior messages for the initial render (empty for a new session). }
    function History: TChatMessageArray;

    { Cancel pending approvals; frees owned objects. Idempotent. }
    procedure Close;
  end;
```

### Prompt editor

Unit: `hildegard.helper.tui.prompt`.

```pascal
type
  TPromptSubmittedEvent = procedure(const AText: string) of object;

  { A single-line editor with a visible cursor and history. Handles printable
    keys, Backspace/Delete, Home/End, Left/Right, Up/Down (history), Enter
    (submit). Inactive: ignores keys and renders dimmed. }
  TPromptLine = class(TWidget)
  public
    constructor Create(const APrompt: string = '> ');
    procedure SetActive(AValue: Boolean);
    procedure Clear;
    procedure AddHistory(const AText: string);
    function Text: string;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;

    property Active: Boolean read FActive write SetActive;
    property Prompt: string read FPrompt write FPrompt;
    property Attr: TAttr read FAttr write FAttr;
    property OnSubmit: TPromptSubmittedEvent read FOnSubmit write FOnSubmit;
  end;
```

### Conversation view

Unit: `hildegard.helper.tui.conversation`.

```pascal
type
  { A scrolling, styled transcript with sticky-to-bottom behaviour: it follows
    new content unless the user has scrolled up, and resumes following when they
    return to the bottom. Composes a TTextBlock inside a TScrollContainer. }
  TConversationView = class(TWidget)
  public
    constructor Create;
    destructor Destroy; override;
    procedure Append(const AText: UnicodeString; const AAttr: TAttr);
    procedure AppendSpans(const ASpans: array of TSpan);
    procedure Clear;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;
```

### Approval modal

Unit: `hildegard.helper.tui.approvalmodal`.

```pascal
type
  TApprovalChoiceEvent = procedure(const AChoice: TApprovalChoice) of object;

  { A modal for one TApprovalAsk. Up/Down (or number keys 1..n) select; Enter
    confirms; Escape denies; Tab (or g/w/s) cycles the persist scope. Answering
    fires OnChoose once and sets Answered. }
  TApprovalModal = class(TWidget)
  public
    constructor Create(const AAsk: TApprovalAsk);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;

    property Ask: TApprovalAsk read FAsk;
    property Answered: Boolean read FAnswered;
    property Choice: TApprovalChoice read FChoice;
    property OnChoose: TApprovalChoiceEvent read FOnChoose write FOnChoose;
  end;
```

### Application assembly

Unit: `hildegard.helper.harness.app`. `examples/tui_agent.pas` is a thin entry
point: create surface, input source, session, and `THarnessApp`; run.

```pascal
type
  { Builds the widget tree (conversation, activity/status, prompt), drains the
    turn queue each Step, routes approval asks to a modal, and starts a worker
    per submitted prompt. Owns the TTuiApp and the current worker. }
  THarnessApp = class
  public
    constructor Create(const ASurface: ISurface; const AInput: IInputSource;
      ASession: THarnessSession);
    destructor Destroy; override;

    { One iteration: pop an answered approval modal and surface the next queued
      ask, drain all queued turn events (rendering once), then run TTuiApp.Step.
      Returns False once stopped. Also stops on TInputSourceTerminal.Terminated. }
    function Step: Boolean;
    procedure Run;
  end;
```

## Architecture

### Prior Art & Reuse

- `hildegard.helper.tui.app` (`TTuiApp`, `TPlane`) - plane stack, modal trap and
  dim, `Step`, `Invalidate` (replaces the demo's hand-rolled loop).
- `hildegard.helper.tui.text` (`TTextBlock`, `TSpan`) - styled, width-correct
  text; the conversation view wraps it rather than re-implementing wrapping.
- `hildegard.helper.tui.scroll` (`TScrollContainer`) - clipping and scrollbar;
  reuse for the conversation.
- `hildegard.helper.tui.widget` (`TContainer`, tracks) - layout; no new engine.
- `hildegard.helper.agent` (`TAgentLoop`, `TToolRegistry`, `IConversationStore`)
  and `hildegard.helper.llm` (`TLLMClient`, `TChatMessage`) - the worker body.
- `hildegard.helper.approval` (`IApprovalService`, `TApprovalService`,
  `TApprovalAsk`, `TApprovalChoice`) and `.approval.store` - approval rules; the
  gate only bridges the prompt across threads.
- `hildegard.helper.store` (`TSqliteStore`, `EnsureWorkspace`, `CreateSession`,
  approvals, ledger) and `hildegard.helper.session.store`
  (`TSqliteConversationStore`) - persistence; reuse, do not reimplement.
- `hildegard.helper.workspace` (`TWorkspace.Open`) and `hildegard.helper.env`
  (`LoadDotEnvFile`) - workspace identity and `.env`; the same resolution as
  `examples/agent_cli.pas`.
- `hildegard.helper.command.tool` (`TCommandTool`, `IExecutor`) and
  `hildegard.helper.process` (`TCommandRunner`) - the shell tool.
- `hildegard.helper.input.terminal` - the SIGTERM `Terminated` flag is surfaced by
  the app so a signal still exits through the normal path.

Gap designed here: the thread-safe event queue + approval gate, the prompt-line
editor, the conversation view's append/follow, the approval modal, and the
session/app assembly. `examples/agent_cli.pas` contains a working bootstrap of
the same object graph; `THarnessSession` is the shared extraction so the CLI and
the TUI do not drift (see Component Boundaries).

### Component Boundaries

- **`harness.turn`** owns the queue, gate, and worker. It knows nothing about
  widgets. It depends on `agent`, `llm`, `approval`.
- **`harness.session`** owns the object graph and configuration resolution. It
  knows nothing about widgets. It depends on `agent`, `llm`, `store`,
  `approval`, `workspace`, `command.tool`, `env`.
- **`tui.prompt` / `tui.conversation` / `tui.approvalmodal`** are pure widgets;
  they depend only on the (terminal-free) TUI Core.
- **`harness.app`** is the only unit that knows both; it depends on the above and
  `tui.app`. It owns the `TTuiApp` and the active worker.
- **`examples/tui_agent.pas`** is the only place that touches a real terminal.

No unit under `harness.*` links `video`/`termio`; only the example does, mirroring
the toolkit/yadapter split.

### Data Flow

1. **Submit.** `TPromptLine.OnSubmit` -> `THarnessApp` echoes the prompt
   (`teUserMessage` locally), disables the prompt, and creates a `TTurnWorker`.
2. **Work.** The worker calls `TAgentLoop.Send` with callbacks that `Push`
   `teAssistantDelta`/`teReasoningDelta`/`teToolCall`/`teToolResult`, then
   `teDone`/`teError`.
3. **Approval.** A `run_command` ask reaches `TApprovalService`, whose prompt is
   `TApprovalGate.Prompt`; the worker blocks while the gate posts
   `teApprovalAsk`. The UI renders a modal and calls
   `Gate.Answer(RequestId, Choice)`; the worker resumes. Asks are shown **one at
   a time**: a second ask that arrives while a modal is open is queued and shown
   once the current one is answered.
4. **Drain.** Each `THarnessApp.Step` drains the queue, appends to the
   conversation/activity, routes asks, then renders exactly one frame.
5. **Complete.** `teDone`/`teError` re-enable the prompt and free/join the worker.

### Integration Patterns

- **Threads.** One worker per turn, created on submit, `FreeOnTerminate = False`,
  joined with `WaitFor` before `Free`. `cthreads` is first in the example. The UI
  thread never blocks on the worker except during quit.
- **Queue.** A dynamic array behind a `TCriticalSection` (project convention;
  `TSemaphore` is unusable on macOS). `Push` is O(1) amortised; `Pop` from the
  head. Drain-until-empty each `Step`.
- **Gate.** One pending ask guarded by a `TCriticalSection` plus a
  `TSimpleEvent`. `Ask` records the request id, pushes the event, then
  `WaitFor`; `Answer`/`Cancel` set the choice and signal. `TimeoutMs = 0` means
  wait indefinitely (the UI is the only watcher); `Cancel` on quit guarantees
  release.
- **Ownership.** `THarnessSession` owns the store, client, registry, approval
  objects, queue, and gate. `THarnessApp` owns the `TTuiApp`, widgets, and the
  current worker. `TTurnWorker` owns only its stack and its `TChatResult`.
- **Cancellation.** Best-effort: `RequestCancel` sets a flag checked before/after
  the send; the blocking HTTP stream is not interrupted (see Risks).

## Validation Rules

### Input

- Empty or whitespace-only prompts are ignored (no turn, no history entry).
- History navigation clamps to the available entries; editing after recall does
  not mutate history.
- Cursor movement is by grapheme cluster and clamps to `[0, Length]`.
- `THarnessSessionConfig` with `Resume = True` and no/invalid `SessionId` fails
  with a clear error, not a new session.
- `StorePath` that cannot be opened fails `Open` with an error (the app shows it
  and exits); it does not silently fall back to memory.

### Output Guarantees

- Exactly one `teDone` or `teError` terminates a turn's event stream.
- `teApprovalAsk.RequestId` is unique per turn; `Answer` with an unknown id is a
  no-op.
- Every submitted prompt appears once as `teUserMessage` before any assistant
  event.

## Error Handling

### Error Types

- **Config/validation:** missing API key/model, bad workspace, unopenable store -
  reported by `THarnessSession.Open` via `AError`; the app surfaces it.
- **LLM/system:** `TLLMError` (`leNetwork`, `leHttpStatus`, `leAuth`,
  `leRateLimit`, `leMalformedStream`, `leProvider`) -> `teError`.
- **Tool:** a failed tool call -> `teToolResult` with `ToolOk = False`.
- **Approval:** deny/cancel -> the tool call is refused and the loop continues.

### Error Contracts

```pascal
type
  { Session bootstrap failure. Message is user-facing. }
  TSituationError = record
    Message: string;
    Detail: string;
  end;
```

The harness follows existing codes where a code is meaningful (`0` success,
`124` timeout, `128 + signal`, `130` cancelled). Turn errors carry the
`TLLMErrorCode`; store errors carry `TStoreError`.

## Testing Requirements

> What to test. Widgets are exercised against `TSurfaceMemory` and
> `TInputSourceScripted`; the worker against a canned `TLLMTransport`.

### Unit Tests

- [ ] `TTurnQueue`: FIFO order, empty/pop semantics, concurrent push/pop under a
      stress test, no leaks.
- [ ] `TApprovalGate`: `Ask` blocks until `Answer`; `Cancel` denies and releases;
      `Answer` with a stale id is a no-op; timeout denies.
- [ ] `TTurnWorker`: with a canned stream, emits deltas in order then `teDone`;
      a provider error emits `teError`; tool call/result events carry name,
      reason, and ok; `RequestCancel` stops before the next turn; joined cleanly.
- [ ] `THarnessSession`: in-memory config builds a loop with the builtins plus
      `run_command`; store config ensures workspace/session and `History` round
      trips; `Resume` with a bad id fails.
- [ ] `TPromptLine`: typing, Backspace/Delete, Home/End, Left/Right by cluster,
      Up/Down history, Enter fires `OnSubmit` with the text and clears.
- [ ] `TConversationView`: append renders styled spans; follows the bottom on
      append; stops following after the user scrolls up and resumes at the
      bottom; `Clear`.
- [ ] `TApprovalModal`: renders the summary and options; Up/Down and number keys
      select; Enter fires `OnChoose` with the matching option; Escape denies; a
      zero-option ask denies safely.
- [ ] `THarnessApp`: a scripted turn drives the tree - prompt echo, streamed
      assistant text appears, a tool line appears, an approval ask opens a modal
      and answering resumes the turn, `teDone` re-enables the prompt, `teError`
      shows an error line.

### Integration Tests

- [ ] `run_command` approval end to end: a scripted approval service backed by the
      gate; allow persists a rule (store), deny refuses; the second identical
      call is auto-allowed.
- [ ] Resume: append messages to a store session, open with `Resume`, and confirm
      `History` renders in order.
- [ ] Deterministic render: draining N queued events in one `Step` renders exactly
      one frame with proportionally changed cells (uses `TSurfaceMemory`).

### Thread/Leak Tests

- [ ] Quit mid-turn (with a blocked approval) joins the worker and frees every
      owned object; `make test-leak` clean.

## Performance Targets

- Input-to-visible latency < 50 ms while streaming; >= 60 fps in an 80x50 frame.
- A batch of streamed deltas drained in one `Step` renders one frame, not one per
  event.
- No per-frame heap growth beyond a small tolerance at a fixed size.

## Security Considerations

- The API key is read from the environment/`.env` only; never a flag, never
  logged, never written to the ledger. The session must not render credentials.
- The tool surface and approval rules are exactly the CLI's: `run_command` is
  gated by the same per-scope rules; a non-interactive/absent prompt denies.
- The workspace remains the trust boundary for relative paths (reused
  `TWorkspace`).
- The ledger stores conversation content; the store path is caller-chosen and
  documented (as the CLI).

## Success Criteria

### Functional

- [ ] All contracts implemented; all validation rules enforced; all error paths
      handled.
- [ ] Every acceptance criterion in the FEATURE maps to at least one test.
- [ ] `make check` passes (tests + leak gate).
- [ ] `examples/tui_agent.pas` demonstrates a live streaming turn, tool lines, a
      real approval modal, quit-mid-turn, and resume.

### Quality

- [ ] The UI thread never blocks on network/tools/approvals (verified by a
      blocking-approval test that keeps stepping).
- [ ] No memory leaks; the worker is always joined.
- [ ] Documentation (this SPEC + the example header) is complete.

## Future Considerations

- Markdown rendering of model output once `Markdown_v1` lands.
- A file/diff viewport pane beside the conversation.
- Token pacing (`--max-tps` parity) and a cancel that interrupts the HTTP stream.
- Multiple concurrent turns / subagent panes.
- Splitting the widgets into their own SPEC if the surface grows.
