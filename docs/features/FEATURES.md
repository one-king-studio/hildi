# Features

Index of all features in hildegard-helper. Each feature lives in its own directory
under `docs/features/<Feature_Name>/` and follows the artifact chain described
in `../guidelines/spec-driven-development.md`:

`FEATURE.md` -> `<Component>_v1.SPEC.md` -> `<Component>_v1.TODO.md` -> `<Component>_v1.DONE.md`

## Status Key

- **Proposed** - `FEATURE.md` exists, no spec yet
- **Specified** - at least one `SPEC.md` exists
- **In Progress** - a `TODO.md` is being worked
- **Implemented** - all tasks done, `make check` green, `DONE.md` recorded

## Features

| Feature | Status | Specs | Notes |
| ------- | ------ | ----- | ----- |
| [Agent Loop](Agent_Loop/FEATURE.md) | In Progress | LLM Client v1, Agent Loop v1 | Single-threaded OpenAI-compatible loop with streamed SSE, injectable tools, and an in-memory multi-turn store. Code complete; live CLI verification pending. |
| [Command Tool](Command_Tool/FEATURE.md) | Superseded | Command Policy v1 (parser), Tool Reason v1 | Gated `run_command`. The parser, required `reason`, shell profile, and synchronous executor carry forward; the policy/approval/audit layers are replaced by Tool Approvals and Sessions and Ledger. |
| [File Tools](File_Tools/FEATURE.md) | In Progress | File Tools v1 | Approval-gated `file_read`, `file_write`, `file_edit`, `file_list`, `file_glob`, `file_grep` confined to the workspace, with bounded output. Registered by the TUI harness and the CLI; live smoke pending. |
| [TUI Widgets](TUI_Widgets/FEATURE.md) | Implemented | TUI Widgets v1 | A widget kit over TUI Core: `TSingleChild`/`TPanel`, `TTheme`, a focus group (`Tab`/click), and `TButton`/`TListView`. Adopted by the `tui_widgets_demo`. |
| [TUI Text Editing](TUI_Text_Editing/FEATURE.md) | Implemented | Text Edit v1 | A caret-aware multi-line editor (`TTextEdit`) over shared grapheme/width helpers: insert/delete, arrow navigation, soft wrapping, and a blinking caret. Reused by the chat compose box and, later, the editor panel. |
| [TUI Animation](TUI_Animation/FEATURE.md) | Implemented | TUI Animation v1 | One app-owned frame clock (default 10 ms); widgets derive content from time via `Advance(nowMs)`/`Animating`; one composite+diff per frame; idle waits on a long timeout. Clients: `TSpinner`, `TProgress`. |
| [Tool Approvals](Tool_Approvals/FEATURE.md) | In Progress | Approvals v1 | Generic, durable whitelist for tool calls: `ref` + `params`, scoped global/workspace/session; `run_command:<bin>` for the shell, `suite:function` for external tools. Supersedes the command policy and audit. Engine, persistence, command adapter, and CLI done; live smoke pending. Path gating dropped by decision. |
| [Workspaces](Workspaces/FEATURE.md) | Implemented | Workspaces v1 | The directory the agent operates in: canonical identity, access check, relative-path base, and the trust boundary for path checks; scopes approvals and sessions. |
| [Sessions and Ledger](Sessions_And_Ledger/FEATURE.md) | Implemented | Sessions v2, Turn Stats v1, Turn Stats v2 | Relational history: `sessions -> turns (loops) -> requests` and `sessions -> messages` (user, assistant, reasoning, tool call, tool, error). Token usage and timings per request, rolled up per turn; restore renders the streamed blocks (tool reasons and reasoning included). Turn Stats v1 renders the latest turn's metrics in the status bar (workspace left, stats right) with the hints in the CTA toolbar, identically live and resumed. Turn Stats v2 makes the status bar show the session's usage for cost (`total <ctx> ctx · <used> used · <cached>% cached · <time> · <req> req`: the final context, the billed total, the token-weighted cache hit, the wall time, and the request count), ends each successful loop with a dimmed divider of its metrics, and collects per-block reasoning/content durations so a thought reads `Thought for 2.3s` (live and resumed from the same measured value, carried as the `reasoning_done` event). The loop's context guard is overridable via `HILDEGARD_MAX_CONTEXT_TOKENS` until the model API supplies the limit. Supersedes the v1 flat ledger; a full schema reset with no data migrations. |
| [Remote Agent Link](Remote_Agent_Link/FEATURE.md) | Proposed | - | Pair a device to an account and hold an outbound link to execute requests locally. Helper-side only in v1. |
| [TUI Harness](TUI_Harness/FEATURE.md) | In Progress | TUI Core v1 (implemented, tested); Markdown v1 (implemented, tested); Markdown View v1 (implemented, tested); Markdown Tables v1 (implemented, tested); Harness UI v1 (implemented); Chat Panel v1 (implemented); Interrupt v1 (implemented); Approval Modal v1 (implemented); Session Header v1 (implemented) | Full-screen front end: nested grid layout, independently scrolling panes, modal overlay planes, and markdown-coloured text. Reuses FPC `video` plus RTL `termio`; no new deps. Reverses the earlier CLI-only/pager decision (the CLI is retained). Harness UI v1 wires the toolkit to the agent loop (worker thread + event queue, approval modal, SQLite sessions); Chat Panel v1 replaces its transcript with the designed conversation view (message blocks, overlay compose, stats/status lines); Interrupt v1 adds an Esc-Esc turn interrupt and the compose's Ctrl+U/Ctrl+C keys, with Ctrl+C quitting only when the box is empty; Approval Modal v1 redraws the dialog to the design and dims the whole screen behind it. Markdown v1 adds a pure parser (blocks of styled spans + theme) with an inert streaming tail; Markdown View v1 draws it as a vertical stack (bullets, quote bar, code backdrop, rule) without rebuilding finalised blocks, and assistant blocks in the chat stream now render through it. Markdown Tables v1 adds GFM pipe tables: a rounded grid drawn at its content width, which compresses and wraps its columns when the content is wider than the container. Run with `make tui-agent`. Session Header v1 puts the session id (left) and the context — tokens, a ten-cell shades bar, percentage — on the messages panel's top border; the status bar carries the workspace (left) and the session's consumption (right: billed in/out, cache hit, time, requests). A live terminal sign-off remains. |
| [Live Turn Control](Live_Turn_Control/FEATURE.md) | Implemented | Live Turn Control v1 | Refines the live loop from a TUI trial: immediate no-trace cancel that restores the prompt, a prompt queue injected at loop boundaries, the model's reason in the approval dialog, wrapping/compaction of long content, a Shift+Enter submit with bracketed paste and a primary-action CTA, a tool-call budget, and a live thinking tail. |
| [Response Continuation](Response_Continuation/FEATURE.md) | Implemented | Response Continuation v1 | The loop owns the in-flight response: on `finish_reason: length` it re-requests a followup and appends until a proper stop, committing the assembled response as one message. Persistence is ephemeral until a stop; on any other error the pending response is dropped and the live view rolls back its streamed blocks. A cut-off tool call is dropped, answered with a paired notice, and resubmitted. |
| [Local SQLite Store](Local_SQLite_Store/FEATURE.md) | Implemented | Store v1 | Embedded SQLite for credentials, request history, durable queue, and settings. Vendored 3.53.4. |
| [Context Budget](Context_Budget/FEATURE.md) | Implemented | Tool Output Budget v1 | Keeps the history faithful on disk while bounding what enters the prompt: an oversized tool result is stored in full as a session artifact and the prompt carries a truncated head plus a reference; `recall_tool_result` reads slices and caps but never spills. Depends on Sessions v2. |
| [Tool Streaming](Tool_Streaming/FEATURE.md) | Implemented | Tool Streaming v1 | One output seam every tool shares, RxJS-shaped: a tool may flush chunks through an observer (`next`) and complete with its authoritative result. `run_command` streams its stdout/stderr live (bounded by the output cap) and lets the model define its own timeout (an operator can cap it via `HILDEGARD_COMMAND_TIMEOUT_MS`); the other tools are single-shot. The stream crosses agent -> turn -> session protocol (`tool_output`) -> driver -> TUI, where the live block auto-expands its tail and settles to the result so live and resume match. |
| [Session Handoff](Session_Handoff/FEATURE.md) | Superseded | - | Superseded by [Headless Sessions](Headless_Sessions/FEATURE.md): the heartbeat lease, the pid/start-time impersonation guard, and the drain-on-handoff migration are dropped, because the loop no longer moves between processes. The drive lease and observe mode move there. |
| [Headless Sessions](Headless_Sessions/FEATURE.md) | Implemented | Session Protocol v1, Session Runtime v1, TUI Adoption v1 | A per-session headless process with a stable Unix socket: the agent loop runs detached, and clients (TUI/CLI/web) attach to a typed NDJSON event stream, replay the live turn, and map events to their own rendering. One driver, many observers; the socket bind is the lease and the liveness check; subagents are child sessions. v1 delivers the protocol, the runtime, the client library, and the CLI as the first client (`--attach [--drive]`); the TUI now drives a runtime too (`make tui-agent`, via a driver seam), so the loop leaves the UI process. The daemon and network transport wait for Remote Agent Link. |
| [Process Split](Process_Split/FEATURE.md) | Implemented | Process Split v1, Chat Window v1 | Two programs from the one binary: a headless agent (`make headless-agent`) that links no TUI unit, and a TUI client (`make tui-agent`) that links no agent/loop/tool/runtime unit, located by `HILDEGARD_RUNTIME_BIN` else a sibling of the TUI executable. The boundary is enforced by unit splits (`session.socket`/`.client`, `harness.view`, `harness.turn.worker`, `harness.driver.local`) and asserted by a test that walks the client roots' transitive `uses` closure. It also trims the bootstrap waste (the runtime no longer loads history; the client builds no LLM client or tools) and windows the chat list, which now materializes only the visible blocks plus an overscan — 700 blocks allocate ~0.75 MB and stay flat as the transcript grows, versus the 56 MB that retained every block's layout. |
| [Animation Clock](Animation_Clock/FEATURE.md) | Implemented | Animation Clock v1, Focus Reporting v1 | The TUI clock is demand-driven and focus-aware. A widget registers an animation with the frame interval it needs (`TWidget.SetAnimation`, backed by `TAnimationClock`); the clock runs at the fastest registered interval, the frame cadence while a turn streams, or the idle wait — instead of a fixed 100 Hz whenever anything reported `Animating`, discovered by walking the tree. The compose caret registers at ~250 ms (it blinks every 530 ms) and renders as a steady box when the compose is inactive; DECSET 1004 focus reporting (`CSI I`/`CSI O`) withdraws all animation when the terminal is unfocused, and `TChatStack` now reports `Animating` in O(1) with an animating-block count. Found while chasing idle CPU: a focused idle TUI was ~1–2% CPU for a 2 Hz blink. |
| [TUI Clipboard](TUI_Clipboard/FEATURE.md) | Proposed | - | Copy-out for the Harness TUI via OSC 52: targeted yank bindings (last assistant message first), graceful degradation, zero dependencies — the only mechanism that survives SSH. Arbitrary selection stays terminal-native (Shift/Fn+drag, tmux), now documented. |
| [TUI Syntax Highlighting](TUI_Syntax_Highlighting/FEATURE.md) | Specified | Syntax Highlighting v1 | Lexical highlighting for fenced code blocks (Pascal/shell first, then Python/JSON/SQL): a pure-function tokenizer driven by per-language rule tables, computed once per immutable block, themed via `TMdTheme`, zero dependencies. Vim-style keyword+delimiter scanning, not LSP or a regex engine — rejected in doc with rationale, and SynEdit recorded as design-only prior art (MPL/GPL). |
| [Approval Path Scoping](Approval_Path_Scoping/FEATURE.md) | Specified | Approval Path Scoping v1 | Extend the approval engine with directory (subtree-inclusive), extension, and combined (AND) match dimensions on file-tool rules — "allow .md writes under docs/" — plus a persistable `never` (deny). The tool declares the path on the subject; an additive v2 store migration rebuilds `approvals` for the extended UNIQUE; deny-wins preserved; session scope = per-agent gating. |
| [TLS Foundation](TLS_Foundation/FEATURE.md) | Implemented (**critical**) | TLS Foundation v1 | Replace runtime-`dlopen`'d OpenSSL (`opensslsockets`) with a vendored, statically linked mbedTLS (the SQLite pattern) behind FPC's `TSSLSocketHandler` seam — a small C shim over an opaque handle, a CA bundle embedded in the binary, and an offline loopback handshake test. Verified: a live HTTPS turn with no libssl/libcrypto loaded. Prerequisite for Remote Agent Link. |
| [Composed Tool Sandbox](Composed_Tool_Sandbox/FEATURE.md) | Proposed | - | A script tier that composes the harness's own gated tools: the model writes one JavaScript program that loops and chains `await tools.file_read(…)`-style calls, so a batch is one turn instead of N. Embeds GocciaScript (MIT, FPC-native ECMAScript) core-only with `TGocciaCapabilities.None`; the injected tools are the only reachable surface, each routing through the same gate, reason, audit row and snapshot interception as a direct call. No shell and no `recall` in the sandbox. Supersedes the earlier compute-only framing; the first task is a spike that measures the release-binary delta before a SPEC is written. |
| [Skills](Skills/FEATURE.md) | Implemented | Skills v1 | On-demand capabilities, shaped like Anthropic's Agent Skills: a manifest (name, description, when-to-use, **and loaded/unloaded state**) is always in the wrapped prompt; `load_skill(name)` activates a skill's instructions and tools; activation **decays by idle time** rather than per turn. No `list_available_skills` — availability is context. MCP is the first provider. |
| [Lazy MCP](Lazy_MCP/FEATURE.md) | Specified | Lazy MCP v1 | MCP servers connect **on load**, not at runtime startup. Today they connect before the socket is bound — ~2 s of blank TUI (measured) and a launch failure when a server is slow. A connection is a skill (`mcp_<id>`); loading it connects, discovers, and registers `mcp_<id>_<tool>` tools, kept alive by use and released on idle. |
| [TUI Startup](TUI_Startup/FEATURE.md) | Specified | TUI Startup v1 | The TUI paints a connecting frame **before** it connects to (or spawns) the runtime, and loads the transcript tail-first with **scroll-to-top back-pagination** (the same primitive `Context_Checkpoint` needs). The safety net for the blank-startup window; Lazy MCP removes the current ~2 s cause. |
| [Workspace Snapshots](Workspace_Snapshots/FEATURE.md) | Proposed | - | Per-turn workspace snapshots with a changed-files view and a diff view, plus undo/redo that walks the history and brings the files along with it. Self-contained on the vendored SQLite; no git dependency. Prior art: SynProject's `TVersions` (GPL-3, Windows-only — shape only). |
| [Async Core](Async_Core/FEATURE.md) | Implemented | Async Core v1 | A standalone, dependency-free Object Pascal library for async and reactive programming: **futures** (one async value) and **observables** (a stream) over **one spine** — scheduler, continuation-scoped context, cancellation. No event loop; a synchronous driver, the GocciaScript model. Concurrency is a scheduler choice (`RunOn`, `SubscribeOn`/`ObserveOn` over a bounded executor); the UI never awaits. The surface is free functions composed RxJS-style (`Pipe(src, [FilterOp(p), TakeOp(3)])`): creation, transform, filter, fan-in, flatten (`MergeMap`/`ConcatMap`/`SwitchMap`/`ExhaustMap`/`Expand`), combine (`Zip`/`CombineLatest`/`WithLatestFrom`), utility, aggregate, error, multicasting, and the full time set on the virtual clock. `TBoundedQueue` backs the real TUI's turn queue. FPC 3.3.1's incomplete generics cap the surface (see `FPC_Generics_Notes.md`); the container-returning family (`Buffer`/`Window`/`GroupBy`/`MergeAll`/`ForkJoin`) is the genuinely blocked set, tracked by `test_async_parity`. All ten phases done (`Async_Core_v1.DONE.md`); 1186 tests, leak-clean. No harness or engine dependency, so it is extractable. |
| [TUI Event Graph (RxPascal)](TUI_Event_Graph/FEATURE.md) | In Progress | TUI Event Graph v1 | The TUI is one drain on one thread — correct — but it drained **unbounded**, so a streaming `run_command` kept the UI inside `DrainQueue` and froze it. **v1 is implemented**: the drain is bounded per frame (256 events), the turn queue is a bounded `TBoundedQueue<TTurnEvent>` with O(1) push (control events are never dropped — a streamed event yields instead), the streamed tool output is coalesced per frame, and the live tool block is capped at 64 KiB. The direction is the whole TUI as an event graph on Async Core ("RxPascal"): sources are streams, state is a `Scan`, rendering is a frame-paced subscription — with a two-lane split (commands lossless, signals coalescible). |
| [Dynamic Tools](Dynamic_Tools/FEATURE.md) | Implemented | Tool Boundary v1, MCP Lifecycle v1 | A running session's MCP tool surface is dynamic: reconcile from the store at each turn boundary, with enable/disable/remove and reconnect (bounded backoff) for dropped servers. Adds `TAgentLoop.OnTurnStart`, `TToolRegistry.Remove`, and a per-server MCP lifecycle manager. Trust unchanged (every call stays approval-gated). |
| [Turn Injection](Turn_Injection/FEATURE.md) | Implemented | Turn Assembly v1, MCP Provider v1 | Assemble the loop's tools **and prompt** fresh each turn from registered contributors, so tools can load dynamically and skills can inject prompt + tools. Adds the `IToolProvider` seam (`Prepare`/`Specs`/`PromptFragment`/`Find`); MCP is one contributor. Prompt fragments are request-only (never persisted). |
| [Runtime Lifecycle](Runtime_Lifecycle/FEATURE.md) | Implemented | Runtime Shutdown v1 | The session runtime stops promptly and gracefully: an in-band `scShutdown` command, SIGTERM/SIGINT handling, and an exit-when-no-clients policy with a short grace. |

