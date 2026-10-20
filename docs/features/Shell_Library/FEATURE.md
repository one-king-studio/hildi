# Shell Library

**Status:** Implemented (v1, 2026-10-19) — `Shell_Library_v1.DONE.md`. A
standalone, publishable library that depends on no harness unit; the harness is
its first consumer, through the [Builtin Shell Tier](../Builtin_Shell_Tier/FEATURE.md).

## Overview

A **standalone, publishable shell library** written in Free Pascal: its own
lexer and parser, an interpreter that owns the shell language, and a **registry
of commands** the consumer plugs in. It depends on no harness unit, so it can be
published independently; the harness is its first consumer.

The decision it records (2026-10-19): **we write the parser ourselves**.
Tree-sitter is no longer a dependency of the command tool — it stays only in the
TUI as the syntax-highlighting engine. The rationale and the study that led here
are in
[`docs/research/just-bash-and-the-builtin-shell-tier.md`](../../research/just-bash-and-the-builtin-shell-tier.md).

The point of the library is a **closed shell**: the language is ours (control
flow, pipelines, redirections, expansions), and *commands are capabilities the
consumer registers*. Anything not registered does not run. That is how the
harness gains a mediateable shell without a JS VM, a C parser, or a real
`/bin/bash`.

## Problem Statement

Three failed or insufficient approaches precede this:

1. **The real shell cannot be mediated.** `run_command` runs `/bin/bash -c`
   behind a program-level gate. The gate names the programs; it does not own
   them. `bash -c`, `eval`, `xargs`, `find -exec`, and interpreters all hide
   work behind one approved name.
2. **The splitter is a guardrail, not a parser.** `command.policy.ParseCommand`
   splits at unquoted operators and takes each first word as the executable. It
   invents programs (`for`, `do`, `done`) and misses programs (`$(…)`).
3. **The parked sandbox chose the wrong layer.** It added a JavaScript VM to
   *observe* compound work. The work being hidden was shell, and the boundary
   that needs to see it is the shell boundary — not a new interpreter.

The cheaper correction: own the **shell language** (a parser we can test) and
make **commands** a registry. No new runtime, no vendored parser, no host shell
for the default path.

## Goals

- **A shell parser we own.** A lexer plus recursive descent — no regex, no
  backtracking — covering a documented v1 subset: lists, pipelines, compound
  commands, functions, redirections, here-docs, and basic words.
- **The interpreter owns the language.** Control flow, pipelines, redirection
  wiring, exit status, and the environment are internal to the library.
- **Commands are a registry.** A consumer registers `ls`, `cat`, `grep`, … by
  name; the library resolves a call against the registry and reports
  `command not found` for anything else.
- **Every effect is a seam.** The filesystem (redirects, globs), the environment,
  and a **gate** consulted before every handler belong to the consumer. A
  handler cannot be reached around the policy.
- **Standalone and publishable.** `src/shell/` with `shell.*` units, no
  `hildegard.helper.*` dependency, an isolation test over the `uses` closure, and
  a `make shell-standalone` smoke.
- **Fail-safe.** A parse error is a first-class outcome: the caller gets the
  error and its position. The consumer decides the conservative path (today's
  splitter, or a refusal).
- **Limits in the library.** Command count, loop iterations, call depth, output
  bytes, and a wall-clock deadline — because the library runs no process for the
  OS to kill.

## Non-Goals

- **Full bash.** The v1 subset is documented and enforced; v2 adds the expansion
  surface. A construct outside the subset is a parse error, not a best effort.
