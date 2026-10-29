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
  script rather than 40 model turns — while still being asked to approve the
  mutations, with the option to pre-grant a class so it is not 40 prompts.
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
      (required non-empty `reason`; approval-gated as the class `script:run`). The
      reason is the **script's**; it flows to every sub-call.
- [ ] Execution is in-process, core-language-only, with
      `TGocciaCapabilities.None`: no filesystem, network, FFI, exec, or
      time-of-day; no runtime globals.
- [ ] The harness's world-touching tools are injected as **one global `tools`
      object** (snake_case, async). Each method routes to the same registered tool
      and resolves **its own** approval ask — same ref, same options, same audit
      row, same snapshot interception as a direct call — with the script's reason
      flowing to every sub-call.
- [ ] Each method returns a Promise and **blocks on its approval** (the engine
      parks on the `await`; the host pumps the ask off the engine thread), so the
      script sees an ordinary `await` and needs no approval concept of its own.
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
      the tool and the denial, never a host path; the script may catch it and
      continue, exactly as it catches any other rejection.

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

### Tool reference

Each method is a thin, **async** wrapper over a registered tool. "Returns" is
indicative — the SPEC pins the exact shape. Every method carries the script's
`reason` and is gated exactly like the tool it wraps.

**Reading and writing files**

- `file_read(path, opts?) → { content, lines, truncated }` — read a text file in
  the workspace. `opts.offset` (1-based first line) and `opts.limit` (max lines;
  `0` = all) select a range. Output is bounded; a large read sets `truncated`.
  Replaces `cat`, `head`, `tail`, `sed -n 'a,bp'`.
- `file_write(path, content) → { bytes }` — create or overwrite a file atomically.
  Replaces `cat > f <<EOF`, `printf > f`, `tee`. *The existing `file_write`.*
- `file_append(path, content) → { bytes }` — append; creates the file if absent.
  Replaces `>>`, `tee -a`.
- `file_edit(path, old, new, opts?) → { replaced }` — replace an exact string;
  fails if it is absent or ambiguous unless `opts.all`. Replaces `ed`/`ex`, small
  `sed`. *The existing `file_edit`.*
- `file_replace_regex(path, pattern, repl, opts?) → { replaced }` — regex replace
  within one file. `opts.all` (every match), `opts.flags`. Replaces `sed -i`,
  `perl -pi -e`, `python -c`.
- `file_search_replace(glob, pattern, repl, opts?) → { files, replacements }` —
  regex replace across the files matching the `glob` pattern. `opts.dryRun` returns the count
  and the paths without writing. Replaces `grep -rl X | xargs sed -i`,
  `find … -exec sed`.

**Filesystem operations**

- `file_delete(path) → { deleted }` — remove a file. Replaces `rm`.
- `file_move(src, dst) → { moved }` — rename or move. Replaces `mv`.
- `file_copy(src, dst) → { copied }` — copy. Replaces `cp`.
- `file_mkdir(path) → { created }` — create a directory and its parents. Replaces
  `mkdir -p`.
- `file_list(path, opts?) → { entries }` — list a directory; `opts.recursive`.
  Replaces `ls`, `find`. *The existing `file_list`.*
- `file_glob(pattern) → [paths]` — find files by path pattern (`*`, `?`, `**`).
  Replaces `find -name`, shell globs. *The existing `file_glob`.*
- `file_grep(pattern, opts?) → [matches]` — search file contents; `opts.glob`,
  `opts.context`. Replaces `grep`, `rg`. *The existing `file_grep`.*
- `file_stat(path) → { size, mtime, mode, type }` — stat a path. Replaces `stat`,
  `ls -l`.

**Structured formats**

- `json_read(path, pointer?) → value` — parse JSON, optionally at a JSON pointer.
  Replaces `jq`.
- `json_edit(path, pointer, value) → { written }` — set a JSON pointer and write
  back, validated (a parse failure never writes). Replaces `jq '…' > f`.
- `yaml_read(path, path_expr?) → value` — parse YAML. Replaces `yq`.
- `yaml_edit(path, path_expr, value) → { written }` — set a path and write back,
  validated. Replaces `yq -i`.

**Patches**

- `patch_apply(patch, opts?) → { applied, rejected }` — apply a unified diff;
  `opts.strip` (default 1), `opts.dryRun`. Replaces `patch -p1`, `git apply`.

Design points to pin:

