# SPEC: Approval Review v1

**Related:** [FEATURE.md](FEATURE.md)

## 1. The ask data (phase 2)

```pascal
TApprovalAsk = record
  Summary: string;          // today: the segment text
  Reason: string;
  Subject: TApprovalSubject;
  Options: TApprovalOptionArray;
  Covers: TApprovalSubject;
  HasCovers: Boolean;
  { New: the whole command and the span the operator is approving. }
  Script: string;           // '' when unknown (older producers)
  FocusStart, FocusLen: Integer;   // 1-based byte offset, 0 = no focus
end;
```

- Producers: `BuildAsks` (the splitter) fills `Script := ACommand` and the
  segment span; the tier fills it from the parsed command's span.
- The splitter's tokens need `Start`/`Len` (the tokenizer knows them), so
  `TCommandSegment` gains `Start`/`Len`; the tier's AST needs a `TCommand` span
  (the lexer already tracks offsets; the parser records the first and last
  token's range).
- `session.protocol` encodes `script`, `focus_start`, `focus_len` additively
  (absent = no focus, so older clients still render).

## 2. Redirects are file effects (phase 1, shipped)

| Operator | Ask |
|---|---|
| `>`, `>>`, `>|`, `2>`, `2>>`, `1>`, `1>>`, `&>`, `&>>` | `file:write` for the target |
| `<` | `file:read` for the target |
| `<<`, `<<-`, `<<<` | none (a delimiter, not a path) |
| `<&`, `>&` | none (an fd duplication) |

- The target is resolved like any path (against the effective cwd, with `cd`
  tracked) and must be inside the workspace; an outside target keeps the
  `path:` ask.
- The subject is `Path = <workspace-relative>`, `Params = [<relative>]` — the
  file tools' shape.
- Options, mirroring `TFileTool.Approve`:
  `once`, `exact` (`Params = [rel]`), `dir` (`Directory`), `ext`
  (`Extension`, writes only), `dir_ext` (`Directory` + `Extension`, writes
  only), `any`. There is no `never`: a persistent deny is a rule in the store
  (the `aeDeny` effect), not an option the dialog offers; denying the prompt is
  the per-call answer.
- The segment's `Summary` includes its redirects (`echo x > out.txt`), because
  the operator must see the effect.

## 2a. Pure commands (shipped)

`hildi.command.pure.IsPureCommand` names the commands that produce
text from their own arguments and nothing else:

`echo`, `printf`, `true`, `false`, `basename`, `dirname`.

- They raise **no command ask**, on both executors (`BuildAsks` skips the
  segment; the tier's gate skips the command ask).
- Their **redirects are still asked**: the interpreter records the command's
  expanded `Reads`/`Writes` in `TShellCall`, and the gate raises the file asks.
- `test`/`[` is not pure (it inspects the filesystem); neither is anything that
  reads, lists, or writes. The rule is "no filesystem, no stdin, no information
  about the machine", not "harmless name".

The tier's gate asks, in one batch: the command (unless pure) + `file:write`
for every write redirect + `file:read` for every read redirect. An empty batch
allows without a prompt.

## 2b. The effect-scoped gate (tier, shipped)

`hildi.shell.effects.ComputeEffects(Name, Args, out Reads, out
Writes, out Known)` maps a builtin command to the files it will read and write,
positionally (grep's first operand is a pattern, `cp`'s second is the
destination) and without touching the filesystem:

| Effects | Commands |
|---|---|
| reads | `cat`, `head`, `tail`, `wc`, `grep`, `rg`, `sed` (without `-i`), `awk`, `jq`, `sort`, `uniq`, `cut`, `ls`, `find`, `test`/`[` (file tests), `cp`'s source |
| writes | `sed -i`, `tee`, `rm`, `mv`, `cp`'s destination, `mkdir`, `touch` |
| none | `echo`, `printf`, `true`, `false`, `basename`, `dirname`, `tr` (stdin only) |
| unknown | `tool`, `mcp`, and anything not in the table |

The tier's gate then asks, in one batch:

- one `file:write` / `file:read` ask per distinct effect (argument effects and
  redirect effects), with the file tools' options;
- the **command ask only when `Known = False`** (the effect cannot be named);
- nothing at all when the effect list is empty.

A previous grant is matched by the approval service, so a covered effect never
prompts: **the grant is the scope**.

The process path **keeps the command-level asks**, and deliberately: in bash a
name is not the program. The same script may define `cat() { … }`, an alias may
shadow it, and `PATH` may resolve to something else entirely, so the effect
table (which describes *our* builtins) cannot be applied to a spawned command
without under-gating. Its asks still carry the script, the focus span, the
redirect file asks and the outside-path asks; supporting a missing flag in the
tier is how a command moves to effect asks.

**Why not one ask per bucket?** Matching is per subject: a granted scope
suppresses an ask whose `Subject` it covers. A bucket ask with several paths
has no single subject a directory grant can cover, so it would re-prompt
despite the grant — the opposite of "the grant is the scope". Each effect
therefore keeps its own ask (already offering exact / dir / ext / dir+ext /
any), and one grant silences the rest of the call. A batched ask with
per-subject matching is a possible later feature, not a simplification.

## 2c. The working directory (shipped)

- The interpreter's `cd` sets the shell's cwd; every command's `TShellCall.Cwd`
  is the cwd at that point, so effects and redirects resolve against it
  (`cd sub; cat a.txt` asks for `read sub/a.txt`).
- The file ask (and the command ask) appends ` (cwd <root-relative dir>)` when
  the cwd is not the workspace root, so a relative argument is never
  ambiguous.
- `cd` is a library builtin and does not reach the gate. Its target is checked
  through `IShellFileSystem.Stat`, which enforces the workspace: an outside
  directory fails with `path escapes the workspace`, status 1. The script's
  later commands therefore keep the old cwd (or, under `&&`, do not run).
  Outside access remains the process tier's business, where `PathAccesses`
  tracks a top-level `cd` for the path asks.

## 3. The dialog (shipped)

`TApprovalModal` renders the ask's `Script` (the whole command), so the
operator reads the command in context rather than a reconstructed segment:

- The script is wrapped to the details band (honouring newlines, hard-breaking
  a long word), and the band shows at most **8 rows**; the rest scrolls.
- The band **opens on the focus**: when the focus row is past the eighth, the
  view starts at `focus - 4` (clamped).
- The focus span is drawn **bold** and the rest of the script **dimmed** —
  rendition only, no colour, so the eye lands on the command being approved.
  A bold `▸` sits in the band's left pad on the focus row. The effect summary
  line above the script stays normal text: it is the key information.
- PageUp/PageDown scroll a page; the wheel scrolls three rows.
- For an **effect** ask (one with `Subject.Path`, e.g. `file:read`), the
  summary line is shown *above* the script — the path is what is approved,
  the script is its context. For a command ask the script alone is shown.
- With no `Script` (an older producer) the summary is wrapped and compacted
  exactly as before.

`LayoutScript` (modal-internal) converts the ask's 1-based **byte** span into
characters once (a span ends on a token boundary, hence a character boundary),
then maps each wrapped row's character range against the span, producing the
per-row highlight window. The layout is cached per band width.

## 3a. Offsets on the wire

- The splitter records `TCommandSegment.Start/Len` from its token spans
  (words and redirects, not the operator that introduced the segment).
- The tier's parser records the same span on a simple `TCommand`
  (`shell.ast` + `shell.lexer` `EndOffset`), and the interpreter copies it
  onto `TShellCall.Start/Len`; the gate stamps every ask with the script and
  the call's span.
- `session.protocol` sends `script`, `focus_start`, `focus_len` additively
  (absent = no focus), so an older client keeps rendering `Summary`.
- The modal's height is capped by the terminal; the scroll offset starts at the
  focus line's block.
- `Summary` remains the fallback when `Script` is empty.

## 4. Known effects per command (phase 3)

The tier parses the command, so it can name the file effects a command *will*
make before running it:

| Command | Effects |
|---|---|
| `sed -i` | `file:write` for each file operand |
| `tee` | `file:write` for each file (append when `-a`) |
| `rm` | `file:write` (delete) for each operand |
| `mv` | write for both operands |
| `cp` | write for the destination |
| `mkdir`, `touch` | write for each operand |
| `cat`, `grep`, `rg`, `find`, `jq`, `wc`, `head`, `tail`, `sort`, `uniq` | reads only (the command ask covers them; no extra ask) |

Redirects are already asked this way on both executors (`TShellCall.Writes` /
`Reads`, filled by the interpreter). The table above is for effects that are
not redirects.

These asks are raised in the same gate call as the command ask, before the
command runs. Anything the table does not know falls back to the command ask
alone (never a silent write).

## 5. Bucketing (phase 4)

When several effects share a ref, the options can be shared: one `dir` option
covering every effect under it, one `ext` option covering every effect with
that extension, and a `dir_ext` for the pair. A batch that is all reads is one
`file:read` ask listing its paths; a batch with writes is one `file:write` ask
per distinct directory/extension bucket. The subject carries the paths (the
file tools' `Path` is singular, so a bucket uses `Params` for the paths and a
`Directory`/`Extension` for the scope).

Open question: whether a bucket ask lists every path in its summary (which can
be long) or the scope it covers — the latter reads better and matches the
grant, but hides the specific files.

## Testing

- `test_command_tool`: the redirect summary includes the redirect; `>` yields a
  `file:write` ask with the full option set; `<` yields `file:read` without
  `ext`; `2>&1` yields no file ask; an outside redirect keeps `path:`.
- Phase 2: the splitter span and the modal's scroll/focus rendering.
- Phase 3: `sed -i`, `tee`, `rm`, `mv`, `cp`, `mkdir`, `touch` ask for their
  targets before running; a denied file ask stops the command before it runs.
- Pure commands raise nothing (both executors); `echo x > f` raises only the
  file ask.
