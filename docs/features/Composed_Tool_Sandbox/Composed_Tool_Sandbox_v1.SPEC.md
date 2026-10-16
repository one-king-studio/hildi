# Component Specification: Composed Tool Sandbox v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.agent` (the tool registry + `TToolHandler`),
`hildegard.helper.approval` (the gate the sub-calls route through),
`hildegard.helper.files` / `hildegard.helper.command.tool` (the world-touching
tools the sandbox exposes), the vendored engine (`deps/goccia`, via
`scripts/fetch-goccia.sh`).

**Depended on by:** nothing (a leaf capability).

## Purpose

A `run_script` tool that executes a model-authored JavaScript program able to
call the harness's own gated tools — `await tools.file_read(...)`,
`await tools.file_search_replace(...)` — as **one** tool call. The engine is
GocciaScript, embedded in-process core-only with `TGocciaCapabilities.None`; the
injected `tools` object is the only reachable surface, and each method is a
**view over the registry**, so every sub-call passes the same approval gate,
`reason` requirement, and audit row as a direct call.

The spike (recorded in `FEATURE.md`) proved the engine builds, embeds, and runs;
the operator accepted the ~8 MB binary delta. This SPEC pins the integration.

## Prior art and reuse

| Need | Existing | Change |
| --- | --- | --- |
| The tool registry + handler contract | `hildegard.helper.agent` | reuse; the `tools` object is a view over it |
| The approval gate | `IApprovalService` (the same one a tool uses) | reuse |
| The async "block then settle" pattern | the harness's own worker/queue | reuse the idea: the callback blocks |
| Vendored-dep build integration | `scripts/fetch-sqlite.sh`, `fetch-mbedtls.sh`, the Makefile's `libstatic` pattern | follow it for `fetch-goccia.sh` |
| Console capture | the engine's `OutputCallback` | reuse |

The genuinely new work: a facade unit, the `tools` view, the `run_script` tool,
and the Makefile integration.

## Requirements

### Functional

- [ ] `run_script(script, reason)` is registered and advertised like every other
      tool (required non-empty `reason`; gated as `script:run`). The `reason` is
      the **script's** and flows to every sub-call.
- [ ] Execution is in-process, core-language-only, `TGocciaCapabilities.None`:
      no filesystem, network, FFI, exec, or time-of-day; no runtime extensions.
- [ ] The harness's world-touching tools are injected as **one global `tools`
      object** (snake_case, async). Each method routes to the same registered
      tool and resolves **its own** approval ask — same ref, same options, same
      audit row — with the script's `reason` on every sub-call.
- [ ] Each method returns a Promise and **blocks inside its callback** until the
      tool (and its approval) completes, then returns an **already-settled**
      promise (rejects on denial). The script sees an ordinary `await` and needs
      no approval concept of its own. (Spike path A — no engine change.)
- [ ] `run_command` is **not injected**; `recall_tool_result` is **not injected**.
- [ ] Limits are enforced: a wall-clock timeout wired to the turn's cancel check,
      an instruction cap, a memory cap, and an output-size cap.
- [ ] The result is structured: standard output, the script's return value, and a
      typed error on failure or timeout — never a crash of the harness.
- [ ] A denied tool call inside a script surfaces as a script-level error naming
      the tool and the denial; the script may catch it and continue.
- [ ] The engine is **recreated per script** (realm isolation: a script can
      mutate intrinsics).
- [ ] An **engine-integrity fault** (`EObjectCheck`, `EAccessViolation`,
      `EInvalidPointer`, `EDivByZero`, `EPrivilege`, `EExternalException`) is not
      swallowed: it fails the tool call with a clear message and the turn
      continues (the process is not trusted after such a fault, but we do not
      crash the TUI).

### Non-Functional

