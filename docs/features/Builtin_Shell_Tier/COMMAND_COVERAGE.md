# Command & Flag Coverage: Builtin Shell Tier v1

**Related:** [Builtin_Tier_v1.SPEC.md](Builtin_Tier_v1.SPEC.md) · [FEATURE.md](FEATURE.md)

This is the reference for what the builtin tier supports, what it declines, and
what the evidence says to add next. Every number here comes from the recorded
corpus (`tests/data/shell_corpus.txt`, 3.255 commands) parsed with the same
parser the tier uses; re-run `make shell-flags` to reproduce the tallies.

## The rules

1. **Whole script or nothing.** The pre-flight checks every command name and
   every **literal** option. One unknown name or unsupported literal flag
   declines the whole script to `/bin/bash` — nothing runs in the tier.
2. **The runtime edge.** A flag that only appears at run time (from a variable
   or a glob) cannot be checked; if it is unsupported, the command returns a
   usage error (status 2) naming it. That is the documented edge.
3. **How a flag is checked.** Combined short flags are decomposed (`-rf` → `r`,
   `f`); each letter must be in the command's option set. `--` is always
   accepted. A long option (`--all`) is never supported. `N` in an option set
   additionally allows the BSD numeric shorthand (`-20`).
4. **`test` / `[` are exempt**: their `-f`/`-d`/`-eq` are the expression's
   operands, not options.
5. **No silent difference.** A command that runs in the tier must mean what
   bash means for the flags it accepts; anything else declines. The documented
   exceptions are whitespace-only (`wc`/`uniq -c` print unpadded counts).

## What is supported today

### The library's own builtins (no gate, they are language/state)

`cd`, `pwd`, `export`, `unset`, `local`, `shift`, `return`, `exit`,
`set --`. These never spawn and never ask: they mutate shell state.

### Registered commands (gated, one ask per command)

| Command | Options accepted | Behaviour / limits |
|---|---|---|
| `echo` | `-n` | args joined with one space; `-n` drops the newline |
| `head` | `-n N`, `-N` | first N lines (default 10); 0 or 1 file, or stdin |
| `tail` | `-n N`, `-N` | last N lines (default 10); 0 or 1 file, or stdin |
| `cat` | — | many files, `-` for stdin |
| `wc` | `-l -w -c` | default all three; `N name` per file plus a `total` |
| `grep` | `-n -i -v -l -c -F -E -G -r` | **BRE** by default, **ERE** with `-E`, fixed with `-F`; POSIX classes mapped; `-r` walks directories (sorted; symlinked dirs skipped) and prefixes every hit |
| `sed` | `-n -E -r -e -i[SUFFIX]` | paging/ranges (`N`, `$`, `/re/`, ranges), `p`/`d`/`q`, `s///` with `g`/`p`/`i`, `&` and groups; `-i` rewrites through the workspace FS |
| `awk` | `-F` | `[condition] { print ... }`: `$N`/`$0`/`NF`/`NR`, comparisons, `~`/`!~`, `&&`/`||`, string and number literals |
| `find` | — | `-name`/`-iname`/`-type`/`-maxdepth`; symlinked directories are reported, not followed |
| `jq` | `-r -c` | path filters, `.[N]` (negative too), `.[]`, `.["k"]`; jq's pretty/compact output |
| `cut` | `-d -f -c -s` | fields (default TAB) or character positions; `-s` skips lines without the delimiter |
| `tr` | `-d -s` | map/delete/squeeze over character sets with ranges (`a-z`) and escapes (`\t`) |
| `tee` | `-a` | stdin to stdout and to each file, through the workspace FS |
| `printf` | — | `%s`/`%d`/`%i`/`%%` and `\n \t \r`; the format recycles |
| `rg` | `-n -i -l -c -F -E -g --hidden --no-ignore` | recursive by default; respects `.gitignore` inside a repo (root + nested, `!` negation); hidden entries and `.git` skipped; binary files skipped; no stdin heuristic |
| `ls` | `-a -d` | bare names, one path; `-d` prints the path |
| `mkdir` | `-p` | |
| `rm` | `-r -f` | directories only with `-r`; `-f` suppresses missing |
| `mv` | — | one source, one destination |
| `cp` | — | one **file** source; no `-r` |
| `touch` | — | creates missing files; existing mtime is not changed |
| `sort` | `-r -u` | one file or stdin |
| `uniq` | `-c -d -u` | adjacent duplicates; unpadded count |
| `basename` | — | optional suffix |
| `dirname` | — | |
| `test` / `[` | — | one unary or one binary expression |
| `true` / `false` | — | status 0 / 1 |
| `tool` | — | `tool <name> [json]`; allow-list; `run_command` refused |
| `mcp` | — | `mcp <server>:<tool> [json]`; maps to `mcp_<s>_<t>` |

