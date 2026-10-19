# Implementation Plan: Shell Library v1

**Related Specification:** `Shell_Parser_v1.SPEC.md`, `Shell_Interpreter_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

A standalone, pure-Pascal shell library: its own lexer/parser, an interpreter
that owns control flow, and a command registry the consumer fills. Parser first
(the corpus gates it), then the interpreter. TDD-first; `make check` before
moving on. `main` only.

## Implementation Tasks

### Phase 0: The package

- [ ] **Create** `src/shell/` with `shell.types`, `shell.ast`, `shell.lexer`,
      `shell.words`, `shell.parser`, `shell.interpreter`, `shell.registry`,
      `shell.fs`; every unit self-declares `{$mode delphi}{$H+}`.
- [ ] **Test**: `TestShellClosureExcludesHarness` — walk the library roots'
      transitive `uses`; assert no `hildegard.helper.*` / TUI / store / socket
      unit (mirror `TestHeadlessClosureExcludesTui`).
- [ ] **Add** `make shell-standalone` — build a tiny example against `src/shell`
      only (mirror `async-standalone`), and run it in `make check`.

### Phase 1: The AST (`shell.ast`)

- [ ] **Define** `TWord`/`TWordPart`, `TRedirect`, `TAssignment`, `TCommand`,
      `TPipeline`, `TAndOr`, `TStatement`, `TScript` per the SPEC.
- [ ] **Test**: construct a nested script by hand and assert the shapes the
      interpreter will rely on (precedence fields present).

### Phase 2: The lexer (`shell.lexer`)

- [ ] **Test**: token streams for operators, quoting modes, escapes, comments,
      line continuation, fd redirects, `&>`/`&>>`.
- [ ] **Implement**: the tokenizer with quoting modes and position tracking.
- [ ] **Test**: `#` rules (`#` at word start, `\#`, `#` in a word).
- [ ] **Test**: positions (line/column/offset).

### Phase 3: Words (`shell.words`)

- [ ] **Test**: literal, `'…'`, `"…"`, `\`, `$VAR`, `${VAR}`, `$?`, `$@`, `$#`,
      `$1`, `~`, globs; adjacent parts concatenate.
- [ ] **Test**: each unsupported construct (`${VAR:-x}`, `$((…))`, `$(…)`,
      backticks, `<(...)`, `{a,b}`) errors with its name.
- [ ] **Implement**: the word parser (pure; no expansion).

### Phase 4: Simple commands and redirects (`shell.parser`)

- [ ] **Test**: `cmd a b`, assignment prefixes, redirects (`>`, `>>`, `<`,
      `2>`, `2>&1`, `&>`), mixed order.
- [ ] **Implement**: simple-command parsing.
- [ ] **Test**: golden ASTs.

### Phase 5: Lists and pipelines

- [ ] **Test**: precedence (`a && b | c ; d` → `(a && (b|c)) ; d`),
      `|`/`|&`, `&&`/`||` association, `;`/`&`/newlines.
- [ ] **Implement**: pipeline + list parsing.

### Phase 6: Compound and functions

- [ ] **Test**: `if/elif/else/fi`, `for … in …; do … done`, `while`/`until`,
      `case … esac` (patterns, `;;`), `{ …; }`, `( … )`, `f() { …; }`,
      `function f { …; }`.
- [ ] **Test**: reserved words in command position vs as arguments.
- [ ] **Implement**: compound parsing.

### Phase 7: Here-docs

- [ ] **Test**: `<<EOF` (expanded), `<<'EOF'` (literal), `<<-EOF` (tabs),
      multiple in one command, unterminated (error naming the delimiter).
- [ ] **Implement**: the lexer deferral + parser attachment.

### Phase 8: The corpus

- [ ] **Add** a fixture: the recorded `run_command` arguments from the ledger
      (sanitized), as lines.
- [ ] **Test**: parse every line; assert no error inside the subset, the
      construct named outside it, and the counts against a recorded baseline.
- [ ] **Refactor** the parser against the corpus; fix the failures it exposes.

### Phase 9: The interpreter core (`shell.interpreter`)

- [ ] **Test**: a script walk with a trivial handler; `$?`; an unregistered
      command (127).
