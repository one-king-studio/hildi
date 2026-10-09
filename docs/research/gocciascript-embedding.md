# GocciaScript Embedding (research)

Notes from the GocciaScript source and docs, for the two things we want from it:

1. **A capability-free compute tier** (`Sandboxed_Script_Compute`): the model
   writes a small script for deterministic data/text work between "think" and
   "act".
2. **A composed-tool sandbox**: the model writes a script that **calls our tools**
   — loops, chaining, conditionals — as **one** tool call, so it stops reaching
   for `bash` to orchestrate and every file modification still goes through our
   gate.

## Where the source lives

**Vendored** at `deps/goccia/` by `scripts/fetch-goccia.sh`, which pins upstream
commit `531fb523efe10375858ac29faf3da5dd15195418`, verifies the archive's SHA-256
(`c0a97fe9…`), and extracts it — the project's `deps/` pattern, like SQLite and
mbedTLS: fetched, not committed. The script is idempotent; re-run it any time.

The useful material is its `docs/`: `embedding.md`, `capability-audit.md`,
`permissions.md`, `architecture.md`, `bytecode-vm.md`, `host-environment.md`,
`built-ins-ffi.md`.

GocciaScript is an MIT, FPC-native ECMAScript engine (tree-walk interpreter and a
bytecode VM), embeddable from Pascal.

## The embedding surface we would use

**Entry points.** `TGocciaRuntime.Create(name, Source)` for the runtime layer
(file loading + runtime extensions); `TGocciaEngine.Create(name, Source, Executor)`
for a core-language-only engine (`TGocciaInterpreterExecutor` for tree-walk,
`TGocciaBytecodeExecutor` for the VM). `RunScript*` are one-shot helpers; a
long-lived engine reuses `Execute` across calls.

**Capabilities — the sandbox's whole point.** Every constructor has an overload
taking an immutable `TGocciaCapabilities`; the overloads without one use
**`TGocciaCapabilities.None`**. Nothing outside the process is reachable unless a
capability is granted, and grants are **scoped**:

```pascal
Caps := TGocciaCapabilities.None.Allow(gcImport, 'node_modules=/srv/app');
Caps := TGocciaCapabilities.None.Allow(gcNet, 'private');
```

`net` is judged per host *and* per resolved address (a private/loopback/link-local
address passes only when a scope names it). `ffi` gates the native shared-library
extension (`TGocciaFFIRuntimeExtension`, `FFI.open`) — we would never grant it.

**Injecting our tools as JS.** This is the mechanism for the composed-tool
sandbox:

- a value: `Engine.Interpreter.GlobalScope.DefineLexicalBinding(name, value, dtConst)`
- a function: `TGocciaNativeFunctionValue.Create(callback, name, arity)`, where
  `callback` is `function(const AArgs: TGocciaArgumentsCollection; const AThisValue: TGocciaValue): TGocciaValue of object`
- a namespace with methods: `TGocciaObjectValue.Create` + `RegisterNativeMethod(...)`

So `files.read(path)`, `files.edit(path, old, new)`, `search.replace(glob, …)`
become ordinary JS calls whose Pascal callbacks are **our gated tools**.

**Limits.** `StartExecutionTimeout(ms)` / `ClearExecutionTimeout`,
`StartInstructionLimit(steps)`, `SetMaxStackDepth(frames)`, and the GC's
`TGarbageCollector.MaxBytes` (a memory ceiling; the VM charges its stacks to it).
Each is thread-local.

**Console capture.** `OutputCallback` (takes priority) or `LogCallback` (fires
even when stdout is suppressed) — how we surface a script's output as the tool
result.

**Host modules.** `RegisterHostModule(name, Module)` lets a script `import` a
Pascal-provided module; virtual modules cover host configuration through ordinary
ES imports.

**Realm isolation.** Each engine owns a realm of intrinsics, torn down with it. To
give an untrusted script a clean slate (a script can mutate `Object.prototype`),
**recreate the engine per script** — a reused engine intentionally shares
intrinsics.

