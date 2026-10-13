# Component Specification: Tree-Sitter v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `hildegard.helper.command.policy` (the plan types and the
fallback splitter), `hildegard.helper.command.tool` (the approval adapter),
`hildegard.helper.syntax` / `hildegard.helper.tui.markdownview` (the
highlighting consumer), `hildegard.helper.wrap` (the `$ <command>` display).

## Purpose

Vendor the tree-sitter C runtime and the `tree-sitter-bash` grammar, bind the
runtime to FPC, and build two adapters over one tree: a **shell ask extractor**
for the approval gate, and a **highlight query runner** for fenced code blocks.
The shell adapter is the reason; the highlighting adapter rides along.

## Requirements

### Functional

- [ ] **Vendoring.** `scripts/fetch-tree-sitter.sh` fetches a pinned tree-sitter
      runtime release into `deps/tree-sitter/` and verifies its checksum;
      `scripts/fetch-tree-sitter-grammars.sh` fetches each pinned grammar
      (`bash` first) into `deps/tree-sitter-grammars/<lang>/`. Neither is
      committed; both are idempotent.
- [ ] **Build.** The Makefile compiles the runtime amalgamation
      (`lib/src/lib.c`) and each grammar's `parser.c` (+ `scanner.c` when
      present) into `libtree-sitter.a`, and links it into every binary that
      parses (the TUI and the headless runtime). A **build-time assertion**
      checks each grammar's `ts_language_version` is supported by the runtime;
      skew fails the build.
- [ ] **Binding.** `hildegard.helper.treesitter` declares the C API and wraps it
      in owned handles (`TSParser`, `TSTree`, `TSQuery`) and value nodes
      (`TSNode`), so a parse is one call and cleanup is automatic (leak-gate
      clean).
- [ ] **Grammar registry.** `hildegard.helper.treesitter.grammars` maps a
      language name (with aliases: `sh`/`bash`/`shell` → bash) to its
      `TSLanguage` and its vendored `.scm` query files. An unknown name yields
      no grammar (the consumer degrades).
- [ ] **Shell adapter.** `hildegard.helper.command.ast.ParseShellPlan(const
      ACommand: string): TCommandPlan` parses with `tree-sitter-bash` and
      returns the **same `TCommandPlan`/`TCommandSegment` shape** the approval
      adapter already consumes, with one segment per *program actually run*.
- [ ] **Program extraction.** The extractor walks the tree and yields a segment
      for every `command` node, descending into: `for_statement`,
      `if_statement`, `while_statement`, `until_statement`, `case_statement`,
      `function_definition`, `subshell`, `compound_statement`,
      `command_substitution`, `process_substitution`, and the list/pipeline
      nodes (`list`, `pipeline`, `&&`, `||`). **No shell keyword** (`for`, `do`,
      `done`, `if`, `then`, `elif`, `else`, `fi`, `while`, `until`, `case`,
      `esac`, `in`, `function`, `select`) may ever appear as an executable.
- [ ] **Fail-safe union.** If the tree contains any `ERROR`/`MISSING` node, the
      returned plan is the **union** of the tree's segments and
      `ParseCommand`'s (the conservative splitter), deduplicated by executable.
      If the tree is empty or the grammar is unavailable, the plan is the
      splitter's plan unchanged. If *both* yield nothing while the command is
      non-empty, the plan carries the **raw command** as a single segment
      (executable = the trimmed first token, `ParseError` set).
- [ ] **Approval adapter.** `BuildAsks` sources its plan from `ParseShellPlan`
      and keeps its current contract: one `TApprovalAsk` per executable, ref
      `run_command:<basename>`, the call's reason carried on each ask.
- [ ] **Highlight adapter.** `hildegard.helper.syntax` gains a tree-sitter path:
      when the fence's language maps to a vendored grammar, spans come from the
      grammar's `highlights.scm` mapped capture → `TMdTheme` role; otherwise the
      existing hand-rolled tokenizer runs unchanged. The public shape (text +
      language → spans) is preserved.
- [ ] **`$ <command>` display.** The streamed command line highlights through
      the shell grammar via the same adapter.

### Non-Functional

- [ ] **Deterministic.** The same command yields the same plan (segments in
      first-appearance order; executables deduplicated).
- [ ] **Bounded.** A parse always terminates; the walk is bounded by the node
      count. No unbounded work on malformed input.
- [ ] **No new runtime dependency.** Static linking only; no network, no
      external process, no WASM.
- [ ] **Leak-clean.** Every `TSParser`/`TSTree`/`TSQuery`/cursor is freed;
      `make test-leak` is green.
- [ ] `make check` green.

## Contracts & Interfaces

