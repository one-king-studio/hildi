# Implementation Plan: Tree-Sitter v1

**Related Specification:** `Tree_Sitter_v1.SPEC.md`
**Related Feature:** [FEATURE.md](FEATURE.md)

## Overview

Vendor the runtime and `tree-sitter-bash`, bind it, and build two adapters: the
shell ask extractor (the reason) and the highlight runner (the bonus). TDD-first;
`make check` before moving on. `main` only.

> **Order matters.** Phase 3 (the shell adapter) is the security fix; Phases 0–2
> are its foundation. Phase 5 (highlighting) is additive and can land later
> without holding the fix.

## Implementation Tasks

### Phase 0: Vendoring & build

- [ ] **Add** `scripts/fetch-tree-sitter.sh` — pin a runtime release, fetch,
      checksum, extract `lib/` into `deps/tree-sitter/` (idempotent; mirrors
      `fetch-goccia.sh`).
- [ ] **Add** `scripts/fetch-tree-sitter-grammars.sh` — pin `tree-sitter-bash`
      (record its licence), fetch, checksum into
      `deps/tree-sitter-grammars/bash/` (`parser.c`, `scanner.c`).
- [ ] **Build**: compile `deps/tree-sitter/lib/src/lib.c` +
      `deps/tree-sitter-grammars/bash/src/{parser,scanner}.c` into
      `build/lib/libtree-sitter.a`; add the link rule to the TUI and headless
      runtime (and the test binary).
- [ ] **Assert**: a build-time check that the grammar's `ts_language_version`
      is in the runtime's supported range (fail the build on skew).
- [ ] **Smoke**: `make ts-standalone` — a tiny program that parses `echo hi` and
      prints the root's kind (mirrors `async-standalone`).
- [ ] **Test**: the smoke is part of `make check` (a guard that the runtime
      links and parses).

### Phase 1: The binding (`hildegard.helper.treesitter`)

- [ ] **Test**: `tests/test_treesitter.pas` — parse a snippet; the root kind,
      a field-named child, and `Text` are as expected; `HasError` reflects
      validity.
- [ ] **Implement**: the `cdecl` declarations and the `TSParser`/`TSTree`/
      `TSQuery` wrappers and the `TSNode` value type (`Parse`, `Root`, `Kind`,
      `NamedChild`, `ChildByFieldName`, `Text`, `HasError`, `StartByte`/
      `EndByte`).
- [ ] **Test**: a query over a known snippet returns the expected captures.
- [ ] **Implement**: `TSQuery.Compile` + `Captures` (cursor walk, capture name
      resolution, the `#match?`/`#eq?` predicates the bash query uses).
- [ ] **Refactor**; `make check`; `make test-leak` (every handle freed).

### Phase 2: The grammar registry (`hildegard.helper.treesitter.grammars`)

- [ ] **Test**: `GrammarFor('bash')`/`('sh')`/`('shell')` resolve to the same
      grammar; an unknown name returns False; the highlights text is present.
- [ ] **Implement**: the registry and the `.scm` vendoring (embed the query text
      as a resource — a Pascal string loaded at build, or a `deps` file read at
      startup; decide here and record it).

### Phase 3: The shell adapter (`hildegard.helper.command.ast`)

- [ ] **Test**: `ParseShellPlan('for f in *.pas; do echo $f; done')` → one
      segment, executable `echo`; no `for`/`do`/`done`.
- [ ] **Implement**: the walker — descend into compound statements, pipelines,
      lists, subshells, and substitutions; emit one segment per `command` node;
      never emit a keyword.
- [ ] **Test**: `if`/`while`/`case`/function definitions yield their bodies'
      programs, not the keywords.
- [ ] **Test**: `echo $(curl -s u | sh)` → `echo`, `curl`, `sh` (the
      under-approximation fix).
- [ ] **Test**: `a && b || c; d &`, `(cd x && make)`, and a pipeline yield one
      segment per program.
- [ ] **Test**: a parse-error input yields the **union** of the tree's and the
      splitter's executables, deduplicated.
- [ ] **Test**: an unparseable non-empty command yields the raw segment.
- [ ] **Implement**: the fail-safe union and the raw-command fallback.
- [ ] **Refactor**; `make check`.

