# Task Plan: Agent Skills (third-party) v1

**Spec:** [Agent_Skills_v1.SPEC.md](Agent_Skills_v1.SPEC.md)

Work TDD-first: each phase adds its tests before its implementation and runs
`make check` before moving on. Phases 1–3 are pure and need no loop.

## Phase 1 — frontmatter parsing (pure)

- [ ] **Test**: `---`-delimited frontmatter splits into fields and body.
- [ ] **Test**: a file with no frontmatter is invalid and says so.
- [ ] **Test**: an unclosed frontmatter block is invalid, not a hang.
- [ ] **Test**: an unquoted value containing a colon parses via the fallback
      (`description: Use when: the user asks`) — this is a real-world case, not a
      hypothetical.
- [ ] **Implement** `SplitFrontmatter` and `ParseSkillFile` in `HildiSkillsFiles`.
- [ ] `make check` green.

## Phase 2 — validation (pure)

- [ ] **Test**: each `name` rule fails independently — too long, uppercase,
      leading hyphen, trailing hyphen, double hyphen, empty.
- [ ] **Test**: `name` not matching the parent directory is invalid.
- [ ] **Test**: `description` over 1024 chars is invalid.
- [ ] **Test**: `compatibility` over 500 chars is invalid.
- [ ] **Test**: a valid file yields `Problem = ''`.
- [ ] **Implement** `ValidateSkillFile`.
- [ ] `make check` green.

## Phase 3 — discovery (filesystem)

- [ ] **Test**: a subdirectory containing `SKILL.md` is found.
- [ ] **Test**: a directory without `SKILL.md` is ignored, not an error.
- [ ] **Test**: `.git/` and `node_modules/` are skipped.
- [ ] **Test**: the depth and directory bounds stop the scan and report it.
- [ ] **Test**: an invalid skill appears with `Problem` set and does not abort
      the rest of the scan.
- [ ] **Implement** `ScanSkills` over the four scope paths.
- [ ] `make check` green.

## Phase 4 — import into the registry

- [ ] **Test**: a valid `TSkillFile` imports as an unloaded `TSkill`.
- [ ] **Test**: `Key` is derived as snake_case and is stable across scans.
- [ ] **Test**: project scope beats user scope on a name collision, and the
      shadowed one is reported.
- [ ] **Test**: invalid skills are not imported.
- [ ] **Implement** `ImportSkills`.
- [ ] `make check` green.

## Phase 5 — activation

- [ ] **Test**: `load_skill` returns the body wrapped in `<skill_content>`.
- [ ] **Test**: frontmatter is absent from the returned content.
- [ ] **Test**: the skill directory is included.
- [ ] **Test**: resources are listed and NOT read.
- [ ] **Test**: the listing is capped and says so.
- [ ] **Test**: re-activating an active skill does not re-inject the body.
- [ ] **Implement** `SkillContent` and teach `load_skill` about file skills.
- [ ] `make check` green.

## Phase 6 — the approval gate

- [ ] **Test**: a model-initiated `load_skill` raises an approval ask naming the
      skill.
- [ ] **Test**: a refusal is reported to the model as a refusal with the reason,
      and the skill is not loaded.
- [ ] **Test**: approving at SESSION scope covers this session only; another
      session in the same workspace still asks.
- [ ] **Test**: approving at WORKSPACE scope means another session in the same
      workspace does **not** ask.
- [ ] **Test**: approving at GLOBAL scope covers a session in a different
      workspace.
- [ ] **Test**: a second `load_skill` for the same skill does not ask again
      within whatever scope was granted.
- [ ] **Test**: the approval is per skill name — approving `pdf` does not permit
      `data-analysis`.
- [ ] **Test**: `/skill-name` records a SESSION-scope approval only, so another
      session still asks.
- [ ] **Implement** the ask through the existing approval seam, reusing
      `TApprovalScope` rather than inventing a skill-specific one.
- [ ] `make check` green.

## Phase 7 — catalog

- [ ] **Test**: `StableText` includes `location` per skill.
- [ ] **Test**: a skill with `Problem` set is absent from the catalog.
- [ ] **Test**: an already-approved skill is marked so the model knows a load
      will not prompt.
- [ ] **Implement** the catalog change in `HildiSkills`.
- [ ] `make check` green.

## Phase 8 — operator activation

- [ ] **Test**: `/skill-name` loads that skill without the model acting.
- [ ] **Test**: `/skill-name` records the same session approval the gate grants,
      so a later model-initiated load does not ask.
- [ ] **Test**: an unknown name is refused and lists what is available.
- [ ] **Test**: the palette offers known skill names.
- [ ] **Implement** the palette entry and dispatch.
- [ ] `make check` green.

## Close-out

- [x] Update `docs/features/FEATURES.md` with the row.
- [x] Update `docs/features/Skills/FEATURE.md` — it said "file-based instruction
      packs are the next"; it now points here.
- [ ] **The `/skill-name` palette entry and dispatch.** `LoadSkillByName` exists
      and is tested, but nothing in the TUI calls it yet: the command is not in
      `DefaultCommands` and `RunCommand` has no branch. Without that the operator
      has no way to invoke it, which is the same gap that made `/undo` unreachable
      before it was registered.
- [ ] **`/skill-name` must not be a static palette entry.** The palette is built
      from a fixed array; skill names are dynamic. Either the entry is created at
      startup from the discovered keys, or the composer recognises `/<key>` when
      it matches a known skill. Decide before wiring.

## What is NOT done

Everything above is real and tested at the unit level. What has **not** happened:

- **No interactive verification.** Nothing has been driven in a terminal: no
  discovery against a real `~/.agents/skills`, no approval prompt for a skill
  load, no `/skill-name`.
- **Nothing scans at session start.** `ScanSkills` and `ImportSkills` are never
  called by `THarnessSession.Init` - the machinery exists and is unattached. A
  real session today still has no file-backed skills.
- **The recorder is not wired into `Lazy_MCP`'s reconcile path** either, so a
  rescan after a skill is added mid-session does not happen.

Those three are the difference between "the pieces work" and "the feature works".
