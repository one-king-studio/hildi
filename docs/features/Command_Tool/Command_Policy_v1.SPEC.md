# Component Specification: Command Policy

> **PARTLY SUPERSEDED.** The parser (`ParseCommand`, `TCommandPlan`,
> `TCommandSegment`, `SegmentText`) carries forward and feeds the command
> approval adapter. The policy/allow/deny/root classification, the `=`
> exact marker, and the interleaved `*` are replaced by
> [Tool Approvals](../Tool_Approvals/FEATURE.md).

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildegard.helper.command.policy` is the pure decision core of the Command Tool.
It parses a shell command line into simple-command segments, extracts each
segment's executable and literal path-like arguments, and classifies the whole
command against a policy as **allow**, **ask**, or **deny**. It never executes
anything, never reads the store, and never talks to a terminal, so it is
exhaustively testable offline.

The policy is a guardrail, not a sandbox. It reasons about literal tokens only;
it cannot see through variable expansion, command substitution, globs, `eval`,
or nested interpreters, and it reports such cases rather than guessing (see
Validation Rules).

v1 implements the POSIX syntax mode only. The `TShellSyntax` type reserves a
`cmd.exe` mode so a future Windows profile is additive.

> **Revision (v1.1):** classification is now per segment
> (`ClassifySegment`/`ClassifySegments`), and allow/deny patterns may name
> arguments (`cat /etc/os-release`, `cat *`), so approvals can be exact or
> wildcard. `TCommandPath` gained `IsRedirect` so redirection targets are always
> path-checked. See `Command_Tool_v1.SPEC.md` for the approval model.

## Requirements

### Functional

- [ ] Parse a command line into ordered segments, recording the operator that
      separates each segment.
- [ ] Tokenize each segment respecting POSIX quoting and escapes, dropping the
      quotes from the resulting tokens.
- [ ] Identify each segment's executable (`argv[0]`) and its arguments.
- [ ] Recognise redirection operators and their targets and exclude them from
      the argv.
- [ ] Collect literal path-like tokens (arguments and redirection targets) and
      classify each as relative, absolute, home (`~`), or unresolved (contains an
      unexpanded variable or substitution).
- [ ] Classify each segment independently (`ClassifySegment`), and summarise the
      plan (`ClassifyCommand`: deny if any deny, else ask if any ask, else allow).
- [ ] Match allow/deny patterns against the executable and, when a pattern names
      arguments, the argument list: `cat` (executable only, any args),
      `cat *` (executable, any args), `git * main` (interleaved `*`), and a
      leading `=` for the exact command with no wildcards (`=uname`,
      `=cat /etc/os-release`).
- [ ] Flag paths that resolve outside the configured allowed roots; redirection
      targets are always checked, while an explicit argument pattern approves the
      command's argument paths.
- [ ] Treat interpreter/indirection commands as high-risk unless explicitly
      enabled.
- [ ] Never return **allow** for an unparseable or empty command.

### Non-Functional

- [ ] Pure: no execution, no I/O, no globals, deterministic.
- [ ] Leak-clean under `make test-leak` (managed records initialised with
      `Default`).
- [ ] POSIX literals confined to the POSIX syntax mode; the classifier and the
      policy records are syntax-agnostic.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies. The implementer
> decides the bodies.

### Public API

```pascal
unit hildegard.helper.command.policy;

interface

uses
  SysUtils;

type
  { Reserved for future profiles; v1 implements ssPosix only. }
  TShellSyntax = (ssPosix, ssCmd);

  { The operator that introduces a segment in the original command line. }
  TCommandOp = (coExec, coPipe, coAnd, coOr, coSeq, coBackground);

  { How a literal path token was written, before any shell expansion. }
  TPathKind = (pkRelative, pkAbsolute, pkHome, pkUnresolved);

  TCommandArgArray = array of string;

  TCommandRedirect = record
    Operator: string;        // '>', '>>', '<', '2>', '&>'
    Target: string;          // literal target token as written
    TargetKind: TPathKind;
  end;

  TCommandPath = record
    Text: string;            // literal token as written
    Kind: TPathKind;
    IsRedirect: Boolean;     // True when the path is a redirection target
  end;

  TCommandRedirectArray = array of TCommandRedirect;
  TCommandPathArray = array of TCommandPath;

  TCommandSegment = record
    Text: string;                  // original substring for this segment
    Op: TCommandOp;                // operator that introduced the segment
    Executable: string;            // argv[0] token as written, '' if none
    Arguments: TCommandArgArray;   // argv[1..], quotes removed
    Redirects: TCommandRedirectArray;
    Paths: TCommandPathArray;      // path-like args + redirect targets
  end;

  TCommandSegmentArray = array of TCommandSegment;

  TCommandPlan = record
    Raw: string;
    Syntax: TShellSyntax;
    Segments: TCommandSegmentArray;
    ParseError: string;            // '' => fully parsed; else human-readable
  end;

  { Policy rules. Patterns are whitespace-separated words:
      - one word ('cat') = executable (token or basename), any arguments;
      - two or more = executable plus arguments, '*' matches any number of
        arguments ('cat *', 'git * main');
      - a leading '=' means the exact command, no wildcards ('=uname',
        '=cat /etc/os-release').
    '*' and '?' are wildcards elsewhere (case-sensitive). }
  TCommandPolicy = record
    Allow: TCommandArgArray;         // patterns that may run freely
    Deny: TCommandArgArray;          // patterns that never run
    AllowedRoots: TCommandArgArray;  // absolute directory prefixes for paths
    AllowInterpreters: Boolean;      // acknowledge interpreter indirection
  end;

  TCommandDecision = (cdAllow, cdAsk, cdDeny);

  TPolicyDecision = record
    Decision: TCommandDecision;
    Reason: string;                  // human-readable, safe to show the operator
    SegmentIndex: Integer;           // offending segment, or -1
  end;

  { The decision for one simple-command segment. }
  TSegmentDecision = record
    SegmentIndex: Integer;
    Decision: TCommandDecision;
    Reason: string;
  end;

  TSegmentDecisionArray = array of TSegmentDecision;