## Parked (ideated, awaiting a need)

- **Reasoning Doom Loop Detection** (`Doom_Loop_Detection/FEATURE.md`) — a
  signal-only detector over the reasoning stream: deflate-style backwards
  match pass of the tail against recent history, keeping the *parse*
  (coverage, max run, dominant period) as the diagnosis, with
  trend/period-band/arm-length false-positive guards. Soft response reuses
  notice interception; hard response reuses Interrupt v1. Tool-call loop
  detection (signature-based) is a separate, simpler future feature. Parked
  with the full design sketch in the doc.

- **MCP Client** (`MCP_Client/FEATURE.md`) — consume MCP servers' tools as
  first-class registry tools over stdio (a new bidirectional child manager, a
  JSON-RPC 2.0 client, `inputSchema`/result mapping, and a scoped SQLite
  config) — namespaced `mcp/<server>/<tool>` approval refs through the existing
  approvals/ledger/reason gates — zero special cases in the loop. Helper is
  MCP client, not server. **v1 (stdio) is implemented & tested** (see
  `MCP_Client/MCP_v1.DONE.md`); v2 (HTTP/OAuth) is parked pending a decision on
  the shared OAuth pipeline (Remote Agent Link specifies device pairing +
  bearer token, not OAuth). v1 is independent of that and of TLS. Full FEATURE
  doc and v1 SPECs in the directory.

