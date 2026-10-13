# Approval Path Scoping

## Overview

Tool Approvals v1 matches rules on a tool `ref` plus an exact-or-prefix
parameter list. The file tools put a **workspace-relative path** in that list —
the only parameter for `read`/`write`/`edit`/`list`, and the second of two for
`file_glob`/`file_grep` (which lead with the pattern) — so the practical scoping
granularities today are "this exact operation" and "all file operations." This
feature adds **path-shaped scoping** to the approval engine:

- approve by **directory** (the operation's path is inside the directory, at
  any depth),
- approve by **file extension** (the operation's path ends in the
  extension),
- approve by **directory + extension combined** (both must match),
- and a persistable **never** (a deny rule) alongside the allow options.

Motivating example, from the operator: *allow one agent to write or edit
markdown files only under `docs/` (subdirectories included) — and nothing
else.* That single sentence describes the whole feature: with it, per-agent
capability gating becomes configuration instead of policing.

Built as a **v2 of the rule matching** with an additive store migration:
existing rules keep matching byte-for-byte; the new dimensions are opt-in
fields on the rule.

## Problem Statement

The approval engine matches `Ref` (exact string) and `Params` (exact or
prefix over the full path). Neither expresses class-of-target rules:

- "always allow writing to `docs/**`" cannot be stated — a prefix on the
  *params array* is not a path-prefix rule on a *value*, and any looser
  reading (`any` = all file operations) is far too broad.
- "allow editing `.md` files anywhere" cannot be stated at all.
- The combined form — *this directory, this extension* — is the actual
  operational need: gating different agents (headless holders, Session
  Handoff participants, future Remote Link drivers) to different project
  areas. Today each grant is per-file; a working session produces dozens of
  asks or an over-broad "always allow `file:write`".

The result is approval fatigue (operators click "always allow everything" to
get work done — the failure mode that motivated the trust-model rebuild in
the first place) or stonewalled agents.

Applying the Ponytail ladder: the engine, scopes, deny-wins precedence,
persistence, and the ask UI all exist. The genuine gap is two matchable
attributes on file-tool subjects plus the option rows that grant them. No
new scope axis, no policy language, no glob engine.

## Goals

- File-tool approval asks gain "always in this directory" and "always for
  this file type" options (and the combined "always for this type in this
  directory"), alongside the existing once/exact/any options — and a
  persistable **`never`** (a deny rule), so refusal can be expressed as a
  durable rule rather than only a one-off Escape.
- The path a directory/extension rule matches is declared by the tool **on the
  subject**, so `file_glob`/`file_grep` scope on the directory they searched, not the
  pattern. The engine stays generic and never parses the params array.
- **Each tool owns its own approval definition.** The file tool adds the path
  options to its asks; the command tool keeps its own options unchanged; there
  is no shared option builder.
- Rules express directory (workspace-relative, subtree-inclusive),
  extension, or both; combined rules require **both** to match (AND).
- Extensions apply to **write-shaped** effects by default (`file:write`,
  `file:edit`); read-shaped refs can opt in via rule, but the UI does not
  offer extension scoping for reads (asking "allow reading all `.md`" is
  almost never the intent).
- **Negative rules compose with the existing deny-wins engine**: an operator
  can allow `.md` under `docs/` while denying `.env` under any directory,
  and deny still wins.
- Per-agent gating works through the **existing scope axis**: a session-
  scoped rule binds the grant to one agent's session; a workspace-scoped
  rule grants to every holder in the workspace. No new identity machinery.
