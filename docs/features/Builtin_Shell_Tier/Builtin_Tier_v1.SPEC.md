# SPEC: Builtin Shell Tier v1

**Related:** [FEATURE.md](FEATURE.md) · [Shell Interpreter v1](../Shell_Library/Shell_Interpreter_v1.SPEC.md) · [Approval Path Scoping](../Approval_Path_Scoping/Approval_Path_Scoping_v1.SPEC.md)

## Scope

The harness consumer of the Shell Library: a workspace-bounded filesystem, a
closed command set, a per-command gate that reuses `run_command`'s approval
refs, tool dispatch, and an `ICommandExecutor` that prefers the tier and falls
back to `/bin/bash`.

Out of scope: new approval refs, regex matching in `grep`, `find`, recursive
`rm` semantics beyond the flags listed, and any command that needs a process.

## Units

```
src/hildegard.helper.shell.fs.pas         TWorkspaceShellFs (IShellFileSystem + ops)
src/hildegard.helper.shell.commands.pas   TBuiltinCommands (the closed command set)
src/hildegard.helper.shell.tier.pas       TBuiltinShell (pre-flight, gate, run)
src/hildegard.helper.shell.executor.pas   TBuiltinCommandExecutor (ICommandExecutor)
```

### Changes to existing units

- `hildegard.helper.command.tool`: `ICommandExecutor.Execute` gains
  `const AReason: string`; `TProcessCommandExecutor` accepts and ignores it.
  `TCommandTool.Run` passes the model's reason.
- `hildegard.helper.harness.session`: construct the builtin executor with the
  approval service, the workspace root, a timeout cap, and a tool dispatcher;
  pass it as `TCommandTool`'s executor. The process executor remains the
  fallback inside it.
- `docs/features/FEATURES.md`: a new row.

## 1. `TWorkspaceShellFs`

```pascal
type
  TWorkspaceShellFs = class(TInterfacedObject, IShellFileSystem)
  public
    constructor Create(const ARoot: string);
    { IShellFileSystem }
    function Resolve(const ACwd, APath: string): string;
    function ReadFile(const APath: string; out AData, AError: string): Boolean;
    function WriteFile(const APath, AData: string; AAppend: Boolean;
      out AError: string): Boolean;
    function ListDir(const APath: string; out AEntries: TStringArray;
      out AError: string): Boolean;
    function Stat(const APath: string; out AKind: TShellFileKind;
      out AError: string): Boolean;
    { The extra operations the command set needs. }
    function Delete(const APath: string; ARecursive: Boolean;
      out AError: string): Boolean;
    function Move(const AFrom, ATo: string; out AError: string): Boolean;
    function Copy(const AFrom, ATo: string; out AError: string): Boolean;
    function MakeDir(const APath: string; AParents: Boolean;
      out AError: string): Boolean;
    function Touch(const APath: string; out AError: string): Boolean;
    function ReadText(const APath: string; out AData, AError: string): Boolean;
  end;
```

Rules:

- `Create` canonicalises the root (`CanonicalWorkspacePath`).
- `Resolve` joins a relative path to the cwd, normalises `.`/`..` and duplicate
  slashes, and returns an absolute path. It does not enforce containment.
- **Every operation enforces `PhysicalContains(FRoot, APath)`** before touching
  the disk; a violation is `False` + `'path escapes the workspace: <path>'`
  (symlinks included, because `PhysicalContains` resolves them). The root itself
  is always inside.
- `ReadFile`/`ReadText` cap at `MaxFileBytes` (default 8 MiB) and say so.
- `WriteFile` creates or truncates; append appends. The parent directory must
  exist (like a shell redirect). Write failures are reported.
- `ListDir` requires a directory, returns sorted entry names, and excludes
  `.`/`..`.
- `Stat` reports `sfkFile`/`sfkDirectory`/`sfkOther`/`sfkMissing` and, for a
  missing path, `False` + `'no such file or directory'`.
