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
| [Tool Approvals](Tool_Approvals/FEATURE.md) | In Progress | Approvals v1 | Generic, durable whitelist for tool calls: `ref` + `params`, scoped global/workspace/session; `run_command:<bin>` for the shell, `suite:function` for external tools. Supersedes the command policy and audit. Engine, persistence, command adapter, and CLI done; live smoke pending. Path gating dropped by decision. |
| [Workspaces](Workspaces/FEATURE.md) | Implemented | Workspaces v1 | The directory the agent operates in: canonical identity, access check, relative-path base, and the trust boundary for path checks; scopes approvals and sessions. |
| [Sessions and Ledger](Sessions_And_Ledger/FEATURE.md) | In Progress | Sessions v1 | Random-hex session ids bound to a workspace, an append-only typed ledger (messages, reasoning, tool calls/results, errors), restore into messages, and a SQLite conversation adapter; drops the `requests` table. Ledger + adapter done; live smoke pending. |
| [Remote Agent Link](Remote_Agent_Link/FEATURE.md) | Proposed | - | Pair a device to an account and hold an outbound link to execute requests locally. Helper-side only in v1. |
| [TUI Harness](TUI_Harness/FEATURE.md) | In Progress | TUI Core v1 (implemented, tested); Markdown v1 (spec only); Harness UI v1 (implemented, sign-off pending) | Full-screen front end: nested grid layout, independently scrolling panes, modal overlay planes, and markdown-coloured text. Reuses FPC `video` plus RTL `termio`; no new deps. Reverses the earlier CLI-only/pager decision (the CLI is retained). Harness UI v1 wires the toolkit to the agent loop (worker thread + event queue, prompt line, streaming conversation, approval modal, SQLite sessions); run with `make tui-agent`. A live terminal sign-off and Markdown_v1 remain. |
| [Local SQLite Store](Local_SQLite_Store/FEATURE.md) | Implemented | Store v1 | Embedded SQLite for credentials, request history, durable queue, and settings. Vendored 3.53.4. |

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
