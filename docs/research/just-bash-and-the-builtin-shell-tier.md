# just-bash and the Builtin Shell Tier

**Status:** Live — a design input for a builtin command tier.
**Date:** 2026-10-19 (worktree `research/just-bash`, from `70d23b7`).
**Related:** [Tree-Sitter](../features/Tree_Sitter/FEATURE.md),
[Composed Tool Sandbox](../features/Composed_Tool_Sandbox/FEATURE.md) (parked),
[Tool Approvals](../features/Tool_Approvals/FEATURE.md),
[Approval Path Scoping](../features/Approval_Path_Scoping/FEATURE.md),
[Command Tool](../features/Command_Tool/FEATURE.md),
[vendored-engine-lessons.md](vendored-engine-lessons.md).

## The conclusion first

[`just-bash`](https://github.com/vercel-labs/just-bash) is a **bash implementation
that runs in the host** — a hand-written parser, an interpreter, an in-memory
filesystem, and ~80 commands written in TypeScript. Its security property is not
isolation (it states plainly that it is *not* a VM): it is that **the shell can
only run the commands the host implemented**, and every command is a host
function the host can see.

That is exactly the property worth borrowing, and it is the same goal the parked
Composed Tool Sandbox chased — but at the right layer. The sandbox added a
*second interpreter* (a JS VM) to observe compound work; this adds **no runtime**
at all. It makes the *shell* boundary closed: parse the command, execute a known
command set directly in FPC, and refuse or escalate everything else.

The cheapest credible path is **not** to port just-bash. Its expensive parts are
a hand-written bash parser (~15 modules) and ~80 commands (awk, sed, jq/yq, tar
are each a project). We already plan [Tree-Sitter](../features/Tree_Sitter/FEATURE.md)
for the parse, which removes the first cost; the second is scoped by starting
with a handful of commands.

## What just-bash actually is (the numbers)

| Piece | Facts |
| --- | --- |
| Package | `just-bash` v3.6.0, Apache-2.0, TypeScript, Node `>=20.19` |
| Model | `Bash.exec(script)` parses and **interprets** the shell in-process; no OS process, no real shell |
| Shell state | Each `exec()` has isolated state (env, functions, cwd); the **filesystem is shared** across calls |
| Parser | Hand-written: `lexer`, `word-parser`, `expansion-parser`, `arithmetic-parser`, `command/compound/conditional-parser`, heredoc, process substitution — `parser.ts` ≈ 1,378 lines, ~15 modules |
| Interpreter | `interpreter.ts` ≈ 1,261 lines plus ~40 modules (control flow, expansion, fd table, alias expansion, arithmetic, conditionals, builtins) |
| Entry | `Bash.ts` ≈ 1,286 lines |
| Commands | ~80, in `src/commands/` (a registry + one module per command, some with WASM workers) |
| Filesystems | `InMemoryFs` (default), `OverlayFs` (copy-on-write over a real dir), `ReadWriteFs` (real dir), `MountableFs` (a unified namespace) |
| Optional runtimes | `js-exec` (QuickJS/WASM), `python3` (CPython/WASM), `sqlite3` (sql.js/WASM) — **off by default** |
| Network | Off by default; `curl` exists only when configured, behind URL-prefix and method allow-lists, with header transforms so secrets never enter |
| Limits | ~60 named bounds in `limits.ts`, two profiles (`normal`, `hardened`) |
| Transforms | `parse → AST → plugins → serialize`; built-ins collect command names or wrap pipeline stages with `tee` |

The command set is worth reading as a checklist even if we implement none of it:

- **Files:** `cat cp file ln ls mkdir mktemp mv readlink rm rmdir split stat touch tree`
- **Text:** `awk base64 column comm cut diff expand fold grep head join md5sum nl od paste printf rev rg sed sha1sum sha256sum sort strings tac tail tr unexpand uniq wc xargs`
- **Data:** `jq sqlite3 xan yq`
- **Navigation/env:** `basename cd dirname du echo env export find hostname printenv pwd tee`
- **Shell utilities:** `alias bash chmod clear date expr false help history seq sh sleep time timeout true unalias which whoami yes`
- **Network:** `curl html-to-markdown`

Shell features: pipes, all redirects, `&&`/`||`/`;`, variables and positional
parameters, globs, `if`, functions, `local`, `for`/`while`/`until`, symlinks.

## The ideas worth taking

1. **A closed command set is the security property.** Unknown command → "command
   not found". There is no host binary to fall through to. Contrast the real
   shell, where the gate can name `bash` but not what `bash -c` does.
2. **Direct dispatch.** Every command is a host function receiving `(argv, cwd,
   env, stdin, fs)`; the host sees the structured operation, not a string. That
   is precisely the shape our approval subjects already use.
3. **Filesystem and network are capabilities, not ambient authority.** The shell
   only sees the FS it is given; network is an allow-list, off by default. Our
   analogue is the workspace root plus `PhysicalContains`.
4. **Parse-then-transform is a gating seam.** `parse → plugins → serialize` lets
   the host inspect or rewrite a script before execution. The `CommandCollector`
   plugin is a five-line idea: enumerate every command name in the AST, including
   inside `$()` and compound bodies.
5. **Limits are first-class and profiled.** ~60 named bounds (source bytes, call
   depth, command count, loop iterations, output bytes, traversal work, wall
   clock). Even if we implement a fraction, the list is the review checklist.
6. **Fail-safe defaults.** Network off; JS/Python off; `date` in UTC so the host
   timezone does not leak; read-only by default in the CLI.
7. **The security model is written down, including its limits.** "No VM
   isolation"; "JavaScript cannot forcibly stop arbitrary host code"; "WASM
   memory caps are not reliable". That honesty is the pattern to copy.

## What not to take

- **The in-memory filesystem as the default.** Our agent's job is to change the
  real workspace, and our file tools are already the mediated surface. An
  in-memory FS would be a second, divergent tree.
- **The optional runtimes** (`js-exec`, `python3`, `sqlite3`). Each is a new
  interpreter to secure — the exact trap the parked sandbox documented in
  [vendored-engine-lessons.md](vendored-engine-lessons.md) §8.
- **The Node/TypeScript dependency.** We are FPC and statically linked; adding a
  runtime to avoid a runtime is not a trade.
- **The full bash language** (see the decision below).
- **`curl` / network.** A separate feature with its own policy; not part of a
  command tier.

## The mapping to hildegard-helper

Today: `run_command` runs **real** `/bin/bash -c`, gated per program (Tool
Approvals) and, since Approval Path Scoping, per outside path. The shell
library's own parser will make the ask set correct (keywords are not programs;
`$()` contents are).