- [ ] The engine is compiled **once**, with its own production flags, into a
      cached unit directory; the debug and leak builds consume those units
      rather than recompiling the engine. (Rationale: the spike found FPC 3.3.1's
      compiler crashes nondeterministically on the engine under `-gl`; the
      engine's production flags build cleanly. See "Build integration".)
- [ ] `make check` green with the engine linked; the engine's allocations do not
      leak (the facade frees the engine + executor per call).
- [ ] The release binary stays self-contained (no runtime `.dylib`/`.so`).
- [ ] Portability: macOS + Linux, arm64 + x86-64; FPC 3.3.1.

## Contracts & Interfaces

> Pascal type declarations; bodies are the implementer's.

```pascal
unit hildegard.helper.script;
{ The facade over the vendored engine: run one script with the harness's tools
  injected, and map the result. Isolates the engine's surface so an upgrade is a
  facade change. }

type
  { Resolves one injected tool call: run the named tool with these JSON
    arguments and the script's reason, returning the tool's text result. False +
    AError on a tool failure or a denial. Called on the engine thread. }
  TScriptToolInvoker = function(const AName, AArgumentsJson,
    AReason: string; out AResult, AError: string): Boolean of object;

  TScriptLimits = record
    TimeoutMs: Integer;       // wall-clock; 0 => default
    MaxInstructions: Int64;   // 0 => default
    MaxMemoryBytes: Int64;    // 0 => default
    MaxOutputBytes: Integer;  // 0 => default
  end;

  TScriptResult = record
    Ok: Boolean;
    Output: string;           // captured console output
    Value: string;            // the script's return value, as text
    Error: string;            // '' when Ok
  end;

{ Run ASource with ATool as the tools.* dispatcher. Never raises for a guest
  fault; returns Ok=False with Error set. }
function RunScript(const ASource: string; const AReason: string;
  const AInvoke: TScriptToolInvoker; const ALimits: TScriptLimits;
  const ACancel: TScriptCancelCheck): TScriptResult;
```

```pascal
unit hildegard.helper.tool.script;
{ The run_script tool: parses its arguments, wires the facade to the registry,
  and gates the call. }

type
  TScriptTool = class(TInterfacedObject)
  public
    constructor Create(ATools: TToolRegistry; AService: IApprovalService);
    { Registers run_script. }
    procedure Register(ATools: TToolRegistry);
    { Matches TToolHandler; public for direct testing. }
    function Run(const AArgumentsJson: string; out AResult: string;
      out AError: string; AObserver: TToolObserver = nil): Boolean;
  end;
```

## Architecture

### The `tools` object

Built per script from the registry: for each tool the sandbox may expose (every
registered tool except `run_command` and `recall_tool_result`), a native method
`tools.<name>` whose Pascal callback:

1. reads the JSON arguments (a `tools.file_read({path, reason})` call arrives as
   a JS object; the facade serialises it to JSON),
2. calls `AInvoke(name, argsJson, scriptReason, ...)`, which dispatches through
   the registry (the same handler a direct call uses),
3. returns an already-settled promise carrying the result text (or a rejection
   with the error).

The tool's **own** approval ask fires inside that dispatch — identical to a
direct call.

### Build integration

- `scripts/fetch-goccia.sh` (exists) vendors the pinned tree into `deps/goccia`.
- A **patch step** applies the two spike fixes to the vendored tree (they are
  engine bugs against this FPC, not our code):
  1. the seven `{$IFDEF FPC}constref…` comparison callbacks → `const`;
  2. (if still needed) any follow-on compiler-compatibility fix.
  The patch is a small, documented, idempotent `scripts/patch-goccia.sh` — a
  vendored-tree patch, like a `deps/` fixup, never a change to our `src/`.
- The Makefile gains a `libgoccia` target that compiles the engine's units
  **once**, with the engine's own flags (`-O4 -dPRODUCTION` + the resource
  opt-outs), into `build/units/goccia`. The debug, leak, and release builds add
  `-Fu<that dir>` and never recompile the engine.
  - **Resource opt-outs:** build with `GOCCIA_INTL_NO_EMBEDDED_CLDR` (the
    cheapest ~1.2 MB win) by default; TZ/UCD stay unless a need appears.
  - **Why a separate compile:** the spike found FPC 3.3.1's compiler
    EAccessViolations on the engine under `-gl` (nondeterministic, unit-varying
    — heap pressure, not one construct). Precompiled prod-flag units sidestep it
    and keep `make check`'s debug/leak flags intact for our own code.

### The engine's boundary

- The engine is `{$mode delphiunicode}` (UTF-16 `string`); our units are UTF-8
  `{$mode delphi}`. Every value crossing the boundary converts **explicitly**
  (`UTF8Encode`/`UTF8Decode`), the same rule the codebase already follows.
- The engine's public surface is reached only through `hildegard.helper.script`.

## Validation and error handling

- A script that calls no tool is pure compute (the subsumed case).
- A malformed script: a syntax error → `Ok=False`, the message as the tool result.
- A timeout or instruction-limit breach: `Ok=False` naming which limit.
- A denied sub-call: the rejection carries the tool name and the denial reason.
- A guest exception: caught, reported as `Ok=False` with the message.

## Testing requirements

### Unit tests (`test_script.pas`)

- [ ] `RunScript` on a pure-compute script returns its value (`1 + 2` → `3`).
- [ ] Console output is captured into `Output`.
- [ ] A syntax error yields `Ok=False` with a message (no raise).
- [ ] An injected tool call reaches `AInvoke` with the name + JSON args + the
      script's reason, and the returned text is visible to the script.
- [ ] A denied sub-call rejects; a script that `try/catch`es it can continue.
- [ ] The instruction cap and the timeout each stop a runaway script.
- [ ] `run_command` and `recall_tool_result` are **not** in the injected object.

### Integration tests (`test_tool_script.pas`)

- [ ] `run_script` is registered with a required `reason`; a call with no reason
      fails validation before the engine runs.
- [ ] The `script:run` gate is resolved before the engine runs; a denial returns
      the batch reason and runs nothing.
- [ ] A script calling `tools.file_read` on a workspace file runs the **same**
      gated handler (a fake service records the ask ref `file:read`).

## Performance targets

- Engine construction is per call (realm isolation); a trivial script completes
  in well under the default timeout. The engine's ~8 MB code is the accepted
  cost (operator decision, `FEATURE.md`).

## Security considerations

- `TGocciaCapabilities.None`, core-only, no runtime extensions: the injected
  tools are the only reachable surface.
- The engine is recreated per script (intrinsics cannot bleed between scripts).
- `run_command` is not reachable from a script (the sandbox is not a bash
  backdoor); `recall` is not a tool to compose.
- Limits (time/instructions/memory/output) bound a hostile or runaway script.

## Success criteria

- [ ] All contracts implemented; `make check` green; leak-clean.
- [ ] `make release` stays self-contained.
- [ ] One model turn runs N tool calls, each gated as a direct call would be.
- [ ] A script cannot reach the shell.

## Out of scope

- Runtime extensions (console/fetch/URL/data modules) — core-only v1.
- `command_run` or `recall` in the sandbox.
- True concurrency (the spike's path B: a host completion pump). Path A blocks.
- A REPL/editor; cross-machine execution; the bytecode VM (interpreter only, to
  trim size).

## Future considerations

- The bytecode VM (`TGocciaBytecodeExecutor`) if speed ever matters.
- Snapshot-in/diff-out execution (`--copy`) as prior art for Remote Link.
- A build-time feature trim to shrink the ~8 MB engine delta.