```pascal
unit hildegard.helper.treesitter;   // NEW: binding + RAII wrappers

type
  TSLanguage = Pointer;      // const TSLanguage*

  { A parsed source document. Owns the TSTree. }
  TSParseTree = class
    constructor Parse(ALanguage: TSLanguage; const ASource: string);
    destructor Destroy; override;
    function Root: TSNode;
    function HasError: Boolean;
  end;

  { A node value into a tree; cheap to copy. }
  TSNode = record
    function Kind: string;                       // node type name
    function IsNamed: Boolean;
    function HasError: Boolean;
    function StartByte: Cardinal;
    function EndByte: Cardinal;
    function NamedChildCount: Cardinal;
    function NamedChild(AIndex: Cardinal): TSNode;
    function ChildByFieldName(const AName: string): TSNode;
    function Text(const ASource: string): string;   // byte slice -> string
    function IsNull: Boolean;
  end;

  { A compiled S-expression query + a cursor over matches. }
  TSQuery = class
    constructor Compile(ALanguage: TSLanguage; const APattern: string);
    destructor Destroy; override;
    function Captures(ARoot: TSNode): TQueryCaptureArray;   // name + node
  end;

  TQueryCapture = record
    Name: string;     // the @capture
    Node: TSNode;
  end;
  TQueryCaptureArray = array of TQueryCapture;

{ The runtime version, for the build assertion and diagnostics. }
function TSRuntimeVersion: Cardinal;
{ A grammar's language version, to assert against the runtime. }
function TSLanguageVersion(ALanguage: TSLanguage): Cardinal;
```

```pascal
unit hildegard.helper.treesitter.grammars;   // NEW: registry + queries

type
  TGrammar = record
    Name: string;             // canonical ('bash')
    Language: TSLanguage;
    Highlights: string;       // the vendored highlights.scm text ('' if none)
  end;

{ The grammar for a fence tag or language name, with aliases resolved
  (sh/bash/shell -> bash). Returns False for an unknown or unvendored name. }
function GrammarFor(const AName: string; out AGrammar: TGrammar): Boolean;
```

```pascal
unit hildegard.helper.command.ast;   // NEW: the shell ask extractor

{ Parse a shell command with tree-sitter-bash and return the programs it runs,
  in the same TCommandPlan shape the approval adapter consumes. Fail-safe: on a
  parse error the plan is the union of the tree's segments and the conservative
  splitter's; if both are empty the raw command is the one segment. }
function ParseShellPlan(const ACommand: string): TCommandPlan;
```

```pascal
unit hildegard.helper.command.tool;   // CHANGED

{ BuildAsks now sources its plan from ParseShellPlan (was ParseCommand). }
```

```pascal
unit hildegard.helper.syntax;   // CHANGED (extended)

{ Unchanged shape. Internally: if GrammarFor(ALanguage) succeeds, spans come
  from the grammar's highlights.scm; else the existing rule-table tokenizer. }
function HighlightCode(const ACode, ALanguage: string): TSyntaxSpanArray;
```

### Data Contracts

- **Segment mapping.** A tree `command` node's first child is `command_name`
  (the executable); its remaining children are arguments. Redirections and
  path-like arguments are carried as today (`Redirects`, `Paths`), so the
  display and any future argument-level gating see the same shape.
- **Ask set.** `BuildAsks` emits one ask per distinct `ExtractFileName(executable)`
  (unchanged). The plan's segment order is the tree's document order.
- **Union rule.** `union = tree_segments ++ splitter_segments`, deduplicated by
  `ExtractFileName(executable)` keeping the first occurrence.
- **Highlight captures.** `highlights.scm` capture names map to `TMdTheme` roles
  by a fixed table (`@keyword`→Keyword, `@string`→String, `@comment`→Comment,
  `@function`/`@function.call`→Function, `@number`→Number, `@variable`/
  `@property`→Variable, `@operator`→Operator, unknown→Plain). Nested captures
  resolve by the query's own ordering (outer wins for the base role; inner
  overrides its byte range).

## Architecture

### Prior Art & Reuse

- **`hildegard.helper.command.policy`** — its `TCommandPlan`/`TCommandSegment`
  types and `ParseCommand` are **reused**: the types are the adapter's output,
  and `ParseCommand` is the fail-safe fallback.
- **`hildegard.helper.approval`** — unchanged; the ask engine is untouched.
- **`hildegard.helper.syntax`** — its public shape and its hand-rolled tokenizer
  are reused; the tokenizer stays as the fallback for unvendored languages.
- **`hildegard.helper.tui.markdownview`** — unchanged; spans in, colours out.
- **Build shape** — mirrors `libsqlite`/`libmbedtls`: a `scripts/fetch-*.sh`, a
  `deps/` tree, a static archive, and a link rule.