function DefaultCommandPolicy: TCommandPolicy;
function ParseCommand(const ACommand: string;
  ASyntax: TShellSyntax = ssPosix): TCommandPlan;
function ClassifySegment(const APlan: TCommandPlan; AIndex: Integer;
  const APolicy: TCommandPolicy): TSegmentDecision;
function ClassifySegments(const APlan: TCommandPlan;
  const APolicy: TCommandPolicy): TSegmentDecisionArray;
function ClassifyCommand(const APlan: TCommandPlan;
  const APolicy: TCommandPolicy): TPolicyDecision;
function IsInterpreter(const AName: string): Boolean;
{ Executable plus arguments, joined by spaces; not including redirections. }
function SegmentText(const ASegment: TCommandSegment): string;
```

### Data Contracts

- `TCommandPlan.ParseError <> ''` means the command could not be fully parsed;
  callers must not treat its `Segments` as authoritative.
- `TCommandSegment.Executable` is the token as written (may include a path, e.g.
  `/usr/bin/rm`); policy matching considers both the full token and its basename.
- `TCommandSegment.Paths` contains only literal tokens that *look* like paths
  (contain `/` or `\`, start with `~`, `.`, or `..`, or are a redirect target). It
  is a heuristic, never an assertion that no other path is touched.
- `TPathKind` values:
  - `pkRelative` - relative literal path.
  - `pkAbsolute` - begins with `/`.
  - `pkHome` - begins with `~`.
  - `pkUnresolved` - contains `$`, backtick, or `$(` and therefore cannot be
    resolved statically.

### Event Contracts

None. The unit is pure and emits nothing.

## Architecture

### Prior Art & Reuse

- `SysUtils` for `MatchesMask` (glob matching) and string handling.
- `fpjson` is **not** used here; parsing is character-level and dependency-free.
- There is no shell parser in the codebase, the RTL/FCL, or `deps/`, so the
  bounded segment/token analyser is genuinely new. It is deliberately not a
  POSIX grammar implementation (Ponytail: build only the gap).

### Component Boundaries

- **Responsibilities:** segmentation, tokenization, redirection extraction,
  literal path classification, policy matching, decision production.
- **Dependencies:** `SysUtils`.
- **Side effects:** none.

### Data Flow

1. `ParseCommand` scans the input once, tracking quote/escape state and building
   segments split on unquoted operators.
2. Each segment is tokenized into executable, arguments, and redirects.
3. Path-like tokens are classified into `PathKind`.
4. `ClassifyCommand` evaluates segments against the policy in order: deny, then
   interpreter risk, then path roots, then allow coverage.
5. A single `TPolicyDecision` is returned, naming the segment that drove it.

### Integration Patterns

- Synchronous, pure functions and value records. No threads, no ownership
  concerns beyond managed-record initialisation.

## Validation Rules

### Input

- An empty or whitespace-only command yields an empty plan; classification is
  **ask**.
- Unbalanced quotes, a dangling escape, or a redirection with no target sets
  `ParseError`; classification is **ask**.
- A token containing an unexpanded variable or substitution is `pkUnresolved`
  and can never satisfy a literal path check.

### Classification Precedence (per segment)

1. A `Deny` pattern matches the segment (any pattern form) -> **deny**.
2. The segment is an interpreter/indirection command and
   `AllowInterpreters = False` -> **ask**.
3. A redirection target is `pkAbsolute`/`pkHome`/`pkRelative` with a `..` escape
   and is not under an `AllowedRoots` entry -> **ask**.
4. An **argument** allow pattern matches the segment (`cat /etc/os-release`,
   `cat *`) -> **allow**; this approves the segment's argument paths.
5. A non-redirect path is outside the allowed roots -> **ask**.
6. An **executable-only** allow pattern matches the segment -> **allow**.
7. Otherwise -> **ask**.

`ClassifyCommand` summarises the per-segment decisions: **deny** if any segment
denies, else **ask** if any segment asks, else **allow**. `ParseError <> ''` or
zero segments is **ask**. `Deny` always takes precedence over `Allow`.

### Output Guarantees

- `Decision` is exactly one of the three values; `Reason` is non-empty for
  **ask** and **deny** and names the segment/rule where applicable.
- Classification never throws for arbitrary input.

## Error Handling

### Error Types

- **Parse:** reported via `ParseError` and mapped to **ask**; not an exception.
- **Policy:** no matching rule is an **ask**, not a failure.
- **System:** none; the unit performs no I/O.

### Error Contracts

This unit produces no `TLLMError` and no `TStoreError`; parse problems are data
(`ParseError`), not exceptions. The tool layer decides how to surface them.

## Testing Requirements

> What to test; the implementer decides how. Each item becomes a named fpcunit
> method in `tests/test_command_policy.pas`.

### Unit Tests

- [ ] `TestEmptyCommandAsks`
- [ ] `TestSingleCommandParsed`
- [ ] `TestSingleQuotesAndDoubleQuotesStripped`
- [ ] `TestEscapedOperatorIsNotOperator`
- [ ] `TestSemicolonSplitsSegments`
- [ ] `TestAndOrPipeSplitSegments`
- [ ] `TestBackgroundOperator`
- [ ] `TestLeadingAssignmentSkipped`
- [ ] `TestExecutableWithPathKeepsTokenAndBasename`
- [ ] `TestRedirectionExtractedFromArgv`
- [ ] `TestRedirectTargetIsPath`
- [ ] `TestUnbalancedQuoteAsks`
- [ ] `TestUnresolvedVariablePathIsUnresolved` (`$HOME/x`, `` `pwd`/x ``, `$(x)/y`)
- [ ] `TestHomeAndAbsoluteAndRelativePathKinds`
- [ ] `TestDenyBeatsAllow`
- [ ] `TestAllowWhenAllSegmentsAllowed`
- [ ] `TestAskWhenAnySegmentUnmatched`
- [ ] `TestDenyPatternMatchesBasename`
- [ ] `TestGlobPatternMatches`
- [ ] `TestInterpreterAsksUnlessAcknowledged`
- [ ] `TestInterpreterAllowedWhenAcknowledgedAndAllowed`
- [ ] `TestPathOutsideRootsAsks`
- [ ] `TestPathInsideRootsAllowed`
- [ ] `TestRelativeDotDotEscapeAsks`
- [ ] `TestClassifySegmentsReturnsOnePerSegment`
- [ ] `TestSegmentTextJoinsExecutableAndArgs`
- [ ] `TestExactArgPatternAllowsOnlyThatArg`
- [ ] `TestWildcardArgPatternAllowsAnyArgs`
- [ ] `TestFullArgAllowBypassesArgPathCheck`
- [ ] `TestRedirectPathStillCheckedWithFullArgAllow`
- [ ] `TestDenyArgPatternMatches`
- [ ] `TestExactPrefixAllowsOnlyNoArgs`
- [ ] `TestExactPrefixAllowsOnlyThatArg`
- [ ] `TestSingleWordPatternStillAllowsAnyArgs`
- [ ] `TestNoLeaks` (enforced by `make test-leak`)

### Integration Tests

- [ ] `TestClassifyCompoundCommandWithMixedSegments` - a realistic pipeline with
      allowed and unallowed executables decides **ask** and names the segment.

## Performance Targets

- Parsing and classification are single-pass over the command string; negligible
  relative to process startup.

## Security Considerations

- The unit is the trust-boundary classifier. It must default to **ask**, never
  **allow**, on any ambiguity.
- It must never `eval`, execute, glob-expand, or spawn a subprocess to resolve a
  token.
- Interpreter/indirection commands (`sh`, `bash`, `zsh`, `env`, `xargs`, `sudo`,
  `eval`, `command`, `exec`, `nohup`, `time`, `nice`, `python`, `perl`, `ruby`,
  `awk`, `find -exec`, ...) are a known escape hatch and are gated explicitly.
- The `Reason` string is shown to the operator and included in audit records; it
  must not contain the API key or other secrets (it never sees them).

## Success Criteria

### Functional

- [ ] All contracts implemented and pure.
- [ ] Every precedence rule above is covered by a test.
- [ ] `make check` passes.

### Quality

- [ ] No leaks; POSIX assumptions confined to the POSIX syntax mode.
- [ ] Adding `ssCmd` later requires no change to `TCommandPolicy`,
      `TPolicyDecision`, or the classification precedence.

## Future Considerations

- Implement `ssCmd` (Windows `cmd.exe`) syntax mode and its test table.
- Richer rule syntax: per-argument constraints, per-rule roots, command
  subcommand matching (e.g. `git status` vs `git push`).
- Structured command rewriting suggestions when a safer equivalent exists.
- Optional best-effort `cd` tracking across segments to refine the working
  directory used by path checks.
