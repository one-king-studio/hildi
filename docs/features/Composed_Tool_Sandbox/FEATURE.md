# Composed Tool Sandbox

## Overview

Give the agent a **script tier that composes the harness's own tools**: the model
writes a small JavaScript program that loops, branches, and chains **our gated
tools** — `await tools.file_read("some/file.ps")`,
`await tools.file_search_replace("src/**/*.pas", …)` — and the whole program is
**one** tool call. It sits between *think* (no side effects) and *act* (a single
approval-gated tool call), and it removes the orchestration reason to reach for
`bash`.

The engine is [GocciaScript](https://github.com/frostney/GocciaScript) — an MIT,
FPC-native ECMAScript runtime built *for* AI-agent hosts, whose capability model
already matches this project's values (deny-by-default, deny-wins, auditable
denials). It is embedded in-process from a pinned source tree and compiled by the
helper's own Free Pascal toolchain. It runs **capability-free**
(`TGocciaCapabilities.None`); the only way a script can touch the world is through
the tool functions we inject, and each of those is the **same** gated, audited,
snapshot-intercepted call a direct invocation would be.

## Problem Statement

Today, composing tool calls is the model's job, one turn at a time:

- **N round-trips.** "Read these 40 files and rename a symbol in each" is 40 tool
  calls across 40 model turns; the loop lives in the model's head, not in code.
- **`run_command` as the orchestrator.** The moment composition is non-trivial the
  model reaches for `bash` — `grep -rl X | xargs sed -i` — which is *one* approval
  for **arbitrary** host access, and whose effects we cannot observe, scope, or
  snapshot. We do not know which files it changed.
- **No structured composition.** A shell pipe passes text; a tool call returns a
  structure. Neither lets the model write `if` / `for` / `try` over tool results
  while the tools stay gated.

There is no tier where the model can *orchestrate* our tools without either
spending a turn per call or handing the machine to a shell. This feature adds one.

## Decision

**Committed: GocciaScript, embedded in-process from a pinned source tree, with the
harness's tools injected as native functions.** Not a subprocess, not a
dynamically loaded library, not a second interpreter written here, and not a shell
by another name.

Sub-decisions, each load-bearing:

1. **Capability-free core.** Core-only `TGocciaEngine`, an immutable
   `TGocciaCapabilities.None`. No runtime extensions, so no `console`, `fetch`,
   `URL`, or `goccia:` modules; no filesystem, network, FFI, or exec. The engine
   grants nothing; the **injected tools are the only reachable surface**.
2. **The tools are a *view over the registry*, not a second registry.** Each
   `tools.*` method routes to the same registered tool, so the approval ref, the
   `reason` requirement, the audit row, and the snapshot interception are identical
   to a direct call. If any method bypassed that, the sandbox would be an ungated
   shell one level up.
3. **No `command_run` in the sandbox.** The shell stays a separate, first-class,
   separately-approved tool call — its own reason, its own approval, its own audit
   row. It just cannot be hidden inside a script.
4. **No `recall` in the sandbox.** `recall` reads back a result the harness spilled
   into its *own* store; it is a built-in harness feature that bypasses the
   approval gate and is not a tool to compose.
5. **Vendoring follows the `deps/` pattern.** `scripts/fetch-goccia.sh` pins the
   commit and verifies the archive's checksum; the source is **fetched, not
   committed** (like SQLite and mbedTLS) — there is no submodule.
6. **Spike before SPEC.** The integration cost is the open question. The first task
   is a throwaway spike that builds the engine, embeds it, and measures the
   release-binary delta and the clean-build cost. If the delta is out of proportion
   to the value, the feature is re-evaluated before any SPEC is written.

## Goals

- Add a `run_script` tool that executes a model-authored program able to call the
  harness's tools, with **no ambient host access beyond those tools**.
- Make **one turn, N tool calls** the normal shape for a batch or a loop.
- Route every tool call a script makes through the **same** approval gate, reason,
  audit row, and snapshot interception as a direct call.