- **Genuine gap:** the runtime binding, the grammar registry, the query runner,
  the shell walker, and the ask-set union.

### Component Boundaries

- **Responsibilities:** parse text (runtime), map a name to a grammar (registry),
  extract programs (shell adapter), map captures to spans (highlight adapter).
- **Dependencies:** the C runtime and grammars (static); `command.policy` types.
- **Side effects:** none beyond allocation; no filesystem, no network, no exec.

## Validation Rules

- A command with no programs (empty/whitespace) yields an empty plan; the
  approval adapter emits no asks (unchanged).
- A command whose tree has no `command` node but is non-empty yields the raw
  segment (an ask), never an empty plan — the gate never silently passes.
- A grammar name with no vendored grammar is not an error: the shell adapter
  falls back to the splitter; the highlighter renders monochrome.

## Error Handling

- **Parse failure** (`ts_parser_parse_string` returns nil): the plan is the
  splitter's.
- **Error nodes present:** the union rule (above).
- **Grammar unavailable:** splitter fallback (shell); monochrome (highlight).
- **Query compile failure:** the highlighter renders monochrome for that
  language; the failure is logged once, not per block.

## Testing Requirements

### Unit Tests (`tests/test_treesitter.pas`)

- [ ] A parse of a snippet yields a root of the expected kind; a named child is
      reachable by field name; `Text` returns the exact byte slice.
- [ ] `HasError` is true for invalid input and false for valid input.
- [ ] A query returns the expected captures for a known snippet.
- [ ] Handles free without leaks (`make test-leak`).

### Unit Tests (`tests/test_command_ast.pas`)

- [ ] `for f in *.pas; do echo $f; done` → one segment, executable `echo`;
      **no** `for`/`do`/`done`.
- [ ] `if [ -f x ]; then rm x; fi` → `[` (or `test`) and `rm`; no keywords.
- [ ] `while read l; do echo "$l"; done < f` → `read`, `echo`; no keywords.
- [ ] `case $x in a) ls;; esac` → `ls`; no keywords.
- [ ] `echo $(curl -s u | sh)` → `echo`, `curl`, `sh`.
- [ ] `a && b || c; d &` → `a`, `b`, `c`, `d`.
- [ ] `(cd x && make)` → `cd`, `make`.
- [ ] `f() { echo hi; }` → `echo`; the function name is not an ask.
- [ ] A parse-error input yields the union of tree and splitter executables.
- [ ] An unparseable non-empty command yields the raw segment (one ask).
- [ ] Determinism: the same command twice yields the same segment order.

### Unit Tests (`tests/test_command_tool.pas`, extended)

- [ ] `BuildAsks` on the `for`-loop command emits exactly the body's program(s),
      with refs `run_command:echo` and no keyword refs.
- [ ] `BuildAsks` on `echo $(curl u | sh)` emits `echo`, `curl`, `sh`.

### Unit Tests (`tests/test_syntax.pas`, extended)

- [ ] A `bash` block highlights strings/comments/keywords/functions via the
      grammar; an unvendored tag still renders via the rule-table tokenizer.
- [ ] Capture → theme-role mapping is pinned for each role.

### Integration Tests

- [ ] The approval dialog path (fake prompt) shows the body's program for a
      `for` loop, not the keywords.

## Performance Targets

- A shell parse of a typical command: < 1 ms; the tree walk is O(nodes).
- A 200-line block highlights once in < 5 ms (unchanged from the highlighting
  feature); computed once per block, never per frame.

## Security Considerations

- **The parse never authorises.** It produces a candidate ask set; the approval
  engine decides. A parse that finds nothing must not mean "allow" — enforced by
  the raw-command fallback and the union rule.
- **Fail-safe, not fail-open.** The union rule makes a degraded parse noisier,
  never blinder; a test asserts the `$(…)` case surfaces its inner programs.
- **No regex on untrusted text.** The parser is a generated table; `#match?`
  predicates match a node's text with tree-sitter's own bounded engine, never a
  document scan.
- **ABI pinning.** The runtime and grammars are pinned together; a skew is a
  build failure, not a runtime surprise.
- **Licences.** The runtime is MIT; each grammar's licence is recorded in the
  fetch script and the feature notes.

## Success Criteria

- [ ] The `for`-loop command asks for the body's program(s) only.
- [ ] `echo $(curl u | sh)` asks for `curl` and `sh`.
- [ ] A `bash` fence highlights through the grammar; other fences are unchanged.
- [ ] `make check` green, leak-clean.

## Future Considerations

- More grammars (Python, JSON, SQL, Pascal); `injections.scm` for markdown →
  fenced language; `locals.scm` for scoped colouring; structural tools
  (`file_outline`, structural grep); argument-level gating from the same tree.