What that still cannot do is **mediate the operation**. A real shell can run any
binary, read any file the process can, and hide work behind `eval`, `bash -c`,
`xargs`, or an interpreter. The gate names the programs; it does not own them.

A **builtin tier** would:

- parse the command with the shell library's own parser,
- execute a **known command set** in FPC against the real workspace,
- route every operation through the existing approval + path gate (a command is
  a structured subject: program, args, path),
- and **refuse or escalate** anything outside the set.

The layered picture:

```
model writes bash
      │
      ▼
shell parser (own)  ──►  parse error? → conservative union (the splitter)
      │
      ▼
builtin tier (FPC)  ──►  known command → execute in-process (gated)
      │                   unknown/compound → escalate to real shell (gated)
      ▼
real workspace (PhysicalContains)
```

This is the boundary we already have, made *closed* — exactly lesson 8 in
`vendored-engine-lessons.md` ("prefer the boundary you already have").

## The central decision: how much shell language?

This is the cost, and it should be decided explicitly.

**Tier A — linear.** Simple commands, pipes, redirects, `&&`/`||`/`;`, literal
env assignments, globs. **No** `for`/`if`/`while`/functions/`$()`/backticks.
A walk over the pipeline/list nodes; no expansion engine beyond globs. Small,
testable, and it covers most file/text work.

- *Cost:* low.
- *Limit:* compound constructs are precisely where hidden work lives, so they
  fall back to the real shell — the hole remains for the case that motivated
  all of this.

**Tier B — compound.** Add control flow, functions, parameter/arithmetic
expansion, command and process substitution, a word-splitting model, an fd
table. That is a shell interpreter — the thing just-bash is.

- *Cost:* high (just-bash's interpreter + parser is the bulk of its code; we
  would skip the parser via tree-sitter, not the expansion/semantics work).
- *Benefit:* every construct executes under our control.

**Tier C — transform, not interpret.** Do not execute the shell at all. Use the
parse to enumerate or **decompose** the work into existing gated tool calls:
a `for` over a literal/glob list unrolls into N calls; a pipeline becomes
staged calls; anything not statically decomposable is refused with a hint.

- *Cost:* medium; no shell execution engine.
- *Limit:* only statically-known scripts decompose. Dynamic loops over command
  output do not.

