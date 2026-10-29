# Component Specification: Approval Path Scoping v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Extends:** [Tool Approvals v1](../Tool_Approvals/Approvals_v1.SPEC.md) (the
engine, store, and ask model) and [File Tools
v1](../File_Tools/File_Tools_v1.SPEC.md) (the asks).

## Purpose

Add path-shaped scoping to the approval engine: a rule can carry a **directory**
(subtree-inclusive), an **extension**, or both, and the ask offers them — plus a
persistable **`never`** (deny) — alongside the existing once/exact/any options.
The engine stays generic: it matches the new dimensions against a path the
**tool declares on the subject**, never parsing the params array.

Two consumers declare that path, in two coordinate spaces. The **file tools**
declare a *workspace-relative* path, scoping a grant **within** the workspace.
The **command tool** declares an *absolute* path for anything its command names
**outside** the workspace root, so a shell command cannot leave the workspace
without its own ask. The spaces never cross-match — a relative path and an
absolute one share no prefix — which keeps the file tools' confinement and the
shell's boundary independent. The path is resolved **physically** (symlinks and
`..` included), walking up to the nearest existing ancestor so a non-existent
target still compares; the same primitive closes a symlink hole in the file
tools.

## Requirements

### Functional

**Engine** (`hildi.approval`)

- [ ] `TApprovalRule` gains `Directory` and `Extension`; `TApprovalSubject`
      gains `Path`.
- [ ] `ApprovalMatches` matches a rule when the ref matches, the params match as
      today, **and** (when present) the subject's path is inside the rule's
      directory (component-wise, any depth) and/or ends in the rule's extension
      (case-insensitive).
- [ ] A directory/extension rule is a **path grant**: its params are empty with
      `AnyParams` set, so the params do not narrow it.
- [ ] `Decide` is unchanged: any matching deny wins, then the most specific
      allow scope (session → workspace → global), then ask.
- [ ] A deny rule may carry a directory/extension and composes per deny-wins.
- [ ] Normalisation: a directory strips a trailing `/` and a leading `./` and
      treats `.` as the workspace root; an extension strips a leading `.` and
      lower-cases. Matching compares canonical to canonical — the path is the
      one the tool already computes, so `..`/`./` cannot defeat it.

**File tools** (`hildi.files`)

- [ ] `Approve` takes the operation's workspace-relative path and sets
      `Subject.Path`; `file_glob`/`file_grep` pass the searched directory, not the pattern.
- [ ] A `file:write`/`file:edit` ask offers: `once`, `exact`, `dir`, `ext`,
      `dir_ext`, `any`, `never`. A read-shaped ask (`file:read`/`file:list`/
      `file:glob`/`file:grep`) offers: `once`, `exact`, `dir`, `any`, `never`
      (no extension scoping).
- [ ] `never` persists a **blanket deny for the ref** (`Effect=aeDeny`,
      `AnyParams`, no directory/extension). Scoped deny rules are supported by
      the engine and authored outside the ask in v1.
- [ ] Each tool owns its own option builder: the file tool gains the path
      options; the command tool gains the boundary options below.

**Workspace** (`hildi.workspace`)

- [ ] `PhysicalResolve`/`PhysicalContains`: resolve a path physically —
      `realpath(3)` the nearest **existing** ancestor and re-append the
      non-existent tail — and treat a path as inside only when **both** the
      lexical and the physical readings are in-bounds (`..` after a symlink is
      mode-dependent — bash's `cd` is logical by default, physical with `-P` —
      so neither reading alone is trusted).
- [ ] The file tools' `ResolveChecked` uses `PhysicalContains`, closing the
      symlink escape: a link inside the workspace pointing out is refused.

**Command tool** (`hildi.command.tool`,
`hildi.command.paths`)