- Keep the shell a **separate, first-class, separately-approved** tool; make it
  unreachable from a script.
- Keep the privileged tier unchanged; keep the deployment story (a single
  self-contained binary); keep the dependency surface pinned.
- Be deterministic where it can be: a script that calls no tool and reads no clock
  is reproducible across runs.

## User Stories

- As an **operator**, I want "read 40 files and rename a symbol in each" to be one
  approved script, so I approve a *class* of operation instead of 40 times.
- As an **operator**, I want a script to be *unable* to run a shell command, so the
  sandbox cannot become the bash backdoor I was trying to remove.
- As an **operator**, I want every file the script changes to appear in the turn's
  diff and be undoable, because its calls are the same intercepted calls as a
  direct edit.
- As the **agent**, I want loops, conditionals, and aggregation over tool results —
  a scratchpad that is exact where token arithmetic is not, and that *acts* where a
  scratchpad could not.
- As a **reviewer**, I want a script that is the answer — a codemod, a migration —
  to be persisted and re-runnable, not a wall of pseudocode.
- As the **Remote Agent Link designer**, I want the engine's snapshot-in / diff-out
  execution and layered capability model available as prior art for the link's
  request scoping.

## Acceptance Criteria

### Functional Requirements

- [ ] A `run_script` tool is registered and advertised like every other tool
      (required non-empty `reason`; approval-gated as the class `script:run`).
- [ ] Execution is in-process, core-language-only, with
      `TGocciaCapabilities.None`: no filesystem, network, FFI, exec, or
      time-of-day; no runtime globals.
- [ ] The harness's world-touching tools are injected as **one global `tools`
      object** (snake_case, async). Each method routes to the same registered tool
      — same approval ref, same `reason` requirement, same audit row, same
      snapshot interception as a direct call.
- [ ] The shell is **not reachable** from a script: no `command_run` method is
      injected, and no capability grants exec.
- [ ] `recall` is **not injected** (harness-internal, ungated, not a tool to
      compose).
- [ ] Limits are enforced: a wall-clock timeout wired to the existing cancel check,
      an instruction cap, a memory cap, and an output-size cap.
- [ ] The result is structured: standard output, the script's return value, and a
      typed error on failure or timeout — never a crash of the harness.
