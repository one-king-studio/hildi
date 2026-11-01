# Component Specification: Agent Skills (third-party)

**Related Feature:** [FEATURE.md](FEATURE.md)

**Depends on:** `HildiSkills` (`TSkillRegistry`, `TSkill`,
`ISkillToolSource`), `HildiYAML` (frontmatter), the ignore-aware walker used by
the change log, `HildiWorkspace` (root resolution).
**Depended on by:** nothing yet. This is a provider for the existing registry.

**External standard:** <https://agentskills.io/specification.md>

## Purpose

Make a directory of `SKILL.md` files a first-class skill source, so skills
written in the open Agent Skills format load through the existing registry with
no bespoke manifest and no per-skill code.

## Prior art and reuse

| Need | Existing unit | What changes |
| --- | --- | --- |
| The skill registry | `HildiSkills` `TSkillRegistry.Add` | nothing — we call it |
| Skill record | `HildiSkills` `TSkill` | gains `Name16`, `Description`, `Location`, `Metadata`, `AllowedTools`, `License`, `Compatibility` |
| YAML frontmatter | `HildiYAML` | a frontmatter splitter; the parser is reused |
| File walking | the change log's ignore-aware walker | extracted or shared, not duplicated |
| Activation | `load_skill` in `HildiSkills` | returns the body + resource listing for a file skill |

**New unit:** `HildiSkillsFiles` — scan, parse, validate, import.
**Changed unit:** `HildiSkills` — the record gains fields; `load_skill` learns to
render a file skill's body and resources.

## The data model

```pascal
{ One discovered skill directory. Everything the spec's frontmatter defines,
  carried faithfully; we interpret only what the registry needs. }
TSkillFile = record
  Name: string;           // spec `name`, validated
  Description: string;    // spec `description`, validated
  License: string;
  Compatibility: string;
  AllowedTools: string;   // parsed, DISPLAYED, never enforced
  Metadata: TStringList;  // arbitrary string->string
  Body: string;           // markdown after the closing ---, trimmed
  Dir: string;            // absolute skill directory
  SkillMDPath: string;    // absolute path to SKILL.md
  Scope: TSkillScope;     // ssProject | ssUser
  Resources: TStringArray;// relative paths found under the dir, capped
  Problem: string;        // '' when valid; the reason otherwise
end;
```

`Problem` rather than an exception: one broken skill must not stop the scan, and
the operator needs to see *which* file and *why*.

## Requirements

### Discovery

- [ ] `ScanSkills(ARoot, AUserHome: string): TSkillFileArray` walks, in order:
      `<root>/.hildi/skills`, `<root>/.agents/skills`, `~/.hildi/skills`,
      `~/.agents/skills`.
- [ ] A candidate is a subdirectory containing a file named exactly `SKILL.md`
      (case-sensitive).
- [ ] Skip `.git`, `node_modules`, and anything the ignore matcher excludes.
- [ ] Bound by `MaxScanDepth` (default 2 from a skills root) and
      `MaxScanDirs` (default 2000); on hitting a bound, stop and record a warning.
- [ ] `README.md` and loose files in a skills directory are ignored, not errors.

### Parsing

- [ ] The file **must** begin with `---` on its own line; the next line that is
      exactly `---` closes the frontmatter. No frontmatter ⇒ invalid, with a
      reason saying so.
- [ ] Parse the frontmatter with `HildiYAML`. A YAML failure marks the skill
      invalid; it does not raise.
- [ ] `name` and `description` are required and non-empty.
- [ ] Everything after the closing delimiter, trimmed, is the body.
- [ ] **Malformed-YAML fallback**: the client guide notes skills written for
      other clients often contain technically invalid YAML, most commonly an
      unquoted value containing a colon (`description: Use when: the user ...`).
      On a parse failure, retry with each offending value wrapped in quotes
      before declaring the skill invalid. This is a real-world compatibility
      concern, not politeness.

### Validation (spec rules, enforced)

- [ ] `name` is 1–64 characters.
- [ ] `name` contains only `a-z`, `0-9` and `-`.
- [ ] `name` does not start or end with `-`.
- [ ] `name` contains no `--`.
- [ ] `name` equals the parent directory name. **A mismatch is invalid.**
- [ ] `description` is 1–1024 characters.
- [ ] `compatibility`, when present, is 1–500 characters.
- [ ] An invalid skill is returned with `Problem` set and is **not** imported.

### Import

- [ ] Import one `TSkillFile` as a `TSkill` with `Key` derived from `Name`
      (snake_case for the approval namespace), instructions = body,
      `Location` = `Dir`.
- [ ] Import all valid skills from a scan into a registry.
- [ ] **Project beats user** on a name collision; the shadowed entry is recorded
      with its scope so the caller can log it.

### Activation

- [ ] **`load_skill` goes through the approval gate.** A model-initiated
      activation is an ask, like any other tool call that can change what the
      agent is able to do. The ask offers the standard approval scopes.
- [ ] Approving at **session** scope covers only this session.
- [ ] Approving at **workspace** scope covers every session in the same
      workspace: a later load from another session does not ask again.
- [ ] Approving at **global** scope covers every workspace (the scope the
      approval system already defines; we add no new one).
