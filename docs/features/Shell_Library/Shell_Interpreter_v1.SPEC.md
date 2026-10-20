# Component Specification: Shell Interpreter v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** [Shell Parser v1](Shell_Parser_v1.SPEC.md) (the AST) and
`shell.registry` / `shell.fs` / `shell.types` (all in `src/shell/`).

## Purpose

Execute the AST with the library's own control flow, and dispatch commands to a
**registry** the consumer registers. Every effect the shell performs (a
redirect, a glob, a `cd`) goes through a consumer seam; every external command
passes a consumer **gate** first.

## Requirements

### Functional

**Execution**

- [ ] Walk the AST: statement lists, `&&`/`||` short-circuit, pipelines,
      compound commands, and function definitions/calls.
- [ ] **Pipelines**: each stage runs in a subshell (a copy of cwd/env); the
      pipeline's status is the last stage's. Output flows stage to stage;
      `|&` also feeds stderr. No `pipefail` in v1.
- [ ] **Redirections**: apply around the command with save/restore semantics;
      `2>&1` and fd duplication honour order; a redirect failure is a command
      failure (stderr + status 1), not a parse error.
- [ ] **Assignments**: a `NAME=value` prefix applies to that command's
      environment only; a bare assignment persists in the shell.
- [ ] **Control flow**: `if`/`elif`/`else`, `for … in …`, `while`/`until`,
      `case` with `*`/`?`/`[…]` patterns, `{ …; }` (same shell), `( … )`
      (subshell), and functions with positional parameters.
- [ ] **Exit status**: the last command's; `!` inverts; `return`/`exit` unwind
      correctly through functions and subshells.
- [ ] **Word expansion (v1)**: literal parts, quotes, `$VAR`/`${VAR}`, `$?`,
      `$#`, `$@`, `$1..`, tilde, and glob expansion against the consumer's
      filesystem; no field splitting beyond a documented, simple model.
- [ ] **Globs**: `*`, `?`, `[…]` expand against the FS; no match leaves the
      pattern literal (POSIX default) — documented.
- [ ] **Here-docs**: the body is expanded unless the delimiter was quoted;
      `<<-` strips leading tabs.

**Registry and seams**

- [ ] `TShellRegistry.Register(name, handler)`; `Resolve(name, handler)`.
      Names are matched literally (no aliases in v1).
- [ ] An unregistered name is `command not found` on stderr with status 127.
- [ ] **The gate is consulted before every registered handler**; a denial is
      stderr + status 126 and the handler never runs.
- [ ] **The filesystem seam** handles redirects, input redirection, `cd`
      validation, and glob listing. The consumer's implementation owns the path
      bound.
- [ ] The environment is the library's model, initialised by the consumer.

**Library builtins (the language, not the registry)**

- [ ] `cd`, `pwd`, `export`, `unset`, `local`, `shift`, `return`, `exit`,
      `set --` are implemented by the library: they mutate shell state, which is
      the library's.
- [ ] `cd` validates through the FS seam (`Stat` must report a directory); a
      refusal is stderr + status 1.
- [ ] These builtins are **not** gated: they are the language. Their reach is
      bounded by the FS seam.

**Limits**

- [ ] `MaxCommands`, `MaxLoopIterations`, `MaxCallDepth`, `MaxOutputBytes`, and
      `MaxExecutionTimeMs` bound execution; exceeding one is a clear error with
      a non-zero status, not a hang.
- [ ] The wall-clock deadline is checked between commands and loop iterations.

### Non-Functional

- [ ] **Deterministic**: the same AST, registry, FS, and gate produce the same
      output, status, and handler-call order.
- [ ] **No host escape**: the library never spawns a process, reads a real file
      directly, or opens a socket. (A consumer handler may; that is its gate.)
- [ ] **Leak-clean**; no exception escapes `Run` (errors are results).
- [ ] **Standalone**: no `hildegard.helper.*` dependency.

## Contracts & Interfaces

