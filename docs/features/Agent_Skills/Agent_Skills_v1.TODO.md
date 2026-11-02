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

## Phase 8 — operator activation (`/skill` and `ctrl+=`)

**Blocked on a seam, not on design.** `THarnessApp` holds a `TSessionView`, which
has no `Skills` property, and `ISessionDriver` does not expose the registry
either. The app therefore cannot ask "what skills are available?" — needed for
both the command list entry and the selector.

Three ways in, and it is a choice rather than a puzzle:

1. Put `Skills` on `ISessionDriver` (remote enforces it over the protocol — a
   `scSkills` command; local returns its session's registry directly).
2. Put the registry on `TSessionView`, which the app already holds.
3. Give the app its own reference at construction, alongside `FDriver`.

Option 2 is probably right — the view is the app's window onto the session, and
the registry is session state. Option 1 is the only one that works for a purely
remote app, which matters because the TUI is a client.

- [ ] **Decide the seam above before writing any of Phase 8.**
- [ ] **Test**: `/skill` opens the skill selector.
- [ ] **Test**: `ctrl+=` opens the same selector.
- [ ] **Test**: selecting a skill side-loads it and records a session approval.
- [ ] **Test**: the composer text is UNCHANGED by loading a skill — no marker is
      inserted into what the operator typed.
- [ ] **Test**: the loaded skills render as `+<name>` on their own line under the
      user prompt.
- [ ] **Test**: unloading removes the `+<name>` entry.
- [ ] **Test**: the command list's `/skill` entry names the `ctrl+=` shortcut.
- [ ] **Implement** the selector, the shortcut, and the composer line.
- [ ] `make check` green.

## Phase 8b — the skill detail modal

- [ ] **Test**: clicking `+<name>` opens the modal for THAT skill.
- [ ] **Test**: the modal shows name, description, metadata and instructions.
- [ ] **Test**: the instructions pane is bounded and scrolls (a long SKILL.md must
      not push the CTAs off screen).
- [ ] **Test**: `ctrl+u` unloads the skill and the `+<name>` entry disappears.
- [ ] **Test**: `esc` dismisses and changes nothing — the skill stays loaded.
- [ ] **Test**: a skill with no optional metadata omits those rows rather than
      showing empty labels.
- [ ] **Implement** the modal over the existing modal pattern (`TSessionsModal`,
      `TDiffViewer`, `THistoryModal` all share it).
- [ ] `make check` green.

## Phase 9 — turn summary

- [ ] **Test**: a submitted turn shows the skills it ran with, as `+<name>`.
- [ ] **Test**: a resumed session shows the same line for the same turn.
- [ ] **Implement** the summary line. This is an OUT-OF-SCOPE UI change per the
      operator: the summary needs new fields before it can render them.

## Deferred — inline prompt markers

A footnote-style token typed inline (skills, and later files and line numbers),
edited atomically and parsed out of the markdown on submit. Explicitly NOT part
of v1: the side-load model above does not need it. Recorded here so the idea is
not lost, and because a future markdown editor for files would share the
mechanism.

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

Corrected 2026-11-02. The previous version of this section was **wrong about the
two most important items** and would have sent a reader to rebuild working code:

- it said *"Nothing scans at session start"* — discovery has been wired since
  `c7f6975`, at `Init` **and** at every turn boundary;
- it described `Lazy_MCP`'s rescan gap — MCP is no longer a skill at all.

### Verified working in a real terminal

The operator drove these by hand, which is how the following were found and
fixed: the skill panel opens, lists skills, marks loaded state, resets to the
command list on dismiss, and navigation wraps. Getting there also fixed a
genuine product bug — a client that attached never received the skill catalogue
at all, so `ctrl+=` could only ever say "no skills available".

- discovery against a real `.agents/skills` (the shipped example is found)
- the skills panel: `/skill` and `ctrl+=`
- loaded/unloaded marking, dismiss-and-reset, and wrapping navigation

### Genuinely not done

- **Loading a skill by hand has never been driven.** The open path, the approval
  prompt for a file-backed skill, and body injection are covered by unit tests
  only. Every interactive bug so far came from a path the suite never walked, so
  this is the most likely place for the next one.
- **No composer `+<name>` line.** Nothing renders what is loaded above the input;
  `+N more` truncation is part of the operator's spec and is unimplemented.
- **No skill detail modal.** Consequence: `license`, `compatibility`,
  `allowed-tools` and the resource list are parsed and stored but **never shown
  anywhere**, so parsing them currently buys nothing visible.
- **The unload machinery still exists** — `UnloadSkill`, `scUnloadSkill`, its
  protocol branches and driver method — although skills no longer leave context.
  Removing it is not a simple delete: `scUnloadSkill` sits **mid-enum**, between
  `scLoadSkill` and `scSkills`, so dropping it renumbers the wire format. It needs
  a deprecation marker or an unused slot kept, which is a decision.

### Deliberate, not gaps

- `allowed-tools` is parsed and displayed but **never enforced**: honouring it
  would let a downloaded skill widen its own permissions.
- Phase 9's turn-summary line is out of scope by the operator's decision.
- Per-skill palette commands were replaced by `/skill` + `ctrl+=`.