- [ ] `load_skill` on a file skill returns:
      `<skill_content name="...">`, the body, the skill directory, and a
      `<skill_resources>` listing.
- [ ] The resource listing is capped at `MaxListedResources` (default 50) and
      says so when it truncated.
- [ ] Resources are **listed, never read**.
- [ ] Frontmatter is **stripped** from the returned content.
- [ ] Re-activating an active skill returns a short "already loaded" notice
      rather than the body again.
- [ ] A refusal is reported to the model as a refusal, with the reason, so it can
      proceed without that skill rather than retrying blindly.

### Operator activation: `/skill` and `ctrl+=`

Skills are **not** command names. There is one command — `/skill` — that opens a
skill selector, and `ctrl+=` as a shortcut to the same selector. The command's
help text names the shortcut, so an operator who does not know it can still find
the feature.

- [ ] `/skill` opens the selector; its entry in the command list names `ctrl+=`.
- [ ] `ctrl+=` opens the same selector directly.
- [ ] Selecting a skill **side-loads** it and records a **session-scope**
      approval. Typing the selector is the approval; asking again would be asking
      the operator to confirm what they just chose.
- [ ] **No literal marker is inserted into the prompt text.** The prompt the
      operator typed is unchanged by loading a skill.
- [ ] The composer renders the loaded skills **on their own line under the user
      prompt**, each as `+<skill-name>`.
- [ ] The turn summary renders the same line, so a resumed session shows which
      skills a turn ran with.
- [ ] Unloading removes the `+<skill-name>` entry.

### The skill detail modal

The `+<skill-name>` line is clickable. Clicking an entry opens a read-only modal
for that skill, because "what did I just load into my context?" is a question the
operator cannot otherwise answer without re-reading the directory.

- [ ] A click on `+<name>` opens the modal for that skill.
- [ ] The modal shows: the **name**, the **description**, the **additional
      metadata** (`license`, `compatibility`, `allowed-tools`, `metadata` pairs,
      the skill directory), and the **instructions** in a **bounded, scrollable**
      pane.
- [ ] **The instructions pane is bounded** — a long `SKILL.md` must not push the
      CTAs off screen. It scrolls independently of the modal.
- [ ] **`ctrl+u` unloads** the skill and closes the modal; the `+<name>` entry
      disappears.
- [ ] **`esc` dismisses** the modal and changes nothing.
- [ ] The modal is read-only: it never edits a skill.
- [ ] A skill with no metadata shows the fields it has and omits the rest —
      no empty labelled rows.

Deferred: inline prompt markers (a footnote-style token that is edited atomically
and parsed on submit). The side-load model above does not need them.

### Catalog

- [ ] `StableText` gains `location` per skill, so relative references in a body
      resolve. Without it a skill saying "run `scripts/x.py`" is unfollowable.
- [ ] A skill with `Problem` set never appears in the catalog.
- [ ] A skill already approved this session is marked as such in the catalog, so
      the model knows a load will not prompt.

## Contracts & Interfaces

```pascal
{ Scan + parse + validate, without importing. Pure filesystem work. }
function ScanSkills(const ARoot: string;
  AIncludeUserScope: Boolean = True): TSkillFileArray;

{ Import the valid entries. Returns how many were added; AShadowed receives the
  qualified names that lost a collision, for the caller to log. }
function ImportSkills(const ARegistry: TSkillRegistry;
  const ASkills: TSkillFileArray): Integer;

{ The activation payload for one file skill (tags, body, dir, resources). }
function SkillContent(const ASkill: TSkillFile): string;

{ Validation only - no registry, no filesystem beyond the record. }
function ValidateSkillFile(const ASkill: TSkillFile): string;  // '' when valid
```

## Threats and how we handle them

| Threat | Handling |
| --- | --- |
| A cloned repo ships a skill that hijacks the agent | Project scope is the exposure. v1: **log every project-scope skill loaded**, so it is visible. Trust gating is deferred and named. |
| `allowed-tools` widens permissions | Parsed for display only. Approval is unaffected by a frontmatter field, always. |
| A skill body says "ignore your instructions" | Not solvable at this layer; the body is context, and the operator chose to load it. Recorded as a known limit. |
| Runaway scan in a huge tree | Depth and directory bounds, with a logged warning. |
| A malformed skill breaks startup | Per-skill `Problem`; the scan continues. |
| Skill content is silently compacted away | Exempt skill content from compaction; the tags make it identifiable. |

## Out of scope

Writing/exporting skills, installing from a URL or registry, enforcing
`allowed-tools`, subagent-forked execution, `skills-ref` parity, workspace trust.

## Notes

- **Why `Key` is not `name`.** `Key` is part of an approval ref and is used in a
  tool namespace; it must be a stable identifier we control. The spec's `name` is
  a display and lookup identity. Deriving one from the other keeps the approval
  surface ours while staying compatible.
- **Why frontmatter is stripped on activation.** We already parsed it; sending it
  again costs tokens and invites the model to treat `allowed-tools` as a grant.
- **Why the fallback parser.** Compatibility with skills authored elsewhere is
  the entire point of adopting a standard. Rejecting a file over an unquoted
  colon would defeat it.