```pascal
unit shell.types;

type
  TShellEnv = class            // the library's environment model
    function Get(const AName: string): string;
    procedure SetValue(const AName, AValue: string);
    procedure Unset(const AName: string);
    function Names: TStringArray;
  end;

  TShellCall = record
    Name: string;
    Args: TStringArray;        // already expanded and split
    Stdin: string;
    Cwd: string;
    Env: TShellEnv;
  end;

  TShellResult = record
    Stdout: string;
    Stderr: string;
    ExitCode: Integer;
  end;

  TShellHandler = function(const ACall: TShellCall): TShellResult of object;
  { Consulted before a registered handler. False = denied (stderr + 126). }
  TShellGate = function(const ACall: TShellCall): Boolean of object;

unit shell.registry;
  TShellRegistry = class
    procedure Register(const AName: string; AHandler: TShellHandler);
    function Resolve(const AName: string; out AHandler: TShellHandler): Boolean;
  end;

unit shell.fs;

type
  TShellFileKind = (sfkMissing, sfkFile, sfkDirectory, sfkOther);
  IShellFileSystem = interface
    { Resolve APath against ACwd; no requirement that it exists. }
    function Resolve(const ACwd, APath: string): string;
    function ReadFile(const APath: string; out AData, AError: string): Boolean;
    function WriteFile(const APath, AData: string; AAppend: Boolean;
      out AError: string): Boolean;
    function ListDir(const APath: string; out AEntries: TStringArray;
      out AError: string): Boolean;
    function Stat(const APath: string; out AKind: TShellFileKind;
      out AError: string): Boolean;
    { Kind + size + mode + mtime, for `ls -l`. A platform without mode bits
      reports 0; a consumer that cannot supply details still implements it. }
    function Info(const APath: string; out AInfo: TShellFileInfo;
      out AError: string): Boolean;
  end;

unit shell.interpreter;

type
  TShellLimits = record
    MaxCommands, MaxLoopIterations, MaxCallDepth, MaxOutputBytes: Integer;
    MaxExecutionTimeMs: Int64;
  end;

  TShell = class
    constructor Create(ARegistry: TShellRegistry; AFs: IShellFileSystem;
      const AInitialCwd: string; AGate: TShellGate;
      const ALimits: TShellLimits; AEnv: TShellEnv = nil);
    { Execute a parsed script in the current shell. }
    function Run(const AScript: TScript; out AOutput, AError: string): Integer;
    { Parse and run; a parse error is reported, nothing is executed. }
    function RunSource(const ASource: string;
      out AOutput, AError: string): Integer;
  end;
```

### Data Contracts

- **Pipeline subshell.** Each stage runs with a copy of the environment, cwd and
  positional parameters, and any function it defines is dropped afterwards;
  `cd`/assignments inside a pipeline do not leak to the parent. The gate sees
  each stage's call. Stages run sequentially in v1 (see Deviations).
- **Redirect evaluation order.** Left to right, before the command runs; a
  failure stops the command. `2>&1` duplicates the current fd 2 target.
- **Gate order.** Expand words → resolve the registry → call the gate → call the
  handler. A missing command is not gated (there is nothing to approve); it is
  127.
- **Output.** `Stdout`/`Stderr` are accumulated and bounded by
  `MaxOutputBytes`; truncation is marked once.
- **Exit status.** `$?` is set after every statement; a pipeline's is its last
  stage; a `case` with no match is 0; an empty command list is 0.

## Validation Rules

- `Run` on an empty script returns 0 with empty output.
- An unregistered command is 127; a gated denial is 126; a redirect failure is 1.
- A loop exceeding `MaxLoopIterations` aborts the script with a named error.
- A parse error from `RunSource` returns status 2 and executes nothing.

## Error Handling

- All errors are results (status + stderr), never exceptions.
- A handler that returns a non-zero status sets `$?`; its stderr is appended.
- A gate that raises is treated as a denial (fail safe).

## Testing Requirements

### Unit Tests (`tests/test_shell_interpreter.pas`)

