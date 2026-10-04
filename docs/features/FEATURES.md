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
| [File Tools](File_Tools/FEATURE.md) | In Progress | File Tools v1 | Approval-gated `read_file`, `write_file`, `edit_file`, `list_dir`, `glob`, `grep` confined to the workspace, with bounded output. Registered by the TUI harness and the CLI; live smoke pending. |
| [TUI Widgets](TUI_Widgets/FEATURE.md) | In Progress | TUI Widgets v1 | A widget kit over TUI Core: `TSingleChild`/`TPanel`, `TTheme`, a focus group (`Tab`/click), and `TButton`/`TListView`. Demo adoption pending. |
| [TUI Text Editing](TUI_Text_Editing/FEATURE.md) | Implemented | Text Edit v1 | A caret-aware multi-line editor (`TTextEdit`) over shared grapheme/width helpers: insert/delete, arrow navigation, soft wrapping, and a blinking caret. Reused by the chat compose box and, later, the editor panel. |
| [TUI Animation](TUI_Animation/FEATURE.md) | Implemented | TUI Animation v1 | One app-owned frame clock (default 10 ms); widgets derive content from time via `Advance(nowMs)`/`Animating`; one composite+diff per frame; idle waits on a long timeout. Clients: `TSpinner`, `TProgress`. |
| [Tool Approvals](Tool_Approvals/FEATURE.md) | In Progress | Approvals v1 | Generic, durable whitelist for tool calls: `ref` + `params`, scoped global/workspace/session; `run_command:<bin>` for the shell, `suite:function` for external tools. Supersedes the command policy and audit. Engine, persistence, command adapter, and CLI done; live smoke pending. Path gating dropped by decision. |
| [Workspaces](Workspaces/FEATURE.md) | Implemented | Workspaces v1 | The directory the agent operates in: canonical identity, access check, relative-path base, and the trust boundary for path checks; scopes approvals and sessions. |
| [Sessions and Ledger](Sessions_And_Ledger/FEATURE.md) | Implemented | Sessions v2, Turn Stats v1 | Relational history: `sessions -> turns (loops) -> requests` and `sessions -> messages` (user, assistant, reasoning, tool call, tool, error). Token usage and timings per request, rolled up per turn; restore renders the streamed blocks (tool reasons and reasoning included). Turn Stats v1 renders the latest turn's metrics in the status bar (workspace left, stats right) with the hints in the CTA toolbar, identically live and resumed. Supersedes the v1 flat ledger; a full schema reset with no data migrations. |
| [Remote Agent Link](Remote_Agent_Link/FEATURE.md) | Proposed | - | Pair a device to an account and hold an outbound link to execute requests locally. Helper-side only in v1. |
| [TUI Harness](TUI_Harness/FEATURE.md) | In Progress | TUI Core v1 (implemented, tested); Markdown v1 (implemented, tested); Markdown View v1 (implemented, tested); Harness UI v1 (implemented); Chat Panel v1 (implemented); Interrupt v1 (implemented); Approval Modal v1 (implemented) | Full-screen front end: nested grid layout, independently scrolling panes, modal overlay planes, and markdown-coloured text. Reuses FPC `video` plus RTL `termio`; no new deps. Reverses the earlier CLI-only/pager decision (the CLI is retained). Harness UI v1 wires the toolkit to the agent loop (worker thread + event queue, approval modal, SQLite sessions); Chat Panel v1 replaces its transcript with the designed conversation view (message blocks, overlay compose, stats/status lines); Interrupt v1 adds an Esc-Esc turn interrupt and the compose's Ctrl+U/Ctrl+C keys, with Ctrl+C quitting only when the box is empty; Approval Modal v1 redraws the dialog to the design and dims the whole screen behind it. Markdown v1 adds a pure parser (blocks of styled spans + theme) with an inert streaming tail; Markdown View v1 draws it as a vertical stack (bullets, quote bar, code backdrop, rule) without rebuilding finalised blocks, and assistant blocks in the chat stream now render through it. Run with `make tui-agent`. A live terminal sign-off remains. |
| [Live Turn Control](Live_Turn_Control/FEATURE.md) | Implemented | Live Turn Control v1 | Refines the live loop from a TUI trial: immediate no-trace cancel that restores the prompt, a prompt queue injected at loop boundaries, the model's reason in the approval dialog, wrapping/compaction of long content, a Shift+Enter submit with bracketed paste and a primary-action CTA, a tool-call budget, and a live thinking tail. |
| [Response Continuation](Response_Continuation/FEATURE.md) | Implemented | Response Continuation v1 | The loop owns the in-flight response: on `finish_reason: length` it re-requests a followup and appends until a proper stop, committing the assembled response as one message. Persistence is ephemeral until a stop; on any other error the pending response is dropped and the live view rolls back its streamed blocks. A cut-off tool call is dropped, answered with a paired notice, and resubmitted. |
| [Local SQLite Store](Local_SQLite_Store/FEATURE.md) | Implemented | Store v1 | Embedded SQLite for credentials, request history, durable queue, and settings. Vendored 3.53.4. |
| [Context Budget](Context_Budget/FEATURE.md) | Implemented | Tool Output Budget v1 | Keeps the history faithful on disk while bounding what enters the prompt: an oversized tool result is stored in full as a session artifact and the prompt carries a truncated head plus a reference; `recall_tool_result` reads slices and caps but never spills. Depends on Sessions v2. |
| [Session Handoff](Session_Handoff/FEATURE.md) | Proposed | - | One live holder (lease + heartbeat) per session; explicit, user-confirmed handoff; read-only observe mode; headless detached holders that report to SQLite. Store-as-broker; the driver abstraction Remote Agent Link will adopt. |
| [TUI Clipboard](TUI_Clipboard/FEATURE.md) | Proposed | - | Copy-out for the Harness TUI via OSC 52: targeted yank bindings (last assistant message first), graceful degradation, zero dependencies — the only mechanism that survives SSH. Arbitrary selection stays terminal-native (Shift/Fn+drag, tmux), now documented. |
| [TLS Foundation](TLS_Foundation/FEATURE.md) | Proposed (**critical**) | - | Replace dynamically linked OpenSSL (`opensslsockets`) with a vendored, statically linked TLS stack (mbedTLS, via the SQLite pattern). Today the release binary needs host libssl/libcrypto, which fails on a clean remote device. Prerequisite for Remote Agent Link. |

## Planned (not yet specified)

- **Sandboxed Script Compute** - embed [GocciaScript](https://github.com/frostney/GocciaScript)
  (MIT, FPC-native JavaScript engine) as an in-process, capability-free compute
  tier for model-authored scripts. Deliberately **no filesystem, network, or
  system access** - the helper's shell path remains the privileged tier; scripts
  are the safe, deterministic compute tier. Intended as an **internal compute
  tool** for the helper first, with a possible future `run script` action over
  the Remote Agent Link. Parked until a concrete need appears; when picked up,
  the SPEC must nail down a hard per-execution timeout, a minimal builtin set,
  in-memory-only module resolution (or no imports), output/memory caps, and
  host-object isolation at the sandbox boundary.

## Existing Behaviour (to be documented)

The foundation below is implemented and tested, but predates this documentation
system. It can be back-filled into features as needed:

- Command execution with streamed output, timeout, and cancellation
  (`src/hildegard.helper.process.pas`, covered by
  `tests/test_hildegard_helper.pas`)
- Bounded-concurrency subagent pool (`src/hildegard.helper.pool.pas`)