**Recommendation: A first, C as the escape hatch, B only if measured demand
exists.** Tier A is small and proves the value; C turns the common compound
cases into gated tool calls without an interpreter; Tier B is a feature-sized
commitment that should be justified by real usage, not by symmetry with
just-bash.

## A starter command set

Split by *what the operator must be able to bound*, not by what is convenient to
implement (see "Own vs pass through"):

**Owned (full mediation).** The workspace operations — `cd pwd stat find` and the
file primitives behind `cat head tail wc grep`, plus the mutators `mkdir rmdir rm
mv cp ln touch` — and the trivial shell plumbing `echo printf test [ true false`.

**Passed through, gated (byte transforms).** `sort uniq cut tr diff base64` and
the checksums: exact tools, low risk, no shell re-entry. `awk sed jq yq tar
sqlite3` are passed through too, but they are interpreters/archivers; their file
arguments still take the path gate, and the operator grants them explicitly.

**Never in the tier.** `bash sh eval source . xargs env timeout sudo` and
`find -exec` — they re-enter the shell or spawn outside the process model. They
escalate to the real shell (policy 2 below), which is itself gated.

- **Read-only** commands are safe to run ungated (they still pass `PhysicalContains`).
- **Mutating** commands are gated exactly like the file tools; the approval
  subject is the program + the resolved path.
- A command outside the owned set is not an error — it is the escalation path.

## The gating model

- **The subject is structured.** `builtin:<cmd>` + resolved args, or reuse the
  existing `run_command:<cmd>` family with the arguments as params — the
  decision is whether a builtin is a *new tool family* or a *mode* of
  `run_command`. Reusing `run_command` keeps one shell surface for the model;
  a distinct family keeps the audit unambiguous.
- **Path scoping applies unchanged.** `PhysicalContains` already gates outside
  access; a builtin that names a path uses the same resolver.
- **The tier never escalates silently.** Falling back to the real shell is an
  explicit step (a new ask, or a result line saying `shell: …`), so the operator
  can tell which tier ran.
- **Fail safe.** An unparseable command is refused or escalated — never run.

## The tier as a shell over the tool registry

The builtin set is not only coreutils. The harness already resolves capabilities
from several providers — file tools, `recall`, MCP servers (lazy), skills — behind
one `IToolProvider`/`TToolRegistry` seam, and each tool's handler is already
`(argsJson, result, error, observer)`. The tier should **dispatch to that
registry**, so a script can compose the harness's capabilities with shell syntax:

```bash
for f in docs/*.md; do
  mcp docs:convert "$f" > "${f%.md}.html"
done
```

This is the stronger version of the closed set: the set is exactly what the
operator has installed and granted, and every call is one the harness already
mediates.

**Naming.** `mcp <server>:<tool> [json]` resolves the registry's existing
`mcp_<sanitized server>_<sanitized tool>` name (`mcp.client.pas:295`). A generic
`tool <name> [json]` covers any other registry tool. Builtins (`cat`, `ls`, `grep`,
…) are plain names; the file tools map onto them rather than being exposed twice.

**Arguments are JSON, not flags (v1).** The handler takes a JSON object, so
`mcp browser:navigate '{"url":"…","selector":"…"}'` is one shell-quoted string
parsed by the same JSON parser. Flags need schema-aware coercion and are a later
ergonomic layer over the same JSON. Malformed JSON is a clear stderr + a distinct
exit code, never a guess.

**The reason is inherited.** Every tool schema requires a non-empty `reason`
(`MakeToolSpec`; the loop rejects calls without it). The tier injects the
**outer script's** reason into every sub-call — the parked sandbox's rule
("per-script reason inherited by sub-calls"). Accountability does not vanish
because the call is inside a pipe.

**The gate is the loop's gate.** `mcp`/`tool` must go through the same
validate-reason → resolve → approval → invoke → record path the loop uses, not a
shortcut. That pipeline already exists (and Parallel Tool Calls made the gate
concurrent), so the tier calls it. The consequence is the policy: the shell's
builtins are asked as they are today, and an MCP/tool call inside the script gets
**that tool's own ask** — no blanket pass from the script grant, no bypass.

**Result mapping.** Success → stdout; failure → stderr + exit 1; the tool's
observer → the command's stdout, so a text tool is pipeable. Output is bounded by
the existing tool-output budget; a binary result (a screenshot) is returned as an
artifact reference, not written to stdout.

**Allow-list rules.**

- Expose an **explicit** set of providers/tools (operator or config), never the
  whole registry automatically.