Anything not listed — `git`, `make`, `curl`, `fpc`, `python3` — is **not** in
the tier and always falls back. (`sed`, `awk`, `find`, `jq`, `rg` and the
pipeline glue joined the set; `yq` is deliberately not planned.)

## The evidence

### Commands by frequency (top 20 of 125 distinct names)

| # | command | uses | in tier? |
|---|---|---|---|
| 1 | `grep` | 2287 | yes |
| 2 | `echo` | 2208 | yes |
| 3 | `cd` | 1732 | yes (builtin) |
| 4 | `head` | 1598 | yes |
| 5 | `git` | 1448 | no |
| 6 | `sed` | 1203 | yes |
| 7 | `make` | 500 | no |
| 8 | `tail` | 465 | yes |
| 9 | `ls` | 239 | yes |
| 10 | `fpc` | 113 | no |
| 11 | `rm` | 77 | yes |
| 12 | `cp` | 60 | yes |
| 13 | `sqlite3` | 42 | no |
| 14 | `python3` | 39 | no |
| 15 | `find` | 36 | yes |
| 16 | `sort` | 35 | yes |
| 17 | `wc` | 35 | yes |
| 18 | `awk` | 34 | yes |
| 19 | `cat` | 31 | yes |
| 20 | `curl` | 31 | no |

### The flags that matter for the commands we own

| Flag family | uses | today |
|---|---|---|
| `head -N` (BSD shorthand) | 851 | **added** (was declining) |
| `tail -N` (BSD shorthand) | 457 | **added** (was declining) |
| `grep -E` / `-nE` / `-iE` / `-cE` (`-E` family) | 931 | **added** (BRE/ERE) |
| `grep -r` / `-rn` / `-rln` (recursive) | 309 | **added** |
| `grep -n` | 780 | yes |
| `grep -v` / `-c` / `-i` | 193 | yes |
| `head -n` / `tail -n` | 0 | yes (nobody writes it) |
| `ls -la` (long + all) | 49 | `-a` yes, `-l` declines |
| `rm -f` | 64 | yes |
| `wc -l` | 35 | yes |
| `find -name` | 33 | command missing |

### Whole-script coverage

Of the 3.255 corpus entries, the tier runs **1,717 (52%)** today (76 before
`head -N`/`tail -N`, 105 before grep regex, 585 before `grep -r`, 751 before
`sed`). The rest decline, and the **first** blocker per script is:

| First blocker | scripts |
|---|---|
| `git` not in the tier | 564 |
| `make` not in the tier | 439 |
| `fpc` not in the tier | 111 |
| `python3` not in the tier | 23 |
| `ls -la` (needs `-l`) | 21 |
| `curl` not in the tier | 21 |

What remains is dominated by real programs. The in-tier options left are
`ls -l` (needs a richer `Stat`), `find`, and the transform commands in
[Text & Data Commands](../Text_Data_Commands/FEATURE.md) (`awk`, `jq`, `rg`).

These are *first* blockers and overlap: a script may contain both `sed` and a
regex grep. `sed`, `git`, `make` are real programs, so the tier will never own
them; the question they raise is not "which flag next" but "should a script be
allowed to mix the two tiers" (see below).

Coverage is pinned by `tests/test_shell_tier_corpus.pas` (floor 70, prints the
number and the decline reasons).

## Backlog, in evidence order

**P1 — done:** `head -N` / `tail -N`. 1.308 uses; trivial; the shorthand is what
the corpus actually writes.

**P1.5 — done:** `sed` (1,245 uses, 964 first-blockers). The subset in
[sed v1](../Text_Data_Commands/Sed_v1.SPEC.md) covers paging, ranges,
substitution and in-place edits. Coverage 751 → 1,670 (23% → 51%).

**P1.6 — done:** `awk` fields (15 uses). `-F`, `[condition] { print ... }`
over `$N`/`NF`/`NR`, comparisons, `~`/`!~`, `&&`/`||`. Coverage 1,670 → 1,686.

