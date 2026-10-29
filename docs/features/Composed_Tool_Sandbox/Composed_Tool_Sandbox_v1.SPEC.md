# Component Specification: Composed Tool Sandbox v1

> **Status: parked, and detached from the build (2026-10-17 / 2026-10-18).** This
> SPEC describes a feature that is not built. It is retained because its
> *security design* — a `tools` object that is a view over the registry, the
> invoker seam, the exclusions, the limits — is the part worth rebuilding; see
> `REWRITE_PROPOSAL.md` §3. `deps/goccia` no longer exists and no Makefile target
> references it.

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildi.agent` (the tool registry + `TToolHandler`),
`hildi.approval` (the gate the sub-calls route through),
`hildi.files` / `hildi.command.tool` (the world-touching
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
| The tool registry + handler contract | `hildi.agent` | reuse; the `tools` object is a view over it |
| The approval gate | `IApprovalService` (the same one a tool uses) | reuse |
| The async "block then settle" pattern | the harness's own worker/queue | reuse the idea: the callback blocks |
| Vendored-dep build integration | `scripts/fetch-sqlite.sh`, `fetch-mbedtls.sh`, the Makefile's `libstatic` pattern | follow it for `fetch-goccia.sh` |
| Console capture | the engine's `OutputCallback` | reuse |

The genuinely new work: a facade unit, the `tools` view, the `run_script` tool,
and the Makefile integration.

## Requirements

### Functional

- [x] `run_script(script, reason)` is registered and advertised like every other
      tool (required non-empty `reason`; gated as `script:run`). The `reason` is
      the **script's** and flows to every sub-call.
- [x] Execution is in-process, core-language-only, `TGocciaCapabilities.None`:
      no filesystem, network, FFI, exec, or time-of-day; no runtime extensions.
- [x] The harness's world-touching tools are injected as **one global `tools`
      object** (snake_case, async). Each method routes to the same registered
      tool and resolves **its own** approval ask — same ref, same options, same
      audit row — with the script's `reason` on every sub-call.
- [x] Each method returns a Promise and **blocks inside its callback** until the
      tool (and its approval) completes, then returns an **already-settled**
      promise (rejects on denial). The script sees an ordinary `await` and needs
      no approval concept of its own. (Spike path A — no engine change.)
- [x] `run_command` is **not injected**; `recall_tool_result` is **not injected**.
- [x] Limits are enforced: a wall-clock timeout wired to the turn's cancel check,
      an instruction cap, a memory cap, and an output-size cap.
- [x] The result is structured: standard output, the script's return value, and a
      typed error on failure or timeout — never a crash of the harness.
- [x] A denied tool call inside a script surfaces as a script-level error naming
      the tool and the denial; the script may catch it and continue.
- [x] The engine is **recreated per script** (realm isolation: a script can
      mutate intrinsics).
- [x] An **engine-integrity fault** (`EObjectCheck`, `EAccessViolation`,
      `EInvalidPointer`, `EDivByZero`, `EPrivilege`, `EExternalException`) is not
      swallowed: it fails the tool call with a clear message and the turn
      continues (the process is not trusted after such a fault, but we do not
      crash the TUI).

### Non-Functional

- [x] The engine is compiled **per target** into that target's unit dir, like any
      vendored source; a prebuilt shared cache was tried and abandoned (it never
      converged, and a flag mismatch crashed the compiler). See "Build
      integration".
- [x] `make check` green with the engine linked; the facade frees the engine +
      executor per call and releases each run's realm graph with a post-run
      `GC.Collect`. The engine's fixed process-lifetime singleton pin leaves a
      ~2.5k-block floor, which the leak gate allows (see the TODO deviations).
- [x] The runtime binary stays self-contained (no runtime `.dylib`/`.so`); the
      TUI links no engine at all.
- [x] Portability: macOS + Linux, arm64 + x86-64; FPC 3.3.1.

## Contracts & Interfaces

> Pascal type declarations; bodies are the implementer's.

```pascal
unit hildi.script;
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
unit hildi.tool.script;
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
- `scripts/patch-goccia.sh` applies the vendored-tree fixes (a `constref`→`const`
  FPC-3.3.1 incompatibility; `{$WARNINGS OFF}` so the engine compiles under our
  `-Sew`; and the `JSONParser`→`Goccia.JSONParser` rename that avoids an FCL
  unit collision). Idempotent.