- `Delete` is recursive only when asked; it refuses the root. `Move` uses
  `RenameFile`; `Copy` copies files only (directories are an error). `MakeDir`
  creates the leaf, or the parents when asked. `Touch` creates a missing file;
  an existing file is left as is (its mtime is not changed in v1).

## 2. `TBuiltinCommands`

A class with one method per command, matching `TShellHandler`:

```pascal
type
  TBuiltinCommands = class
  public
    constructor Create(AFs: TWorkspaceShellFs; AInvoke: TShellToolInvoke;
      const AAllowedTools: TStringArray);
    function Echo(const ACall: TShellCall): TShellResult;
    ...
    function Tool(const ACall: TShellCall): TShellResult;
    function Mcp(const ACall: TShellCall): TShellResult;
  end;
```

Every command returns `TShellResult` (`Stdout`, `Stderr`, `ExitCode`) and never
raises. Usage errors are stderr + status 2 (grep: 2; commands use `2` for bad
usage, `1` for a failed operation, matching the conventions the model already
knows).

| Command | Flags | Semantics |
|---|---|---|
| `echo` | `-n` | join args with one space; newline unless `-n` |
| `cat` | — | files in order, or stdin |
| `head` | `-n N` | first N lines (default 10); files or stdin |
| `tail` | `-n N` | last N lines (default 10); files or stdin |
| `wc` | `-l -w -c` | selected counts (default all three); `N name` per file |
| `grep` | `-n -i -v -l -c -F` | fixed-string match; a pattern with a regex metacharacter and no `-F` is an error naming it |
| `ls` | `-a -d` | sorted names; `-a` includes dotfiles; `-d` lists the path itself |
| `mkdir` | `-p` | create directories |
| `rm` | `-r -f` | remove files; directories only with `-r`; `-f` suppresses missing |
| `mv` | — | one source, one destination |
| `cp` | — | one file source, one destination |
| `touch` | — | create missing files |
| `sort` | `-r -u` | line sort |
| `uniq` | `-c -d -u` | adjacent duplicates |
| `basename` | — | final component, optional suffix |
| `dirname` | — | the parent path |
| `test` / `[` | — | `-e -f -d -r -w -x -s -z -n`, `=`/`!=`, `-eq -ne -lt -le -gt -ge`, `!` |
| `true` / `false` | — | status 0 / 1 |
| `tool` | — | `tool <name> [json]` |
| `mcp` | — | `mcp <server>:<tool> [json]` |

`test`/`[` accept exactly one unary or one binary expression; anything else is
`test: unsupported expression`. `[` requires the closing `]`.

### Command options and the pre-flight

Each registered command declares its **supported option set** (the flags above).
The pre-flight walks the AST and, for every simple command, checks:

1. the name is registered (or a library builtin, or `tool`/`mcp`);
2. every **literal** argument that starts with `-` (other than `-`/`--`) is
   supported: a combined short flag is decomposed (`-rf` → `r`, `f`), and a
   long option (`--x`) is unsupported unless the command lists it.

A failed check **declines the whole script** — it does not run in the tier. An
argument that is only known at run time (a variable, a glob) is not checked; if
it turns out to name an unsupported option, the command returns a usage error
naming it. That is the documented edge.

## 3. `TBuiltinShell`

```pascal
type
  TShellToolInvoke = function(const AName, AArgumentsJson, AReason: string;
    out AResult, AError: string): Boolean of object;

  TBuiltinShellConfig = record
    Root: string;                 // the workspace root
    MaxOutputBytes: Integer;      // default 32 KiB (the tool's cap)
    MaxCommands: Integer;         // propagated to the interpreter
    MaxLoopIterations: Integer;
    MaxCallDepth: Integer;
    AllowedTools: TStringArray;   // glob patterns; '' = no dispatch
  end;

  TBuiltinShell = class
    constructor Create(const AConfig: TBuiltinShellConfig;
      AApproval: IApprovalService; AInvoke: TShellToolInvoke = nil);
    destructor Destroy; override;
    { True when the whole script is in the tier and ran; False = decline. }
    function TryRun(const ACommand, ACwd, AReason: string;
      ATimeoutMs: QWord; out AOutput: string; out AExitCode: Integer): Boolean;
    property LastError: string read FLastError;
  end;
```

