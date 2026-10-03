# Component Specification: Live Turn Control v1

**Related Feature:** `FEATURE.md` (Live Turn Control)

## Purpose

Six refinements to the live loop, in three groups:

- **Control** - a cancel honoured mid-stream (before the provider answers), and
  a prompt queue that injects context at loop boundaries.
- **Approval** - the model's reason in the dialog, and wrapping/compaction so
  long tool details do not blow up the dialog.
- **Compose** - Shift+Enter to submit (Ctrl+Enter fallback), bracketed paste, and
  a primary-action CTA.

## Requirements

### Functional

Immediate cancel

- [ ] A cancel issued while the first request is streaming stops the turn at
      once, without waiting for the response to complete.
- [ ] The aborting turn keeps its `turns` row with status `tsCancelled` and
      **no messages** (the user prompt, streamed text, and reasoning are gone).
- [ ] The last user prompt is prepended to the compose text.
- [ ] A cancel after an assistant message has been committed (a tool call was
      made) falls back to the loop-boundary cancel: messages are kept and the
      turn is `tsCancelled`.
- [ ] The two-escape gesture is unchanged.

Prompt queue

- [ ] While a turn is in flight, Shift+Enter enqueues the compose text and
      clears the box; Shift+Enter with no turn in flight submits as usual.
- [ ] The loop drains the queue at each boundary before building a request, and
      appends the queued prompts as user messages (multiple, in order).
- [ ] If a request returns tool calls and the queue is non-empty, the assistant
      tool-call message (and its reasoning block) is dropped, no tool is
      executed, and the queued prompts are appended instead.
- [ ] If the loop reaches a stop with prompts still queued, a new turn begins
      immediately with those prompts.

Approval reason

- [ ] `TApprovalAsk` carries the model's `reason`; the dialog draws it beneath
      the title, labelled `reason:`.

Wrapping and compaction

- [ ] The dialog's details wrap to the inner width and use the compact helper
      when long.
- [ ] The dialog is clamped to the screen minus 4 columns and 4 rows.

Compact content

- [ ] A shared unit trims leading/trailing blank lines; >10 trimmed lines
      render as first 2, `...`, last 3.

Compose

- [ ] Shift+Enter or Ctrl+Enter submits; Enter inserts a newline.
- [ ] Bracketed paste is enabled for the run; a paste inserts literally and
      never submits.
- [ ] The CTA at the bottom right reflects state (none / `shift+enter send` /
      `esc cancel`) with the key muted and the action in the accent.

Reason length and live thinking (trial follow-up)

- [ ] Every tool schema advertises `maxLength` on the `reason` property.
- [ ] A block title is truncated with an ellipsis when it does not fit, keeping
      the rule and the collapse mark.
- [ ] Streaming reasoning shows a live `Thinking...` block with the last six
      lines (prefixed with `...` when longer); it settles to a collapsed
      `Thought` block when the reasoning is done.

### Non-Functional

- [ ] Leak-clean; `make check` green.
- [ ] The queue is safe across the worker/UI boundary.
- [ ] No idle CPU or per-frame cost added.

## Contracts & Interfaces

### Compact content (`hildegard.helper.tui.compact`, new)

```pascal
type
  TCompactOptions = record
    MaxLines: Integer;    // <= this: unchanged; default 10
    HeadLines: Integer;   // default 2
    TailLines: Integer;   // default 3
  end;

function DefaultCompactOptions: TCompactOptions;
{ Trim leading/trailing blank lines. If more than MaxLines remain, return
  HeadLines, a '...' line, then TailLines. Otherwise return the trimmed text. }
function CompactLines(const AText: UnicodeString;
  const AOptions: TCompactOptions): UnicodeString;

{ Trim blank edges, then keep the last AMaxLines; a '...' line is prepended
  when there is more above. }
function TailLines(const AText: UnicodeString; AMaxLines: Integer): UnicodeString;
```

### Chat (`hildegard.helper.tui.chat`)

```pascal
type
  TChatItem = class(TWidget)
    { A live block shows TailLines(FBody, 6) and cannot be toggled; it settles
      into a normal block when the stream ends. }
    property Live: Boolean read FLive write SetLive;
  end;
```

### Agent (`hildegard.helper.agent`)