- `scripts/gen-goccia-version.sh` writes the engine's `Goccia.Version.Generated.inc`
  (build.pas normally generates it).
- The Makefile's `libgoccia` target fetches and patches the tree; the engine then
  compiles **per target** into that target's own unit dir. Consumers add
  `$(GOCCIA_DEFINES) $(GOCCIA_PATHS)` and let it build.

**The recipe, found the hard way (three constraints):**

1. **No `-Mdelphi`.** The engine is `{$mode delphiunicode}` per unit; a forced
   `-Mdelphi` clashes and the compiler crashes (first a `TComparison` type
   error, then a nondeterministic `EAccessViolation`). Our units each declare
   their own `{$mode delphi}`, so the build simply omits `-Mdelphi` — verified
   transparent (`make check` unchanged).
2. **The engine must be allowed its warnings.** Its own code has warnings our
   `-Sew` treats as errors (unreachable code in `HashMap`, "Constructor should
   be public" in `Primitives`, `UnicodeString`→`AnsiString` in `TextSemantics`).
   `patch-goccia.sh` injects `{$WARNINGS OFF}` into the engine's shared include
   (`Goccia.inc` → `Shared.inc`), so it compiles under the consumer's flags.
3. **Per target, not a shared cache.** A prebuilt cache was tried and abandoned:
   it never converged (FPC recompiled the engine's circular core cluster — ~87
   units — on every build regardless of a prebuilt dir), and a consumer whose
   flags differed from the cache's crashed the compiler. The engine now builds
   into each target's unit dir like any vendored source.

**Resource opt-out:** build with `GOCCIA_INTL_NO_EMBEDDED_CLDR` (the cheapest
~1.2 MB win); TZ/UCD stay unless a need appears.


### The engine's boundary

- The engine is `{$mode delphiunicode}` (UTF-16 `string`); our units are UTF-8
  `{$mode delphi}`. Every value crossing the boundary converts **explicitly**
  (`UTF8Encode`/`UTF8Decode`), the same rule the codebase already follows.
- The engine's public surface is reached only through `hildi.script`.

## Validation and error handling

- A script that calls no tool is pure compute (the subsumed case).
- A malformed script: a syntax error → `Ok=False`, the message as the tool result.
- A timeout or instruction-limit breach: `Ok=False` naming which limit.
- A denied sub-call: the rejection carries the tool name and the denial reason.
- A guest exception: caught, reported as `Ok=False` with the message.

## Testing requirements

### Unit tests (`test_script.pas`)

- [x] `RunScript` on a pure-compute script returns its value (`1 + 2` → `3`).
- [x] Console output is captured into `Output`.
- [x] A syntax error yields `Ok=False` with a message (no raise).
- [x] An injected tool call reaches `AInvoke` with the name + JSON args + the
      script's reason, and the returned text is visible to the script.
- [x] A denied sub-call rejects; a script that `try/catch`es it can continue.
- [x] The instruction cap and the timeout each stop a runaway script.
- [x] `run_command` and `recall_tool_result` are **not** in the injected object.

### Integration tests (`test_tool_script.pas`)

- [x] `run_script` is registered with a required `reason`; a call with no reason
      fails validation before the engine runs.
- [x] The `script:run` gate is resolved before the engine runs; a denial returns
      the batch reason and runs nothing.
- [x] A script calling `tools.file_read` on a workspace file runs the **same**
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

- [x] All contracts implemented; `make check` green; leak-clean.
- [x] `make release` stays self-contained.
- [x] One model turn runs N tool calls, each gated as a direct call would be.
- [x] A script cannot reach the shell.

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
