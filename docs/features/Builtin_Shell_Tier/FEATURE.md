# Feature: Builtin Shell Tier

**Status:** Specified (2026-10-19)

**Related:** [Shell Library](../Shell_Library/FEATURE.md) (`Shell_Library_v1.DONE.md`),
[Approval Path Scoping](../Approval_Path_Scoping/Approval_Path_Scoping_v1.SPEC.md),
the research note [just-bash and the builtin shell tier](../../research/just-bash-and-the-builtin-shell-tier.md).

## The Problem

`run_command` is the agent's most-used tool, and every call spawns
`/bin/bash -c`:

- **Cost.** A `cat`, a `grep`, a `wc -l` — the overwhelmingly common commands in
  the recorded corpus — pay a process spawn, a shell startup and an OS pipe.
- **The gate is a guess.** Approval asks are built by
  `hildegard.helper.command.policy`'s splitter, which has no shell-language
  knowledge: a `for` loop asks to allow `for`, a command inside `$(...)` is
  never surfaced, and a script's meaning is never seen. The gate is wrong in
  both directions.
- **No composition over tools.** A script cannot call an MCP tool or a harness
  tool: tools exist only as top-level model calls. "Grep the tool output, then
  feed it to another tool" needs the model to shuttle text through its context.

The Shell Library now gives us a parser and an interpreter that own the
language and resolve commands against a registry we fill. The harness should be
its first consumer.

## The Decision

Add a **builtin shell tier**: a closed set of commands the harness registers
with the library, executed in-process, behind the existing approval service.

1. **The tier is an executor, not a replacement.** It plugs into
   `TCommandTool`'s existing `ICommandExecutor` seam as a first choice; the
   current `/bin/bash` executor remains the fallback. The call gains an
   optional `mode` (`auto` / `builtin` / `bash`) so the model chooses
   deliberately: `builtin` for composed file work and never falls back,
   `bash` for real programs. The result shape and approval model do not
   change.
2. **A script runs builtin only if the whole script is supported.** Before
   executing anything, the tier parses the script and checks that every command
   name is registered and the whole script is inside the library's v1 subset.
   If not, it declines and the process executor runs the command exactly as
   today — same asks, same behaviour. There is no partial run and no silent
   semantic change: either the script is fully understood, or it is not ours.
3. **The filesystem is the workspace.** The tier's `IShellFileSystem` is rooted
   at the workspace; every read, write, listing, `cd` and glob goes through the
   same `PhysicalContains` check the file tools use, symlinks included. A path
   outside the workspace is an error, not a prompt: the builtin tier has no
   business there. Outside access remains a matter for the process tier.
4. **The gate is the existing one.** Each command in the tier builds the same
   asks `run_command` builds (`Ref = 'run_command:<bin>'`, the arguments, the
   once/exact/any/prefix options) and resolves them through the same
   `IApprovalService`, so existing grants keep working. The model's `reason`
   is inherited by every ask the run produces — including asks raised by a tool
   dispatched from inside the script.
5. **Tools are composable, explicitly.** The tier registers `tool <name>
   [json]` and `mcp <server>:<tool> [json]`. They resolve against the normal
   tool registry (MCP included) and therefore pass the normal per-tool gate. An
   explicit allow-list decides which tools may be called this way; `run_command`
   and any other shell-entry tool are refused, so the tier cannot recurse.
6. **The command set is small and honest.** `echo`, `cat`, `head`, `tail`,
   `wc`, `grep`, `ls`, `find`, `mkdir`, `rm`, `mv`, `cp`, `touch`, `sort`,
   `uniq`, `basename`, `dirname`, `test`, `[`, `true`, `false`, plus the
   library's own `cd`/`pwd`/`export`/`unset`/… builtins. Everything else —
   `git`, `curl`, `make` — falls back to the process tier, where the asks name
   the program and the paths. The set grows by registering a handler, never by
   changing the core.

## What This Is Not

- **Not a sandbox.** The workspace bound is the same path policy the file tools
  already use; the OS boundary is still the process's.
- **Not a second policy.** No new approval rules, refs or option kinds. The
  refs are `run_command:<bin>`, exactly as today, so an operator's existing
  grants apply unchanged.
- **Not a shell rewrite.** The language is the Shell Library's; the tier only
  supplies commands, a filesystem and a gate.
- **Not a fallback hiding place.** A supported script never silently runs in
  the process tier, and an unsupported one never partially runs in the builtin
  tier.

## Why This Shape

- **Library-owned language, consumer-owned capability** is the boundary the
  Shell Library was built for; the tier is its proof.
- **The whole-script pre-flight** is what makes the two tiers safe to mix: the
  decision is made once, before any side effect, from the AST rather than from
  a token guess.
- **Reusing `run_command:<bin>`** means the feature ships without a policy
  migration: today's "always allow grep" is today's grant inside the tier.
- **An allow-list for tool dispatch** keeps the tier's reach auditable: a
  script can call the tools the operator listed, and nothing else.

## Acceptance

- A `run_command` whose whole script uses the registered set runs in-process:
  no process is spawned, output/exit match the process tier for the shared
  cases (pinned by the differential corpus), and each command's ask appears in
  order with the model's reason.
- A script with one unregistered command, or one out-of-subset construct, runs
  entirely through the process tier with today's asks — the tier executes
  nothing.
- A path outside the workspace is refused by the builtin filesystem, including
  through a symlink.
- `mcp <server>:<tool>` calls the MCP tool through its normal gate; `run_command`
  inside the tier is refused; a tool outside the allow-list is refused.
- Existing `run_command` grants still apply without re-prompting.
- `mode=builtin` runs a supported script without spawning and refuses an
  unsupported one without asking or falling back; `mode=bash` never consults
  the tier.
- `make check` green, leak-clean.

## Alternatives Considered

- **Replace `/bin/bash` outright.** Rejected: the corpus is 9% dynamic and the
  agent needs the real shell for builds, git and the network. A tier, not a
  wall.
- **Run the builtin tier only for an explicit list of scripts.** Rejected: the
  pre-flight is cheap and gives the behaviour automatically.
- **Gate the tier with a new `shell:` ref.** Rejected: it would invalidate every
  stored grant and split the policy in two.
- **Let the tier spawn for a single unknown command inside an otherwise
  supported script.** Rejected: partial execution across two tiers makes side
  effects unpredictable; the whole script falls back.