`TryRun`:

1. Parse with `ParseShellScript`. A parse error declines (`LastError` = the
   message), so `run_command` reports nothing from the tier.
2. Pre-flight the AST (names + literal options). An unsupported name declines.
3. Build the environment: `HOME` = root, `PWD` = cwd, plus a minimal `PATH`
   (empty; the tier never spawns).
4. Execute through `TShell.Run` with `MaxExecutionTimeMs = ATimeoutMs` and the
   other limits from the config. The interpreter's stdout/stderr merge into
   `AOutput` in that order; `AExitCode` is the script status.
5. Output is capped at `MaxOutputBytes` by `TShell.Run`; the executor marks
   truncation once, like the process tier.

### The gate

A `TShellGate` implementation on `TBuiltinShell`:

- Build `TApprovalAsk`s for the call, one per command, in execution order:
  ```
  Subject.Ref    := 'run_command:' + ExtractFileName(Call.Name)
  Subject.Params := Call.Args
  Summary        := Call.Name + ' ' + join(Call.Args)
  Reason         := the run's reason (inherited)
  ```
  with the same four options `BuildAsks` produces: `once` (persist False),
  `exact` (persist True, Params = args), `any` (persist True, AnyParams True),
  `prefix` (persist True, first non-flag arg, AnyParams True).
- Resolve through `IApprovalService.Resolve`; allow only when
  `Allowed and not Denied`.
- A resolve infrastructure failure denies and records `LastError`.
- Builtins handled by the library (`cd`, `pwd`, `export`, …) never reach the
  gate — they are language state, not capabilities. `tool`/`mcp` do reach the
  gate (the script names a capability), and the dispatched tool then passes its
  own gate as usual.

### Tool dispatch

`tool <name> [json]` and `mcp <server>:<tool> [json]`:

- `mcp` maps `server:tool` to `mcp_<sanitised server>_<sanitised tool>`. The
  mapping reuses `McpToolName`/`McpSanitize` from `hildegard.helper.mcp.client`
  so it cannot drift from the registry's names.
- The name must match one of `AllowedTools` (glob, `MatchGlob` from the shell
  interpreter). Otherwise status 1 + `not allowed in the builtin shell: <name>`.
- `run_command` (and any name ending in `run_command`) is always refused, as is
  a missing dispatcher: `not available in the builtin shell`.
- Arguments: the JSON object is passed through; if it has no `reason`, the
  run's reason is added. Invalid JSON is a usage error (2).
- The dispatcher returns `(Result, Error)`; `Result` goes to stdout (with a
  newline if missing), `Error` to stderr + status 1.
- No recursion: the dispatcher is the session's normal tool resolution, and the
  tier refuses shell-entry tools by name.

## 4. `TBuiltinCommandExecutor`

```pascal
type
  TBuiltinCommandExecutor = class(TInterfacedObject, ICommandExecutor)
    constructor Create(const AConfig: TBuiltinShellConfig;
      AApproval: IApprovalService; AFallback: ICommandExecutor;
      AInvoke: TShellToolInvoke = nil);
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord; AObserver: TToolObserver;
      const AReason: string; out AExecution: TCommandExecution): Boolean;
  end;
```