- **Never** expose `run_command`, the tier itself, `bash`/`sh`, or delegating/
  async tools (subagents): they re-enter the boundary or leave the process model.
- Resolve **at execution**, not at parse: Lazy MCP registers tools on load, so the
  command set is dynamic; an unloaded tool is a clear command-not-found error.

## Own vs pass through: what is worth rewriting

The question is not "can we reimplement `grep`?" but "which operations must the
operator be able to see and bound?"

| | Rewrite internally | Pass through to the real binary |
| --- | --- | --- |
| Fidelity | a documented subset | exact, all flags |
| Mediation | **full** — the operation is an API call (path, args) | program-level only |
| Host exposure | none — no binary | the binary's own reach (`-exec`, `-i`, `-r`, `xargs`, interpreters) |
| Path gating | exact (`PhysicalContains`) | heuristic (path-like arguments) |
| Portability | uniform (GNU/BSD differences gone) | GNU vs BSD drift |
| Cost | one project per command | zero |
| Testability | in-process, no subprocess | process + smoke |
| Model knowledge | must learn the subset | exact |

**The rule that follows:** rewrite what **touches the workspace or spawns**
(read/list/glob/grep/stat/write/edit/mkdir/rm/mv/cp/touch); pass through what only
**transforms bytes** (`sort`, `uniq`, `cut`, `tr`, `diff`, `base64`, hashes);
**never** re-enter the shell inside the tier (`bash`, `sh`, `eval`, `source`,
`xargs`, `find -exec`, `env`, `timeout`, `sudo`). The interpreters (`awk`, `sed`,
`jq`, `yq`) are passed through gated — rewriting them is the "second interpreter"
trap — and their file arguments still go through the path gate.

**"Enough to get work done" is a documented subset.** Each owned command states
what it supports; an unsupported flag is a clear error that names the fallback
("`grep -P` is not supported in the builtin tier; use the shell tool"). The model
learns a smaller surface, once, instead of the tool silently behaving differently.

**Three policies, and the real decision is mediation vs capability:**

1. **Closed tier.** Only our implementations; no real binaries. Maximum mediation,
   minimum capability — the model hits the ceiling and must ask.
2. **Default-closed, explicit escalation.** Our builtins are the default; anything
   else escalates to the existing `run_command` (program-gated, path-gated,
   labelled `shell:` in the result). The common case is fully mediated; the escape
   is visible and gated.
3. **Passthru by default.** Today: every command is a real binary behind a
   program-level gate.

**Recommendation: 2.** It gives the agent the flexibility it needs without
pretending the real shell is gone. The security claim becomes precise: *the
default path is mediated; the escape hatch is explicit, gated, and labelled* —
rather than "we gate programs".

## A standalone command-tool library

The tier should be a **library first** and a harness feature second — the Async
Core pattern (`src/async`, `async.*`, `make async-standalone`, an isolation
test), not a unit inside the harness. The consumer registers commands; the
library owns the language.

**The boundary:**

| Owned by the library | Owned by the consumer |
| --- | --- |
| The shell **language**: control flow (`if`/`for`/`while`/`until`/`case`), lists (`&&`/`\|\|`/`;`), pipelines, redirections, functions, exit status | The **commands** (`ls`, `cat`, `grep`, …) — one handler per name |
| The **interpreter** (AST walk, expansion, word splitting, fd wiring) | The **filesystem** (the workspace) and the **environment** |
| The **command registry** (name → handler, aliases) | The **policy** — the approval gate, per-command |
| **Execution limits** (command count, loop iterations, depth, output, time) | The limits' *values* |
| The **parser seam** (an injected `TScriptParser`) | The parser *adapter* (tree-sitter) |

**The API shape (sketch):**

```pascal
unit shell.types;
type
  TShellCall = record
    Name: string;
    Args: TStringArray;       // already expanded and split
    Stdin: string;
    Cwd: string;
    Env: TShellEnv;
  end;
  TShellResult = record
    Stdout: string;
    Stderr: string;
    ExitCode: Integer;
  end;

unit shell.registry;
type
  TShellHandler = function(const ACall: TShellCall): TShellResult of object;
  { Consulted before the handler; False = denied (stderr + a non-zero status). }
  TShellGate = function(const ACall: TShellCall): Boolean of object;
  TShellRegistry = class
    procedure Register(const AName: string; AHandler: TShellHandler);
    function Resolve(const AName: string; out AHandler: TShellHandler): Boolean;
  end;

unit shell.interpreter;
type
  TShellParser = function(const ASource: string; out AScript: TShellScript;
    out AError: string): Boolean of object;
  TShell = class
    constructor Create(AParser: TShellParser; ARegistry: TShellRegistry;
      AFs: IShellFileSystem; AGate: TShellGate);
    function Run(const ASource: string; out AOutput, AError: string): Integer;
  end;
```