- **Turn Lifecycle** (`Turn_Lifecycle/FEATURE.md`) — guarantee a turn always
  reaches a terminal state: reconcile orphaned `tsRunning` turns on runtime
  start, self-heal in `BeginTurn`, finalize the in-flight turn on client loss
  and shutdown, bound the approval wait, and repair a dangling tool call on
  resume. Fixes the non-stable session state (pending approvals, unresolved tool
  calls) that long-running commands make likely. Spec'd (v1); not yet
  implemented.

- **Context Checkpoint** (`Context_Checkpoint/FEATURE.md`) — replace destructive
  compaction with a **recoverable checkpoint** in one continuous session: a
  checkpoint archives the messages before it, resume starts from the latest
  checkpoint forward, and the archived messages stay intact (back-pagination) and
  are recallable via whole-session SQLite FTS5 weighted toward tool
  reasons/names. One session id. Implemented: the checkpoint is an ordinary
  ambient turn whose reply is the document, recorded at the boundary; resume and
  the TUI use the active window; back-pagination, the left-border page gauge
  (which doubles as the coarse scroll), the per-page context metric, and the
  nudge are in. The live manual sign-off is pending.

## Backlog (low priority)

Bugs and improvements, not yet scoped into a feature. When one is picked up,
move it into its own feature directory (or the relevant existing one) and give
it the usual artifact chain.