**Errors.** `TGocciaSyntaxError`/`LexerError`/`RuntimeError`/`TypeError`/
`ReferenceError`/`ThrowValue`/`TimeoutError`/`InstructionLimitError` are catchable
Pascal exceptions. **Engine-integrity faults** (`EObjectCheck`,
`EAccessViolation`, `EInvalidPointer`, `EDivByZero`, `EPrivilege`,
`EExternalException`) are re-raised past every guest `catch` and escape
`Execute`: they mean the process is no longer trustworthy — report and exit, do
not resume. `EOutOfMemory` stays catchable.

**FPU mask.** The engine masks FPU exceptions on creation (for IEEE 754 `NaN`/
`Infinity`) and restores the host's mask in the destructor — transparent for
one-shot use, notable for a long-lived engine.

**GC.** A mark-and-sweep GC initializes automatically; no manual interaction in
the normal case.

## How it maps to our two uses

**Compute tier.** `TGocciaCapabilities.None`, core-only `TGocciaEngine`, a timeout,
an instruction cap, a memory cap, console capture for the result. No FS, no net,
no exec — it can only compute. That is exactly `Sandboxed_Script_Compute`'s
"capability-free compute tier".

**Composed-tool sandbox.** Same capability-free engine, but we **inject the
harness's tools as native functions/objects**. The script then loops and chains
tool calls; the only way to touch the world is through those callbacks, so every
mutation is **gated, logged, and snapshot-intercepted** exactly as a direct call
would be. One model turn produces one script instead of N tool round-trips.

The critical invariant: **the sandbox must not become a bash backdoor.** No
`exec`, no `ffi`, no `net`, no `read` outside the workspace; the injected tool
functions go through the same approval gate and the same file-modification
interception as a direct tool call — otherwise the gate has just moved one level
up and we have re-created the ungated shell.

## End to end

The full picture, in the order it would land:

1. **Vendor** — `scripts/fetch-goccia.sh` → `deps/goccia/` (pinned, checksummed).
   *Done.*
2. **Compute tier** (`Sandboxed_Script_Compute`) — a capability-free engine: no
   FS, net, or exec; a timeout, an instruction cap, a memory cap; the script's
   output is the tool result. The model's "think in code" step for deterministic
   data/text work.
3. **Composed-tool sandbox** — the same capability-free engine, but with the
   harness's tools **injected as native functions/objects**. The model writes one
   script that loops and chains tool calls; every call is the same gated,
   approval-checked, snapshot-intercepted path as a direct call. One turn, N tool
   calls.
4. **First-class edit tools** — the table above: `apply_patch`, a regex
   `edit_file`, `search_replace`, `edit_json`/`edit_yaml`, file ops. These make the
   gated path the *easy* path, so the sandbox is an optimization rather than a
   requirement.
5. **Snapshots** (`Workspace_Snapshots`) — every tool-driven file change is
   intercepted and recorded, so the operator can see a turn's diff and undo it.
   The sandbox's calls go through the same interception, or the feature has a hole.

The ordering matters: (1) unblocks (2) and (3); (4) is independently valuable and
shrinks the need for (3); (5) is what makes all of it safe to let run.



Agents reach for `bash` when a tool is missing. The strategies, grouped (the
*group* is the tool to add):

| Strategy | The bash idiom | First-class tool |
| --- | --- | --- |
| In-place line substitution | `sed -i`, `perl -pi -e`, `awk …>tmp&&mv`, `ed`/`ex`/`vim -c`, `python -c` | regex `edit_file` (pattern + flags) |
| Whole-file overwrite | `cat > f <<'EOF'`, `printf '…' > f`, `tee` | `write_file` (already; make it the obvious path) |
| Append | `>>`, `tee -a` | `append_file` (or `write_file` with a mode) |
| Multi-file search/replace | `grep -rl X \| xargs sed -i`, `find … -exec sed` | `search_replace` over a glob, with a dry-run count |
| Structured edits | `jq`, `yq`, `xmlstarlet` | `edit_json` / `edit_yaml` (path + value, validated) |
| Patch application | `patch -p1`, `git apply`, `diff -u \| patch` | `apply_patch` (unified diff) |
| File/dir ops | `mv`, `cp`, `rm`, `mkdir -p`, `touch`, `ln`, `chmod`, `truncate` | `move`/`copy`/`delete`/`mkdir` |
| Line-range ops | `head`/`tail`, `sed -n 'a,bp'`, `sort -o`, `uniq -o` | `read_file` with a range |
| Revert | `git checkout -- f`, `cp f.bak f` | the snapshot undo (see `Workspace_Snapshots`) |

