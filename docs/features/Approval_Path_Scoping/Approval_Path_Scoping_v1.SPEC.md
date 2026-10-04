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

## Requirements

### Functional

**Engine** (`hildegard.helper.approval`)

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

**File tools** (`hildegard.helper.files`)

- [ ] `Approve` takes the operation's workspace-relative path and sets
      `Subject.Path`; `glob`/`grep` pass the searched directory, not the pattern.
- [ ] A `file:write`/`file:edit` ask offers: `once`, `exact`, `dir`, `ext`,
      `dir_ext`, `any`, `never`. A read-shaped ask (`file:read`/`file:list`/
      `file:glob`/`file:grep`) offers: `once`, `exact`, `dir`, `any`, `never`
      (no extension scoping).
- [ ] `never` persists a **blanket deny for the ref** (`Effect=aeDeny`,
      `AnyParams`, no directory/extension). Scoped deny rules are supported by
      the engine and authored outside the ask in v1.
- [ ] Each tool owns its own option builder: the file tool gains the path
      options; the command tool's options are unchanged.

**Store** (`hildegard.helper.store`, `hildegard.helper.approval.store`)

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
unit hildegard.helper.approval;

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

The ask model is unchanged (`TApprovalOption` carries a `TApprovalRule`); the
new options simply fill the new fields. Option keys:

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

### Event Contracts

- None. The matcher is pure; the ask flow is synchronous as today.

## Architecture

### Prior Art & Reuse

- **Reuse `hildegard.helper.approval`** wholesale: ref/params matching, scopes,
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

## Performance Targets

- Linear over rules; 200 rules match in microseconds. No index.

## Security Considerations

- The new dimensions only **narrow** a grant; deny still wins. The path is the
  canonical workspace-relative path the file tools already confine to the
  workspace, so a directory/extension rule cannot escape it. No glob or regex is
  introduced.

## Success Criteria

### Functional

- [ ] One approval click grants "`.md` under `docs/`" and produces no further
      asks for matching writes, and denies everything else.
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