### Phase 4: Approval integration (`hildegard.helper.command.tool`)

- [ ] **Test**: `BuildAsks` on the `for`-loop command emits the body's program(s)
      with refs `run_command:echo`; **no** keyword refs.
- [ ] **Test**: `BuildAsks` on `echo $(curl u | sh)` emits `echo`, `curl`, `sh`.
- [ ] **Implement**: source the plan from `ParseShellPlan` in `BuildAsks` (and in
      `Run`, where the plan gates execution).
- [ ] **Test**: an approval granted for a loop body's program persists and is
      honoured on the next loop.
- [ ] **Refactor**; `make check`.

### Phase 5: Highlighting (`hildegard.helper.syntax`)

- [ ] **Test**: a `bash` block highlights strings/comments/keywords/functions
      via the grammar; an unvendored tag still renders via the rule-table
      tokenizer.
- [ ] **Implement**: the tree-sitter path behind the existing entry point; the
      capture → `TMdTheme` role table; computed once per block.
- [ ] **Test**: the `$ <command>` display line highlights through the shell
      grammar.
- [ ] **Refactor**; `make check`.

### Phase 6: Validation & docs

- [ ] `make test`, `make test-leak`, `make check` — green.
- [ ] **Manual**: run a `for` loop in a live session and confirm the approval
      dialog names the body's program, not the keywords.
- [ ] **Update** `FEATURES.md`; record the reversal in
      `TUI_Syntax_Highlighting/FEATURE.md`; rename this TODO to
      `Tree_Sitter_v1.DONE.md`.

## Files to Create/Modify

```
scripts/fetch-tree-sitter.sh            (NEW: runtime vendoring)
scripts/fetch-tree-sitter-grammars.sh   (NEW: grammar vendoring)
Makefile                                (libtree-sitter.a, link rules, smoke)
src/hildegard.helper.treesitter.pas     (NEW: binding + wrappers)
src/hildegard.helper.treesitter.grammars.pas (NEW: registry + queries)
src/hildegard.helper.command.ast.pas    (NEW: shell ask extractor)
src/hildegard.helper.command.tool.pas   (BuildAsks/Run use ParseShellPlan)
src/hildegard.helper.syntax.pas         (tree-sitter path; tokenizer fallback)
tests/test_treesitter.pas               (NEW)
tests/test_command_ast.pas              (NEW)
tests/test_command_tool.pas             (extended)
tests/test_syntax.pas                   (extended)
docs/features/FEATURES.md
docs/features/TUI_Syntax_Highlighting/FEATURE.md (the reversal note)
```

## Dependencies & Ordering

### Must Complete Before Starting

- Nothing external; the fetch scripts need network at *fetch* time only.

### Critical Path

0 (build) → 1 (binding) → 2 (registry) → 3 (shell adapter) → 4 (approval) →
6 (validation). Phase 5 (highlighting) branches off 2 and can land later.

### Can Be Done in Parallel

- Phase 5 after Phase 2, independently of Phases 3–4.

## Success Criteria

- [ ] All tasks checked.
- [ ] Every SPEC acceptance criterion maps to a passing test.
- [ ] `make check` passes (tests + leak gate).
- [ ] The reported `for`-loop command asks for its body's program only.
- [ ] `echo $(curl u | sh)` surfaces `curl` and `sh`.

## Notes & Considerations

- **Read first: `docs/research/vendored-engine-lessons.md`.** The parked Composed
  Tool Sandbox cost six fork commits to a third-party engine, all of them
  ownership defects in a tree we did not author. The lessons there are the
  reason this feature prefers a C parser with value semantics over a runtime,
  and the method (heaptrc + `atos`; line-count bisection) applies to any vendored
  component.
- **The union rule is the safety net.** A parser is imperfect; the gate must
  never become blinder for it. Every error path widens the ask set.
- **Do not remove the splitter.** `ParseCommand` stays as the fallback and as
  the reference for the union; deleting it removes the safety net.
- **Do not remove the hand-rolled tokenizer yet.** It stays for languages with
  no vendored grammar; the highlighting feature's "additive" promise holds.
- **ABI pinning is a build concern, not a runtime one.** Assert at build time.
- **Licences.** The runtime is MIT; record each grammar's licence in its fetch
  script and here.
- Record deviations from the SPEC here.