**P2 — done:** grep regex. `grep` is BRE by default, ERE with `-E`, fixed with
`-F`, using FPC's `regexpr` behind a translation layer: BRE metacharacters,
GNU word boundaries and POSIX classes are mapped; unknown letter escapes stay
literal as bash treats them. A construct the translation cannot express is
declined for a literal pattern (so `auto` falls back to bash) and errors at run
time. Coverage 105 → 585 scripts.

**P4/P5 — done:** `find` (`-name`/`-iname`/`-type`/`-maxdepth`) and `jq`
(path filters, `-r`/`-c`, jq's exact pretty format). Coverage 1,686 → 1,699.

**P3 — done:** `grep -r` / `-rn` / `-rln`. Walks directories through the FS
seam, prefixes every hit (as bash does, even for a file operand), lists every
file for `-rc`, and skips symlinked directories (that is `-R`, not `-r`). The
walk is depth-limited and sorted; bash's directory order is not, so fixtures
that depend on order pipe through `sort`. Coverage 585 → 751.

**P4 — `ls -l` (49 uses, under 20 first-blockers).** Needs a richer `Stat`
(mode, size, mtime) in `IShellFileSystem`; small but touches the seam. Until
then `-l` declines (and falls back).

**P5 — `find -name` / `-type` (33 uses).** A deliberately small `find`
(`find PATH -name GLOB [-type f|d]`), sharing the recursive walk with `grep -r`.

**P6 — long tail:** `sort -n`, `sort -k`, `cut -d/-f`, `tr`, `sed`-lite
(`sed -n 'a,bp'`) — each below ~20 uses; add only when a workload asks.

**Never in the tier:** `git`, `make`, `fpc`, `python3`, `curl`, `sqlite3`,
`awk` — real programs whose semantics the tier must not imitate. The process
tier is their home, and that is correct.

## The bigger decision: one tier or two?

The tier is whole-script by design: partial execution across two engines makes
side effects and `cd`/environment state unpredictable, and the approval story
messier (two gates for one script). The cost is visible above: one `sed` in a
chain sends the whole script to the process tier, so the historical corpus is
only 3% tier-eligible.

Three options for the next feature, in order of cost:

1. **Keep whole-script, grow the set** (P2–P5). Simple, safe, and the win is
   concentrated in scripts the agent writes itself. Coverage rises with the
   flags it actually uses.
2. **Steer the model** — **implemented**: the `mode` parameter (`builtin` /
   `bash` / `auto`) plus the tool description that lists the command set and
   when to use each. `builtin` fails instead of falling back, so an explicit
   builtin request is honoured exactly.
3. **Mixed execution** — run the supported commands in the tier and hand the
   rest to `/bin/bash`, syncing cwd and exported variables across the boundary.
   That is the only way to own `cd /ws && sed -n … | grep …`, but it is a
   separate feature with its own spec: the state sync, the two gates, and what
   "the script's status" means.

Recommendation: do (1) and (2) now; treat (3) as its own feature if the tier is
meant to carry the bulk of the traffic rather than the self-contained scripts.

## Choosing the executor: `mode`

`run_command` takes an optional `mode`, and the tool description tells the model
when to use which:

| mode | use it for |
|---|---|
| `builtin` | composed file work: loops, pipelines, redirects, `tool`/`mcp` composition. Gated once per command, never spawns, and **fails** rather than silently falling back. |
| `bash` | real programs: `git`, `sed`, `make`, `curl`, builds, package managers — anything outside the table above. The splitter's asks are the gate. |
| `auto` (default) | no opinion: the tier when the whole command is supported, `/bin/bash` otherwise. |

That turns "which tier?" into an explicit choice the model makes per call, and
makes the fallback intentional instead of incidental. It does not change the
coverage numbers above — only who decides.

## Adding a flag or a command

1. Add the command to `CommandSpecs` in `src/hildegard.helper.shell.commands.pas`
   with its option string (`N` for a numeric shorthand).
2. Implement the handler there; it must return a `TShellResult` and never raise.
3. Register it in `TBuiltinShell.Create`.
4. Add tests in `tests/test_shell_commands.pas` (common + error case) and, for
   an end-to-end script, a fixture in `tests/data/shell_commands_differential.txt`
   recorded from `/bin/bash`.
5. Re-run `make shell-flags` and the coverage test; update this document.

Tooling:

- `make shell-flags` — the command/flag tallies above.
- `make shell-ast` — dump the AST for any script.
- `make test SUITE=TShellTierCorpusTest` — the whole-script coverage number.