The point is not to ban `bash` (you cannot); it is to make the **gated** path the
**easier** path, so the agent chooses a tool we can approve, diff, and snapshot
over a shell we cannot — and the sandbox then removes the *orchestration* reason
to use it at all.

## The VM tool surface (`tools.*`)

The sandbox exposes the harness's tools as **one global object, `tools`**, with
snake_case methods. They are **async** (each returns a Promise), so a script
awaits them and a loop over many files is still one turn:

```javascript
const src = await tools.file_read("some/file.ps");
const files = await tools.file_glob("src/**/*.pas");
for (const f of files) {
  await tools.file_replace_regex(f, "OldName", "NewName", { all: true });
}
await tools.patch_apply(patchText, { dryRun: true });
```

The methods, and the bash idiom each replaces:

| VM method | Replaces | Notes |
| --- | --- | --- |
| `file_read(path, opts?)` | `cat`, `head`, `tail`, `sed -n 'a,bp'` | `opts`: `{ offset, limit }` for a line range |
| `file_write(path, content)` | `cat > f <<EOF`, `printf > f`, `tee` | atomic; the existing `write_file` |
| `file_append(path, content)` | `>>`, `tee -a` | |
| `file_edit(path, old, new, opts?)` | `ed`/`ex`, small `sed` | exact-string replace; the existing `edit_file` |
| `file_replace_regex(path, pattern, repl, opts?)` | `sed -i`, `perl -pi -e`, `python -c` | `opts`: `{ all, flags }` |
| `file_search_replace(glob, pattern, repl, opts?)` | `grep -rl X \| xargs sed -i`, `find … -exec sed` | `opts`: `{ dryRun, all, flags }`; returns the changed paths + counts |
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
| `command_run(command, opts?)` | the shell itself | the existing `run_command` — still gated, still there for what the tools cannot express |
| `recall(id, opts?)` | — | the existing `recall_tool_result` |

Design points to pin:

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
  approved once and the sub-calls are covered by it, is a policy decision — but
  the default must not be "a script runs N mutations unapproved".
- **Async by construction.** Native callbacks that block would stall the engine's
  thread; returning a Promise (resolved on completion) keeps `await` honest and
  lets the host run the work off the engine thread.
- **Return values are structured, not text.** A tool returns a value the script
  composes (a list of paths, a parsed object) — the point of code over a shell
  pipe. Text-only tools throw that away.

## Risks / caveats

- **The vendored source is fetched, not committed.** `scripts/fetch-goccia.sh`
  pins the commit and verifies the archive; re-run it after a `make clean` or on a
  fresh checkout.
- **A capability-free sandbox is still a compute cost.** Cap time, instructions,
  and memory; run it off the UI thread; a script can loop.
- **Realm bleed.** Recreate the engine per script for untrusted input; a reused
  engine shares intrinsics by design.
- **Engine-integrity faults are fatal.** Treat `EObjectCheck`/`EAccessViolation`/…
  as "the process is broken", not as a script error.
- **The gate must survive the indirection.** The whole design rests on the
  injected tool functions being *the same* gated, intercepted calls.
- **Portability.** GocciaScript is FPC-native and builds with our compiler; verify
  the tree-walk vs bytecode choice and the release-binary delta before committing
  (`Sandboxed_Script_Compute`'s first task is exactly that spike).

## Sources

- `deps/goccia` (vendored by `scripts/fetch-goccia.sh`, commit `531fb52…`):
  `docs/embedding.md`, `docs/permissions.md`, `docs/capability-audit.md`,
  `docs/architecture.md`, `docs/bytecode-vm.md`, `docs/host-environment.md`,
  `docs/built-ins-ffi.md`.
- `docs/features/Sandboxed_Script_Compute/FEATURE.md` (the compute tier).
- `docs/research/cli-agent-harness-parity.md` (the field's "code execution /
  Codemode" direction: opencode, Pi).
