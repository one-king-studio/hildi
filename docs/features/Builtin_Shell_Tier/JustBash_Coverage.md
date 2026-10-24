# just-bash Coverage Comparison

**Status:** Reference. Compares our builtin shell tier against
[`vercel-labs/just-bash`](https://github.com/vercel-labs/just-bash)
**`just-bash@3.6.0`** (the version this was read from).

**Why this document exists:** the comparison was first compiled from the GitHub
API into `build/`, which is gitignored — so it would have died on a clean clone,
exactly like the `features_audit.py` script it replaced. The gap list belongs in
the repo.

**How the data was obtained:** `gh api repos/vercel-labs/just-bash/contents/packages/just-bash/src/commands`
for the command directories, and each command's own `.ts` for its
`flagsForFuzzing` list. Re-verify before acting on an old copy; just-bash moves.

**Not authoritative about behaviour.** We compared *flag names*, not semantics.
A shared flag may still differ in edge cases.

## Summary

| | just-bash | ours |
| --- | --- | --- |
| Commands | **80** | **31** |
| Both | 27 | |
| Theirs only | 53 | |
| Ours only | 4 (`[`, `false`, `tool`, `mcp`) | |

## Why the gap matters more than convenience

`KnownTierName` returns False for anything not in `CommandSpecs`, and the tier
then hands the **whole script** to the process tier. A missing command is
therefore not a missing convenience — it is a **silent escalation out of the
gated tier**, where effects are *inferred* by a before/after tree walk rather
than known exactly, and where the per-call option whitelist no longer applies.

Observed in one session: `perl -pi -e` (used repeatedly), `python3`, and `od`
all escalated without any signal. `perl -pi` is the most consequential, because
it is mostly `sed -i` work.

**Tier coverage is a measure of how much of an agent's real work stays inside
the gate.**

## Commands we both support

| Command | Ours | just-bash adds | Value |
| --- | --- | --- | --- |
| `grep` | `-nivlcFEGrm` | `-A -B -C -o -w -x -q -h -e -f -P -L` | **high** |
| `sed` | `-nEr ei` | *(same)* | at parity |
| `cut` | `-dfcs` | *(same)* | at parity |
| `tr` | `-ds` | `-c -C` | low |
| `sort` | `-rufnhMkbtsco` | `-V -d -M -b -s -c` | moderate |
| `uniq` | `-cdu` | `-i` | low |
| `head` | `-nN` | `-c -q -v` | moderate |
| `tail` | `-nN` | `-c -q -v` | moderate |
| `wc` | `-lwc` | `-m` | low |
| `awk` | `-F` | `-v` | low |
| `find` | `-name -type -maxdepth` | `-iname -mindepth -empty -print0` | moderate |
| `cat` `ls` `mkdir` `rm` `mv` `cp` `touch` `echo` `printf` `true` `basename` `dirname` `jq` `rg` `tee` `test` | | | |

## Theirs only — the full 63

Grouped by whether a capable library **already exists here**, which is what
makes a command cheap rather than merely desirable.

### Nearly free — the machinery is already in the repo

| Command | Reuse | Effort |
| --- | --- | --- |
| `diff` | `DiffText` / `ApplyUnifiedDiff` in `src/changes/changes.text.pas` | **very low** |
| `yq` | `ParseYaml` / `ToYaml` in `hildegard.helper.yaml` | **very low** |
| `md5sum` | `Sha256Hex` / `Sha256File` in `hildegard.helper.hash` | trivial |
| `stat` | `FFs.Info` already returns size, kind, mtime | trivial |
| `pwd` | `ACall.Cwd` | trivial |
| `seq`, `rev`, `tac`, `nl` | pure string work over `LinesOf` | trivial |
| `which` | `IsBuiltinCommand` + the function table | trivial |
| `env`, `printenv` | the variable table already exists | trivial |
| `date` | `IsoUtc` shape in `wrap.pas`; `+%s` is `DateTimeToUnix` | low |

`diff` is the standout. It is how an agent verifies its own edit landed, and
today that costs a `perl` or `python3` escalation. It also pairs with
`patch_apply`.

**Constraint to check first:** `make shell-standalone` builds `src/shell` with
only `src/shell` on the path. `hildegard.helper.shell.commands` lives in `src/`,
not `src/shell/`, so reaching `changes.text` *should* be legal — but confirm it
or the isolation gate breaks.

### Small but real

`head -c`, `tail -c`, `wc -m`, `uniq -i`, `tr -c`, `grep -o/-w/-q/-h`,
`base64` (needs real, not URL, encoding — `Base64Url` in `mcp.oauth` is not it),
`xargs` (mostly matters with `find`), `split`, `join`, `paste`, `fold`, `column`,
`comm`, `expand`, `unexpand`, `expr`, `nl`.

### Filesystem completeness

`ln`, `readlink`, `chmod`, `rmdir`, `mktemp`, `du`, `tree`, `file`, `strings`,
`od`, `whoami`, `hostname`, `sleep`, `timeout`, `time`, `yes`, `clear`,
`history`, `alias`.

### Skip deliberately

| Command(s) | Why |
| --- | --- |
| `curl` | network — out of scope by design |
| `python3`, `js-exec`, `bash` | interpreters defeat the point of a sandbox |
| `tar`, `gzip`, `compression` | archive formats, no agent need seen |
| `sqlite3` | we have the store |
| `history`, `alias`, `help` | shell state we do not model |
| `html-to-markdown`, `xan`, `query-engine`, `search-engine`, `worker-bridge` | product-specific |
| `split`, `column`, `comm`, `join` | niche for agent work |

## Ours only (13)

`tool`, `mcp`, `[`, `false`, `rg` and the rest of the core set. `tool`/`mcp` are
the harness's own dispatch and have no just-bash equivalent; `[` and `false` are
ours for completeness.

## Recommended order

1. **`diff`** — highest value-to-effort; removes a real escalation.
2. **`stat`, `md5sum`, `pwd`, `seq`** — an afternoon, all trivial.
3. **`yq`** — the parser exists; this is plumbing.
4. **`grep -o -w -x -q -h`** — analysed and planned; see the matrix.

## Caveat

The demand evidence is one session's observed escalations. That is a real
signal, but it is one agent's habits. If telemetry exists on which commands
actually fall back to the process tier, it beats this list.