- **No `command_run` in the sandbox.** The shell is the one mutation path we cannot
  observe, snapshot, or scope: we do not know which files it changed, so the
  snapshot store has a hole. The sandbox's contract is that the only way to touch
  the world is through the typed, gated, intercepted tools; `command_run` breaks it
  — a script could `sh -c` its way around every one of them. The agent keeps
  `run_command` as a **separate, first-class tool call** — its own reason, its own
  approval, its own audit row. The ergonomic cost is a separate build/test call
  after the script, which is the clearer shape anyway.
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
- **Naming — the existing file tools are renamed to match.** The VM surface is
  snake_case noun-verb (`file_read`); the harness's current names are verb-noun
  (`read_file`). **Decision: rename the existing file tools to the VM names** —
  `read_file`→`file_read`, `write_file`→`file_write`, `edit_file`→`file_edit`,
  `list_dir`→`file_list`, `glob`→`file_glob`, `grep`→`file_grep` — so the VM uses
  the *same* names rather than an alias layer. `run_command` and
  `recall_tool_result` keep their names (not file tools; the shell and recall stay
  outside the sandbox anyway).
- **The `reason` — one per script.** The harness requires a non-empty `reason` per
  tool call. In the sandbox the *script* is the one model tool call and carries one
  reason; the `tools.*` sub-calls **inherit it** rather than inventing their own.
  The reason describes the whole script ("rename the symbol across `src/`"), which
  is what the operator is approving; N per-call reasons would be noise the model has
  to fabricate.
- **Approval — every sub-call pipes through the normal flow.** There is no "one
  approval covers the script" shortcut: each `tools.*` call resolves its own ask
  exactly as a direct call would (same ref, same `once`/`exact`/`dir`/… options,
  same audit row). The `run_script` call is approved as `script:run`, but that
  grants *the script*, not its mutations — so a script can never run N mutations
  under one "yes". The cost is N prompts; the operator can pre-grant a class
  (`file:write` on a directory, say) to keep it quiet.
- **Async by construction — it is *how* approval blocks.** Every injected method
  returns a Promise, and that is not cosmetic: an approval ask is a *wait* (the
  operator has to answer), and a synchronous native callback would freeze the engine
  while it waited. The Promise lets the call **block on the approval** — the engine
  parks on the `await`, the host pumps the ask off the engine thread, and the script
  simply sees an `await` that took a while. It cannot tell a fast call from an
  approved one, so it needs no approval concept of its own.
- **Return values are structured, not text.** A tool returns a value the script
  composes (a list of paths, a parsed object) — the point of code over a shell
  pipe. Text-only tools throw that away.

## Dependencies

### Internal

- `hildi.agent` — the tool registry and contract (`reason` validation,
  dispatch). The `tools` object is a **view over it**.
- `hildi.approval` — the `script:run` class ref and the per-tool refs the
  sub-calls carry.
- `hildi.files` — the world-touching tools that get injected.
- The turn cancellation seam (`Live Turn Control`) — the timeout rides it.
- `Workspace_Snapshots` — the interception the sub-calls must pass through, or the
  feature has a hole.
- `hildi.llm` — nothing new; the tool result is ordinary text.

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

### Spike results (2026-10-16, FPC 3.3.1 aarch64-darwin)

**The engine builds, embeds, and runs.** A minimal program — core-only
`TGocciaEngine` + `TGocciaInterpreterExecutor`, no capabilities — compiles against
the vendored tree and executes a script (`for (let i of [1,2,3,4,5]) total += i`
→ `15`). Numbers, measured:

| Metric | Value |
| --- | --- |
| Clean build (291k lines) | **~43 s** |
| Full engine binary | **23.5 MB** |
| Lean (drop Intl + TZ + UCD) | **21.2 MB** |
| Engine code alone | ~8.2 MB |
| Intl resource | 1.19 MB |
| TimeZone resource | 0.72 MB |
| UCD resource | 0.39 MB |
| Empty FPC program (baseline) | 0.47 MB |
| Our TUI binary, for scale | 8.2 MB |

**Verdict: the binary delta is the concern, and it is larger than the FEATURE
feared.** The engine adds ~**8.2 MB of code** over a baseline — roughly the size
of the *entire current TUI binary* — before any data. Dropping all three
resources saves ~2.3 MB (23.5 → 21.2 MB), so **the resources are not the main
cost; the engine code is.** The Intl opt-out alone saves ~1.2 MB and is the
cheapest single win.

**Two integration obstacles found, both real:**

1. **A `constref` vs `const` mismatch.** Seven engine sites declare comparison
   callbacks as `{$IFDEF FPC}constref{$ELSE}const{$ENDIF}`, but this FPC's
   `TComparison<Int64>` wants plain `const`. Verified in isolation: `const`
   compiles, `constref` fails with *"Incompatible type … expected
   `TCOMPARISON<System.Int64>`"*. A vendored-patch or an upstream fix is needed.