- [ ] A new extractor derives the paths a command **names** from its plan: each
      segment's path-like arguments and redirection targets, the `cwd`
      argument, and each `cd`/`pushd` target — resolved against the effective
      base (the tool's `cwd`, else the workspace root), with a top-level `cd`
      moving the base for later segments (a subshell resets it). An unresolved
      token (`$VAR`, a glob) is an access to check, never assumed in-bounds.
- [ ] An access that resolves **outside** the workspace root raises its own ask,
      whose subject is the segment's command (`run_command:<bin>`) with
      `Subject.Path` set to the **absolute** path.
- [ ] Precedence — **specificity wins**: an ask whose command subject is matched
      by an allow rule with `AnyParams = false` (an **exact** command grant) is
      **suppressed**; a **wildcard** command grant (`AnyParams = true`) covers
      the command but **not** the path — "any arguments" is not "any location";
      a path rule covers the path for any command; deny-first still applies at
      whichever level matched.
- [ ] The command path ask offers `once`, `dir` (the absolute directory), `any`
      (any outside path), `never` — no `ext`, as with the read-shaped file asks.
- [ ] When a path ask fires for a command that is already allowed, the dialog
      says so ("`cat` is allowed; `/etc/hosts` is not"), so a wildcard grant is
      not misleading.

**Store** (`hildi.store`, `hildi.approval.store`)

- [ ] A v2 migration adds `directory` and `extension` (`TEXT NOT NULL DEFAULT
      ''`) and **rebuilds** `approvals` so the `UNIQUE` includes them (SQLite
      cannot alter a `UNIQUE` in place).
- [ ] `Load`/`Save`/`Remove` carry the new columns; `Save` stays `INSERT OR
      IGNORE` and `Remove` matches on the full column set, so rules differing
      only by directory/extension coexist and re-saving is idempotent.
- [ ] Existing rows migrate to `directory=''`, `extension=''` and keep their
      exact meaning.

**Modal / CLI**

- [ ] The TUI modal and the CLI prompt render whatever options a tool reports;
      no change beyond displaying more rows.

### Non-Functional

- [ ] The matcher stays a pure function (rules, subject → decision); the new
      cases are table-driven tests needing no store or UI.
- [ ] Matching is linear over rules; the SPEC's ceiling is 200 rules per
      workspace (tens expected).
- [ ] Leak-clean under `make test-leak`.
- [ ] Portability: macOS and Linux, FPC 3.3.1, `{$mode delphi}`.

## Contracts & Interfaces

> Contracts are Pascal type declarations. No method bodies.

### Public API

```pascal
unit hildi.approval;

type
  TApprovalRule = record
    Effect: TApprovalEffect;
    Scope: TApprovalScope;
    WorkspaceId: Integer;
    SessionId: string;
    Ref: string;
    Params: TApprovalParams;
    AnyParams: Boolean;
    Directory: string;   { workspace-relative, subtree-inclusive; '' = any }
    Extension: string;   { normalised: no leading dot, lower-case; '' = any }
  end;

  TApprovalSubject = record
    Ref: string;
    Params: TApprovalParams;
    Path: string;        { the operation's workspace-relative path; '' = none }
  end;

{ Normalise a directory (strip a trailing '/', a leading './'; '.' → ''). }
function NormalizeDirectory(const ADirectory: string): string;
{ Normalise an extension (strip a leading '.'; lower-case). }
function NormalizeExtension(const AExtension: string): string;
{ True when APath is ADirectory or below it, component-wise. '' dir = any. }
function PathInDirectory(const APath, ADirectory: string): Boolean;
{ True when APath's final component ends in '.' + AExtension. '' ext = any. }
function PathHasExtension(const APath, AExtension: string): Boolean;
```

The ask model is unchanged in shape (`TApprovalOption` carries a
`TApprovalRule`); the new options fill the new fields. One field is added, for
the command boundary: `TApprovalAsk` gains `Covers: TApprovalSubject` +
`HasCovers: Boolean`, and an ask with `HasCovers` is **skipped** when `Covers`
is matched by an allow rule with `AnyParams = false` (an exact command grant
trumps the path gate). Two units carry the boundary:

```pascal
unit hildi.workspace;   // extended

  { Resolve APath (relative allowed) against ABase ('' => the root), physically:
    the nearest existing ancestor is realpath(3)-resolved and the non-existent
    tail re-appended. Never raises; a resolution failure yields the lexical path. }
  function PhysicalResolve(const APath: string; const ABase: string = ''): string;
  { True only when BOTH the lexical and the physical readings are in-bounds. }
  function PhysicalContains(const APath: string; const ABase: string = ''): Boolean;
```

```pascal
unit hildi.command.paths;   // NEW

type
  TPathAccess = record
    Token: string;       // as written
    Resolved: string;    // physical absolute
    Exists: Boolean;     // the full path exists
    Inside: Boolean;     // physically under the workspace root
    Segment: Integer;    // index into the plan's segments
  end;
  TPathAccessArray = array of TPathAccess;

{ Every path-like token in the plan, resolved against ACwd with a top-level `cd`
  tracked; `OutsideAccesses` filters to the ones outside the root. Both are
  ordered: segment order, then token order. }
function PathAccesses(const APlan: TCommandPlan; const AWorkspace: TWorkspace;
  const ACwd: string): TPathAccessArray;
function OutsideAccesses(const APlan: TCommandPlan; const AWorkspace: TWorkspace;
  const ACwd: string): TPathAccessArray;
```

Option keys:

| Key | Effect | Params | Directory / Extension |
| --- | --- | --- | --- |
| `once` | allow, not persisted | — | — |
| `exact` | allow | the operation's params | — |
| `dir` | allow | empty (`AnyParams`) | directory of the path |
| `ext` | allow | empty (`AnyParams`) | extension of the path |
| `dir_ext` | allow | empty (`AnyParams`) | both |
| `any` | allow | empty (`AnyParams`) | — |
| `never` | **deny** | empty (`AnyParams`) | — |

### Data Contracts

- **Match shape.** `ApprovalMatches` is: `Ref` equal, params match (exact, or
  prefix when `AnyParams`), and — when `Directory`/`Extension` are non-empty —
  the subject's `Path` satisfies them. A rule with no directory/extension
  behaves exactly as v1.
- **Directory.** Component-wise prefix: `docs` matches `docs/a.md` and
  `docs/x/b.md`; not `docs.md`, not `src/docs/a.md`. `''` matches any path.
- **Extension.** The final component's extension, compared lower-cased with no
  leading dot: `md` matches `a.MD` and `.md` normalises to `md`. `''` matches
  any path.
- **Migration.** The v2 migration rebuilds `approvals`:

  ```sql
  CREATE TABLE approvals_new ( …existing columns…,
    directory TEXT NOT NULL DEFAULT '', extension TEXT NOT NULL DEFAULT '',
    UNIQUE (effect, scope, workspace_id, session_id, ref, params, any_params,
            directory, extension));
  INSERT INTO approvals_new (…, directory, extension, …)
    SELECT …, '', '', … FROM approvals;
  DROP TABLE approvals;
  ALTER TABLE approvals_new RENAME TO approvals;
  CREATE INDEX idx_approvals_scope ON approvals (scope, workspace_id, session_id);
  ```

- **Coordinate spaces.** A file-tool subject's `Path` is workspace-relative; a
  command subject's is absolute (outside the root). A rule stores whichever
  space the operator granted; a rule in one space never matches a subject in the
  other, because a relative path and an absolute one share no prefix.
- **Boundary suppression.** In `Resolve`, after the deny-first scan and before
  prompting: for each ask with `HasCovers`, if `Decide(Rules, Covers)` is an
  allow with `AnyParams = false`, skip the ask. A deny on `Covers` still denies.
- **Effective base.** The tool's `cwd` argument, else the workspace root. A
  top-level `cd X` moves the base for later segments; a `( … )` subshell's `cd`
  does not leak out. `~` expands to the home directory (outside, so it asks).
- **Unresolved tokens.** A path-like token the parser marks unresolved (`$VAR`,
  a glob) is an access to check, never assumed in-bounds.

### Event Contracts

- None. The matcher is pure; the ask flow is synchronous as today.

## Architecture

### Prior Art & Reuse

- **Reuse `hildi.approval`** wholesale: ref/params matching, scopes,
  deny-wins, the ask/option model, and the store interface. This adds two rule
  fields, one subject field, and the option rows.
- **Reuse `TSqliteStore`'s migration framework** (`DefaultMigrations`,
  `PRAGMA user_version`): a v2 migration is the additive path, with v1 kept for
  a fresh database.
