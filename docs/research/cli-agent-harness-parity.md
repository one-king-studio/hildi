# CLI Agent Harness Feature Parity

A survey of five terminal/CLI coding-agent harnesses, compared against
`hildi`. The point is to see what the field treats as table stakes,
what is differentiating, and where this project deliberately or accidentally
diverges.

Surveyed: **OpenCode**, **OpenAI Codex CLI**, **Anthropic Claude Code**,
**Pi**, **DeepSeek Harness (`dsh`)**. Sources are listed at the bottom. This
space moves fast; treat every cell as "as documented at the time of writing".

## Legend

| Mark | Meaning |
| ---- | ------- |
| ✅ | First-class, built in and documented |
| ◐ | Partial, plugin/extension, opt-in, or on the roadmap |
| ✗ | Not available |
| ? | Not verified in the sources read |

The `hildi` column reflects `docs/features/FEATURES.md` at the time
of writing, not aspirations.

## Foundations

| Feature | hildi | OpenCode | Codex CLI | Claude Code | Pi | DeepSeek Harness |
| ------- | ---------------- | -------- | --------- | ----------- | -- | ---------------- |
| Implementation language | Free Pascal | TypeScript | Rust | TypeScript + native | TypeScript | TypeScript |
| License | none (private) | MIT | Apache-2.0 | Proprietary | MIT | MIT |
| Distribution | build from source | npm / brew / binary | npm / brew / installer | npm / native installer | npm / curl / brew | npm (`npx`) |
| Multi-provider | ◐ OpenAI-compatible only | ✅ many | ◐ OpenAI + local OSS | ◐ Anthropic + Bedrock/Vertex/Foundry | ✅ 15+ | ✅ (plugin) |
| Local / open models | ✅ any OpenAI-compatible endpoint | ✅ | ✅ `--oss` (Ollama/LM Studio/MLX) | ◐ via LLM gateway | ✅ Ollama, etc. | ✅ |
| Auth | API key (env / `.env`) | API keys, OAuth | ChatGPT account or API key | Claude subscription or API key | API keys, OAuth | API key |

## Interfaces

| Feature | hildi | OpenCode | Codex CLI | Claude Code | Pi | DeepSeek Harness |
| ------- | ---------------- | -------- | --------- | ----------- | -- | ---------------- |
| Interactive TUI | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ (`dsh cli`) |
| Headless / print mode | ✅ (`-p`, pipe) | ✅ (`opencode run`) | ✅ (`codex exec`) | ✅ (`-p`) | ✅ (`-p`) | ✅ (`--profile headless`) |
| Structured JSON output | ✗ (listed as a future nicety) | ✅ | ✅ (JSONL) | ✅ (`json` / `stream-json`) | ✅ (`--mode json`) | ◐ (SDK JSON-RPC) |
| RPC / SDK | ◐ internal Unix-socket protocol, no public SDK | ✅ SDK + server | ◐ app-server, `codex mcp-server` | ✅ Agent SDK | ✅ RPC + TypeScript SDK | ✅ SDK + ACP |
| Web UI | ✗ | ✅ | ◐ (cloud web) | ◐ (claude.ai/code) | ✗ | ✅ |
| Desktop app | ✗ | ✅ | ✅ | ✅ | ✗ | ✅ |
| IDE extension | ✗ | ✅ | ✅ | ✅ | ◐ (via SDK) | ◐ (via ACP) |
| Long-lived daemon / attach | ✅ headless session, `--attach` | ✅ server, attach | ◐ app-server, cloud | ✅ background agents, `attach`, Remote Control | ◐ RPC | ✅ profiles serve |

## Agent model

