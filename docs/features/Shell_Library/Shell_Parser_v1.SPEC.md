# Component Specification: Shell Parser v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** nothing. Pure Pascal in `src/shell/` (`shell.lexer`,
`shell.words`, `shell.parser`, `shell.ast`).

## Purpose

Turn a shell source string into the library's AST, or into a precise error. The
parser owns the **v1 subset** documented below; anything outside it is a
reported parse error, never a guess. It uses no regex and no backtracking: a
hand-written lexer plus recursive descent.

## Requirements

### Functional

**Lexer** (`shell.lexer`)

- [ ] Tokens: `WORD`, `NEWLINE`, `EOF`, and the operators
      `| |& || && ; ;; ;& ;;& & ( ) { } < > >> <> <& >& << <<- <<<`.
- [ ] **Quoting modes**: unquoted, single-quoted (literal, no escapes),
      double-quoted (expansions allowed, `\` escapes `$`, `` ` ``, `"`, `\`,
      newline), and `$'…'` (ANSI-C escapes; v2 if deferred, but the token must
      not be mis-lexed).
- [ ] **Line continuation**: `\` + newline is removed, not a token.
- [ ] **Comments**: `#` starts a comment only at the start of a word (unquoted).
- [ ] **Redirection recognition**: an optional leading fd (`2>`), the operator,
      and the target word; `&>`/`&>>` map to fd 1 + fd 2.
- [ ] **Here-doc deferral**: on `<<`/`<<-`, record the delimiter and the strip
      flag; the body is collected when the next newline is reached and attached
      to the pending redirect. An unclosed here-doc is a parse error with the
      delimiter named.
- [ ] **Position tracking**: every token carries byte offset, line, and column;
      errors report them.

**Words** (`shell.words`)

- [ ] A word is a list of parts: literal, single-quoted, double-quoted,
      variable (`$VAR`, `${VAR}` basic), special (`$?`, `$#`, `$@`, `$*`, `$1`),
      tilde (`~`, `~/…`), and glob (`*`, `?`, `[…]`).
- [ ] Adjacent parts concatenate within one word (`a"b"c` is one word).
- [ ] **v1 does not expand** inside the parser: the AST records the parts; the
      interpreter expands. The parser must not silently drop an unsupported
      expansion.
- [ ] A word containing an unsupported construct (`${VAR:-x}`, `$((…))`,
      `$(…)`, backticks, process substitution, brace expansion) is a **parse
      error** in v1 naming the construct — *unless* the construct is inside a
      context the parser defers (there is none in v1).

**Parser** (`shell.parser`)

- [ ] **Simple command**: assignment prefixes (`NAME=value`), words, and
      redirects, in any order the subset permits.
- [ ] **Pipeline**: `|` and `|&`, optional leading `!`.
- [ ] **And-or list**: `&&` and `||`, left-associative.
- [ ] **Statement list**: `;`, `&`, and newlines; `&` is parsed (and run
      sequentially by the interpreter).
- [ ] **Compound**: `if/elif/else/fi`, `for NAME [in WORDS]; do … done`,
      `for ((…))` (v2), `while`/`until`, `case WORD in PATTERN) … ;; esac`,
      `{ …; }`, `( … )`, and function definitions (`name() …`, `function name …`).
- [ ] **Reserved words** are recognised only in command position; elsewhere they
      are ordinary words (`echo if`).
- [ ] **Precedence**: `;`/`&` list < `&&`/`||` < `|`/`|&` < a command. The AST
      encodes it, so the interpreter never re-derives it.

### Non-Functional

- [ ] **No regex, no backtracking.** A lexer with bounded lookahead and
      recursive descent. No input can cause super-linear behaviour.
- [ ] **Deterministic** and **pure**: the same bytes yield the same AST or the
      same error. No I/O, no environment, no globals.
- [ ] **Bounded**: input size is capped (`MaxSourceBytes`); nesting depth is
      capped (`MaxNestingDepth`) with a clear error, mirroring the parser's
      discipline elsewhere.
- [ ] **Leak-clean**; no exceptions escape (errors are values).

## Contracts & Interfaces

```pascal
unit shell.ast;

type
  TWordPartKind = (wpLiteral, wpSingleQuote, wpDoubleQuote, wpVariable,
    wpSpecial, wpTilde, wpGlob);
  TWordPart = record
    Kind: TWordPartKind;
    Text: string;        // the literal/name text, unquoted where applicable
    Quoted: Boolean;     // the part was quoted (affects glob/splitting)
  end;
  TWordPartArray = array of TWordPart;
  TWord = record
    Parts: TWordPartArray;
  end;

  TRedirectOp = (roRead, roWrite, roAppend, roReadWrite, roDupIn, roDupOut,
    roHeredoc, roHeredocStrip, roHereString);
  TRedirect = record
    FD: Integer;         // the target fd; -1 = default for the op
    Op: TRedirectOp;
    Target: TWord;
    Body: TWord;         // the here-doc body (empty for other ops)
  end;

  TAssignment = record
    Name: string;
    Value: TWord;
  end;

  TCommandKind = (ckSimple, ckIf, ckFor, ckWhile, ckUntil, ckCase,
    ckGroup, ckSubshell, ckFunction);
  TCommand = record
    Kind: TCommandKind;
    Assignments: TAssignmentArray;
    Words: TWordArray;          // ckSimple: argv
    Redirects: TRedirectArray;
    Body: TStatement;           // compound bodies
    …
  end;

  TPipeline = record
    Commands: TCommandArray;
    Negated: Boolean;
  end;
  TAndOr = record
    Pipelines: TPipelineArray;
    Ops: array of TAndOrOp;     // aoAnd, aoOr
  end;
  TStatement = record
    Items: TAndOrArray;
    Ops: array of TStatementOp; // soSeq, soBackground
  end;
  TScript = record
    Statements: TStatementArray;
  end;
```

```pascal
unit shell.parser;

type
  TParseError = record
    Offset, Line, Column: Integer;
    Message: string;
  end;

{ Parse ASource into AScript. Returns False and fills AError on the first
  syntax error; nothing is executed and no partial AST is returned. }
function ParseScript(const ASource: string; out AScript: TScript;
  out AError: TParseError): Boolean;
```

### Data Contracts

- **Precedence.** `TStatement` (items joined by `;`/`&`/newline) contains
  `TAndOr` (pipelines joined by `&&`/`||`) contains `TPipeline` (commands
  joined by `|`/`|&`) contains `TCommand`.
- **Reserved words.** `if then elif else fi for in do done while until case
  esac function { } !` — recognised only when a command is expected.
- **Subset gate.** Each unsupported construct gets a distinct message naming it
  (`${…} operator`, `$((…))`, `$(…)`, backticks, process substitution, brace
  expansion, `for ((…))`), so the consumer can fall back knowingly.

## Validation Rules

- Empty/whitespace-only source parses to an empty `TScript`.
- A here-doc without a terminator is an error at the redirect's position, naming
  the delimiter.
- An unclosed quote/`$(`/`{` is an error at the opening position.
- Nesting beyond `MaxNestingDepth` is an error, not a crash.
- A word with an unsupported expansion is an error naming the construct.

## Error Handling

- Errors are **values** (`TParseError`), never exceptions.
- The parser stops at the first error; the caller gets no partial AST.

## Testing Requirements

### Unit Tests (`tests/test_shell_lexer.pas`)

- [ ] Token streams for: operators, quoting modes, escapes, comments, line
      continuation, fd redirects, `&>`/`&>>`.
- [ ] A `#` inside a word is literal; `\#` is literal; `#` after whitespace is a
      comment.
- [ ] Positions: each token's line/column.

### Unit Tests (`tests/test_shell_parser.pas`)

- [ ] Golden ASTs: simple command; assignment prefix; pipeline; `&&`/`||`;
      `;`/`&`; `if`; `for`; `while`/`until`; `case`; group; subshell; function.
- [ ] Precedence: `a && b | c ; d` groups as `(a && (b|c)) ; d`.
- [ ] Reserved words in command position vs as arguments.
- [ ] Here-docs: `<<EOF`, `<<-EOF` (tabs stripped), multiple in one command,
      unterminated (error).
- [ ] Quotes: `a"b"c`, `'a b'`, `"a $V b"`, `$'a\nb'`.
- [ ] The subset gate: each unsupported construct errors with its name.
- [ ] Nesting depth limit.

### Corpus Tests (`tests/test_shell_corpus.pas`)

- [ ] Parse every command in the recorded corpus (the ledger's `run_command`
      arguments) and assert: no error for the supported subset; the error
      construct named for the rest; the counts match the recorded baseline.
- [ ] The corpus is a fixture file, so the test is hermetic.

### Differential Tests (`tests/test_shell_differential.pas`, opt-in)

- [ ] For a table of scripts, run `/bin/bash -c` and the interpreter (once it
      exists) and compare stdout/stderr/exit. Fixtures are recorded so
      `make check` does not need bash.

## Performance Targets

- Parse a typical command (< 1 KiB) in well under a millisecond; the corpus of
  ~6k commands in a few seconds. Linear in input size.

## Security Considerations

- **No regex/backtracking**; bounded lookahead and depth.
- **No evaluation** during parse: words are recorded, not expanded, and nothing
  is executed.
- **No I/O**: a pure function over a string, so it is safe to run on untrusted
  input.
- The parser is **not** a validator: a successful parse means "we understand the
  shape", not "the script is safe". The gate and the FS seam are the boundary.

## Success Criteria

- [ ] The v1 subset parses with golden ASTs.
- [ ] The corpus parses with zero errors inside the subset, and every
      unsupported construct is named.
- [ ] No exception escapes; nesting and size are bounded.
- [ ] The library isolation test passes (no harness dependency).
- [ ] `make check` green.

## Future Considerations

- v2: `${…}` operators, `$((…))`, `$(…)`/backticks, process substitution,
  brace expansion, `$'…'` if deferred.
- A serializer (AST → shell) for round-trip tests and transforms.
- A fuzz corpus and a property test (`parse` never raises).