- **Reuse the modal's option model**: it already sizes to `Length(Options)`,
  numbers the rows, and selects by digit or arrow, so it takes more options
  without a new interaction.
- No glob engine and no path canonicalisation are added: the file tools already
  hand the engine a canonical workspace-relative path.

The gap: two matchable rule fields, one subject field, the option rows, and the
table rebuild.

### Component Boundaries

- **Responsibilities:** match the new dimensions; persist them; offer them.
- **Dependencies:** the engine stays generic (no knowledge of refs or paths); the
  file tool declares the path; the store persists the columns.
- **Side effects:** none beyond the existing store writes.

### Data Flow

1. A file tool computes its canonical relative path (as today) and calls
   `Approve`, which sets `Subject.Path` and builds the options.
2. The service matches rules via `ApprovalMatches`; the new dimensions are
   evaluated against `Subject.Path`.
3. The chosen option's rule is persisted (or, for `once`, not).
4. `Load` reconstructs rules including the new columns.

### Integration Patterns

- Synchronous and single-threaded, like the rest of the harness.
- Ownership: unchanged; the service owns nothing new.

## Validation Rules

### Input

- `Directory`/`Extension` are normalised on save and on match; an empty value
  means "any".
- A rule with no directory/extension matches exactly as v1.
- `Subject.Path` is the tool's canonical relative path; `''` means the rule's
  path dimensions cannot match (a path rule never matches a pathless subject).