```pascal
const
  { Advertised as maxLength on every tool's reason property. }
  ToolReasonMaxLength = 120;
  DefaultSoftToolLimit = 30;
  DefaultHardToolLimit = 50;
  DefaultToolNoticeStep = 5;
  DefaultMaxContextTokens = 120000;

type
  TAgentConfig = record
    ...
    SoftToolLimit: Integer;     // nudge from here
    HardToolLimit: Integer;     // lockdown at this many
    ToolNoticeStep: Integer;    // nudge every this many after the soft limit
    MaxContextTokens: Integer;  // latest prompt tokens; negative disables
  end;
```

The loop counts tool-call rounds. At the soft limit and every `ToolNoticeStep`
calls after it, and at the hard limit, it intercepts the round: it does not run
the tools, answers each call with a paired notice result, and re-queries. One
round past the hard limit fails the turn with `leLoop`. The running context (the
latest request's prompt tokens) is checked each round.

### LLM (`hildegard.helper.llm`)

```pascal
type
  TLLMErrorCode = (..., leProvider, leCancelled, leLoop);
```

### Approval (`hildegard.helper.approval`)

```pascal
type
  TApprovalAsk = record
    Summary: string;
    Reason: string;          // the model's stated reason, '' when absent
    Subject: TApprovalSubject;
    Options: TApprovalOptionArray;
  end;
```

The reason is the call's `reason` argument, already parsed by
`ExtractToolReason` in `hildegard.helper.agent`. Each approvable tool
(`command.tool`, `files`) fills `Reason` in its `ApprovalAsks`.

### Approval modal (`hildegard.helper.tui.approvalmodal`)

Rows, top to bottom: title, `reason:`, details (sunken, wrapped/compacted),
blank, options, scope, separator, actions. `Measure` clamps to `AAvail - 8` in
both dimensions and keeps `MinWidth = 55`.

### Compose (`hildegard.helper.tui.compose` / `.edit`)

```pascal
type
  TCtaKind = (ckNone, ckSend, ckCancel);

  TComposeBox = class(TWidget)
    ...
    property Cta: TCtaKind read FCta write SetCta;
  end;
```

`HandleEvent`: Enter with Shift or Ctrl submits; a bare Enter falls through to
the editor as a newline. `ikPaste` inserts text literally. The CTA renders on
the info row: the key in `Muted`, the action in `Accent`, right-aligned.

### Input (`hildegard.helper.tui.input` / `.input.decode` / `.input.terminal`)

```pascal
type
  TInputEventKind = (ikKey, ikMouse, ikPaste);
  TInputEvent = record
    ...
    Text: UnicodeString;     // ikPaste payload
  end;
```

The decoder recognises `ESC [ 200 ~ ... ESC [ 201 ~` and emits one `ikPaste`.
The terminal source writes `ESC [ ? 2004 h` on start and `ESC [ ? 2004 l` on
stop.

### Agent (`hildegard.helper.agent`)

```pascal
type
  TPromptQueue = class
    procedure Push(const AText: string);        // thread-safe
    function Drain: TStringArray;               // thread-safe, empties
    function Pending: Boolean;
  end;

  TAgentLoop = class
    ...
    property PromptQueue: TPromptQueue read FPromptQueue;
  end;

  IConversationStore = interface
    ...
    { Drop every message the open turn appended, keeping the turn row. }
    procedure DropTurnMessages(ATurnId: Int64);
  end;
```

`DoSend` becomes a loop over turns: drain before each request; when a response
with tool calls arrives and the queue is non-empty, keep no response for it and
drain instead (the tool call is superseded); after a stop, begin a new turn if
the queue is non-empty.

### Cancel (`hildegard.helper.llm`)

```pascal
type
  TLLMCancelCheck = function: Boolean of object;

  TLLMTransport = class
    function PostStream(..., out AStatusCode: Integer; out AError: string;
      out ACancelled: Boolean): Boolean; virtual; abstract;
  end;

  TLLMClient = class
    property CancelCheck: TLLMCancelCheck read FCancel write FCancel;
  end;
```

The transport checks the callback between stream reads; when it fires it returns
`ACancelled = True` and the client returns `leCancelled`. The loop sets
`FClient.CancelCheck` before each request.

When the cancel lands before any response has been committed, the loop drops the
turn's messages (keeping the `tsCancelled` row) and records `LastTurnDropped`;
the worker puts that on the `teError` event as `Dropped`. A queued prompt
injected mid-flight is reported as `tePromptQueued`.

### Turn worker / app (`hildegard.helper.harness.turn` / `.harness.app`)

```pascal
type
  TTurnWorker = class(TThread)
    procedure QueuePrompt(const AText: string);
    property Queue: TPromptQueue;
  end;

  THarnessApp = class
    ...
    procedure Submit(const AText: string);   // enqueue when busy
  end;
```

On `leCancelled` with no committed assistant message, the app removes the user
block, restores the prompt to the compose (prepended), and leaves the turn row
`tsCancelled` with no messages.

## Architecture

### Prior Art & Reuse

- `TTurnWorker.RequestCancel`, the cancel check, and `tsCancelled` exist; the
  stream just needs to consult the same check.
- `TTurnQueue`/`TTurnWorker` already bridge worker and UI; the prompt queue rides
  the same ownership.
- `TTextEdit` already inserts text; `ikPaste` reuses it.
- `TApprovalAsk`, `ExtractToolReason`, and the modal exist; the reason is one
  field.
- `TTextBlock` already wraps; the modal uses it for details.

### Component Boundaries

- **compact** owns trimming and elision.
- **approval** carries the reason; **command.tool**/**files** populate it.
- **approvalmodal** owns the layout, wrapping, and clamping.
- **compose**/**edit** own submit keys, paste insertion, and the CTA.
- **input** owns bracketed paste.
- **agent** owns the queue drain, the dropped tool call, and the cancel outcome.
- **harness.app** owns enqueue-vs-submit and the cancel UI rollback.

### Data Flow

1. Shift+Enter in-flight → `TTurnWorker.QueuePrompt` → `TPromptQueue`.
2. The loop drains before a request; or, before a tool call, drops the assistant
   message and drains instead.
3. A stop with a non-empty queue opens a new turn.
4. A mid-stream cancel fires the transport check → `leCancelled` → the agent
   drops the turn's messages (keeping the row) → the app restores the prompt.

## Validation Rules

- Compaction counts trimmed lines; a blank interior line is preserved.
- A dropped tool call never leaves an orphaned result.
- The CTA is never drawn while the box is idle and empty.
- Bracketed paste is disabled on every exit path.

## Error Handling

- A cancel is `leCancelled`, not an error; no error block is drawn or stored.
- A paste with no active editor is ignored.
- A dropped response with no assistant message is a no-op.

## Testing Requirements

### Unit Tests

- [ ] `TestCompactLeavesShortText` (10 lines unchanged).
- [ ] `TestCompactElidesLongText` (2 + `...` + 3).
- [ ] `TestCompactTrimsBlankEdges`.
- [ ] `TestCompactPreservesInteriorBlanks`.
- [ ] `TestApprovalAskCarriesReason`.
- [ ] `TestModalShowsReasonUnderTitle`.
- [ ] `TestModalWrapsLongDetails`.
- [ ] `TestModalCompactsVeryLongDetails`.
- [ ] `TestModalKeepsEdgePadding`.
- [ ] `TestShiftEnterSubmits`.
- [ ] `TestCtrlEnterSubmits`.
- [ ] `TestPlainEnterInsertsNewline`.
- [ ] `TestPasteInsertsLiterallyWithoutSubmit`.
- [ ] `TestCtaStates` (none/send/cancel).
- [ ] `TestDecoderEmitsPaste`.
- [ ] `TestQueueDrainsBeforeRequest`.
- [ ] `TestQueuedPromptDropsToolCall`.
- [ ] `TestQueuedPromptsStartNextTurn`.
- [ ] `TestEarlyCancelDropsMessages`.
- [ ] `TestLateCancelKeepsMessages`.
- [ ] `TestCancelledTurnKeepsRow`.

### Integration Tests

- [ ] `TestCancelMidStream` (fake transport blocks, cancel fires).
- [ ] `TestEnqueueWhileBusy` (app: in-flight Shift+Enter queues).
- [ ] `TestCancelRestoresPrompt`.

## Performance Targets

- Compaction is O(lines); the queue is a lock plus a slice move; no per-frame
  cost.

## Security Considerations

- None new; the queue carries operator text only.

## Success Criteria

### Functional

- [ ] A prompt can be cancelled before the provider answers and is restored.
- [ ] Context can be injected mid-loop and drops an about-to-run tool call.
- [ ] The dialog shows the reason and stays within the screen.
- [ ] Shift+Enter submits, paste is safe, the CTA reflects state.

### Quality

- [ ] `make check` green; no leaks.

## Future Considerations

- A visible queue and editing of queued prompts.
- A configurable submit binding.
- Transport-level socket abort for an instant cancel.