| Feature | hildi | OpenCode | Codex CLI | Claude Code | Pi | DeepSeek Harness |
| ------- | ---------------- | -------- | --------- | ----------- | -- | ---------------- |
| Agent loop | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Subagents | ✗ (a bounded shell-command pool exists; no agent tool) | ✅ General/Explore/Scout | ✅ | ✅ built-in + custom | ✗ (extensions / tmux) | ✅ (Codex + Claude Code subagent plugins) |
| Parallel / multiple sessions | ◐ one driver, many observers; one session per TUI | ✅ tabs | ◐ cloud + worktrees | ✅ agent view, agent teams | ◐ tmux | ✅ |
| Plan mode | ✗ | ✅ Build/Plan | ✅ read-only / plan | ✅ | ✗ (extension) | ◐ modes |
| Custom agents / personas | ◐ single system prompt | ✅ primary + subagents | ✅ AGENTS.md + profiles | ✅ subagents + output styles | ✅ SYSTEM.md + extensions | ✅ presets + profiles |
| Context compaction | ◐ context guard truncates; no summarisation | ✅ compaction agent | ✅ auto-compact | ✅ auto-compact | ✅ customisable | ✅ token-aware truncation |
| Response continuation | ✅ on `finish_reason: length` | ✅ | ✅ | ✅ | ✅ | ✅ |
| Steering / queued messages | ✅ prompt queue at loop boundaries | ◐ | ✅ steer active turn | ✅ | ✅ steer + follow-up | ◐ |
| Interrupt / cancel | ✅ Esc-Esc | ✅ | ✅ | ✅ | ✅ | ✅ |
| Step / turn / budget limits | ✅ tool-call budget | ✅ `steps` | ◐ | ✅ `--max-turns`, `--max-budget-usd` | ◐ | ✅ |
| Reasoning stream display | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

## Tools

| Feature | hildi | OpenCode | Codex CLI | Claude Code | Pi | DeepSeek Harness |
| ------- | ---------------- | -------- | --------- | ----------- | -- | ---------------- |
| Shell execution | ✅ `run_command` | ✅ `bash` | ✅ | ✅ `Bash` | ✅ | ✅ |
| Read / write / edit files | ✅ `file_read`/`file_write`/`file_edit` | ✅ | ✅ | ✅ | ✅ | ✅ |
| Glob / grep search | ✅ `file_glob`/`file_grep` | ✅ (ripgrep) | ✅ | ✅ | ✅ | ✅ |
| Web search | ✗ | ✅ (Exa/Parallel) | ✅ `--search` | ✅ | ◐ (extensions) | ✅ |
| Web fetch | ✗ (TLS is ready) | ✅ `webfetch` | ✅ | ✅ `WebFetch` | ◐ (extensions) | ✅ |
| LSP / code intelligence | ✗ | ✅ (experimental tool) | ◐ | ✅ code-intelligence plugins | ◐ (extension) | ◐ (plugin) |
| Todo list | ✗ | ✅ `todowrite` | ◐ | ✅ | ✗ (TODO.md) | ✅ |
| Ask-the-user tool | ◐ approval modal only | ✅ `question` | ◐ | ✅ | ◐ | ✅ |
| Apply patch | ◐ via `file_edit` | ✅ `apply_patch` | ✅ | ✅ | ✅ | ✅ |
| Browser automation | ✗ | ✅ (MCP / plugin) | ✅ | ✅ Chrome | ◐ (extension) | ◐ (plugin) |
| Image / vision input | ✗ | ✅ drag-drop images | ✅ `--image` | ✅ | ✅ | ✅ |
| Scripted tool composition | ◐ proposed (Composed Tool Sandbox) | ◐ | ◐ sandbox | ◐ | ✅ Codemode JS sandbox | ◐ (plugin) |
| Custom tools at runtime | ◐ Pascal units, no runtime plugin | ✅ custom tools | ✅ plugins | ✅ plugins | ✅ TS extensions | ✅ plugins |
| MCP client | ◐ designed, parked | ✅ | ✅ | ✅ | ✅ | ◐ plugin, off by default |
| MCP server (expose itself) | ✗ | ◐ (SDK; third-party `opencode-mcp`) | ✅ `codex mcp-server` | ◐ (SDK) | ◐ (RPC/SDK) | ✅ SDK/ACP |
| Tool-output budgeting | ✅ Context Budget + `recall_tool_result` | ◐ | ✅ `output_token_limit` | ✅ tool search | ◐ | ✅ |

## Context and configuration

