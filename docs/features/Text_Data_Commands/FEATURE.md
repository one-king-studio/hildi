# Feature: Text & Data Commands

**Status:** Partially implemented — `sed` shipped; `awk`, `jq`, `yq`, `rg` planned.

**Related:** [Builtin Shell Tier](../Builtin_Shell_Tier/FEATURE.md) ·
[Command & Flag Coverage](../Builtin_Shell_Tier/COMMAND_COVERAGE.md) ·
[Sed v1 SPEC](Sed_v1.SPEC.md)

## The Problem

The builtin shell tier now carries the simple file-work commands (`cat`, `grep`,
`ls`, `head`, …), but the **transform** commands are what remain outside it:

- After `grep`, `head`, `wc` and `grep -r`, the top in-tier blocker in the
  recorded corpus was `sed` — **1,245 uses, 964 scripts where it was the first
  reason to fall back**. Almost all of it is one shape: `sed -n 'a,bp'` to page
  a region, `sed -n '/re/,/re/p'` to print a section, and `sed 's/x/y/'` (with
  `-i`) to rewrite.
- `awk` appears 15 times (field printing: `awk -F: '{print $2}'`,
  `awk '{print $1, $2}'`, simple numeric conditions).
- `jq`, `yq`/`yaml` and `rg` appear **zero** times in the corpus — the agent
  reached for `python3 -c`, `sqlite3`, or the harness's typed tools instead.
  They are prospective: the composition primitives a coding agent wants once it
  can pipe anything into anything.

Every one of those commands forces the whole script into `/bin/bash`, where the
gate is the splitter's guess and nothing is observable. The composition the
agent actually wants — *read a region, filter it, rewrite it, query a document*
— is exactly the shape the tier exists to own.

## The Decision

Add the transform commands to the builtin shell tier as **subsets**, in
evidence order, each declining anything outside its subset so the process tier
still handles the long tail:

1. **`sed`** (shipped): `-n`, `-E`/`-r`, `-e`, `-i[SUFFIX]`; addresses `N`, `$`,
   `/re/`, and ranges (numeric, regex, to end); `p`, `d`, `q`, `s///` with
   `g`/`p`/`i`. The covered set is [the corpus's actual sed usage](Sed_v1.SPEC.md).
2. **`awk`** (planned): `-F`, `{print $1, $2, …}`, `$N` comparisons and
   `$N ~ /re/` with `&&`/`||`, `NR`/`NF`, and one pattern-action form. Not a
   general awk: no functions, arrays, getline, printf formats beyond `print`.
3. **`jq`** (planned): identity, `.foo`, `.foo.bar`, `.foo[]`, `.[N]`,
   `.["k"]`, `-r`, `-c`, and `keys`/`length`. A query subset, not a language.
4. **`yq`** (planned, last): the same path queries over YAML, since the harness
   already has `yaml_read`/`yaml_edit`; add it only when a workload asks.
5. **`rg`** (planned, last): recursive search over the same engine as `grep`,
   with `-n`, `-i`, `-l`, `-c`, `-F`, `-E`, `-g`. The open question is
   `.gitignore` fidelity: ripgrep's defining behaviour is skipping ignored
   files, so a version that does not must decline rather than return a
   different set of hits.

## Boundaries

- **Subsets, not emulations.** Each command declares what it supports; a
  program outside it is a program error (status 1/2) or a pre-flight decline —
  never a silent approximation.
- **The pattern engine is shared.** `sed` and `grep` use the same BRE/ERE
  translation (`shell.pattern`), so `s/a\+b/x/` and `grep 'a\+b'` mean the same
  thing and neither drifts from bash alone.
- **The filesystem stays bounded.** `sed -i` writes through
  `TWorkspaceShellFs`; an outside path is refused like a redirect.
- **The gate is unchanged.** Each command asks once, with `run_command:<bin>`
  and the inherited reason.
- **Not a scripting language.** No `awk` functions, no `jq` programs with
  variables, no sed hold space. Those are what the process tier is for.

## Why This Order

The corpus decides: `sed` was 964 first-blockers and one afternoon's work;
`awk` is a dozen uses; `jq`/`yq`/`rg` are zero. Shipping `sed` moved whole-script
coverage from 23% to **51%** — more than every other addition combined. The rest
are worth having when the model actually reaches for them, and the feature can
grow one command at a time without touching the tier's core.

## Acceptance

- `sed` programs in the shipped subset run in the tier and match `/bin/bash`
  byte for byte (13 recorded differential fixtures).
- A `sed` program outside the subset fails with a message naming the construct;
  a *literal* unsupported construct declines the script (so `auto` falls back).
- `sed -i` rewrites through the workspace filesystem and keeps a backup when a
  suffix is given.
- The remaining commands land with the same contract: subset, differential
  fixtures, and a coverage measurement.