- **`eval` / `source` / `.`** — executing text that is not in the input.
- **Spawning.** The library never starts a process. A consumer may register a
  handler that does (the harness's real-shell escalation), but that is the
  consumer's decision and its own gate.
- **Being a sandbox.** It is a guardrail: the consumer's FS and gate are the
  boundary, and the OS boundary is unchanged.
- **Embedded runtimes** (JS, Python, SQL). Each is a new interpreter to secure —
  the parked sandbox's lesson.
- **Syntax highlighting.** That is the TUI's concern, served by tree-sitter.
- **A general POSIX shell** for arbitrary scripts; this serves an agent's
  commands, not `/etc/rc`.

## User Stories

- As a **harness author**, I want to register a handler per command, so
  supporting `ls` or a new MCP tool is a registration, not a core change.
- As a **harness author**, I want the shell's effects (redirects, globs) to go
  through my filesystem, so the workspace bound applies to the whole script.
- As an **operator**, I want every command in a script to pass my gate, so a
  loop cannot run something I did not approve.
- As a **library consumer**, I want a parser and interpreter with no harness
  dependency, so I can use or publish it on its own.
- As a **test author**, I want a parse failure to be a value (message +
  position), not an exception, so I can pin the exact behaviour.

## Acceptance Criteria

### Functional

- [ ] **Parse** a script into an AST: lists (`&&`, `||`, `;`, `&`, newlines),
      pipelines (`|`, `|&`), simple commands (assignments, words, redirects),
      compound commands (`if`, `for`, `while`, `until`, `case`, `{ }`, `( )`),
      function definitions, and here-docs (`<<`, `<<-`).
- [ ] **Words**: literals, `'…'`, `"…"`, `\` escapes, `$VAR`, `${VAR}`, `$?`,
      `$1`/`$@`/`$#`, tilde, and globs (`*`, `?`, `[…]`).
- [ ] **Reserved words** (`if`, `then`, `fi`, `for`, `do`, `done`, …) are
      recognised only in command position.
- [ ] **Execute** the AST: control flow, pipelines, redirections (including
      `2>&1` and fd duplication), assignment prefixes, and the exit status.
- [ ] **Registry**: a name resolves to a handler; an unknown name is
      `command not found` with a non-zero status.
- [ ] **Gate**: consulted before every handler; a denial is a stderr line and a
      non-zero status, never a silent skip.
- [ ] **Filesystem seam**: redirects, input redirection, and glob expansion all
      go through the consumer's filesystem.
- [ ] **Limits**: command count, loop iterations, call depth, output bytes, and
      a wall-clock deadline all bound execution with a clear error.
- [ ] **Fail-safe**: a parse error returns the message and position; nothing is
      executed.

### Non-Functional

- [ ] **Standalone**: the library's transitive `uses` closure contains no
      `hildegard.helper.*`, TUI, store, or network unit (asserted by a test).
- [ ] **No regex, no backtracking**: a hand-written lexer and recursive descent
      with bounded lookahead.
- [ ] **Deterministic**: the same script and registry produce the same output,
      status, and handler-call order.
- [ ] **Bounded**: a malformed or adversarial input terminates in bounded time
      and memory.
- [ ] **Leak-clean** under `make test-leak`; `make check` green.
- [ ] **Publishable**: a version, a documented API, a license decision, and no
      build step beyond FPC.

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`, POSIX (macOS/Linux).
- Pure Pascal; no external dependency, no C, no vendored parser.
- `src/shell/` with `shell.*` units (the Async Core precedent: `src/async`,
  `async.*`, an isolation gate).
- POSIX shell semantics for the supported subset; GNU-isms are not a target.
- The AST is the library's own; it does not mirror any external grammar's nodes.

### Business / Time

- No deadline. `main` only, TDD-first, one logical commit per step.
- The parser lands before the interpreter; the corpus gates the parser.

## Dependencies

### Internal

- None. The library is standalone by construction.
- The **harness** consumes it: the builtin tier registers handlers, supplies the
  workspace-backed filesystem and the approval gate, and escalates unregistered
  commands to the real shell (a separate feature).

### External

- None.

## Risks

- **Parser correctness.** Shell grammar is subtle (quoting, reserved words,
  heredoc termination, operator precedence). Mitigation: the documented subset,
  the 6,295-command corpus, golden ASTs, and differential tests against
  `/bin/bash` with recorded fixtures.
- **Scope creep toward full bash.** Mitigation: v1/v2 are explicit; a construct
  outside the subset is an error, and the corpus measures how often that happens.
- **A new interpreter to secure.** Mitigation: no spawn, no `eval`/`source`, the
  gate before every handler, the FS seam, and the limits. The parked sandbox's
  lesson (a boundary component needs a degraded mode and a test) applies.
- **Divergence from `/bin/bash`.** Mitigation: differential fixtures and a
  documented "supported subset" that the error messages name.
- **Publishing prerequisites.** No license exists in the repository yet; a
  version and an API-stability policy are part of "publishable".

## Out of Scope

- Word-splitting/`IFS` subtleties beyond v1's documented model (v2).
- Job control (background `&` is parsed and run sequentially).
- Signals, traps, `set -e`/`set -u` semantics, `shopt`.
- Locale-dependent collation and character classes in globs.
- Windows.

## Future Considerations

- **v2 expansions**: `${VAR:-…}` and the parameter operators, `$((…))`,
  `$(…)`/backticks, process substitution, brace expansion, the full splitting
  model.
- **A serializer** (AST → shell text) for tests and transforms — just-bash's
  `parse → transform → serialize` pipeline.
- **A transform hook** (AST in, AST out) as a gating/instrumentation seam.
- **Other consumers**: a REPL, a script checker, a linter.

## Notes

- **Decision (2026-10-19): own the parser.** Reasons, the three rejected parser
  options, and the study of just-bash are in
  [`docs/research/just-bash-and-the-builtin-shell-tier.md`](../../research/just-bash-and-the-builtin-shell-tier.md).
- **Tree-Sitter is out of this path.** It remains only the TUI highlighter
  ([`Tree_Sitter`](../Tree_Sitter/FEATURE.md), scope note 2026-10-19). The
  highlighter and this parser use different grammars and may disagree on exotic
  syntax; the parser is the authority.
- **ICE score: Impact 9** (a mediateable shell is the point of the trust model),
  **Confidence 6** (the parser is the work; the corpus makes it measurable),
  **Ease 3** (a parser + interpreter is a project, staged by v1/v2).
- **Prior art:** just-bash (the closed-set shell in the host), POSIX's shell
  grammar, `mvdan/sh` (a Go shell parser).