**Decision (2026-10-19): own the parser.** The library ships its own lexer and
recursive-descent parser; **tree-sitter is no longer a dependency of the command
tool**. It stays only in the TUI, as the syntax-highlighting engine
(`TUI_Syntax_Highlighting`).

Why:

- The corpus is already large — **6,295 real commands** — and the target is a
  bounded subset, so the grammar can be tested against real input from day one.
- A hand-written parser keeps the library pure Pascal and independently
  publishable: no C runtime, no grammar ABI, no vendored artifacts.
- No regex on untrusted input, by construction (a lexer + recursive descent).
- One parser for every consumer: the approval asks, the builtin tier, and the
  path extraction.

The cost is explicit: we own the grammar's correctness — quoting, reserved
words, heredoc termination, expansions. Mitigation: the subset (below), the
corpus as a fixture, and differential tests against `/bin/bash` for the supported
forms.

**Every *effect* is a consumer seam.** A command handler covers `cat`/`rm`; but
the *shell* also writes (a `>` redirect), reads (a `<`), and lists (a glob `*`).
Those must go through `IShellFileSystem`, and the consumer's implementation is
where the path bound lives (`PhysicalContains`). Likewise the gate is consulted
before every handler, so a handler can never be reached around the policy.

**Packaging.** `src/shell/` with `shell.*` units, no `hildegard.helper.*`
dependency, an isolation test that walks the `uses` closure (like
`TestHeadlessClosureExcludesTui`), and a `make shell-standalone` smoke. A version,
a license (this repository has none of its own yet — a publishing prerequisite),
and a documented API surface.

**Scope is staged, and the language is the cost.**
- **v1 — control flow + simple commands**: `if`/`for`/`while`/`until`/`case`,
  `&& || ;`, pipelines, redirects, env assignment, functions, `$?`, `$VAR`,
  `"…"`/`'…'`, globs. This is "handle all the control flow" with a bounded
  expansion model.
- **v2 — the expansion surface**: `${…}` operators, `$@`/`$#`, arithmetic
  `$((…))`, `$(…)`, process substitution, heredocs.
- **Never**: `eval`/`source`, and any command that spawns (the consumer can
  register such a handler, but the library does not provide one).

The v1/v2 split matters: expansions are where shell semantics get subtle, and
they are the difference between a page of code and a project.

## The parser we own

**Layering** (each a unit, each testable alone):

```
lexer       source bytes → tokens (words in quoting modes, operators,
            redirections, newlines, comments)
words       a token → a word (literal, quoted, escaped, $VAR, glob, tilde, …)
parser      words/operators → AST:
              simple command   assignments, words, redirects
              pipeline         | |&
              list             && || ; & newline
              compound         if / for / while / until / case / { } / ( ) /
                               function definitions
            here-docs are the lexer/parser interaction: the lexer defers a body
            until the terminator, the parser attaches it to the redirect
arithmetic  a small precedence-climbing expression parser (v2)
```

Reserved words (`if`, `then`, `fi`, `for`, `do`, `done`, …) are recognised only
in command position — the classic reason a shell parser is not a word list.

**The subset (v1).** Control flow and simple commands:

- lists: `&&`, `||`, `;`, `&`, newlines; pipelines `|`, `|&`;
- compound: `if/elif/else/fi`, `for … in …; do … done`, `while`/`until`, `case`,
  `{ …; }`, `( … )`, function definitions;
- words: literals, `'…'`, `"…"`, `\` escapes, `$VAR`/`${VAR}` (basic), tilde,
  globs (`*`, `?`, `[…]`), `$?`, `$1`/`$@`/`$#`;