- [ ] `echo`-style handler: a simple command, args, and `$?`.
- [ ] Registry: registered, unregistered (127), gate denial (126).
- [ ] The gate is called once per command, in order, with expanded args.
- [ ] Pipelines: two and three stages; `|&`; last-stage status; subshell `cd`.
- [ ] Redirects: `>`, `>>`, `<`, `2>`, `2>&1`, failure.
- [ ] Assignments: prefix (scoped) vs bare (persistent).
- [ ] Control flow: `if`, `for`, `while`, `until`, `case`, `{ }`, `( )`,
      functions + `return`.
- [ ] Expansion: quotes, `$VAR`, `$?`, `$@`, tilde, globs; no-match literal.
- [ ] Here-docs: expanded vs quoted delimiter; `<<-` tabs.
- [ ] Limits: command count, loop iterations, call depth, output bytes, deadline.

### Integration Tests (`tests/test_shell_consumer.pas`)

- [ ] A small consumer registers `cat`/`ls`/`grep` over an in-memory FS and runs
      a script with a loop and a pipeline; assert output, status, and the gate
      call list.

### Differential Tests (opt-in, fixtures recorded)

- [ ] Scripts run in `/bin/bash -c` and the interpreter agree on
      stdout/stderr/exit for the supported subset.

## Performance Targets

- A script of 1,000 simple commands with a trivial handler in well under a
  second; per-command overhead is allocation-bound, not I/O.

## Security Considerations

- **The gate is the policy seam.** No registered handler runs without it; a
  denial is fail-safe (the handler never runs).
- **The FS is the path seam.** Redirects, globs, and `cd` go through it; the
  consumer's implementation enforces the workspace bound.
- **The library never spawns.** A consumer that wants the real shell registers a
  handler for an explicit name (and gates it).
- **Limits are mandatory**, not advisory: a script cannot loop or recurse
  unbounded.
- **Not a sandbox.** The OS boundary belongs to the consumer; the library bounds
  its own execution, not the process.

## Success Criteria

- [ ] A loop + pipeline + redirect script runs against a registered set, with the
      gate called for every command.
- [ ] An unregistered command and a denied command fail distinctly.
- [ ] Limits abort a runaway script.
- [ ] The corpus's supported scripts parse and run.
- [ ] `make check` green, leak-clean.

## Recorded Deviations (v1 implementation)

The implementation follows this SPEC except where noted. Each is a deliberate,
tested ceiling with its upgrade path.

- **Pipelines are sequential.** The handler contract is
  `function(Call): TShellResult`: it returns a whole stdout string, it does not
  stream. Stages therefore run to completion in order, and `yes | head` would
  not terminate. Upgrade path: a streaming handler API (an observer, or an
  input/output stream pair); the AST already separates the stages.
- **The constructor takes the initial cwd.** `IShellFileSystem` resolves against
  a cwd, so the shell must be told where it starts; it cannot be derived from the
  environment alone.
- **Field splitting is a simple, documented model.** A word that is exactly one
  unquoted variable (or `$@`) splits on whitespace; any other word is one field.
  Quotes suppress splitting. That is enough for `for f in $FILES` without the
  full IFS algorithm.
- **Redirections are supported on simple commands.** `{ ...; } > f` and
  `if ...; fi > f` are not v1.
- **Globs are expanded by the interpreter** through `IShellFileSystem.ListDir`
  and a small matcher (no regex, no C `fnmatch`). No match yields the literal
  pattern, which is POSIX's default.
- **`cd` is a library builtin**, not a consumer handler: cwd, environment,
  positional parameters and functions are shell state, and a handler could not
  mutate them without exposing the interpreter's internals. The consumer still
  supplies the filesystem, so the path bound remains theirs.
- **Not implemented (v1):** arithmetic, arrays, `eval`/`source`, `trap`, `read`,
  process substitution, command substitution, brace expansion, parameter
  operators, `cd -`/`OLDPWD`, and `set -e`/`-u`/`pipefail`.

## Future Considerations

- v2 expansions; `pipefail`; `set -e`/`-u`.
- Aliases and functions exported to subshells.
- A transform hook (AST in/out).
- Parallel pipeline stages.