- [ ] **Implement**: `TShell.Run` over statements/pipelines/simple commands.
- [ ] **Test**: pipelines (stages, `|&`, last-stage status, subshell `cd`).
- [ ] **Test**: redirects (order, `2>&1`, failure) via a fake FS.
- [ ] **Implement**: fd wiring + the FS seam.

### Phase 10: The registry, gate, and builtins

- [ ] **Test**: the gate is called once per registered handler, in order, with
      expanded args; a denial is 126 and the handler never runs.
- [ ] **Implement**: `shell.registry` + the gate hook.
- [ ] **Test**: `cd`/`pwd`/`export`/`unset`/`local`/`shift`/`return`/`exit`.
- [ ] **Implement**: the library builtins (state-mutating; bounded by the FS).

### Phase 11: Expansions and control flow

- [ ] **Test**: quotes, `$VAR`, `$@`, `~`, globs (incl. no-match literal).
- [ ] **Test**: `if`/`for`/`while`/`until`/`case`/functions + `return`.
- [ ] **Implement**: expansion + the control-flow walk.

### Phase 12: Limits

- [ ] **Test**: command count, loop iterations, call depth, output bytes, wall
      clock — each aborts with a named error.
- [ ] **Implement**: the counters + the deadline check between commands.

### Phase 13: Differential fixtures (opt-in)

- [ ] **Add** a small script table; record `/bin/bash -c` results as fixtures;
      replay them against the interpreter in `make check` (no bash needed).

### Phase 14: Validation & docs

- [ ] `make test`, `make test-leak`, `make check` — green.
- [ ] **Update** `FEATURES.md`; rename this TODO to `Shell_Library_v1.DONE.md`.
- [ ] **Note** the harness consumer (the builtin tier) as a separate feature:
      handler registration, the tool dispatch (`mcp`/`tool`), the labelled
      escalation.

## Files to Create/Modify

```
src/shell/shell.types.pas          (env, call, result, handler, gate)
src/shell/shell.ast.pas            (the AST records)
src/shell/shell.lexer.pas          (tokens + quoting modes + positions)
src/shell/shell.words.pas          (word parts)
src/shell/shell.parser.pas         (recursive descent)
src/shell/shell.registry.pas       (name -> handler)
src/shell/shell.fs.pas             (IShellFileSystem)
src/shell/shell.interpreter.pas    (control flow + execution)
src/shell/shell.limits.pas         (the limits record + checks)
examples/shell_standalone.pas      (the make shell-standalone smoke)
tests/test_shell_lexer.pas
tests/test_shell_parser.pas
tests/test_shell_corpus.pas
tests/test_shell_interpreter.pas
tests/test_shell_consumer.pas
tests/test_shell_isolation.pas     (the uses-closure test)
tests/hildegard_helper_tests.pas   (register the suites)
tests/data/shell_corpus.txt        (the recorded commands)
Makefile                           (shell-standalone)
docs/features/FEATURES.md
```

## Dependencies & Ordering

### Critical Path

0 (package) → 1 (AST) → 2 (lexer) → 3 (words) → 4 (simple) → 5 (lists) →
6 (compound) → 7 (here-docs) → 8 (corpus) → 9 (interpreter) → 10 (registry) →
11 (expansions) → 12 (limits) → 14.

### Can Be Done in Parallel

- Phase 13 (differential fixtures) after Phase 11.
- The **harness consumer** (a separate feature) after Phase 10.

## Success Criteria

- [ ] All tasks checked.
- [ ] Every SPEC acceptance criterion maps to a passing test.
- [ ] `make check` passes (tests + leak gate).
- [ ] The corpus parses with zero in-subset errors.
- [ ] The isolation test proves the library links no harness unit.

## Notes & Considerations

- **The corpus is the oracle.** It is the reason we can write a parser rather
  than guess: 6,295 real commands, with a baseline of what the current splitter
  does.
- **Parser first, interpreter second.** A wrong AST is a wrong interpreter; the
  golden ASTs are the contract.
- **Do not add a construct the SPEC does not list.** v1 is a subset; the error
  message names the construct and the fallback.
- **The library builtins are the language.** `cd`/`export` mutate shell state,
  which is the library's; the consumer registers external commands. This is a
  deliberate deviation from "the consumer registers `cd`" — shell state cannot
  live in a handler without exposing the shell's internals.
- **Never spawn, never `eval`/`source`.** Those are consumer decisions, gated by
  the consumer.
- Record deviations from the SPEC here.