- redirections: `< > >> 2> 2>&1 &>`, `<&`; here-docs `<<`/`<<-`;
- assignment prefixes (`VAR=x cmd`);
- comments and line continuation (`\` newline).

**v2** adds `${VAR:-…}` and the other parameter operators, `$((…))`,
`$(…)`/backticks, process substitution `<(...)`, brace expansion, and the full
word-splitting/`IFS` model.

**Test strategy, in layers:**

1. **The corpus** — the 6,295 real commands. The parser must accept every command
   in the supported subset with no error, and the ask extractor must name the
   same programs the current splitter does on the linear bucket (a differential
   against today's behaviour).
2. **Golden ASTs** for a hand-picked set per construct. The just-bash corpus and
   the POSIX shell grammar are the references.
3. **Differential execution** against `/bin/bash` for the supported forms: run
   the snippet in both, compare stdout/stderr/exit code; record the fixtures so
   the check is hermetic (just-bash's comparison tests do exactly this).
4. **Fail-safe** — a parse error is a first-class outcome: the consumer gets the
   error and the conservative path applies; a test pins it.

**The known-hard list** (write these tests first): quoting modes; reserved words
in command position; heredoc bodies and `<<-` indentation; `case` patterns;
`;;`/`;&`/`;;&`; `$(…)` nesting inside double quotes; `$'…'`; word-splitting and
globbing order; operator precedence (`|` vs `&&` vs `;`); redirection order and
fd duplication.

**The property to keep:** no regex, no backtracking — a lexer and recursive
descent with bounded lookahead. Fuzz it with the corpus plus a generated-input
loop.

## Limits (the checklist)

just-bash's `limits.ts` maps almost one-to-one onto bounds we already have or
should state for the tier:

- source bytes (`maxSourceBytes`), command count (`maxCommandCount`), call depth
  (`maxCallDepth`), loop iterations (`maxLoopIterations`);
- output bytes (`maxOutputSize`), string length, heredoc size, array elements;
- traversal entries/depth/work for `find`/glob;
- wall clock (`maxExecutionTimeMs`) and a cancel-poll grace;
- FS bytes retained (for us: workspace size is the operator's, not ours).

Our existing equivalents: `Context_Budget` (tool output cap), `Tool_Limits`
(call budget), the `run_command` timeout (5 min default, 1 h ceiling), and the
cancel check. The tier needs its **own** command-count and loop-iteration bounds
because it runs no process for the OS to kill.

## Risks and open questions

1. **Command fidelity.** A partial `grep` that differs from real `grep` is a
   correctness bug the model will discover at the worst time. Mitigation: keep
   the starter set small, specify behaviour against the real tool, and test
   differential output where cheap.
2. **Word splitting and globbing** are where shell semantics get subtle
   (`IFS`, quoted globs, `nullglob`). Tier A should use **one** documented
   expansion model and refuse what it does not implement.
3. **The real-shell boundary remains** for anything outside the set, so the
   gate is still needed. The win is that the *default* is closed, not that the
   shell disappears.
4. **Two shell surfaces** confuse the model if both are exposed as tools.
   Prefer one tool with an honest result line naming the tier.
5. **The parked sandbox's lesson stands:** a new interpreter is a new thing to
   secure and test. Tier A is not an interpreter (no expansions beyond globs);
   Tier B is, and should be treated as such.
6. **The FS is the real workspace.** Unlike just-bash's in-memory default, a
   builtin write has real effects — the approval gate and `PhysicalContains`
   must be on every mutating command, not only on the process boundary.
7. **argv↔JSON quoting** is the highest-risk seam in the tool dispatch. A tool
   call inside a shell string has to survive quoting, and a malformed JSON
   argument must fail clearly rather than be guessed at.
8. **The tool set is dynamic.** Lazy MCP registers tools on load, so the tier
   resolves at execution; an unloaded tool is a clear error, and the exposed
   allow-list is explicit.

## What to build if this is accepted

1. The **library**: `src/shell/` (`shell.*`), no `hildegard.helper.*`
   dependency, an isolation test over the `uses` closure, `make shell-standalone`.
2. The **parser** (the first component): lexer, words, simple/compound/list
   parsing, here-docs; the corpus + golden ASTs + differential fixtures.
3. The **interpreter**: the AST walk, pipelines/redirects/fd wiring, the
   registry, the gate and FS seams, the limits.
4. A **FEATURE** and **SPEC** for the library (the closed-set property, the
   subset, the API, the limits, the fallback).
5. The **harness consumer**: register `ls`/`cat`/… handlers over the file tools;
   `mcp`/`tool` dispatch through the loop's per-call pipeline; the explicit
   allow-list; the labelled escalation.
6. TDD throughout: the parser corpus and differential tests, each command's
   behaviour, the gate subjects, the limits, and the fallback.

**Implementation can start now.** The library and its parser do not depend on
Tree-Sitter, which is now only the TUI highlighter — the two workstreams are
independent.