| Feature | hildi | OpenCode | Codex CLI | Claude Code | Pi | DeepSeek Harness |
| ------- | ---------------- | -------- | --------- | ----------- | -- | ---------------- |
| Project instructions file | ✅ `AGENTS.md` | ✅ `AGENTS.md` | ✅ `AGENTS.md` | ✅ `CLAUDE.md` | ✅ `AGENTS.md` + `SYSTEM.md` | ✅ `AGENTS.md` |
| Skills | ✗ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Prompt templates / slash commands | ✗ | ✅ commands | ✅ | ✅ | ✅ | ✅ |
| Hooks | ✗ | ✅ plugin hooks | ✅ | ✅ (rich lifecycle) | ✅ extension events | ✅ plugin |
| Plugins / extensions | ✗ | ✅ | ✅ + marketplace | ✅ + marketplaces | ✅ TS extensions | ✅ everything-is-a-plugin |
| Themes | ✅ `TTheme` dark/light/auto | ✅ | ✅ syntax theme | ✅ | ✅ | ✅ |
| Declarative config file | ◐ `.env` only | ✅ JSON/JSONC | ✅ TOML | ✅ JSON | ✅ JSON | ✅ YAML + profiles |
| Path-scoped rules | ✗ | ◐ | ◐ | ✅ `.claude/rules` with paths | ◐ | ◐ |

## Safety and control

| Feature | hildi | OpenCode | Codex CLI | Claude Code | Pi | DeepSeek Harness |
| ------- | ---------------- | -------- | --------- | ----------- | -- | ---------------- |
| Approval / permission modes | ✅ durable whitelist, ask/allow/deny | ✅ per-tool `allow`/`ask`/`deny` | ✅ untrusted/on-request/never + writes | ✅ default/acceptEdits/plan/auto/bypass | ✗ (extensions) | ✅ permission cycling |
| OS-level sandbox | ✗ (static parser is a guardrail, by design) | ◐ | ✅ Seatbelt/Landlock/Windows | ✅ sandboxed Bash (Seatbelt/bubblewrap) | ✗ (run in a container) | ✅ (plugin) |
| Workspace confinement | ✅ | ✅ | ✅ workspace-write | ✅ working directories | ◐ project trust | ✅ |
| Network controls | ✗ | ◐ | ✅ network proxy + domain allow/deny | ◐ | ✗ | ◐ |
| Audit / durable transcript | ✅ sessions + ledger | ✅ | ✅ | ✅ transcripts | ✅ JSONL | ✅ session logs |

## Sessions and state

| Feature | hildi | OpenCode | Codex CLI | Claude Code | Pi | DeepSeek Harness |
| ------- | ---------------- | -------- | --------- | ----------- | -- | ---------------- |
| Session persistence | ✅ SQLite | ✅ | ✅ | ✅ | ✅ JSONL | ✅ |
| Resume / continue | ✅ `--attach`, ledger replay | ✅ | ✅ `codex resume` | ✅ `-c` / `-r` | ✅ `/tree` | ✅ |
| Branch / fork a session | ✗ | ◐ | ◐ | ✅ `--fork-session` | ✅ tree + branches | ◐ |
| Share a session | ✗ | ✅ `/share` | ◐ | ◐ | ✅ `/share`, `/export` | ◐ |
| Cross-session messaging | ✗ | ◐ | ✗ | ✅ | ✗ | ✗ |
| Undo / checkpoint / rollback | ✗ | ✅ `/undo`, `/redo` | ◐ git checkpoints | ✅ checkpoints | ◐ session tree | ◐ |
| Durable / resumable runtime | ✅ socket-lease headless session | ✅ server | ◐ | ✅ background supervisor | ◐ | ✅ durable session |
| Publishable artifacts | ✗ | ◐ | ◐ | ✅ | ◐ | ◐ |

## Ecosystem