- The **command tool** adopts the dimensions across the workspace boundary: a
  command that names a path **outside** the workspace root raises its own ask
  (the subject's path is the absolute path), resolved **physically**, and an
  **exact** command grant trumps that ask while a **wildcard** grant does not.

## User Stories

- As an **operator**, I want to approve "always allow writes under `docs/`",
  so a documentation agent can work without per-file asks and still cannot
  touch source or config.
- As an **operator**, I want to allow "edits to `.md` files in `notes/` and
  subdirectories", so broad-but-bounded grants are one click, not one per
  file.
- As an **operator**, I want a **"never"** option so I can deny `.env` and
  `.key` writes everywhere while allowing markdown elsewhere, so secrets are
  excluded even from generous grants.
- As an **operator** running multiple agents, I want grants scoped to the
  asking session, so different agents get different capabilities against the
  same workspace.
- As an **operator**, I want a shell command that leaves the workspace to ask
  about *where* it goes — `cat /etc/hosts`, `cd ..` — without re-asking for a
  command I have already approved exactly.
- As an **operator** reviewing rules, I want each stored rule to read
  unambiguously ("allow file:write in docs/** for .md"), so an audit of the
  `approvals` table tells me exactly who can do what.

## Acceptance Criteria

### Functional Requirements

Matching semantics

- [ ] A directory rule matches when the operation's workspace-relative path
      is inside the directory at any depth (`docs` matches `docs/a.md` and
      `docs/x/b.md`, not `docs.md`, not `src/docs/a.md`).
- [ ] The path a rule scopes on is declared by the tool **on the subject** (the
      file tool sets the operation's workspace-relative path; `file_glob`/`file_grep` set
      the directory, not the pattern). The engine stays generic and does not
      parse the params array, so a rule saved against `[pattern, path]` still
      matches byte-for-byte.
- [ ] A directory/extension rule is a **path grant, not a per-operation one**:
      it carries no params (with `AnyParams` set), so the params do not narrow
      it — the path dimensions are what scope it.
- [ ] An extension rule matches on the final path component's extension,
      case-insensitively (`md` matches `a.MD`); a leading-dot spelling is
      normalised (`md` ≡ `.md`).
- [ ] A combined rule (directory + extension) matches only when both match.
- [ ] Matching uses the **canonical workspace-relative path** the file tools
      already compute — no second path canonicalisation is introduced; the
      engine matches on the value the tool hands it.
- [ ] Existing exact and `any` rules match exactly as before; a v1 rule and
      a v2 rule coexist in the same table and `Decide` is unchanged in
      structure (deny wins, then most-specific allow scope, then ask).
- [ ] Directory matching must not be defeated by relative tricks (`..`,
      `./`) or trailing slashes: the canonical relative path is the input, so
      the rule compares canonical to canonical; the SPEC must show the
      normalisation once and the tests must pin it.

Ask options (UI)

- [ ] A `file:write`/`file:edit` ask offers, in the existing option row
      model: `once`, `exact` (this file), **`dir`** ("always in `docs/`"),
      **`ext`** ("always `.md` files"), **`dir+ext`** ("always `.md` in
      `docs/`"), `any` (the current last resort), and **`never`** ("never
      allow file:write") — captions generated from the actual relative path so
      the dialog reads unambiguously.
- [ ] A directory ask (`file:list`/`file:glob`/`file:grep`) offers directory
      scoping on the queried directory (the subject's path), not extension
      scoping (no UI row for `ext` on read-shaped refs).
- [ ] Every persisted rule renders an unambiguous summary in the approval
      dialog (and any future rules list): ref, scope, directory, extension —
      e.g. "allow file:write · workspace · docs/ · *.md".
- [ ] The modal gains no new interaction paradigm: new options are additional
      keys in the existing option list (the row/scroll UI already supports
      more than three options; the SPEC verifies and stays inside it).

Persistence

- [ ] The store migrates additively (a v2 migration, v1 kept for a fresh
      database): `directory` and `extension` columns on `approvals` as
      `TEXT NOT NULL DEFAULT ''`; existing rows are unchanged and keep their
      meaning; no history reset (the Sessions v2 reset was a deliberate
      exception, not a pattern to repeat).
- [ ] The `UNIQUE` constraint extends to include the new columns, so
      re-approving the same grant is idempotent and two rules differing only by
      directory or extension coexist. SQLite cannot change a `UNIQUE` with
      `ALTER TABLE`, so the migration **rebuilds** the table (create-new /
      copy / drop / rename), and `Load`/`Save`/`Remove` carry the columns —
      otherwise `INSERT OR IGNORE` would silently drop the second rule.
- [ ] Session-scoped combined rules round-trip (write, read, match, remove)
      across process restart.

Engine

- [ ] `ApprovalMatches` honours the new dimensions when present: the ref
      matches, the rule's params match as today, **and** the subject's path
      parameter matches the directory (subtree-inclusive) and/or extension.
      `Decide`'s deny-wins / scope-ordering logic is untouched.
- [ ] A deny rule can carry a directory/extension too (deny `.env` writes
      anywhere) and composes per deny-wins; the ask UI's **`never`** option
      writes exactly such a deny rule.

Command boundary (the command tool)

- [ ] A path a command **names** that resolves **outside** the workspace root
      raises its own ask, with `Subject.Path` = the **absolute** path: a
      path-like argument, a redirection target, the `cwd` argument, or a
      `cd`/`pushd` target.
- [ ] Resolution is **physical** (symlinks and `..`, via the nearest existing
      ancestor so a non-existent target still compares) and the boundary is the
      workspace **root**, not the cwd.
- [ ] An **exact** command grant (`AnyParams = false`) suppresses the path ask; a
      **wildcard** grant does not. A path rule covers the path for any command;
      deny still wins.
- [ ] A path-like token the parser cannot resolve (`$VAR`, a glob) is an access
      to check, never assumed in-bounds.
- [ ] The file tools refuse a symlink that escapes the workspace (the same
      physical primitive).

### Non-Functional Requirements

- [ ] Testability: the matcher stays a pure function (rules, subject →
      decision); the new cases are table-driven tests in the existing
      approval test unit — no store or UI needed to test matching.
- [ ] Leak-clean under `make check`; no new heap retained by extended rule
      records beyond the strings they need.
- [ ] Performance: rule counts are small (tens), matching is linear over
      rules — no index needed; the SPEC states the expected rule-count
      ceiling explicitly.

## Success Metrics

### Quantitative

- The motivating flow — one agent, markdown-only writes under `docs/` — is
  grantable in one approval click and produces zero further asks for any
  `.md` write under `docs/`, and denials (clean, ledgered) for anything
  else.
- Existing approval behaviour is bit-compatible: all v1 rule tests pass
  unchanged.
- Matching cost stays linear in rule count; a 50-rule workspace matches in
  microseconds.

### Qualitative

- Per-agent capability gating is configuration, not behaviour policing.
- The approvals table reads like a capability manifest: who can write what,
  where, in which scope.
- Approval fatigue drops without trust eroding: broad grants are still
  path-shaped and auditable, and deny rules bound them.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- Must extend, not fork: `TApprovalRule` gains fields; `ApprovalMatches` gains
  the path dimensions; the file tools' `AddOption` rows gain the new cases.
  **Each tool owns its own approval definition** — the file tool and the command
  tool keep separate `AddOption` builders (they already do), and only the file
  tool gains path options; there is no shared option builder. The modal and CLI
  approval flows render whatever options a tool reports, through the existing
  ask/option mechanism.
- The file tools remain the only tools offering path scoping in v1; the
  engine is generic, so `run_command` is untouched (its params are not
  paths) and future tools can adopt the dimensions by filling them in.
- Path shapes are workspace-relative POSIX-style (the file tools' existing
  currency); Windows path shapes remain out of scope with the rest of
  Windows support.

### Non-Goals

- No glob patterns in rules (no `**/*.md` syntax): directory + extension
  covers the need with simpler, auditable semantics; globs can come later as
  a rule dimension if a real need appears, without breaking these rules.
- No new identity/agent model for "per-agent" — session scope is the agent
  identity for now (Session Handoff's lease binds a session to a holder
  process; that is the join).
- No approval *referencing* between rules (no inheritance, no rule groups).
- No automatic grant propagation across workspaces.

## Notes

- **ICE score: Impact 9, Confidence 8, Ease 7.** Directly unlocks the
  multi-agent gating story that headless holders and Remote Link imply;
  the engine change is small and testable; the modal-row growth needs the
  one SPEC verification noted above.
- Sequencing: independent of TLS; pairs naturally with Session Handoff
  (session-scoped grants are the per-agent mechanism). SPEC should land
  before or with the Handoff SPEC so the two session models agree.
- **`file:list` breadth.** `file_list` takes a `recursive` flag (`files.pas`)
  but the approval subject is `[path]` only — `recursive` is not a parameter. So
  any `file:list` grant, including a directory one, covers recursive listing of
  that directory. Adding `recursive` to the subject would make existing `[path]`
  rules stop matching (params are compared byte-for-byte), so this stays as
  documented breadth rather than a rule-shape change.
- Related: `Tool_Approvals` (the engine this extends), `Session_Handoff`
  (the consumer), `File_Tools` (the asks this changes).
- **`run_command` is now in scope** (2026-10-13). The original decision left it
  out — "its params are not paths" — which was true of the *params array* but
  missed the paths a command **names** in its text. The command tool now
  declares an **absolute** `Subject.Path` for anything outside the workspace
  root, and the physical primitive (nearest-existing-ancestor + `realpath`) also
  closes the file tools' symlink hole. The command's options are no longer
  "unchanged".
