# Shell Coverage Decision Matrix

**Status:** Decision aid. Companion to [`JustBash_Coverage.md`](JustBash_Coverage.md),
which lists *what* is missing. This one says **what each addition costs, what it
buys, and what it unblocks** — so the choice is a trade, not a wish list.

## Two structural facts that dominate the ranking

### 1. Command substitution is not implemented

```pascal
if C = '(' then FailAt(AStart, 'command substitution is not supported');
// backquotes: same
```

`$(...)` and `` `...` `` both **hard-fail the parse**. Consequences:

- A script cannot pipe a result into a command's arguments. `xargs` is therefore
  not a convenience — it is **the only** way to feed one command's output into
  another as arguments.
- `grep -o` (just added) is far more useful with `xargs`; without it, extracting a
  match and acting on it still needs a language.
- This also explains a common escalation: a script that would naturally write
  `cmd $(other)` instead reaches for `perl` or a loop.

**If command substitution is cheap to add, it is worth more than any three
commands below.** That is a language change, not a command, so it needs its own
decision — but the matrix below is ranked with its absence assumed.

### 2. The filesystem seam is narrow

`IShellFileSystem` is only `Resolve`, `ReadFile`, `WriteFile`, `ListDir`, `Stat`,
`Info`. `TWorkspaceShellFs` implements more (`Delete`, `Move`, `Copy`, `MakeDir`,
`Touch`), but there is **no** symlink, mode, or truncate primitive.

So "the filesystem stuff" is not one bucket — it splits by whether the seam
already has the primitive:

| Command | Needs a new FS primitive? |
| --- | --- |
| `rmdir` | no — `Delete(recursive=False)` exists |
| `ln -s` | **yes** — no symlink creation |
| `readlink` | **yes** — no link target read |
| `chmod` | **partial** — `Info` reports mode, nothing sets it |
| `mktemp` | no — `MakeDir`/`Touch` compose, but needs a name source |
| `du` | no — walk with `Info` |
| `tree` | no — walk with `ListDir` |

Every "yes" is: interface method + implementation + effect-table entry + a
Windows story (where symlinks need privilege and `chmod` is meaningless).

## The matrix

Cost is engineering cost **in this codebase**, not in general. Value is what
escalation it actually removes.

| Command | Cost | Value | Needs | Verdict |
| --- | --- | --- | --- | --- |
| **`expr`** | **low** | moderate | pure computation, no FS | **Do it.** Also covers `$(())` needs, which do not exist. |
| **`xargs`** | **medium** | **high** | interpreter invocation; the only arg-feeding mechanism | **Do it.** Structurally important because of fact 1. |
| **`strings`** | **low** | moderate | read + scan printable runs | **Do it.** Pairs with `od`. |
| **`base64`** | low | low-moderate | real encode/decode (`Base64Url` is not it) | Do it. Cheap, occasionally essential. |
| **`yq`** | low | **high** | `ParseYaml`/`ToYaml` already exist | **Do it.** Best ratio on this list. |
| **`rmdir`** | **very low** | low | seam already has `Delete` | Do it — a few lines. |
| **`du`** | low | low | walk + `Info` | Cheap; low demand. |
| **`tree`** | low | low | walk + `ListDir` | Cheap; `find` mostly covers it. |
| **`mktemp`** | low-medium | moderate | compose + name source | Do it if scratch files matter. |
| **`ln`** | **medium** | moderate | **new FS primitive** + Windows | Only if symlinks matter. |
| **`readlink`** | medium | low | **new FS primitive** | Only with `ln`. |
| **`chmod`** | medium | low | **mode set** + Windows no-op | Low value for agents. |
| `curl` | — | — | network | **No.** Out of scope by design. |
| `python3`/`js-exec` | — | — | interpreters | **No.** Defeats the sandbox. |
| `tar`/`gzip` | medium | low | archive formats | No — no agent demand seen. |
| `sqlite3` | — | — | — | **No.** We have the store. |
| `alias`/`history` | medium | none | shell state we do not model | **No.** |
| `file` | medium | low | magic-number table | No. |
| `nl`/`fold`/`paste`/`join`/`comm`/`column`/`split` | low each | low | pure text | Only on demand. |
| `yes`/`sleep`/`timeout`/`time` | low | low | trivial | Only on demand. |
| `clear`/`whoami`/`hostname` | trivial | ~none | — | No. |

## Recommended order

**Tier A — do next, all cheap, no new primitives:**

1. **`expr`** — the arithmetic gap; a script that needs `2 + 2` currently needs a
   language.
2. **`yq`** — the parser is written; this is plumbing. Highest ratio here.
3. **`strings`** — completes the binary-inspection pair with `od`.
4. **`base64`** — small, occasionally blocking.
5. **`rmdir`** — a few lines on an existing primitive.

**Tier B — worth it, one is structural:**

6. **`xargs`** — the largest single win *after* `expr`, because without it and
   without `$(...)`, pipelines cannot pass arguments. Medium cost.