| Feature | hildi | OpenCode | Codex CLI | Claude Code | Pi | DeepSeek Harness |
| ------- | ---------------- | -------- | --------- | ----------- | -- | ---------------- |
| Package marketplace / registry | ✗ | ✅ plugins + skills | ✅ plugin marketplace | ✅ plugin marketplaces | ✅ Pi packages | ✅ `dsh-plugin` |
| Git worktrees | ✗ | ◐ (community plugin) | ✅ | ✅ `-w` | ◐ tmux | ◐ |
| Git hosting integration | ✗ | ✅ GitHub / GitLab | ✅ PR review, cloud | ✅ GitHub Actions, PRs | ◐ gist share | ◐ |
| CI / headless automation | ◐ CLI is pipe-friendly | ✅ | ✅ | ✅ | ✅ | ✅ |
| Observability / usage stats | ✅ header + status bar, turn stats | ◐ | ◐ | ◐ | ◐ | ✅ stats bar |
| Telemetry | ✗ | ◐ | ◐ | ◐ | ◐ | ◐ |
| Multi-session UI | ◐ one session per TUI | ✅ tabs | ✅ | ✅ agent view | ◐ | ✅ |

## Where hildi stands

**Strengths (uncommon in this set):**

- **A real durable runtime split.** The headless agent process + typed Unix-socket
  protocol + "the socket is the lease, the ledger is the truth" model is closer
  to Codex's app-server and Claude's background supervisor than to the
  in-process loops of OpenCode/Pi. Very few harnesses make the agent loop
  attachable by many observers with replay.
- **Static, dependency-free binaries.** Vendored mbedTLS + SQLite with no runtime
  dylibs; every other harness here is a Node or Rust artifact.
- **Turn-level cost/latency accounting** (tokens, cache hit, wall time, per-block
  reasoning durations) surfaced identically live and on resume — Pi and `dsh`
  have a stats bar, but this is richer than most.
- **Tool-output budgeting** as a first-class feature (`recall_tool_result`), which
  most harnesses handle ad hoc.

**Common features it lacks** (the field treats these as table stakes):

- **Subagents / task delegation** — OpenCode, Codex, Claude, and `dsh` all ship
  it; Pi deliberately does not. This is the single biggest gap.
- **Skills and prompt templates / slash commands** — now near-universal.
- **MCP client** — designed and parked; the only harness here without it live.
- **Hooks and a plugin/extension surface** — the field's main customisation axis.
- **Project-instruction loading from parent dirs / `~`** — the mechanism exists
  conceptually but the loading rules are simpler than AGENTS.md/CLAUDE.md.
- **Compaction (summarise, don't truncate)** and **undo/checkpoint**.
- **Web search / fetch, LSP, image input** — capability tools the others assume.
- **Worktrees, session sharing, structured JSON output** — ergonomics.

**Deliberate divergences (documented, not accidental):**

- **No OS sandbox; the command policy is a guardrail, not a sandbox.** Codex and
  Claude treat the sandbox as the hard security boundary. This is the sharpest
  philosophical split in the table.
- **Reasoning is display-only** and never sent back to the provider.
- **Single-provider shape** (OpenAI-compatible) vs. the multi-provider norm.
- **Pascal, test-driven, self-hosted-first** — a different reason to exist than
  the product harnesses.

## Sources

- OpenCode: <https://opencode.ai/docs/> · `/docs/tools/` · `/docs/agents/`
- Codex CLI: <https://developers.openai.com/codex/cli/> · `/codex/features` ·
  `/codex/agent-approvals-security` · `/codex/extend/mcp` ·
  <https://developers.openai.com/codex/cli/reference>
- Claude Code: <https://code.claude.com/docs/en/features-overview.md> ·
  `/docs/en/cli-reference` · `/docs/en/sub-agents` · `/docs/en/hooks` ·
  `/docs/en/skills`
- Pi: <https://pi.dev/> · <https://pi.dev/docs/latest> · `/how-pi-works`
- DeepSeek Harness: <https://github.com/deepseek-ai/deepseek-harness> ·
  <https://www.deepseek.com/harness/en> · <https://deepseekagent.io/> ·
  <https://github.com/soolaugust/deepseek-harness-cli>
- This project: `docs/features/FEATURES.md`, `HANDOFF.md`