### Output Guarantees

- A v1 rule and a v2 rule coexist; existing rules match byte-for-byte.
- Re-saving an identical grant is idempotent; rules differing only by
  directory/extension coexist.

## Error Handling

- None surfaced beyond the existing store errors; an invalid directory/extension
  normalises to a well-defined value rather than erroring.

## Testing Requirements

### Unit Tests (`tests/test_approval.pas`)

- [ ] `TestDirectoryMatchesSubtree` (`docs` matches `docs/a.md`, `docs/x/b.md`)
- [ ] `TestDirectoryDoesNotMatchPrefixSibling` (not `docs.md`, not
      `src/docs/a.md`)
- [ ] `TestExtensionMatchesCaseInsensitively` (`md` matches `a.MD`)
- [ ] `TestExtensionNormalisesLeadingDot`
- [ ] `TestDirectoryAndExtensionBothRequired`
- [ ] `TestEmptyDirectoryOrExtensionMatchesAny`
- [ ] `TestV1RuleMatchesUnchanged` (no new fields → identical decisions)
- [ ] `TestScopedDenyWins` (a deny with an extension beats a broad allow)
- [ ] `TestPathlessSubjectNeverMatchesPathRule`

### Unit Tests (`tests/test_file_tool.pas`)

- [ ] `TestWriteAskOffersPathOptions` (once/exact/dir/ext/dir_ext/any/never)
- [ ] `TestReadAskOmitsExtensionScoping`
- [ ] `TestGlobAskScopesOnTheDirectoryNotThePattern`
- [ ] `TestNeverPersistsADenyRule`

### Unit Tests (`tests/test_store.pas`)

- [ ] `TestApprovalsMigrationRebuildsWithPathColumns`
- [ ] `TestPathRulesRoundTrip` (write, read, match, remove)
- [ ] `TestRulesDifferingOnlyByPathCoexist`

### Unit Tests (`tests/test_tui_approvalmodal.pas`)

- [ ] `TestModalRendersManyOptions` (the seven-option ask fits and selects)

### Unit Tests (`tests/test_workspace.pas`)

