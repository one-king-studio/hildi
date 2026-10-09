# GocciaScript Embedding (research)

Notes from the GocciaScript source and docs, for what we want from it: a
**composed-tool sandbox** (`Composed_Tool_Sandbox`). The model writes one script
that **calls our gated tools** — loops, chaining, conditionals — as **one** tool
call, so it stops reaching for `bash` to orchestrate and every file modification
still goes through our gate.

(The feature began as a capability-free *compute* tier — a script beside the tools.
That framing is subsumed: a script that calls no tool *is* the compute case, so
there is one feature, not two. The surface and its rules now live in
`docs/features/Composed_Tool_Sandbox/FEATURE.md`.)

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

So `tools.file_read(path)`, `tools.file_edit(path, old, new)`,
`tools.file_search_replace(glob, …)` become ordinary JS calls whose Pascal
callbacks are **our gated tools**.

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

## How it maps to our use

`TGocciaCapabilities.None`, core-only `TGocciaEngine`, a timeout, an instruction
cap, a memory cap, console capture for the result — no FS, no net, no exec. On top
of that we **inject the harness's tools as native functions/objects**. The script
then loops and chains tool calls; the only way to touch the world is through those
callbacks, so every mutation is **gated, logged, and snapshot-intercepted** exactly
as a direct call would be. One model turn produces one script instead of N tool
round-trips. The surface and its rules are specified in
`docs/features/Composed_Tool_Sandbox/FEATURE.md`.

The critical invariant: **the sandbox must not become a bash backdoor.** No
`exec`, no `ffi`, no `net`, no `read` outside the workspace; the injected tool
functions go through the same approval gate and the same file-modification
interception as a direct tool call — otherwise the gate has just moved one level
up and we have re-created the ungated shell.

## The bash idioms we replace with first-class tools

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

## Roadmap

The full picture, in the order it lands:

1. **Vendor** — `scripts/fetch-goccia.sh` → `deps/goccia/` (pinned, checksummed).
   *Done.*
2. **Composed-tool sandbox** (`Composed_Tool_Sandbox`) — the capability-free
   engine with the harness's tools **injected as native functions/objects**. One
   script, N tool calls; every call the same gated, approval-checked,
   snapshot-intercepted path as a direct call.
3. **First-class edit tools** — the table above: `apply_patch`, a regex
   `edit_file`, `search_replace`, `edit_json`/`edit_yaml`, file ops. These make the
   gated path the *easy* path, so the sandbox is an optimization rather than a
   requirement.
4. **Snapshots** (`Workspace_Snapshots`) — every tool-driven file change is
   intercepted and recorded, so the operator can see a turn's diff and undo it.
   The sandbox's calls go through the same interception, or the feature has a hole.

The ordering matters: (1) unblocks (2); (3) is independently valuable and shrinks
the need for (2); (4) is what makes all of it safe to let run.

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
  (`Composed_Tool_Sandbox`'s first task is exactly that spike).

## Sources

- `deps/goccia` (vendored by `scripts/fetch-goccia.sh`, commit `531fb52…`):
  `docs/embedding.md`, `docs/permissions.md`, `docs/capability-audit.md`,
  `docs/architecture.md`, `docs/bytecode-vm.md`, `docs/host-environment.md`,
  `docs/built-ins-ffi.md`.
- `docs/features/Composed_Tool_Sandbox/FEATURE.md` (the feature).
- `docs/research/cli-agent-harness-parity.md` (the field's "code execution /
  Codemode" direction: opencode, Pi).