- **The run-state label says `thinking` when it should say `working`.** The
  label is `thinking` for the whole turn, including while the model is calling
  tools or waiting on a tool result, so it misdescribes what the agent is
  actually doing. It should reflect the phase (`working`, `calling tools`,
  `waiting`, …). Touches the harness run state
  (`hildegard.helper.harness.app`, `TChatPanel.SetState`) and the events that
  drive it. (TUI_Harness, Live_Turn_Control.)

- **`run_command` should echo the command before streaming its output.** Today
  the tool block stays blank until the first output chunk arrives, so a slow or
  silent command looks frozen. Print the resolved command line into the block
  the moment the tool starts, then stream stdout/stderr into it. (Tool_Streaming,
  Command_Tool.)

- **Background (non-blocking) tasks, so the UI does not freeze.** A long tool
  call blocks the turn until it returns, and the UI stops showing progress.
  Support running a task in the background: the operator can keep working (or
  the turn continues) and the result is delivered when it lands — likely riding
  the subagent pool (`hildegard.helper.pool`) and the ambient-record path. Needs
  a scoped design. (Agent_Loop, Subagents, Tool_Streaming.)

## Existing Behaviour (to be documented)

The foundation below is implemented and tested, but predates this documentation
system. It can be back-filled into features as needed:

- Command execution with streamed output, timeout, and cancellation
  (`src/hildegard.helper.process.pas`, covered by
  `tests/test_hildegard_helper.pas`)
- Bounded-concurrency subagent pool (`src/hildegard.helper.pool.pas`)