- [ ] `TestPhysicalContainsRefusesOutside`, `TestPhysicalContainsAcceptsInside`
- [ ] `TestSymlinkOutOfTheWorkspaceIsRefused` (the lexical check says inside —
      the fix)
- [ ] `TestNonExistentTailUsesTheNearestExistingAncestor`
- [ ] `TestDotDotThroughASymlinkIsConservative`
- [ ] `TestBoundarySiblingIsNotUnder` (`<root>-evil`)

### Unit Tests (`tests/test_command_paths.pas`)

- [ ] `TestCdParentIsAnOutsideAccess`, `TestAbsoluteArgumentIsAnOutsideAccess`
- [ ] `TestInBoundsArgumentIsSilent`
- [ ] `TestUnresolvedTokenIsChecked`
- [ ] `TestCdMovesTheBaseForLaterSegments`; `TestSubshellCdDoesNotLeak`
- [ ] `TestCwdArgumentIsAnAccess`
- [ ] `TestOrderAndDedupAreDeterministic`

### Unit Tests (`tests/test_approval.pas`, extended)

- [ ] `TestExactCommandGrantSuppressesThePathAsk`
- [ ] `TestWildcardCommandGrantDoesNotSuppressIt`
- [ ] `TestPathDenyBeatsWildcardCommandAllow`
- [ ] `TestAbsolutePathRuleMatchesByDirectory`

### Unit Tests (`tests/test_command_tool.pas`, extended)

- [ ] `TestWildcardAllowedCatStillAsksAboutThePath`
- [ ] `TestExactlyApprovedCatDoesNotAskAboutThePath`
- [ ] `TestUnknownCommandAsksForBoth`

## Performance Targets

- Linear over rules; 200 rules match in microseconds. No index.

## Security Considerations

- The new dimensions only **narrow** a grant; deny still wins. The file tools'
  path is the canonical workspace-relative path they already confine to the
  workspace, so a directory/extension rule cannot escape it. No glob or regex is
  introduced.
- **The command boundary is a guardrail, not a sandbox.** It sees literal
  path-like tokens, `cwd`, `cd` targets, and non-existent paths (via their
  nearest existing ancestor), with symlinks resolved. It cannot see a path a
  program derives at runtime (`python -c 'open("/etc/passwd")'`, `x=/etc; cat
  $x`), a path built from a non-path argument (`git -C`, `tar -C`), or implicit
  reads (config, libraries, `/tmp` — deliberately **not** flagged, which is what
  keeps the dialog quiet). It raises the cost of an accident and makes an escape
  visible; it does not confine a determined command.
- **No path ask does not mean "safe".** It means nothing outside was *named*;
  the command gate still applies.
- **Fail-safe.** An imperfect parse unions the tree's asks with the conservative
  splitter's, and an unparseable non-empty command asks for the raw command — a
  degraded parse is noisier, never blinder.

## Success Criteria

### Functional

- [ ] One approval click grants "`.md` under `docs/`" and produces no further
      asks for matching writes, and denies everything else.
- [ ] `cat /etc/hosts` asks about `/etc/hosts`, not only `cat`.
- [ ] A symlink inside the workspace pointing out is refused by the file tools.
- [ ] An **exact** `cat /etc/hosts` grant means the operator is never asked
      twice; a **wildcard** `cat` grant still asks about `/etc/shadow`.
- [ ] Existing approval behaviour is bit-compatible.
- [ ] `make check` passes.

### Quality

- [ ] No memory leaks.
- [ ] Adding a tool's path options is a local change in that tool.

## Future Considerations

- A scoped `never` (deny by directory/extension) in the ask, and a rules list to
  author scoped denies directly.
- A glob rule dimension, if a real need appears.
- Other tools adopting path scoping by setting `Subject.Path`.
- Tracking `cd` inside subshells and functions; `pushd`/`popd`.
- Argument-aware gating for known programs (`git -C`, `tar -C`, `find`).
- Fold into the tree-sitter plan when it lands (a better path extraction).