- [ ] The tool boundary is pure text / structured values (the helper's UTF-8
      `AnsiString` converts explicitly to and from the engine's UTF-16 `string`);
      no host object crosses the boundary.
- [ ] A denied tool call inside a script surfaces as a script-level error naming
      the tool and the denial, never a host path.

### Non-Functional Requirements

- [ ] Portability: builds and runs on macOS and Linux, arm64 and x86-64.
- [ ] Binary size: the release-binary delta is measured and recorded; the spike
      gates the feature on it.
- [ ] Build time: the clean-build cost of compiling the engine is measured and
      recorded.
- [ ] `make check` passes (functional suite plus the leak gate) with the engine in
      the process; the engine's allocations do not leak.
- [ ] No runtime library is introduced; the release binary remains self-contained.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}` for helper units, and keep
  `make check` green.
- The engine is `{$mode delphiunicode}` (UTF-16 `string`); per-unit modes are fine,
  but every value crossing the boundary converts explicitly.
- Vendoring follows the `deps/` pattern: pinned source via
  `scripts/fetch-goccia.sh`, no committed compiled artifacts, no system-library
  fallback.
- The engine's public API must be reached through a thin helper facade, so an
  engine upgrade is a facade change and not a sweep of call sites.
- The engine's own capability model is the boundary, and v1 grants nothing; the
  **only** reachable surface is the injected tools.
- The injected tools must be the **same objects** as the direct tools — one
  registry, not a parallel one.

### Business / Time

- No deadline. Sequenced behind the critical path (Remote Agent Link, Session
  Handoff); picked up when a concrete composition need appears.

## The VM tool surface (`tools.*`)

The sandbox exposes the harness's tools as one global object, `tools`, with
snake_case methods. They are **async** (each returns a Promise), so a script awaits
them and a loop over many files is still one turn:

```javascript
const src = await tools.file_read("some/file.ps");
const files = await tools.file_glob("src/**/*.pas");
for (const f of files) {
  await tools.file_replace_regex(f, "OldName", "NewName", { all: true });
}
await tools.patch_apply(patchText, { dryRun: true });
```

| VM method | Replaces | Notes |
| --- | --- | --- |
| `file_read(path, opts?)` | `cat`, `head`, `tail`, `sed -n 'a,bp'` | `opts`: `{ offset, limit }` for a line range |
| `file_write(path, content)` | `cat > f <<EOF`, `printf > f`, `tee` | atomic; the existing `write_file` |
| `file_append(path, content)` | `>>`, `tee -a` | |
| `file_edit(path, old, new, opts?)` | `ed`/`ex`, small `sed` | exact-string replace; the existing `edit_file` |
| `file_replace_regex(path, pattern, repl, opts?)` | `sed -i`, `perl -pi -e`, `python -c` | `opts`: `{ all, flags }` |
| `file_search_replace(glob, pattern, repl, opts?)` | `grep -rl X \| xargs sed -i`, `find … -exec sed` | `opts`: `{ dryRun, all, flags }`; returns changed paths + counts |
| `file_delete(path)` | `rm` | |
| `file_move(src, dst)` | `mv` | |
| `file_copy(src, dst)` | `cp` | |
| `file_mkdir(path)` | `mkdir -p` | |
| `file_list(path, opts?)` | `ls`, `find` | the existing `list_dir` |
| `file_glob(pattern)` | `find -name`, shell globs | the existing `glob` |
| `file_grep(pattern, opts?)` | `grep`, `rg` | the existing `grep`; `opts`: `{ glob, context }` |
| `file_stat(path)` | `stat`, `ls -l` | size, mtime, mode |
| `json_read(path, pointer?)` | `jq` | |
| `json_edit(path, pointer, value)` | `jq '…' > f` | validated; the edit is a JSON patch |
| `yaml_read(path, path_expr?)` | `yq` | |
| `yaml_edit(path, path_expr, value)` | `yq -i` | validated |
| `patch_apply(patch, opts?)` | `patch -p1`, `git apply` | `opts`: `{ strip, dryRun }`; unified diff |

Design points to pin:

- **No `command_run` in the sandbox.** The shell is the one mutation path we cannot
  observe, snapshot, or scope: we do not know which files it changed, so the
  snapshot store has a hole — and inside a script its approval collapses into the
  script's single approval, so one "yes" would cover arbitrary shell. The sandbox's
  contract is that the only way to touch the world is through the typed, gated,
  intercepted tools; `command_run` breaks it. The agent keeps `run_command` as a
  **separate, first-class tool call** — its own reason, its own approval, its own
  audit row. The ergonomic cost is a separate build/test call after the script,
  which is the clearer shape anyway.
- **No `recall` in the sandbox — and `recall` is not a gated tool.** `recall` reads
  back a tool result the harness itself spilled into its own artifact store
  (`Context_Budget`). It touches nothing outside the harness, so it is a
  **built-in, controlled harness feature that bypasses the approval gate** —
  gating it would be second-guessing our own bookkeeping. It is also not something
  the agent should be scripting: it is a retrieval primitive the loop exposes, not
  a tool to compose. So it stays a direct, first-class call (ungated), never a
  `tools.*` method.
- **The gate is for world access.** The corollary: a tool that only reads the
  harness's own state is not gated and is not scriptable; a tool that touches the
  world is gated, and is the kind the sandbox may expose.
- **It is a *view* over the registry, not a second registry.** Each method routes
  to the same tool, so the approval ref, the `reason` requirement, the audit row,
  and the snapshot interception are identical to a direct call. If a method
  bypassed that, the sandbox would be an ungated shell one level up.
- **Naming.** The VM surface is snake_case noun-verb (`file_read`); the harness's
  current names are verb-noun (`read_file`). Either rename the tools to match (and
  migrate the approval refs) or expose the VM names as aliases in the view — a
  decision, not an accident.
- **The `reason`.** The harness requires a non-empty `reason` per tool call. In the
  sandbox the *script* is the one model tool call and carries one reason; the
  `tools.*` sub-calls inherit it. Confirm that is acceptable, or have the script
  pass a reason per call.
- **Approval.** Whether each `tools.*` call prompts, or the outer script call is
  approved once and the sub-calls are covered by it, is a policy decision — but the
  default must not be "a script runs N mutations unapproved".
- **Async by construction.** Native callbacks that block would stall the engine's
  thread; returning a Promise (resolved on completion) keeps `await` honest and
  lets the host run the work off the engine thread.
- **Return values are structured, not text.** A tool returns a value the script
  composes (a list of paths, a parsed object) — the point of code over a shell
  pipe. Text-only tools throw that away.

## Dependencies

### Internal

- `hildegard.helper.agent` — the tool registry and contract (`reason` validation,
  dispatch). The `tools` object is a **view over it**.
- `hildegard.helper.approval` — the `script:run` class ref and the per-tool refs the
  sub-calls carry.
- `hildegard.helper.files` — the world-touching tools that get injected.
- The turn cancellation seam (`Live Turn Control`) — the timeout rides it.
- `Workspace_Snapshots` — the interception the sub-calls must pass through, or the
  feature has a hole.
- `hildegard.helper.llm` — nothing new; the tool result is ordinary text.

### External

- **GocciaScript** (vendored by `scripts/fetch-goccia.sh` under `deps/goccia`) — the
  engine. MIT.
- Its generated data resources (Intl / TimeZone / Unicode) — the largest
  binary-size contributor; optionality is an open question for the spike.

## Risks

- **Binary size.** The engine is large: ~286,000 lines across 351 non-test units,
  plus ~2.3 MB of generated data resources (Intl 1.19 MB, TimeZone 718 KB, Unicode
  393 KB). The release delta could be several megabytes against a 2.9 MB base.
  Mitigation: the spike measures it first; the Temporal timezone resource is
  opt-out (`GOCCIA_TEMPORAL_NO_EMBEDDED_TZDATA`); if the delta is disproportionate,
  the feature is re-evaluated.
- **Bus factor.** Two contributors (the author and a bot), 196 open issues, a 0.x
  version. Mitigation: pin a version; use a narrow, facade-isolated surface; the
  engine is vendored, so upstream changes only arrive when we choose.
- **Build-time cost.** Compiling ~286k lines into the helper raises clean-build
  time. Mitigation: measure it; a cached precompiled unit directory under `build/`
  is the escape hatch (not committed artifacts).
- **String-mode boundary.** The engine's UTF-16 `string` versus the helper's UTF-8
  `AnsiString`. Mitigation: a single conversion point in the facade; the helper
  already links `cwstring`.
- **FPC version coupling.** The engine tracks FPC closely. Mitigation: the project
  already pins FPC 3.3.1; the pin and the engine pin move together.
- **The gate must survive the indirection.** The whole design rests on the injected
  tool functions being *the same* gated, intercepted calls as a direct invocation.
  Mitigation: the `tools` object is a view over the registry (one registry), and a
  test asserts each method dispatches through it.
- **Sandbox escape.** A model-authored script must not reach the host. Mitigation:
  core-only `TGocciaEngine`, `TGocciaCapabilities.None`, no runtime extensions, no
  FFI; the only reachable surface is the injected tools, which are themselves gated.
- **Realm bleed.** A script can mutate intrinsics (`Object.prototype`). Mitigation:
  recreate the engine per script for untrusted input.
- **Engine-integrity faults are fatal.** `EObjectCheck`, `EAccessViolation`,
  `EInvalidPointer`, `EDivByZero`, `EPrivilege`, `EExternalException` are re-raised
  past every guest `catch` and mean the process is no longer trustworthy.
  Mitigation: report and exit; never resume.
- **Approval collapse.** If the script's sub-calls are covered by one approval, a
  script could run N mutations under one "yes". Mitigation: make the policy
  explicit; the default must not be silent.
- **A capability-free sandbox is still a compute cost.** Cap time, instructions,
  and memory; run it off the UI thread; a script can loop.

## Out of Scope

- Runtime extensions (console, fetch, URL, CSV/TSV/JSONL/JSON5/TOML/YAML modules) —
  v1 is core-only; adopting one is a deliberate, separately-approved widening.
- A `command_run` method in the sandbox — the shell stays a separate, first-class
  tool call.
- `recall` in the sandbox — a harness-internal, ungated retrieval primitive.
- File or network *capabilities of the engine itself* — the injected tools are the
  only path to the world.
- The Remote Agent Link `run script` action — this feature provides the local tier;
  the link consumes it later.
- A JavaScript REPL or editor for the operator.

## Future Considerations

- **Data-format modules** (`goccia:csv`, `goccia:jsonl`, …) if core-only proves too
  bare for real work — each a deliberate capability decision.
- **Snapshot-in / diff-out** (`--copy` / `--copy-rw`): compute the would-be changes
  over a snapshot and apply only what the host asks — composes with Approval Path
  Scoping and is prior art for Remote Link writeback.
- **`run script` over the link**, reusing the same tool and approval class.
- **The engine's capability model** (immutable sets, deny-wins, nested contexts only
  narrow, auditable denials) as a cited reference in the Remote Agent Link SPEC's
  request-scoping design.
- **Unify the VM surface with the tool names** — rename `read_file` → `file_read`
  (and migrate the approval refs) or keep the aliases in the view.

## Notes

- **Supersedes the compute-only framing.** This feature began as *Sandboxed Script
  Compute* — a capability-free compute tier sitting *beside* the tools. The strategy
  moved to **composing the tools**: the same engine, with the harness's gated tools
  injected as native functions. The pure-compute case is simply a script that calls
  no tool, so the separate tier is subsumed. The engine, vendoring, limits, and
  spike carry forward unchanged; the FEATURE and its directory were renamed
  `Sandboxed_Script_Compute` → `Composed_Tool_Sandbox` to match.
- **Verified research** (against `main`, 2026-10-04). Every load-bearing claim was
  checked in the repository, not taken from a summary:

  | Claim | Verified |
  | --- | --- |
  | Object Pascal, FPC-native, MIT, active | README ("implemented in FreePascal, supports Delphi"); pushed daily; 0.14.0 |
  | Immutable `TGocciaCapabilities`; `None` by default; deny-wins regardless of order; nested contexts only narrow | `docs/permissions.md` |
  | Denials catchable and audited, naming capability and scope, never a host path | `docs/permissions.md` |
  | Inject values/functions/namespaces: `DefineLexicalBinding`, `TGocciaNativeFunctionValue.Create`, `RegisterNativeMethod` | `docs/embedding.md` |
  | Sandbox mode: in-memory VFS of snapshots; `--copy` vs `--copy-rw`; `--diff` | README |
  | Core-only `TGocciaEngine` vs runtime-layer `TGocciaRuntime`; pluggable resolver | `docs/embedding.md` |
  | `test262` on every PR and main commit, with a live dashboard | README |
  | **Not** a single-file amalgamation; no library target; `{$mode delphiunicode}` | source tree; `build.pas`; `source/shared/Shared.inc` |

- **The first task is a spike**, not a SPEC: build the engine with FPC 3.3.1,
  embed `TGocciaEngine` core-only, inject one trivial tool, and measure (a) the
  release-binary delta, (b) the clean-build time, (c) whether the
  Intl/Temporal/Unicode resources can be dropped. Record the numbers here and gate
  the SPEC on them.
- **Reuse note (Ponytail):** the engine is a dependency, not something to build; the
  new work is a facade, a `tools` view, a tool, and a build integration. The
  capability model is reused wholesale rather than reimplemented.