- `Execute` builds a `TBuiltinShell` per call (so concurrent `run_command`
  calls cannot share a reason or an environment), calls `TryRun`, and:
  - **ran**: `AExecution.Output` = stdout+stderr, `ExitCode`, `Started := True`,
    `Cancelled := False`, `TimedOut := False`; return True.
  - **declined**: delegate to `AFallback` with the same arguments (so the
    process tier's behaviour and asks are unchanged).
- A `TBuiltinShell` construction failure is a decline, not an error.

## 5. Session wiring

In `THarnessSession.Init`, after the approval service exists:

```pascal
TierConfig := Default(TBuiltinShellConfig);
TierConfig.Root := FView.WorkspaceRoot;
TierConfig.MaxOutputBytes := DefaultMaxOutputBytes;  // 32 KiB
TierConfig.AllowedTools := ['file_read', 'file_list', 'file_glob', 'file_grep',
  'file_stat', 'mcp_*'];
FCommandTool := TCommandTool.Create(ToolConfig, ApprovalService,
  TBuiltinCommandExecutor.Create(TierConfig, ApprovalService,
    TProcessCommandExecutor.Create, InvokeTool));
```

`InvokeTool` is the session's normal tool resolution (base registry, then the
MCP manager). It must not be able to re-enter `run_command`; the tier refuses
that name before calling the dispatcher, and the session's resolver does not
special-case it.

## Error Handling

- Commands never raise: all failures are `TShellResult` with stderr + status.
- The tier declines (never fails) when it cannot understand the script; the
  process tier then produces the model-visible error, exactly as today.
- A gate denial is the library's `<name>: denied`, status 126; the approval
  service's reason is the one the operator saw in the prompt.
- The executor returns False only for an approval-infrastructure error or a
  fallback failure — the same failures `run_command` already reports.

## Testing

### `tests/test_shell_harness_fs.pas`
- read/write/append/list/stat inside the workspace;
- a path outside the workspace is refused by every op;
- a symlink to the outside is refused (skip when the OS disallows symlinks);
- recursive delete, move, copy, mkdir (`-p`), touch;
- the read cap.

### `tests/test_shell_commands.pas`
- each command's output/status for the common and the error case;
- option parsing (combined short flags, `--`, unknown option);
- `grep` regex-metacharacter refusal without `-F`;
- `test`/`[` unary, binary, negation, and the unsupported-expression error.

### `tests/test_shell_tier.pas`
- a supported script runs (loop, pipeline, redirect) and produces the transcript;
- an unregistered command declines; an unsupported literal option declines;
- a parse error declines; nothing runs on decline (a redirect target is absent);
- the gate is asked once per command, in order, with the inherited reason;
- an existing exact grant suppresses the prompt (a fake approval service);
- a denial is 126 and the handler never runs;
- `tool` dispatches an allowed tool with the inherited reason; a disallowed tool
  and `run_command` are refused;
- an outside path via a redirect is refused.

### `tests/test_shell_executor.pas`
- the executor uses the tier when the script is supported (the fallback is not
  called) and falls back when it is not;
- reasons are passed through; `TCommandExecution` fields are set.

### Differential (existing)
The `run_command` transcript format is unchanged; the shell differential
fixtures already pin the language. A new fixture set pins the command outputs
(`ls`, `wc`, `head`, `grep -n`, `sort`, `uniq`) against `/bin/bash`.

## Acceptance

- A registered, in-subset script never spawns a process.
- The fallback is chosen before any side effect.
- The gate sees every command once, in order, with the model's reason.
- `run_command` inside the tier and an unlisted `tool` are refused.
- Every filesystem op enforces the workspace bound physically.
- `make check` green, leak-clean.

## Recorded Deviations

- `touch` does not update an existing file's mtime (v1).
- `grep` is fixed-string; a regex pattern without `-F` declines (pre-flight,
  when literal) or errors (at run time).
- `cp` copies files only; `cp -r` declines via the option check.
- `ls` prints bare names (no columns, no `-l`); `ls -l` declines.
- `test` supports one expression, not `-a`/`-o` chains.
- Glob matching uses the interpreter's matcher (no `fnmatch` extensions such as
  `[[ ]]`).