7. **`mktemp`**, **`du`** — cheap, moderate-to-low demand.

**Tier C — needs a seam change, decide separately:**

8. **`ln`/`readlink`** — a new FS primitive and a Windows problem. Only if
   symlinks are genuinely needed; nothing in this session's escalation evidence
   says they are.
9. **`chmod`** — low agent value, and a no-op on Windows.

## `curl` — reconsidered, and the strongest case on this list

I originally marked this "No. Out of scope by design." **That was wrong**, and the
reason is the argument *for* it rather than against:

**A builtin `curl` is more controllable than the alternative.** Today a script
using `curl` runs the real binary on the process tier — a black box with hundreds
of flags, writing wherever it likes, following redirects where it likes, and
invisible to the effect table. A builtin version is the opposite: we decide which
flags exist, the gate sees every request and every byte written, and a redirect
to another host is refused rather than followed.

"The sandbox cannot see it" is an argument for bringing it in, not for leaving it
out — which is the same reasoning that justified `od` and `md5sum`.

### What it exposes: the effect model has no notion of network

`ComputeEffects` knows only reads and writes of *paths*:

```pascal
if AWrite then Ref := 'file:write' else Ref := 'file:read';
```

There is no representation for "this command talks to `example.com`". Adding
`curl` therefore requires a **new effect class**, not just a new command:

| Effect | Meaning | Suggested ref |
| --- | --- | --- |
| network read | fetch a URL; response goes to stdout or a file | `net:read` |
| network write | send a body — `-d`, `-F`, `-X POST/PUT/DELETE` | `net:write` |

That matters because a grant scoped to `file:read` must **not** silently authorise
a network fetch. Two independent decisions: may this agent reach the network, and
may it touch these files. Conflating them would mean a file grant quietly becomes
a data-exfiltration grant.

### Cost, honestly

| Piece | Status | Effort |
| --- | --- | --- |
| TLS client | exists — `hildi_tls_connect/read/write`, `hildi_ca_pem` | reuse |
| HTTP request/response | `THttpTransport` exists but is **MCP-specific** (JSON-RPC framing) | **generalise it** |
| Redirect policy | none | new — and a security decision, not a detail |
| Host allowlist | none | new — the main thing that makes this worth owning |
| Effect modelling | **does not exist** | new — see above |
| Output/`-o` handling | pattern exists in file tools | low |

**Effort: medium-high** — the highest on this list. Not because HTTP is hard, but
because every one of the "new" rows is a *policy* decision rather than code, and
a curl with sloppy policy is worse than no curl at all.

### If we do it, the shape

Start deliberately narrow rather than cloning curl:

- **Methods**: `GET`, `HEAD`, `POST`, `PUT`, `DELETE`. No `PATCH`, no `-F` multipart.
- **Flags**: `-s` (quiet), `-f` (fail on HTTP error), `-o FILE`, `-H` (header),
  `-d` (body), `-X` (override), `-L` (follow, **refused across hosts**), `--max-time`.
- **Default**: refuse redirects unless `-L`, and refuse a cross-host redirect even
  with `-L` unless the target is in the same allowlist entry.
- **Responses**: body to stdout (or `-o`), status via exit code, headers only
  with `-i` / `-I`.
- **Never**: `--insecure`/`-k`, arbitrary protocol schemes (`file://`, `ftp://`,
  `gopher://`), or anything that dereferences a URL as a local path.

Explicitly refusing `-k` matters: a builtin that can be told to skip certificate
verification is worse than the binary, because it makes the insecure path *ours*.

## Ranking update

With `curl` in scope, the order changes — it is no longer "cheap thing to skip"
but a **policy-bearing feature with its own prerequisite** (the network effect
class). Suggested:

1. **Network effects** (`net:read` / `net:write`) — a prerequisite, and useful
   independent of curl.
2. **`expr`, `yq`, `strings`, `base64`, `rmdir`** — Tier A, unchanged, all cheap.
3. **`curl`** — narrow shape above, once (1) exists.
4. **`xargs`** — still structural because of no command substitution.
5. **`mktemp`, `du`**, then the seam-changing ones (`ln`, `readlink`, `chmod`).

## The honest counter-argument

Command count is not the metric. **Tier coverage is**: how much of an agent's
real work stays inside the gate. Our only escalation evidence is one session's
transcript — `perl`, `python3`, `od` — and two of those three are now addressed.

Before adding ten more commands, the higher-value question is whether the
**prompt guidance** (which now lists the gated commands) actually changed
behaviour. If agents stop reaching for `perl`, the marginal command is worth
little. If they still reach for it, the answer is more likely **command
substitution** than another coreutil.

## How to keep this honest

`tests/test_shell_effects.pas` asserts every command the tier admits is either
classified or deliberately opaque, so a new command cannot arrive without a
decision about its effects. That test and this matrix should move together.
