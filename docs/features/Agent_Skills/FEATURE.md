# Agent Skills (third-party)

**Status: Proposed.**

Formal support for the open [Agent Skills](https://agentskills.io/specification.md)
format: a directory containing `SKILL.md` (YAML frontmatter + Markdown body) plus
optional `scripts/`, `references/` and `assets/`. Skills authored for any
compliant client become loadable here, and skills authored here are portable to
them.

## What already exists, and what does not

[Skills v1](../Skills/FEATURE.md) built the **mechanism**: `TSkillRegistry` is an
`IToolProvider`, a manifest is always in the wrapped prompt, and `load_skill(name)`
activates instructions and (optionally) tools. That is real and shipped.

**Nothing reads a file.** Verified: `grep -rn "SKILL.md" src/` returns nothing. A
skill exists only because some code called `TSkillRegistry.Add` with a `TSkill`
record. So the registry can serve MCP servers and hand-registered capabilities,
but it cannot serve a single skill written to disk in the standard format.

That is the whole gap this feature closes: **a filesystem provider for the
registry that speaks the Agent Skills format.**

## Why bother

| Reason | Detail |
| --- | --- |
| **Portability** | A skill authored for another client works here unchanged, and vice versa. The format is the interface; no bespoke manifest. |
| **Progressive disclosure is already ours** | The registry's three tiers (description always, body on load, tools on activation) map exactly onto the spec's catalog → instructions → resources. We are not adding a model, we are feeding the one we have. |
| **Skills are version-controlled prose** | A skill is a folder in the repo, reviewed like code. It is the most natural way to ship procedural knowledge without a plugin system. |
| **Low marginal cost** | The seam exists. This adds a scanner, a `SKILL.md` parser, and a source that yields instructions — not a second registry. |

## The two models, reconciled

Our `TSkill` predates the spec. Where they differ:

| Concept | Agent Skills spec | `TSkill` today | Resolution |
| --- | --- | --- | --- |
| Identity | `name` (1–64 chars, `a-z0-9-`, no leading/trailing/double hyphen) | `Key` (snake_case, part of the approval ref) | **Keep `Key` as the approval identity; carry `name` verbatim as the spec's.** They usually coincide; when they do not, `Key` is derived and the original is preserved. |
| What it does | `description` (1–1024 chars, "what + when") | `Description` **and** `WhenToUse` | The spec folds both into `description`. Import: `Description` = the whole string, `WhenToUse` empty. Export: join them. |
| Body | Markdown after frontmatter | `Instructions` | Direct map. |
| Extras | `license`, `compatibility`, `metadata`, `allowed-tools` | none | Carried, not interpreted (see below). |
| Lifetime | The conversation | Idle TTL | Keep ours. The spec is silent on eviction. |

**`allowed-tools` is *not* our approval system.** The spec marks it experimental,
and it is a *pre-approval allowlist*, not a capability grant. Honouring it
silently would let a downloaded skill widen its own permissions — exactly the
thing approval exists to prevent. We parse and **display** it; we do not enforce
it. If we ever do, it must be an operator decision recorded somewhere, not a
frontmatter field.

## Discovery

Scan, in order, per scope — later scans do not override earlier ones within a
scope, and project beats user:

| Scope | Path |
| --- | --- |
| Project | `<workspace>/.hildi/skills/` |
| Project | `<workspace>/.agents/skills/` (cross-client convention) |
| User | `~/.hildi/skills/` |
| User | `~/.agents/skills/` (cross-client convention) |

Within each directory: **subdirectories containing a file named exactly
`SKILL.md`**. Skip `.git/`, `node_modules/`, and honour `.gitignore` (we already
have an ignore-aware walker for the change log). Bound the scan — max depth and
max directories — so a large tree cannot stall startup.

**Name collisions**: project overrides user, deterministically, and the shadowed
skill is logged. Silent shadowing is how an operator loses an hour.

**Trust**: project-level skills come from the repository, which may be a freshly
cloned stranger. Spec recommends gating them. We have no workspace-trust concept
today; v1 documents this as a known exposure rather than inventing one.

## Progressive disclosure, mapped

| Tier | Spec | Here |
| --- | --- | --- |
| 1. Catalog | `name` + `description` (+ `location`) | `StableText` — already the system prompt |
| 2. Instructions | `SKILL.md` body | `load_skill` result |
| 3. Resources | `scripts/`, `references/`, `assets/` | listed, read on demand via `file_read` |

Tier 3 is the one we get for free and should exploit: a skill's instructions can
say "run `scripts/extract.py`", and the model has a file tool and the skill's
directory path. **The catalog must carry `location`** so relative references
resolve — we do not emit it today.

## What the model receives on activation

The spec allows full-file or body-only. We strip frontmatter (we already parsed
it; re-sending it wastes tokens and invites the model to treat `allowed-tools` as
a grant) and wrap in identifying tags:

```
<skill_content name="pdf-processing">
[body]

Skill directory: /abs/path/to/pdf-processing
Relative paths in this skill are relative to the skill directory.

<skill_resources>
  <file>scripts/extract.py</file>
  <file>references/REFERENCE.md</file>
</skill_resources>
</skill_content>
```

The tags matter for two reasons beyond readability: compaction can identify skill
content, and a resumed session can tell skill text from conversation.

## Requirements

### Functional

- [ ] Scan the four skill directories; discover every subdirectory containing
      `SKILL.md`; ignore `.git/`, `node_modules/`, and gitignored paths.
- [ ] Bound the scan by depth and directory count; log when a bound truncates.
- [ ] Parse `SKILL.md` frontmatter (`name`, `description` required; `license`,
      `compatibility`, `metadata`, `allowed-tools` optional).
- [ ] **Validate `name`** per spec: 1–64 chars, `a-z0-9-` only, no leading or
      trailing hyphen, no consecutive hyphens, and it must match the parent
      directory name.
- [ ] A malformed skill is **skipped with a warning naming the file and the
      reason** — never silently, never fatal.
- [ ] Import a discovered skill into the registry as an unloaded entry with a
      `location`.
- [ ] `load_skill` on a file skill returns the body, frontmatter stripped, in
      `<skill_content>` tags with the directory and a resource listing.
- [ ] List bundled resources (capped) without reading them.
- [ ] Project-level skills override user-level ones on name collision; the
      shadowed entry is logged.
- [ ] Operator can activate explicitly: `/skill-name` adds the skill to context
      without the model having to decide.
- [ ] Activating an already-active skill does not re-inject its body.
- [ ] `allowed-tools` is parsed and surfaced but **never** used to widen
      approval.

### Non-Functional

- [ ] Zero prompt cost for unloaded skills beyond `name` + `description`.
- [ ] Discovery is bounded: startup does not read any skill body.
- [ ] Skill content is exempt from context compaction.
- [ ] No new dependency; the YAML parser we have (`HildiYAML`) is the one used.
- [ ] `make check` green, leak-clean.

## Out of scope for v1

- **Writing skills** (exporting a registry entry to a `SKILL.md` tree).
- **Installing** from a registry or URL. Discovery is local filesystem only.
- **Enforcing `allowed-tools`.**
- **Running a skill in a subagent.** The spec calls this optional and advanced.
- **Workspace trust gating.** Documented as an exposure, not solved.
- **`skills-ref` validation parity.** We implement the rules the spec states; we
  do not shell out to the reference validator.

## Related

- [Skills](../Skills/FEATURE.md) — the mechanism this feeds.
- [Lazy MCP](../Lazy_MCP/FEATURE.md) — the other `ISkillToolSource`.
- [Context Budget](../Context_Budget/FEATURE.md) — the compaction this must
  survive.
- [File Tools](../File_Tools/FEATURE.md) — how the model reads tier-3 resources.
- Spec: <https://agentskills.io/specification.md> ·
  Client guide: <https://agentskills.io/client-implementation/adding-skills-support.md>