2. **The FPC compiler crashes (EAccessViolation) on the debug build.** Building
   with `-gl` (line info) makes `ppca64` die with an internal exception, at a
   *different* unit each run (nondeterministic — heap/stack pressure, not one
   construct). The engine's own **production** flags (`-O4 -dPRODUCTION`) build
   cleanly; the debug build does not. This matters because `make check` uses
   debug flags — the engine cannot be compiled into the test binary as-is.

**Recommendation:** gate the SPEC on the size decision. ~8 MB of engine code
against an 8 MB TUI (doubling it) is a real cost for a feature whose value is
"one turn instead of N". The lighter path — the first-class edit tools, already
landed — delivers most of the bash-avoidance value at zero engine cost. Proceed
to a SPEC only if the composition win justifies roughly doubling the binary, or
if the engine can be trimmed (a build-time feature set, or the bytecode VM
dropped for the interpreter only).


---

## Status: parked (2026-10-17)

**Decision: park this feature.** The engine works — Phase 1–5 landed, `make
check` is green, the AST arena is fixed and the leak floor is bounded — but the
engine is **still too buggy to be a load-bearing security boundary**, and the
cost/benefit no longer holds.

### Why

The arena work fixed a real, deep defect (a whole-tree leak, ~8 blocks per
statement, unbounded in script size; and a latent use-after-free for any closure
that outlived its run). Fixing it took **six fork commits** and exposed **five
further ownership defects of the same kind**, each found only by running the
engine's own heaptrc suite:

1. `TGocciaProgram` had no destructor — the body list leaked.
2. Four node-holding classes never registered with the arena
   (`TGocciaDestructuringProperty`, `TGocciaObjectMatchProperty`,
   `TGocciaMatchClause`, `TGocciaClassDefinition`).
3. Four parser **recovery** paths freed arena-owned nodes — a double free that
   crashed the test runner (`EBusError`/`EAccessViolation`) in
   warning-recovery mode.
4. `DefaultOptions` left a new struct field uninitialized.
5. A class-var singleton graph is pinned at engine construction with no unpin.

Every one of these is the *same shape*: ownership declared in one place and
violated in another, invisible until a specific path runs. That is not a
one-time debt; it is the engine's current maturity. A security boundary cannot
rest on a component whose failure mode we keep discovering by accident.

### What "park" means here

- **Code is kept, not deleted**: `hildi.script`,
  `hildi.tool.script`, `run_script`, the session wiring, the fork
  pin, the leak-floor machinery. It is not advertised as the answer to compound
  work. *(Moved out of the build on 2026-10-18 — see the note below.)*
- **The vendored fork is kept** (`github.com/johnrcui/GocciaScript`, branch
  `ast-arena`, six commits) so the fixes are preserved and can become an
  upstream PR whenever that is worth doing.
- **The `run_script` tool stays available** but is not the recommended path for
  a batch; the first-class file tools and the shell remain the recommended
  paths.

> **Superseded 2026-10-18.** The bullets above described *parked* (in the
> tree, not recommended). The operator then went further and **detached** the
> engine: `9e4e584` removed `libgoccia` from the Makefile and stripped the
> session wiring, deleted `deps/goccia`, and moved this directory's code, tests
> and scripts here. So `run_script` is **not** available in the built binary,
> and this code is not compiled or gated — it is reference material. The leak
> gate is strict zero again. Decision and re-entry conditions:
> [REWRITE_PROPOSAL.md](REWRITE_PROPOSAL.md).

### The reason we were here, restated

The engine was adopted to gate **compound scripts** — the case where the model
would otherwise reach for `bash` and hide a loop inside one unobservable
approval. The deeper reading of that goal is: **the problem is the shell, not
the absence of a scripting tier.** A script engine we gate is a second
interpreter to maintain; gating the shell we already have addresses the same
risk at the boundary where it actually occurs.

That reframing moves the work to
[Tree-Sitter](../Tree_Sitter/FEATURE.md) — a correct shell ask set for the
approval gate — and the lessons below are carried there.

**If the engine is ever fixed enough to reconsider this**, read
[REWRITE_PROPOSAL.md](REWRITE_PROPOSAL.md) first: it lists every defect we hit,
separates what was ours from what was the engine's, names what to drop, and gives
an admission battery the engine must pass *before* any v2 code is written.
Building this feature is not the first task; running that battery is.
